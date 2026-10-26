/**
 * M5.4E local HTTP proofs for exceptional request/approve/reject/post
 * against 127.0.0.1:54321. Does not flip damage.stock_hold_ready.
 * Shared Docker flags: run sequentially with other M5.2–M5.4E SQL/HTTP/concurrency
 * suites. Session advisory lock serializes against 4E SQL/concurrency.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m54e"
const PREFIX = "m54ehttp"
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

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** Holds the suite advisory lock in a dedicated psql session via pg_sleep. */
async function holdStockFlagLock() {
  const child = spawn("docker", [
    "exec",
    "supabase_db_sherlyos",
    "psql",
    "-U",
    "postgres",
    "-d",
    "postgres",
    "-v",
    "ON_ERROR_STOP=1",
    "-tA",
    "-c",
    "select pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests')); select pg_sleep(86400);",
  ])
  for (let i = 0; i < 50; i += 1) {
    const held = await psql(`
      select count(*)::text
      from pg_stat_activity
      where pid <> pg_backend_pid()
        and query like '%sherlyos.m5.stock_flag_tests%'
    `)
    if (Number(String(held).split(/\r?\n/).filter(Boolean).at(-1) ?? "0") > 0) {
      return {
        async release() {
          await psql(`
            select pg_terminate_backend(pid)
            from pg_stat_activity
            where pid <> pg_backend_pid()
              and query like '%sherlyos.m5.stock_flag_tests%'
          `).catch(() => undefined)
          child.kill()
        },
      }
    }
    await delay(100)
  }
  child.kill()
  throw new Error("flag lock timeout")
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
    /not authorized|permission|not approved/i.test(error.message || "")
  )
}

function requestId(payload) {
  return payload?.exceptional_requests?.[0]?.id ?? ""
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M54E Admin"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M54E Godown"),
  verifier: await ensureUser(`verifier.${PREFIX}@example.com`, "M54E Verifier"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M54E Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M54E Driver"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M54E Other"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M54E Admin', true),
    ('${users.godown}', 'M54E Godown', true),
    ('${users.verifier}', 'M54E Verifier', true),
    ('${users.keeper}', 'M54E Keeper', true),
    ('${users.driver}', 'M54E Driver', true),
    ('${users.other}', 'M54E Other', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.verifier}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person'),
    ('${users.other}'::uuid, 'godown_manager')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const verifier = await signIn(env.ANON_KEY, `verifier.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)
const other = await signIn(env.ANON_KEY, `other.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M54E HTTP Godown",
})
const otherBranch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_o_${RUN}`,
  branch_name: "M54E HTTP Other",
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
await rpc(admin, "assign_user_branch", {
  target_user: users.other,
  target_branch: otherBranch,
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
const qzone = await rpc(admin, "create_zone", {
  target_branch: branch,
  zone_code: `${PREFIX}_q_${RUN}`,
  zone_name: "Q",
  zone_description: null,
})
const qcrate = await rpc(admin, "create_crate", {
  target_zone: qzone,
  crate_code: `${PREFIX}_qc_${RUN}`,
  crate_name: "QC",
  crate_description: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`,
  product_name: "M54E HTTP Soap",
  next_supplier: null,
  next_category: null,
})
const shop = await rpc(admin, "create_shop", {
  shop_name: `M54E HTTP Shop ${RUN}`,
  shop_phone: null,
  shop_address: null,
})

await rpc(admin, "post_opening_stock", {
  target_product: product,
  target_crate: crate,
  carton_quantity: 40,
  idempotency_key: `${PREFIX}-open-${RUN}`,
  posting_notes: "M54E HTTP opening",
})
await rpc(admin, "post_opening_stock", {
  target_product: product,
  target_crate: qcrate,
  carton_quantity: 10,
  idempotency_key: `${PREFIX}-openq-${RUN}`,
  posting_notes: "M54E HTTP quarantine opening",
})
await psql(`
  set session_replication_role = replica;
  update public.zones set location_role = 'quarantine' where id = '${qzone}';
  update public.crates set location_role = 'quarantine' where id = '${qcrate}';
  set session_replication_role = origin;
`)

await psql(`
  set session_replication_role = replica;
  insert into public.damage_reports (
    report_number, scenario, godown_id, status, version, reporter_user_id,
    verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
  ) values
    ('${PREFIX}-des-${RUN}', 'storage', '${branch}', 'verified', 3, '${users.godown}',
      '${users.verifier}', now(), '${PREFIX}-des-${RUN}-key', '${PREFIX}-des-${RUN}-fp', 'destroy'),
    ('${PREFIX}-sup-${RUN}', 'storage', '${branch}', 'verified', 3, '${users.godown}',
      '${users.verifier}', now(), '${PREFIX}-sup-${RUN}-key', '${PREFIX}-sup-${RUN}-fp', 'supplier'),
    ('${PREFIX}-rej-${RUN}', 'storage', '${branch}', 'verified', 3, '${users.godown}',
      '${users.verifier}', now(), '${PREFIX}-rej-${RUN}-key', '${PREFIX}-rej-${RUN}-fp', 'reject');

  insert into public.damage_reports (
    report_number, scenario, godown_id, status, version, reporter_user_id,
    idempotency_key, request_fingerprint, notes, shop_id,
    rejected_at, rejected_by, rejection_reason
  ) values (
    '${PREFIX}-sr-${RUN}', 'shop_return', '${branch}', 'rejected', 3, '${users.godown}',
    '${PREFIX}-sr-${RUN}-key', '${PREFIX}-sr-${RUN}-fp', 'rejected shop return', '${shop}',
    now(), '${users.verifier}', 'not accepted'
  );

  insert into public.damage_report_lines (damage_report_id, product_id, crate_id, quantity_cases, damage_reason)
  select id, '${product}'::uuid,
    case when scenario = 'shop_return' then '${qcrate}'::uuid else '${crate}'::uuid end,
    2, 'crushed'
  from public.damage_reports
  where report_number like '${PREFIX}-%-${RUN}';

  insert into public.damage_stock_holds (
    damage_report_id, damage_report_line_id, product_id, crate_id, quantity_cases, hold_kind, status
  )
  select damage_reports.id, damage_report_lines.id, '${product}',
    damage_report_lines.crate_id, 2,
    case when damage_reports.scenario = 'shop_return' then 'quarantine_intake' else 'on_hand_deduction' end,
    'active'
  from public.damage_reports
  join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
  where damage_reports.report_number like '${PREFIX}-%-${RUN}';

  insert into public.damage_evidence (
    damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
  )
  select id, id::text || '/' || gen_random_uuid()::text, '${users.godown}', 'image/jpeg', 4, now()
  from public.damage_reports
  where report_number like '${PREFIX}-%-${RUN}';
  set session_replication_role = origin;
`)

const desId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-des-${RUN}'`,
  ),
)
const supId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-sup-${RUN}'`,
  ),
)
const rejId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-rej-${RUN}'`,
  ),
)
const srId = firstUuid(
  await psql(
    `select id from public.damage_reports where report_number = '${PREFIX}-sr-${RUN}'`,
  ),
)

const flagLock = await holdStockFlagLock()
try {
try {
  await rpc(keeper, "request_exceptional_damage_disposition", {
    target_report: desId,
    expected_version: 3,
    disposition_kind: "destroy",
    request_reason: "keeper request",
    idempotency_key: `${PREFIX}-req-keeper`,
  })
  throw new Error("keeper requested exceptional")
} catch (error) {
  if (!denied(error)) throw error
  ok("store keeper denied exceptional request")
}

try {
  await rpc(driver, "request_exceptional_damage_disposition", {
    target_report: desId,
    expected_version: 3,
    disposition_kind: "destroy",
    request_reason: "driver request",
    idempotency_key: `${PREFIX}-req-driver`,
  })
  throw new Error("driver requested exceptional")
} catch (error) {
  if (!denied(error)) throw error
  ok("delivery person denied exceptional request")
}

try {
  await rpc(admin, "request_exceptional_damage_disposition", {
    target_report: desId,
    expected_version: 3,
    disposition_kind: "destroy",
    request_reason: "admin request",
    idempotency_key: `${PREFIX}-req-admin`,
  })
  throw new Error("admin requested exceptional")
} catch (error) {
  if (!denied(error)) throw error
  ok("admin denied exceptional request")
}

try {
  await rpc(other, "request_exceptional_damage_disposition", {
    target_report: desId,
    expected_version: 3,
    disposition_kind: "destroy",
    request_reason: "cross godown",
    idempotency_key: `${PREFIX}-req-other`,
  })
  throw new Error("cross-godown request succeeded")
} catch (error) {
  if (!denied(error)) throw error
  ok("cross-godown exceptional request denied")
}

const requested = await rpc(verifier, "request_exceptional_damage_disposition", {
  target_report: desId,
  expected_version: 3,
  disposition_kind: "destroy",
  request_reason: "destroy crushed soap",
  idempotency_key: `${PREFIX}-req-des`,
})
const replayRequest = await rpc(
  verifier,
  "request_exceptional_damage_disposition",
  {
    target_report: desId,
    expected_version: 1,
    disposition_kind: "destroy",
    request_reason: "destroy crushed soap",
    idempotency_key: `${PREFIX}-req-des`,
  },
)
if (requested?.exceptional_requests?.[0]?.status !== "requested") {
  throw new Error(`request failed ${JSON.stringify(requested)}`)
}
if (!replayRequest) throw new Error("request replay missing")
ok("GM exceptional request and key replay")

try {
  await rpc(verifier, "request_exceptional_damage_disposition", {
    target_report: supId,
    expected_version: 3,
    disposition_kind: "destroy",
    request_reason: "reuse destroy key",
    idempotency_key: `${PREFIX}-req-des`,
  })
  throw new Error("foreign request key succeeded")
} catch (error) {
  if (!denied(error)) throw error
  ok("foreign request key denied")
}

const destroyReq = requestId(requested)

try {
  await rpc(verifier, "approve_exceptional_damage_disposition", {
    target_request: destroyReq,
    expected_version: 1,
  })
  throw new Error("GM approved exceptional")
} catch (error) {
  if (!denied(error)) throw error
  ok("GM denied exceptional approval")
}

try {
  await rpc(admin, "post_exceptional_damage_disposition", {
    target_request: destroyReq,
    expected_version: 1,
    idempotency_key: `${PREFIX}-post-admin`,
  })
  throw new Error("admin posted exceptional")
} catch (error) {
  if (!denied(error)) throw error
  ok("admin denied exceptional execution")
}

const approved = await rpc(admin, "approve_exceptional_damage_disposition", {
  target_request: destroyReq,
  expected_version: 1,
})
const replayApprove = await rpc(admin, "approve_exceptional_damage_disposition", {
  target_request: destroyReq,
  expected_version: 1,
})
if (approved?.exceptional_requests?.[0]?.status !== "approved") {
  throw new Error(`approve failed ${JSON.stringify(approved)}`)
}
if (!replayApprove) throw new Error("approve replay missing")
ok("admin approval is authorization only")

const posted = await rpc(verifier, "post_exceptional_damage_disposition", {
  target_request: destroyReq,
  expected_version: 2,
  idempotency_key: `${PREFIX}-post-des`,
})
const lost = await rpc(verifier, "post_exceptional_damage_disposition", {
  target_request: destroyReq,
  expected_version: 2,
  idempotency_key: `${PREFIX}-post-des`,
})
const stale = await rpc(verifier, "post_exceptional_damage_disposition", {
  target_request: destroyReq,
  expected_version: 1,
  idempotency_key: `${PREFIX}-post-des`,
})
const otherKey = await rpc(verifier, "post_exceptional_damage_disposition", {
  target_request: destroyReq,
  expected_version: 99,
  idempotency_key: `${PREFIX}-post-des-b`,
})
const txns = Number(
  await psql(`
    select count(*) from public.stock_transactions
    where damage_report_id = '${desId}'
      and damage_posting_kind = 'exceptional_writeoff'
  `),
)
if (txns !== 1) throw new Error(`destroy not exact-once ${txns}`)
if (!posted || !lost || !stale || !otherKey) {
  throw new Error("destroy replay payload missing")
}
const hold = (posted.holds ?? []).some((row) => row.status === "written_off")
if (!hold) throw new Error("destroy hold not written_off")
ok("destroy posting lost-response and stale-version recovery")

const supReqPayload = await rpc(
  verifier,
  "request_exceptional_damage_disposition",
  {
    target_report: supId,
    expected_version: 3,
    disposition_kind: "return_supplier",
    request_reason: "return crushed soap",
    idempotency_key: `${PREFIX}-req-sup`,
  },
)
const supReq = requestId(supReqPayload)
await rpc(admin, "approve_exceptional_damage_disposition", {
  target_request: supReq,
  expected_version: 1,
})
const supPosted = await rpc(verifier, "post_exceptional_damage_disposition", {
  target_request: supReq,
  expected_version: 2,
  idempotency_key: `${PREFIX}-post-sup`,
})
if (!(supPosted.holds ?? []).some((row) => row.status === "returned_supplier")) {
  throw new Error("supplier return hold missing")
}
ok("supplier-return posting keeps stock unavailable")

const srReqPayload = await rpc(
  verifier,
  "request_exceptional_damage_disposition",
  {
    target_report: srId,
    expected_version: 3,
    disposition_kind: "destroy",
    request_reason: "destroy rejected return",
    idempotency_key: `${PREFIX}-req-sr`,
  },
)
const srReq = requestId(srReqPayload)
await rpc(admin, "approve_exceptional_damage_disposition", {
  target_request: srReq,
  expected_version: 1,
})
const srPosted = await rpc(verifier, "post_exceptional_damage_disposition", {
  target_request: srReq,
  expected_version: 2,
  idempotency_key: `${PREFIX}-post-sr`,
})
const remaining = (srPosted.holds ?? []).filter(
  (row) => row.status === "active" || row.status === "transferred",
)
if (remaining.length !== 0) {
  throw new Error("rejected shop-return still isolated after destroy")
}
ok("rejected shop-return quarantine destroyed")

const rejReqPayload = await rpc(
  verifier,
  "request_exceptional_damage_disposition",
  {
    target_report: rejId,
    expected_version: 3,
    disposition_kind: "destroy",
    request_reason: "maybe destroy",
    idempotency_key: `${PREFIX}-req-rej`,
  },
)
const rejReq = requestId(rejReqPayload)
await rpc(admin, "reject_exceptional_damage_disposition", {
  target_request: rejReq,
  expected_version: 1,
  decision_reason: "not justified",
})
try {
  await rpc(verifier, "post_exceptional_damage_disposition", {
    target_request: rejReq,
    expected_version: 2,
    idempotency_key: `${PREFIX}-post-rej`,
  })
  throw new Error("rejected request posted")
} catch (error) {
  if (!denied(error) && !/not approved/i.test(error.message)) throw error
  ok("admin rejection blocks execution")
}

try {
  await rpc(keeper, "list_exceptional_damage_requests", {
    page: 1,
    page_size: 25,
  })
  throw new Error("keeper listed exceptional queue")
} catch (error) {
  if (!denied(error)) throw error
  ok("store keeper denied exceptional queue")
}

const listed = await rpc(admin, "list_exceptional_damage_requests", {
  page: 1,
  page_size: 25,
  target_godown: branch,
  status_filter: "posted",
  kind_filter: "destroy",
  scenario_filter: null,
  search_text: `${PREFIX}-des`,
  from_date: null,
  to_date: null,
})
if (!listed?.items?.some((row) => row.report_number === `${PREFIX}-des-${RUN}`)) {
  throw new Error(`admin queue missed destroy ${JSON.stringify(listed)}`)
}
ok("admin queue is server-filtered")

try {
  await rpc(other, "post_exceptional_damage_disposition", {
    target_request: destroyReq,
    expected_version: 2,
    idempotency_key: `${PREFIX}-stolen-post`,
  })
  throw new Error("cross-godown post replay succeeded")
} catch (error) {
  if (!denied(error)) throw error
  ok("cross-godown completed post replay denied")
}

await psql(`
  delete from public.user_roles
  where user_id = '${users.verifier}'
    and role_id = (select id from public.roles where code = 'godown_manager');
`)
try {
  await rpc(verifier, "post_exceptional_damage_disposition", {
    target_request: destroyReq,
    expected_version: 2,
    idempotency_key: `${PREFIX}-post-des`,
  })
  throw new Error("revoked verify replay succeeded")
} catch (error) {
  if (!denied(error)) throw error
  ok("permission-revoked completed post replay denied")
}
await psql(`
  insert into public.user_roles (user_id, role_id, assigned_by)
  select '${users.verifier}'::uuid, roles.id, '${users.admin}'::uuid
  from public.roles where roles.code = 'godown_manager'
  on conflict do nothing;
`)

await psql(`
  delete from public.user_branch_assignments
  where user_id = '${users.verifier}' and branch_id = '${branch}';
`)
try {
  await rpc(verifier, "post_exceptional_damage_disposition", {
    target_request: destroyReq,
    expected_version: 2,
    idempotency_key: `${PREFIX}-post-des`,
  })
  throw new Error("unassigned replay succeeded")
} catch (error) {
  if (!denied(error)) throw error
  ok("assignment-revoked completed post replay denied")
}
await psql(`
  insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
  values ('${users.verifier}', '${branch}', '${users.admin}')
  on conflict do nothing;
`)

await rpc(admin, "set_branch_active", {
  target_branch: branch,
  active: false,
})
try {
  await rpc(verifier, "post_exceptional_damage_disposition", {
    target_request: destroyReq,
    expected_version: 2,
    idempotency_key: `${PREFIX}-post-des`,
  })
  throw new Error("inactive completed replay succeeded")
} catch (error) {
  if (!denied(error) && !/inactive/i.test(error.message)) throw error
  ok("inactive-godown completed post replay denied without re-post")
}
const inactiveTxns = Number(
  await psql(`
    select count(*) from public.stock_transactions
    where damage_report_id = '${desId}'
      and damage_posting_kind = 'exceptional_writeoff'
  `),
)
if (inactiveTxns !== 1) {
  throw new Error(`inactive replay changed ledger ${inactiveTxns}`)
}
await rpc(admin, "set_branch_active", {
  target_branch: branch,
  active: true,
})

const ready = await rpc(godown, "damage_stock_hold_ready_status", {})
if (ready?.stock_hold_ready !== false) {
  throw new Error(`readiness must stay false ${JSON.stringify(ready)}`)
}
ok("readiness remains false")

console.log(`M5.4E HTTP passed ${passed.length}`)
} finally {
try {
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
  delete from public.damage_exceptional_requests
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
  } finally {
    await flagLock.release()
  }
}
