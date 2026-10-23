/**
 * M4 local HTTP integration. 127.0.0.1:54321 only.
 * Cutover flags stay false. No development-cloud access.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m4qa"
const PREFIX = "m4qa"
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
    email_change = coalesce(email_change, '');
`)

const users = {
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M4 Admin"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M4 Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M4 Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M4 Driver"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M4 Other"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M4 Admin', true),
    ('${users.godown}', 'M4 Godown', true),
    ('${users.keeper}', 'M4 Keeper', true),
    ('${users.driver}', 'M4 Driver', true),
    ('${users.other}', 'M4 Other', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person'),
    ('${users.other}'::uuid, 'godown_manager')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)
const other = await signIn(env.ANON_KEY, `other.${PREFIX}@example.com`)
const anon = createClient(API, env.ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })

const branch = await rpc(admin, "create_branch", { branch_code: `${PREFIX}_${RUN}`, branch_name: "M4 QA" })
const branchB = await rpc(admin, "create_branch", { branch_code: `${PREFIX}b_${RUN}`, branch_name: "M4 QB" })
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
  product_sku: `${PREFIX}-${RUN}`, product_name: "M4 Soap", next_supplier: null, next_category: null,
})

await psql(`
  begin;
  set local role authenticated;
  select set_config('request.jwt.claim.sub', '${users.admin}', true);
  select set_config(
    'request.jwt.claims',
    json_build_object('sub', '${users.admin}'::uuid, 'role', 'authenticated')::text,
    true
  );
  select public.post_opening_stock(
    '${product}'::uuid, '${crate}'::uuid, 7, '${PREFIX}-open-${RUN}', null
  );
  commit;
`)

try {
  const dash = await rpc(godown, "get_operations_dashboard", { filter_branch: branch })
  if (dash.timezone !== "UTC") throw new Error("timezone")
  if (dash.cutover.dual_write_enabled) throw new Error("cutover must stay off")
  if (dash.inventory.total_cartons_on_hand !== 7) throw new Error(`on-hand ${dash.inventory.total_cartons_on_hand}`)
  if (dash.inventory.available_to_pick?.state !== "not_applicable") {
    throw new Error("available-to-pick must be not_applicable")
  }
  if (dash.inventory.available_to_pick?.value !== null) throw new Error("available-to-pick leaked a number")
  ok("dashboard cutover-inactive inventory")

  const inv = await rpc(godown, "list_inventory_report", {
    grain: "crate", filter_branch: branch, page: 1, page_size: 50,
  })
  if (inv.total_count !== 1 || inv.rows[0].quantity !== 7) throw new Error("inventory contract")
  ok("inventory report contract")

  const moved = await rpc(godown, "list_stock_movement_report", {
    filter_branch: branch, movement_type: "OPENING_STOCK", page: 1, page_size: 50,
  })
  if (moved.summary.opening_cartons !== 7) throw new Error("movement summary")
  ok("movement report contract")

  const lots = await rpc(godown, "list_lot_stock_report", { filter_branch: branch, page: 1, page_size: 50 })
  if (lots.total_count !== 0) throw new Error("lots must be empty while cutover off")
  ok("empty lot report")

  const exported = await rpc(godown, "export_operations_report", {
    report_kind: "inventory", grain: "crate", filter_branch: branch,
  })
  if (!exported.csv.includes("quantity")) throw new Error("csv header")
  if (exported.row_count !== 1) throw new Error("csv rows")
  ok("authorized csv export")

  try {
    await rpc(driver, "list_inventory_report", { grain: "crate", page: 1, page_size: 50 })
    throw new Error("driver inventory")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("driver denied inventory")

  try {
    await rpc(driver, "export_operations_report", { report_kind: "inventory", grain: "crate" })
    throw new Error("driver export")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("driver denied inventory export")

  try {
    await rpc(other, "get_operations_dashboard", { filter_branch: branch })
    throw new Error("cross-branch dashboard")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("cross-branch dashboard denied")

  const keeperInv = await rpc(keeper, "list_inventory_report", {
    grain: "product", filter_branch: branch, page: 1, page_size: 50,
  })
  if (keeperInv.rows[0].quantity !== 7) throw new Error("keeper inventory")
  ok("store keeper inventory")

  try {
    await rpc(keeper, "list_dispatch_delivery_report", { page: 1, page_size: 50 })
    throw new Error("keeper dispatch")
  } catch (error) {
    if (!/not authorized/i.test(error.message)) throw error
  }
  ok("store keeper denied dispatch")

  try {
    await rpc(godown, "list_inventory_report", { grain: "pallet", page: 1, page_size: 50 })
    throw new Error("invalid grain")
  } catch (error) {
    if (!/invalid/i.test(error.message)) throw error
  }
  ok("filter validation")

  const emptyPage = await rpc(godown, "list_dispatch_delivery_report", {
    filter_branch: branch, page: 1, page_size: 50,
  })
  if (emptyPage.total_count !== 0 || emptyPage.rows.length !== 0) throw new Error("empty dispatch")
  ok("empty dispatch response")

  try {
    await rpc(anon, "get_operations_dashboard", {})
    throw new Error("anon dashboard")
  } catch (error) {
    if (!/not authorized|jwt|permission denied/i.test(error.message)) throw error
  }
  ok("anonymous denied")
} finally {
  await psql(`
    set session_replication_role = replica;
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

console.log(`M4 HTTP passed ${passed.length} checks`)
