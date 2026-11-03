/**
 * DMG-05: disposable transit fixture on development cloud (5173 / ypkfondrkhkydkgovwup).
 * Owner-approved: product + opening 3 + order/pick + one confirm_dispatch of 2 + assign driver.
 * Does not create/submit damage. Does not touch AVT/GOODLIFE/DMG-04. No flag changes.
 */
import { createClient } from "@supabase/supabase-js"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const PASSWORD = "12345678"
const PREFIX = `dmg05-${Date.now().toString(36)}`
const GODOWN = "798bacf9-2212-43fc-9cbb-2fe1e7367a93" // gd_1 Godown-1
const CRATE = "351e1770-a537-4a90-863d-5c76d9a301c7" // uat_c1
const SUPPLIER = "46384c83-0ef3-41f1-9428-0c6e5e9ba064" // AVT master (product supplier only)
const CATEGORY = "a13842e3-4d97-4a1c-bafe-56193c9fba28" // Edible Oils
const VEHICLE = "50faabad-90ca-44cf-b61e-d4d72da20ae9" // KL-43-F-948
const SKU = "TEST-DMG05-ONLY"
const LOT = "TEST-LOT-DMG05"
const OPENING_CASES = 3
const ORDER_CASES = 2
const OPENING_KEY = "dmg05-opening-uat-c1-cloud-v1"
const FORBIDDEN_SKUS = ["AVT-CATER-BLEND-1KG", "GOODLIFE-MILK-500ML", "TEST-DMG04-ONLY"]
const EXPECTED_CLOUD_HOST = "ypkfondrkhkydkgovwup.supabase.co"

function fail(message) {
  console.error(`DMG-05 cloud fixture refused: ${message}`)
  process.exit(1)
}

function loadEnv() {
  const env = {}
  for (const line of readFileSync(resolve(".env.local"), "utf8").split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/)
    if (m) env[m[1]] = m[2].replace(/^"|"$/g, "")
  }
  return env
}

async function signIn(email) {
  const env = loadEnv()
  const client = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD })
  if (error) throw new Error(`${email}: ${error.message}`)
  return client
}

async function rpc(client, name, args) {
  const { data, error } = await client.rpc(name, args)
  if (error) throw new Error(`${name}: ${error.message}`)
  return data
}

async function skuQty(client, sku) {
  const { data, error } = await client.from("products").select("id").eq("sku", sku).maybeSingle()
  if (error) throw error
  if (!data?.id) return 0
  const bal = await client.from("stock_balances").select("quantity").eq("product_id", data.id)
  if (bal.error) throw bal.error
  return (bal.data ?? []).reduce((sum, row) => sum + Number(row.quantity || 0), 0)
}

async function snapshotForbidden(client) {
  const out = {}
  for (const sku of FORBIDDEN_SKUS) out[sku] = await skuQty(client, sku)
  return out
}

async function main() {
  const env = loadEnv()
  if (!env.VITE_SUPABASE_URL?.includes(EXPECTED_CLOUD_HOST)) {
    fail(`expected cloud host ${EXPECTED_CLOUD_HOST}, got ${env.VITE_SUPABASE_URL}`)
  }
  if (env.VITE_SUPABASE_URL.includes("127.0.0.1") || env.VITE_SUPABASE_URL.includes("localhost")) {
    fail("refusing local API URL for cloud fixture script")
  }

  const admin = await signIn("jeffinpappachan110@gmail.com")
  const sales = await signIn("testsalesperson@gmail.com")
  const accounts = await signIn("testaccounts@gmail.com")
  const gm = await signIn("testgodownmanager@gmail.com")
  const keeper = await signIn("teststorekeeper@gmail.com")

  const before = await snapshotForbidden(admin)
  console.log("forbidden_baselines_before", before)
  if (before["AVT-CATER-BLEND-1KG"] !== 17 || before["GOODLIFE-MILK-500ML"] !== 18) {
    fail(`commercial baseline drift before write: ${JSON.stringify(before)}`)
  }
  if (before["TEST-DMG04-ONLY"] !== 3) {
    fail(`DMG-04 physical baseline drift before write: ${before["TEST-DMG04-ONLY"]}`)
  }

  const dmg04Pack = await admin
    .from("stock_picking_requests")
    .select("id,request_number,status")
    .eq("request_number", "PK-20261103-000002")
    .maybeSingle()
  if (dmg04Pack.error) throw dmg04Pack.error
  if (!dmg04Pack.data) fail("DMG-04 packing missing unexpectedly")

  const shopRows = await admin.from("shops").select("id,name").eq("name", "SHOPPE FRESH").limit(1)
  if (shopRows.error) throw shopRows.error
  const shopId = shopRows.data?.[0]?.id
  if (!shopId) fail("SHOPPE FRESH shop missing")

  const driverRows = await admin.from("profiles").select("id,email,full_name").eq("email", "testdeliveryperson@gmail.com").maybeSingle()
  // profiles.email may be null; resolve via auth through a known assignment path
  let driverId = driverRows.data?.id
  if (!driverId) {
    // Fallback: lookup via RPC-visible users table is blocked; use admin auth admin API is unavailable.
    // Sign in as driver briefly to capture uid.
    const driverClient = await signIn("testdeliveryperson@gmail.com")
    driverId = (await driverClient.auth.getUser()).data.user?.id
  }
  if (!driverId) fail("testdeliveryperson user id missing")

  let productId
  const existing = await admin.from("products").select("id,sku,expiry_policy").eq("sku", SKU).maybeSingle()
  if (existing.error) throw existing.error
  if (existing.data?.id) {
    productId = existing.data.id
    console.log("reuse product", productId)
  } else {
    productId = await rpc(admin, "create_product", {
      product_sku: SKU,
      product_name: "TEST ONLY DMG-05 transit fixture — do not sell",
      next_supplier: SUPPLIER,
      next_category: CATEGORY,
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

  let openingRef = null
  try {
    const opening = await rpc(admin, "post_opening_stock", {
      target_product: productId,
      target_crate: CRATE,
      carton_quantity: OPENING_CASES,
      idempotency_key: OPENING_KEY,
      posting_notes: "TEST-ONLY DMG-05 cloud opening 3 cases",
      manufacturer_lot_code: LOT,
      manufactured_on: null,
      expiry_date: null,
    })
    openingRef = opening?.reference_number ?? opening?.id ?? opening
    console.log("opening", opening)
  } catch (err) {
    console.log("opening note:", String(err.message || err))
  }

  const physicalBeforeOrder = await skuQty(admin, SKU)
  if (physicalBeforeOrder < ORDER_CASES) {
    fail(`insufficient TEST physical before order: ${physicalBeforeOrder}`)
  }
  console.log("physical_before_order", physicalBeforeOrder)

  const created = await rpc(sales, "create_order", {
    target_shop: shopId,
    target_branch: GODOWN,
    order_source: "salesperson",
    source_reference: null,
    order_notes: "TEST ONLY DMG-05 transit fixture — one confirm_dispatch authorized",
    order_lines: [{ product_id: productId, requested_cases: ORDER_CASES }],
    idempotency_key: `${PREFIX}-ord`,
  })
  const orderId = created.order?.id ?? created.id
  let version = created.order?.version ?? created.version

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
  await rpc(gm, "acknowledge_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: noteVersion,
    idempotency_key: `${PREFIX}-ack`,
  })

  const preview = await rpc(gm, "preview_order_allocation", { target_order: orderId })
  if (!preview.eligible) {
    fail(`allocation ineligible: ${JSON.stringify(preview.blockers ?? preview)}`)
  }

  const reserved = await rpc(gm, "reserve_order_allocation", {
    target_order: orderId,
    expected_order_version: version,
    idempotency_key: `${PREFIX}-res`,
  })
  const pickingId = reserved.id
  let pickingVersion = reserved.version
  console.log("picking", reserved.request_number, pickingId)

  if (reserved.request_number === "PK-20261103-000002") {
    fail("refused: allocated onto DMG-04 packing number")
  }

  const keeperId = (await keeper.auth.getUser()).data.user.id
  let picking = await rpc(gm, "assign_picking_request", {
    target_request: pickingId,
    assignee: keeperId,
    expected_version: pickingVersion,
    idempotency_key: `${PREFIX}-asg`,
  })
  pickingVersion = picking.version

  picking = await rpc(gm, "start_picking", {
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

  picking = await rpc(gm, "confirm_picking_handoff", {
    target_request: pickingId,
    expected_version: pickingVersion,
    idempotency_key: `${PREFIX}-ho`,
  })
  pickingVersion = picking.version
  console.log("handoff", picking.status)

  const dispPreview = await rpc(gm, "preview_dispatch", { target_order: orderId })
  let header = await rpc(gm, "prepare_dispatch", {
    target_order: orderId,
    expected_picking_version: dispPreview.picking_version ?? pickingVersion,
    idempotency_key: `${PREFIX}-prep`,
  })
  console.log("prepared", header.request_number)

  header = await rpc(gm, "confirm_dispatch", {
    target_dispatch: header.id,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-cfm`,
  })
  if (!header.stock_consumed) fail("confirm_dispatch did not consume stock")
  console.log("confirmed", header.request_number, "stock_consumed=true")

  header = await rpc(gm, "assign_dispatch_delivery", {
    target_dispatch: header.id,
    assignee: driverId,
    target_vehicle: VEHICLE,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-drv`,
  })
  console.log("assigned", "testdeliveryperson@gmail.com")

  const physicalAfter = await skuQty(admin, SKU)
  if (physicalAfter !== 1) fail(`expected remaining physical 1, got ${physicalAfter}`)

  const after = await snapshotForbidden(admin)
  console.log("forbidden_baselines_after", after)
  for (const sku of FORBIDDEN_SKUS) {
    if (after[sku] !== before[sku]) {
      fail(`forbidden SKU ${sku} changed ${before[sku]} → ${after[sku]}`)
    }
  }

  const dmg04After = await admin
    .from("stock_picking_requests")
    .select("id,request_number,status")
    .eq("request_number", "PK-20261103-000002")
    .maybeSingle()
  if (dmg04After.data?.status !== dmg04Pack.data.status) {
    fail("DMG-04 packing status changed")
  }

  const sources = await rpc(gm, "list_damage_report_sources", {
    scenario: "transit",
    target_godown: GODOWN,
    search_text: header.request_number,
    page: 1,
    page_size: 20,
    catalog_search: null,
    catalog_page: 1,
  })
  const match = (sources?.items ?? []).filter(
    (i) => i.label === header.request_number || i.id === header.id,
  )
  if (match.length < 1) fail("dispatch not eligible in transit source picker")

  const lotRow = await admin
    .from("stock_lots")
    .select("id,manufacturer_lot_code")
    .eq("product_id", productId)
    .eq("manufacturer_lot_code", LOT)
    .maybeSingle()

  const summary = {
    environment: "development-cloud",
    project: EXPECTED_CLOUD_HOST,
    app: "http://127.0.0.1:5173",
    product_sku: SKU,
    product_id: productId,
    lot: LOT,
    lot_id: lotRow.data?.id ?? null,
    opening_reference: openingRef,
    opening_physical: physicalBeforeOrder,
    order_number: verified.order.order_number,
    order_id: orderId,
    packing_number: reserved.request_number,
    packing_id: pickingId,
    dispatch_number: header.request_number,
    dispatch_id: header.id,
    dispatch_status: header.status,
    stock_consumed: header.stock_consumed,
    assigned_delivery_person: "testdeliveryperson@gmail.com",
    vehicle: "KL-43-F-948",
    dispatched_cases: ORDER_CASES,
    remaining_physical: physicalAfter,
    transit_sources_match: match,
    stop: "no damage report create/submit/verify",
  }
  console.log(JSON.stringify(summary, null, 2))
  console.log("READY: TEST-DMG05-ONLY transit fixture on development cloud")
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
