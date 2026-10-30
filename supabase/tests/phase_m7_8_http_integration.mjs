/**
 * M7.8 HTTP: shared fleet plates are imported; salesperson cannot create vehicles;
 * duplicate normalized registration is rejected; assignable list is the whole fleet.
 * Local API only. Does not flip flags or post stock.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const ADMIN_EMAIL = "admin.m1s2qa@example.com"
const ADMIN_PASSWORD = "local-only-m1s2qa"
const SALES_EMAIL = "sales.m78qa@example.com"
const SALES_PASSWORD = "local-only-m1s2qa"
const GODOWN_EMAIL = "godown.m78qa@example.com"
const GODOWN_PASSWORD = "local-only-m1s2qa"
const SHERLYS_PLATES = [
  "kl43f948",
  "kl43k3458",
  "kl43t5764",
  "kl43n3241",
  "kl43p0012",
  "kl43p7981",
  "kl43q1561",
  "kl43r1543",
  "kl43r5470",
  "kl43s7528",
  "kl43r6725",
]

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
  return run(
    "docker",
    [
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
    ],
    sql,
  )
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

const plateList = SHERLYS_PLATES.map((plate) => `'${plate}'`).join(",")
const imported = await psql(
  `select count(*) from public.vehicles where registration_normalized in (${plateList})`,
)
if (imported !== "11") {
  throw new Error(`expected 11 Sherlys fleet plates, found ${imported}`)
}
const boleroActive = await psql(
  `select is_active::text from public.vehicles where registration_normalized = 'kl43r6725'`,
)
if (boleroActive !== "false") {
  throw new Error(`Bolero must stay inactive until the owner activates it, got ${boleroActive}`)
}
ok("Sherlys fleet plates are in the vehicle master and Bolero is inactive")

await psql(`
  do $$
  declare
    admin_id uuid;
    sales_id uuid;
    godown_id uuid;
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
    values (sales_id, 'M78 salesperson', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select sales_id, roles.id, admin_id
    from public.roles
    where roles.code = 'salesperson'
    on conflict do nothing;

    select id into godown_id from auth.users where email = '${GODOWN_EMAIL}';
    if godown_id is null then
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      values (
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        '${GODOWN_EMAIL}', extensions.crypt('${GODOWN_PASSWORD}', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      )
      returning id into godown_id;
      insert into auth.identities (
        id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
      )
      values (
        gen_random_uuid(), godown_id,
        jsonb_build_object('sub', godown_id::text, 'email', '${GODOWN_EMAIL}'),
        'email', godown_id::text, now(), now(), now()
      );
    end if;
    insert into public.profiles (id, full_name, is_active)
    values (godown_id, 'M78 godown manager', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select godown_id, roles.id, admin_id
    from public.roles
    where roles.code = 'godown_manager'
    on conflict do nothing;
  end $$;
`)

const admin = await signIn(env.ANON_KEY, ADMIN_EMAIL, ADMIN_PASSWORD)
const sales = await signIn(env.ANON_KEY, SALES_EMAIL, SALES_PASSWORD)
const godown = await signIn(env.ANON_KEY, GODOWN_EMAIL, GODOWN_PASSWORD)
const suffix = Date.now().toString(36).slice(-6)
const branch = await admin.rpc("create_branch", {
  branch_code: `m78http_${suffix}`,
  branch_name: `M78 HTTP ${suffix}`,
})
if (branch.error || !branch.data) {
  throw new Error(branch.error?.message ?? "create_branch failed")
}
const plate = `KL-43-H${suffix}`.slice(0, 32)

const denied = await sales.rpc("create_vehicle", {
  target_branch: branch.data,
  registration_number: plate,
  vehicle_type: "van",
  display_name: "Sales blocked van",
  capacity_cases: null,
  operational_notes: null,
})
if (!denied.error || !/not authorized|permission/i.test(denied.error.message)) {
  throw new Error(`salesperson create_vehicle should fail, got ${denied.error?.message ?? "success"}`)
}
ok("salesperson cannot create vehicles")

const created = await admin.rpc("create_vehicle", {
  target_branch: null,
  registration_number: plate,
  vehicle_type: "other",
  display_name: "M78 HTTP van",
  capacity_cases: null,
  operational_notes: "shared fleet disposable",
})
if (created.error || !created.data) {
  throw new Error(created.error?.message ?? "admin create_vehicle failed")
}
ok("admin can create a disposable vehicle")

const dup = await admin.rpc("create_vehicle", {
  target_branch: branch.data,
  registration_number: plate.replaceAll("-", ""),
  vehicle_type: "van",
  display_name: "Duplicate HTTP van",
  capacity_cases: null,
  operational_notes: null,
})
if (!dup.error || !/already exists/i.test(dup.error.message)) {
  throw new Error(`duplicate registration should fail, got ${dup.error?.message ?? "success"}`)
}
ok("duplicate normalized registration is rejected")

const assigned = await admin.rpc("assign_user_branch", {
  target_user: (await psql(`select id from auth.users where email = '${GODOWN_EMAIL}'`)).trim(),
  target_branch: branch.data,
})
if (assigned.error) throw new Error(assigned.error.message)

const assignable = await godown.rpc("list_assignable_vehicles", { target_branch: branch.data })
if (assignable.error) throw new Error(assignable.error.message)
const rows = Array.isArray(assignable.data) ? assignable.data : []
if (!rows.some((row) => row.id === created.data && row.in_use === false)) {
  throw new Error("list_assignable_vehicles missed the new idle vehicle")
}
const normalizePlate = (value) => String(value ?? "").toLowerCase().replace(/[^a-z0-9]/g, "")
if (!rows.some((row) => normalizePlate(row.registration_number) === "kl43f948")) {
  throw new Error("delivery selector omitted Benz (B)")
}
if (rows.some((row) => normalizePlate(row.registration_number) === "kl43r6725")) {
  throw new Error("delivery selector included inactive Bolero")
}
ok("delivery selector lists the fleet, including idle vehicles, and omits inactive Bolero")

await admin.rpc("set_vehicle_active", { target_vehicle: created.data, active: false })

console.log(`M7.8 HTTP ${passed.length} passed`)
