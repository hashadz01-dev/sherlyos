/**
 * DMG-05: prepare a stock-consumed transit-damage fixture on disposable m82c only.
 * Creates TEST-DMG05-ONLY → order 2 → pick → confirm_dispatch once → assign driver.
 * Refuses cloud / owner / m81c. Does not submit damage. Requires M82C_OWNER_APPROVED=1.
 */
import { spawn } from "node:child_process"
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
} from "../m8-2c/constants.mjs"

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const API = `http://127.0.0.1:${API_PORT}`
const PREFIX = `dmg05-${Date.now().toString(36)}`
const SKU = "TEST-DMG05-ONLY"
const LOT = "TEST-LOT-DMG05"
const OPENING_CASES = 3
const ORDER_CASES = 2
const OPENING_KEY = "dmg05-opening-m82c-c1-v1"

function fail(message) {
  console.error(`DMG-05 fixture refused: ${message}`)
  process.exit(1)
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

function assertIsolated(url) {
  const parsed = new URL(url)
  if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") {
    fail(`non-local host ${parsed.hostname}`)
  }
  if (FORBIDDEN_API_PORTS.has(parsed.port || "443")) fail(`forbidden API port ${parsed.port}`)
  if (parsed.port !== API_PORT) fail(`expected API port ${API_PORT}`)
}

async function rpc(client, name, params = {}) {
  const result = await client.rpc(name, params)
  if (result.error) throw new Error(`${name}: ${result.error.message}`)
  return result.data
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

// Refuse forbidden database identities before any write.
const sysid = (await psql("select system_identifier from pg_control_system()")).trim()
if (sysid === OWNER_SYSID || sysid === M81C_SYSID) fail(`forbidden sysid ${sysid}`)
assertIsolated(API)

const commercial = await psql(`
  select count(*)::text from public.products
  where sku in ('AVT-CATER-BLEND-1KG','GOODLIFE-MILK-500ML')
`)
if (commercial !== "0") fail(`commercial SKUs present on m82c (${commercial}) — abort`)

const dmg04Touch = await psql(`
  select count(*)::text from public.stock_picking_requests
  where request_number = 'PK-20261103-000002'
`)
if (dmg04Touch !== "0") fail("DMG-04 packing present on unexpected stack — abort")

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
if (!env.ANON_KEY) fail("anon key missing")
assertIsolated(env.API_URL || API)

const ids = {
  keeper: firstUuid(await psql(`select id from auth.users where email = '${USERS.keeper.email}'`)),
  driver: firstUuid(await psql(`select id from auth.users where email = '${USERS.driver.email}'`)),
}
if (!ids.keeper || !ids.driver) fail("keeper/driver user missing")

const branch = firstUuid(await psql("select id from public.branches where code = 'm82c_gd1'"))
const crate = firstUuid(await psql("select id from public.crates where code = 'm82c_c1'"))
const shop = firstUuid(await psql("select id from public.shops where name = 'TEST ONLY Shop Alpha'"))
const category = firstUuid(await psql("select id from public.product_categories where name = 'TEST ONLY Category'"))
const supplier = firstUuid(await psql("select id from public.suppliers where name = 'TEST ONLY UAT Supplier'"))
const vehicle = firstUuid(
  await psql("select id from public.vehicles where registration_number = 'TEST-UAT-0001'"),
)
if (!branch || !crate || !shop || !category || !supplier || !vehicle) {
  fail("required TEST masters missing on m82c")
}

const admin = await signIn(env.ANON_KEY, USERS.admin.email)
const accounts = await signIn(env.ANON_KEY, USERS.accounts.email)
const godown = await signIn(env.ANON_KEY, USERS.godown.email)
const sales = await signIn(env.ANON_KEY, USERS.sales.email)
const keeper = await signIn(env.ANON_KEY, USERS.keeper.email)

let productId = firstUuid(await psql(`select id from public.products where sku = '${SKU}'`))
if (productId) {
  console.log("reuse product", productId)
} else {
  productId = await rpc(admin, "create_product", {
    product_sku: SKU,
    product_name: "TEST ONLY DMG-05 transit fixture — do not sell",
    next_supplier: supplier,
    next_category: category,
  })
  console.log("created product", productId)
}

await rpc(admin, "set_product_expiry_policy", {
  target_product: productId,
  new_policy: "non_expiring",
})
await rpc(admin, "set_product_billing_conversion", {
  p_product_id: productId,
  p_billing_unit: "nos",
  p_billed_units_per_case: 10,
})
await rpc(admin, "upsert_product_selling_price", {
  p_product_id: productId,
  p_shop_id: null,
  p_unit_amount: 10,
  p_effective_from: "2026-01-01",
  p_effective_to: null,
  p_price_id: null,
})

try {
  const opening = await rpc(admin, "post_opening_stock", {
    target_product: productId,
    target_crate: crate,
    carton_quantity: OPENING_CASES,
    idempotency_key: OPENING_KEY,
    posting_notes: "TEST-ONLY DMG-05 opening 3 cases on m82c_c1",
    manufacturer_lot_code: LOT,
    manufactured_on: null,
    expiry_date: null,
  })
  console.log("opening", opening)
} catch (err) {
  // Idempotent replay is expected if fixture is re-run after a prior opening.
  console.log("opening note:", String(err.message || err))
}

const physicalBefore = Number(
  await psql(`
    select coalesce(sum(quantity),0)::text from public.stock_balances
    where product_id = '${productId}'
  `),
)
if (physicalBefore < ORDER_CASES) {
  fail(`insufficient TEST physical stock before order: ${physicalBefore}`)
}
console.log("physical_before_order", physicalBefore)

const created = await rpc(sales, "create_order", {
  target_shop: shop,
  target_branch: branch,
  order_source: "salesperson",
  source_reference: null,
  order_notes: "TEST ONLY DMG-05 transit damage fixture — confirm_dispatch authorized once",
  order_lines: [{ product_id: productId, requested_cases: ORDER_CASES }],
  idempotency_key: `${PREFIX}-ord`,
})
const orderId = created.order.id
let version = created.order.version

const submitted = await rpc(sales, "submit_order", {
  target_order: orderId,
  expected_version: version,
  idempotency_key: `${PREFIX}-sub`,
})
version = submitted.order.version

const verified = await rpc(accounts, "verify_order", {
  target_order: orderId,
  expected_version: version,
  idempotency_key: `${PREFIX}-ver`,
})
version = verified.order.version
console.log("order", verified.order.order_number, verified.order.status)

const dn = await rpc(accounts, "create_delivery_note", {
  target_order: orderId,
  idempotency_key: `${PREFIX}-dn`,
})
let noteVersion = dn.delivery_note.version
const generated = await rpc(accounts, "generate_delivery_note", {
  target_note: dn.delivery_note.id,
  expected_version: noteVersion,
  idempotency_key: `${PREFIX}-gen`,
})
noteVersion = generated.delivery_note?.version ?? noteVersion + 1
const sent = await rpc(accounts, "send_delivery_note", {
  target_note: dn.delivery_note.id,
  expected_version: noteVersion,
  idempotency_key: `${PREFIX}-send`,
})
noteVersion = sent.delivery_note?.version ?? noteVersion + 1
await rpc(godown, "acknowledge_delivery_note", {
  target_note: dn.delivery_note.id,
  expected_version: noteVersion,
  idempotency_key: `${PREFIX}-ack`,
})

const preview = await rpc(godown, "preview_order_allocation", { target_order: orderId })
if (!preview.eligible) {
  fail(`allocation ineligible: ${JSON.stringify(preview.blockers ?? preview)}`)
}

const reserved = await rpc(godown, "reserve_order_allocation", {
  target_order: orderId,
  expected_order_version: version,
  idempotency_key: `${PREFIX}-res`,
})
const pickingId = reserved.id
let pickingVersion = reserved.version
console.log("picking", reserved.request_number, pickingId)

let picking = await rpc(godown, "assign_picking_request", {
  target_request: pickingId,
  assignee: ids.keeper,
  expected_version: pickingVersion,
  idempotency_key: `${PREFIX}-asg`,
})
pickingVersion = picking.version

picking = await rpc(godown, "start_picking", {
  target_request: pickingId,
  expected_version: pickingVersion,
  idempotency_key: `${PREFIX}-start`,
})
pickingVersion = picking.version

for (const row of picking.reservations ?? []) {
  picking = await rpc(keeper, "confirm_picking_quantity", {
    target_request: pickingId,
    target_reservation: row.id,
    picked_quantity: row.reserved_cases,
    expected_version: pickingVersion,
    idempotency_key: `${PREFIX}-pick-${row.id}`.slice(0, 80),
  })
  pickingVersion = picking.version
}

picking = await rpc(keeper, "complete_picking", {
  target_request: pickingId,
  expected_version: pickingVersion,
  idempotency_key: `${PREFIX}-done`,
})
pickingVersion = picking.version

picking = await rpc(godown, "confirm_picking_handoff", {
  target_request: pickingId,
  expected_version: pickingVersion,
  idempotency_key: `${PREFIX}-ho`,
})
pickingVersion = picking.version
console.log("handoff", picking.status)

const dispPreview = await rpc(godown, "preview_dispatch", { target_order: orderId })
let header = await rpc(godown, "prepare_dispatch", {
  target_order: orderId,
  expected_picking_version: dispPreview.picking_version ?? pickingVersion,
  idempotency_key: `${PREFIX}-prep`,
})
console.log("prepared dispatch", header.request_number, header.id)

// Authorized once: consume the two TEST cases.
header = await rpc(godown, "confirm_dispatch", {
  target_dispatch: header.id,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-cfm`,
})
if (!header.stock_consumed) fail("confirm_dispatch did not consume stock")
console.log("confirmed dispatch", header.request_number, "stock_consumed=true")

header = await rpc(godown, "assign_dispatch_delivery", {
  target_dispatch: header.id,
  assignee: ids.driver,
  target_vehicle: vehicle,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-drv`,
})
console.log("assigned driver", USERS.driver.email)

const physicalAfter = Number(
  await psql(`
    select coalesce(sum(quantity),0)::text from public.stock_balances
    where product_id = '${productId}'
  `),
)
const lotAfter = await psql(`
  select coalesce(sum(lb.quantity),0)::text
  from public.stock_lot_balances lb
  join public.stock_lots l on l.id = lb.lot_id
  where l.product_id = '${productId}'
    and l.manufacturer_lot_code = '${LOT}'
`)
const reservedActive = await psql(`
  select coalesce(sum(reserved_cases),0)::text
  from public.stock_reservations
  where picking_request_id = '${pickingId}' and status = 'active'
`)

// Transit eligibility via GM damage source picker (no report created).
const sources = await rpc(godown, "list_damage_report_sources", {
  scenario: "transit",
  target_godown: branch,
  search_text: header.request_number,
  page: 1,
  page_size: 20,
  catalog_search: null,
  catalog_page: 1,
})
const items = sources?.items ?? []
const match = items.filter((i) => i.label === header.request_number || i.id === header.id)

const summary = {
  environment: "m82c",
  api: API,
  sysid,
  product_sku: SKU,
  lot: LOT,
  godown: "m82c_gd1 (TEST ONLY Godown-1)",
  crate: "m82c_c1",
  shop: "TEST ONLY Shop Alpha",
  order_number: verified.order.order_number,
  order_id: orderId,
  packing_number: reserved.request_number,
  packing_id: pickingId,
  dispatch_number: header.request_number,
  dispatch_id: header.id,
  dispatch_status: header.status,
  stock_consumed: header.stock_consumed,
  assigned_delivery_person: USERS.driver.email,
  vehicle: "TEST-UAT-0001",
  opening_physical: physicalBefore,
  dispatched_cases: ORDER_CASES,
  remaining_physical: physicalAfter,
  remaining_lot: Number(lotAfter),
  active_reservations: Number(reservedActive),
  transit_sources_match: match,
  stop: "no damage report create/submit/verify",
}
console.log(JSON.stringify(summary, null, 2))

if (!header.stock_consumed) fail("dispatch not stock-consumed")
if (match.length < 1) fail("dispatch not returned by transit source picker")
if (physicalAfter !== physicalBefore - ORDER_CASES) {
  fail(`unexpected remaining physical ${physicalAfter} (before ${physicalBefore})`)
}
console.log("READY: TEST-DMG05-ONLY transit fixture prepared on m82c")
