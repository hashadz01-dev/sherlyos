/**
 * Local-only M7.8 vehicle import.
 *
 * Uses create_vehicle as an authenticated admin when a row is eligible.
 * Refuses the cloud API and the isolated M8.1C container.
 * Default is dry-run. Shared fleet: no home godown. Type is stored as
 * other because Vehicle.docx did not classify truck/van. Bolero is
 * created then deactivated.
 *
 * Usage:
 *   node scripts/m7-8-import-local.mjs
 *   node scripts/m7-8-import-local.mjs --apply
 */
import { spawn } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { createClient } from "@supabase/supabase-js"
import {
  CATALOGUE_VERSION,
  VEHICLES,
  insertableVehicles,
} from "./m7-8-vehicles.mjs"

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..")
const DOCS_DIR = join(ROOT, "docs", "m7-8")
const OWNER_CONTAINER = "supabase_db_sherlyos"
const LOCAL_API = "http://127.0.0.1:54321"
const ADMIN_EMAIL = "admin.m1s2qa@example.com"
const ADMIN_PASSWORD = "local-only-m1s2qa"
const APPLY = process.argv.includes("--apply")

function csvEscape(value) {
  const text = value == null ? "" : String(value)
  if (/[",\n]/.test(text)) return `"${text.replaceAll('"', '""')}"`
  return text
}

function toCsv(rows) {
  if (rows.length === 0) return ""
  const headers = Object.keys(rows[0])
  return [
    headers.join(","),
    ...rows.map((row) => headers.map((key) => csvEscape(row[key])).join(",")),
  ].join("\n")
}

function writeManifests() {
  mkdirSync(DOCS_DIR, { recursive: true })
  writeFileSync(
    join(DOCS_DIR, "vehicles.csv"),
    toCsv(
      VEHICLES.map((row) => ({
        ref: row.ref,
        display_name: row.displayName,
        registration_number: row.registrationNumber,
        registration_normalized: row.registrationNormalized,
        optional: row.optional ? "yes" : "no",
        branch_id: row.branchId ?? "",
        vehicle_type: row.vehicleType ?? "",
        capacity_cases: row.capacityCases ?? "",
        disposition: row.disposition,
        review_flags: row.reviewFlags.join("|"),
        notes: row.notes,
      })),
    ),
    "utf8",
  )
}

function run(command, args, input, useShell = false) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"], shell: useShell })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (chunk) => {
      stdout += chunk
    })
    child.stderr.on("data", (chunk) => {
      stderr += chunk
    })
    child.on("close", (code) => {
      const text = (stdout + stderr).trim()
      if (code === 0) resolve(stdout.trim())
      else reject(new Error(text || `${command} exit ${code}`))
    })
    if (input) child.stdin.end(input)
    else child.stdin.end()
  })
}

function psql(sql) {
  return run(
    "docker",
    [
      "exec",
      "-i",
      OWNER_CONTAINER,
      "psql",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
      "-tA",
    ],
    sql,
  )
}

async function statusEnv() {
  const output = await run("npx", ["supabase", "status", "-o", "env"], undefined, true)
  const env = {}
  for (const line of output.split(/\r?\n/)) {
    const cut = line.indexOf("=")
    if (cut < 1) continue
    env[line.slice(0, cut)] = line.slice(cut + 1).replace(/^"|"$/g, "")
  }
  return env
}

async function rpc(client, name, args = {}) {
  const result = await client.rpc(name, args)
  if (result.error) {
    const error = new Error(result.error.message)
    error.code = result.error.code
    throw error
  }
  return result.data
}

async function snapshot() {
  const row = await psql(`
    select json_build_object(
      'vehicles', (select count(*) from public.vehicles),
      'active_vehicles', (select count(*) from public.vehicles where is_active),
      'dispatch_with_vehicle', (select count(*) from public.stock_dispatch_requests where vehicle_id is not null),
      'assignments', (select count(*) from public.stock_dispatch_assignments),
      'ledger', (select count(*) from public.stock_ledger),
      'balances', (select count(*) from public.stock_balances),
      'lots', (select count(*) from public.stock_lots),
      'prices', (select count(*) from public.product_selling_prices),
      'invoice_notes', (select count(*) from public.invoice_notes),
      'true_flags', (
        select count(*) from public.app_configuration
        where key in (
          'damage.stock_hold_ready',
          'stock.lots.dual_write_enabled',
          'stock.lots.aggregate_only_blocked'
        ) and value = 'true'::jsonb
      )
    );
  `)
  return JSON.parse(row)
}

async function assertLocalGuard() {
  const names = await run("docker", ["ps", "--format", "{{.Names}}"])
  if (!names.split(/\r?\n/).includes(OWNER_CONTAINER)) {
    throw new Error(`M7.8 requires running container ${OWNER_CONTAINER}`)
  }
  const isolated = await run("docker", ["inspect", "-f", "{{.Name}}", OWNER_CONTAINER])
  if (isolated.includes("m81c")) {
    throw new Error("M7.8 refused the isolated M8.1C database")
  }
  const env = await statusEnv()
  const api = env.API_URL || LOCAL_API
  if (api !== LOCAL_API) {
    throw new Error(`M7.8 refused API ${api}; expected ${LOCAL_API}`)
  }
  const flags = await snapshot()
  if (flags.true_flags !== 0) {
    throw new Error(`operational flags must stay false: ${JSON.stringify(flags)}`)
  }
  return env
}

function classifyVehicle(existingByNormalized, vehicle) {
  const hit = existingByNormalized.get(vehicle.registrationNormalized)
  if (hit) {
    const sameName = hit.display_name === vehicle.displayName
    if (sameName) {
      return {
        outcome: "ALREADY_EXISTS",
        ref: vehicle.ref,
        registrationNumber: vehicle.registrationNumber,
        id: hit.id,
        reason: "Normalized registration already present.",
      }
    }
    return {
      outcome: "CONFLICT_REQUIRES_REVIEW",
      ref: vehicle.ref,
      registrationNumber: vehicle.registrationNumber,
      existingName: hit.display_name,
      reason: "Normalized registration exists under a different display name.",
    }
  }
  if (vehicle.disposition !== "INSERT" || !vehicle.vehicleType) {
    return {
      outcome: "SKIPPED_PENDING_VERIFICATION",
      ref: vehicle.ref,
      displayName: vehicle.displayName,
      registrationNumber: vehicle.registrationNumber,
      reason: vehicle.notes,
    }
  }
  return {
    outcome: "CREATED",
    ref: vehicle.ref,
    displayName: vehicle.displayName,
    registrationNumber: vehicle.registrationNumber,
    branchId: vehicle.branchId,
    vehicleType: vehicle.vehicleType,
    deactivateAfterCreate: Boolean(vehicle.optional),
  }
}

async function main() {
  writeManifests()
  const env = await assertLocalGuard()
  const before = await snapshot()
  const existing = JSON.parse(
    await psql(`
      select coalesce(json_agg(json_build_object(
        'id', id,
        'display_name', display_name,
        'registration_number', registration_number,
        'registration_normalized', registration_normalized,
        'branch_id', branch_id,
        'is_active', is_active
      )), '[]'::json)
      from public.vehicles;
    `),
  )
  const existingByNormalized = new Map(
    existing.map((row) => [row.registration_normalized, row]),
  )
  const plan = VEHICLES.map((row) => classifyVehicle(existingByNormalized, row))

  if (!APPLY) {
    const report = {
      version: CATALOGUE_VERSION,
      mode: "dry-run",
      ownerDatabaseModified: false,
      before,
      vehicles: plan,
      insertable: insertableVehicles().length,
      staged: VEHICLES.length - insertableVehicles().length,
    }
    writeFileSync(join(DOCS_DIR, "dry-run-report.json"), JSON.stringify(report, null, 2), "utf8")
    console.log(
      `M7.8 dry-run: create ${plan.filter((r) => r.outcome === "CREATED").length} / reuse ${plan.filter((r) => r.outcome === "ALREADY_EXISTS").length} / staged ${plan.filter((r) => r.outcome === "SKIPPED_PENDING_VERIFICATION").length} / conflict ${plan.filter((r) => r.outcome === "CONFLICT_REQUIRES_REVIEW").length}`,
    )
    console.log("Wrote docs/m7-8/vehicles.csv and docs/m7-8/dry-run-report.json. Re-run with --apply to create the shared fleet.")
    return
  }

  if (!env.ANON_KEY) throw new Error("local anon key missing")
  const auth = createClient(LOCAL_API, env.ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const session = await auth.auth.signInWithPassword({
    email: ADMIN_EMAIL,
    password: ADMIN_PASSWORD,
  })
  if (session.error || !session.data.session) {
    throw new Error(session.error?.message ?? "local admin sign-in failed")
  }
  const client = createClient(LOCAL_API, env.ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${session.data.session.access_token}` } },
  })

  const results = []
  for (const vehicle of VEHICLES) {
    const planned = classifyVehicle(existingByNormalized, vehicle)
    if (planned.outcome !== "CREATED") {
      results.push(planned)
      continue
    }
    const id = await rpc(client, "create_vehicle", {
      target_branch: vehicle.branchId,
      registration_number: vehicle.registrationNumber,
      vehicle_type: vehicle.vehicleType,
      display_name: vehicle.displayName,
      capacity_cases: vehicle.capacityCases,
      operational_notes: vehicle.notes || null,
    })
    if (vehicle.optional) {
      await rpc(client, "set_vehicle_active", { target_vehicle: id, active: false })
    }
    existingByNormalized.set(vehicle.registrationNormalized, {
      id,
      display_name: vehicle.displayName,
      registration_normalized: vehicle.registrationNormalized,
    })
    results.push({ ...planned, id, inactive: Boolean(vehicle.optional) })
  }

  const after = await snapshot()
  if (
    after.dispatch_with_vehicle !== before.dispatch_with_vehicle ||
    after.assignments !== before.assignments ||
    after.ledger !== before.ledger ||
    after.balances !== before.balances ||
    after.lots !== before.lots ||
    after.prices !== before.prices ||
    after.invoice_notes !== before.invoice_notes ||
    after.true_flags !== 0
  ) {
    throw new Error(
      `integrity drift after import: before=${JSON.stringify(before)} after=${JSON.stringify(after)}`,
    )
  }

  const report = {
    version: CATALOGUE_VERSION,
    mode: "apply",
    ownerDatabaseModified: false,
    localContainer: OWNER_CONTAINER,
    before,
    after,
    vehicles: results,
  }
  writeFileSync(join(DOCS_DIR, "local-apply-report.json"), JSON.stringify(report, null, 2), "utf8")
  console.log(
    `M7.8 applied locally. vehicles ${before.vehicles} -> ${after.vehicles}. Delivery assignments/stock/flags unchanged.`,
  )
}

main().catch((error) => {
  console.error(error.message || error)
  process.exit(1)
})
