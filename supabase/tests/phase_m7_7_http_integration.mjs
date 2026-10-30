/**
 * M7.7 HTTP: admin can read imported catalogue SKUs; salesperson cannot create masters.
 * Local API only. Does not flip flags or post stock.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const ADMIN_EMAIL = "admin.m1s2qa@example.com"
const ADMIN_PASSWORD = "local-only-m1s2qa"
const SALES_EMAIL = "sales.m77qa@example.com"
const SALES_PASSWORD = "local-only-m1s2qa"

function run(command, args, input, useShell = false) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"], shell: useShell })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (chunk) => {
      stdout += chunk
    })
    child.stderr.on("data", (chunk) => {
      stderr += chunk
    })
    child.on("close", (code) => {
      const text = (stdout + stderr).trim()
      if (code === 0) resolve(stdout.trim())
      else reject(new Error(text || `${command} exit ${code}`))
    })
    if (input) child.stdin.end(input)
    else child.stdin.end()
  })
}

function psql(sql) {
  return run("docker", [
    "exec",
    "-i",
    "supabase_db_sherlyos",
    "psql",
    "-U",
    "postgres",
    "-d",
    "postgres",
    "-v",
    "ON_ERROR_STOP=1",
    "-tA",
  ], sql)
}

async function statusEnv() {
  const output = await run("npx", ["supabase", "status", "-o", "env"], undefined, true)
  const env = {}
  for (const line of output.split(/\r?\n/)) {
    const cut = line.indexOf("=")
    if (cut < 1) continue
    env[line.slice(0, cut)] = line.slice(cut + 1).replace(/^"|"$/g, "")
  }
  return env
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

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

const env = await statusEnv()
if ((env.API_URL || API) !== API) throw new Error(`refused API ${env.API_URL}`)
if (!env.ANON_KEY) throw new Error("local anon key missing")

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

const skuCount = await psql(`select count(*) from public.products where sku = 'AVT-PREM-DUST-100G'`)
if (skuCount !== "1") {
  throw new Error("run node scripts/m7-7-import-local.mjs --apply before HTTP checks")
}
ok("catalogue SKU exists locally")

await psql(`
  do $$
  declare
    admin_id uuid;
    sales_id uuid;
  begin
    select id into admin_id from auth.users where email = '${ADMIN_EMAIL}';
    if admin_id is null then
      raise exception 'admin.m1s2qa missing';
    end if;
    select id into sales_id from auth.users where email = '${SALES_EMAIL}';
    if sales_id is null then
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      values (
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        '${SALES_EMAIL}', extensions.crypt('${SALES_PASSWORD}', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      )
      returning id into sales_id;
      insert into auth.identities (
        id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
      )
      values (
        gen_random_uuid(), sales_id,
        jsonb_build_object('sub', sales_id::text, 'email', '${SALES_EMAIL}'),
        'email', sales_id::text, now(), now(), now()
      );
    end if;
    insert into public.profiles (id, full_name, is_active)
    values (sales_id, 'M77 salesperson', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select sales_id, roles.id, admin_id
    from public.roles
    where roles.code = 'salesperson'
    on conflict do nothing;
  end $$;
`)

const admin = await signIn(env.ANON_KEY, ADMIN_EMAIL, ADMIN_PASSWORD)
const sales = await signIn(env.ANON_KEY, SALES_EMAIL, SALES_PASSWORD)

const found = await admin.rpc("search_products", {
  product_query: "AVT-PREM-DUST-100G",
  result_limit: 10,
  result_offset: 0,
  active_only: true,
  filter_supplier: null,
})
if (found.error) throw new Error(found.error.message)
if (!Array.isArray(found.data) || !found.data.some((row) => row.sku === "AVT-PREM-DUST-100G")) {
  throw new Error("admin search missed AVT-PREM-DUST-100G")
}
ok("admin search finds imported SKU")

const denied = await sales.rpc("create_product", {
  product_sku: "M77-SALES-BLOCK",
  product_name: "Should not persist",
  next_supplier: null,
  next_category: null,
})
if (!denied.error || !/not authorized|permission/i.test(denied.error.message)) {
  throw new Error(`salesperson create_product should fail, got ${denied.error?.message ?? "success"}`)
}
ok("salesperson cannot create products")

const dup = await admin.rpc("create_product", {
  product_sku: "AVT-PREM-DUST-100G",
  product_name: "Duplicate",
  next_supplier: null,
  next_category: null,
})
if (!dup.error || !/already exists/i.test(dup.error.message)) {
  throw new Error(`duplicate SKU should fail, got ${dup.error?.message ?? "success"}`)
}
ok("duplicate SKU is rejected")

console.log(`M7.7 HTTP ${passed.length} passed`)
