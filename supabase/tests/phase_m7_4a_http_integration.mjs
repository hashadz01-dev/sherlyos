/**
 * M7.4A local HTTP proofs against 127.0.0.1:54321 only.
 * Replica-enables dual-write for disposable fixtures, then restores flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m74a"
const PREFIX = "m74ahttp"
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
    const error = new Error(result.error.message)
    error.code = result.error.code
    throw error
  }
  return result.data
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
    email_change = coalesce(email_change, ''),
    phone_change = coalesce(phone_change, ''),
    phone_change_token = coalesce(phone_change_token, '');
`)

const users = {
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M74A Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M74A Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M74A Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M74A Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M74A Driver"),
  driver2: await ensureUser(`driver2.${PREFIX}@example.com`, "M74A Driver2"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M74A Admin', true),
    ('${users.accounts}', 'M74A Accounts', true),
    ('${users.godown}', 'M74A Godown', true),
    ('${users.keeper}', 'M74A Keeper', true),
    ('${users.driver}', 'M74A Driver', true),
    ('${users.driver2}', 'M74A Driver2', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person'),
    ('${users.driver2}'::uuid, 'delivery_person')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)
const driver2 = await signIn(env.ANON_KEY, `driver2.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M74A QA",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.driver, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.driver2, target_branch: branch })
const zone = await rpc(admin, "create_zone", {
  target_branch: branch,
  zone_code: `${PREFIX}_z_${RUN}`,
  zone_name: "Z",
  zone_description: null,
})
const crate = await rpc(admin, "create_crate", {
  target_zone: zone,
  crate_code: `${PREFIX}_c_${RUN}`,
  crate_name: "C",
  crate_description: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`,
  product_name: "M74A Soap",
  next_supplier: null,
  next_category: null,
})
await rpc(admin, "set_product_expiry_policy", {
  target_product: product,
  new_policy: "expiry_controlled",
})
const shop = await rpc(admin, "create_shop", {
  shop_name: `M74A shop ${RUN}`,
  shop_phone: null,
  shop_address: null,
})

try {
  await rpc(keeper, "create_vehicle", {
    target_branch: branch,
    registration_number: `KL07${RUN}K`,
    vehicle_type: "van",
    display_name: "Keeper van",
    capacity_cases: null,
    operational_notes: null,
  })
  throw new Error("store keeper must not create vehicles")
} catch (error) {
  if (!/not authorized/i.test(error.message)) throw error
}
ok("unauthorized vehicle creation denied")

const vehicleId = await rpc(godown, "create_vehicle", {
  target_branch: branch,
  registration_number: `KL07${RUN}`,
  vehicle_type: "van",
  display_name: `${PREFIX} van`,
  capacity_cases: 12,
  operational_notes: "informational capacity",
})
if (!vehicleId) throw new Error("create_vehicle returned no id")
ok("godown manager creates vehicle")

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
    null, 'M74A-HTTP', null, '2028-06-01'
  );
  commit;
`)

async function handshake(orderId, prefix) {
  const dn = await rpc(accounts, "create_delivery_note", {
    target_order: orderId,
    idempotency_key: `${prefix}-dn`,
  })
  await rpc(accounts, "generate_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 1,
    idempotency_key: `${prefix}-gen`,
  })
  await rpc(accounts, "send_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 2,
    idempotency_key: `${prefix}-send`,
  })
  await rpc(godown, "acknowledge_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 3,
    idempotency_key: `${prefix}-ack`,
  })
}

async function pickAll(orderId, prefix, expectedOrderVersion) {
  const reserved = await rpc(godown, "reserve_order_allocation", {
    target_order: orderId,
    expected_order_version: expectedOrderVersion,
    idempotency_key: `${prefix}-res`,
  })
  let picking = await rpc(godown, "assign_picking_request", {
    target_request: reserved.id,
    assignee: users.keeper,
    expected_version: reserved.version,
    idempotency_key: `${prefix}-asg`,
  })
  picking = await rpc(godown, "start_picking", {
    target_request: reserved.id,
    expected_version: picking.version,
    idempotency_key: `${prefix}-start`,
  })
  for (const row of picking.reservations) {
    picking = await rpc(keeper, "confirm_picking_quantity", {
      target_request: reserved.id,
      target_reservation: row.id,
      picked_quantity: row.reserved_cases,
      expected_version: picking.version,
      idempotency_key: `${prefix}-pick-${row.id}`,
    })
  }
  picking = await rpc(keeper, "complete_picking", {
    target_request: reserved.id,
    expected_version: picking.version,
    idempotency_key: `${prefix}-done`,
  })
  picking = await rpc(godown, "confirm_picking_handoff", {
    target_request: reserved.id,
    expected_version: picking.version,
    idempotency_key: `${prefix}-ho`,
  })
  return picking
}

try {
  const created = await rpc(accounts, "create_order", {
    target_shop: shop,
    target_branch: branch,
    order_source: "accounts",
    source_reference: null,
    order_notes: null,
    order_lines: [{ product_id: product, requested_cases: 2 }],
    idempotency_key: `${PREFIX}-ord-${RUN}`,
  })
  const orderId = created.order.id
  await rpc(accounts, "submit_order", {
    target_order: orderId,
    expected_version: created.order.version,
    idempotency_key: `${PREFIX}-sub-${RUN}`,
  })
  await rpc(accounts, "verify_order", {
    target_order: orderId,
    expected_version: created.order.version + 1,
    idempotency_key: `${PREFIX}-ver-${RUN}`,
  })
  await handshake(orderId, `${PREFIX}-${RUN}`)
  const picking = await pickAll(orderId, `${PREFIX}-${RUN}`, created.order.version + 2)
  const prepared = await rpc(godown, "prepare_dispatch", {
    target_order: orderId,
    expected_picking_version: picking.version,
    idempotency_key: `${PREFIX}-prep-${RUN}`,
  })
  const confirmed = await rpc(godown, "confirm_dispatch", {
    target_dispatch: prepared.id,
    expected_version: prepared.version,
    idempotency_key: `${PREFIX}-cfm-${RUN}`,
  })
  const assigned = await rpc(godown, "assign_dispatch_delivery", {
    target_dispatch: confirmed.id,
    assignee: users.driver,
    target_vehicle: vehicleId,
    expected_version: confirmed.version,
    idempotency_key: `${PREFIX}-drv-${RUN}`,
  })
  if (assigned.vehicle_id !== vehicleId) throw new Error("vehicle assignment missing")
  ok("vehicle and driver assigned")

  try {
    await rpc(driver2, "start_dispatch_delivery", {
      target_dispatch: confirmed.id,
      expected_version: assigned.version,
      idempotency_key: `${PREFIX}-go-other-${RUN}`,
    })
    throw new Error("other driver must not start")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("other driver cannot start")

  const started = await rpc(driver, "start_dispatch_delivery", {
    target_dispatch: confirmed.id,
    expected_version: assigned.version,
    idempotency_key: `${PREFIX}-go-${RUN}`,
  })
  if (started.status !== "in_transit") throw new Error("start delivery failed")
  ok("delivery in transit")

  try {
    await rpc(driver2, "acknowledge_dispatch_delivery", {
      target_dispatch: confirmed.id,
      recipient_name: "Forged",
      acknowledgement_notes: null,
      expected_version: started.version,
      idempotency_key: `${PREFIX}-pod-forged-${RUN}`,
    })
    throw new Error("forged POD must fail")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("forged POD denied")

  const txnBefore = Number(
    await psql(
      `select count(*) from public.stock_transactions where product_id = '${product}'::uuid and transaction_type = 'DISPATCH'`,
    ),
  )
  const pod = await rpc(driver, "acknowledge_dispatch_delivery", {
    target_dispatch: confirmed.id,
    recipient_name: "Shop owner",
    acknowledgement_notes: "received",
    proof_reference: `POD-${RUN}`,
    expected_version: started.version,
    idempotency_key: `${PREFIX}-pod-${RUN}`,
  })
  if (pod.status !== "delivered" || pod.proof_reference !== `POD-${RUN}`) {
    throw new Error("POD failed")
  }
  const txnAfter = Number(
    await psql(
      `select count(*) from public.stock_transactions where product_id = '${product}'::uuid and transaction_type = 'DISPATCH'`,
    ),
  )
  if (txnAfter !== txnBefore) throw new Error("POD wrote stock")
  ok("proof of delivery metadata without stock write")

  const createdFail = await rpc(accounts, "create_order", {
    target_shop: shop,
    target_branch: branch,
    order_source: "accounts",
    source_reference: null,
    order_notes: null,
    order_lines: [{ product_id: product, requested_cases: 2 }],
    idempotency_key: `${PREFIX}-ord-part-${RUN}`,
  })
  await rpc(accounts, "submit_order", {
    target_order: createdFail.order.id,
    expected_version: createdFail.order.version,
    idempotency_key: `${PREFIX}-sub-part-${RUN}`,
  })
  await rpc(accounts, "verify_order", {
    target_order: createdFail.order.id,
    expected_version: createdFail.order.version + 1,
    idempotency_key: `${PREFIX}-ver-part-${RUN}`,
  })
  await handshake(createdFail.order.id, `${PREFIX}-part-${RUN}`)
  const pickingPart = await pickAll(
    createdFail.order.id,
    `${PREFIX}-part-${RUN}`,
    createdFail.order.version + 2,
  )
  const preparedPart = await rpc(godown, "prepare_dispatch", {
    target_order: createdFail.order.id,
    expected_picking_version: pickingPart.version,
    idempotency_key: `${PREFIX}-prep-part-${RUN}`,
  })
  const confirmedPart = await rpc(godown, "confirm_dispatch", {
    target_dispatch: preparedPart.id,
    expected_version: preparedPart.version,
    idempotency_key: `${PREFIX}-cfm-part-${RUN}`,
  })
  const assignedPart = await rpc(godown, "assign_dispatch_delivery", {
    target_dispatch: confirmedPart.id,
    assignee: users.driver,
    target_vehicle: vehicleId,
    expected_version: confirmedPart.version,
    idempotency_key: `${PREFIX}-asg-part-${RUN}`,
  })
  const startedPart = await rpc(driver, "start_dispatch_delivery", {
    target_dispatch: confirmedPart.id,
    expected_version: assignedPart.version,
    idempotency_key: `${PREFIX}-go-part-${RUN}`,
  })
  const line = startedPart.delivery_lines?.[0]
  if (!line?.order_line_id) throw new Error("delivery lines missing")
  try {
    await rpc(driver, "record_partial_dispatch_delivery", {
      target_dispatch: confirmedPart.id,
      delivered_lines: [{ order_line_id: line.order_line_id, delivered_cases: 99 }],
      exception_reason: "too many",
      expected_version: startedPart.version,
      idempotency_key: `${PREFIX}-part-bad-${RUN}`,
    })
    throw new Error("over-delivered quantity must fail")
  } catch (error) {
    if (!/exceed|invalid|partial/i.test(error.message)) throw error
  }
  ok("invalid delivered quantity denied")

  const partial = await rpc(driver, "record_partial_dispatch_delivery", {
    target_dispatch: confirmedPart.id,
    delivered_lines: [{ order_line_id: line.order_line_id, delivered_cases: 1 }],
    exception_reason: "shop took one case",
    expected_version: startedPart.version,
    idempotency_key: `${PREFIX}-part-ok-${RUN}`,
  })
  if (partial.delivery_outcome !== "partial" || partial.return_required !== true) {
    throw new Error("partial outcome missing")
  }
  ok("partial delivery records undelivered without restock")
} finally {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    select set_config('app.dispatch_write', 'on', true);
    update public.stock_reservations set status = 'released'
    where product_id = '${product}'::uuid and status = 'active';
    update public.stock_ledger
    set lot_id = null
    where product_id = '${product}'::uuid;
    delete from public.stock_balances where product_id = '${product}'::uuid;
    delete from public.stock_lot_balances
    where lot_id in (select id from public.stock_lots where product_id = '${product}'::uuid);
    delete from public.stock_lots where product_id = '${product}'::uuid;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)
}

console.log(`M7.4A HTTP passed ${passed.length} checks`)
