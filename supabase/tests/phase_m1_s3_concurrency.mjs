/**
 * M1-S3 two-session proofs. Local Docker only.
 * Setup may seed lots in this isolated local database; cleanup wipes lots only
 * when dual-write is off and ledger has no lot_id rows.
 */
import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_m1_s3_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(new URL("./phase_m1_s3_concurrency_cleanup.sql", import.meta.url), "utf8")

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

function lastLine(text) {
  return String(text).split(/\r?\n/).filter(Boolean).at(-1)
}

await psql(setupSql)
await psql(`
  begin;
  select set_config('app.lot_reconciliation_write', 'on', true);
  update public.stock_lot_reconciliation_scope_crates sc
  set holds_scope = false
  from public.stock_lot_reconciliations s
  join public.branches b on b.id = s.godown_id
  where sc.session_id = s.id and b.code like 'm1s3c_%';
  commit;
`)
const runId = Date.now().toString()

try {
  const sessionId = lastLine(
    await psql(`
      select public.m1s3c_claim('admin');
      set role authenticated;
      select public.create_lot_reconciliation(
        (select id from public.branches where code = 'm1s3c_a'),
        array[(select id from public.crates where code = 'm1s3cca1')],
        'm1s3c-session-${runId}',
        null
      ) ->> 'id';
    `),
  )

  await psql(`
    select public.m1s3c_claim('godown');
    set role authenticated;
    do $$
    declare
      payload jsonb;
      version integer;
      line uuid;
      expected integer;
    begin
      payload := public.get_lot_reconciliation('${sessionId}'::uuid);
      version := (payload ->> 'version')::integer;
      line := (payload -> 'lines' -> 0 ->> 'id')::uuid;
      expected := (payload -> 'lines' -> 0 ->> 'expected_quantity')::integer;
      payload := public.save_lot_reconciliation_count(
        '${sessionId}'::uuid,
        version,
        (select crate_id from public.stock_lot_reconciliation_lines where id = line),
        (select product_id from public.stock_lot_reconciliation_lines where id = line),
        expected
      );
      version := (payload ->> 'version')::integer;
      payload := public.save_lot_reconciliation_lots(
        '${sessionId}'::uuid,
        version,
        line,
        jsonb_build_array(jsonb_build_object(
          'manufacturer_lot_code', 'SOAP-C',
          'expiry_date', '2028-01-01',
          'expiry_unknown', false,
          'identity_unknown', false,
          'quantity', expected,
          'condition', 'available'
        ))
      );
      version := (payload ->> 'version')::integer;
      perform public.submit_lot_reconciliation('${sessionId}'::uuid, version, 'm1s3c-submit-${runId}');
    end;
    $$;
  `)

  await psql(`
    select public.m1s3c_claim('admin2');
    set role authenticated;
    select public.approve_lot_reconciliation(
      '${sessionId}'::uuid,
      (select version from public.stock_lot_reconciliations where id = '${sessionId}'::uuid),
      'concurrency',
      'm1s3c-approve-${runId}'
    );
  `)

  await psql(`
    select public.m1s3c_claim('admin');
    set role authenticated;
    select public.seed_legacy_stock_lots();
  `)

  const version = lastLine(
    await psql(`select version from public.stock_lot_reconciliations where id = '${sessionId}'::uuid;`),
  )

  {
    const holder = holdWithMarker(`
begin;
select public.m1s3c_claim('admin');
set role authenticated;
select public.apply_legacy_lot_attribution(
  '${sessionId}'::uuid,
  ${version},
  'm1s3c-apply-hold-${runId}'
);
select 'APPLIED';
select pg_sleep(2.5);
commit;
`)
    await sleep(600)
    let competing
    try {
      competing = await psql(`
        set lock_timeout = '8s';
        select public.m1s3c_claim('admin2');
        set role authenticated;
        select public.apply_legacy_lot_attribution(
          '${sessionId}'::uuid,
          ${version},
          'm1s3c-apply-compete-${runId}'
        ) ->> 'status';
      `)
    } catch (error) {
      competing = error.message
    }
    holder.end()
    await holder.done
    if (!/applied/i.test(competing) && !/already been applied/i.test(competing)) {
      throw new Error(`concurrent apply expected idempotent applied, got ${competing}`)
    }
    const lots = await psql(`
      select count(*) from public.stock_lots
      where manufacturer_lot_code = 'SOAP-C';
    `)
    if (lastLine(lots) !== "1") {
      throw new Error(`concurrent apply created duplicate lots: ${lots}`)
    }
    console.log("PASS concurrent duplicate apply")
  }

  {
    const holder = holdWithMarker(`
begin;
select pg_advisory_xact_lock(88104301, 1);
select 'LOCKED';
select pg_sleep(2.5);
commit;
`)
    await sleep(600)
    let competing
    try {
      competing = await psql(`
        set lock_timeout = '8s';
        select public.m1s3c_claim('admin');
        set role authenticated;
        select public.post_crate_transfer(
          (select id from public.products where sku = 'm1s3c-soap'),
          (select id from public.crates where code = 'm1s3cca1'),
          (select id from public.crates where code = 'm1s3cca2'),
          1,
          'm1s3c-post-during-attribution-${runId}',
          null
        );
      `)
    } catch (error) {
      competing = error.message
    }
    holder.end()
    await holder.done
    if (!/blocked|aggregate-only|not allowed|lock timeout/i.test(competing)) {
      throw new Error(`concurrent posting expected blocked/wait, got ${competing}`)
    }
    console.log("PASS concurrent stock posting versus exclusive attribution lock")
  }

  const flags = await psql(`
    select value::text from public.app_configuration where key = 'stock.lots.dual_write_enabled'
    union all
    select value::text from public.app_configuration where key = 'stock.lots.aggregate_only_blocked';
  `)
  const lines = flags.split(/\r?\n/)
  if (lines[0] !== "false") {
    throw new Error(`dual-write must remain false, got ${flags}`)
  }
} finally {
  await psql(cleanupSql)
}

console.log("M1-S3 concurrency checks passed")
