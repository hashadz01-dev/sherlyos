/**
 * M6.4 independent-session races for linked receiving.
 * Local Docker only. Does not flip damage/lot flags. Does not modify verify_stock_receipt.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m64c_${RUN}`

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

function lastNumeric(text) {
  return String(text)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => /^\d+$/.test(line))
    .at(-1)
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
      keeper_id uuid;
      gm_id uuid;
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
        ('keeper.${PREFIX}@example.com'),
        ('gm.${PREFIX}@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.${PREFIX}@example.com';
      select id into accounts_id from auth.users where email = 'accounts.${PREFIX}@example.com';
      select id into keeper_id from auth.users where email = 'keeper.${PREFIX}@example.com';
      select id into gm_id from auth.users where email = 'gm.${PREFIX}@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M64C Admin', true),
        (accounts_id, 'M64C Accounts', true),
        (keeper_id, 'M64C Keeper', true),
        (gm_id, 'M64C GM', true)
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
      select keeper_id, roles.id, admin_id from public.roles where roles.code = 'store_keeper'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select gm_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      branch_uuid := public.create_branch('${PREFIX}', 'M64C');
      perform public.assign_user_branch(accounts_id, branch_uuid);
      perform public.assign_user_branch(keeper_id, branch_uuid);
      perform public.assign_user_branch(gm_id, branch_uuid);
      zone_uuid := public.create_zone(branch_uuid, 'z', 'Z', null);
      crate_uuid := public.create_crate(zone_uuid, 'c', 'C', null);
      supplier_uuid := public.create_supplier('${PREFIX} brand', null, null);
      product_uuid := public.create_product('${PREFIX}-sku', 'M64C soap', supplier_uuid, null);
    end $$;
  `)
  ids.admin = lastLine(await psql(`select id from auth.users where email = 'admin.${PREFIX}@example.com'`))
  ids.accounts = lastLine(await psql(`select id from auth.users where email = 'accounts.${PREFIX}@example.com'`))
  ids.keeper = lastLine(await psql(`select id from auth.users where email = 'keeper.${PREFIX}@example.com'`))
  ids.gm = lastLine(await psql(`select id from auth.users where email = 'gm.${PREFIX}@example.com'`))
  ids.branch = lastLine(await psql(`select id from public.branches where code = '${PREFIX}'`))
  ids.supplier = lastLine(await psql(`select id from public.suppliers where name = '${PREFIX} brand'`))
  ids.product = lastLine(await psql(`select id from public.products where sku = '${PREFIX}-sku'`))
  ids.crate = lastLine(await psql(`select crates.id from public.crates join public.zones on zones.id = crates.zone_id where zones.branch_id = '${ids.branch}'::uuid`))
}

async function approveRequest(key, qty = 20) {
  const text = await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.create_stock_refill_request(
      '${ids.supplier}'::uuid, '${ids.branch}'::uuid,
      jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', ${qty})),
      '${key}-c', null
    );
    commit;
  `)
  const requestId = String(text).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1]
  const createdVersion = lastLine(
    await psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`),
  )
  await psql(`
    begin;
    ${jwtSql(ids.accounts)}
    select public.submit_stock_refill_request('${requestId}'::uuid, ${createdVersion}::integer, '${key}-s');
    commit;
  `)
  const submittedVersion = lastLine(
    await psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`),
  )
  await psql(`
    begin;
    ${jwtSql(ids.admin)}
    select public.approve_stock_refill_request('${requestId}'::uuid, ${submittedVersion}::integer, '${key}-a', null);
    commit;
  `)
  return requestId
}

function lineJson(counted = 4) {
  return `jsonb_build_array(jsonb_build_object(
    'product_id', '${ids.product}'::uuid,
    'destination_crate_id', '${ids.crate}'::uuid,
    'document_cases', ${counted},
    'counted_cases', ${counted},
    'damaged_cases', 0
  ))`
}

function createSql(document, refillId, counted = 4) {
  return `
    begin;
    ${jwtSql(ids.keeper)}
    select pg_sleep(0.08);
    select public.create_stock_receipt(
      '${ids.branch}'::uuid,
      '${ids.supplier}'::uuid,
      '${document}',
      (clock_timestamp() at time zone 'utc')::date,
      null,
      ${lineJson(counted)},
      '${refillId}'::uuid
    );
    commit;
  `
}

async function createSubmitted(document, refillId, counted = 4) {
  const text = await psql(`
    begin;
    ${jwtSql(ids.keeper)}
    select public.create_stock_receipt(
      '${ids.branch}'::uuid,
      '${ids.supplier}'::uuid,
      '${document}',
      (clock_timestamp() at time zone 'utc')::date,
      null,
      jsonb_build_array(jsonb_build_object(
        'product_id', '${ids.product}'::uuid,
        'destination_crate_id', '${ids.crate}'::uuid,
        'document_cases', ${counted},
        'counted_cases', ${counted},
        'damaged_cases', 0
      )),
      '${refillId}'::uuid
    );
    commit;
  `)
  const receiptId = String(text).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1]
  await psql(`
    begin;
    ${jwtSql(ids.keeper)}
    select public.submit_stock_receipt('${receiptId}'::uuid);
    commit;
  `)
  return receiptId
}

function verifySql(receiptId, key) {
  return `
    begin;
    ${jwtSql(ids.gm)}
    select pg_sleep(0.08);
    select public.verify_stock_receipt('${receiptId}'::uuid, '${key}');
    commit;
  `
}

try {
  await setup()
  if (!ids.keeper || !ids.gm || !ids.crate) {
    throw new Error(`setup missing ids ${JSON.stringify(ids)}`)
  }

  {
    const requestId = await approveRequest(`${PREFIX}-two`)
    const [a, b] = await Promise.all([
      session(createSql(`${PREFIX}-d1`, requestId)),
      session(createSql(`${PREFIX}-d2`, requestId)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    if (wins.length !== 2) throw new Error(`two concurrent links must both succeed ${JSON.stringify([a, b])}`)
    const count = lastLine(
      await psql(`select count(*) from public.stock_receipts where refill_request_id = '${requestId}'`),
    )
    if (count !== "2") throw new Error(`expected 2 linked receipts, got ${count}`)
    ok("two receipts linked to the same request concurrently")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-over`, 10)
    const [a, b] = await Promise.all([
      session(createSql(`${PREFIX}-over-a`, requestId, 8)),
      session(createSql(`${PREFIX}-over-b`, requestId, 8)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1) {
      throw new Error(`cumulative create must keep one winner ${JSON.stringify([a, b])}`)
    }
    const winnerId = String(wins[0].text).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1]
    await psql(`
      begin;
      ${jwtSql(ids.keeper)}
      select public.submit_stock_receipt('${winnerId}'::uuid);
      commit;
    `)
    const verified = await session(verifySql(winnerId, `${PREFIX}-over-v`))
    if (verified.code !== 0) throw new Error(`winner verify failed ${verified.text}`)
    const accepted = lastNumeric(
      await psql(`
        begin;
        ${jwtSql(ids.accounts)}
        select public.get_stock_refill_receiving_reconciliation('${requestId}'::uuid)
          -> 'receiving' -> 'summary' ->> 'accepted_cases';
        commit;
      `),
    )
    if (Number(accepted) !== 8) throw new Error(`over-delivery posted ${accepted}, expected 8`)
    const txs = lastLine(
      await psql(`select count(*) from public.stock_transactions where receipt_id = '${winnerId}'::uuid`),
    )
    if (txs !== "1") throw new Error(`expected one stock tx, got ${txs}`)
    ok("concurrent over-limit creates keep requested quantity")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-vv`)
    const r1 = await createSubmitted(`${PREFIX}-vv1`, requestId, 5)
    const r2 = await createSubmitted(`${PREFIX}-vv2`, requestId, 6)
    const [a, b] = await Promise.all([
      session(verifySql(r1, `${PREFIX}-vv1k`)),
      session(verifySql(r2, `${PREFIX}-vv2k`)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    if (wins.length !== 2) throw new Error(`dual verify must both succeed ${JSON.stringify([a, b])}`)
    const accepted = lastNumeric(
      await psql(`
        begin;
        ${jwtSql(ids.accounts)}
        select public.get_stock_refill_receiving_reconciliation('${requestId}'::uuid)
          -> 'receiving' -> 'summary' ->> 'accepted_cases';
        commit;
      `),
    )
    if (accepted !== "11") throw new Error(`outstanding recon after dual verify expected 11 accepted, got ${accepted}`)
    const txs = lastLine(
      await psql(`
        select count(*) from public.stock_transactions
        where receipt_id in ('${r1}'::uuid, '${r2}'::uuid)
      `),
    )
    if (txs !== "2") throw new Error(`expected 2 stock txs, got ${txs}`)
    ok("two independent partial receipts verified concurrently")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-twice`)
    const receiptId = await createSubmitted(`${PREFIX}-twice`, requestId, 3)
    const [a, b] = await Promise.all([
      session(verifySql(receiptId, `${PREFIX}-samekey`)),
      session(verifySql(receiptId, `${PREFIX}-samekey`)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    if (wins.length < 1) throw new Error(`same receipt verify twice produced no winner ${JSON.stringify([a, b])}`)
    const txs = lastLine(
      await psql(`select count(*) from public.stock_transactions where receipt_id = '${receiptId}'::uuid`),
    )
    if (txs !== "1") throw new Error(`double post on replay ${txs}`)
    ok("same receipt verified twice posts once")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-vc`)
    const receiptId = await createSubmitted(`${PREFIX}-vc`, requestId, 3)
    const [verify, cancel] = await Promise.all([
      session(verifySql(receiptId, `${PREFIX}-vck`)),
      session(`
        begin;
        ${jwtSql(ids.gm)}
        select pg_sleep(0.08);
        select public.cancel_stock_receipt('${receiptId}'::uuid, 'race');
        commit;
      `),
    ])
    const verifyWins = verify.code === 0
    const cancelWins = cancel.code === 0
    if (verifyWins && cancelWins) throw new Error("verify vs cancel must not both succeed")
    if (!verifyWins && !cancelWins) throw new Error(`verify vs cancel produced no winner ${JSON.stringify([verify, cancel])}`)
    const status = lastLine(await psql(`select status from public.stock_receipts where id = '${receiptId}'`))
    const txs = lastLine(
      await psql(`select count(*) from public.stock_transactions where receipt_id = '${receiptId}'::uuid`),
    )
    if (status === "posted" && txs !== "1") throw new Error("posted receipt missing tx")
    if (status === "cancelled" && txs !== "0") throw new Error("cancelled receipt posted stock")
    ok("receipt verification vs cancellation serializes")
  }

  {
    const text = await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.create_stock_refill_request(
        '${ids.supplier}'::uuid, '${ids.branch}'::uuid,
        jsonb_build_array(jsonb_build_object('product_id', '${ids.product}'::uuid, 'requested_cases', 8)),
        '${PREFIX}-linkst-c', null
      );
      commit;
    `)
    const requestId = String(text).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1]
    const createdVersion = lastLine(
      await psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`),
    )
    await psql(`
      begin;
      ${jwtSql(ids.accounts)}
      select public.submit_stock_refill_request('${requestId}'::uuid, ${createdVersion}::integer, '${PREFIX}-linkst-s');
      commit;
    `)
    const submittedVersion = lastLine(
      await psql(`select version::text from public.stock_refill_requests where id = '${requestId}'`),
    )
    const [link, approve] = await Promise.all([
      session(createSql(`${PREFIX}-linkst`, requestId)),
      session(`
        begin;
        ${jwtSql(ids.admin)}
        select pg_sleep(0.08);
        select public.approve_stock_refill_request('${requestId}'::uuid, ${submittedVersion}::integer, '${PREFIX}-linkst-a', null);
        commit;
      `),
    ])
    const status = lastLine(await psql(`select status from public.stock_refill_requests where id = '${requestId}'`))
    const linked = lastLine(
      await psql(`select count(*) from public.stock_receipts where refill_request_id = '${requestId}'`),
    )
    if (link.code === 0 && status !== "approved") {
      throw new Error("link succeeded against a non-approved request")
    }
    if (status === "approved" && link.code !== 0 && approve.code !== 0) {
      throw new Error(`approve vs link produced no winner ${JSON.stringify([link, approve])}`)
    }
    if (Number(linked) > 1) throw new Error("duplicate linkage")
    ok("receipt linkage vs request status changes")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-gdn`)
    const receiptId = await createSubmitted(`${PREFIX}-gdn`, requestId, 2)
    const [verify, _deactivate] = await Promise.all([
      session(verifySql(receiptId, `${PREFIX}-gdnk`)),
      session(`
        begin;
        select pg_sleep(0.05);
        update public.branches set is_active = false where id = '${ids.branch}'::uuid;
        commit;
      `),
    ])
    await psql(`update public.branches set is_active = true where id = '${ids.branch}'::uuid`)
    const status = lastLine(await psql(`select status from public.stock_receipts where id = '${receiptId}'`))
    const txs = lastLine(
      await psql(`select count(*) from public.stock_transactions where receipt_id = '${receiptId}'::uuid`),
    )
    if (verify.code === 0 && status === "posted" && txs !== "1") throw new Error("posted without tx")
    if (verify.code !== 0 && txs !== "0") throw new Error("failed verify posted stock")
    if (_deactivate.code !== 0) throw new Error(`godown deactivate failed ${_deactivate.text}`)
    ok("receipt verification vs godown deactivation")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-sup`)
    const receiptId = await createSubmitted(`${PREFIX}-sup`, requestId, 2)
    const [verify, _deactivate] = await Promise.all([
      session(verifySql(receiptId, `${PREFIX}-supk`)),
      session(`
        begin;
        select pg_sleep(0.05);
        update public.suppliers set is_active = false where id = '${ids.supplier}'::uuid;
        commit;
      `),
    ])
    await psql(`update public.suppliers set is_active = true where id = '${ids.supplier}'::uuid`)
    const txs = lastLine(
      await psql(`select count(*) from public.stock_transactions where receipt_id = '${receiptId}'::uuid`),
    )
    if (verify.code === 0 && txs !== "1") throw new Error("supplier race posted without tx")
    if (verify.code !== 0 && txs !== "0") throw new Error("failed supplier-race verify posted stock")
    ok("receipt verification vs supplier deactivation")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-read`)
    const receiptId = await createSubmitted(`${PREFIX}-read`, requestId, 4)
    const [verify, read] = await Promise.all([
      session(verifySql(receiptId, `${PREFIX}-readk`)),
      session(`
        begin;
        ${jwtSql(ids.accounts)}
        select pg_sleep(0.08);
        select public.get_stock_refill_receiving_reconciliation('${requestId}'::uuid);
        commit;
      `),
    ])
    if (read.code !== 0) throw new Error(`reconciliation read failed ${read.text}`)
    if (verify.code !== 0) throw new Error(`verify vs read failed ${verify.text}`)
    ok("receipt verification vs refill reconciliation read")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-dup`)
    const [a, b] = await Promise.all([
      session(createSql(`${PREFIX}-dupdoc`, requestId)),
      session(createSql(`${PREFIX}-dupdoc`, requestId)),
    ])
    const wins = [a, b].filter((row) => row.code === 0)
    const losses = [a, b].filter((row) => row.code !== 0)
    if (wins.length !== 1 || losses.length !== 1) {
      throw new Error(`duplicate document must have one winner ${JSON.stringify([a, b])}`)
    }
    ok("duplicate receipt-link request replay")
  }

  {
    const requestId = await approveRequest(`${PREFIX}-unl`)
    const linked = await createSubmitted(`${PREFIX}-unl-l`, requestId, 3)
    const unlinkedText = await psql(`
      begin;
      ${jwtSql(ids.keeper)}
      select public.create_stock_receipt(
        '${ids.branch}'::uuid,
        '${ids.supplier}'::uuid,
        '${PREFIX}-unl-u',
        (clock_timestamp() at time zone 'utc')::date,
        null,
        jsonb_build_array(jsonb_build_object(
          'product_id', '${ids.product}'::uuid,
          'destination_crate_id', '${ids.crate}'::uuid,
          'document_cases', 2,
          'counted_cases', 2,
          'damaged_cases', 0
        ))
      );
      commit;
    `)
    const unlinkedId = String(unlinkedText).match(/"id"\s*:\s*"([0-9a-f-]+)"/i)?.[1]
    await psql(`
      begin;
      ${jwtSql(ids.keeper)}
      select public.submit_stock_receipt('${unlinkedId}'::uuid);
      commit;
    `)
    const [a, b] = await Promise.all([
      session(verifySql(linked, `${PREFIX}-unl-lk`)),
      session(verifySql(unlinkedId, `${PREFIX}-unl-uk`)),
    ])
    if (a.code !== 0 || b.code !== 0) {
      throw new Error(`linked vs unlinked verify failed ${JSON.stringify([a, b])}`)
    }
    const qty = lastLine(
      await psql(`
        select coalesce(sum(quantity),0)::text from public.stock_balances
        where crate_id = '${ids.crate}'::uuid and product_id = '${ids.product}'::uuid
      `),
    )
    if (Number(qty) < 5) throw new Error(`crate balance after dual verify expected >=5 got ${qty}`)
    const refillAccepted = lastNumeric(
      await psql(`
        begin;
        ${jwtSql(ids.accounts)}
        select public.get_stock_refill_receiving_reconciliation('${requestId}'::uuid)
          -> 'receiving' -> 'summary' ->> 'accepted_cases';
        commit;
      `),
    )
    if (refillAccepted !== "3") throw new Error(`unlinked qty leaked into refill accepted ${refillAccepted}`)
    ok("linked verify vs unlinked receiving on the same crate")
  }

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
  if (flags !== "0") throw new Error("cutover flags flipped")
  ok("cutover flags remain false")
} catch (error) {
  console.error(error)
  process.exitCode = 1
}

console.log(`M6.4 concurrency passed ${passed.length}`)
if (process.exitCode !== 1 && passed.length < 12) {
  throw new Error("expected at least 12 concurrency proofs; skipped races are not passing")
}
