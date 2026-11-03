/**
 * M8.2D Scenario A against isolated sherlyos_m82c only.
 * Refuses owner, m81c, and development cloud. Requires M82C_OWNER_APPROVED=1.
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
} from "./constants.mjs"

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const API = `http://127.0.0.1:${API_PORT}`
const PREFIX = `m82ca-${Date.now().toString(36)}`

function fail(message) {
  console.error(`M8.2D Scenario A refused: ${message}`)
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

async function expectDenied(label, fn) {
  try {
    await fn()
    throw new Error(`${label} should have been denied`)
  } catch (error) {
    if (/should have been denied/i.test(error.message)) throw error
    if (!/not authorized|permission denied|violat|policy|42501/i.test(error.message)) {
      throw error
    }
  }
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

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

const sysid = (await psql("select system_identifier from pg_control_system()")).trim()
if (sysid === OWNER_SYSID || sysid === M81C_SYSID) fail(`forbidden sysid ${sysid}`)
assertIsolated(API)
ok(`isolated sysid ${sysid}`)

const flags = await psql(`
  select key || '=' || value::text
  from public.app_configuration
  where key in (
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked',
    'damage.stock_hold_ready'
  )
  order by 1
`)
if (!flags.includes("stock.lots.dual_write_enabled=true")) fail(`dual-write not enabled:\n${flags}`)
if (!flags.includes("stock.lots.aggregate_only_blocked=true")) fail(flags)
if (!flags.includes("damage.stock_hold_ready=false")) fail(flags)
ok("isolated lot cutover on; damage holds false")

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
  admin: firstUuid(await psql(`select id from auth.users where email = '${USERS.admin.email}'`)),
  accounts: firstUuid(await psql(`select id from auth.users where email = '${USERS.accounts.email}'`)),
  godown: firstUuid(await psql(`select id from auth.users where email = '${USERS.godown.email}'`)),
  sales: firstUuid(await psql(`select id from auth.users where email = '${USERS.sales.email}'`)),
  keeper: firstUuid(await psql(`select id from auth.users where email = '${USERS.keeper.email}'`)),
  driver: firstUuid(await psql(`select id from auth.users where email = '${USERS.driver.email}'`)),
}

const admin = await signIn(env.ANON_KEY, USERS.admin.email)
const accounts = await signIn(env.ANON_KEY, USERS.accounts.email)
const godown = await signIn(env.ANON_KEY, USERS.godown.email)
const sales = await signIn(env.ANON_KEY, USERS.sales.email)
const keeper = await signIn(env.ANON_KEY, USERS.keeper.email)
const driver = await signIn(env.ANON_KEY, USERS.driver.email)
ok("six isolated roles signed in")

const branch = firstUuid(await psql("select id from public.branches where code = 'm82c_gd1'"))
const shop = firstUuid(await psql("select id from public.shops where name = 'TEST ONLY Shop Alpha'"))
const productA = firstUuid(await psql("select id from public.products where sku = 'm82c-expiry'"))
const productB = firstUuid(await psql("select id from public.products where sku = 'm82c-stable'"))
const vehicle = firstUuid(
  await psql("select id from public.vehicles where registration_number = 'TEST-UAT-0001'"),
)

const opening = await psql(`
  select coalesce(sum(quantity),0)::text from public.stock_balances
  where product_id in ('${productA}','${productB}')
`)
const openingLots = await psql(`
  select coalesce(sum(lb.quantity),0)::text
  from public.stock_lot_balances lb
  join public.stock_lots l on l.id = lb.lot_id
  where l.product_id in ('${productA}','${productB}')
`)
if (opening !== "40" || openingLots !== "40") {
  fail(`opening oracle agg=${opening} lot=${openingLots}`)
}
ok("available opening stock 20+20 with lot=aggregate")

await expectDenied("salesperson verify", () =>
  rpc(sales, "verify_order", {
    target_order: "00000000-0000-0000-0000-000000000001",
    expected_version: 1,
    idempotency_key: `${PREFIX}-bad-ver`,
  }),
)
await expectDenied("keeper dispatch", () =>
  rpc(keeper, "prepare_dispatch", {
    target_order: "00000000-0000-0000-0000-000000000001",
    expected_picking_version: 1,
    idempotency_key: `${PREFIX}-bad-disp`,
  }),
)
await expectDenied("driver invoice", () =>
  rpc(driver, "prepare_invoice_note", {
    p_dispatch_id: "00000000-0000-0000-0000-000000000001",
    p_idempotency_key: `${PREFIX}-bad-inv`,
    p_expected_version: 1,
    p_remarks: null,
  }),
)
ok("role denials: salesperson cannot verify, keeper cannot dispatch, driver cannot bill")

const created = await rpc(sales, "create_order", {
  target_shop: shop,
  target_branch: branch,
  order_source: "salesperson",
  source_reference: null,
  order_notes: "TEST ONLY Scenario A",
  order_lines: [
    { product_id: productA, requested_cases: 5 },
    { product_id: productB, requested_cases: 3 },
  ],
  idempotency_key: `${PREFIX}-ord`,
})
const submitted = await rpc(sales, "submit_order", {
  target_order: created.order.id,
  expected_version: created.order.version,
  idempotency_key: `${PREFIX}-sub`,
})
ok(`salesperson submitted ${submitted.order.order_number}`)

const verified = await rpc(accounts, "verify_order", {
  target_order: created.order.id,
  expected_version: submitted.order.version,
  idempotency_key: `${PREFIX}-ver`,
})
if (verified.order.status !== "verified") fail(`verify status ${verified.order.status}`)
ok("accounts verified")

const dn = await rpc(accounts, "create_delivery_note", {
  target_order: created.order.id,
  idempotency_key: `${PREFIX}-dn`,
})
await rpc(accounts, "generate_delivery_note", {
  target_note: dn.delivery_note.id,
  expected_version: 1,
  idempotency_key: `${PREFIX}-gen`,
})
await rpc(accounts, "send_delivery_note", {
  target_note: dn.delivery_note.id,
  expected_version: 2,
  idempotency_key: `${PREFIX}-send`,
})
await rpc(godown, "acknowledge_delivery_note", {
  target_note: dn.delivery_note.id,
  expected_version: 3,
  idempotency_key: `${PREFIX}-ack`,
})
ok("delivery note sent and acknowledged")

const preview = await rpc(godown, "preview_order_allocation", { target_order: created.order.id })
if (!preview.eligible) fail(`picking ineligible ${JSON.stringify(preview.blockers)}`)
ok("allocation preview eligible")

const reserved = await rpc(godown, "reserve_order_allocation", {
  target_order: created.order.id,
  expected_order_version: verified.order.version,
  idempotency_key: `${PREFIX}-res`,
})
let picking = await rpc(godown, "assign_picking_request", {
  target_request: reserved.id,
  assignee: ids.keeper,
  expected_version: reserved.version,
  idempotency_key: `${PREFIX}-asg`,
})
picking = await rpc(godown, "start_picking", {
  target_request: reserved.id,
  expected_version: picking.version,
  idempotency_key: `${PREFIX}-start`,
})
let pickedTotal = 0
for (const row of picking.reservations) {
  picking = await rpc(keeper, "confirm_picking_quantity", {
    target_request: reserved.id,
    target_reservation: row.id,
    picked_quantity: row.reserved_cases,
    expected_version: picking.version,
    idempotency_key: `${PREFIX}-pick-${row.id}`.slice(0, 80),
  })
  pickedTotal += Number(row.reserved_cases)
}
if (pickedTotal !== 8) fail(`picked ${pickedTotal}, expected 8`)
picking = await rpc(keeper, "complete_picking", {
  target_request: reserved.id,
  expected_version: picking.version,
  idempotency_key: `${PREFIX}-done`,
})
picking = await rpc(godown, "confirm_picking_handoff", {
  target_request: reserved.id,
  expected_version: picking.version,
  idempotency_key: `${PREFIX}-ho`,
})
ok("store keeper picked 8 cases; GM handoff ready")

const dispPreview = await rpc(godown, "preview_dispatch", { target_order: created.order.id })
let header = await rpc(godown, "prepare_dispatch", {
  target_order: created.order.id,
  expected_picking_version: dispPreview.picking_version ?? picking.version,
  idempotency_key: `${PREFIX}-prep`,
})
header = await rpc(godown, "confirm_dispatch", {
  target_dispatch: header.id,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-cfm`,
})
if (!header.stock_consumed) fail("confirm_dispatch did not consume")
const replay = await rpc(godown, "confirm_dispatch", {
  target_dispatch: header.id,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-cfm`,
})
if (replay.posted_transaction_id !== header.posted_transaction_id) {
  fail("duplicate confirm posted a second ledger")
}
ok("dispatch consumed once")

header = await rpc(godown, "assign_dispatch_delivery", {
  target_dispatch: header.id,
  assignee: ids.driver,
  target_vehicle: vehicle,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-drv`,
})

const note = await rpc(godown, "prepare_invoice_note", {
  p_dispatch_id: header.id,
  p_idempotency_key: `${PREFIX}-inv`,
  p_expected_version: 1,
  p_remarks: "TEST ONLY Scenario A",
})
const submittedNote = await rpc(godown, "submit_invoice_note", {
  p_invoice_note_id: note.id,
  p_expected_version: note.version,
})
const reviewed = await rpc(accounts, "review_invoice_note", {
  p_invoice_note_id: note.id,
  p_expected_version: submittedNote.version,
})
if (reviewed.status !== "reviewed") fail(`invoice note ${reviewed.status}`)
const taxAmount = Number(reviewed.tax_amount ?? reviewed.totals?.tax_amount ?? 0)
if (taxAmount !== 0) fail(`tax_amount must stay 0, got ${taxAmount}`)
ok("internal invoice note reviewed; tax_amount 0")

header = await rpc(driver, "start_dispatch_delivery", {
  target_dispatch: header.id,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-go`,
})
header = await rpc(driver, "acknowledge_dispatch_delivery", {
  target_dispatch: header.id,
  recipient_name: "TEST ONLY Receiver",
  acknowledgement_notes: "TEST ONLY POD",
  expected_version: header.version,
  idempotency_key: `${PREFIX}-pod`,
  proof_reference: "TEST-POD-A",
})
if (header.status !== "delivered") fail(`POD status ${header.status}`)
ok("delivery person POD delivered")

const remaining = await psql(`
  select coalesce(sum(quantity),0)::text from public.stock_balances
  where product_id in ('${productA}','${productB}')
`)
const remainingLots = await psql(`
  select coalesce(sum(lb.quantity),0)::text
  from public.stock_lot_balances lb
  join public.stock_lots l on l.id = lb.lot_id
  where l.product_id in ('${productA}','${productB}')
`)
if (remaining !== "32" || remainingLots !== "32") {
  fail(`after dispatch expected 32 remaining, agg=${remaining} lot=${remainingLots}`)
}
const ledger = await psql(`
  select count(*)::text from public.stock_transactions
  where transaction_type = 'DISPATCH' and product_id in ('${productA}','${productB}')
`)
const dispatchTx = await psql(`
  select count(distinct posted_transaction_id)::text
  from public.stock_dispatch_requests
  where id = '${header.id}'
`)
if (dispatchTx !== "1") fail(`expected one posted dispatch txn, got ${dispatchTx}`)
ok(`stock remaining 32=32; DISPATCH ledger rows ${ledger}`)

const legal = await psql(`
  select count(*)::text from public.statutory_invoices
  where issued_at is not null or legal_invoice_number is not null
`)
if (legal !== "0") fail(`legal invoice issued: ${legal}`)
ok("no legal GST invoice issued")

const ordered = await psql(`
  select sum(requested_cases)::text from public.order_lines where order_id = '${created.order.id}'
`)
if (ordered !== "8") fail(`ordered ${ordered}`)
ok("ordered quantity remains 8")

console.log(`\nM8.2D Scenario A PASS (${passed.length} checks)`)
console.log(
  JSON.stringify(
    {
      sysid,
      order: submitted.order.order_number,
      dispatch: header.dispatch_number || header.id,
      invoice: reviewed.invoice_number || reviewed.id,
      remaining,
      remainingLots,
    },
    null,
    2,
  ),
)
