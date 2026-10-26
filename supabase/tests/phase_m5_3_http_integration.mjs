/**
 * M5.3 local HTTP proofs against 127.0.0.1:54321 only.
 * Enables dual-write and the hold flag for disposable fixtures, then restores.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m53"
const PREFIX = "m53http"
const RUN = Date.now().toString(36)
const passed = []

function ok(name) {
  passed.push(name)
  console.log("PASS", name)
}

function statusEnv() {
  return new Promise((resolve, reject) => {
    const child = spawn("npx", ["supabase", "status", "-o", "env"], { shell: true })
    let output = ""
    child.stdout.on("data", (chunk) => { output += chunk })
    child.stderr.on("data", (chunk) => { output += chunk })
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
    child.stdout.on("data", (chunk) => { output += chunk })
    child.stderr.on("data", (chunk) => { output += chunk })
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

function denied(error) {
  return /not authorized|permission/i.test(error.message || "")
}

async function ensureUser(email, fullName) {
  const existing = firstUuid(await psql(`select id from auth.users where email = '${email}'`))
  if (existing) return existing
  return firstUuid(await psql(`
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new,
      email_change_token_current, reauthentication_token, email_change
    ) values (
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
    ) returning id;
  `))
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

const env = await statusEnv()
const url = env.API_URL || API
if (!/^https?:\/\/(127\.0\.0\.1|localhost)/.test(url)) throw new Error(`refusing non-local ${url}`)
const anonKey = env.ANON_KEY
const users = {
  admin: await ensureUser(`admin.${PREFIX}.${RUN}@example.com`, "admin"),
  godown: await ensureUser(`godown.${PREFIX}.${RUN}@example.com`, "godown"),
  verifier: await ensureUser(`verifier.${PREFIX}.${RUN}@example.com`, "verifier"),
  keeper: await ensureUser(`keeper.${PREFIX}.${RUN}@example.com`, "keeper"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  select id, split_part(email, '.', 1), true from auth.users
  where email like '%${PREFIX}.${RUN}@example.com'
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, u.id from auth.users u
  join public.roles r on r.code = case split_part(u.email, '.', 1)
    when 'admin' then 'admin'
    when 'godown' then 'godown_manager'
    when 'verifier' then 'godown_manager'
    when 'keeper' then 'store_keeper'
  end
  where u.email like '%${PREFIX}.${RUN}@example.com'
  on conflict do nothing;
`)

const admin = await signIn(anonKey, `admin.${PREFIX}.${RUN}@example.com`)
const godown = await signIn(anonKey, `godown.${PREFIX}.${RUN}@example.com`)
const _verifier = await signIn(anonKey, `verifier.${PREFIX}.${RUN}@example.com`)
const _keeper = await signIn(anonKey, `keeper.${PREFIX}.${RUN}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_b_${RUN}`, branch_name: "M53 HTTP",
})
for (const id of [users.godown, users.verifier, users.keeper]) {
  await rpc(admin, "assign_user_branch", { target_user: id, target_branch: branch })
}
const zone = await rpc(admin, "create_zone", {
  target_branch: branch, zone_code: `${PREFIX}_z`, zone_name: "Z", zone_description: null,
})
const crate = await rpc(admin, "create_crate", {
  target_zone: zone, crate_code: `${PREFIX}_c`, crate_name: "C", crate_description: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`, product_name: "M53 HTTP Soap", next_supplier: null, next_category: null,
})
await rpc(admin, "set_product_expiry_policy", {
  target_product: product, new_policy: "expiry_controlled",
})

await psql(`
  set session_replication_role = replica;
  update public.app_configuration set value = 'true'::jsonb
  where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked', 'damage.stock_hold_ready');
  set session_replication_role = origin;
  begin;
  set local role authenticated;
  select set_config('request.jwt.claim.sub', '${users.admin}', true);
  select set_config('request.jwt.claims', json_build_object('sub', '${users.admin}'::uuid, 'role', 'authenticated')::text, true);
  select public.post_opening_stock(
    '${product}'::uuid, '${crate}'::uuid, 6, '${PREFIX}-open-${RUN}',
    null, 'M53-HTTP', null, '2028-06-01'
  );
  commit;
`)
const lot = firstUuid(await psql(`
  select id from public.stock_lots where product_id = '${product}'::uuid order by created_at limit 1
`))

try {
  try {
    await rpc(admin, "post_ordinary_damage_writeoff", {
      target_report: "00000000-0000-0000-0000-000000000001",
      expected_version: 1,
      idempotency_key: `${PREFIX}-adm-${RUN}`,
    })
    throw new Error("admin ordinary write-off must fail")
  } catch (error) {
    if (!denied(error) && !/not ready|not authorized/i.test(error.message || "")) throw error
  }
  ok("admin cannot post ordinary damage write-off")

  const storage = await rpc(godown, "create_damage_report", {
    scenario: "storage",
    target_godown: branch,
    report_lines: [{
      product_id: product, crate_id: crate, lot_id: lot,
      quantity_cases: 1, damage_reason: "rodent",
    }],
    idempotency_key: `${PREFIX}-st-${RUN}`,
  })
  const submitted = await rpc(godown, "submit_damage_report", {
    target_report: storage.id,
    expected_version: storage.version,
    idempotency_key: `${PREFIX}-stsub-${RUN}`,
  })
  if (!submitted.holds?.length) throw new Error("storage submit must create a hold")
  ok("storage submit isolates on-hand stock")

  try {
    await rpc(godown, "verify_damage_report", {
      target_report: submitted.id,
      expected_version: submitted.version,
    })
    throw new Error("self-verify must fail")
  } catch (error) {
    if (!/reporter cannot verify/i.test(error.message || "") && !denied(error)) throw error
  }
  ok("reporter cannot self-verify")

  const holdReady = await psql(
    `select value #>> '{}' from public.app_configuration where key = 'damage.stock_hold_ready'`,
  )
  if (holdReady.trim() !== "true") throw new Error("test must enable the hold flag locally")
} finally {
  await psql(`
    set session_replication_role = replica;
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

const restored = await psql(`
  select key || '=' || (value #>> '{}') from public.app_configuration
  where key in ('stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked','damage.stock_hold_ready')
  order by 1
`)
if (!/damage.stock_hold_ready=false/.test(restored)
  || !/stock.lots.aggregate_only_blocked=false/.test(restored)
  || !/stock.lots.dual_write_enabled=false/.test(restored)) {
  throw new Error(`flags not restored: ${restored}`)
}
ok("cutover and hold flags restored")
console.log(`M5.3 HTTP passed ${passed.length} checks`)
