/**
 * M2 local HTTP integration. 127.0.0.1:54321 only.
 * Enables dual-write only for disposable m2qa fixtures, then replica-cleans flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m2qa"
const PREFIX = "m2qa"
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M2 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M2 Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M2 Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M2 Keeper"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M2 Admin', true),
    ('${users.accounts}', 'M2 Accounts', true),
    ('${users.godown}', 'M2 Godown', true),
    ('${users.keeper}', 'M2 Keeper', true)
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

const branch = await rpc(admin, "create_branch", { branch_code: `${PREFIX}_${RUN}`, branch_name: "M2 QA" })
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
  product_sku: `${PREFIX}-${RUN}`, product_name: "M2 Soap", next_supplier: null, next_category: null,
})
await rpc(admin, "set_product_expiry_policy", {
  target_product: product, new_policy: "expiry_controlled",
})
const shop = await rpc(admin, "create_shop", {
  shop_name: `M2 shop ${RUN}`, shop_phone: null, shop_address: null,
})

await psql(`
  update public.app_configuration set value = 'true'::jsonb where key = 'stock.lots.aggregate_only_blocked';
  update public.app_configuration set value = 'true'::jsonb where key = 'stock.lots.dual_write_enabled';
  begin;
  set local role authenticated;
  select set_config('request.jwt.claim.sub', '${users.admin}', true);
  select set_config(
    'request.jwt.claims',
    json_build_object('sub', '${users.admin}'::uuid, 'role', 'authenticated')::text,
    true
  );
  select public.post_opening_stock(
    '${product}'::uuid,
    '${crate}'::uuid,
    6,
    '${PREFIX}-open-${RUN}',
    null,
    'M2-HTTP',
    null,
    '2028-06-01'
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

try {
  try {
    await rpc(keeper, "preview_order_allocation", { target_order: orderId })
    throw new Error("store keeper must not preview")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("store keeper cannot preview")

  try {
    await rpc(accounts, "reserve_order_allocation", {
      target_order: orderId,
      expected_order_version: created.order.version + 2,
      idempotency_key: `${PREFIX}-bad-${RUN}`,
    })
    throw new Error("accounts must not reserve")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("accounts cannot reserve")

  const preview = await rpc(godown, "preview_order_allocation", { target_order: orderId })
  if (!preview.eligible) throw new Error(`preview not eligible: ${JSON.stringify(preview.blockers)}`)
  ok("godown manager preview eligible")

  const reserved = await rpc(godown, "reserve_order_allocation", {
    target_order: orderId,
    expected_order_version: preview.order_version,
    idempotency_key: `${PREFIX}-res-${RUN}`,
  })
  if (reserved.status !== "allocated") throw new Error("reserve did not allocate")
  ok("godown manager reserved")

  const replay = await rpc(godown, "reserve_order_allocation", {
    target_order: orderId,
    expected_order_version: preview.order_version,
    idempotency_key: `${PREFIX}-res-${RUN}`,
  })
  if (replay.id !== reserved.id) throw new Error("idempotent reserve replay failed")
  ok("idempotent reserve replay")
} finally {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    update public.stock_reservations set status = 'released'
    where product_id = '${product}'::uuid;
    update public.stock_picking_requests
    set status = 'cancelled', cancelled_by = created_by, cancelled_at = clock_timestamp(),
        cancellation_reason = 'm2qa http cleanup'
    where order_id = '${orderId}'
      and status is distinct from 'cancelled';
    update public.stock_ledger
    set lot_id = null
    where product_id = '${product}'::uuid;
    delete from public.stock_balances where product_id = '${product}'::uuid;
    delete from public.stock_lot_balances
    where lot_id in (
      select id from public.stock_lots
      where product_id = '${product}'::uuid
    );
    delete from public.stock_lots where product_id = '${product}'::uuid;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)
}

console.log(`M2 HTTP passed ${passed.length} checks`)
