/**
 * M5.4D local HTTP proofs for verify/return/reject/write-off
 * against 127.0.0.1:54321. Does not flip damage.stock_hold_ready.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m54d"
const PREFIX = "m54dhttp"
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
    /not authorized|permission|reporter cannot verify/i.test(error.message || "")
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M54D Admin"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M54D Godown"),
  verifier: await ensureUser(`verifier.${PREFIX}@example.com`, "M54D Verifier"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M54D Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M54D Driver"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M54D Admin', true),
    ('${users.godown}', 'M54D Godown', true),
    ('${users.verifier}', 'M54D Verifier', true),
    ('${users.keeper}', 'M54D Keeper', true),
    ('${users.driver}', 'M54D Driver', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.verifier}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const verifier = await signIn(env.ANON_KEY, `verifier.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M54D HTTP Godown",
})
await rpc(admin, "assign_user_branch", {
  target_user: users.godown,
  target_branch: branch,
})
await rpc(admin, "assign_user_branch", {
  target_user: users.verifier,
  target_branch: branch,
})
await rpc(admin, "assign_user_branch", {
  target_user: users.keeper,
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
  product_name: "M54D HTTP Soap",
  next_supplier: null,
  next_category: null,
})

await rpc(admin, "post_opening_stock", {
  target_product: product,
  target_crate: crate,
  carton_quantity: 20,
  idempotency_key: `${PREFIX}-open-${RUN}`,
  posting_notes: "M54D HTTP opening",
})

await psql(`
  set session_replication_role = replica;
  insert into public.damage_reports (
    report_number, scenario, godown_id, status, version, reporter_user_id,
    idempotency_key, request_fingerprint, notes
  ) values
    ('${PREFIX}-in-${RUN}', 'refill_supply', '${branch}', 'submitted', 2, '${users.godown}',
      '${PREFIX}-in-${RUN}-key', '${PREFIX}-in-${RUN}-fp', 'http inbound'),
    ('${PREFIX}-self-${RUN}', 'refill_supply', '${branch}', 'submitted', 2, '${users.verifier}',
      '${PREFIX}-self-${RUN}-key', '${PREFIX}-self-${RUN}-fp', 'self verify'),
    ('${PREFIX}-ret-${RUN}', 'refill_supply', '${branch}', 'submitted', 2, '${users.keeper}',
      '${PREFIX}-ret-${RUN}-key', '${PREFIX}-ret-${RUN}-fp', 'return'),
    ('${PREFIX}-rej-${RUN}', 'refill_supply', '${branch}', 'submitted', 2, '${users.keeper}',
      '${PREFIX}-rej-${RUN}-key', '${PREFIX}-rej-${RUN}-fp', 'reject'),
    ('${PREFIX}-noev-${RUN}', 'refill_supply', '${branch}', 'submitted', 2, '${users.godown}',
      '${PREFIX}-noev-${RUN}-key', '${PREFIX}-noev-${RUN}-fp', 'no evidence'),
    ('${PREFIX}-iso-${RUN}', 'storage', '${branch}', 'submitted', 2, '${users.godown}',
      '${PREFIX}-iso-${RUN}-key', '${PREFIX}-iso-${RUN}-fp', 'no holds'),
    ('${PREFIX}-wo-${RUN}', 'storage', '${branch}', 'verified', 3, '${users.godown}',
      '${PREFIX}-wo-${RUN}-key', '${PREFIX}-wo-${RUN}-fp', 'write-off');

  insert into public.damage_report_lines (damage_report_id, product_id, crate_id, quantity_cases, damage_reason)
  select id, '${product}'::uuid,
    case when scenario = 'refill_supply' then null else '${crate}'::uuid end,
    2, 'crushed'
  from public.damage_reports
  where report_number like '${PREFIX}-%-${RUN}';

  insert into public.damage_stock_holds (
    damage_report_id, damage_report_line_id, product_id, crate_id, quantity_cases, hold_kind, status
  )
  select damage_reports.id, damage_report_lines.id, '${product}', '${crate}',
    2, 'on_hand_deduction', 'active'
  from public.damage_reports
  join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
  where damage_reports.report_number = '${PREFIX}-wo-${RUN}';

  insert into public.damage_evidence (
    damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
  )
  select id, id::text || '/' || gen_random_uuid()::text, '${users.godown}', 'image/jpeg', 4, now()
  from public.damage_reports
  where report_number in (
    '${PREFIX}-in-${RUN}', '${PREFIX}-self-${RUN}', '${PREFIX}-ret-${RUN}',
    '${PREFIX}-rej-${RUN}', '${PREFIX}-iso-${RUN}', '${PREFIX}-wo-${RUN}'
  );
  set session_replication_role = origin;
`)

const inboundId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-in-${RUN}'`,
  ),
)
const selfId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-self-${RUN}'`,
  ),
)
const returnId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-ret-${RUN}'`,
  ),
)
const rejectId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-rej-${RUN}'`,
  ),
)
const noevId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-noev-${RUN}'`,
  ),
)
const isoId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-iso-${RUN}'`,
  ),
)
const writeoffId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-wo-${RUN}'`,
  ),
)

try {
  await rpc(keeper, "verify_damage_report", {
    target_report: inboundId,
    expected_version: 2,
  })
  throw new Error("store keeper verified")
} catch (error) {
  if (!denied(error)) throw error
  ok("store keeper denied verification")
}

try {
  await rpc(driver, "verify_damage_report", {
    target_report: inboundId,
    expected_version: 2,
  })
  throw new Error("driver verified")
} catch (error) {
  if (!denied(error)) throw error
  ok("delivery person denied verification")
}

try {
  await rpc(verifier, "verify_damage_report", {
    target_report: selfId,
    expected_version: 2,
  })
  throw new Error("reporter self-verified")
} catch (error) {
  if (!denied(error) && !/reporter cannot verify/i.test(error.message)) {
    throw error
  }
  ok("reporter self-verification denied over HTTP")
}

try {
  await rpc(verifier, "verify_damage_report", {
    target_report: noevId,
    expected_version: 2,
  })
  throw new Error("missing evidence verified")
} catch (error) {
  if (!/photographic evidence/i.test(error.message)) throw error
  ok("unfinalized evidence blocked verification")
}

try {
  await rpc(verifier, "verify_damage_report", {
    target_report: isoId,
    expected_version: 2,
  })
  throw new Error("storage without holds verified")
} catch (error) {
  if (!/stock isolation is not ready/i.test(error.message)) throw error
  ok("readiness=false isolation prerequisite fail-closed")
}

try {
  await rpc(verifier, "verify_damage_report", {
    target_report: inboundId,
    expected_version: 1,
  })
  throw new Error("stale version verified")
} catch (error) {
  if (!/changed by someone else|PT409/i.test(error.message + error.code)) {
    throw error
  }
  ok("stale expected_version denied")
}

const verified = await rpc(verifier, "verify_damage_report", {
  target_report: inboundId,
  expected_version: 2,
})
if (verified?.status !== "verified" || !verified.verified_at) {
  throw new Error(`authorized verify failed ${JSON.stringify(verified)}`)
}
ok("authorized GM verification")

const returned = await rpc(verifier, "return_damage_report", {
  target_report: returnId,
  expected_version: 2,
  reason: "need clearer photos",
})
if (returned?.status !== "returned") {
  throw new Error(`return failed ${JSON.stringify(returned)}`)
}
ok("return for correction")

const rejected = await rpc(verifier, "reject_damage_report", {
  target_report: rejectId,
  expected_version: 2,
  reason: "not accepted",
})
if (rejected?.status !== "rejected") {
  throw new Error(`reject failed ${JSON.stringify(rejected)}`)
}
ok("formal rejection")

try {
  await rpc(keeper, "post_ordinary_damage_writeoff", {
    target_report: writeoffId,
    expected_version: 3,
    idempotency_key: `${PREFIX}-wo-keeper`,
  })
  throw new Error("keeper posted write-off")
} catch (error) {
  if (!denied(error)) throw error
  ok("store keeper denied write-off")
}

const posted = await rpc(verifier, "post_ordinary_damage_writeoff", {
  target_report: writeoffId,
  expected_version: 3,
  idempotency_key: `${PREFIX}-wo-a`,
})
const lost = await rpc(verifier, "post_ordinary_damage_writeoff", {
  target_report: writeoffId,
  expected_version: 3,
  idempotency_key: `${PREFIX}-wo-a`,
})
const stale = await rpc(verifier, "post_ordinary_damage_writeoff", {
  target_report: writeoffId,
  expected_version: 2,
  idempotency_key: `${PREFIX}-wo-a`,
})
const replay = await rpc(verifier, "post_ordinary_damage_writeoff", {
  target_report: writeoffId,
  expected_version: 99,
  idempotency_key: `${PREFIX}-wo-b`,
})
const refreshed = await rpc(verifier, "get_damage_report", {
  target_report: writeoffId,
})
const txns = Number(
  await psql(`
    select count(*) from public.stock_transactions
    where damage_report_id = '${writeoffId}'
      and damage_posting_kind = 'ordinary_writeoff'
  `),
)
if (txns !== 1) throw new Error(`write-off not exact-once ${txns}`)
if (!posted || !lost || !stale || !replay || !refreshed) {
  throw new Error("write-off payload missing")
}
const written = (refreshed.holds ?? []).some(
  (hold) => hold.status === "written_off",
)
if (!written) throw new Error("refresh after write-off missing written_off hold")
ok("ordinary write-off exact-once over HTTP")

const listed = await rpc(verifier, "list_damage_reports", {
  page: 1,
  page_size: 25,
  target_godown: branch,
  status_filter: "verified",
  scenario_filter: null,
  search_text: `${PREFIX}-in`,
  from_date: null,
  to_date: null,
})
if (!listed?.items?.some((row) => row.report_number === `${PREFIX}-in-${RUN}`)) {
  throw new Error(`verification list missed inbound ${JSON.stringify(listed)}`)
}
if (listed.items[0]?.has_finalized_evidence !== true) {
  throw new Error("list missing evidence fact")
}
ok("list_damage_reports serves verification queue filters")

const ready = await rpc(godown, "damage_stock_hold_ready_status", {})
if (ready?.stock_hold_ready !== false) {
  throw new Error(`readiness must stay false ${JSON.stringify(ready)}`)
}
ok("readiness remains false")

console.log(`M5.4D HTTP passed ${passed.length}`)

await psql(`
  set session_replication_role = replica;
  delete from public.damage_evidence
  where damage_report_id in (
    select id from public.damage_reports where report_number like '${PREFIX}-%'
  );
  delete from public.damage_stock_holds
  where damage_report_id in (
    select id from public.damage_reports where report_number like '${PREFIX}-%'
  );
  delete from public.damage_report_events
  where damage_report_id in (
    select id from public.damage_reports where report_number like '${PREFIX}-%'
  );
  delete from public.stock_ledger
  where product_id in (select id from public.products where sku like '${PREFIX}-%');
  delete from public.stock_transactions
  where damage_report_id in (
    select id from public.damage_reports where report_number like '${PREFIX}-%'
  )
     or product_id in (select id from public.products where sku like '${PREFIX}-%');
  delete from public.damage_report_lines
  where damage_report_id in (
    select id from public.damage_reports where report_number like '${PREFIX}-%'
  );
  delete from public.damage_reports where report_number like '${PREFIX}-%';
  delete from public.stock_balances
  where product_id in (select id from public.products where sku like '${PREFIX}-%');
  delete from public.products where sku like '${PREFIX}-%';
  update public.app_configuration set value = 'false'::jsonb
  where key in (
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked',
    'damage.stock_hold_ready'
  );
  set session_replication_role = origin;
`)
