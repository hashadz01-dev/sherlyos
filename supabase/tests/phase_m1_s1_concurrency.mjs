/**
 * M1-S1.1 two-session cutover lock proofs.
 * Uses the local Docker database. Every mutating session rolls back.
 * Does not leave dual-write enabled or seed working inventory.
 */
import { spawn } from "node:child_process"

const LOCK_KEY = "88104301, 1"
const HOLD_MS = 2500
const WAIT_SLACK_MS = 1800

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
    outputIncludes: (marker) => output.includes(marker),
    getOutput: () => output,
  }
}

await assertFlagsUnchanged()

// ---------------------------------------------------------------------------
// 0) Advisory incompatibility (shared try-lock while exclusive is held)
// ---------------------------------------------------------------------------
{
  const holder = holdWithMarker(`
begin;
select pg_advisory_xact_lock(${LOCK_KEY});
select 'LOCKED';
select pg_sleep(${HOLD_MS / 1000.0});
commit;
select 'RELEASED';
`)
  await sleep(400)
  const during = await psql(`select pg_try_advisory_lock_shared(${LOCK_KEY});`)
  if (during !== "f") {
    holder.end()
    throw new Error(`expected shared try-lock to fail while exclusive held, got ${during}`)
  }
  await psql(`select pg_advisory_unlock_shared(${LOCK_KEY});`)
  holder.end()
  await holder.done
  const after = await psql(`select pg_try_advisory_lock_shared(${LOCK_KEY});`)
  if (after !== "t") {
    throw new Error(`expected shared try-lock to succeed after exclusive released, got ${after}`)
  }
  await psql(`select pg_advisory_unlock_shared(${LOCK_KEY});`)
  console.log("PASS 0 exclusive blocks shared try-lock")
}

// ---------------------------------------------------------------------------
// 1) Flag transition waits for an active stock writer (shared lock)
// ---------------------------------------------------------------------------
{
  const holder = holdWithMarker(`
begin;
select app_private.acquire_stock_cutover_shared_lock();
select 'WRITER_LOCKED';
select pg_sleep(${HOLD_MS / 1000.0});
rollback;
`)
  const startedWait = Date.now()
  while (!holder.outputIncludes("WRITER_LOCKED") && Date.now() - startedWait < 5000) {
    await sleep(50)
  }
  if (!holder.outputIncludes("WRITER_LOCKED")) {
    holder.end()
    throw new Error(`writer never acquired shared lock: ${holder.getOutput()}`)
  }

  const t0 = Date.now()
  let err = ""
  try {
    await psql(`
begin;
set local lock_timeout = '8s';
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';
rollback;
`)
  } catch (caught) {
    err = String(caught.message || caught)
  }
  const elapsed = Date.now() - t0
  holder.end()
  await holder.done

  if (elapsed < WAIT_SLACK_MS) {
    throw new Error(`flag UPDATE did not wait for writer (${elapsed}ms) err=${err}`)
  }
  if (!/55000|requires stock.lots.aggregate_only_blocked/i.test(err)) {
    throw new Error(`flag UPDATE after writer wait should fail Rule A, got: ${err || "no error"}`)
  }
  await assertFlagsUnchanged()
  console.log(`PASS 1 flag waits for writer (${elapsed}ms)`)
}

// ---------------------------------------------------------------------------
// 2) Stock writer waits for an active flag transition (exclusive lock)
// ---------------------------------------------------------------------------
{
  const holder = holdWithMarker(`
begin;
select app_private.lot_seed_lock_exclusive();
select 'FLAG_LOCKED';
select pg_sleep(${HOLD_MS / 1000.0});
rollback;
`)
  const startedWait = Date.now()
  while (!holder.outputIncludes("FLAG_LOCKED") && Date.now() - startedWait < 5000) {
    await sleep(50)
  }
  if (!holder.outputIncludes("FLAG_LOCKED")) {
    holder.end()
    throw new Error(`flag holder never acquired exclusive lock: ${holder.getOutput()}`)
  }

  const t0 = Date.now()
  await psql(`
begin;
set local lock_timeout = '8s';
select app_private.acquire_stock_cutover_shared_lock();
select 'WRITER_ACQUIRED';
rollback;
`)
  const elapsed = Date.now() - t0
  holder.end()
  await holder.done
  if (elapsed < WAIT_SLACK_MS) {
    throw new Error(`writer did not wait for flag transition (${elapsed}ms)`)
  }
  console.log(`PASS 2 writer waits for flag (${elapsed}ms)`)
}

// ---------------------------------------------------------------------------
// 3) Reconciliation snapshot: writer cannot mutate balances while validate holds
//    exclusive + FOR UPDATE on stock_balances
// ---------------------------------------------------------------------------
{
  const holder = holdWithMarker(`
begin;
select app_private.lot_seed_lock_exclusive();
select 1 from public.stock_balances
order by crate_id, product_id
for update;
select 'BALANCES_LOCKED';
select pg_sleep(${HOLD_MS / 1000.0});
rollback;
`)
  const startedWait = Date.now()
  while (!holder.outputIncludes("BALANCES_LOCKED") && Date.now() - startedWait < 8000) {
    await sleep(50)
  }
  if (!holder.outputIncludes("BALANCES_LOCKED")) {
    holder.end()
    throw new Error(`validate-style lock never acquired: ${holder.getOutput()}`)
  }

  const grain = await psql(`
    select crate_id::text || ',' || product_id::text
    from public.stock_balances
    where quantity > 0
    limit 1;
  `)
  if (!grain || !grain.includes(",")) {
    holder.end()
    await holder.done.catch(() => undefined)
    throw new Error("need a positive stock_balances grain for reconciliation wait proof")
  }
  const [crateId, productId] = grain.split(",")

  const t0 = Date.now()
  await psql(`
begin;
set local lock_timeout = '8s';
select 1
from public.stock_balances
where crate_id = '${crateId}'::uuid
  and product_id = '${productId}'::uuid
for update;
rollback;
`)
  const elapsed = Date.now() - t0
  holder.end()
  await holder.done
  if (elapsed < WAIT_SLACK_MS) {
    throw new Error(`apply_stock_delta did not wait for reconciliation locks (${elapsed}ms)`)
  }
  await assertFlagsUnchanged()
  console.log(`PASS 3 balance FOR UPDATE waits during validation snapshot (${elapsed}ms)`)
}

// ---------------------------------------------------------------------------
// 4) Concurrent seed and flag transition: both take exclusive; second waits
// ---------------------------------------------------------------------------
{
  const holder = holdWithMarker(`
begin;
select app_private.lot_seed_lock_exclusive();
select 'SEED_LOCKED';
select pg_sleep(${HOLD_MS / 1000.0});
rollback;
`)
  const startedWait = Date.now()
  while (!holder.outputIncludes("SEED_LOCKED") && Date.now() - startedWait < 5000) {
    await sleep(50)
  }
  if (!holder.outputIncludes("SEED_LOCKED")) {
    holder.end()
    throw new Error(`seed lock never acquired: ${holder.getOutput()}`)
  }

  const t0 = Date.now()
  let err = ""
  try {
    await psql(`
begin;
set local lock_timeout = '8s';
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';
rollback;
`)
  } catch (caught) {
    err = String(caught.message || caught)
  }
  const elapsed = Date.now() - t0
  holder.end()
  await holder.done
  if (elapsed < WAIT_SLACK_MS) {
    throw new Error(`flag UPDATE did not wait for seed exclusive (${elapsed}ms)`)
  }
  if (!/55000|requires stock.lots.aggregate_only_blocked/i.test(err)) {
    throw new Error(`flag UPDATE after seed wait should fail Rule A, got: ${err || "no error"}`)
  }
  console.log(`PASS 4 flag waits for seed exclusive (${elapsed}ms)`)
}

// ---------------------------------------------------------------------------
// 5) Failed flag transition leaves configuration unchanged
// ---------------------------------------------------------------------------
{
  let err = ""
  try {
    await psql(`
begin;
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';
rollback;
`)
  } catch (caught) {
    err = String(caught.message || caught)
  }
  if (!/55000|requires stock.lots.aggregate_only_blocked/i.test(err)) {
    throw new Error(`expected failed dual-write enable, got: ${err || "no error"}`)
  }
  await assertFlagsUnchanged()
  console.log("PASS 5 failed flag transition leaves flags unchanged")
}

// ---------------------------------------------------------------------------
// 6) Supported posting lock order vs flag exclusive: no deadlock (40P01)
// ---------------------------------------------------------------------------
{
  const writerThenFlag = (async () => {
    const holder = holdWithMarker(`
begin;
select app_private.acquire_stock_cutover_shared_lock();
select 1 from public.stock_balances order by crate_id, product_id for update;
select 'ORDER_A';
select pg_sleep(1.2);
rollback;
`)
    const startedWait = Date.now()
    while (!holder.outputIncludes("ORDER_A") && Date.now() - startedWait < 5000) {
      await sleep(50)
    }
    try {
      await psql(`
begin;
set local lock_timeout = '8s';
select app_private.lot_seed_lock_exclusive();
rollback;
`)
    } finally {
      holder.end()
      await holder.done
    }
  })()

  await writerThenFlag

  const flagThenWriter = (async () => {
    const holder = holdWithMarker(`
begin;
select app_private.lot_seed_lock_exclusive();
select 1 from public.stock_balances order by crate_id, product_id for update;
select 'ORDER_B';
select pg_sleep(1.2);
rollback;
`)
    const startedWait = Date.now()
    while (!holder.outputIncludes("ORDER_B") && Date.now() - startedWait < 8000) {
      await sleep(50)
    }
    try {
      await psql(`
begin;
set local lock_timeout = '8s';
select app_private.acquire_stock_cutover_shared_lock();
rollback;
`)
    } finally {
      holder.end()
      await holder.done
    }
  })()

  await flagThenWriter
  await assertFlagsUnchanged()
  console.log("PASS 6 no deadlock in writer-then-flag and flag-then-writer")
}

await assertFlagsUnchanged()
console.log("PASS phase_m1_s1_concurrency")
