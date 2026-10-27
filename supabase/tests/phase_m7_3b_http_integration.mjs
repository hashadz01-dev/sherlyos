/**
 * M7.3B local HTTP proofs against 127.0.0.1:54321 only.
 * Replica-enables dual-write for disposable m73b fixtures, then restores flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m73b"
const PREFIX = "m73bhttp"
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M73B Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M73B Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M73B Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M73B Keeper"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M73B Admin', true),
    ('${users.accounts}', 'M73B Accounts', true),
    ('${users.godown}', 'M73B Godown', true),
    ('${users.keeper}', 'M73B Keeper', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", { branch_code: `${PREFIX}_${RUN}`, branch_name: "M73B QA" })
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
const zone = await rpc(admin, "create_zone", {
  target_branch: branch, zone_code: `${PREFIX}_z_${RUN}`, zone_name: "Z", zone_description: null,
})
const crate = await rpc(admin, "create_crate", {
  target_zone: zone, crate_code: `${PREFIX}_c_${RUN}`, crate_name: "C", crate_description: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`, product_name: "M73B Soap", next_supplier: null, next_category: null,
})
await rpc(admin, "set_product_expiry_policy", { target_product: product, new_policy: "non_expiring" })
const shop = await rpc(admin, "create_shop", {
  shop_name: `M73B shop ${RUN}`, shop_phone: null, shop_address: null,
})

try {
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
      '${product}'::uuid, '${crate}'::uuid, 6, '${PREFIX}-open-${RUN}', null, 'M73B-HTTP', null, null
    );
    commit;
  `)

  const created = await rpc(accounts, "create_order", {
    target_shop: shop,
    target_branch: branch,
    order_source: "accounts",
    source_reference: null,
    order_notes: null,
    order_lines: [{ product_id: product, requested_cases: 2 }],
    idempotency_key: `${PREFIX}-ord-${RUN}`,
  })
  await rpc(accounts, "submit_order", {
    target_order: created.order.id,
    expected_version: 1,
    idempotency_key: `${PREFIX}-sub-${RUN}`,
  })
  const verified = await rpc(accounts, "verify_order", {
    target_order: created.order.id,
    expected_version: 2,
    idempotency_key: `${PREFIX}-ver-${RUN}`,
  })
  const dn = await rpc(accounts, "create_delivery_note", {
    target_order: created.order.id,
    idempotency_key: `${PREFIX}-dn-${RUN}`,
  })
  await rpc(accounts, "generate_delivery_note", {
    target_note: dn.delivery_note.id, expected_version: 1, idempotency_key: `${PREFIX}-gen-${RUN}`,
  })
  await rpc(accounts, "send_delivery_note", {
    target_note: dn.delivery_note.id, expected_version: 2, idempotency_key: `${PREFIX}-send-${RUN}`,
  })
  await rpc(godown, "acknowledge_delivery_note", {
    target_note: dn.delivery_note.id, expected_version: 3, idempotency_key: `${PREFIX}-ack-${RUN}`,
  })

  const reserved = await rpc(godown, "reserve_order_allocation", {
    target_order: created.order.id,
    expected_order_version: verified.order.version,
    idempotency_key: `${PREFIX}-res-${RUN}`,
  })
  let header = await rpc(godown, "assign_picking_request", {
    target_request: reserved.id,
    assignee: users.keeper,
    expected_version: reserved.version,
    idempotency_key: `${PREFIX}-asg-${RUN}`,
  })
  header = await rpc(keeper, "start_picking", {
    target_request: reserved.id,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-start-${RUN}`,
  })
  const reservation = header.reservations[0]
  header = await rpc(keeper, "confirm_picking_quantity", {
    target_request: reserved.id,
    target_reservation: reservation.id,
    picked_quantity: 1,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-pick-${RUN}`,
  })
  header = await rpc(keeper, "report_picking_shortage", {
    target_request: reserved.id,
    target_reservation: reservation.id,
    short_quantity: 1,
    shortage_note: "one missing",
    expected_version: header.version,
    idempotency_key: `${PREFIX}-short-${RUN}`,
  })
  header = await rpc(keeper, "complete_picking", {
    target_request: reserved.id,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-complete-${RUN}`,
  })

  try {
    await rpc(accounts, "create_short_shipment", {
      target_request: reserved.id,
      expected_picking_version: header.version,
      idempotency_key: `${PREFIX}-sh-acc-${RUN}`,
    })
    throw new Error("Accounts must not create short-shipment")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("Accounts cannot create short-shipment")

  try {
    await rpc(godown, "approve_short_shipment", {
      target_shipment: "00000000-0000-0000-0000-000000000000",
      expected_version: 1,
      lot_quantities: null,
      idempotency_key: `${PREFIX}-sh-gm-ap-${RUN}`,
    })
    throw new Error("GM must not approve")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("GM cannot Accounts-approve")

  let shipment = await rpc(godown, "create_short_shipment", {
    target_request: reserved.id,
    expected_picking_version: header.version,
    idempotency_key: `${PREFIX}-sh-create-${RUN}`,
  })
  try {
    await rpc(accounts, "confirm_short_shipment_quantities", {
      target_shipment: shipment.id,
      expected_version: shipment.version,
      idempotency_key: `${PREFIX}-sh-acc-gm-${RUN}`,
    })
    throw new Error("Accounts must not GM-confirm")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("Accounts cannot GM-confirm")

  shipment = await rpc(godown, "confirm_short_shipment_quantities", {
    target_shipment: shipment.id,
    expected_version: shipment.version,
    idempotency_key: `${PREFIX}-sh-gm-${RUN}`,
  })
  shipment = await rpc(accounts, "approve_short_shipment", {
    target_shipment: shipment.id,
    expected_version: shipment.version,
    lot_quantities: null,
    idempotency_key: `${PREFIX}-sh-ap-${RUN}`,
  })
  if (shipment.status !== "approved" || shipment.approved_cases !== 1) {
    throw new Error(`approve failed: ${JSON.stringify(shipment)}`)
  }
  ok("GM confirm and Accounts approve over HTTP")

  header = await rpc(godown, "confirm_picking_handoff", {
    target_request: reserved.id,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-hand-${RUN}`,
  })
  let dispatch = await rpc(godown, "prepare_dispatch", {
    target_order: created.order.id,
    expected_picking_version: header.version,
    idempotency_key: `${PREFIX}-prep-${RUN}`,
  })
  dispatch = await rpc(godown, "confirm_dispatch", {
    target_dispatch: dispatch.id,
    expected_version: dispatch.version,
    idempotency_key: `${PREFIX}-cfm-${RUN}`,
  })
  if (dispatch.status !== "dispatched") throw new Error("dispatch failed")
  const replay = await rpc(godown, "confirm_dispatch", {
    target_dispatch: dispatch.id,
    expected_version: dispatch.version,
    idempotency_key: `${PREFIX}-cfm-${RUN}`,
  })
  if (replay.status !== "dispatched") throw new Error("dispatch replay failed")
  const ledger = await psql(`
    select coalesce(sum(sl.quantity), 0)
    from public.stock_ledger sl
    join public.stock_transactions st on st.id = sl.transaction_id
    where st.dispatch_request_id = '${dispatch.id}'::uuid;
  `)
  if (String(ledger).trim() !== "-1") throw new Error(`expected ledger -1, got ${ledger}`)
  const backorders = await psql(`
    select count(*) from public.orders
    where parent_order_id = '${created.order.id}'::uuid
      and status is distinct from 'cancelled';
  `)
  if (String(backorders).trim() !== "1") throw new Error(`expected 1 backorder, got ${backorders}`)
  ok("partial confirm_dispatch deducts approved lots once and links a backorder")
} finally {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    select set_config('app.shipment_write', 'on', true);
    delete from public.order_shipment_events
    where shipment_id in (
      select s.id from public.order_shipments s
      join public.orders o on o.id = s.order_id
      where o.idempotency_key like '${PREFIX}%'
    );
    delete from public.order_shipment_lots
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    delete from public.order_shipment_lines
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    delete from public.order_shipments
    where order_id in (select id from public.orders where idempotency_key like '${PREFIX}%');
    delete from public.stock_picking_exceptions
    where reservation_id in (
      select id from public.stock_reservations
      where product_id in (select id from public.products where sku like '${PREFIX}%')
    );
    delete from public.stock_reservations
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    update public.stock_picking_requests
    set status = 'cancelled', cancelled_by = created_by, cancelled_at = clock_timestamp(),
        cancellation_reason = 'm73b http cleanup'
    where order_id in (select id from public.orders where idempotency_key like '${PREFIX}%')
      and status is distinct from 'cancelled';
    delete from public.stock_ledger
    where product_id in (select id from public.products where sku like '${PREFIX}%')
      and lot_id is not null;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    );
    set session_replication_role = origin;
  `)
}

const flags = await psql(`
  select string_agg(key || '=' || value::text, ',')
  from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  );
`)
if (!flags.includes("false") || flags.includes("true")) {
  throw new Error(`flags not restored: ${flags}`)
}

console.log(`M7.3B HTTP ${passed.length}/${passed.length} passed`)
