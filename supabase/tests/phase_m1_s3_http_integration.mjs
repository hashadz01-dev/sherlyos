/**
 * M1-S3 local HTTP integration. Talks to 127.0.0.1:54321 only.
 * Seeds and attributes only disposable m1s3qa fixtures, then wipes lots
 * if dual-write is off and ledger has no lot_id rows.
 */
import { spawn, spawnSync } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m1s3qa"
const PREFIX = "m1s3qa"
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
  const parsed = new URL(url)
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

async function ensureUser(email, fullName) {
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
  return firstUuid(created)
}

async function signIn(anonKey, email) {
  const supabase = createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const result = await supabase.auth.signInWithPassword({ email, password: PASSWORD })
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

async function snapshot() {
  return JSON.parse(
    await psql(`
      select json_build_object(
        'balances', (select coalesce(sum(quantity), 0) from public.stock_balances),
        'ledger_rows', (select count(*) from public.stock_ledger),
        'ledger_net', (select coalesce(sum(quantity), 0) from public.stock_ledger),
        'lots', (select count(*) from public.stock_lots),
        'dual_write', (select value::text from public.app_configuration where key = 'stock.lots.dual_write_enabled'),
        'blocked', (select value::text from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
      );
    `),
  )
}

async function wipeLotsIfSafe() {
  await psql(`
    do $$
    begin
      if exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ) then
        raise exception 'refusing lot wipe while dual-write is enabled';
      end if;
      if exists (select 1 from public.stock_ledger where lot_id is not null) then
        raise exception 'refusing lot wipe while lot-attributed ledger exists';
      end if;
      perform set_config('app.lot_reconciliation_write', 'on', true);
      perform app_private.begin_lot_balance_write('seed');
      delete from public.stock_lot_reconciliation_attributions;
      delete from public.stock_lot_attribution_baselines;
      delete from public.stock_lot_balances;
      delete from public.stock_legacy_lot_seeds;
      delete from public.stock_lots;
      perform app_private.end_lot_balance_write();
      update public.app_configuration
      set value = 'false'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    end;
    $$;
  `)
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
      where sc.session_id = s.id and b.code like '${PREFIX}_%';
    end;
    $$;
  `)
  await wipeLotsIfSafe()
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

async function main() {
  const env = statusEnv()
  assertLocalApi(env.API_URL || API)
  if (!env.ANON_KEY) throw new Error("local anon key missing")
  const health = await fetch(`${API}/auth/v1/health`)
  if (!health.ok) throw new Error("local Auth is not healthy")
  console.log(`effective API ${API}`)

  // Local GoTrue cannot scan NULL confirmation tokens.
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

  const before = await snapshot()
  if (before.dual_write !== "false" || before.blocked !== "false") {
    throw new Error("cutover flags must start false/false")
  }
  if (before.lots !== 0) throw new Error("local lots must be empty before M1-S3 HTTP")

  const users = {
    admin: await ensureUser("admin.m1s3qa@example.com", "S3 Admin"),
    admin2: await ensureUser("admin2.m1s3qa@example.com", "S3 Admin 2"),
    godown: await ensureUser("godown.m1s3qa@example.com", "S3 Godown"),
    keeper: await ensureUser("keeper.m1s3qa@example.com", "S3 Keeper"),
  }

  await psql(`
    insert into public.profiles (id, full_name, is_active)
    values
      ('${users.admin}'::uuid, 'S3 Admin', true),
      ('${users.admin2}'::uuid, 'S3 Admin 2', true),
      ('${users.godown}'::uuid, 'S3 Godown', true),
      ('${users.keeper}'::uuid, 'S3 Keeper', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select u.id, r.id, '${users.admin}'::uuid
    from (values
      ('${users.admin}'::uuid, 'admin'),
      ('${users.admin2}'::uuid, 'admin'),
      ('${users.godown}'::uuid, 'godown_manager'),
      ('${users.keeper}'::uuid, 'store_keeper')
    ) u(id, role_code)
    join public.roles r on r.code = u.role_code
    on conflict do nothing;
  `)

  const admin = await signIn(env.ANON_KEY, "admin.m1s3qa@example.com")
  const admin2 = await signIn(env.ANON_KEY, "admin2.m1s3qa@example.com")
  const godown = await signIn(env.ANON_KEY, "godown.m1s3qa@example.com")
  const keeper = await signIn(env.ANON_KEY, "keeper.m1s3qa@example.com")

  async function ensureMaster(kind, column, code, create) {
    const found = firstUuid(await psql(`select id from public.${kind} where ${column} = '${code}'`))
    if (found) return found
    const created = await create()
    return created.id ?? created
  }

  const branch = await ensureMaster("branches", "code", `${PREFIX}_a`, () =>
    rpc(admin, "create_branch", { branch_code: `${PREFIX}_a`, branch_name: "M1 S3 QA A" }),
  )
  await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
  await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
  const zone = await ensureMaster("zones", "code", `${PREFIX}_z`, () =>
    rpc(admin, "create_zone", {
      target_branch: branch,
      zone_code: `${PREFIX}_z`,
      zone_name: "QA Zone",
      zone_description: null,
    }),
  )
  const crate = await ensureMaster("crates", "code", `${PREFIX}_c1`, () =>
    rpc(admin, "create_crate", {
      target_zone: zone,
      crate_code: `${PREFIX}_c1`,
      crate_name: "QA Crate",
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
  await rpc(admin, "set_product_expiry_policy", {
    target_product: soap,
    new_policy: "expiry_controlled",
  })
  const existingQty = Number(
    (await psql(
      `select coalesce(quantity, 0) from public.stock_balances where crate_id = '${crate}' and product_id = '${soap}'`,
    )).match(/\d+/)?.[0] ?? 0,
  )
  if (existingQty === 0) {
    await rpc(admin, "post_opening_stock", {
      target_product: soap,
      target_crate: crate,
      carton_quantity: 6,
      idempotency_key: `${PREFIX}-open`,
      posting_notes: null,
    })
  }

  const baseline = await snapshot()
  let session = await rpc(admin, "create_lot_reconciliation", {
    target_godown: branch,
    crate_ids: [crate],
    idempotency_key: `${PREFIX}-create-${RUN}`,
    session_notes: "http attribution",
  })
  const line = session.lines[0]
  session = await rpc(godown, "save_lot_reconciliation_count", {
    target_session: session.id,
    expected_version: session.version,
    target_crate: crate,
    target_product: soap,
    counted_quantity: line.expected_quantity,
  })
  session = await rpc(godown, "save_lot_reconciliation_lots", {
    target_session: session.id,
    expected_version: session.version,
    target_line: session.lines[0].id,
    lots: [
      {
        manufacturer_lot_code: "SOAP-HTTP",
        expiry_date: "2028-01-01",
        expiry_unknown: false,
        identity_unknown: false,
        quantity: 4,
        condition: "available",
      },
      {
        identity_unknown: true,
        expiry_unknown: true,
        quantity: line.expected_quantity - 4,
        condition: "available",
      },
    ],
  })
  session = await rpc(godown, "submit_lot_reconciliation", {
    target_session: session.id,
    expected_version: session.version,
    idempotency_key: `${PREFIX}-submit-${RUN}`,
  })
  session = await rpc(admin2, "approve_lot_reconciliation", {
    target_session: session.id,
    expected_version: session.version,
    review_notes: "http",
    idempotency_key: `${PREFIX}-approve-${RUN}`,
  })
  ok("approved matched session over HTTP")

  try {
    await rpc(keeper, "apply_legacy_lot_attribution", {
      target_session: session.id,
      expected_version: session.version,
      idempotency_key: `${PREFIX}-keeper-${RUN}`,
    })
    throw new Error("keeper apply should fail")
  } catch (error) {
    if (error.message === "keeper apply should fail") throw error
    ok("store keeper cannot apply")
  }

  try {
    await rpc(godown, "apply_legacy_lot_attribution", {
      target_session: session.id,
      expected_version: session.version,
      idempotency_key: `${PREFIX}-gm-${RUN}`,
    })
    throw new Error("gm apply should fail")
  } catch (error) {
    if (error.message === "gm apply should fail") throw error
    ok("godown manager cannot apply")
  }

  await rpc(admin, "seed_legacy_stock_lots")
  ok("legacy seed under local HTTP")

  const readiness = await rpc(admin, "get_lot_attribution_readiness", {
    target_session: session.id,
  })
  if (!readiness.eligible) {
    throw new Error(`expected eligible readiness, got ${JSON.stringify(readiness)}`)
  }

  const applied = await rpc(admin, "apply_legacy_lot_attribution", {
    target_session: session.id,
    expected_version: session.version,
    idempotency_key: `${PREFIX}-apply-${RUN}`,
  })
  if (applied.status !== "applied") throw new Error(`expected applied, got ${applied.status}`)
  const replay = await rpc(admin, "apply_legacy_lot_attribution", {
    target_session: session.id,
    expected_version: applied.version,
    idempotency_key: `${PREFIX}-apply-${RUN}`,
  })
  if (replay.status !== "applied") throw new Error("idempotent retry failed")
  ok("admin applied attribution with idempotent retry")

  const after = await snapshot()
  if (after.balances !== baseline.balances || after.ledger_rows !== baseline.ledger_rows) {
    throw new Error("aggregate stock or ledger changed")
  }
  if (after.dual_write !== "false") throw new Error("dual-write was activated")
  if (after.lots < 1) throw new Error("expected attributed lots")
  const known = Number(
    await psql(`
      select coalesce(sum(quantity), 0)
      from public.stock_lot_balances slb
      join public.stock_lots sl on sl.id = slb.lot_id
      where sl.manufacturer_lot_code = 'SOAP-HTTP';
    `),
  )
  if (known !== 4) throw new Error(`expected SOAP-HTTP qty 4, got ${known}`)
  ok("inventory conserved and known lot created")

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
