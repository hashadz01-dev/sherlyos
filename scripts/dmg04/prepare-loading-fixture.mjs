/**
 * DMG-04: prepare an undispatched, lot-aware packing fixture on development cloud.
 * Trusted RPCs only. Does not dispatch, does not submit loading damage, does not
 * touch AVT/GOODLIFE. Leaves packing ready for manual browser UAT.
 */
import { createClient } from "@supabase/supabase-js"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const PASSWORD = "12345678"
const PREFIX = `dmg04-${Date.now()}`
const GODOWN = "798bacf9-2212-43fc-9cbb-2fe1e7367a93" // gd_1
const CRATE = "351e1770-a537-4a90-863d-5c76d9a301c7" // uat_c1
const SUPPLIER = "46384c83-0ef3-41f1-9428-0c6e5e9ba064" // AVT
const CATEGORY = "a13842e3-4d97-4a1c-bafe-56193c9fba28" // Edible Oils
const SKU = "TEST-DMG04-ONLY"
const LOT = "TEST-LOT-DMG04"

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
  const client = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY)
  const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD })
  if (error) throw new Error(`${email}: ${error.message}`)
  return client
}

async function rpc(client, name, args) {
  const { data, error } = await client.rpc(name, args)
  if (error) throw new Error(`${name}: ${error.message}`)
  return data
}

async function main() {
  const admin = await signIn("jeffinpappachan110@gmail.com")
  const sales = await signIn("testsalesperson@gmail.com")
  const accounts = await signIn("testaccounts@gmail.com")
  const gm = await signIn("testgodownmanager@gmail.com")
  const keeper = await signIn("teststorekeeper@gmail.com")

  // Shop already assigned to salesperson (SHOPPE FRESH).
  const shopRows = await admin
    .from("shops")
    .select("id,name")
    .eq("name", "SHOPPE FRESH")
    .limit(1)
  if (shopRows.error) throw shopRows.error
  const shopId = shopRows.data?.[0]?.id
  if (!shopId) throw new Error("SHOPPE FRESH shop missing")

  let productId
  const existing = await admin
    .from("products")
    .select("id,sku,expiry_policy")
    .eq("sku", SKU)
    .maybeSingle()
  if (existing.data?.id) {
    productId = existing.data.id
    console.log("reuse product", productId)
  } else {
    productId = await rpc(admin, "create_product", {
      product_sku: SKU,
      product_name: "TEST ONLY DMG-04 loading fixture — do not sell",
      next_supplier: SUPPLIER,
      next_category: CATEGORY,
    })
    console.log("created product", productId)
  }
  if (!existing.data?.expiry_policy) {
    await rpc(admin, "set_product_expiry_policy", {
      target_product: productId,
      new_policy: "non_expiring",
    })
  }

  // Company-wide selling price so order lines price.
  await rpc(admin, "upsert_product_selling_price", {
    p_product_id: productId,
    p_shop_id: null,
    p_unit_amount: 10,
    p_effective_from: "2026-01-01",
    p_effective_to: null,
    p_price_id: null,
  })

  // Ensure ≥3 free cases on TEST lot (idempotent opening key).
  try {
    const opening = await rpc(admin, "post_opening_stock", {
      target_product: productId,
      target_crate: CRATE,
      carton_quantity: 3,
      idempotency_key: "dmg04-opening-uat-c1-v1",
      posting_notes: "TEST-ONLY DMG-04 opening 3 cases",
      manufacturer_lot_code: LOT,
      manufactured_on: null,
      expiry_date: null,
    })
    console.log("opening", opening)
  } catch (err) {
    console.log("opening note:", String(err.message || err))
  }

  const created = await rpc(sales, "create_order", {
    target_shop: shopId,
    target_branch: GODOWN,
    order_source: "salesperson",
    source_reference: null,
    order_notes: "TEST ONLY DMG-04 loading damage fixture — do not dispatch",
    order_lines: [{ product_id: productId, requested_cases: 2 }],
    idempotency_key: `${PREFIX}-ord`,
  })
  const orderId = created.order?.id ?? created.id
  let version = created.order?.version ?? created.version
  console.log("order", created.order?.order_number ?? created.order_number, orderId)

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
  console.log("verified", verified.order.status)

  const dn = await rpc(accounts, "create_delivery_note", {
    target_order: orderId,
    idempotency_key: `${PREFIX}-dn`,
  })
  const noteId = dn.delivery_note.id
  let noteVersion = dn.delivery_note.version
  const generated = await rpc(accounts, "generate_delivery_note", {
    target_note: noteId,
    expected_version: noteVersion,
    idempotency_key: `${PREFIX}-gen`,
  })
  noteVersion = generated.delivery_note?.version ?? generated.version ?? noteVersion + 1
  const sent = await rpc(accounts, "send_delivery_note", {
    target_note: noteId,
    expected_version: noteVersion,
    idempotency_key: `${PREFIX}-send`,
  })
  noteVersion = sent.delivery_note?.version ?? sent.version ?? noteVersion + 1
  await rpc(gm, "acknowledge_delivery_note", {
    target_note: noteId,
    expected_version: noteVersion,
    idempotency_key: `${PREFIX}-ack`,
  })
  console.log("delivery note acknowledged")

  const preview = await rpc(gm, "preview_order_allocation", { target_order: orderId })
  if (!preview.eligible) {
    throw new Error(`allocation ineligible: ${JSON.stringify(preview.blockers ?? preview)}`)
  }

  const reserved = await rpc(gm, "reserve_order_allocation", {
    target_order: orderId,
    expected_order_version: version,
    idempotency_key: `${PREFIX}-res`,
  })
  const pickingId = reserved.id
  let pickingVersion = reserved.version
  console.log("picking", reserved.request_number, pickingId)

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
  console.log("handoff status", picking.status, "version", picking.version)
  console.log("STOP: no prepare_dispatch / confirm_dispatch")

  // Eligibility proof via trusted damage source picker as Store Keeper.
  const sources = await rpc(keeper, "list_damage_report_sources", {
    scenario: "loading",
    target_godown: GODOWN,
    search_text: reserved.request_number,
    page: 1,
    page_size: 20,
    catalog_search: null,
    catalog_page: 1,
  })
  const items = sources?.items ?? []
  console.log(
    JSON.stringify(
      {
        product_sku: SKU,
        lot: LOT,
        shop: "SHOPPE FRESH",
        order_id: orderId,
        order_number: verified.order.order_number,
        picking_id: pickingId,
        picking_number: reserved.request_number,
        picking_status: picking.status,
        sources_match: items.filter(
          (i) => i.label === reserved.request_number || i.id === pickingId,
        ),
      },
      null,
      2,
    ),
  )
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
