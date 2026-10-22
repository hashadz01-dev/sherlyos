/**
 * M1-S2.2 two-session proofs. Local Docker only.
 * Setup commits isolated m1s2c_* fixtures; cleanup releases crate holds.
 * Does not seed lots or flip cutover flags.
 */
import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_m1_s2_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(new URL("./phase_m1_s2_concurrency_cleanup.sql", import.meta.url), "utf8")

function psql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "docker",
      ["exec", "-i", "supabase_db_sherlyos", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"],
      { stdio: ["pipe", "pipe", "pipe"] },
    )
    let output = ""
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    child.stderr.on("data", (chunk) => {
      output += chunk
    })
    child.on("close", (code) => {
      const text = output.trim()
      if (code === 0) resolve(text)
      else reject(new Error(text || `psql exit ${code}`))
    })
    child.stdin.end(sql)
  })
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function assertFlagsUnchanged() {
  const flags = await psql(`
    select value::text from public.app_configuration
    where key = 'stock.lots.dual_write_enabled'
    union all
    select value::text from public.app_configuration
    where key = 'stock.lots.aggregate_only_blocked';
  `)
  const lines = flags.split(/\r?\n/)
  if (lines[0] !== "false" || lines[1] !== "false") {
    throw new Error(`cutover flags must remain false/false, got ${flags}`)
  }
}

function holdWithMarker(sql) {
  const child = spawn(
    "docker",
    ["exec", "-i", "supabase_db_sherlyos", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"],
    { stdio: ["pipe", "pipe", "pipe"] },
  )
  let output = ""
  child.stdout.on("data", (chunk) => {
    output += chunk.toString()
  })
  child.stderr.on("data", (chunk) => {
    output += chunk.toString()
  })
  const done = new Promise((resolve, reject) => {
    child.on("close", (code) => {
      const text = output.trim()
      if (code === 0) resolve(text)
      else reject(new Error(text || `holder exit ${code}`))
    })
  })
  child.stdin.write(sql)
  return {
    end: () => child.stdin.end(),
    done,
    getOutput: () => output,
  }
}

const runId = Date.now().toString()

await assertFlagsUnchanged()
await psql(setupSql)

async function cancelHeld(crateCode) {
  await psql(`
    select public.m1s2c_claim('admin');
    set role authenticated;
    select public.cancel_lot_reconciliation(
      scope.session_id,
      header.version,
      'release concurrency fixture'
    )
    from public.stock_lot_reconciliation_scope_crates scope
    join public.stock_lot_reconciliations header on header.id = scope.session_id
    join public.crates on crates.id = scope.crate_id
    where crates.code = '${crateCode}'
      and scope.holds_scope
      and header.status in ('draft', 'rejected');
  `)
}

try {
  // T20 overlapping create: holder keeps the unique crate row uncommitted.
  {
    const holder = holdWithMarker(`
begin;
select public.m1s2c_claim('admin');
set role authenticated;
select public.create_lot_reconciliation(
  (select id from public.branches where code = 'm1s2c_a'),
  array[(select id from public.crates where code = 'm1s2cca1')],
  'm1s2c-hold-a1-${runId}',
  null
);
select 'CREATED';
select pg_sleep(2.5);
commit;
`)
    await sleep(600)
    let competing
    try {
      competing = await psql(`
        set lock_timeout = '8s';
        select public.m1s2c_claim('admin');
        set role authenticated;
        select public.create_lot_reconciliation(
          (select id from public.branches where code = 'm1s2c_a'),
          array[(select id from public.crates where code = 'm1s2cca1')],
          'm1s2c-compete-a1-${runId}',
          null
        );
      `)
    } catch (error) {
      competing = error.message
    }
    holder.end()
    await holder.done
    if (!/overlapping lot reconciliation/i.test(competing)) {
      throw new Error(`T20 expected overlapping rejection, got ${competing}`)
    }
    console.log("PASS T20 overlapping create")
    await cancelHeld("m1s2cca1")
  }

  // Non-overlapping crate succeeds after crate 1 is independently held.
  {
    const payload = await psql(`
      select public.m1s2c_claim('admin');
      set role authenticated;
      select public.create_lot_reconciliation(
        (select id from public.branches where code = 'm1s2c_a'),
        array[(select id from public.crates where code = 'm1s2cca2')],
        'm1s2c-nonoverlap-${runId}',
        null
      ) ->> 'status';
    `)
    if (!payload.split(/\r?\n/).includes("draft")) {
      throw new Error(`T03 concurrent non-overlap failed: ${payload}`)
    }
    console.log("PASS non-overlapping create")
    await cancelHeld("m1s2cca2")
  }

  // T21 concurrent count editing: first commit wins, second PT409.
  {
    const sessionId = await psql(`
      select public.m1s2c_claim('admin');
      set role authenticated;
      select public.create_lot_reconciliation(
        (select id from public.branches where code = 'm1s2c_a'),
        array[(select id from public.crates where code = 'm1s2cca1')],
        'm1s2c-count-session-${runId}',
        null
      ) ->> 'id';
    `)
    const id = sessionId.split(/\r?\n/).filter(Boolean).at(-1)
    const holder = holdWithMarker(`
begin;
select public.m1s2c_claim('godown');
set role authenticated;
select public.save_lot_reconciliation_count(
  '${id}'::uuid,
  1,
  (select id from public.crates where code = 'm1s2cca1'),
  (select id from public.products where sku = 'm1s2c-soap'),
  4
);
select 'SAVED';
select pg_sleep(2.5);
commit;
`)
    await sleep(600)
    let competing
    try {
      competing = await psql(`
        set lock_timeout = '8s';
        select public.m1s2c_claim('godown2');
        set role authenticated;
        select public.save_lot_reconciliation_count(
          '${id}'::uuid,
          1,
          (select id from public.crates where code = 'm1s2cca1'),
          (select id from public.products where sku = 'm1s2c-soap'),
          4
        );
      `)
    } catch (error) {
      competing = error.message
    }
    holder.end()
    await holder.done
    if (!/PT409|changed by someone else/i.test(competing)) {
      throw new Error(`T21 expected PT409, got ${competing}`)
    }
    console.log("PASS T21 concurrent count PT409")
    await cancelHeld("m1s2cca1")
  }

  // T22 approve waits for an in-flight transfer lock, then fail-closes on drifted baseline.
  {
    const created = await psql(`
      select public.m1s2c_claim('admin');
      set role authenticated;
      select public.create_lot_reconciliation(
        (select id from public.branches where code = 'm1s2c_a'),
        array[(select id from public.crates where code = 'm1s2cca2')],
        'm1s2c-approve-race-${runId}',
        null
      ) ->> 'id';
    `)
    const id = created.split(/\r?\n/).filter(Boolean).at(-1)
    await psql(`
      select public.m1s2c_claim('godown');
      set role authenticated;
      do $$
      declare
        payload jsonb;
        version integer;
        expected integer;
        line uuid;
      begin
        payload := public.get_lot_reconciliation('${id}'::uuid);
        version := (payload ->> 'version')::integer;
        expected := (payload -> 'lines' -> 0 ->> 'expected_quantity')::integer;
        line := (payload -> 'lines' -> 0 ->> 'id')::uuid;
        payload := public.save_lot_reconciliation_count(
          '${id}'::uuid,
          version,
          (select crate_id from public.stock_lot_reconciliation_lines where id = line),
          (select product_id from public.stock_lot_reconciliation_lines where id = line),
          expected
        );
        version := (payload ->> 'version')::integer;
        payload := public.save_lot_reconciliation_lots(
          '${id}'::uuid,
          version,
          line,
          jsonb_build_array(jsonb_build_object(
            'identity_unknown', true,
            'expiry_unknown', true,
            'quantity', expected,
            'condition', 'available'
          ))
        );
        version := (payload ->> 'version')::integer;
        perform public.submit_lot_reconciliation(
          '${id}'::uuid,
          version,
          'm1s2c-submit-race-${runId}'
        );
      end;
      $$;
    `)

    const holder = holdWithMarker(`
begin;
select public.m1s2c_claim('godown');
set role authenticated;
select public.post_crate_transfer(
  (select id from public.products where sku = 'm1s2c-soap'),
  (select id from public.crates where code = 'm1s2cca2'),
  (select id from public.crates where code = 'm1s2cca1'),
  1,
  'm1s2c-xfer-race-${runId}',
  null
);
select 'TRANSFERRED';
select pg_sleep(2.5);
commit;
`)
    await sleep(600)
    let competing
    try {
      competing = await psql(`
        set lock_timeout = '8s';
        select public.m1s2c_claim('admin');
        set role authenticated;
        select public.approve_lot_reconciliation(
          '${id}'::uuid,
          (
            select version from public.stock_lot_reconciliations where id = '${id}'::uuid
          ),
          'race'
        );
      `)
    } catch (error) {
      competing = error.message
    }
    holder.end()
    await holder.done
    if (!/baseline changed|discrepanc/i.test(competing)) {
      throw new Error(`T22 expected baseline/discrepancy rejection, got ${competing}`)
    }
    console.log("PASS T22 approve versus posting")
  }

  await assertFlagsUnchanged()
} finally {
  await psql(cleanupSql)
}

console.log("M1-S2.2 concurrency checks passed")
