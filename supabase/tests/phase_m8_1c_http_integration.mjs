/**
 * M8.1C isolated HTTP cutover. Talks only to 127.0.0.1:56321 and
 * supabase_db_sherlyos_m81c. Refuses the owner API and container.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const STACK = resolve(REPO, ".rehearsal/m81c")
const API = "http://127.0.0.1:56321"
const CONTAINER = "supabase_db_sherlyos_m81c"
const PASSWORD = "local-only-m81c"
const PREFIX = "m81cqa"
const RUN = Date.now().toString(36)

function statusEnv() {
  return new Promise((resolvePromise, reject) => {
    const child = spawn("npx", ["supabase", "status", "-o", "env"], {
      cwd: STACK,
      shell: true,
    })
    let output = ""
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    child.stderr.on("data", (chunk) => {
      output += chunk
    })
    child.on("close", (code) => {
      if (code !== 0) reject(new Error(output || "supabase status failed"))
      else {
        const env = {}
        for (const line of output.split(/\r?\n/)) {
          const cut = line.indexOf("=")
          if (cut < 1) continue
          env[line.slice(0, cut)] = line.slice(cut + 1).replace(/^"|"$/g, "")
        }
        resolvePromise(env)
      }
    })
  })
}

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
    throw new Error(`refusing non-local host ${parsed.hostname}`)
  }
  if (parsed.port === "54321") {
    throw new Error("M8.1C refused the owner API port 54321")
  }
  if (parsed.port !== "56321") {
    throw new Error(`M8.1C expected API port 56321, got ${parsed.port}`)
  }
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
        '${email}', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')), now(),
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

async function signIn(anonKey, email) {
  const auth = createClient(API, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const result = await auth.auth.signInWithPassword({ email, password: PASSWORD })
  if (result.error || !result.data.session) {
    throw new Error(`sign-in failed for ${email}: ${result.error?.message ?? "no session"}`)
  }
  return createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${result.data.session.access_token}` } },
  })
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

async function expectDenied(label, fn) {
  try {
    await fn()
    throw new Error(`${label} should have been denied`)
  } catch (error) {
    if (/should have been denied/i.test(error.message)) throw error
    if (!/not authorized|violat|policy|unclassified|lot|expiry|insufficient|duplicate|already/i.test(error.message)) {
      throw error
    }
  }
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

const env = await statusEnv()
assertIsolated(env.API_URL || API)
if (!env.ANON_KEY) throw new Error("isolated anon key missing")

const sysid = await psql("select system_identifier from pg_control_system()")
if (sysid.trim() === "7699785797738577957") {
  throw new Error("M8.1C HTTP refused the owner system identifier")
}

const users = {
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M81C Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M81C Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M81C Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M81C Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M81C Driver"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M81C Other GM"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M81C Admin', true),
    ('${users.accounts}', 'M81C Accounts', true),
    ('${users.godown}', 'M81C Godown', true),
    ('${users.keeper}', 'M81C Keeper', true),
    ('${users.driver}', 'M81C Driver', true),
    ('${users.other}', 'M81C Other GM', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person'),
    ('${users.other}'::uuid, 'godown_manager')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)
const other = await signIn(env.ANON_KEY, `other.${PREFIX}@example.com`)
ok("auth sign-in for five staff roles plus peer godown")

try {
  await admin.from("app_configuration").update({ value: true }).eq("key", "stock.lots.dual_write_enabled")
  const dual = await psql("select value from public.app_configuration where key = 'stock.lots.dual_write_enabled'")
  if (dual.includes("true")) throw new Error("authenticated config update mutated flags")
} catch {
  /* PostgREST may return an error; either path is fail-closed if flags stay false */
}
{
  const dual = await psql("select value from public.app_configuration where key = 'stock.lots.dual_write_enabled'")
  if (dual.includes("true")) throw new Error("staff JWT must not enable dual-write")
}
ok("authenticated staff cannot enable cutover flags")

const branch = await rpc(admin, "create_branch", { branch_code: `${PREFIX}_${RUN}`, branch_name: "M81C A" })
const branchB = await rpc(admin, "create_branch", { branch_code: `${PREFIX}b_${RUN}`, branch_name: "M81C B" })
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.driver, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.other, target_branch: branchB })
const zone = await rpc(admin, "create_zone", {
  target_branch: branch, zone_code: `${PREFIX}_z`, zone_name: "Z", zone_description: null,
})
const crate = await rpc(admin, "create_crate", {
  target_zone: zone, crate_code: `${PREFIX}_c`, crate_name: "C", crate_description: null,
})
const crate2 = await rpc(admin, "create_crate", {
  target_zone: zone, crate_code: `${PREFIX}_c2`, crate_name: "C2", crate_description: null,
})
const zoneB = await rpc(admin, "create_zone", {
  target_branch: branchB, zone_code: `${PREFIX}_zb`, zone_name: "ZB", zone_description: null,
})
const crateX = await rpc(admin, "create_crate", {
  target_zone: zoneB, crate_code: `${PREFIX}_cx`, crate_name: "CX", crate_description: null,
})
const exp = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-exp-${RUN}`, product_name: "M81C Expiry", next_supplier: null, next_category: null,
})
const nx = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-nx-${RUN}`, product_name: "M81C Non-expiring", next_supplier: null, next_category: null,
})
const unclass = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-un-${RUN}`, product_name: "M81C Unclassified", next_supplier: null, next_category: null,
})
await rpc(admin, "set_product_expiry_policy", { target_product: exp, new_policy: "expiry_controlled" })
await rpc(admin, "set_product_expiry_policy", { target_product: nx, new_policy: "non_expiring" })
const shop = await rpc(admin, "create_shop", {
  shop_name: `M81C shop ${RUN}`, shop_phone: null, shop_address: null,
})
ok("classified products and crate hierarchy via authenticated RPCs")

await psql(`
  update public.app_configuration
  set value = 'true'::jsonb
  where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
`)
{
  const flags = await psql(`
    select key || '=' || value::text
    from public.app_configuration
    where key in ('stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked','damage.stock_hold_ready')
    order by 1
  `)
  if (!flags.includes("stock.lots.dual_write_enabled=true")) throw new Error(flags)
  if (!flags.includes("stock.lots.aggregate_only_blocked=true")) throw new Error(flags)
  if (!flags.includes("damage.stock_hold_ready=false")) throw new Error(flags)
}
ok("atomic dual-write + blocked enable")

await expectDenied("unclassified opening", () =>
  rpc(admin, "post_opening_stock", {
    target_product: unclass,
    target_crate: crate,
    carton_quantity: 1,
    idempotency_key: `${PREFIX}-un-${RUN}`,
    posting_notes: null,
    manufacturer_lot_code: "UN-1",
    manufactured_on: null,
    expiry_date: null,
  }),
)
await expectDenied("missing lot opening", () =>
  rpc(admin, "post_opening_stock", {
    target_product: exp,
    target_crate: crate,
    carton_quantity: 1,
    idempotency_key: `${PREFIX}-agg-${RUN}`,
    posting_notes: null,
  }),
)
await expectDenied("driver opening", () =>
  rpc(driver, "post_opening_stock", {
    target_product: nx,
    target_crate: crate,
    carton_quantity: 1,
    idempotency_key: `${PREFIX}-drv-open-${RUN}`,
    posting_notes: null,
    manufacturer_lot_code: "NX-DRV",
    manufactured_on: null,
    expiry_date: null,
  }),
)
await expectDenied("cross-godown crate", () =>
  rpc(godown, "post_opening_stock", {
    target_product: exp,
    target_crate: crateX,
    carton_quantity: 1,
    idempotency_key: `${PREFIX}-xcrate-${RUN}`,
    posting_notes: null,
    manufacturer_lot_code: "X-LOT",
    manufactured_on: null,
    expiry_date: "2028-01-01",
  }),
)
ok("fail-closed unclassified, missing lot, unauthorized, and cross-godown writes")

await rpc(admin, "post_opening_stock", {
  target_product: exp, target_crate: crate2, carton_quantity: 4,
  idempotency_key: `${PREFIX}-open-late-${RUN}`, posting_notes: null,
  manufacturer_lot_code: "BATCH-LATE", manufactured_on: null, expiry_date: "2028-12-01",
})
await rpc(admin, "post_opening_stock", {
  target_product: exp, target_crate: crate, carton_quantity: 4,
  idempotency_key: `${PREFIX}-open-early-${RUN}`, posting_notes: null,
  manufacturer_lot_code: "BATCH-EARLY", manufactured_on: null, expiry_date: "2027-01-15",
})
await rpc(admin, "post_opening_stock", {
  target_product: nx, target_crate: crate, carton_quantity: 3,
  idempotency_key: `${PREFIX}-open-old-${RUN}`, posting_notes: null,
  manufacturer_lot_code: "NX-OLD", manufactured_on: null, expiry_date: null,
})
await rpc(admin, "post_opening_stock", {
  target_product: nx, target_crate: crate2, carton_quantity: 3,
  idempotency_key: `${PREFIX}-open-new-${RUN}`, posting_notes: null,
  manufacturer_lot_code: "NX-NEW", manufactured_on: null, expiry_date: null,
})
ok("lot-aware openings")

const replayOpen = await rpc(admin, "post_opening_stock", {
  target_product: exp, target_crate: crate, carton_quantity: 4,
  idempotency_key: `${PREFIX}-open-early-${RUN}`, posting_notes: null,
  manufacturer_lot_code: "BATCH-EARLY", manufactured_on: null, expiry_date: "2027-01-15",
})
if (!replayOpen?.id) throw new Error("idempotent opening replay missing id")
ok("duplicate opening idempotent")

const qty = await psql(`
  select coalesce(sum(quantity),0) from public.stock_balances
  where product_id in ('${exp}','${nx}')
`)
const lotQty = await psql(`
  select coalesce(sum(lb.quantity),0)
  from public.stock_lot_balances lb
  join public.stock_lots l on l.id = lb.lot_id
  where l.product_id in ('${exp}','${nx}')
`)
if (qty.trim() !== "14" || lotQty.trim() !== "14") {
  throw new Error(`opening oracle agg=${qty} lot=${lotQty}`)
}
ok("aggregate/lot reconcile after opening 14")

async function handshake(orderId, prefix) {
  const dn = await rpc(accounts, "create_delivery_note", {
    target_order: orderId, idempotency_key: `${prefix}-dn`,
  })
  await rpc(accounts, "generate_delivery_note", {
    target_note: dn.delivery_note.id, expected_version: 1, idempotency_key: `${prefix}-gen`,
  })
  await rpc(accounts, "send_delivery_note", {
    target_note: dn.delivery_note.id, expected_version: 2, idempotency_key: `${prefix}-send`,
  })
  await rpc(godown, "acknowledge_delivery_note", {
    target_note: dn.delivery_note.id, expected_version: 3, idempotency_key: `${prefix}-ack`,
  })
}

async function pickAll(orderId, prefix, orderVersion) {
  const reserved = await rpc(godown, "reserve_order_allocation", {
    target_order: orderId, expected_order_version: orderVersion, idempotency_key: `${prefix}-res`,
  })
  let picking = await rpc(godown, "assign_picking_request", {
    target_request: reserved.id, assignee: users.keeper,
    expected_version: reserved.version, idempotency_key: `${prefix}-asg`,
  })
  picking = await rpc(godown, "start_picking", {
    target_request: reserved.id, expected_version: picking.version, idempotency_key: `${prefix}-start`,
  })
  for (const row of picking.reservations) {
    picking = await rpc(keeper, "confirm_picking_quantity", {
      target_request: reserved.id, target_reservation: row.id,
      picked_quantity: row.reserved_cases, expected_version: picking.version,
      idempotency_key: `${prefix}-pick-${row.id}`.slice(0, 80),
    })
  }
  picking = await rpc(keeper, "complete_picking", {
    target_request: reserved.id, expected_version: picking.version, idempotency_key: `${prefix}-done`,
  })
  return rpc(godown, "confirm_picking_handoff", {
    target_request: reserved.id, expected_version: picking.version, idempotency_key: `${prefix}-ho`,
  })
}

const created = await rpc(accounts, "create_order", {
  target_shop: shop, target_branch: branch, order_source: "accounts",
  source_reference: null, order_notes: null,
  order_lines: [
    { product_id: exp, requested_cases: 5 },
    { product_id: nx, requested_cases: 2 },
  ],
  idempotency_key: `${PREFIX}-ord-${RUN}`,
})
await rpc(accounts, "submit_order", {
  target_order: created.order.id, expected_version: created.order.version,
  idempotency_key: `${PREFIX}-sub-${RUN}`,
})
await rpc(accounts, "verify_order", {
  target_order: created.order.id, expected_version: created.order.version + 1,
  idempotency_key: `${PREFIX}-ver-${RUN}`,
})
await handshake(created.order.id, `${PREFIX}-hs-${RUN}`)
const preview = await rpc(godown, "preview_order_allocation", { target_order: created.order.id })
if (!preview.eligible) throw new Error(`picking ineligible ${JSON.stringify(preview.blockers)}`)
for (const line of preview.lines ?? []) {
  const first = line.slices?.[0]?.manufacturer_lot_code
  if (line.expiry_policy === "expiry_controlled" && first !== "BATCH-EARLY") {
    throw new Error(`FEFO expected BATCH-EARLY got ${first}`)
  }
  if (line.expiry_policy === "non_expiring" && first !== "NX-OLD") {
    throw new Error(`FIFO expected NX-OLD got ${first}`)
  }
}
ok("FEFO/FIFO preview")

await expectDenied("peer godown preview", () =>
  rpc(other, "preview_order_allocation", { target_order: created.order.id }),
)
ok("cross-godown picking denied")

const picking = await pickAll(created.order.id, `${PREFIX}-pk-${RUN}`, created.order.version + 2)

await expectDenied("keeper prepare dispatch", () =>
  rpc(keeper, "prepare_dispatch", {
    target_order: created.order.id,
    expected_picking_version: picking.version,
    idempotency_key: `${PREFIX}-bad-${RUN}`,
  }),
)
ok("store keeper cannot prepare dispatch")

const dispPreview = await rpc(godown, "preview_dispatch", { target_order: created.order.id })
let header = await rpc(godown, "prepare_dispatch", {
  target_order: created.order.id,
  expected_picking_version: dispPreview.picking_version ?? picking.version,
  idempotency_key: `${PREFIX}-prep-${RUN}`,
})
header = await rpc(godown, "confirm_dispatch", {
  target_dispatch: header.id, expected_version: header.version,
  idempotency_key: `${PREFIX}-cfm-${RUN}`,
})
if (!header.stock_consumed) throw new Error("confirm did not consume")
const replay = await rpc(godown, "confirm_dispatch", {
  target_dispatch: header.id, expected_version: header.version,
  idempotency_key: `${PREFIX}-cfm-${RUN}`,
})
if (replay.posted_transaction_id !== header.posted_transaction_id) {
  throw new Error("duplicate confirm posted a second ledger")
}
ok("dispatch consume and idempotent replay")

const vehicleId = await rpc(godown, "create_vehicle", {
  target_branch: header.branch_id,
  registration_number: `KL81${RUN}`.slice(0, 12),
  vehicle_type: "van",
  display_name: `${PREFIX} van`,
  capacity_cases: 20,
  operational_notes: null,
})
header = await rpc(godown, "assign_dispatch_delivery", {
  target_dispatch: header.id, assignee: users.driver, target_vehicle: vehicleId,
  expected_version: header.version, idempotency_key: `${PREFIX}-drv-${RUN}`,
})
header = await rpc(driver, "start_dispatch_delivery", {
  target_dispatch: header.id, expected_version: header.version,
  idempotency_key: `${PREFIX}-go-${RUN}`,
})
header = await rpc(driver, "acknowledge_dispatch_delivery", {
  target_dispatch: header.id, recipient_name: "Shop owner", acknowledgement_notes: "received",
  expected_version: header.version, idempotency_key: `${PREFIX}-pod-${RUN}`,
})
if (header.status !== "delivered") throw new Error(`POD ${header.status}`)
ok("proof of delivery")

const createdRet = await rpc(accounts, "create_order", {
  target_shop: shop, target_branch: branch, order_source: "accounts",
  source_reference: null, order_notes: null,
  order_lines: [{ product_id: exp, requested_cases: 2 }],
  idempotency_key: `${PREFIX}-ordr-${RUN}`,
})
await rpc(accounts, "submit_order", {
  target_order: createdRet.order.id, expected_version: createdRet.order.version,
  idempotency_key: `${PREFIX}-subr-${RUN}`,
})
await rpc(accounts, "verify_order", {
  target_order: createdRet.order.id, expected_version: createdRet.order.version + 1,
  idempotency_key: `${PREFIX}-verr-${RUN}`,
})
await handshake(createdRet.order.id, `${PREFIX}-hsr-${RUN}`)
const pickingRet = await pickAll(createdRet.order.id, `${PREFIX}-pkr-${RUN}`, createdRet.order.version + 2)
const prevRet = await rpc(godown, "preview_dispatch", { target_order: createdRet.order.id })
let retHeader = await rpc(godown, "prepare_dispatch", {
  target_order: createdRet.order.id,
  expected_picking_version: prevRet.picking_version ?? pickingRet.version,
  idempotency_key: `${PREFIX}-prepr-${RUN}`,
})
retHeader = await rpc(godown, "confirm_dispatch", {
  target_dispatch: retHeader.id, expected_version: retHeader.version,
  idempotency_key: `${PREFIX}-cfmr-${RUN}`,
})
retHeader = await rpc(godown, "assign_dispatch_delivery", {
  target_dispatch: retHeader.id, assignee: users.driver, target_vehicle: vehicleId,
  expected_version: retHeader.version, idempotency_key: `${PREFIX}-asgr-${RUN}`,
})
retHeader = await rpc(godown, "report_dispatch_delivery_exception", {
  target_dispatch: retHeader.id, exception_reason: "shop closed",
  expected_version: retHeader.version, idempotency_key: `${PREFIX}-exc-${RUN}`,
})
if (!retHeader.return_id) throw new Error("exception must open a return")
ok("failed delivery opens return")

let ret = await rpc(driver, "declare_delivery_return_handback", {
  target_return: retHeader.return_id,
  declared_returned_cases: 2,
  handback_notes: "physical cartons",
  expected_version: retHeader.return_version ?? 1,
  idempotency_key: `${PREFIX}-hb-${RUN}`,
})
const lotId = ret.lots?.[0]?.id
if (!lotId) throw new Error("return has no lot rows before count")
ret = await rpc(keeper, "count_delivery_return", {
  target_return: ret.id,
  lot_counts: [{
    id: lotId, delivered_cases: 0, saleable_cases: 2, damaged_cases: 0,
    uncertain_cases: 0, missing_cases: 0, receiving_crate_id: crate,
  }],
  expected_version: ret.version, idempotency_key: `${PREFIX}-count-${RUN}`,
})
ret = await rpc(godown, "approve_delivery_return", {
  target_return: ret.id, expected_version: ret.version, idempotency_key: `${PREFIX}-ap-${RUN}`,
})
const before = Number(await psql(`select coalesce(sum(quantity),0) from public.stock_balances where product_id='${exp}'`))
ret = await rpc(godown, "post_delivery_return", {
  target_return: ret.id, expected_version: ret.version, idempotency_key: `${PREFIX}-post-${RUN}`,
})
if (ret.status !== "posted") throw new Error(`return ${ret.status}`)
const after = Number(await psql(`select coalesce(sum(quantity),0) from public.stock_balances where product_id='${exp}'`))
if (after !== before + 2) throw new Error(`return credit ${before} -> ${after}`)
const dup = await rpc(godown, "post_delivery_return", {
  target_return: ret.id, expected_version: ret.version, idempotency_key: `${PREFIX}-post-${RUN}`,
})
const afterDup = Number(await psql(`select coalesce(sum(quantity),0) from public.stock_balances where product_id='${exp}'`))
if (afterDup !== after) throw new Error("duplicate return mutated stock")
if (!dup.lots?.length && !(ret.lots?.length)) throw new Error("posted return missing lots")
ok("lot-aware return post, lots present, duplicate is idempotent")

const finalAgg = await psql("select coalesce(sum(quantity),0) from public.stock_balances")
const finalLot = await psql("select coalesce(sum(quantity),0) from public.stock_lot_balances")
if (finalAgg.trim() !== finalLot.trim()) {
  throw new Error(`final mismatch agg=${finalAgg} lot=${finalLot}`)
}
ok(`final aggregate/lot ${finalAgg.trim()}`)

console.log(`M8.1C HTTP passed ${passed.length} checks`)
