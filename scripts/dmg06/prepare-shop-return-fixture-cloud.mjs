/**
 * DMG-06: disposable shop-return catalog fixture on development cloud (5173).
 * Owner-approved: TEST-DMG06-ONLY + TEST-LOT-DMG06 + opening exactly 2 @ uat_c1.
 * Does not create order/dispatch/return/damage. Does not create verifier user.
 */
import { createClient } from "@supabase/supabase-js"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const PASSWORD = "12345678"
const GODOWN = "798bacf9-2212-43fc-9cbb-2fe1e7367a93" // gd_1
const CRATE = "351e1770-a537-4a90-863d-5c76d9a301c7" // uat_c1
const SUPPLIER = "46384c83-0ef3-41f1-9428-0c6e5e9ba064" // AVT master only
const CATEGORY = "a13842e3-4d97-4a1c-bafe-56193c9fba28" // Edible Oils
const SKU = "TEST-DMG06-ONLY"
const LOT = "TEST-LOT-DMG06"
const OPENING_CASES = 2
const OPENING_KEY = "dmg06-opening-uat-c1-cloud-v1"
const FORBIDDEN = {
  "AVT-CATER-BLEND-1KG": 17,
  "GOODLIFE-MILK-500ML": 18,
  "TEST-DMG03M-ONLY": 2,
  "TEST-DMG04-ONLY": 3,
  "TEST-DMG05-ONLY": 1,
}
const EXPECTED_CLOUD_HOST = "ypkfondrkhkydkgovwup.supabase.co"

function fail(message) {
  console.error(`DMG-06 cloud fixture refused: ${message}`)
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

async function main() {
  const env = loadEnv()
  if (!env.VITE_SUPABASE_URL?.includes(EXPECTED_CLOUD_HOST)) {
    fail(`expected cloud host ${EXPECTED_CLOUD_HOST}`)
  }

  const admin = await signIn("jeffinpappachan110@gmail.com")

  for (const [sku, expected] of Object.entries(FORBIDDEN)) {
    const qty = await skuQty(admin, sku)
    if (qty !== expected) fail(`baseline drift ${sku}: expected ${expected}, got ${qty}`)
  }
  console.log("forbidden_baselines_ok", FORBIDDEN)

  if ((await skuQty(admin, SKU)) !== 0) {
    fail(`${SKU} already has stock — refusing unexpected reuse`)
  }

  const shop = await admin.from("shops").select("id,name,is_active").eq("name", "SHOPPE FRESH").maybeSingle()
  if (shop.error) throw shop.error
  if (!shop.data?.id || shop.data.is_active !== true) fail("SHOPPE FRESH missing or inactive")

  let productId
  const existing = await admin.from("products").select("id,sku").eq("sku", SKU).maybeSingle()
  if (existing.error) throw existing.error
  if (existing.data?.id) {
    productId = existing.data.id
    console.log("reuse product", productId)
  } else {
    productId = await rpc(admin, "create_product", {
      product_sku: SKU,
      product_name: "TEST ONLY DMG-06 shop-return fixture — do not sell",
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
  const opening = await rpc(admin, "post_opening_stock", {
    target_product: productId,
    target_crate: CRATE,
    carton_quantity: OPENING_CASES,
    idempotency_key: OPENING_KEY,
    posting_notes: "TEST-ONLY DMG-06 cloud opening 2 cases for catalog",
    manufacturer_lot_code: LOT,
    manufactured_on: null,
    expiry_date: null,
  })
  openingRef = opening?.reference_number ?? opening?.id ?? opening
  console.log("opening", opening)

  const physical = await skuQty(admin, SKU)
  if (physical !== OPENING_CASES) fail(`expected physical ${OPENING_CASES}, got ${physical}`)

  const lot = await admin
    .from("stock_lots")
    .select("id,manufacturer_lot_code")
    .eq("product_id", productId)
    .eq("manufacturer_lot_code", LOT)
    .maybeSingle()
  if (lot.error) throw lot.error
  if (!lot.data?.id) fail("lot TEST-LOT-DMG06 missing after opening")

  const lotBal = await admin
    .from("stock_lot_balances")
    .select("quantity,crate_id")
    .eq("lot_id", lot.data.id)
  if (lotBal.error) throw lotBal.error
  const lotQty = (lotBal.data ?? []).reduce((sum, row) => sum + Number(row.quantity || 0), 0)
  if (lotQty !== OPENING_CASES) fail(`lot qty ${lotQty} != aggregate ${OPENING_CASES}`)

  for (const [sku, expected] of Object.entries(FORBIDDEN)) {
    const qty = await skuQty(admin, sku)
    if (qty !== expected) fail(`forbidden SKU changed ${sku}: ${expected} → ${qty}`)
  }

  const shopReturnReports = await admin
    .from("damage_reports")
    .select("id,report_number,status")
    .eq("scenario", "shop_return")
    .limit(5)
  if (shopReturnReports.error) throw shopReturnReports.error
  if ((shopReturnReports.data ?? []).length > 0) {
    fail(`unexpected existing shop_return reports: ${JSON.stringify(shopReturnReports.data)}`)
  }

  // Catalog eligibility proof: GM source picker must return product under shop_return catalogs.
  const gm = await signIn("testgodownmanager@gmail.com")
  const sources = await rpc(gm, "list_damage_report_sources", {
    scenario: "shop_return",
    target_godown: GODOWN,
    search_text: "SHOPPE",
    page: 1,
    page_size: 20,
    catalog_search: SKU,
    catalog_page: 1,
  })
  const products = sources?.catalogs?.products ?? []
  const selectable = products.some((p) => p.sku === SKU || p.id === productId)
  if (!selectable) fail("TEST-DMG06-ONLY not selectable in shop_return product catalog")

  const shopItems = sources?.items ?? []
  const shopMatch = shopItems.some((i) => i.label === "SHOPPE FRESH" || i.id === shop.data.id)

  const summary = {
    environment: "development-cloud",
    app: "http://127.0.0.1:5173",
    product_sku: SKU,
    product_id: productId,
    lot: LOT,
    lot_id: lot.data.id,
    opening_reference: openingRef,
    physical_cases: physical,
    lot_cases: lotQty,
    shop: "SHOPPE FRESH",
    shop_selectable: shopMatch,
    product_selectable: selectable,
    stop: "no order/dispatch/return/damage; verifier not created",
  }
  console.log(JSON.stringify(summary, null, 2))
  console.log("READY: TEST-DMG06-ONLY shop-return fixture on development cloud")
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
