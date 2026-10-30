/**
 * Local-only M8.2A shop master import.
 * Creates shops with name only. Does not assign salespersons, invent
 * phones/GSTIN/addresses, or write route tables (those do not exist yet).
 * Refuses the cloud API and isolated M8.1C. Default is dry-run.
 *
 * Usage:
 *   node scripts/m8-2a-import-local.mjs
 *   node scripts/m8-2a-import-local.mjs --apply
 */
import { spawn } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { createClient } from "@supabase/supabase-js"
import {
  CATALOGUE_VERSION,
  EXPECTED_ROUTE_AREAS,
  SOURCE_ENTRIES,
  proposedShopKey,
  normalizeShopName,
} from "./m8-2a-shops.mjs"

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..")
const DOCS_DIR = join(ROOT, "data", "imports", "shops")
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
  return [headers.join(","), ...rows.map((row) => headers.map((key) => csvEscape(row[key])).join(","))].join(
    "\n",
  )
}

function writeManifests(plan) {
  mkdirSync(DOCS_DIR, { recursive: true })
  writeFileSync(
    join(DOCS_DIR, "sherlyos_sales_routes.csv"),
    toCsv(
      EXPECTED_ROUTE_AREAS.map((row) => ({
        source_collection: row.sourceCollection,
        source_day: row.sourceDay ?? "",
        route_area: row.routeArea,
        route_name: row.routeArea,
        expected_shop_count: row.expectedCount,
        extracted_shop_count: SOURCE_ENTRIES.filter(
          (entry) => entry.routeArea === row.routeArea && entry.sourceCollection === row.sourceCollection,
        ).length,
      })),
    ),
    "utf8",
  )
  writeFileSync(
    join(DOCS_DIR, "sherlyos_shop_master.csv"),
    toCsv(
      plan.map((row) => ({
        proposed_shop_key: row.proposedShopKey,
        original_shop_name: row.originalShopName,
        normalized_shop_name: row.normalizedShopName,
        source_collection: row.sourceCollection,
        source_day: row.sourceDay ?? "",
        route_area: row.routeArea,
        visit_sequence: row.visitSequence,
        review_status: row.reviewStatus,
        matched_existing_shop_id: row.matchedExistingShopId ?? "",
        review_notes: row.reviewNotes,
      })),
    ) || "proposed_shop_key,original_shop_name,normalized_shop_name,source_collection,source_day,route_area,visit_sequence,review_status,matched_existing_shop_id,review_notes\n",
    "utf8",
  )
  writeFileSync(
    join(DOCS_DIR, "sherlyos_route_shop_memberships.csv"),
    toCsv(
      SOURCE_ENTRIES.map((row) => ({
        source_collection: row.sourceCollection,
        source_day: row.sourceDay ?? "",
        route_area: row.routeArea,
        route_name: row.routeArea,
        visit_sequence: row.visitSequence,
        original_shop_name: row.originalShopName,
        proposed_shop_key: proposedShopKey(row.routeArea, row.originalShopName),
        salesperson_id: "",
      })),
    ) ||
      "source_collection,source_day,route_area,route_name,visit_sequence,original_shop_name,proposed_shop_key,salesperson_id\n",
    "utf8",
  )
  writeFileSync(
    join(DOCS_DIR, "shop_import_review.csv"),
    toCsv(plan.map((row) => ({
      proposed_shop_key: row.proposedShopKey,
      original_shop_name: row.originalShopName,
      review_status: row.reviewStatus,
      review_notes: row.reviewNotes,
    }))) || "proposed_shop_key,original_shop_name,review_status,review_notes\n",
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
      if (code === 0) resolve(stdout.trim())
      else reject(new Error((stdout + stderr).trim() || `${command} exit ${code}`))
    })
    if (input) child.stdin.end(input)
    else child.stdin.end()
  })
}

function psql(sql) {
  return run(
    "docker",
    ["exec", "-i", OWNER_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"],
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

async function snapshot() {
  const json = await psql(`
    select json_build_object(
      'shops', (select count(*) from public.shops),
      'assignments', (select count(*) from public.shop_salesperson_assignments),
      'ledger', (select count(*) from public.stock_ledger),
      'lots', (select count(*) from public.stock_lots),
      'prices', (select count(*) from public.product_selling_prices),
      'invoice_notes', (select count(*) from public.invoice_notes),
      'true_flags', (
        select count(*) from public.app_configuration
        where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked')
          and value = 'true'::jsonb
      )
    );
  `)
  return JSON.parse(json)
}

function classifyEntries(existingByKey) {
  const seen = new Map()
  return SOURCE_ENTRIES.map((entry) => {
    const originalShopName = entry.originalShopName
    const normalizedShopName = normalizeShopName(originalShopName)
    const key = proposedShopKey(entry.routeArea, originalShopName)
    const existing = existingByKey.get(key)
    const first = seen.get(key)
    seen.set(key, (first ?? 0) + 1)
    let reviewStatus = "PROPOSED_NEW"
    let reviewNotes = "Eligible for create_shop(name, null, null) after owner authorization."
    if (!normalizedShopName) {
      reviewStatus = "UNRESOLVED"
      reviewNotes = "Empty shop name after normalize."
    } else if (existing) {
      reviewStatus = "EXISTING_MATCH"
      reviewNotes = "Same area and normalized name already exists. Do not create a second shop."
    } else if ((first ?? 0) > 0) {
      reviewStatus = "ROUTE_MEMBERSHIP_ONLY"
      reviewNotes = "Same shop appears again on this key; keep one shop record and extra route membership."
    }
    return {
      ...entry,
      originalShopName,
      normalizedShopName,
      proposedShopKey: key,
      matchedExistingShopId: existing?.id ?? null,
      reviewStatus,
      reviewNotes,
    }
  })
}

async function main() {
  const env = await statusEnv()
  if ((env.API_URL || LOCAL_API) !== LOCAL_API) {
    throw new Error(`refused API ${env.API_URL}`)
  }
  const before = await snapshot()
  if (before.true_flags !== 0) throw new Error("operational flags must stay false")

  const existingRows = JSON.parse(
    await psql(`
      select coalesce(json_agg(json_build_object('id', id, 'name', name)), '[]'::json)
      from public.shops;
    `),
  )
  const existingByKey = new Map()
  for (const row of existingRows) {
    existingByKey.set(proposedShopKey("unscoped", row.name), row)
  }

  const plan = classifyEntries(existingByKey)
  writeManifests(plan)

  const report = {
    version: CATALOGUE_VERSION,
    mode: APPLY ? "apply" : "dry-run",
    ownerDatabaseModified: false,
    sourceEntries: SOURCE_ENTRIES.length,
    expectedSourceEntries: EXPECTED_ROUTE_AREAS.reduce((sum, row) => sum + row.expectedCount, 0),
    uniqueProposedShops: new Set(plan.map((row) => row.proposedShopKey)).size,
    proposedNew: plan.filter((row) => row.reviewStatus === "PROPOSED_NEW").length,
    existingMatches: plan.filter((row) => row.reviewStatus === "EXISTING_MATCH").length,
    unresolved: plan.filter((row) => row.reviewStatus === "UNRESOLVED").length,
    missingMandatoryFields: SOURCE_ENTRIES.length === 0 ? ["original_shop_name from screenshots"] : [],
    unresolvedBranchMappings: ["shops have no branch_id; order capture still needs a godown at order time"],
    salespersonAssignments: 0,
    before,
  }
  writeFileSync(join(DOCS_DIR, "dry-run-report.json"), JSON.stringify(report, null, 2), "utf8")

  if (SOURCE_ENTRIES.length === 0) {
    console.log("M8.2A dry-run: 0 extracted shops. Place the four screenshots in data/imports/shops/source/.")
    return
  }
  if (!APPLY) {
    console.log(`M8.2A dry-run: ${report.proposedNew} proposed new / ${report.existingMatches} reuse / ${report.unresolved} unresolved`)
    return
  }
  throw new Error("apply is refused until source extraction is complete and the owner authorizes local writes")
}

main().catch((error) => {
  console.error(error.message || error)
  process.exit(1)
})
