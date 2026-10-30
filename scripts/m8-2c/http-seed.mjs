/**
 * M8.2C TEST ONLY seeder for the isolated Branch-1 UAT stack.
 * Refuses development cloud, owner local 54321, and m81c 56321.
 * Requires M82C_OWNER_APPROVED=1. Does not flip flags unless --cutover.
 */
import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { createClient } from "@supabase/supabase-js"
import {
  API_PORT,
  APPROVAL_ENV,
  CONTAINER,
  FORBIDDEN_API_PORTS,
  LOCAL_PASSWORD,
  M81C_SYSID,
  OWNER_SYSID,
  USERS,
} from "./constants.mjs"

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const args = new Set(process.argv.slice(2))
const API = `http://127.0.0.1:${API_PORT}`
const writeFlags = ["--masters", "--cutover", "--stock"]

function fail(message) {
  console.error(`M8.2C seed refused: ${message}`)
  process.exit(1)
}

if (![...args].some((flag) => writeFlags.includes(flag))) {
  console.log("M8.2C http-seed flags: --masters | --cutover | --stock")
  console.log(`${APPROVAL_ENV}=1 is required before any write flag.`)
  process.exit(0)
}

if (process.env[APPROVAL_ENV] !== "1") fail(`${APPROVAL_ENV}=1 is required`)

function psql(sql) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(
      "docker",
      ["exec", "-i", CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"],
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
      if (code === 0) resolvePromise(text)
      else reject(new Error(text || `psql exit ${code}`))
    })
    child.stdin.end(sql)
  })
}

function firstUuid(text) {
  return String(text).match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0] ?? ""
}

function guarded(sql) {
  // GUC is transaction-local so the abort checks in the SQL files can see it.
  return `begin;\nselect set_config('app.m82c_seed_approved', 'on', true);\n${sql}\ncommit;`
}

async function ensureUser(email, fullName) {
  const existing = firstUuid(await psql(`select id from auth.users where email = '${email}'`))
  if (existing) return existing
  return firstUuid(
    await psql(`
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      values (
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        '${email}', extensions.crypt('${LOCAL_PASSWORD}', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('full_name', '${fullName}'), now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      )
      returning id;
    `),
  )
}

async function rpc(client, name, params = {}) {
  const result = await client.rpc(name, params)
  if (result.error) throw new Error(`${name}: ${result.error.message}`)
  return result.data
}

function assertIsolated(url) {
  const parsed = new URL(url)
  if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") {
    fail(`non-local host ${parsed.hostname}`)
  }
  if (FORBIDDEN_API_PORTS.has(parsed.port || "443")) {
    fail(`forbidden API port ${parsed.port}`)
  }
  if (parsed.port !== API_PORT) fail(`expected API port ${API_PORT}`)
}

async function signIn(anonKey, email) {
  const auth = createClient(API, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const result = await auth.auth.signInWithPassword({ email, password: LOCAL_PASSWORD })
  if (result.error || !result.data.session) {
    throw new Error(`sign-in failed for ${email}: ${result.error?.message ?? "no session"}`)
  }
  return createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${result.data.session.access_token}` } },
  })
}

async function loadIsolatedEnv() {
  const sysid = (await psql("select system_identifier from pg_control_system()")).trim()
  if (sysid === OWNER_SYSID || sysid === M81C_SYSID) fail(`forbidden sysid ${sysid}`)
  assertIsolated(API)

  const status = spawn("npx", ["supabase", "status", "-o", "env"], {
    cwd: resolve(repo, ".rehearsal/m82c"),
    shell: true,
  })
  const envText = await new Promise((resolvePromise, reject) => {
    let output = ""
    status.stdout.on("data", (chunk) => {
      output += chunk
    })
    status.stderr.on("data", (chunk) => {
      output += chunk
    })
    status.on("close", (code) => {
      if (code !== 0) reject(new Error(output || "supabase status failed"))
      else resolvePromise(output)
    })
  })
  const env = {}
  for (const line of envText.split(/\r?\n/)) {
    const cut = line.indexOf("=")
    if (cut < 1) continue
    env[line.slice(0, cut)] = line.slice(cut + 1).replace(/^"|"$/g, "")
  }
  if (!env.ANON_KEY) fail("isolated anon key missing")
  assertIsolated(env.API_URL || API)
  return env
}

const env = await loadIsolatedEnv()

async function seedMasters() {
  const ids = {}
  for (const [key, user] of Object.entries(USERS)) {
    ids[key] = await ensureUser(user.email, user.name)
  }
  await psql(`
    insert into public.profiles (id, full_name, is_active)
    values
      ${Object.entries(USERS)
        .map(([key, user]) => `('${ids[key]}', '${user.name.replace(/'/g, "''")}', true)`)
        .join(",\n      ")}
    on conflict (id) do update set is_active = true, full_name = excluded.full_name;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select u.id, r.id, '${ids.admin}'::uuid
    from (values
      ${Object.entries(USERS)
        .map(([key, user]) => `('${ids[key]}'::uuid, '${user.role}')`)
        .join(",\n      ")}
    ) u(id, role_code)
    join public.roles r on r.code = u.role_code
    on conflict do nothing;
  `)

  await psql(guarded(readFileSync(resolve(repo, "scripts/m8-2c/seed.sql"), "utf8")))

  const admin = await signIn(env.ANON_KEY, USERS.admin.email)
  const branch = await rpc(admin, "create_branch", {
    branch_code: "m82c_gd1",
    branch_name: "TEST ONLY Godown-1",
  })
  for (const key of ["accounts", "godown", "sales", "keeper", "driver"]) {
    await rpc(admin, "assign_user_branch", { target_user: ids[key], target_branch: branch })
  }
  const zone = await rpc(admin, "create_zone", {
    target_branch: branch,
    zone_code: "m82c_z1",
    zone_name: "TEST ONLY Zone 1",
    zone_description: "TEST ONLY",
  })
  const crateA = await rpc(admin, "create_crate", {
    target_zone: zone,
    crate_code: "m82c_c1",
    crate_name: "TEST ONLY Crate 1",
    crate_description: "TEST ONLY",
  })
  const crateB = await rpc(admin, "create_crate", {
    target_zone: zone,
    crate_code: "m82c_c2",
    crate_name: "TEST ONLY Crate 2",
    crate_description: "TEST ONLY",
  })
  const category = await rpc(admin, "create_product_category", {
    category_name: "TEST ONLY Category",
    category_description: "TEST ONLY",
  })
  const supplier = await rpc(admin, "create_supplier", {
    supplier_name: "TEST ONLY UAT Supplier",
    supplier_phone: null,
    supplier_email: null,
  })
  const expiry = await rpc(admin, "create_product", {
    product_sku: "m82c-expiry",
    product_name: "TEST ONLY Expiry SKU",
    next_supplier: supplier,
    next_category: category,
  })
  const stable = await rpc(admin, "create_product", {
    product_sku: "m82c-stable",
    product_name: "TEST ONLY Stable SKU",
    next_supplier: supplier,
    next_category: category,
  })
  const spare = await rpc(admin, "create_product", {
    product_sku: "m82c-spare",
    product_name: "TEST ONLY Spare SKU",
    next_supplier: supplier,
    next_category: category,
  })
  await rpc(admin, "set_product_expiry_policy", { target_product: expiry, new_policy: "expiry_controlled" })
  await rpc(admin, "set_product_expiry_policy", { target_product: stable, new_policy: "non_expiring" })
  await rpc(admin, "set_product_expiry_policy", { target_product: spare, new_policy: "non_expiring" })
  for (const productId of [expiry, stable, spare]) {
    await rpc(admin, "set_product_billing_conversion", {
      p_product_id: productId,
      p_billing_unit: "nos",
      p_billed_units_per_case: 10,
    })
  }
  const prices = [
    [expiry, 10],
    [stable, 25],
    [spare, 40],
  ]
  for (const [productId, amount] of prices) {
    await rpc(admin, "upsert_product_selling_price", {
      p_product_id: productId,
      p_shop_id: null,
      p_unit_amount: amount,
      p_effective_from: "2026-01-01",
      p_effective_to: null,
      p_price_id: null,
    })
  }
  const alpha = await rpc(admin, "create_shop", {
    shop_name: "TEST ONLY Shop Alpha",
    shop_phone: null,
    shop_address: null,
  })
  const beta = await rpc(admin, "create_shop", {
    shop_name: "TEST ONLY Shop Beta",
    shop_phone: null,
    shop_address: null,
  })
  const routeId = firstUuid(
    await psql("select id from public.sales_routes where code = 'm82c_rt'"),
  )
  await rpc(admin, "set_shop_sales_route", { target_shop: alpha, target_route: routeId, visit_sequence: 1 })
  await rpc(admin, "set_shop_sales_route", { target_shop: beta, target_route: routeId, visit_sequence: 2 })
  await rpc(admin, "assign_shop_salesperson", { target_shop: alpha, target_salesperson: ids.sales })
  await rpc(admin, "assign_shop_salesperson", { target_shop: beta, target_salesperson: ids.sales })
  await rpc(admin, "create_vehicle", {
    target_branch: null,
    registration_number: "TEST-UAT-0001",
    vehicle_type: "other",
    display_name: "TEST ONLY Vehicle",
    capacity_cases: null,
    operational_notes: "TEST ONLY synthetic vehicle. Capacity is not a company figure.",
  })
  console.log("M8.2C TEST ONLY masters seeded")
  console.log(JSON.stringify({ branch, zone, crateA, crateB, expiry, stable, spare, alpha, beta }, null, 2))
}

async function activateCutover() {
  const sql = readFileSync(resolve(repo, "scripts/m8-2c/activate-dual-write.sql"), "utf8")
  console.log(await psql(guarded(sql)))
}

async function seedStock() {
  const dual = await psql(
    "select value::text from public.app_configuration where key = 'stock.lots.dual_write_enabled'",
  )
  if (!dual.includes("true")) fail("dual-write is still false; run --cutover after owner approval")
  const admin = await signIn(env.ANON_KEY, USERS.admin.email)
  const crateA = firstUuid(await psql("select id from public.crates where code = 'm82c_c1'"))
  const products = {
    expiry: firstUuid(await psql("select id from public.products where sku = 'm82c-expiry'")),
    stable: firstUuid(await psql("select id from public.products where sku = 'm82c-stable'")),
    spare: firstUuid(await psql("select id from public.products where sku = 'm82c-spare'")),
  }
  await rpc(admin, "post_opening_stock", {
    target_product: products.expiry,
    target_crate: crateA,
    carton_quantity: 20,
    idempotency_key: "m82c-open-expiry",
    posting_notes: "TEST ONLY synthetic opening lot",
    manufacturer_lot_code: "TEST-LOT-EXPIRY",
    manufactured_on: "2026-01-01",
    expiry_date: "2099-12-31",
  })
  await rpc(admin, "post_opening_stock", {
    target_product: products.stable,
    target_crate: crateA,
    carton_quantity: 20,
    idempotency_key: "m82c-open-stable",
    posting_notes: "TEST ONLY synthetic opening lot",
    manufacturer_lot_code: "TEST-LOT-STABLE",
    manufactured_on: null,
    expiry_date: null,
  })
  await rpc(admin, "post_opening_stock", {
    target_product: products.spare,
    target_crate: crateA,
    carton_quantity: 20,
    idempotency_key: "m82c-open-spare",
    posting_notes: "TEST ONLY synthetic opening lot",
    manufacturer_lot_code: "TEST-LOT-SPARE",
    manufactured_on: null,
    expiry_date: null,
  })
  console.log("M8.2C TEST ONLY opening lots posted")
}

if (args.has("--masters")) await seedMasters()
if (args.has("--cutover")) await activateCutover()
if (args.has("--stock")) await seedStock()
