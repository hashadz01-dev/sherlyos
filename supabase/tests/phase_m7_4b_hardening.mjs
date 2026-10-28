/**
 * M7.4B final hardening. Local Docker only.
 * Multi-lot ledger rollback, concurrent sessions, crate/lot/permission races.
 * Operational flags are restored in finally.
 */
import { spawn } from "node:child_process"

const PREFIX = `m74bh_${Date.now().toString(36)}`
const PASSWORD = "local-only-m74bh"

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

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

function asUser(email) {
  return `
select set_config('request.jwt.claim.sub',
  (select id::text from auth.users where email = '${email}'), true);
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = '${email}'), true);
set local role authenticated;
`
}

// dual=true seeds two original lots for the inject. Later races use one lot so
// they stay independent of the posted two-lot return in the same database.
function seedSql(suffix, { missing = false, approve = false, dual = true } = {}) {
  const qty = missing ? 0 : 1
  const miss = missing ? 1 : 0
  const lines = dual
    ? `jsonb_build_array(
      jsonb_build_object('product_id', product_a, 'requested_cases', 1),
      jsonb_build_object('product_id', product_b, 'requested_cases', 1)
    )`
    : `jsonb_build_array(
      jsonb_build_object('product_id', product_a, 'requested_cases', 1)
    )`
  const handback = dual ? 2 : 1
  return `
do $$
declare
  admin_id uuid := (select id from auth.users where email = 'admin.${PREFIX}@example.com');
  accounts_id uuid := (select id from auth.users where email = 'accounts.${PREFIX}@example.com');
  godown_id uuid := (select id from auth.users where email = 'godown.${PREFIX}@example.com');
  keeper_id uuid := (select id from auth.users where email = 'keeper.${PREFIX}@example.com');
  driver_id uuid := (select id from auth.users where email = 'driver.${PREFIX}@example.com');
  branch_id uuid := (select id from public.branches where code = '${PREFIX}');
  crate_id uuid := (select crates.id from public.crates where crates.code = '${PREFIX}_c1');
  crate_2 uuid := (select crates.id from public.crates where crates.code = '${PREFIX}_c2');
  product_a uuid := (select id from public.products where sku = '${PREFIX}-a');
  product_b uuid := (select id from public.products where sku = '${PREFIX}-b');
  shop_id uuid := (select id from public.shops where name = 'M74BH shop' order by created_at desc limit 1);
  vehicle_id uuid := (select id from public.vehicles where registration_normalized = lower(replace('KL07${PREFIX}',' ','')));
  order_id uuid;
  request_id uuid;
  header jsonb;
  res jsonb;
  i int;
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  excepted jsonb;
  ret jsonb;
  lot jsonb;
  counts jsonb := '[]'::jsonb;
  step text := 'start';
begin
  perform set_config('request.jwt.claim.sub', accounts_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  header := public.create_order(
    shop_id, branch_id, 'accounts', null, null,
    ${lines},
    '${PREFIX}-${suffix}-ord'
  );
  order_id := (header -> 'order' ->> 'id')::uuid;
  perform public.submit_order(order_id, 1, '${PREFIX}-${suffix}-sub');
  perform public.verify_order(order_id, 2, '${PREFIX}-${suffix}-ver');
  header := public.create_delivery_note(order_id, '${PREFIX}-${suffix}-dn');
  perform public.generate_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-${suffix}-gen');
  perform public.send_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-${suffix}-send');
  perform set_config('request.jwt.claim.sub', godown_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
  perform public.acknowledge_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-${suffix}-ack');
  header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-${suffix}-res');
  request_id := (header ->> 'id')::uuid;
  header := public.assign_picking_request(request_id, keeper_id, 1, '${PREFIX}-${suffix}-asg');
  header := public.start_picking(request_id, 2, '${PREFIX}-${suffix}-start');
  perform set_config('request.jwt.claim.sub', keeper_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
  header := public.get_picking_request(request_id);
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer, '${PREFIX}-${suffix}-pick-' || i::text
    );
  end loop;
  header := public.complete_picking(request_id, (header ->> 'version')::integer, '${PREFIX}-${suffix}-done');
  perform set_config('request.jwt.claim.sub', godown_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
  header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, '${PREFIX}-${suffix}-ho');
  step := 'preview';
  preview := public.preview_dispatch(order_id);
  step := 'prepare';
  prepared := public.prepare_dispatch(order_id, (preview ->> 'picking_version')::integer, '${PREFIX}-${suffix}-prep');
  step := 'confirm';
  confirmed := public.confirm_dispatch((prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, '${PREFIX}-${suffix}-cfm');
  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid, driver_id, (confirmed ->> 'version')::integer, '${PREFIX}-${suffix}-asgd', vehicle_id
  );
  excepted := public.report_dispatch_delivery_exception(
    (assigned ->> 'id')::uuid, 'closed', (assigned ->> 'version')::integer, '${PREFIX}-${suffix}-exc'
  );
  perform set_config('request.jwt.claim.sub', driver_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', driver_id, 'role', 'authenticated')::text, true);
  ret := public.get_delivery_return((excepted ->> 'id')::uuid);
  ret := public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, ${handback}, null, (ret ->> 'version')::integer, '${PREFIX}-${suffix}-hb'
  );
  perform set_config('request.jwt.claim.sub', keeper_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
  for i in 0 .. jsonb_array_length(ret -> 'lots') - 1 loop
    lot := ret -> 'lots' -> i;
    counts := counts || jsonb_build_array(jsonb_build_object(
      'id', lot ->> 'id',
      'delivered_cases', 0,
      'saleable_cases', ${qty},
      'damaged_cases', 0,
      'uncertain_cases', 0,
      'missing_cases', ${miss},
      'receiving_crate_id', case
        when (lot ->> 'product_id') = product_a::text then crate_id::text
        else crate_2::text
      end
    ));
  end loop;
  ret := public.count_delivery_return(
    (ret ->> 'id')::uuid, counts, (ret ->> 'version')::integer, '${PREFIX}-${suffix}-ct'
  );
  if ${approve ? "true" : "false"} then
    perform set_config('request.jwt.claim.sub', godown_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
    perform public.approve_delivery_return(
      (ret ->> 'id')::uuid, (ret ->> 'version')::integer, '${PREFIX}-${suffix}-ap'
    );
  end if;
  -- Deferred ledger completeness runs at commit as the session role.
  -- Keepers cannot read DISPATCH rows through RLS, so reset first.
  execute 'reset role';
exception
  when others then
    raise exception 'seed % failed at %: %', '${suffix}', step, sqlerrm;
end $$;
`
}

async function loadReturn(skuA = `${PREFIX}-a`) {
  const row = String(
    await psql(`
      select concat_ws('|',
        r.id::text,
        r.version::text,
        r.dispatch_id::text,
        r.status,
        coalesce(r.posted_transaction_id::text, ''),
        coalesce(r.approved_by::text, ''),
        (select count(*)::text from public.stock_delivery_return_lots where return_id = r.id)
      )
      from public.stock_delivery_returns r
      join public.stock_delivery_return_lots lots on lots.return_id = r.id
      join public.products p on p.id = lots.product_id
      where p.sku = '${skuA}'
      order by r.created_at desc
      limit 1
    `),
  ).trim()
  const [returnId, version, dispatchId, status, txn, approvedBy, lotCount] = row.split("|")
  if (!returnId) throw new Error(`return missing for ${skuA}: ${row}`)
  return { returnId, version: Number(version), dispatchId, status, txn, approvedBy, lotCount: Number(lotCount) }
}

function balancesSql() {
  return `
    select coalesce(string_agg(concat_ws(':', p.sku, b.quantity::text), ',' order by p.sku), '')
    from public.stock_balances b
    join public.products p on p.id = b.product_id
    where p.sku in ('${PREFIX}-a', '${PREFIX}-b')
  `
}

function lotBalancesSql() {
  return `
    select coalesce(sum(lb.quantity), 0)::text
    from public.stock_lot_balances lb
    join public.stock_lots sl on sl.id = lb.lot_id
    join public.products p on p.id = sl.product_id
    where p.sku in ('${PREFIX}-a', '${PREFIX}-b')
  `
}

try {
  await psql(`
    do $$
    declare
      admin_id uuid := gen_random_uuid();
      accounts_id uuid := gen_random_uuid();
      godown_id uuid := gen_random_uuid();
      keeper_id uuid := gen_random_uuid();
      driver_id uuid := gen_random_uuid();
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      crate_2 uuid;
      product_a uuid;
      product_b uuid;
    begin
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at
      )
      values
        ('00000000-0000-0000-0000-000000000000', admin_id, 'authenticated', 'authenticated',
          'admin.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
        ('00000000-0000-0000-0000-000000000000', accounts_id, 'authenticated', 'authenticated',
          'accounts.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
        ('00000000-0000-0000-0000-000000000000', godown_id, 'authenticated', 'authenticated',
          'godown.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
        ('00000000-0000-0000-0000-000000000000', keeper_id, 'authenticated', 'authenticated',
          'keeper.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
        ('00000000-0000-0000-0000-000000000000', driver_id, 'authenticated', 'authenticated',
          'driver.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());
      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'admin', true), (accounts_id, 'accounts', true),
        (godown_id, 'godown', true), (keeper_id, 'keeper', true), (driver_id, 'driver', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, roles.id, admin_id
      from (values
        (admin_id, 'admin'), (accounts_id, 'accounts'), (godown_id, 'godown_manager'),
        (keeper_id, 'store_keeper'), (driver_id, 'delivery_person')
      ) u(id, role_code)
      join public.roles on roles.code = u.role_code
      on conflict do nothing;
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      branch_id := public.create_branch('${PREFIX}', 'M74B H');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c1', 'C1', null);
      crate_2 := public.create_crate(zone_id, '${PREFIX}_c2', 'C2', null);
      product_a := public.create_product('${PREFIX}-a', 'M74BH A', null, null);
      product_b := public.create_product('${PREFIX}-b', 'M74BH B', null, null);
      perform public.set_product_expiry_policy(product_a, 'expiry_controlled');
      perform public.set_product_expiry_policy(product_b, 'expiry_controlled');
      perform public.create_shop('M74BH shop', null, null);
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.create_vehicle(branch_id, 'KL07${PREFIX}', 'van', 'H van', 10, null);
    end $$;
  `)

  await psql(`
    set session_replication_role = replica;
    update public.app_configuration set value = 'true'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)

  await psql(`
    do $$
    declare
      admin_id uuid := (select id from auth.users where email = 'admin.${PREFIX}@example.com');
      crate_id uuid := (select crates.id from public.crates where crates.code = '${PREFIX}_c1');
      crate_2 uuid := (select crates.id from public.crates where crates.code = '${PREFIX}_c2');
      product_a uuid := (select id from public.products where sku = '${PREFIX}-a');
      product_b uuid := (select id from public.products where sku = '${PREFIX}-b');
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      perform public.post_opening_stock(product_a, crate_id, 20, '${PREFIX}-open-a', null, 'M74BHA', null, '2028-06-01');
      perform public.post_opening_stock(product_b, crate_2, 20, '${PREFIX}-open-b', null, 'M74BHB', null, '2028-07-01');
    end $$;
  `)

  // --- 1. Unposted two-lot inject after first ledger credit, then retry ---
  await psql(seedSql("ml", { approve: true }))
  const multi = await loadReturn()
  const openingBalances = String(await psql(balancesSql())).trim()
  const openingLots = String(await psql(lotBalancesSql())).trim()
  if (multi.lotCount < 2) throw new Error(`expected two return lots, got ${multi.lotCount}`)
  if (multi.status !== "approved") throw new Error(`expected approved, got ${multi.status}`)

  await psql(`
    create or replace function public.m74bh_inject_second_ledger()
    returns trigger language plpgsql as $f$
    begin
      if exists (
        select 1 from public.stock_transactions
        where id = new.transaction_id and transaction_type = 'DELIVERY_RETURN'
      ) and (
        select count(*) from public.stock_ledger where transaction_id = new.transaction_id
      ) >= 2 then
        raise exception 'injected multi-lot ledger failure' using errcode = 'P0001';
      end if;
      return new;
    end;
    $f$;
    drop trigger if exists m74bh_inject on public.stock_ledger;
    create constraint trigger m74bh_inject
      after insert on public.stock_ledger
      deferrable initially immediate
      for each row execute function public.m74bh_inject_second_ledger();
  `)

  const inject = await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.post_delivery_return('${multi.returnId}'::uuid, ${multi.version}, '${PREFIX}-inject');
    commit;
  `).then(
    () => "posted",
    (error) => String(error.message),
  )

  const afterInjectTxn = Number(
    await psql(
      `select count(*) from public.stock_transactions where delivery_return_id = '${multi.returnId}'::uuid`,
    ),
  )
  const afterInjectLedger = Number(
    await psql(`
      select count(*) from public.stock_ledger sl
      join public.stock_transactions st on st.id = sl.transaction_id
      where st.delivery_return_id = '${multi.returnId}'::uuid
        and sl.quantity > 0
    `),
  )
  const afterInjectStatus = String(
    await psql(`select status from public.stock_delivery_returns where id = '${multi.returnId}'::uuid`),
  ).trim()
  const afterInjectPostedBy = String(
    await psql(
      `select coalesce(posted_by::text, '') from public.stock_delivery_returns where id = '${multi.returnId}'::uuid`,
    ),
  ).trim()
  const afterInjectBalances = String(await psql(balancesSql())).trim()
  const afterInjectLots = String(await psql(lotBalancesSql())).trim()

  await psql(`
    drop trigger if exists m74bh_inject on public.stock_ledger;
    drop function if exists public.m74bh_inject_second_ledger();
  `)

  if (inject === "posted") throw new Error("injected multi-lot failure must abort posting")
  if (!/injected multi-lot ledger failure/i.test(inject)) {
    throw new Error(`unexpected inject result ${inject}`)
  }
  if (afterInjectTxn !== 0) throw new Error(`inject leaked ${afterInjectTxn} DELIVERY_RETURN txn`)
  if (afterInjectLedger !== 0) throw new Error(`inject leaked ${afterInjectLedger} positive ledger lines`)
  if (afterInjectStatus !== "approved") {
    throw new Error(`inject must leave return approved, got ${afterInjectStatus}`)
  }
  if (afterInjectPostedBy) throw new Error("inject must not set posted_by")
  if (afterInjectBalances !== openingBalances) {
    throw new Error(`inject changed stock_balances ${openingBalances} -> ${afterInjectBalances}`)
  }
  if (afterInjectLots !== openingLots) {
    throw new Error(`inject changed lot balances ${openingLots} -> ${afterInjectLots}`)
  }
  ok("multi-lot failure after first ledger credit rolled back")

  await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.post_delivery_return('${multi.returnId}'::uuid, ${multi.version}, '${PREFIX}-retry');
    commit;
  `)
  const retryTxn = Number(
    await psql(
      `select count(*) from public.stock_transactions where delivery_return_id = '${multi.returnId}'::uuid`,
    ),
  )
  const retryLedger = Number(
    await psql(`
      select count(*) from public.stock_ledger sl
      join public.stock_transactions st on st.id = sl.transaction_id
      where st.delivery_return_id = '${multi.returnId}'::uuid and sl.quantity > 0
    `),
  )
  const retryStatus = String(
    await psql(`select status from public.stock_delivery_returns where id = '${multi.returnId}'::uuid`),
  ).trim()
  if (retryTxn !== 1) throw new Error(`retry expected one txn, got ${retryTxn}`)
  if (retryLedger !== 2) throw new Error(`retry expected two positive ledger lines, got ${retryLedger}`)
  if (retryStatus !== "posted") throw new Error(`retry expected posted, got ${retryStatus}`)

  await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.post_delivery_return(
      '${multi.returnId}'::uuid,
      (public.get_delivery_return('${multi.dispatchId}'::uuid) ->> 'version')::integer,
      '${PREFIX}-retry-2'
    );
    commit;
  `).catch(() => null)
  const replayTxn = Number(
    await psql(
      `select count(*) from public.stock_transactions where delivery_return_id = '${multi.returnId}'::uuid`,
    ),
  )
  if (replayTxn !== 1) throw new Error("successful retry replay added a transaction")
  ok("multi-lot retry posts exactly once")

  // --- 2. GM approval versus Store Keeper count correction ---
  await psql(seedSql("race-ap", { approve: false, dual: false }))
  const counted = await loadReturn()
  const lotRows = String(
    await psql(`
      select string_agg(concat_ws(',', id::text, product_id::text, source_crate_id::text, dispatched_cases::text), ';')
      from public.stock_delivery_return_lots
      where return_id = '${counted.returnId}'::uuid
    `),
  ).trim()
  const correction = lotRows
    .split(";")
    .map((row, index) => {
      const [id, , crate] = row.split(",")
      return {
        id,
        delivered_cases: 0,
        saleable_cases: index === 0 ? 0 : 1,
        damaged_cases: 0,
        uncertain_cases: 0,
        missing_cases: index === 0 ? 1 : 0,
        receiving_crate_id: index === 0 ? null : crate,
      }
    })
  const approveRace = await Promise.allSettled([
    psql(`
      begin;
      ${asUser(`godown.${PREFIX}@example.com`)}
      select public.approve_delivery_return('${counted.returnId}'::uuid, ${counted.version}, '${PREFIX}-race-ap');
      commit;
    `),
    psql(`
      begin;
      ${asUser(`keeper.${PREFIX}@example.com`)}
      select public.count_delivery_return(
        '${counted.returnId}'::uuid,
        '${JSON.stringify(correction)}'::jsonb,
        ${counted.version},
        '${PREFIX}-race-ct'
      );
      commit;
    `),
  ])
  const approveWins = approveRace.filter((row) => row.status === "fulfilled").length
  if (approveWins < 1) {
    throw new Error(`approve vs count produced no winner: ${JSON.stringify(approveRace.map((r) => r.reason ?? "ok"))}`)
  }
  const raceState = String(
    await psql(`
      select concat_ws('|', status, coalesce(approved_by::text, ''), coalesce(approval_fingerprint, ''), version::text)
      from public.stock_delivery_returns where id = '${counted.returnId}'::uuid
    `),
  ).trim()
  const [raceStatus, raceApprovedBy, raceFp, raceVersion] = raceState.split("|")
  if (Number(raceVersion) !== counted.version + 1) {
    throw new Error(`approve vs count must advance version once, got ${raceVersion}`)
  }
  if (raceStatus === "approved") {
    const liveFp = String(
      await psql(`select app_private.return_lot_fingerprint('${counted.returnId}'::uuid)`),
    ).trim()
    if (!raceApprovedBy || raceFp !== liveFp) {
      throw new Error("approved fingerprint does not match current count")
    }
  } else if (raceStatus !== "counted" || raceApprovedBy) {
    throw new Error(`approve vs count left invalid state ${raceState}`)
  }
  ok("GM approval versus Store Keeper count correction")

  // --- 3. close-all-missing versus post ---
  await psql(seedSql("race-cl", { approve: true, dual: false }))
  const closable = await loadReturn()
  const closeRace = await Promise.allSettled([
    psql(`
      begin;
      ${asUser(`godown.${PREFIX}@example.com`)}
      select public.post_delivery_return('${closable.returnId}'::uuid, ${closable.version}, '${PREFIX}-race-post');
      commit;
    `),
    psql(`
      begin;
      ${asUser(`godown.${PREFIX}@example.com`)}
      select public.close_delivery_return_missing('${closable.returnId}'::uuid, ${closable.version}, '${PREFIX}-race-close');
      commit;
    `),
  ])
  const closeWins = closeRace.filter((row) => row.status === "fulfilled").length
  if (closeWins < 1) {
    throw new Error(`close vs post produced no winner: ${JSON.stringify(closeRace.map((r) => r.reason ?? "ok"))}`)
  }
  const closeState = String(
    await psql(`
      select concat_ws('|',
        status,
        coalesce(posted_transaction_id::text, ''),
        (select count(*)::text from public.stock_transactions where delivery_return_id = stock_delivery_returns.id)
      )
      from public.stock_delivery_returns where id = '${closable.returnId}'::uuid
    `),
  ).trim()
  const [closeStatus, closeTxnId, closeTxnCount] = closeState.split("|")
  if (closeStatus === "posted") {
    if (Number(closeTxnCount) !== 1 || !closeTxnId) {
      throw new Error(`posted close-race must have one txn, got ${closeState}`)
    }
  } else if (closeStatus === "closed_missing") {
    if (Number(closeTxnCount) !== 0 || closeTxnId) {
      throw new Error(`closed_missing must not credit stock, got ${closeState}`)
    }
  } else {
    throw new Error(`close vs post left ${closeState}`)
  }
  ok("close_delivery_return_missing versus post_delivery_return")

  // --- 4. Receiving crate deactivation versus posting ---
  await psql(seedSql("crate", { approve: true, dual: false }))
  const crateReturn = await loadReturn()
  const crateRace = await Promise.allSettled([
    psql(`
      begin;
      ${asUser(`godown.${PREFIX}@example.com`)}
      select public.post_delivery_return('${crateReturn.returnId}'::uuid, ${crateReturn.version}, '${PREFIX}-crate-post');
      commit;
    `),
    psql(`
      begin;
      set session_replication_role = replica;
      update public.crates set is_active = false where code in ('${PREFIX}_c1', '${PREFIX}_c2');
      set session_replication_role = origin;
      commit;
    `),
  ])
  const cratePosted = crateRace[0].status === "fulfilled"
  const crateStatus = String(
    await psql(`select status from public.stock_delivery_returns where id = '${crateReturn.returnId}'::uuid`),
  ).trim()
  const crateTxn = Number(
    await psql(
      `select count(*) from public.stock_transactions where delivery_return_id = '${crateReturn.returnId}'::uuid`,
    ),
  )
  if (cratePosted) {
    if (crateStatus !== "posted" || crateTxn !== 1) {
      throw new Error(`crate race post winner invalid ${crateStatus} txn=${crateTxn}`)
    }
  } else {
    if (crateStatus === "posted" || crateTxn !== 0) {
      throw new Error(`crate deactivation leaked a credit ${crateStatus} txn=${crateTxn}`)
    }
    const crateErr = String(crateRace[0].reason || "")
    if (!/inactive|storage crate|23514/i.test(crateErr)) {
      throw new Error(`crate race unexpected post error ${crateErr}`)
    }
  }
  await psql(`
    set session_replication_role = replica;
    update public.crates set is_active = true where code in ('${PREFIX}_c1', '${PREFIX}_c2');
    set session_replication_role = origin;
  `)
  ok("receiving crate deactivation versus posting")

  // --- 5. Lot expiry versus posting ---
  await psql(seedSql("exp", { approve: true, dual: false }))
  const expReturn = await loadReturn()
  const expRace = await Promise.allSettled([
    psql(`
      begin;
      ${asUser(`godown.${PREFIX}@example.com`)}
      select public.post_delivery_return('${expReturn.returnId}'::uuid, ${expReturn.version}, '${PREFIX}-exp-post');
      commit;
    `),
    psql(`
      begin;
      set session_replication_role = replica;
      update public.stock_lots sl
      set expiry_date = (current_date - 1)
      from public.products p
      where p.id = sl.product_id and p.sku in ('${PREFIX}-a', '${PREFIX}-b');
      set session_replication_role = origin;
      commit;
    `),
  ])
  const expPosted = expRace[0].status === "fulfilled"
  const expStatus = String(
    await psql(`select status from public.stock_delivery_returns where id = '${expReturn.returnId}'::uuid`),
  ).trim()
  const expTxn = Number(
    await psql(
      `select count(*) from public.stock_transactions where delivery_return_id = '${expReturn.returnId}'::uuid`,
    ),
  )
  if (expPosted) {
    if (expStatus !== "posted" || expTxn !== 1) {
      throw new Error(`expiry race post winner invalid ${expStatus} txn=${expTxn}`)
    }
  } else {
    if (expStatus === "posted" || expTxn !== 0) {
      throw new Error(`expiry change leaked a saleable credit ${expStatus} txn=${expTxn}`)
    }
    const expErr = String(expRace[0].reason || "")
    if (!/expired|blocked|23514/i.test(expErr)) {
      throw new Error(`expiry race unexpected post error ${expErr}`)
    }
  }
  await psql(`
    set session_replication_role = replica;
    update public.stock_lots sl
    set expiry_date = '2028-06-01'
    from public.products p
    where p.id = sl.product_id and p.sku = '${PREFIX}-a';
    update public.stock_lots sl
    set expiry_date = '2028-07-01'
    from public.products p
    where p.id = sl.product_id and p.sku = '${PREFIX}-b';
    set session_replication_role = origin;
  `)
  ok("lot expiry change versus posting")

  // --- 6. Permission revocation versus posting ---
  await psql(seedSql("perm", { approve: true, dual: false }))
  const permReturn = await loadReturn()
  await psql(`
    delete from public.role_permissions
    using public.roles, public.permissions
    where role_permissions.role_id = roles.id
      and role_permissions.permission_id = permissions.id
      and roles.code = 'godown_manager'
      and permissions.code = 'deliveries.return_post';
  `)
  const perm = await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.post_delivery_return('${permReturn.returnId}'::uuid, ${permReturn.version}, '${PREFIX}-perm-post');
    commit;
  `).then(
    () => "posted",
    (error) => String(error.message),
  )
  await psql(`
    insert into public.role_permissions (role_id, permission_id)
    select roles.id, permissions.id
    from public.roles, public.permissions
    where roles.code = 'godown_manager'
      and permissions.code = 'deliveries.return_post'
    on conflict do nothing;
  `)
  const permStatus = String(
    await psql(`select status from public.stock_delivery_returns where id = '${permReturn.returnId}'::uuid`),
  ).trim()
  const permTxn = Number(
    await psql(
      `select count(*) from public.stock_transactions where delivery_return_id = '${permReturn.returnId}'::uuid`,
    ),
  )
  if (perm === "posted" || permStatus === "posted" || permTxn !== 0) {
    throw new Error("revoked GM must not post a DELIVERY_RETURN")
  }
  if (!/42501|not authorized/i.test(perm)) {
    throw new Error(`revocation unexpected result ${perm}`)
  }
  ok("permission revocation versus posting")
} finally {
  await psql(`
    drop trigger if exists m74bh_inject on public.stock_ledger;
    drop function if exists public.m74bh_inject_second_ledger();
    insert into public.role_permissions (role_id, permission_id)
    select roles.id, permissions.id
    from public.roles, public.permissions
    where roles.code = 'godown_manager'
      and permissions.code = 'deliveries.return_post'
    on conflict do nothing;
    set session_replication_role = replica;
    update public.crates set is_active = true where code like '${PREFIX}%';
    update public.stock_ledger sl
    set lot_id = null
    from public.products p
    where p.id = sl.product_id and p.sku like '${PREFIX}%';
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

console.log(`M7.4B hardening passed ${passed.length} checks`)
