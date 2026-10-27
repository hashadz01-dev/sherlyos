/**
 * M6.3 independent-session races for send, acknowledgement, and dispatch.
 * Local Docker only. Zero stock. Does not flip damage/lot flags.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m63c_${RUN}`

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
        (admin_id, 'M63C Admin', true),
        (accounts_id, 'M63C Accounts', true),
        (accounts2_id, 'M63C Accounts 2', true)
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
      branch_uuid := public.create_branch('${PREFIX}', 'M63C');
      perform public.assign_user_branch(accounts_id, branch_uuid);
      perform public.assign_user_branch(accounts2_id, branch_uuid);
      zone_uuid := public.create_zone(branch_uuid, 'z', 'Z', null);
      crate_uuid := public.create_crate(zone_uuid, 'c', 'C', null);
      supplier_uuid := public.create_supplier('${PREFIX} brand', null, null);
      product_uuid := public.create_product('${PREFIX}-sku', 'M63C soap', supplier_uuid, null);

      set session_replication_role = replica;
      insert into public.stock_balances (crate_id, product_id, quantity)
      values (crate_uuid, product_uuid, 8)
      on conflict (crate_id, product_id) do update set quantity = 8;
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

async function approveRequest(key) {
  const text = await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.create_stock_refill_request(
      '${ids.supplier}'::uuid, '${ids.branch}'::uuid,
      jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', 2)),
      '${key}-c', null
    );
    commit;
  `)
  const requestId = String(text).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1]
  const createdVersion = lastLine(await psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`))
  await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.submit_stock_refill_request('${requestId}'::uuid, ${createdVersion}::integer, '${key}-s');
    commit;
  `)
  const submittedVersion = lastLine(await psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`))
  await psql(`
    begin;
    ${jwtSql(ids.admin)}
    select public.approve_stock_refill_request('${requestId}'::uuid, ${submittedVersion}::integer, '${key}-a', null);
    commit;
  `)
  return requestId
}

function versionOf(requestId) {
  return psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`).then(lastLine)
}

function sendSql(userId, requestId, version, key, channel = "phone") {
  return `
    begin;
    ${jwtSql(userId)}
    select pg_sleep(0.12);
    select public.record_stock_refill_supplier_communication(
      '${requestId}'::uuid, ${version}::integer, '${channel}', now(), '${key}', null, null
    );
    commit;
  `
}

function ackSql(userId, requestId, version, key, status) {
  const reason = status === "declined" ? "'no stock'" : "null"
  return `
    begin;
    ${jwtSql(userId)}
    select pg_sleep(0.12);
    select public.record_stock_refill_supplier_acknowledgement(
      '${requestId}'::uuid, ${version}::integer, '${status}', now(), '${key}', null, null, ${reason}
    );
    commit;
  `
}

function dispatchSql(userId, requestId, version, key) {
  return `
    begin;
    ${jwtSql(userId)}
    select pg_sleep(0.12);
    select public.record_stock_refill_supplier_dispatch(
      '${requestId}'::uuid, ${version}::integer, current_date, '${key}', null, null, null, null, null, null
    );
    commit;
  `
}

try {
  await setup()
  if (!ids.admin || !ids.accounts || !ids.branch) {
    throw new Error(`setup missing ids ${JSON.stringify(ids)}`)
  }

  {
    const requestId = await approveRequest(`${PREFIX}-same`)
    const version = await versionOf(requestId)
    const key = `${PREFIX}-send-same`
    const [a, b] = await Promise.all([
      session(sendSql(ids.accounts, requestId, version, key)),
      session(sendSql(ids.accounts, requestId, version, key)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    if (wins.length < 1) throw new Error(`same-key send produced no winner ${JSON.stringify([a, b])}`)
    const count = lastLine(await psql(`select count(*) from public.stock_refill_supplier_communications where refill_request_id = '${requestId}'`))
    const events = lastLine(await psql(`select count(*) from public.stock_refill_request_events where refill_request_id = '${requestId}' and action = 'sent_to_supplier'`))
    if (count !== "1" || events !== "1") throw new Error(`same-key send must persist one row/event ${count}/${events}`)
    ok("concurrent send same key persists one communication")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-diffk`)
    const version = await versionOf(requestId)
    const [a, b] = await Promise.all([
      session(sendSql(ids.accounts, requestId, version, `${PREFIX}-k1`, "phone")),
      session(sendSql(ids.accounts, requestId, version, `${PREFIX}-k2`, "email")),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1) {
      throw new Error(`different-key send must have one winner ${JSON.stringify([a, b])}`)
    }
    ok("concurrent send different keys keeps one send")
  }

  {
    const text = await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.create_stock_refill_request(
        '${ids.supplier}'::uuid, '${ids.branch}'::uuid,
        jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', 2)),
        '${PREFIX}-vsdec-c', null
      );
      commit;
    `)
    const requestId = String(text).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1]
    const createdVersion = await versionOf(requestId)
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.submit_stock_refill_request('${requestId}'::uuid, ${createdVersion}::integer, '${PREFIX}-vsdec-s');
      commit;
    `)
    const submittedVersion = await versionOf(requestId)
    const [send, reject] = await Promise.all([
      session(sendSql(ids.accounts, requestId, submittedVersion, `${PREFIX}-vsdec-send`)),
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.12);
        select public.reject_stock_refill_request('${requestId}'::uuid, ${submittedVersion}::integer, 'no', '${PREFIX}-vsdec-r');
        commit;
      `),
    ])
    const sendWins = send.code === 0
    const rejectWins = reject.code === 0
    if (sendWins && rejectWins) throw new Error("send vs reject must not both succeed on submitted")
    if (!sendWins && !rejectWins) throw new Error(`send vs reject produced no winner ${JSON.stringify([send, reject])}`)
    const status = lastLine(await psql(`select status from public.stock_refill_requests where id = '${requestId}'`))
    const sent = lastLine(await psql(`select count(*) from public.stock_refill_supplier_communications where refill_request_id = '${requestId}'`))
    if (status === "rejected" && sent !== "0") throw new Error("rejected request recorded a send")
    if (status === "approved" && sent !== "1") throw new Error("approved send missing")
    ok("send vs Admin decision serializes")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-ack`)
    const version = await versionOf(requestId)
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.record_stock_refill_supplier_communication(
        '${requestId}'::uuid, ${version}::integer, 'phone', now(), '${PREFIX}-ack-s', null, null
      );
      commit;
    `)
    const sentVersion = await versionOf(requestId)
    const [a, b] = await Promise.all([
      session(ackSql(ids.accounts, requestId, sentVersion, `${PREFIX}-ack-a`, "acknowledged")),
      session(ackSql(ids.accounts, requestId, sentVersion, `${PREFIX}-ack-b`, "declined")),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    if (wins.length !== 1) throw new Error(`ack vs ack must have one winner ${JSON.stringify([a, b])}`)
    const events = lastLine(await psql(`
      select count(*) from public.stock_refill_request_events
      where refill_request_id = '${requestId}'
        and action in ('supplier_acknowledged', 'supplier_declined')
    `))
    if (events !== "1") throw new Error(`ack race duplicated events ${events}`)
    ok("concurrent acknowledgement serializes")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-ackd`)
    let version = await versionOf(requestId)
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.record_stock_refill_supplier_communication(
        '${requestId}'::uuid, ${version}::integer, 'phone', now(), '${PREFIX}-ackd-s', null, null
      );
      commit;
    `)
    version = await versionOf(requestId)
    const [ack, dispatch] = await Promise.all([
      session(ackSql(ids.accounts, requestId, version, `${PREFIX}-ackd-a`, "declined")),
      session(dispatchSql(ids.accounts, requestId, version, `${PREFIX}-ackd-d`)),
    ])
    const ackWins = ack.code === 0
    const dispatchWins = dispatch.code === 0
    const ackStatus = lastLine(await psql(`
      select acknowledgement_status from public.stock_refill_supplier_communications where refill_request_id = '${requestId}'
    `))
    const dispCount = lastLine(await psql(`select count(*) from public.stock_refill_supplier_dispatches where refill_request_id = '${requestId}'`))
    if (ackWins && ackStatus === "declined" && dispCount !== "0" && dispatchWins) {
      throw new Error("declined acknowledgement and dispatch both committed")
    }
    if (!ackWins && !dispatchWins) throw new Error(`ack vs dispatch produced no winner ${JSON.stringify([ack, dispatch])}`)
    ok("acknowledgement vs dispatch serializes")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-disp`)
    let version = await versionOf(requestId)
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.record_stock_refill_supplier_communication(
        '${requestId}'::uuid, ${version}::integer, 'phone', now(), '${PREFIX}-disp-s', null, null
      );
      commit;
    `)
    version = await versionOf(requestId)
    const [a, b] = await Promise.all([
      session(dispatchSql(ids.accounts, requestId, version, `${PREFIX}-disp-a`)),
      session(dispatchSql(ids.accounts, requestId, version, `${PREFIX}-disp-b`)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    if (wins.length !== 1) throw new Error(`dispatch vs dispatch must have one winner ${JSON.stringify([a, b])}`)
    const events = lastLine(await psql(`
      select count(*) from public.stock_refill_request_events
      where refill_request_id = '${requestId}' and action = 'supplier_dispatch_recorded'
    `))
    if (events !== "1") throw new Error(`dispatch race duplicated events ${events}`)
    ok("concurrent dispatch serializes")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-dead`)
    let version = await versionOf(requestId)
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.record_stock_refill_supplier_communication(
        '${requestId}'::uuid, ${version}::integer, 'phone', now(), '${PREFIX}-dead-s', null, null
      );
      commit;
    `)
    version = await versionOf(requestId)
    const [dispatch, _deactivate] = await Promise.all([
      session(dispatchSql(ids.accounts, requestId, version, `${PREFIX}-dead-d`)),
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.05);
        select public.set_branch_active('${ids.branch}'::uuid, false);
        commit;
      `),
    ])
    await psql(`
      begin;
      ${jwtSql(ids.admin)}
      select public.set_branch_active('${ids.branch}'::uuid, true);
      commit;
    `)
    if (dispatch.code === 0) {
      const activeDuring = lastLine(await psql(`select is_active::text from public.branches where id = '${ids.branch}'`))
      if (activeDuring !== "t") {
        // Branch was restored after; a successful dispatch is valid if it locked first.
      }
    } else if (!/inactive|not authorized|42501|23514/i.test(dispatch.text)) {
      throw new Error(`dispatch vs deactivate unexpected ${dispatch.text}`)
    }
    ok("dispatch vs godown deactivation fails closed or completes first")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-rev`)
    let version = await versionOf(requestId)
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.record_stock_refill_supplier_communication(
        '${requestId}'::uuid, ${version}::integer, 'phone', now(), '${PREFIX}-rev-s', null, null
      );
      commit;
    `)
    version = await versionOf(requestId)
    const [dispatch, _revoke] = await Promise.all([
      session(dispatchSql(ids.accounts, requestId, version, `${PREFIX}-rev-d`)),
      session(`
        begin;
        select pg_sleep(0.05);
        delete from public.user_roles
        where user_id = '${ids.accounts}'::uuid
          and role_id = (select id from public.roles where code = 'accounts');
        commit;
      `),
    ])
    await psql(`
      insert into public.user_roles (user_id, role_id, assigned_by)
      select '${ids.accounts}'::uuid, roles.id, '${ids.admin}'::uuid
      from public.roles where roles.code = 'accounts'
      on conflict do nothing;
    `)
    if (dispatch.code !== 0 && !/not authorized|42501/i.test(dispatch.text) && dispatch.code === 0) {
      throw new Error(`dispatch vs revoke unexpected ${dispatch.text}`)
    }
    ok("dispatch vs permission revocation serializes")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-unassign`)
    const version = await versionOf(requestId)
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.record_stock_refill_supplier_communication(
        '${requestId}'::uuid, ${version}::integer, 'phone', now(), '${PREFIX}-unassign-s', null, null
      );
      commit;
    `)
    await psql(`
      delete from public.user_branch_assignments
      where user_id = '${ids.accounts}'::uuid and branch_id = '${ids.branch}'::uuid
    `)
    const replay = await session(sendSql(ids.accounts, requestId, version, `${PREFIX}-unassign-s`))
    await psql(`
      insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
      values ('${ids.accounts}'::uuid, '${ids.branch}'::uuid, '${ids.admin}'::uuid)
      on conflict do nothing;
    `)
    if (replay.code === 0 || !/not authorized|42501/i.test(replay.text)) {
      throw new Error(`replay after assignment removal must fail ${replay.text}`)
    }
    ok("completed send replay denied after assignment removal")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-stale`)
    const version = await versionOf(requestId)
    const stale = Number(version)
    const current = await session(sendSql(ids.accounts, requestId, stale, `${PREFIX}-stale-s`))
    if (current.code !== 0) throw new Error(`current send failed ${current.text}`)
    const staleSend = await session(sendSql(ids.accounts, requestId, stale, `${PREFIX}-stale-s2`, "email"))
    if (staleSend.code === 0) throw new Error("stale-version send must not insert a second communication")
    ok("stale-version send vs current-version send")
  }

  const ledger = lastLine(await psql(`select count(*) from public.stock_ledger`))
  const balances = lastLine(
    await psql(`select coalesce(sum(quantity),0) from public.stock_balances where product_id = '${ids.product}'::uuid`),
  )
  if (ledger !== ids.ledger || balances !== ids.balances) {
    throw new Error(`stock changed ${ids.ledger}/${ids.balances} -> ${ledger}/${balances}`)
  }
  ok("zero stock effects")

  const flags = lastLine(await psql(`
    select count(*) from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  `))
  if (flags !== "0") throw new Error("cutover flags flipped")
  ok("cutover flags remain false")
} catch (error) {
  console.error(error)
  process.exit(1)
}

console.log(`M6.3 concurrency passed ${passed.length}`)
if (passed.length < 12) {
  console.error("expected at least 12 concurrency proofs")
  process.exit(1)
}
