/**
 * M5.4F local HTTP proofs for dashboard posted totals, quarantine
 * returned-supplier, fail-closed storage submit, and role denial.
 * Does not flip damage.stock_hold_ready. Shared Docker flags: run sequentially
 * with other M5.2–M5.4F SQL/HTTP/concurrency suites.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m54f"
const PREFIX = "m54fhttp"
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
    /not authorized|permission|not approved|not ready/i.test(
      error.message || "",
    )
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

const flagLock = await holdStockFlagLock()

try {
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
    admin: await ensureUser(`admin.${PREFIX}@example.com`, "M54F Admin"),
    godown: await ensureUser(`godown.${PREFIX}@example.com`, "M54F Godown"),
    sales: await ensureUser(`sales.${PREFIX}@example.com`, "M54F Sales"),
  }

  await psql(`
    insert into public.profiles (id, full_name, is_active)
    values
      ('${users.admin}', 'M54F Admin', true),
      ('${users.godown}', 'M54F Godown', true),
      ('${users.sales}', 'M54F Sales', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select u.id, r.id, '${users.admin}'::uuid
    from (values
      ('${users.admin}'::uuid, 'admin'),
      ('${users.godown}'::uuid, 'godown_manager'),
      ('${users.sales}'::uuid, 'salesperson')
    ) u(id, role_code)
    join public.roles r on r.code = u.role_code
    on conflict do nothing;
  `)

  const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
  const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
  const sales = await signIn(env.ANON_KEY, `sales.${PREFIX}@example.com`)

  const branch = await rpc(admin, "create_branch", {
    branch_code: `${PREFIX}_${RUN}`,
    branch_name: "M54F HTTP Godown",
  })
  await rpc(admin, "assign_user_branch", {
    target_user: users.godown,
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
    product_name: "M54F HTTP soap",
    next_supplier: null,
    next_category: null,
  })

  await psql(`
    set session_replication_role = replica;
    insert into public.damage_reports (
      report_number, scenario, godown_id, status, version, reporter_user_id,
      verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
    ) values
      ('${PREFIX}-ord-${RUN}', 'storage', '${branch}', 'verified', 3, '${users.godown}',
       '${users.godown}', now(), '${PREFIX}-ord-key', '${PREFIX}-ord-fp', 'ordinary'),
      ('${PREFIX}-des-${RUN}', 'storage', '${branch}', 'verified', 3, '${users.godown}',
       '${users.godown}', now(), '${PREFIX}-des-key', '${PREFIX}-des-fp', 'destroy');

    insert into public.damage_report_lines (
      damage_report_id, product_id, crate_id, quantity_cases, damage_reason
    )
    select id, '${product}', '${crate}',
      case when report_number like '%-ord-%' then 3 else 2 end,
      'crushed'
    from public.damage_reports
    where report_number in ('${PREFIX}-ord-${RUN}', '${PREFIX}-des-${RUN}');

    insert into public.damage_stock_holds (
      damage_report_id, damage_report_line_id, product_id, crate_id,
      quantity_cases, hold_kind, status
    )
    select r.id, l.id, '${product}', '${crate}', l.quantity_cases,
      'on_hand_deduction', 'written_off'
    from public.damage_reports r
    join public.damage_report_lines l on l.damage_report_id = r.id
    where r.report_number in ('${PREFIX}-ord-${RUN}', '${PREFIX}-des-${RUN}');

    insert into public.damage_report_events (
      damage_report_id, actor_id, action, previous_status, next_status
    )
    select id, '${users.godown}', 'ordinary_writeoff', 'verified', 'verified'
    from public.damage_reports where report_number = '${PREFIX}-ord-${RUN}';

    insert into public.damage_report_events (
      damage_report_id, actor_id, action, previous_status, next_status
    )
    select id, '${users.godown}', 'exceptional_posted', 'verified', 'verified'
    from public.damage_reports where report_number = '${PREFIX}-des-${RUN}';
    set session_replication_role = origin;
  `)

  const dash = await rpc(godown, "get_damage_dashboard", {})
  if (Number(dash?.totals?.ordinary_writeoff_cases) !== 3) {
    throw new Error(`ordinary dashboard ${JSON.stringify(dash?.totals)}`)
  }
  if (Number(dash?.totals?.exceptional_writeoff_cases) !== 2) {
    throw new Error(`exceptional dashboard ${JSON.stringify(dash?.totals)}`)
  }
  if (Number(dash?.totals?.active_hold_cases) !== 0) {
    throw new Error(`posted history leaked into current holds ${JSON.stringify(dash?.totals)}`)
  }
  ok("dashboard distinguishes ordinary vs exceptional posted cartons")

  try {
    await rpc(sales, "get_damage_dashboard", {})
    throw new Error("salesperson dashboard succeeded")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("salesperson cannot execute get_damage_dashboard")

  const draft = await rpc(godown, "create_damage_report", {
    scenario: "storage",
    target_godown: branch,
    report_lines: [
      {
        product_id: product,
        crate_id: crate,
        quantity_cases: 1,
        damage_reason: "crushed",
      },
    ],
    idempotency_key: `${PREFIX}-ready-${RUN}`,
    notes: "fail closed",
  })
  try {
    await rpc(godown, "submit_damage_report", {
      target_report: draft.id,
      expected_version: draft.version,
      idempotency_key: `${PREFIX}-ready-sub-${RUN}`,
    })
    throw new Error("storage submit succeeded while readiness is false")
  } catch (error) {
    if (
      !denied(error) &&
      !/not ready|isolation/i.test(error.message || "") &&
      error.code !== "23514" &&
      error.code !== "PGRST202"
    ) {
      throw error
    }
  }
  ok("storage submit fail-closed while damage.stock_hold_ready=false")

  const ready = await rpc(godown, "damage_stock_hold_ready_status", {})
  if (ready?.stock_hold_ready !== false) {
    throw new Error(`readiness must stay false ${JSON.stringify(ready)}`)
  }
  ok("readiness remains false")

  console.log(`M5.4F HTTP passed ${passed.length}`)
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
      delete from public.damage_report_lines
      where damage_report_id in (
        select id from public.damage_reports where report_number like '${PREFIX}-%'
      );
      delete from public.damage_reports where report_number like '${PREFIX}-%';
      delete from public.stock_ledger
      where product_id in (select id from public.products where sku like '${PREFIX}-%');
      delete from public.stock_transactions
      where product_id in (select id from public.products where sku like '${PREFIX}-%');
      delete from public.stock_balances
      where product_id in (select id from public.products where sku like '${PREFIX}-%')
         or crate_id in (select id from public.crates where code like '${PREFIX}_%');
      delete from public.products where sku like '${PREFIX}-%';
      delete from public.crates where code like '${PREFIX}_%';
      delete from public.zones where code like '${PREFIX}_%';
      delete from public.user_branch_assignments
      where branch_id in (select id from public.branches where code like '${PREFIX}_%');
      delete from public.branches where code like '${PREFIX}_%' or code like '${PREFIX}\\_%';
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
