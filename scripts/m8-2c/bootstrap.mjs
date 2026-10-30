/**
 * M8.2C isolated Branch-1 UAT bootstrap.
 * Default is a dry-run plan. Does not start Docker, flip flags, or write
 * to the development cloud. --start and --seed require M82C_OWNER_APPROVED=1.
 */
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { spawnSync } from "node:child_process"
import {
  ANALYTICS_PORT,
  API_PORT,
  APP_PORT,
  APPROVAL_ENV,
  CLOUD_HOST_FRAGMENT,
  CONTAINER,
  DB_PORT,
  FORBIDDEN_API_PORTS,
  INBUCKET_PORT,
  M81C_SYSID,
  OWNER_SYSID,
  POOLER_PORT,
  PROJECT_ID,
  SHADOW_PORT,
  STUDIO_PORT,
} from "./constants.mjs"

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const rehearsal = resolve(repo, ".rehearsal/m82c")
const rehearsalSupabase = resolve(rehearsal, "supabase")
const args = new Set(process.argv.slice(2))

function approved() {
  return process.env[APPROVAL_ENV] === "1"
}

function fail(message) {
  console.error(`M8.2C bootstrap refused: ${message}`)
  process.exit(1)
}

function printPlan() {
  console.log(`M8.2C isolated UAT plan
Project: ${PROJECT_ID}
API: 127.0.0.1:${API_PORT}
Postgres: 127.0.0.1:${DB_PORT}
App: 127.0.0.1:${APP_PORT}
Container: ${CONTAINER}
Refused sysids: owner ${OWNER_SYSID}, m81c ${M81C_SYSID}
Refused API ports: ${[...FORBIDDEN_API_PORTS].join(", ")}
Cloud host fragment refused: ${CLOUD_HOST_FRAGMENT}

Sequence after owner approval:
  1. node scripts/m8-2c/bootstrap.mjs --write-rehearsal
  2. ${APPROVAL_ENV}=1 node scripts/m8-2c/bootstrap.mjs --start
  3. node scripts/m8-2c/bootstrap.mjs --guards
  4. ${APPROVAL_ENV}=1 node scripts/m8-2c/http-seed.mjs --masters
  5. Review activate-dual-write.sql, then ${APPROVAL_ENV}=1 node scripts/m8-2c/http-seed.mjs --cutover
  6. ${APPROVAL_ENV}=1 node scripts/m8-2c/http-seed.mjs --stock
  7. npx playwright test -c playwright.m82c.config.ts

Default flags on a fresh stack stay false. Dual-write is enabled only in step 5
on this isolated database. damage.stock_hold_ready and aggregate_only_blocked
stay false. SHORT_SHIPMENT_OPERATIONAL stays false in source.
`)
}

function writeRehearsal() {
  mkdirSync(rehearsalSupabase, { recursive: true })
  cpSync(resolve(repo, "supabase/config.toml"), resolve(rehearsalSupabase, "config.toml"))
  cpSync(resolve(repo, "supabase/migrations"), resolve(rehearsalSupabase, "migrations"), {
    recursive: true,
  })
  writeFileSync(
    resolve(rehearsalSupabase, "seed.sql"),
    "-- Isolated M8.2C seed is applied later through guarded scripts.\n",
  )
  let config = readFileSync(resolve(rehearsalSupabase, "config.toml"), "utf8")
  config = config
    .replace('project_id = "sherlyos"', `project_id = "${PROJECT_ID}"`)
    .replace("port = 54321", `port = ${API_PORT}`)
    .replace("port = 54322", `port = ${DB_PORT}`)
    .replace("shadow_port = 54320", `shadow_port = ${SHADOW_PORT}`)
    .replace("port = 54329", `port = ${POOLER_PORT}`)
    .replace("[realtime]\nenabled = true", "[realtime]\nenabled = false")
    .replace("[studio]\nenabled = true", "[studio]\nenabled = false")
    .replace("port = 54323", `port = ${STUDIO_PORT}`)
    .replace("port = 54324", `port = ${INBUCKET_PORT}`)
    .replace("[analytics]\nenabled = true", "[analytics]\nenabled = false")
    .replace("port = 54327", `port = ${ANALYTICS_PORT}`)
    .replace("[db.seed]\nenabled = true", "[db.seed]\nenabled = false")
  writeFileSync(resolve(rehearsalSupabase, "config.toml"), config)
  writeFileSync(
    resolve(repo, ".env.m82c.local"),
    `# Isolated M8.2C. Gitignored. Do not point 5173 at this file.\nVITE_SUPABASE_URL=http://127.0.0.1:${API_PORT}\nVITE_SUPABASE_PUBLISHABLE_KEY=replace-after-supabase-status\n`,
  )
  console.log(`Wrote ${rehearsalSupabase} and .env.m82c.local`)
}

function runGuards() {
  const sql = readFileSync(resolve(repo, "supabase/tests/phase_m8_2c_isolation_guards.sql"), "utf8")
  const result = spawnSync(
    "docker",
    ["exec", "-i", CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1"],
    { input: sql, encoding: "utf8" },
  )
  if (result.status !== 0) {
    fail(result.stderr || result.stdout || "isolation guards failed")
  }
  console.log(result.stdout)
}

function startStack() {
  if (!approved()) fail(`${APPROVAL_ENV}=1 is required before --start`)
  if (!existsSync(resolve(rehearsalSupabase, "config.toml"))) {
    fail("run --write-rehearsal first")
  }
  const result = spawnSync("npx", ["supabase", "start"], {
    cwd: rehearsal,
    shell: true,
    stdio: "inherit",
  })
  if (result.status !== 0) fail("supabase start failed")
}

if (args.size === 0 || args.has("--plan")) printPlan()
if (args.has("--write-rehearsal")) writeRehearsal()
if (args.has("--start")) startStack()
if (args.has("--guards")) runGuards()
