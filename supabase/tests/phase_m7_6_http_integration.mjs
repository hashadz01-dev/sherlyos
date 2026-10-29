/**
 * M7.6 HTTP readiness: dashboard cutover, roles, statutory blockers, flags.
 * Does not enable dual-write or issue statutory documents.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const ADMIN_EMAIL = "admin.m1s2qa@example.com"
const ADMIN_PASSWORD = "local-only-m1s2qa"
const DRIVER_EMAIL = "driver.m75d1e2e@example.com"
const DRIVER_PASSWORD = "local-only-m1s2qa"

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

async function signIn(anonKey, email, password) {
  const auth = createClient(API, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const result = await auth.auth.signInWithPassword({ email, password })
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

function denied(error) {
  return /permission denied|not authorized/i.test(error.message)
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

const env = await statusEnv()
if (!env.ANON_KEY) throw new Error("local anon key missing")

await psql(`
  do $$
  declare
    driver_id uuid;
    admin_id uuid;
  begin
    select id into admin_id from auth.users where email = '${ADMIN_EMAIL}';
    if admin_id is null then
      raise exception 'admin.m1s2qa missing';
    end if;
    select id into driver_id from auth.users where email = '${DRIVER_EMAIL}';
    if driver_id is null then
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      values (
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        '${DRIVER_EMAIL}', extensions.crypt('${DRIVER_PASSWORD}', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      )
      returning id into driver_id;
    end if;
    insert into public.profiles (id, full_name, is_active)
    values (driver_id, 'M76 driver', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select driver_id, roles.id, admin_id
    from public.roles
    where roles.code = 'delivery_person'
    on conflict do nothing;
  end $$;
`)

const flags = await psql(`
  select count(*) from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  ) and value = 'true'::jsonb
`)
if (flags !== "0") throw new Error(`operational flags must be false, got ${flags}`)
ok("operational flags are false")

const admin = await signIn(env.ANON_KEY, ADMIN_EMAIL, ADMIN_PASSWORD)
const dashboard = await rpc(admin, "get_operations_dashboard", { filter_branch: null })
if (dashboard.cutover?.dual_write_enabled !== false) {
  throw new Error("dashboard must report dual-write off")
}
if (dashboard.inventory?.available_to_pick?.state !== "not_applicable") {
  throw new Error("available-to-pick must stay not_applicable")
}
if (dashboard.inventory?.visible !== true) {
  throw new Error("admin must see inventory KPIs")
}
ok("dashboard reports cutover-inactive ATP")

const readiness = await rpc(admin, "assess_invoice_finalization_readiness", {
  p_invoice_note_id: null,
})
if (readiness.ready !== false || readiness.legal_issuance_blocked !== true) {
  throw new Error("statutory invoice issuance must stay blocked")
}
ok("statutory invoice issuance stays blocked")

const movements = await rpc(admin, "list_stock_movement_report", {
  filter_branch: null,
  filter_product: null,
  movement_type: null,
  posted_from: null,
  posted_to: null,
  page: 1,
  page_size: 50,
})
if (!movements.summary || movements.summary.dispatch_cartons == null) {
  throw new Error("movement report must expose dispatch totals")
}
const returnTxn = await psql("select count(*) from public.stock_transactions where transaction_type = 'DELIVERY_RETURN'")
if (Number(returnTxn) > 0 && !Array.isArray(movements.rows)) {
  throw new Error("movement report rows must be an array")
}
ok("movement report returns scoped document totals")

try {
  await rpc(admin, "list_stock_movement_report", {
    filter_branch: null,
    filter_product: null,
    movement_type: "DELIVERY_RETURN",
    posted_from: null,
    posted_to: null,
    page: 1,
    page_size: 50,
  })
  throw new Error("DELIVERY_RETURN filter must stay rejected until an owner report change")
} catch (error) {
  if (!/movement type is invalid/i.test(error.message)) throw error
}
ok("DELIVERY_RETURN type filter remains an explicit reporting gap")

const driver = await signIn(env.ANON_KEY, DRIVER_EMAIL, DRIVER_PASSWORD)
try {
  await rpc(driver, "list_credit_adjustments", { p_status: null, p_branch_id: null })
  throw new Error("driver must not list credit adjustments")
} catch (error) {
  if (!denied(error)) throw error
}
const driverDash = await rpc(driver, "get_operations_dashboard", { filter_branch: null })
if (driverDash.inventory?.visible === true) {
  throw new Error("delivery person must not see inventory financial KPIs")
}
ok("delivery person is denied credit adjustments and inventory dashboard KPIs")

const flagsAfter = await psql(`
  select count(*) from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  ) and value = 'true'::jsonb
`)
if (flagsAfter !== "0") throw new Error("HTTP readiness leaked operational flags")
ok("HTTP readiness left operational flags false")

console.log(`M7.6 HTTP passed ${passed.length} checks`)
