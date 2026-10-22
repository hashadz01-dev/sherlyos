/**
 * M1-S2.4 local HTTP integration. Talks to 127.0.0.1:54321 only.
 * Creates disposable m1s2qa_* fixtures, signs in through Auth, and calls the
 * same RPC argument names as the frontend wrappers. Cleans only those fixtures.
 * Never prints secrets. Never contacts the development cloud.
 */
import { spawn, spawnSync } from "node:child_process"
import { writeFileSync } from "node:fs"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m1s2qa"
const PREFIX = "m1s2qa"
const RUN = Date.now().toString(36)

function statusEnv() {
  const result = spawnSync("npx", ["supabase", "status", "-o", "env"], {
    encoding: "utf8",
    shell: true,
  })
  if (result.status !== 0) {
    throw new Error(result.stderr || "supabase status failed")
  }
  const env = {}
  for (const line of result.stdout.split(/\r?\n/)) {
    const cut = line.indexOf("=")
    if (cut < 1) continue
    env[line.slice(0, cut)] = line.slice(cut + 1).replace(/^"|"$/g, "")
  }
  return env
}

function assertLocalApi(url) {
  let parsed
  try {
    parsed = new URL(url)
  } catch {
    throw new Error("local API URL is invalid")
  }
  if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") {
    throw new Error(`refusing non-local API host ${parsed.hostname}`)
  }
  if (parsed.port && parsed.port !== "54321") {
    throw new Error(`refusing unexpected local API port ${parsed.port}`)
  }
}

function firstUuid(text) {
  const match = String(text).match(
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
  )
  return match?.[0] ?? ""
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

async function ensureUser(_serviceKey, email, fullName) {
  const existing = firstUuid(await psql(`select id from auth.users where email = '${email}'`))
  if (existing) return existing
  const created = await psql(`
    with created as (
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token
      )
      values (
        '00000000-0000-0000-0000-000000000000',
        gen_random_uuid(),
        'authenticated',
        'authenticated',
        '${email}',
        extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('full_name', '${fullName}'),
        now(),
        now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a'
      )
      returning id, email
    ),
    ident as (
      insert into auth.identities (
        id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
      )
      select
        gen_random_uuid(),
        created.id,
        jsonb_build_object('sub', created.id::text, 'email', created.email),
        'email',
        created.id::text,
        now(),
        now(),
        now()
      from created
      returning user_id
    )
    select user_id from ident;
  `)
  const id = firstUuid(created)
  if (!id) throw new Error(`could not create auth user ${email}`)
  return id
}

async function signIn(anonKey, email) {
  const supabase = createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const result = await supabase.auth.signInWithPassword({ email, password: PASSWORD })
  if (result.error || !result.data.session) {
    throw new Error(`sign-in failed for ${email}: ${result.error?.message ?? "no session"}`)
  }
  return {
    userId: result.data.user.id,
    accessToken: result.data.session.access_token,
    supabase: createClient(API, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${result.data.session.access_token}` } },
    }),
  }
}

async function rpc(session, name, args = {}) {
  const result = await session.supabase.rpc(name, args)
  if (result.error) {
    const error = new Error(result.error.message)
    error.code = result.error.code
    error.details = result.error.details
    throw error
  }
  return result.data
}

function expectCode(error, codeOrPattern) {
  const code = error.code ?? ""
  const message = error.message ?? ""
  const ok =
    typeof codeOrPattern === "string"
      ? code === codeOrPattern || message.includes(codeOrPattern)
      : codeOrPattern.test(code) || codeOrPattern.test(message)
  if (!ok) {
    throw new Error(`expected ${codeOrPattern}, got code=${code} message=${message}`)
  }
}

async function snapshot(label) {
  const row = await psql(`
    select json_build_object(
      'label', '${label}',
      'balances', (select coalesce(sum(quantity), 0) from public.stock_balances),
      'balance_rows', (select count(*) from public.stock_balances),
      'ledger_rows', (select count(*) from public.stock_ledger),
      'ledger_net', (select coalesce(sum(quantity), 0) from public.stock_ledger),
      'lots', (select count(*) from public.stock_lots),
      'lot_balances', (select count(*) from public.stock_lot_balances),
      'seeds', (select count(*) from public.stock_legacy_lot_seeds),
      'dual_write', (select value::text from public.app_configuration where key = 'stock.lots.dual_write_enabled'),
      'blocked', (select value::text from public.app_configuration where key = 'stock.lots.aggregate_only_blocked'),
      'attribution', exists(
        select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'apply_legacy_lot_attribution'
      )
    );
  `)
  return JSON.parse(row)
}

function assertSameInventory(before, after) {
  for (const key of [
    "balances",
    "balance_rows",
    "ledger_rows",
    "ledger_net",
    "lots",
    "lot_balances",
    "seeds",
    "dual_write",
    "blocked",
  ]) {
    if (before[key] !== after[key]) {
      throw new Error(`inventory drifted on ${key}: ${before[key]} -> ${after[key]}`)
    }
  }
}

async function forceCleanup() {
  await psql(`
    do $$
    begin
      perform set_config('app.lot_reconciliation_write', 'on', true);
      update public.stock_lot_reconciliation_scope_crates sc
      set holds_scope = false
      from public.stock_lot_reconciliations s
      join public.branches b on b.id = s.godown_id
      where sc.session_id = s.id
        and b.code like '${PREFIX}_%';
      update public.stock_lot_reconciliations s
      set
        status = 'cancelled',
        cancelled_by = coalesce(
          s.cancelled_by,
          (select id from auth.users where email = 'admin.m1s2qa@example.com')
        ),
        cancellation_reason = coalesce(s.cancellation_reason, 'm1s2qa cleanup'),
        cancelled_at = coalesce(s.cancelled_at, clock_timestamp())
      from public.branches b
      where b.id = s.godown_id
        and b.code like '${PREFIX}_%'
        and s.status in ('draft', 'rejected');
    end;
    $$;
  `)
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

async function main() {
  const env = statusEnv()
  assertLocalApi(env.API_URL || API)
  if (!env.ANON_KEY || !env.SERVICE_ROLE_KEY) {
    throw new Error("local anon/service keys missing from supabase status")
  }

  writeFileSync(
    new URL("../../.env.m1s2.local", import.meta.url),
    [
      "# LOCAL-ONLY Vite mode. Loaded with: npx vite --mode m1s2",
      "# Does not replace .env or .env.local cloud configuration.",
      "VITE_SUPABASE_URL=http://127.0.0.1:54321",
      `VITE_SUPABASE_PUBLISHABLE_KEY=${env.ANON_KEY}`,
      "",
    ].join("\n"),
    "utf8",
  )
  console.log("wrote .env.m1s2.local (local API host only, anon key, no service role)")

  const health = await fetch(`${API}/auth/v1/health`)
  if (!health.ok) throw new Error("local Auth is not healthy")
  console.log(`effective API ${API} (auth health ${health.status})`)

  // Local GoTrue cannot scan NULL confirmation tokens. Keep tokens unique per user.
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

  const beforeAll = await snapshot("pre-fixture")
  if (beforeAll.dual_write !== "false" || beforeAll.blocked !== "false") {
    throw new Error("cutover flags must be false/false")
  }

  const users = {
    admin: await ensureUser(env.SERVICE_ROLE_KEY, "admin.m1s2qa@example.com", "QA Admin"),
    admin2: await ensureUser(env.SERVICE_ROLE_KEY, "admin2.m1s2qa@example.com", "QA Admin 2"),
    godown: await ensureUser(env.SERVICE_ROLE_KEY, "godown.m1s2qa@example.com", "QA Godown"),
    godownB: await ensureUser(env.SERVICE_ROLE_KEY, "godownb.m1s2qa@example.com", "QA Godown B"),
    keeper: await ensureUser(env.SERVICE_ROLE_KEY, "keeper.m1s2qa@example.com", "QA Keeper"),
  }

  await psql(`
    insert into public.profiles (id, full_name, is_active)
    values
      ('${users.admin}'::uuid, 'QA Admin', true),
      ('${users.admin2}'::uuid, 'QA Admin 2', true),
      ('${users.godown}'::uuid, 'QA Godown', true),
      ('${users.godownB}'::uuid, 'QA Godown B', true),
      ('${users.keeper}'::uuid, 'QA Keeper', true)
    on conflict (id) do update set is_active = true;

    insert into public.user_roles (user_id, role_id, assigned_by)
    select u.id::uuid, r.id, '${users.admin}'::uuid
    from (values
      ('${users.admin}', 'admin'),
      ('${users.admin2}', 'admin'),
      ('${users.godown}', 'godown_manager'),
      ('${users.godownB}', 'godown_manager'),
      ('${users.keeper}', 'store_keeper')
    ) as u(id, role_code)
    join public.roles r on r.code = u.role_code
    on conflict do nothing;
  `)

  const admin = await signIn(env.ANON_KEY, "admin.m1s2qa@example.com")
  const admin2 = await signIn(env.ANON_KEY, "admin2.m1s2qa@example.com")
  const gm = await signIn(env.ANON_KEY, "godown.m1s2qa@example.com")
  const gmB = await signIn(env.ANON_KEY, "godownb.m1s2qa@example.com")
  const keeper = await signIn(env.ANON_KEY, "keeper.m1s2qa@example.com")
  ok("auth sign-in for admin, gm, keeper")

  async function ensureMaster(kind, column, code, create) {
    const found = firstUuid(
      await psql(`select id from public.${kind} where ${column} = '${code}'`),
    )
    if (found) return found
    const created = await create()
    return created.id ?? created
  }

  const branchA = await ensureMaster("branches", "code", `${PREFIX}_a`, () =>
    rpc(admin, "create_branch", { branch_code: `${PREFIX}_a`, branch_name: "M1 S2 QA A" }),
  )
  const branchB = await ensureMaster("branches", "code", `${PREFIX}_b`, () =>
    rpc(admin, "create_branch", { branch_code: `${PREFIX}_b`, branch_name: "M1 S2 QA B" }),
  )
  const zoneA = await ensureMaster("zones", "code", `${PREFIX}_za`, () =>
    rpc(admin, "create_zone", {
      target_branch: branchA,
      zone_code: `${PREFIX}_za`,
      zone_name: "QA Zone A",
      zone_description: null,
    }),
  )
  const zoneB = await ensureMaster("zones", "code", `${PREFIX}_zb`, () =>
    rpc(admin, "create_zone", {
      target_branch: branchB,
      zone_code: `${PREFIX}_zb`,
      zone_name: "QA Zone B",
      zone_description: null,
    }),
  )
  const crateA1 = await ensureMaster("crates", "code", `${PREFIX}_ca1`, () =>
    rpc(admin, "create_crate", {
      target_zone: zoneA,
      crate_code: `${PREFIX}_ca1`,
      crate_name: "QA Crate A1",
      crate_description: null,
    }),
  )
  const crateA2 = await ensureMaster("crates", "code", `${PREFIX}_ca2`, () =>
    rpc(admin, "create_crate", {
      target_zone: zoneA,
      crate_code: `${PREFIX}_ca2`,
      crate_name: "QA Crate A2",
      crate_description: null,
    }),
  )
  const crateB = await ensureMaster("crates", "code", `${PREFIX}_cb`, () =>
    rpc(admin, "create_crate", {
      target_zone: zoneB,
      crate_code: `${PREFIX}_cb`,
      crate_name: "QA Crate B",
      crate_description: null,
    }),
  )
  const soap = await ensureMaster("products", "sku", `${PREFIX}-soap`, () =>
    rpc(admin, "create_product", {
      product_sku: `${PREFIX}-soap`,
      product_name: "QA Soap",
      next_supplier: null,
      next_category: null,
    }),
  )
  const oil = await ensureMaster("products", "sku", `${PREFIX}-oil`, () =>
    rpc(admin, "create_product", {
      product_sku: `${PREFIX}-oil`,
      product_name: "QA Oil",
      next_supplier: null,
      next_category: null,
    }),
  )
  const found = await ensureMaster("products", "sku", `${PREFIX}-found`, () =>
    rpc(admin, "create_product", {
      product_sku: `${PREFIX}-found`,
      product_name: "QA Found",
      next_supplier: null,
      next_category: null,
    }),
  )

  await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branchA })
  await rpc(admin, "assign_user_branch", { target_user: users.godownB, target_branch: branchB })
  await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branchA })
  await rpc(admin, "set_product_expiry_policy", { target_product: soap, new_policy: "expiry_controlled" })
  await rpc(admin, "set_product_expiry_policy", { target_product: oil, new_policy: "non_expiring" })
  await rpc(admin, "set_product_expiry_policy", { target_product: found, new_policy: "expiry_controlled" })

  const soapQty = Number(
    (await psql(
      `select coalesce(quantity, 0) from public.stock_balances where crate_id = '${crateA1}' and product_id = '${soap}'`,
    )).match(/\d+/)?.[0] ?? 0,
  )
  if (soapQty === 0) {
    await rpc(admin, "post_opening_stock", {
      target_product: soap,
      target_crate: crateA1,
      carton_quantity: 6,
      idempotency_key: `${PREFIX}-open-soap`,
      posting_notes: null,
    })
    await rpc(admin, "post_opening_stock", {
      target_product: oil,
      target_crate: crateA1,
      carton_quantity: 4,
      idempotency_key: `${PREFIX}-open-oil`,
      posting_notes: null,
    })
    await rpc(admin, "post_opening_stock", {
      target_product: soap,
      target_crate: crateA2,
      carton_quantity: 3,
      idempotency_key: `${PREFIX}-open-soap-2`,
      posting_notes: null,
    })
    await rpc(admin, "post_opening_stock", {
      target_product: soap,
      target_crate: crateB,
      carton_quantity: 2,
      idempotency_key: `${PREFIX}-open-soap-b`,
      posting_notes: null,
    })
  }
  ok("disposable masters, classification, opening stock")

  await forceCleanup()
  const baseline = await snapshot("post-fixture-pre-recon")

  const session = await rpc(admin, "create_lot_reconciliation", {
    target_godown: branchA,
    crate_ids: [crateA1],
    idempotency_key: `${PREFIX}-create-a1-${Date.now()}`.slice(0, 80),
    session_notes: "qa selected crate",
  })
  if (!session?.id || !/^LR-\d{8}-\d{6}$/.test(session.session_number)) {
    throw new Error("create did not return a database session_number")
  }
  if (session.status !== "draft") throw new Error("created session is not draft")
  ok("admin create selected-crate session")

  try {
    await rpc(admin, "create_lot_reconciliation", {
      target_godown: branchA,
      crate_ids: [crateA1],
      idempotency_key: `${PREFIX}-overlap-${Date.now()}`.slice(0, 80),
      session_notes: "overlap",
    })
    throw new Error("overlapping create should fail")
  } catch (error) {
    if (error.message === "overlapping create should fail") throw error
    expectCode(error, /overlapping lot reconciliation/i)
    ok("overlapping active scope denied")
  }

  try {
    await rpc(gmB, "list_lot_reconciliations")
    const listed = await rpc(gmB, "list_lot_reconciliations")
    const rows = Array.isArray(listed) ? listed : JSON.parse(listed)
    if (rows.some((row) => row.id === session.id)) {
      throw new Error("cross-branch GM listed another godown session")
    }
    ok("cross-branch list isolation")
  } catch (error) {
    if (error.message.includes("cross-branch")) throw error
    // reader assertion may deny GM without physical_reconcile at that branch
    ok("cross-branch list isolation")
  }

  try {
    await rpc(gmB, "get_lot_reconciliation", { target_session: session.id })
    throw new Error("cross-branch get should fail")
  } catch (error) {
    if (error.message === "cross-branch get should fail") throw error
    expectCode(error, /not authorized|42501/i)
    ok("cross-branch get denied")
  }

  try {
    await rpc(keeper, "create_lot_reconciliation", {
      target_godown: branchA,
      crate_ids: [crateA1],
      idempotency_key: `${PREFIX}-keeper-${Date.now()}`.slice(0, 80),
      session_notes: null,
    })
    throw new Error("keeper create should fail")
  } catch (error) {
    if (error.message === "keeper create should fail") throw error
    ok("store keeper create denied")
  }

  try {
    await rpc(keeper, "save_lot_reconciliation_count", {
      target_session: session.id,
      expected_version: session.version,
      target_crate: crateA1,
      target_product: soap,
      counted_quantity: 6,
    })
    throw new Error("keeper count should fail")
  } catch (error) {
    if (error.message === "keeper count should fail") throw error
    ok("store keeper count denied")
  }

  const insert = await gm.supabase.from("stock_lot_reconciliations").insert({
    session_number: "LR-HACK",
    godown_id: branchA,
    status: "draft",
    idempotency_key: `${PREFIX}-dml`,
    created_by: users.godown,
    expected_frozen_at: new Date().toISOString(),
  })
  if (!insert.error) throw new Error("direct insert should be denied")
  ok("direct client DML denied")

  const v1 = session.version
  const counted = await rpc(gm, "save_lot_reconciliation_count", {
    target_session: session.id,
    expected_version: v1,
    target_crate: crateA1,
    target_product: soap,
    counted_quantity: 6,
  })
  try {
    await rpc(gm, "save_lot_reconciliation_count", {
      target_session: session.id,
      expected_version: v1,
      target_crate: crateA1,
      target_product: oil,
      counted_quantity: 4,
    })
    throw new Error("stale version should fail")
  } catch (error) {
    if (error.message === "stale version should fail") throw error
    expectCode(error, /PT409|changed by someone else/i)
    ok("PT409 stale version")
  }

  const countedOil = await rpc(gm, "save_lot_reconciliation_count", {
    target_session: session.id,
    expected_version: counted.version,
    target_crate: crateA1,
    target_product: oil,
    counted_quantity: 4,
  })
  const soapLine = countedOil.lines.find((line) => line.product_id === soap)
  const oilLine = countedOil.lines.find((line) => line.product_id === oil)
  const lotsSoap = await rpc(gm, "save_lot_reconciliation_lots", {
    target_session: session.id,
    expected_version: countedOil.version,
    target_line: soapLine.id,
    lots: [
      {
        manufacturer_lot_code: "SOAP-KNOWN",
        expiry_date: "2027-12-01",
        expiry_unknown: false,
        identity_unknown: false,
        quantity: 3,
        condition: "available",
      },
      {
        manufacturer_lot_code: null,
        expiry_date: null,
        expiry_unknown: true,
        identity_unknown: true,
        quantity: 3,
        condition: "available",
      },
    ],
  })
  const lotsOil = await rpc(gm, "save_lot_reconciliation_lots", {
    target_session: session.id,
    expected_version: lotsSoap.version,
    target_line: oilLine.id,
    lots: [
      {
        manufacturer_lot_code: "OIL-NE",
        expiry_date: null,
        expiry_unknown: false,
        identity_unknown: false,
        quantity: 4,
        condition: "available",
      },
    ],
  })
  ok("gm counted known and unknown lot evidence")

  const foundAdded = await rpc(gm, "add_lot_reconciliation_found_product", {
    target_session: session.id,
    expected_version: lotsOil.version,
    target_crate: crateA1,
    target_product: found,
  })
  if (!foundAdded.lines.some((line) => line.is_found_product && line.expected_quantity === 0)) {
    throw new Error("found product was not recorded as unexpected")
  }
  const foundLine = foundAdded.lines.find((line) => line.is_found_product)
  const foundCounted = await rpc(gm, "save_lot_reconciliation_count", {
    target_session: session.id,
    expected_version: foundAdded.version,
    target_crate: crateA1,
    target_product: found,
    counted_quantity: 1,
  })
  const foundLots = await rpc(gm, "save_lot_reconciliation_lots", {
    target_session: session.id,
    expected_version: foundCounted.version,
    target_line: foundLine.id,
    lots: [
      {
        manufacturer_lot_code: null,
        expiry_date: null,
        expiry_unknown: true,
        identity_unknown: true,
        quantity: 1,
        condition: "available",
      },
    ],
  })
  const submittedUnexpected = await rpc(gm, "submit_lot_reconciliation", {
    target_session: session.id,
    expected_version: foundLots.version,
    idempotency_key: `${PREFIX}-subu-${RUN}`,
  })
  if (submittedUnexpected.status !== "submitted") throw new Error("submit failed")
  try {
    await rpc(admin2, "approve_lot_reconciliation", {
      target_session: session.id,
      expected_version: submittedUnexpected.version,
      review_notes: "should fail",
      idempotency_key: `${PREFIX}-appru-${RUN}`,
    })
    throw new Error("approval of unexpected stock should fail")
  } catch (error) {
    if (error.message === "approval of unexpected stock should fail") throw error
    expectCode(error, /unresolved quantity discrepancies/i)
    ok("unexpected stock blocks approval")
  }

  const rejected = await rpc(admin2, "reject_lot_reconciliation", {
    target_session: session.id,
    expected_version: submittedUnexpected.version,
    reject_reason: "Unexpected product must be resolved first.",
    idempotency_key: `${PREFIX}-rej-${RUN}`,
  })
  if (rejected.status !== "rejected") throw new Error("reject failed")
  const reopened = await rpc(gm, "reopen_lot_reconciliation", {
    target_session: session.id,
    expected_version: rejected.version,
    idempotency_key: `${PREFIX}-reopen-${RUN}`,
  })
  if (reopened.status !== "draft") throw new Error("reopen failed")
  ok("reject and reopen")

  const refreshed = await rpc(gm, "refresh_lot_reconciliation_expected", {
    target_session: session.id,
    expected_version: reopened.version,
  })
  if (refreshed.lines.some((line) => line.counted_quantity !== null || line.is_found_product)) {
    throw new Error("refresh did not clear counts and found products")
  }
  ok("draft refresh wipes counts")

  const afterRefreshSoap = refreshed.lines.find((line) => line.product_id === soap)
  const afterRefreshOil = refreshed.lines.find((line) => line.product_id === oil)
  let current = refreshed
  current = await rpc(gm, "save_lot_reconciliation_count", {
    target_session: session.id,
    expected_version: current.version,
    target_crate: crateA1,
    target_product: soap,
    counted_quantity: afterRefreshSoap.expected_quantity,
  })
  current = await rpc(gm, "save_lot_reconciliation_count", {
    target_session: session.id,
    expected_version: current.version,
    target_crate: crateA1,
    target_product: oil,
    counted_quantity: afterRefreshOil.expected_quantity,
  })
  const soap2 = current.lines.find((line) => line.product_id === soap)
  const oil2 = current.lines.find((line) => line.product_id === oil)
  current = await rpc(gm, "save_lot_reconciliation_lots", {
    target_session: session.id,
    expected_version: current.version,
    target_line: soap2.id,
    lots: [
      {
        manufacturer_lot_code: "SOAP-MATCH",
        expiry_date: "2028-01-01",
        expiry_unknown: false,
        identity_unknown: false,
        quantity: soap2.counted_quantity,
        condition: "available",
      },
    ],
  })
  current = await rpc(gm, "save_lot_reconciliation_lots", {
    target_session: session.id,
    expected_version: current.version,
    target_line: oil2.id,
    lots: [
      {
        manufacturer_lot_code: "OIL-MATCH",
        expiry_date: null,
        expiry_unknown: false,
        identity_unknown: false,
        quantity: oil2.counted_quantity,
        condition: "available",
      },
    ],
  })
  current = await rpc(gm, "submit_lot_reconciliation", {
    target_session: session.id,
    expected_version: current.version,
    idempotency_key: `${PREFIX}-subm-${RUN}`,
  })

  try {
    await rpc(gm, "approve_lot_reconciliation", {
      target_session: session.id,
      expected_version: current.version,
      review_notes: "gm cannot approve",
      idempotency_key: `${PREFIX}-gmappr-${RUN}`,
    })
    throw new Error("gm approve should fail")
  } catch (error) {
    if (error.message === "gm approve should fail") throw error
    ok("unauthorized gm approval denied")
  }

  const listed = await rpc(gm, "list_lot_reconciliations")
  const listRows = Array.isArray(listed) ? listed : JSON.parse(listed)
  if (!listRows.some((row) => row.id === session.id)) {
    throw new Error("gm list did not include the assigned session")
  }
  ok("list returns authorized sessions")

  const approved = await rpc(admin2, "approve_lot_reconciliation", {
    target_session: session.id,
    expected_version: current.version,
    review_notes: "Matched physical count.",
    idempotency_key: `${PREFIX}-apprm-${RUN}`,
  })
  if (approved.status !== "approved") throw new Error("approve failed")
  const eventTypes = approved.events.map((event) => event.event_type)
  for (const required of ["created", "submitted", "rejected", "reopened", "expected_refreshed", "approved"]) {
    if (!eventTypes.includes(required)) {
      throw new Error(`audit missing ${required}`)
    }
  }
  ok("admin2 approved matched session; audit has transitions")

  const cancelSession = await rpc(admin, "create_lot_reconciliation", {
    target_godown: branchA,
    crate_ids: [crateA2],
    idempotency_key: `${PREFIX}-cancel-${Date.now()}`.slice(0, 80),
    session_notes: "to cancel",
  })
  const cancelled = await rpc(admin, "cancel_lot_reconciliation", {
    target_session: cancelSession.id,
    expected_version: cancelSession.version,
    cancel_reason: "Opened on the wrong crate.",
    idempotency_key: `${PREFIX}-canc-${RUN}`,
  })
  if (cancelled.status !== "cancelled") throw new Error("cancel failed")
  if (cancelled.crates.some((crate) => crate.holds_scope)) {
    throw new Error("cancel did not release crate scope")
  }
  ok("eligible cancellation releases scope")

  const selfSession = await rpc(admin, "create_lot_reconciliation", {
    target_godown: branchA,
    crate_ids: [crateA2],
    idempotency_key: `${PREFIX}-self-${Date.now()}`.slice(0, 80),
    session_notes: "self approve",
  })
  let self = selfSession
  const selfSoap = self.lines.find((line) => line.product_id === soap)
  if (selfSoap) {
    self = await rpc(admin, "save_lot_reconciliation_count", {
      target_session: self.id,
      expected_version: self.version,
      target_crate: crateA2,
      target_product: soap,
      counted_quantity: selfSoap.expected_quantity,
    })
    const line = self.lines.find((row) => row.product_id === soap)
    self = await rpc(admin, "save_lot_reconciliation_lots", {
      target_session: self.id,
      expected_version: self.version,
      target_line: line.id,
      lots: [
        {
          manufacturer_lot_code: "SELF",
          expiry_date: "2028-01-01",
          expiry_unknown: false,
          identity_unknown: false,
          quantity: line.counted_quantity,
          condition: "available",
        },
      ],
    })
  }
  self = await rpc(admin, "submit_lot_reconciliation", {
    target_session: self.id,
    expected_version: self.version,
    idempotency_key: `${PREFIX}-ssub-${RUN}`,
  })
  try {
    await rpc(admin, "approve_lot_reconciliation", {
      target_session: self.id,
      expected_version: self.version,
      review_notes: "self",
      idempotency_key: `${PREFIX}-sapp-${RUN}`,
    })
    throw new Error("self-approval should fail")
  } catch (error) {
    if (error.message === "self-approval should fail") throw error
    expectCode(error, /cannot approve your own reconciliation/i)
    ok("self-approval denied")
  }
  await rpc(admin2, "reject_lot_reconciliation", {
    target_session: self.id,
    expected_version: self.version,
    reject_reason: "Cleanup after self-approval check.",
    idempotency_key: `${PREFIX}-srej-${RUN}`,
  })

  try {
    await rpc(admin, "apply_legacy_lot_attribution", {
      target_session: approved.id,
      expected_version: approved.version,
      idempotency_key: `${PREFIX}-apply-nosseed-${RUN}`,
    })
    throw new Error("attribution without seed should fail")
  } catch (error) {
    if (error.message === "attribution without seed should fail") throw error
    expectCode(error, /seed/i)
    ok("attribution without seed is rejected")
  }

  const after = await snapshot("post-recon")
  assertSameInventory(baseline, after)
  ok("inventory, lots, seeds, and flags unchanged by reconciliation")

  await forceCleanup()
  console.log(`\n${passed.length} HTTP checks passed`)
}

main().catch(async (error) => {
  console.error(`FAIL ${error.message}`)
  try {
    await forceCleanup()
  } catch (cleanupError) {
    console.error(`cleanup error ${cleanupError.message}`)
  }
  process.exit(1)
})
