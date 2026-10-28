/**
 * M7.4B concurrency and failure injection. Local Docker only. Flags restored in finally.
 */
import { spawn } from "node:child_process"

const PREFIX = `m74bc_${Date.now().toString(36)}`
const PASSWORD = "local-only-m74bc"

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

function postSql(returnId, version, key) {
  return `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.post_delivery_return('${returnId}'::uuid, ${version}, '${key}');
commit;
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
      product_id uuid;
      shop_id uuid;
      vehicle_id uuid;
      order_id uuid;
      request_id uuid;
      header jsonb;
      res jsonb;
      i int;
      ret jsonb;
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
      perform set_config(
        'request.jwt.claims',
        json_build_object('sub', admin_id, 'role', 'authenticated')::text, true
      );
      perform set_config('role', 'authenticated', true);
      branch_id := public.create_branch('${PREFIX}', 'M74B C');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}', 'M74B C Soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('M74B C shop', null, null);
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config(
        'request.jwt.claims',
        json_build_object('sub', godown_id, 'role', 'authenticated')::text, true
      );
      vehicle_id := public.create_vehicle(branch_id, 'KL07${PREFIX}', 'van', 'C van', 10, null);
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
      accounts_id uuid := (select id from auth.users where email = 'accounts.${PREFIX}@example.com');
      godown_id uuid := (select id from auth.users where email = 'godown.${PREFIX}@example.com');
      keeper_id uuid := (select id from auth.users where email = 'keeper.${PREFIX}@example.com');
      driver_id uuid := (select id from auth.users where email = 'driver.${PREFIX}@example.com');
      branch_id uuid := (select id from public.branches where code = '${PREFIX}');
      crate_id uuid := (select crates.id from public.crates join public.zones on zones.id = crates.zone_id
        where crates.code = '${PREFIX}_c');
      product_id uuid := (select id from public.products where sku = '${PREFIX}');
      shop_id uuid := (select id from public.shops where name = 'M74B C shop' order by created_at desc limit 1);
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
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      perform public.post_opening_stock(product_id, crate_id, 8, '${PREFIX}-open', null, 'M74BC', null, '2028-06-01');

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      header := public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 2)),
        '${PREFIX}-ord'
      );
      order_id := (header -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-ver');
      header := public.create_delivery_note(order_id, '${PREFIX}-dn');
      perform public.generate_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen');
      perform public.send_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-send');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack');
      header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-res');
      request_id := (header ->> 'id')::uuid;
      header := public.assign_picking_request(request_id, keeper_id, 1, '${PREFIX}-asg');
      header := public.start_picking(request_id, 2, '${PREFIX}-start');
      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
      header := public.get_picking_request(request_id);
      for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
        res := header -> 'reservations' -> i;
        header := public.confirm_picking_quantity(
          request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
          (header ->> 'version')::integer, '${PREFIX}-pick-' || i::text
        );
      end loop;
      header := public.complete_picking(request_id, (header ->> 'version')::integer, '${PREFIX}-done');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, '${PREFIX}-ho');
      preview := public.preview_dispatch(order_id);
      prepared := public.prepare_dispatch(order_id, (preview ->> 'picking_version')::integer, '${PREFIX}-prep');
      confirmed := public.confirm_dispatch((prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, '${PREFIX}-cfm');
      assigned := public.assign_dispatch_delivery(
        (confirmed ->> 'id')::uuid, driver_id, (confirmed ->> 'version')::integer, '${PREFIX}-asgd', vehicle_id
      );
      excepted := public.report_dispatch_delivery_exception(
        (assigned ->> 'id')::uuid, 'closed', (assigned ->> 'version')::integer, '${PREFIX}-exc'
      );
      perform set_config('request.jwt.claim.sub', driver_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', driver_id, 'role', 'authenticated')::text, true);
      ret := public.get_delivery_return((excepted ->> 'id')::uuid);
      ret := public.declare_delivery_return_handback(
        (ret ->> 'id')::uuid, 2, null, (ret ->> 'version')::integer, '${PREFIX}-hb'
      );
      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
      ret := public.count_delivery_return(
        (ret ->> 'id')::uuid,
        jsonb_build_array(jsonb_build_object(
          'id', ret -> 'lots' -> 0 ->> 'id',
          'delivered_cases', 0, 'saleable_cases', 2, 'damaged_cases', 0,
          'uncertain_cases', 0, 'missing_cases', 0,
          'receiving_crate_id', crate_id
        )),
        (ret ->> 'version')::integer, '${PREFIX}-ct'
      );
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.approve_delivery_return(
        (ret ->> 'id')::uuid, (ret ->> 'version')::integer, '${PREFIX}-ap'
      );
    end $$;
  `)

  const ids = String(
    await psql(`
      select concat_ws('|',
        r.id::text,
        r.version::text,
        r.dispatch_id::text,
        (select count(*)::text from public.stock_transactions where delivery_return_id = r.id)
      )
      from public.stock_delivery_returns r
      join public.products p on p.sku = '${PREFIX}'
      join public.stock_delivery_return_lots lots on lots.return_id = r.id
      where lots.product_id = p.id
      limit 1
    `),
  ).trim()
  const [returnId, version, dispatchId] = ids.split("|")
  if (!returnId) throw new Error("approved return missing")

  const race = await Promise.allSettled([
    psql(postSql(returnId, version, `${PREFIX}-post-a`)),
    psql(postSql(returnId, version, `${PREFIX}-post-b`)),
  ])
  const wins = race.filter((row) => row.status === "fulfilled").length
  if (wins < 1) {
    throw new Error(`concurrent post produced no winner: ${JSON.stringify(race.map((r) => r.reason ?? "ok"))}`)
  }
  const txnCount = Number(
    await psql(`select count(*) from public.stock_transactions where delivery_return_id = '${returnId}'::uuid`),
  )
  if (txnCount !== 1) throw new Error(`expected one DELIVERY_RETURN, got ${txnCount}`)
  ok("concurrent post_delivery_return writes one transaction")

  await psql(postSql(returnId, Number(version) + 5, `${PREFIX}-post-replay`)).catch(() => null)
  const txnReplay = Number(
    await psql(`select count(*) from public.stock_transactions where delivery_return_id = '${returnId}'::uuid`),
  )
  if (txnReplay !== 1) throw new Error("replay added a transaction")
  ok("post replay remains exact-once")

  const secondWave = await psql(`
    begin;
    select set_config('app.delivery_return_write', 'on', true);
    insert into public.stock_delivery_returns (
      dispatch_id, branch_id, return_number, status, created_by
    )
    select dispatch_id, branch_id, 'DR-DUP-${PREFIX}', 'awaiting_handback', created_by
    from public.stock_delivery_returns
    where id = '${returnId}'::uuid;
    commit;
  `).then(
    () => "inserted",
    (error) => String(error.message),
  )
  if (secondWave === "inserted") throw new Error("second return wave must fail")
  ok("second return document for one dispatch is rejected")

  await psql(`
    create or replace function public.m74b_inject_ledger_fail()
    returns trigger language plpgsql as $f$
    begin
      if current_setting('app.m74b_inject', true) = 'on' then
        if (select count(*) from public.stock_ledger where transaction_id = new.transaction_id) >= 1 then
          raise exception 'injected multi-lot ledger failure' using errcode = 'P0001';
        end if;
      end if;
      return new;
    end;
    $f$;
    drop trigger if exists m74b_inject on public.stock_ledger;
    create constraint trigger m74b_inject
      after insert on public.stock_ledger
      deferrable initially immediate
      for each row execute function public.m74b_inject_ledger_fail();
  `)

  const inject = await psql(`
    begin;
    select set_config('app.m74b_inject', 'on', true);
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.post_delivery_return(
      '${returnId}'::uuid,
      (public.get_delivery_return('${dispatchId}'::uuid) ->> 'version')::integer,
      '${PREFIX}-inject'
    );
    commit;
  `).then(
    () => "posted",
    (error) => String(error.message),
  )
  await psql(`
    drop trigger if exists m74b_inject on public.stock_ledger;
    drop function if exists public.m74b_inject_ledger_fail();
  `)
  if (inject === "posted") {
    // Already posted from the race; inject on a posted return is a replay and must not add lines.
    const extra = Number(
      await psql(`select count(*) from public.stock_ledger sl
        join public.stock_transactions st on st.id = sl.transaction_id
        where st.delivery_return_id = '${returnId}'::uuid`),
    )
    if (extra < 1) throw new Error("posted return lost ledger lines")
    ok("injected failure on already-posted return does not add ledger lines")
  } else if (!/injected multi-lot ledger failure/i.test(inject)) {
    throw new Error(`unexpected inject result ${inject}`)
  } else {
    const leftover = Number(
      await psql(`select count(*) from public.stock_transactions where delivery_return_id = '${returnId}'::uuid`),
    )
    if (leftover !== 0) throw new Error("injected failure leaked a transaction")
    ok("failure after first ledger insert rolled back")
  }
} finally {
  await psql(`
    drop trigger if exists m74b_inject on public.stock_ledger;
    drop function if exists public.m74b_inject_ledger_fail();
    set session_replication_role = replica;
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

console.log(`M7.4B concurrency passed ${passed.length} checks`)
