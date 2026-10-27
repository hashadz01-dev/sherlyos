/**
 * M6.2 independent-session races: submit, approve vs reject, update.
 * Local Docker only. Does not flip damage/lot flags. Zero stock effects.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m62c_${RUN}`

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

function session(sql) {
  return new Promise((resolve) => {
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
      resolve({ code, text: output.trim() })
    })
    child.stdin.end(sql)
  })
}

function lastLine(text) {
  return String(text).split(/\r?\n/).filter(Boolean).at(-1)
}

function jwtSql(userId) {
  return `
    set local role authenticated;
    select set_config('request.jwt.claim.sub', '${userId}', true);
    select set_config(
      'request.jwt.claims',
      json_build_object('sub', '${userId}'::uuid, 'role', 'authenticated')::text,
      true
    );
  `
}

const ids = {}
const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

async function setup() {
  await psql(`
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      accounts2_id uuid;
      branch_uuid uuid;
      supplier_uuid uuid;
      product_uuid uuid;
      crate_uuid uuid;
      zone_uuid uuid;
    begin
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      select
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        email, extensions.crypt('local-only', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('full_name', email), now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      from (values
        ('admin.${PREFIX}@example.com'),
        ('accounts.${PREFIX}@example.com'),
        ('accounts2.${PREFIX}@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.${PREFIX}@example.com';
      select id into accounts_id from auth.users where email = 'accounts.${PREFIX}@example.com';
      select id into accounts2_id from auth.users where email = 'accounts2.${PREFIX}@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M62C Admin', true),
        (accounts_id, 'M62C Accounts', true),
        (accounts2_id, 'M62C Accounts 2', true)
      on conflict (id) do update set is_active = true;

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
          on conflict do nothing;
      end;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts_id, roles.id, admin_id from public.roles where roles.code = 'accounts'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts2_id, roles.id, admin_id from public.roles where roles.code = 'accounts'
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      branch_uuid := public.create_branch('${PREFIX}', 'M62C');
      perform public.assign_user_branch(accounts_id, branch_uuid);
      perform public.assign_user_branch(accounts2_id, branch_uuid);
      zone_uuid := public.create_zone(branch_uuid, 'z', 'Z', null);
      crate_uuid := public.create_crate(zone_uuid, 'c', 'C', null);
      supplier_uuid := public.create_supplier('${PREFIX} brand', null, null);
      product_uuid := public.create_product('${PREFIX}-sku', 'M62C soap', supplier_uuid, null);

      set session_replication_role = replica;
      insert into public.stock_balances (crate_id, product_id, quantity)
      values (crate_uuid, product_uuid, 9)
      on conflict (crate_id, product_id) do update set quantity = 9;
      set session_replication_role = origin;
    end $$;
  `)
  ids.admin = lastLine(await psql(`select id from auth.users where email = 'admin.${PREFIX}@example.com'`))
  ids.accounts = lastLine(await psql(`select id from auth.users where email = 'accounts.${PREFIX}@example.com'`))
  ids.accounts2 = lastLine(await psql(`select id from auth.users where email = 'accounts2.${PREFIX}@example.com'`))
  ids.branch = lastLine(await psql(`select id from public.branches where code = '${PREFIX}'`))
  ids.supplier = lastLine(await psql(`select id from public.suppliers where name = '${PREFIX} brand'`))
  ids.product = lastLine(await psql(`select id from public.products where sku = '${PREFIX}-sku'`))
  ids.ledger = lastLine(await psql(`select count(*) from public.stock_ledger`))
  ids.balances = lastLine(
    await psql(`select coalesce(sum(quantity),0) from public.stock_balances where product_id = '${ids.product}'::uuid`),
  )
}

async function createDraft(key) {
  const text = await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.create_stock_refill_request(
      '${ids.supplier}'::uuid,
      '${ids.branch}'::uuid,
      jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', 2)),
      '${key}',
      null
    );
    commit;
  `)
  const match = text.match(/"id"\s*:\s*"([0-9a-f-]+)"/i)
  return match?.[1] ?? lastLine(await psql(`
    select id::text from public.stock_refill_requests where idempotency_key = '${key}'
  `))
}

async function versionOf(requestId) {
  return lastLine(await psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`))
}

function isConflict(text) {
  return /changed by someone else|PT409|cannot be (submitted|approved|held|rejected|edited)|42501/i.test(
    text,
  )
}

function requestIdFrom(text) {
  return String(text).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1] ?? ""
}

function createSql(userId, key, qty) {
  return `
    begin;
    ${jwtSql(userId)}
    select pg_sleep(0.12);
    select public.create_stock_refill_request(
      '${ids.supplier}'::uuid,
      '${ids.branch}'::uuid,
      jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', ${qty})),
      '${key}',
      null
    );
    commit;
  `
}

try {
  await setup()
  if (!ids.admin || !ids.accounts || !ids.branch) {
    throw new Error(`setup missing ids ${JSON.stringify(ids)}`)
  }

  const sameKey = `${PREFIX}-same`
  {
    const [a, b] = await Promise.all([
      session(createSql(ids.accounts, sameKey, 2)),
      session(createSql(ids.accounts, sameKey, 2)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    if (wins.length < 1) throw new Error(`same-key create produced no winner: ${JSON.stringify([a, b])}`)
    const idsFound = [...new Set(wins.map((row) => requestIdFrom(row.text)).filter(Boolean))]
    if (idsFound.length !== 1) {
      throw new Error(`same-key create must identify one request: ${JSON.stringify(idsFound)} ${JSON.stringify([a, b])}`)
    }
    const rowCount = lastLine(await psql(`select count(*) from public.stock_refill_requests where idempotency_key = '${sameKey}'`))
    const eventCount = lastLine(await psql(`
      select count(*) from public.stock_refill_request_events
      where refill_request_id = '${idsFound[0]}'::uuid and action = 'created'
    `))
    if (rowCount !== "1" || eventCount !== "1") {
      throw new Error(`same-key create must persist one row and one created event (${rowCount}/${eventCount})`)
    }
    ok("concurrent create same payload replays one request")
  }

  const conflictKey = `${PREFIX}-diff`
  {
    const [a, b] = await Promise.all([
      session(createSql(ids.accounts, conflictKey, 2)),
      session(createSql(ids.accounts, conflictKey, 9)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1) {
      throw new Error(`conflicting create expected one win: ${JSON.stringify([a, b])}`)
    }
    if (!/already used for a different request|23505/i.test(losses[0].text)) {
      throw new Error(`conflicting create loser must be 23505: ${losses[0].text}`)
    }
    const rowCount = lastLine(await psql(`select count(*) from public.stock_refill_requests where idempotency_key = '${conflictKey}'`))
    if (rowCount !== "1") throw new Error(`conflicting create must persist one row, got ${rowCount}`)
    ok("concurrent create conflicting payload refuses the loser")
  }

  const actorKey = `${PREFIX}-actor`
  {
    const [a, b] = await Promise.all([
      session(createSql(ids.accounts, actorKey, 2)),
      session(createSql(ids.accounts2, actorKey, 2)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1 || !/not authorized|42501/i.test(losses[0].text)) {
      throw new Error(`cross-actor create expected 42501: ${JSON.stringify([a, b])}`)
    }
    if (/"id"\s*:/.test(losses[0].text) && requestIdFrom(losses[0].text)) {
      throw new Error("foreign actor must not receive the original payload")
    }
    ok("concurrent create rejects a foreign actor without disclosure")
  }

  const followKey = `${PREFIX}-follow`
  {
    const [a, b] = await Promise.all([
      session(createSql(ids.accounts, followKey, 2)),
      session(createSql(ids.accounts, followKey, 2)),
    ])
    const createdId =
      requestIdFrom(a.text) ||
      requestIdFrom(b.text) ||
      lastLine(await psql(`select id::text from public.stock_refill_requests where idempotency_key = '${followKey}'`))
    const version = await versionOf(createdId)
    const submitted = await session(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.submit_stock_refill_request('${createdId}'::uuid, ${version}::integer, '${PREFIX}-follow-sub');
      commit;
    `)
    if (submitted.code !== 0) throw new Error(`submit after concurrent create failed: ${submitted.text}`)
    const status = lastLine(await psql(`select status from public.stock_refill_requests where id = '${createdId}'`))
    if (status !== "submitted") throw new Error(`expected submitted after concurrent create, got ${status}`)
    ok("concurrent create then submit")
  }

  const submitDraft = await createDraft(`${PREFIX}-sub`)
  const submitVersion = await versionOf(submitDraft)
  const submitSql = (label) => `
    begin;
    ${jwtSql(ids.accounts)}
    select pg_sleep(0.15);
    select public.submit_stock_refill_request('${submitDraft}'::uuid, ${submitVersion}::integer, '${PREFIX}-sub-${label}');
    commit;
  `
  {
    const [a, b] = await Promise.all([session(submitSql("a")), session(submitSql("b"))])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1 || !isConflict(losses[0].text)) {
      throw new Error(`expected one submit win: ${JSON.stringify([a, b])}`)
    }
    const status = lastLine(await psql(`select status from public.stock_refill_requests where id = '${submitDraft}'`))
    if (status !== "submitted") throw new Error(`expected submitted, got ${status}`)
    ok("concurrent submit serializes")
  }

  const updateDraft = await createDraft(`${PREFIX}-upd`)
  const updateVersion = await versionOf(updateDraft)
  const updateSql = (qty) => `
    begin;
    ${jwtSql(ids.accounts)}
    select pg_sleep(0.15);
    select public.update_stock_refill_request(
      '${updateDraft}'::uuid, ${updateVersion}::integer,
      '${ids.supplier}'::uuid, '${ids.branch}'::uuid,
      jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', ${qty})),
      'race'
    );
    commit;
  `
  {
    const [a, b] = await Promise.all([session(updateSql(3)), session(updateSql(4))])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1 || !isConflict(losses[0].text)) {
      throw new Error(`expected one update win: ${JSON.stringify([a, b])}`)
    }
    ok("concurrent update serializes")
  }

  const decisionDraft = await createDraft(`${PREFIX}-dec`)
  await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.submit_stock_refill_request(
      '${decisionDraft}'::uuid,
      (select version from public.stock_refill_requests where id = '${decisionDraft}'),
      '${PREFIX}-dec-sub'
    );
    commit;
  `)
  const decisionVersion = await versionOf(decisionDraft)
  const approveSql = `
    begin;
    ${jwtSql(ids.admin)}
    select pg_sleep(0.15);
    select public.approve_stock_refill_request('${decisionDraft}'::uuid, ${decisionVersion}::integer, '${PREFIX}-apr', null);
    commit;
  `
  const rejectSql = `
    begin;
    ${jwtSql(ids.admin)}
    select pg_sleep(0.15);
    select public.reject_stock_refill_request('${decisionDraft}'::uuid, ${decisionVersion}::integer, 'race reject', '${PREFIX}-rej');
    commit;
  `
  {
    const [a, b] = await Promise.all([session(approveSql), session(rejectSql)])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1 || !isConflict(losses[0].text)) {
      throw new Error(`expected one decision win: ${JSON.stringify([a, b])}`)
    }
    const status = lastLine(await psql(`select status from public.stock_refill_requests where id = '${decisionDraft}'`))
    if (status !== "approved" && status !== "rejected") {
      throw new Error(`expected approved or rejected, got ${status}`)
    }
    ok("concurrent approve vs reject serializes")
  }

  const holdDraft = await createDraft(`${PREFIX}-ah`)
  await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.submit_stock_refill_request(
      '${holdDraft}'::uuid,
      (select version from public.stock_refill_requests where id = '${holdDraft}'),
      '${PREFIX}-ah-sub'
    );
    commit;
  `)
  const holdVersion = await versionOf(holdDraft)
  {
    const [a, b] = await Promise.all([
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.12);
        select public.approve_stock_refill_request('${holdDraft}'::uuid, ${holdVersion}::integer, '${PREFIX}-ah-apr', null);
        commit;
      `),
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.12);
        select public.hold_stock_refill_request('${holdDraft}'::uuid, ${holdVersion}::integer, 'race hold', '${PREFIX}-ah-hld');
        commit;
      `),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1 || !isConflict(losses[0].text)) {
      throw new Error(`approve vs hold expected one win: ${JSON.stringify([a, b])}`)
    }
    ok("concurrent approve vs hold serializes")
  }

  const hrDraft = await createDraft(`${PREFIX}-hr`)
  await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.submit_stock_refill_request(
      '${hrDraft}'::uuid,
      (select version from public.stock_refill_requests where id = '${hrDraft}'),
      '${PREFIX}-hr-sub'
    );
    commit;
  `)
  const hrVersion = await versionOf(hrDraft)
  {
    const [a, b] = await Promise.all([
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.12);
        select public.hold_stock_refill_request('${hrDraft}'::uuid, ${hrVersion}::integer, 'race hold', '${PREFIX}-hr-hld');
        commit;
      `),
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.12);
        select public.reject_stock_refill_request('${hrDraft}'::uuid, ${hrVersion}::integer, 'race reject', '${PREFIX}-hr-rej');
        commit;
      `),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1 || !isConflict(losses[0].text)) {
      throw new Error(`hold vs reject expected one win: ${JSON.stringify([a, b])}`)
    }
    ok("concurrent hold vs reject serializes")
  }

  const usDraft = await createDraft(`${PREFIX}-us`)
  const usVersion = await versionOf(usDraft)
  {
    const [a, b] = await Promise.all([
      session(`
        begin;
        ${jwtSql(ids.accounts)}
        select pg_sleep(0.12);
        select public.update_stock_refill_request(
          '${usDraft}'::uuid, ${usVersion}::integer,
          '${ids.supplier}'::uuid, '${ids.branch}'::uuid,
          jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', 5)),
          'race update'
        );
        commit;
      `),
      session(`
        begin;
        ${jwtSql(ids.accounts)}
        select pg_sleep(0.12);
        select public.submit_stock_refill_request('${usDraft}'::uuid, ${usVersion}::integer, '${PREFIX}-us-sub');
        commit;
      `),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1 || !isConflict(losses[0].text)) {
      throw new Error(`update vs submit expected one win: ${JSON.stringify([a, b])}`)
    }
    ok("concurrent update vs submit serializes")
  }

  const staleDraft = await createDraft(`${PREFIX}-stale`)
  await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.submit_stock_refill_request(
      '${staleDraft}'::uuid,
      (select version from public.stock_refill_requests where id = '${staleDraft}'),
      '${PREFIX}-stale-sub'
    );
    commit;
  `)
  await psql(`
    begin;
    ${jwtSql(ids.admin)}
    select public.hold_stock_refill_request(
      '${staleDraft}'::uuid,
      (select version from public.stock_refill_requests where id = '${staleDraft}'),
      'hold for race',
      '${PREFIX}-stale-hld'
    );
    commit;
  `)
  const heldVersion = await versionOf(staleDraft)
  {
    const [a, b] = await Promise.all([
      session(`
        begin;
        ${jwtSql(ids.accounts)}
        select pg_sleep(0.12);
        select public.submit_stock_refill_request('${staleDraft}'::uuid, ${heldVersion}::integer, '${PREFIX}-stale-resub');
        commit;
      `),
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.12);
        select public.approve_stock_refill_request('${staleDraft}'::uuid, ${heldVersion}::integer, '${PREFIX}-stale-apr', null);
        commit;
      `),
    ])
    const approveLost = [a, b].some((row) => row.code !== 0)
    if (!approveLost) {
      throw new Error(`resubmit vs stale approve must conflict: ${JSON.stringify([a, b])}`)
    }
    const status = lastLine(await psql(`select status from public.stock_refill_requests where id = '${staleDraft}'`))
    if (status !== "submitted" && status !== "held") {
      throw new Error(`resubmit vs stale approve left ${status}`)
    }
    ok("resubmit vs stale decision does not dual-write")
  }

  const deadSupplier = await createDraft(`${PREFIX}-sup`)
  await psql(`
    begin;
    ${jwtSql(ids.admin)}
    select public.set_supplier_active('${ids.supplier}'::uuid, false);
    commit;
  `)
  {
    const result = await session(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.submit_stock_refill_request(
        '${deadSupplier}'::uuid,
        (select version from public.stock_refill_requests where id = '${deadSupplier}'),
        '${PREFIX}-sup-sub'
      );
      commit;
    `)
    if (result.code === 0) throw new Error("submit must fail after supplier deactivation")
    ok("supplier deactivation blocks submit")
  }
  await psql(`
    begin;
    ${jwtSql(ids.admin)}
    select public.set_supplier_active('${ids.supplier}'::uuid, true);
    commit;
  `)

  const deadGodown = await createDraft(`${PREFIX}-gd`)
  await psql(`
    begin;
    ${jwtSql(ids.admin)}
    select public.set_branch_active('${ids.branch}'::uuid, false);
    commit;
  `)
  {
    const result = await session(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.submit_stock_refill_request(
        '${deadGodown}'::uuid,
        (select version from public.stock_refill_requests where id = '${deadGodown}'),
        '${PREFIX}-gd-sub'
      );
      commit;
    `)
    if (result.code === 0) throw new Error("submit must fail after godown deactivation")
    ok("godown deactivation blocks submit")
  }
  await psql(`
    begin;
    ${jwtSql(ids.admin)}
    select public.set_branch_active('${ids.branch}'::uuid, true);
    commit;
  `)

  const revokeDraft = await createDraft(`${PREFIX}-rev`)
  await psql(`
    delete from public.user_roles
    where user_id = '${ids.accounts}'::uuid
      and role_id = (select id from public.roles where code = 'accounts');
  `)
  {
    const result = await session(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.submit_stock_refill_request(
        '${revokeDraft}'::uuid,
        (select version from public.stock_refill_requests where id = '${revokeDraft}'),
        '${PREFIX}-rev-sub'
      );
      commit;
    `)
    if (result.code === 0 || !/not authorized|42501/i.test(result.text)) {
      throw new Error(`permission revocation must deny submit: ${result.text}`)
    }
    ok("permission revocation blocks mutation")
  }
  await psql(`
    insert into public.user_roles (user_id, role_id, assigned_by)
    select '${ids.accounts}'::uuid, roles.id, '${ids.admin}'::uuid
    from public.roles where roles.code = 'accounts'
    on conflict do nothing;
  `)

  const ledgerAfter = lastLine(await psql(`select count(*) from public.stock_ledger`))
  const balancesAfter = lastLine(
    await psql(`select coalesce(sum(quantity),0) from public.stock_balances where product_id = '${ids.product}'::uuid`),
  )
  if (ledgerAfter !== ids.ledger || balancesAfter !== ids.balances) {
    throw new Error(`concurrency must not write stock ${ids.ledger}/${ids.balances} -> ${ledgerAfter}/${balancesAfter}`)
  }
  ok("zero stock effects")

  const flags = lastLine(
    await psql(`
      select count(*) from public.app_configuration
      where key in (
        'damage.stock_hold_ready',
        'stock.lots.dual_write_enabled',
        'stock.lots.aggregate_only_blocked'
      ) and value = 'true'::jsonb
    `),
  )
  if (flags !== "0") throw new Error("cutover flags must remain false")
  ok("cutover flags remain false")
} finally {
  await psql(`
    set session_replication_role = replica;
    delete from public.stock_refill_request_events
    where refill_request_id in (
      select id from public.stock_refill_requests where idempotency_key like '${PREFIX}%'
    );
    delete from public.stock_refill_request_lines
    where refill_request_id in (
      select id from public.stock_refill_requests where idempotency_key like '${PREFIX}%'
    );
    delete from public.stock_refill_requests where idempotency_key like '${PREFIX}%';
    set session_replication_role = origin;
  `)
}

console.log(`M6.2 concurrency passed ${passed.length}`)
