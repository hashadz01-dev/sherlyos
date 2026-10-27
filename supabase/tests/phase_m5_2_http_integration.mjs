/**
 * M5.2 local HTTP proofs against 127.0.0.1:54321 only.
 * Dual-write is enabled for disposable fixtures and restored in finally.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m52"
const PREFIX = "m52http"
const RUN = Date.now().toString(36)

function statusEnv() {
  return new Promise((resolve, reject) => {
    const child = spawn("npx", ["supabase", "status", "-o", "env"], { shell: true })
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
        resolve(env)
      }
    })
  })
}

function psql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "docker",
      ["exec", "-i", "supabase_db_sherlyos", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"],
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
      if (code === 0) resolve(text)
      else reject(new Error(text || `psql exit ${code}`))
    })
    child.stdin.end(sql)
  })
}

function firstUuid(text) {
  return String(text).match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0] ?? ""
}

function assertLocal(url) {
  const parsed = new URL(url)
  if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") {
    throw new Error(`refusing non-local host ${parsed.hostname}`)
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
    const error = new Error(
      `${name}: ${result.error.message} [${result.error.code}] ${result.error.details || ""} ${result.error.hint || ""}`,
    )
    error.code = result.error.code
    throw error
  }
  return result.data
}

function denied(error) {
  return (
    error.code === "42501" ||
    error.code === "PGRST301" ||
    /not authorized|permission/i.test(error.message || "")
  )
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

const env = await statusEnv()
assertLocal(env.API_URL || API)
if (!env.ANON_KEY) throw new Error("local anon key missing")

await psql(`
  update auth.users
  set
    confirmation_token = coalesce(nullif(confirmation_token, ''), id::text || '-c'),
    recovery_token = coalesce(nullif(recovery_token, ''), id::text || '-r'),
    email_change_token_new = coalesce(nullif(email_change_token_new, ''), id::text || '-n'),
    email_change_token_current = coalesce(nullif(email_change_token_current, ''), id::text || '-e'),
    reauthentication_token = coalesce(nullif(reauthentication_token, ''), id::text || '-a'),
    email_change = coalesce(email_change, '');
`)

const users = {
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M52 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M52 Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M52 Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M52 Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M52 Driver"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M52 Other"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M52 Admin', true),
    ('${users.accounts}', 'M52 Accounts', true),
    ('${users.godown}', 'M52 Godown', true),
    ('${users.keeper}', 'M52 Keeper', true),
    ('${users.driver}', 'M52 Driver', true),
    ('${users.other}', 'M52 Other', true)
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

const branch = await rpc(admin, "create_branch", { branch_code: `${PREFIX}_${RUN}`, branch_name: "M52 HTTP A" })
const branchB = await rpc(admin, "create_branch", { branch_code: `${PREFIX}b_${RUN}`, branch_name: "M52 HTTP B" })
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.driver, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.other, target_branch: branchB })
const zone = await rpc(admin, "create_zone", {
  target_branch: branch, zone_code: `${PREFIX}_z_${RUN}`, zone_name: "Z", zone_description: null,
})
const crate = await rpc(admin, "create_crate", {
  target_zone: zone, crate_code: `${PREFIX}_c_${RUN}`, crate_name: "C", crate_description: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`, product_name: "M52 HTTP Soap", next_supplier: null, next_category: null,
})
await rpc(admin, "set_product_expiry_policy", {
  target_product: product, new_policy: "expiry_controlled",
})
const shop = await rpc(admin, "create_shop", {
  shop_name: `M52 shop ${RUN}`, shop_phone: null, shop_address: null,
})
const supplier = await rpc(admin, "create_supplier", {
  supplier_name: `M52 supplier ${RUN}`, supplier_phone: null, supplier_email: null,
})

await psql(`
  set session_replication_role = replica;
  update public.app_configuration set value = 'true'::jsonb
  where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
  set session_replication_role = origin;
  begin;
  set local role authenticated;
  select set_config('request.jwt.claim.sub', '${users.admin}', true);
  select set_config(
    'request.jwt.claims',
    json_build_object('sub', '${users.admin}'::uuid, 'role', 'authenticated')::text,
    true
  );
  select public.post_opening_stock(
    '${product}'::uuid, '${crate}'::uuid, 8, '${PREFIX}-open-${RUN}',
    null, 'M52-HTTP', null, '2028-06-01'
  );
  commit;
`)

const receipt = await rpc(keeper, "create_stock_receipt", {
  target_godown: branch,
  target_supplier: supplier,
  supplier_document: `M52-${RUN}`,
  received_on: new Date().toISOString().slice(0, 10),
  receipt_notes: null,
  line_items: [{
    product_id: product,
    destination_crate_id: crate,
    document_cases: 6,
    counted_cases: 5,
    damaged_cases: 2,
  }],
})
const receiptLineId = receipt.lines[0].id
await rpc(keeper, "set_stock_receipt_line_lot_attributions", {
  target_receipt_line: receiptLineId,
  attributions: [{
    carton_quantity: 3,
    manufacturer_lot_code: `${PREFIX}-lot`,
    manufactured_on: "2026-01-01",
    expiry_date: "2028-06-01",
  }],
})
await rpc(keeper, "submit_stock_receipt", { target_receipt: receipt.id })
const posted = await rpc(godown, "verify_stock_receipt", {
  target_receipt: receipt.id,
  idempotency_key: `${PREFIX}-recv-${RUN}`,
})
if (posted.lines[0].id !== receiptLineId) throw new Error("receipt line id changed after post")

const createdOrder = await rpc(accounts, "create_order", {
  target_shop: shop,
  target_branch: branch,
  order_source: "accounts",
  source_reference: null,
  order_notes: null,
  order_lines: [{ product_id: product, requested_cases: 1 }],
  idempotency_key: `${PREFIX}-ord-${RUN}`,
})
const orderId = createdOrder.order.id
await rpc(accounts, "submit_order", {
  target_order: orderId,
  expected_version: createdOrder.order.version,
  idempotency_key: `${PREFIX}-sub-${RUN}`,
})
await rpc(accounts, "verify_order", {
  target_order: orderId,
  expected_version: createdOrder.order.version + 1,
  idempotency_key: `${PREFIX}-ver-${RUN}`,
})
{
  const dn = await rpc(accounts, "create_delivery_note", {
    target_order: orderId,
    idempotency_key: `${PREFIX}-dn-${RUN}`,
  })
  await rpc(accounts, "generate_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 1,
    idempotency_key: `${PREFIX}-gen-${RUN}`,
  })
  await rpc(accounts, "send_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 2,
    idempotency_key: `${PREFIX}-send-${RUN}`,
  })
  await rpc(godown, "acknowledge_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 3,
    idempotency_key: `${PREFIX}-ack-${RUN}`,
  })
}

let reserved = await rpc(godown, "reserve_order_allocation", {
  target_order: orderId,
  expected_order_version: createdOrder.order.version + 2,
  idempotency_key: `${PREFIX}-res-${RUN}`,
})
reserved = await rpc(godown, "assign_picking_request", {
  target_request: reserved.id,
  assignee: users.keeper,
  expected_version: reserved.version,
  idempotency_key: `${PREFIX}-asg-${RUN}`,
})
reserved = await rpc(godown, "start_picking", {
  target_request: reserved.id,
  expected_version: reserved.version,
  idempotency_key: `${PREFIX}-start-${RUN}`,
})
const picking = await rpc(keeper, "get_picking_request", { target_request: reserved.id })
let header = await rpc(keeper, "confirm_picking_quantity", {
  target_request: reserved.id,
  target_reservation: picking.reservations[0].id,
  picked_quantity: picking.reservations[0].reserved_cases,
  expected_version: picking.version,
  idempotency_key: `${PREFIX}-pick-${RUN}`,
})
header = await rpc(keeper, "complete_picking", {
  target_request: reserved.id,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-cmp-${RUN}`,
})
header = await rpc(godown, "confirm_picking_handoff", {
  target_request: reserved.id,
  expected_version: header.version,
  idempotency_key: `${PREFIX}-hand-${RUN}`,
})
const prepared = await rpc(godown, "prepare_dispatch", {
  target_order: orderId,
  expected_picking_version: header.version,
  idempotency_key: `${PREFIX}-prep-${RUN}`,
})
const confirmed = await rpc(godown, "confirm_dispatch", {
  target_dispatch: prepared.id,
  expected_version: prepared.version,
  idempotency_key: `${PREFIX}-cfm-${RUN}`,
})
await rpc(godown, "assign_dispatch_delivery", {
  target_dispatch: confirmed.id,
  assignee: users.driver,
  expected_version: confirmed.version,
  idempotency_key: `${PREFIX}-assign-${RUN}`,
})

const ledgerBefore = Number(
  await psql(`select count(*) from public.stock_ledger where product_id = '${product}'::uuid`),
)

try {
  try {
    await rpc(admin, "create_damage_report", {
      scenario: "refill_supply",
      target_godown: branch,
      report_lines: [{
        product_id: product,
        quantity_cases: 1,
        damage_reason: "crushed",
        receipt_line_id: receiptLineId,
      }],
      idempotency_key: `${PREFIX}-admin-${RUN}`,
      notes: null,
      receipt_id: receipt.id,
    })
    throw new Error("admin ordinary create must fail")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("admin cannot create ordinary damage reports")

  const inbound = await rpc(keeper, "create_damage_report", {
    scenario: "refill_supply",
    target_godown: branch,
    report_lines: [{
      product_id: product,
      quantity_cases: 1,
      damage_reason: "crushed",
      receipt_line_id: receiptLineId,
    }],
    idempotency_key: `${PREFIX}-in-${RUN}`,
    notes: null,
    receipt_id: receipt.id,
  })
  const submitted = await rpc(keeper, "submit_damage_report", {
    target_report: inbound.id,
    expected_version: inbound.version,
    idempotency_key: `${PREFIX}-insub-${RUN}`,
  })
  if (submitted.status !== "submitted") throw new Error("inbound submit should proceed without a hold")
  ok("inbound damaged goods can submit without stock mutation")

  try {
    await rpc(godown, "verify_damage_report", {
      target_report: submitted.id,
      expected_version: submitted.version,
    })
    throw new Error("verify without evidence must fail")
  } catch (error) {
    if (!/photographic evidence/i.test(error.message || "")) throw error
  }
  ok("verification fails closed without finalized evidence")

  try {
    await rpc(godown, "create_damage_report", {
      scenario: "storage",
      target_godown: branch,
      report_lines: [{
        product_id: product,
        crate_id: crate,
        quantity_cases: 1,
        damage_reason: "rodent",
      }],
      idempotency_key: `${PREFIX}-st-${RUN}`,
    }).then(async (draft) => {
      await rpc(godown, "submit_damage_report", {
        target_report: draft.id,
        expected_version: draft.version,
        idempotency_key: `${PREFIX}-stsub-${RUN}`,
      })
    })
    throw new Error("storage submit must stay gated")
  } catch (error) {
    if (!/stock isolation is not ready/i.test(error.message || "")) throw error
  }
  ok("on-hand submit is blocked while the hold flag is false")

  const transit = await rpc(driver, "create_damage_report", {
    scenario: "transit",
    target_godown: branch,
    report_lines: [{
      product_id: product,
      quantity_cases: 1,
      damage_reason: "road",
    }],
    idempotency_key: `${PREFIX}-tr-${RUN}`,
    notes: null,
    receipt_id: null,
    picking_request_id: null,
    dispatch_id: confirmed.id,
  })
  const transitSubmitted = await rpc(driver, "submit_damage_report", {
    target_report: transit.id,
    expected_version: transit.version,
    idempotency_key: `${PREFIX}-trsub-${RUN}`,
  })
  if (transitSubmitted.status !== "submitted") throw new Error("assigned driver transit submit failed")
  ok("assigned driver can report transit damage for the assigned dispatch")

  try {
    await rpc(other, "create_damage_report", {
      scenario: "transit",
      target_godown: branch,
      report_lines: [{
        product_id: product,
        quantity_cases: 1,
        damage_reason: "road",
      }],
      idempotency_key: `${PREFIX}-cross-${RUN}`,
      notes: null,
      receipt_id: null,
      picking_request_id: null,
      dispatch_id: confirmed.id,
    })
    throw new Error("cross-branch transit must fail")
  } catch (error) {
    if (!denied(error) && !/duplicate|unique/i.test(error.message || "")) throw error
    if (/duplicate|unique/i.test(error.message || "")) {
      throw new Error("cross-branch caller must be denied before duplicate detection")
    }
  }
  ok("cross-branch transit reporting is denied")

  await rpc(admin, "set_branch_active", { target_branch: branch, active: false })
  try {
    await rpc(godown, "create_damage_report", {
      scenario: "storage",
      target_godown: branch,
      report_lines: [{
        product_id: product,
        crate_id: crate,
        quantity_cases: 1,
        damage_reason: "rodent",
      }],
      idempotency_key: `${PREFIX}-inact-${RUN}`,
    })
    throw new Error("inactive storage create must fail")
  } catch (error) {
    if (!denied(error) && !/inactive/i.test(error.message || "")) throw error
  }
  ok("inactive godown denies new operational damage writes")
  await rpc(admin, "set_branch_active", { target_branch: branch, active: true })

  const ledgerAfter = Number(
    await psql(`select count(*) from public.stock_ledger where product_id = '${product}'::uuid`),
  )
  if (ledgerAfter !== ledgerBefore) {
    throw new Error(`damage HTTP mutated ledger ${ledgerBefore} -> ${ledgerAfter}`)
  }
  const holdReady = await psql(
    `select value #>> '{}' from public.app_configuration where key = 'damage.stock_hold_ready'`,
  )
  if (holdReady.trim() !== "false") throw new Error("damage.stock_hold_ready must stay false")
  ok("damage HTTP did not mutate stock or enable the hold gate")
} finally {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    select set_config('app.dispatch_write', 'on', true);
    update public.stock_reservations set status = 'released'
    where product_id = '${product}'::uuid;
    update public.stock_picking_requests
    set status = 'cancelled', cancelled_by = created_by, cancelled_at = clock_timestamp(),
        cancellation_reason = 'm52 http cleanup'
    where order_id = '${orderId}'
      and status is distinct from 'cancelled';
    update public.stock_ledger set lot_id = null where product_id = '${product}'::uuid;
    delete from public.stock_balances where product_id = '${product}'::uuid;
    delete from public.stock_lot_balances
    where lot_id in (select id from public.stock_lots where product_id = '${product}'::uuid);
    delete from public.stock_lots where product_id = '${product}'::uuid;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;
  `)
}

console.log(`M5.2 HTTP passed ${passed.length} checks`)
