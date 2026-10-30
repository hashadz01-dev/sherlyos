/**
 * Local-only M7.7 catalogue import.
 *
 * Uses create_product_category, create_supplier, set_supplier_active,
 * create_product, and set_product_billing_conversion as an authenticated admin.
 * Refuses the cloud API and the isolated M8.1C container.
 *
 * Usage:
 *   node scripts/m7-7-import-local.mjs
 *   node scripts/m7-7-import-local.mjs --apply
 */
import { spawn } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { createClient } from "@supabase/supabase-js"
import {
  CATEGORIES,
  CATALOGUE_VERSION,
  PRODUCTS,
  SUPPLIERS,
  insertableProducts,
} from "./m7-7-catalog.mjs"

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..")
const DOCS_DIR = join(ROOT, "docs", "m7-7")
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
    join(DOCS_DIR, "categories.csv"),
    toCsv(CATEGORIES.map((row) => ({ code: row.code, name: row.name, description: row.description }))),
    "utf8",
  )
  writeFileSync(
    join(DOCS_DIR, "suppliers.csv"),
    toCsv(
      SUPPLIERS.map((row) => ({
        ref: row.ref,
        name: row.name,
        brands: row.brands,
        verification: row.verification,
        phone: row.phone ?? "",
        email: row.email ?? "",
        intended_status: "inactive",
      })),
    ),
    "utf8",
  )
  writeFileSync(
    join(DOCS_DIR, "products.csv"),
    toCsv(
      PRODUCTS.map((row) => ({
        sku: row.sku ?? "",
        name: row.name,
        category_code: row.categoryCode,
        supplier_ref: row.supplierRef,
        brand: row.brand,
        pack_size: row.packSize,
        packaging_type: row.packagingType,
        units_per_case: row.unitsPerCase ?? "",
        billing_unit: row.billingUnit ?? "",
        source_class: row.sourceClass,
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
  return run("docker", [
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
  ], sql)
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

function firstUuid(text) {
  const match = String(text).match(/[0-9a-f-]{36}/i)
  return match ? match[0] : null
}

async function snapshot() {
  const row = await psql(`
    select json_build_object(
      'products', (select count(*) from public.products),
      'categories', (select count(*) from public.product_categories),
      'suppliers', (select count(*) from public.suppliers),
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

async function assertLocalGuard(env) {
  const api = env.API_URL || LOCAL_API
  if (api !== LOCAL_API) {
    throw new Error(`M7.7 refused API ${api}; expected ${LOCAL_API}`)
  }
  const names = await run("docker", ["ps", "--format", "{{.Names}}"])
  if (!names.split(/\r?\n/).includes(OWNER_CONTAINER)) {
    throw new Error(`M7.7 requires running container ${OWNER_CONTAINER}`)
  }
  const isolated = await run("docker", [
    "inspect",
    "-f",
    "{{.Name}}",
    OWNER_CONTAINER,
  ])
  if (isolated.includes("m81c")) {
    throw new Error("M7.7 refused the isolated M8.1C database")
  }
  const flags = await snapshot()
  if (flags.true_flags !== 0) {
    throw new Error(`operational flags must stay false: ${JSON.stringify(flags)}`)
  }
}

async function ensureLocalAdmin() {
  const existing = firstUuid(
    await psql(`select id from auth.users where email = '${ADMIN_EMAIL}'`),
  )
  if (existing) return existing
  const created = await psql(`
    with created as (
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      values (
        '00000000-0000-0000-0000-000000000000',
        gen_random_uuid(),
        'authenticated',
        'authenticated',
        '${ADMIN_EMAIL}',
        extensions.crypt('${ADMIN_PASSWORD}', extensions.gen_salt('bf')),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('full_name', 'QA Admin'),
        now(),
        now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      )
      returning id, email
    ),
    ident as (
      insert into auth.identities (
        id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
      )
      select
        gen_random_uuid(),
        created.id,
        jsonb_build_object('sub', created.id::text, 'email', created.email),
        'email',
        created.id::text,
        now(),
        now(),
        now()
      from created
      returning user_id
    )
    select user_id from ident;
  `)
  const id = firstUuid(created)
  if (!id) throw new Error("failed to create local QA admin")
  await psql(`
    insert into public.profiles (id, full_name, is_active)
    values ('${id}'::uuid, 'QA Admin', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select '${id}'::uuid, roles.id, '${id}'::uuid
    from public.roles
    where roles.code = 'admin'
    on conflict do nothing;
  `)
  return id
}

function classifyCategory(existingNameMap, category) {
  const hit = existingNameMap.get(category.name.toLowerCase())
  if (!hit) return { outcome: "CREATED", name: category.name }
  return { outcome: "ALREADY_EXISTS", name: category.name, id: hit.id }
}

function classifySupplier(existingNameMap, supplier) {
  const hit = existingNameMap.get(supplier.name.toLowerCase())
  if (!hit) return { outcome: "CREATED", name: supplier.name }
  if (hit.is_active) {
    return {
      outcome: "CONFLICT_REQUIRES_REVIEW",
      name: supplier.name,
      id: hit.id,
      reason: "Pending invoicing supplier already exists and is active.",
    }
  }
  return { outcome: "ALREADY_EXISTS", name: supplier.name, id: hit.id }
}

function classifyProduct(existingSkuMap, product, categoryId) {
  if (product.disposition !== "INSERT") {
    return {
      outcome: "SKIPPED_PENDING_VERIFICATION",
      sku: product.sku,
      name: product.name,
      reason: product.notes || "Staged; missing case pack, stockist confirmation, or supplier confirmation.",
    }
  }
  const hit = existingSkuMap.get(product.sku.toLowerCase())
  if (!hit) {
    return {
      outcome: "CREATED",
      sku: product.sku,
      name: product.name,
      categoryId,
      billedUnitsPerCase: product.unitsPerCase,
      billingUnit: product.billingUnit,
    }
  }
  const sameName = hit.name === product.name
  const sameCategory = (hit.category_id ?? null) === (categoryId ?? null)
  if (sameName && sameCategory) {
    return { outcome: "ALREADY_EXISTS", sku: product.sku, id: hit.id, name: product.name }
  }
  return {
    outcome: "CONFLICT_REQUIRES_REVIEW",
    sku: product.sku,
    name: product.name,
    existingName: hit.name,
    reason: "SKU exists with a different name or category.",
  }
}

async function loadExisting() {
  const categories = JSON.parse(
    await psql(`select coalesce(json_agg(json_build_object('id', id, 'name', name, 'is_active', is_active)), '[]'::json) from public.product_categories;`),
  )
  const suppliers = JSON.parse(
    await psql(`select coalesce(json_agg(json_build_object('id', id, 'name', name, 'is_active', is_active)), '[]'::json) from public.suppliers;`),
  )
  const products = JSON.parse(
    await psql(`select coalesce(json_agg(json_build_object('id', id, 'sku', sku, 'name', name, 'category_id', category_id, 'supplier_id', supplier_id, 'billing_unit', billing_unit, 'billed_units_per_case', billed_units_per_case)), '[]'::json) from public.products;`),
  )
  return { categories, suppliers, products }
}

async function main() {
  writeManifests()
  const env = await statusEnv()
  await assertLocalGuard(env)
  const before = await snapshot()
  const existing = await loadExisting()
  const categoryByName = new Map(existing.categories.map((row) => [row.name.toLowerCase(), row]))
  const supplierByName = new Map(existing.suppliers.map((row) => [row.name.toLowerCase(), row]))
  const productBySku = new Map(existing.products.map((row) => [row.sku.toLowerCase(), row]))

  const categoryPlan = CATEGORIES.map((row) => classifyCategory(categoryByName, row))
  const supplierPlan = SUPPLIERS.map((row) => classifySupplier(supplierByName, row))
  const plannedCategoryIds = new Map(
    CATEGORIES.map((row) => [row.code, categoryByName.get(row.name.toLowerCase())?.id ?? null]),
  )
  const productPlan = PRODUCTS.map((row) =>
    classifyProduct(productBySku, row, plannedCategoryIds.get(row.categoryCode) ?? null),
  )

  if (!APPLY) {
    const report = {
      version: CATALOGUE_VERSION,
      mode: "dry-run",
      ownerDatabaseModified: false,
      before,
      categories: categoryPlan,
      suppliers: supplierPlan,
      products: productPlan,
      insertable: insertableProducts().length,
      staged: PRODUCTS.filter((row) => row.disposition === "STAGE").length,
    }
    writeFileSync(join(DOCS_DIR, "dry-run-report.json"), JSON.stringify(report, null, 2), "utf8")
    console.log(`M7.7 dry-run: categories ${categoryPlan.filter((r) => r.outcome === "CREATED").length} create / ${categoryPlan.filter((r) => r.outcome === "ALREADY_EXISTS").length} reuse`)
    console.log(`M7.7 dry-run: suppliers ${supplierPlan.filter((r) => r.outcome === "CREATED").length} create / ${supplierPlan.filter((r) => r.outcome === "CONFLICT_REQUIRES_REVIEW").length} conflict`)
    console.log(`M7.7 dry-run: products ${productPlan.filter((r) => r.outcome === "CREATED").length} create / ${productPlan.filter((r) => r.outcome === "SKIPPED_PENDING_VERIFICATION").length} staged / ${productPlan.filter((r) => r.outcome === "CONFLICT_REQUIRES_REVIEW").length} conflict`)
    console.log("Wrote docs/m7-7/*.csv and docs/m7-7/dry-run-report.json. Re-run with --apply to write local rows.")
    return
  }

  if (!env.ANON_KEY) throw new Error("local anon key missing")
  const envLocalPath = join(ROOT, ".env.m1s2.local")
  writeFileSync(
    envLocalPath,
    [
      "# LOCAL-ONLY Vite mode. Loaded with: npm run dev:local / Playwright --mode m1s2",
      "# Does not replace .env cloud configuration. No service_role key.",
      "VITE_SUPABASE_URL=http://127.0.0.1:54321",
      `VITE_SUPABASE_PUBLISHABLE_KEY=${env.ANON_KEY}`,
      "",
    ].join("\n"),
    "utf8",
  )
  await ensureLocalAdmin()
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

  const categoryIds = new Map()
  const categoryResults = []
  for (const category of CATEGORIES) {
    const planned = classifyCategory(categoryByName, category)
    if (planned.outcome === "ALREADY_EXISTS") {
      categoryIds.set(category.code, planned.id)
      categoryResults.push(planned)
      continue
    }
    const id = await rpc(client, "create_product_category", {
      category_name: category.name,
      category_description: category.description,
    })
    categoryIds.set(category.code, id)
    categoryByName.set(category.name.toLowerCase(), { id, name: category.name, is_active: true })
    categoryResults.push({ ...planned, id })
  }

  const supplierResults = []
  for (const supplier of SUPPLIERS) {
    const planned = classifySupplier(supplierByName, supplier)
    if (planned.outcome === "ALREADY_EXISTS" || planned.outcome === "CONFLICT_REQUIRES_REVIEW") {
      supplierResults.push(planned)
      continue
    }
    const id = await rpc(client, "create_supplier", {
      supplier_name: supplier.name,
      supplier_phone: supplier.phone,
      supplier_email: supplier.email,
    })
    await rpc(client, "set_supplier_active", { target_supplier: id, active: false })
    supplierByName.set(supplier.name.toLowerCase(), { id, name: supplier.name, is_active: false })
    supplierResults.push({ ...planned, id })
  }

  const productResults = []
  for (const product of PRODUCTS) {
    const categoryId = categoryIds.get(product.categoryCode) ?? null
    const planned = classifyProduct(productBySku, product, categoryId)
    if (planned.outcome !== "CREATED") {
      productResults.push(planned)
      continue
    }
    const id = await rpc(client, "create_product", {
      product_sku: product.sku,
      product_name: product.name,
      next_supplier: null,
      next_category: categoryId,
    })
    await rpc(client, "set_product_billing_conversion", {
      p_product_id: id,
      p_billing_unit: product.billingUnit,
      p_billed_units_per_case: product.unitsPerCase,
    })
    productBySku.set(product.sku.toLowerCase(), {
      id,
      sku: product.sku,
      name: product.name,
      category_id: categoryId,
      supplier_id: null,
    })
    productResults.push({ ...planned, id })
  }

  const after = await snapshot()
  if (
    after.ledger !== before.ledger ||
    after.balances !== before.balances ||
    after.lots !== before.lots ||
    after.prices !== before.prices ||
    after.invoice_notes !== before.invoice_notes ||
    after.true_flags !== 0
  ) {
    throw new Error(`integrity drift after import: before=${JSON.stringify(before)} after=${JSON.stringify(after)}`)
  }

  const report = {
    version: CATALOGUE_VERSION,
    mode: "apply",
    ownerDatabaseModified: false,
    localContainer: OWNER_CONTAINER,
    before,
    after,
    categories: categoryResults,
    suppliers: supplierResults,
    products: productResults,
  }
  writeFileSync(join(DOCS_DIR, "local-apply-report.json"), JSON.stringify(report, null, 2), "utf8")
  console.log(`M7.7 applied locally. products ${before.products} -> ${after.products}. Stock/prices/flags unchanged.`)
}

main().catch((error) => {
  console.error(error.message || error)
  process.exit(1)
})
