/**
 * M5.4C local HTTP proofs for list_damage_quarantine_inventory
 * against 127.0.0.1:54321. Does not flip damage.stock_hold_ready.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m54c"
const PREFIX = "m54chttp"
const RUN = Date.now().toString(36)

function statusEnv() {
  return new Promise((resolve, reject) => {
    const child = spawn("npx", ["supabase", "status", "-o", "env"], {
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
        resolve(env)
      }
    })
  })
}

function psql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
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
  return (
    String(text).match(
      /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
    )?.[0] ?? ""
  )
}

function assertLocal(url) {
  const parsed = new URL(url)
  if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") {
    throw new Error(`refusing non-local host ${parsed.hostname}`)
  }
}

async function ensureUser(email, fullName) {
  const existing = firstUuid(
    await psql(`select id from auth.users where email = '${email}'`),
  )
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
  const auth = createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const result = await auth.auth.signInWithPassword({
    email,
    password: PASSWORD,
  })
  if (result.error || !result.data.session) {
    throw new Error(
      `sign-in failed for ${email}: ${result.error?.message ?? "no session"}`,
    )
  }
  return createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      headers: { Authorization: `Bearer ${result.data.session.access_token}` },
    },
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M54C Admin"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M54C Godown"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M54C Driver"),
  sales: await ensureUser(`sales.${PREFIX}@example.com`, "M54C Sales"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M54C Admin', true),
    ('${users.godown}', 'M54C Godown', true),
    ('${users.driver}', 'M54C Driver', true),
    ('${users.sales}', 'M54C Sales', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.driver}'::uuid, 'delivery_person'),
    ('${users.sales}'::uuid, 'salesperson')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)
const sales = await signIn(env.ANON_KEY, `sales.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M54C HTTP Godown",
})
await rpc(admin, "assign_user_branch", {
  target_user: users.godown,
  target_branch: branch,
})
await rpc(admin, "assign_user_branch", {
  target_user: users.driver,
  target_branch: branch,
})
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
  product_name: "M54C HTTP Soap",
  next_supplier: null,
  next_category: null,
})

await psql(`
  set session_replication_role = replica;
  insert into public.damage_reports (
    report_number, scenario, godown_id, status, version, reporter_user_id,
    idempotency_key, request_fingerprint, notes
  )
  values (
    '${PREFIX}-http-${RUN}', 'storage', '${branch}', 'verified', 1, '${users.godown}',
    '${PREFIX}-http-${RUN}-key', '${PREFIX}-http-${RUN}-fp', 'http hold'
  );
  insert into public.damage_report_lines (
    damage_report_id, product_id, crate_id, quantity_cases, damage_reason
  )
  select id, '${product}', '${crate}', 1, 'crushed'
  from public.damage_reports where report_number = '${PREFIX}-http-${RUN}';
  insert into public.damage_stock_holds (
    damage_report_id, damage_report_line_id, product_id, crate_id,
    quantity_cases, hold_kind, status
  )
  select damage_reports.id, damage_report_lines.id, '${product}', '${crate}',
    1, 'on_hand_deduction', 'active'
  from public.damage_reports
  join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
  where damage_reports.report_number = '${PREFIX}-http-${RUN}';
  insert into public.damage_reports (
    report_number, scenario, godown_id, status, version, reporter_user_id,
    idempotency_key, request_fingerprint, notes
  )
  values (
    '${PREFIX}-http-wo-${RUN}', 'storage', '${branch}', 'verified', 1, '${users.godown}',
    '${PREFIX}-http-wo-${RUN}-key', '${PREFIX}-http-wo-${RUN}-fp', 'http written off'
  );
  insert into public.damage_report_lines (
    damage_report_id, product_id, crate_id, quantity_cases, damage_reason
  )
  select id, '${product}', '${crate}', 4, 'crushed'
  from public.damage_reports where report_number = '${PREFIX}-http-wo-${RUN}';
  insert into public.damage_stock_holds (
    damage_report_id, damage_report_line_id, product_id, crate_id,
    quantity_cases, hold_kind, status
  )
  select damage_reports.id, damage_report_lines.id, '${product}', '${crate}',
    4, 'on_hand_deduction', 'written_off'
  from public.damage_reports
  join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
  where damage_reports.report_number = '${PREFIX}-http-wo-${RUN}';
  set session_replication_role = origin;
`)

const listed = await rpc(godown, "list_damage_quarantine_inventory", {
  page: 1,
  page_size: 50,
  target_godown: branch,
})
if (!listed?.items?.some((row) => row.report_number === `${PREFIX}-http-${RUN}`)) {
  throw new Error(`godown list missing fixture ${JSON.stringify(listed)}`)
}
if (listed.items.some((row) => row.isolation_class === "logical_hold") === false) {
  throw new Error("expected logical_hold isolation class")
}
if (listed.totals?.current_unavailable_cases !== 1) {
  throw new Error(`written-off must not count as current unavailable ${JSON.stringify(listed.totals)}`)
}
if (listed.totals?.written_off_cases !== 4) {
  throw new Error(`written-off historical total missing ${JSON.stringify(listed.totals)}`)
}
ok("godown lists scoped quarantine inventory")

const paged = await rpc(godown, "list_damage_quarantine_inventory", {
  page: 1,
  page_size: 1,
  target_godown: branch,
})
if (paged.page_size !== 1 || paged.items.length > 1) {
  throw new Error(`page size not applied ${JSON.stringify(paged)}`)
}
if (paged.totals?.current_unavailable_cases !== listed.totals.current_unavailable_cases) {
  throw new Error(`pagination must not shrink class totals ${JSON.stringify(paged.totals)}`)
}
if (paged.total !== listed.total) {
  throw new Error(`pagination must not shrink hold-row total ${paged.total}`)
}
ok("quarantine list paginates")

try {
  await rpc(driver, "list_damage_quarantine_inventory", {})
  throw new Error("driver listed quarantine inventory")
} catch (error) {
  if (!denied(error)) throw error
  ok("driver denied quarantine inventory")
}

try {
  await rpc(sales, "list_damage_quarantine_inventory", {})
  throw new Error("sales listed quarantine inventory")
} catch (error) {
  if (!denied(error)) throw error
  ok("sales denied quarantine inventory")
}

const ready = await rpc(godown, "damage_stock_hold_ready_status", {})
if (ready?.stock_hold_ready !== false) {
  throw new Error(`readiness must stay false ${JSON.stringify(ready)}`)
}
ok("readiness remains false")

console.log(`M5.4C HTTP passed ${passed.length}`)
