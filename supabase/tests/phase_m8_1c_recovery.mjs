/**
 * M8.1C disposable recovery. Dumps the isolated cluster, restores into a
 * sibling database, and refuses the owner container/sysid. Recovery is restore,
 * not flag-off after lot-ledger activity.
 */
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const CONTAINER = "supabase_db_sherlyos_m81c"
const OWNER_CONTAINER = "supabase_db_sherlyos"
const OWNER_SYSID = "7699785797738577957"
const DUMP_IN_CONTAINER = "/tmp/m81c_post_cutover.dump"
const DUMP_LOCAL = resolve(REPO, ".rehearsal/m81c/post_cutover.dump")
const RECOVERED = "m81c_recovered"

function run(command, args, options = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] })
    let output = ""
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    child.stderr.on("data", (chunk) => {
      output += chunk
    })
    child.on("close", (code) => {
      const text = output.trim()
      if (code === 0) resolvePromise(text)
      else reject(new Error(text || `${command} ${args.join(" ")} exit ${code}`))
    })
  })
}

function psql(database, sql) {
  return run("docker", [
    "exec",
    "-i",
    CONTAINER,
    "psql",
    "-U",
    "postgres",
    "-d",
    database,
    "-v",
    "ON_ERROR_STOP=1",
    "-tA",
    "-c",
    sql,
  ])
}

if (CONTAINER === OWNER_CONTAINER) {
  throw new Error("M8.1C recovery refused the owner container")
}

const name = await run("docker", ["inspect", "-f", "{{.Name}}", CONTAINER])
if (name.replace(/^\//, "") !== CONTAINER) {
  throw new Error(`unexpected container identity ${name}`)
}

const liveSysid = (await psql("postgres", "select system_identifier from pg_control_system()")).trim()
if (liveSysid === OWNER_SYSID) {
  throw new Error("M8.1C recovery refused the owner system identifier")
}

const liveFlags = await psql(
  "postgres",
  `select key || '=' || value::text
   from public.app_configuration
   where key in ('stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked','damage.stock_hold_ready')
   order by 1`,
)
const liveAgg = (await psql("postgres", "select coalesce(sum(quantity),0) from public.stock_balances")).trim()
const liveLot = (
  await psql("postgres", "select coalesce(sum(quantity),0) from public.stock_lot_balances")
).trim()

if (!liveFlags.includes("stock.lots.dual_write_enabled=true")) {
  throw new Error(`checkpoint flags unexpected:\n${liveFlags}`)
}
if (liveAgg !== liveLot) {
  throw new Error(`live mismatch agg=${liveAgg} lot=${liveLot}`)
}

await run("docker", [
  "exec",
  CONTAINER,
  "pg_dump",
  "-U",
  "postgres",
  "-Fc",
  "-d",
  "postgres",
  "-f",
  DUMP_IN_CONTAINER,
])
mkdirSync(resolve(REPO, ".rehearsal/m81c"), { recursive: true })
await run("docker", ["cp", `${CONTAINER}:${DUMP_IN_CONTAINER}`, DUMP_LOCAL])
if (!existsSync(DUMP_LOCAL)) throw new Error("checkpoint dump was not copied locally")
const sha = createHash("sha256").update(readFileSync(DUMP_LOCAL)).digest("hex").toUpperCase()

await psql("postgres", `drop database if exists ${RECOVERED} with (force)`)
await psql("postgres", `create database ${RECOVERED}`)
try {
  await run("docker", [
    "exec",
    CONTAINER,
    "pg_restore",
    "-U",
    "postgres",
    "--no-owner",
    "--role=postgres",
    "-d",
    RECOVERED,
    DUMP_IN_CONTAINER,
  ])
} catch (error) {
  // Custom dumps of a live Supabase catalog often warn on existing roles/comments.
  // Continue only when recovered data is queryable and matches the live checkpoint.
  console.warn(String(error.message).slice(0, 500))
}

const recoveredSysid = (
  await psql(RECOVERED, "select system_identifier from pg_control_system()")
).trim()
if (recoveredSysid === OWNER_SYSID || recoveredSysid !== liveSysid) {
  throw new Error(`recovered sysid ${recoveredSysid} live ${liveSysid}`)
}

const recoveredFlags = await psql(
  RECOVERED,
  `select key || '=' || value::text
   from public.app_configuration
   where key in ('stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked','damage.stock_hold_ready')
   order by 1`,
)
const recoveredAgg = (
  await psql(RECOVERED, "select coalesce(sum(quantity),0) from public.stock_balances")
).trim()
const recoveredLot = (
  await psql(RECOVERED, "select coalesce(sum(quantity),0) from public.stock_lot_balances")
).trim()

if (recoveredFlags !== liveFlags) {
  throw new Error(`recovered flags ${recoveredFlags} live ${liveFlags}`)
}
if (recoveredAgg !== liveAgg || recoveredLot !== liveLot) {
  throw new Error(`recovered qty agg=${recoveredAgg} lot=${recoveredLot} live ${liveAgg}/${liveLot}`)
}

try {
  await psql("postgres", "update public.stock_balances set quantity = 0")
  throw new Error("ledger trigger allowed a quantity wipe")
} catch (error) {
  if (!/balance does not match the ledger/i.test(String(error.message))) throw error
}

try {
  await psql(
    "postgres",
    `update public.app_configuration
       set value = 'false'::jsonb
       where key in ('stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked')`,
  )
  throw new Error("cutover trigger allowed unsafe flag rollback after lot ledger")
} catch (error) {
  if (!/cannot be false while lot inventory or lot-attributed ledger rows exist/i.test(String(error.message))) {
    throw error
  }
}

const afterRejectedRollback = await psql(
  "postgres",
  `select key || '=' || value::text
   from public.app_configuration
   where key in ('stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked','damage.stock_hold_ready')
   order by 1`,
)
if (afterRejectedRollback !== liveFlags) {
  throw new Error(`rejected rollback mutated flags:\n${afterRejectedRollback}`)
}

const afterCorruptRecovered = (
  await psql(RECOVERED, "select coalesce(sum(quantity),0) from public.stock_balances")
).trim()
if (afterCorruptRecovered !== liveAgg) {
  throw new Error("live corruption leaked into recovered database")
}

const restoredAgg = (
  await psql("postgres", "select coalesce(sum(quantity),0) from public.stock_balances")
).trim()
const restoredLot = (
  await psql("postgres", "select coalesce(sum(quantity),0) from public.stock_lot_balances")
).trim()
const restoredFlags = afterRejectedRollback
if (restoredAgg !== liveAgg || restoredLot !== liveLot || restoredFlags !== liveFlags) {
  throw new Error(
    `post-recovery live mismatch agg=${restoredAgg} lot=${restoredLot} flags=${restoredFlags}`,
  )
}

console.log(
  JSON.stringify(
    {
      container: CONTAINER,
      sysid: liveSysid,
      sha256: sha,
      live_before: { agg: liveAgg, lot: liveLot, flags: liveFlags.split(/\r?\n/) },
      recovered: { agg: recoveredAgg, lot: recoveredLot, flags: recoveredFlags.split(/\r?\n/) },
      unsafe_flag_rollback: "rejected by lot-cutover trigger",
      live_after_restore: { agg: restoredAgg, lot: restoredLot, flags: restoredFlags.split(/\r?\n/) },
      dump: DUMP_LOCAL,
    },
    null,
    2,
  ),
)
console.log("M8.1C recovery PASS")
