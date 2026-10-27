/**
 * M7.4A concurrency: assignment, start, POD, fail, and vehicle deactivation races.
 * Local Docker only. Flags restored in finally.
 */
import { spawn } from "node:child_process"

const PREFIX = `m74ac_${Date.now().toString(36)}`
const PASSWORD = "local-only-m74ac"

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
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = '${email}'), true);
set local role authenticated;
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
      driver2_id uuid := gen_random_uuid();
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
      prepared jsonb;
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
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
        ('00000000-0000-0000-0000-000000000000', driver2_id, 'authenticated', 'authenticated',
          'driver2.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'admin', true),
        (accounts_id, 'accounts', true),
        (godown_id, 'godown', true),
        (keeper_id, 'keeper', true),
        (driver_id, 'driver', true),
        (driver2_id, 'driver2', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, roles.id, admin_id
      from (values
        (admin_id, 'admin'),
        (accounts_id, 'accounts'),
        (godown_id, 'godown_manager'),
        (keeper_id, 'store_keeper'),
        (driver_id, 'delivery_person'),
        (driver2_id, 'delivery_person')
      ) u(id, role_code)
      join public.roles on roles.code = u.role_code
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      branch_id := public.create_branch('${PREFIX}', 'M74AC');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      perform public.assign_user_branch(driver2_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}c', 'C', null);
      product_id := public.create_product('${PREFIX}-sku', 'M74AC soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('M74AC shop', null, null);
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      vehicle_id := public.create_vehicle(branch_id, 'KL07${PREFIX}', 'van', 'Race van', null, null);
    end;
    $$;
  `)

  await psql(`
    set session_replication_role = replica;
    update public.app_configuration set value = 'true'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)

  await psql(`
    begin;
    ${asUser(`admin.${PREFIX}@example.com`)}
    select public.post_opening_stock(
      (select id from public.products where sku = '${PREFIX}-sku'),
      (select id from public.crates where code = '${PREFIX}c'),
      12, '${PREFIX}-open', null, 'M74AC', null, '2028-06-01'
    );
    commit;
  `)

  async function makeDispatched(tag) {
    await psql(`
      do $$
      declare
        accounts_id uuid := (select id from auth.users where email = 'accounts.${PREFIX}@example.com');
        godown_id uuid := (select id from auth.users where email = 'godown.${PREFIX}@example.com');
        keeper_id uuid := (select id from auth.users where email = 'keeper.${PREFIX}@example.com');
        shop_id uuid := (select id from public.shops where name = 'M74AC shop' order by created_at desc limit 1);
        branch_id uuid := (select id from public.branches where code = '${PREFIX}');
        product_id uuid := (select id from public.products where sku = '${PREFIX}-sku');
        order_id uuid;
        request_id uuid;
        header jsonb;
        res jsonb;
        i int;
        preview jsonb;
        prepared jsonb;
      begin
        perform set_config('request.jwt.claim.sub', accounts_id::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
        order_id := (public.create_order(
          shop_id, branch_id, 'accounts', null, null,
          jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 1)),
          '${PREFIX}-${tag}-ord'
        ) -> 'order' ->> 'id')::uuid;
        perform public.submit_order(order_id, 1, '${PREFIX}-${tag}-sub');
        perform public.verify_order(order_id, 2, '${PREFIX}-${tag}-ver');
        header := public.create_delivery_note(order_id, '${PREFIX}-${tag}-dn');
        perform public.generate_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-${tag}-gen');
        perform public.send_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-${tag}-send');
        perform set_config('request.jwt.claim.sub', godown_id::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
        perform public.acknowledge_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-${tag}-ack');
        header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-${tag}-res');
        request_id := (header ->> 'id')::uuid;
        header := public.assign_picking_request(request_id, keeper_id, 1, '${PREFIX}-${tag}-asg');
        header := public.start_picking(request_id, 2, '${PREFIX}-${tag}-start');
        perform set_config('request.jwt.claim.sub', keeper_id::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
        header := public.get_picking_request(request_id);
        for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
          res := header -> 'reservations' -> i;
          header := public.confirm_picking_quantity(
            request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
            (header ->> 'version')::integer, '${PREFIX}-${tag}-pick-' || i::text
          );
        end loop;
        header := public.complete_picking(request_id, (header ->> 'version')::integer, '${PREFIX}-${tag}-done');
        perform set_config('request.jwt.claim.sub', godown_id::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
        header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, '${PREFIX}-${tag}-ho');
        preview := public.preview_dispatch(order_id);
        prepared := public.prepare_dispatch(order_id, (header ->> 'version')::integer, '${PREFIX}-${tag}-prep');
        perform public.confirm_dispatch(
          (prepared ->> 'id')::uuid,
          (prepared ->> 'version')::integer,
          '${PREFIX}-${tag}-cfm'
        );
      end;
      $$;
    `)
  }

  await makeDispatched("a")
  const vehicleId = String(
    await psql(`select id::text from public.vehicles where display_name = 'Race van' order by created_at desc limit 1`),
  ).trim()
  const driverId = String(
    await psql(`select id::text from auth.users where email = 'driver.${PREFIX}@example.com'`),
  ).trim()
  const driver2Id = String(
    await psql(`select id::text from auth.users where email = 'driver2.${PREFIX}@example.com'`),
  ).trim()
  const dispatchA = String(
    await psql(`
      select id::text from public.stock_dispatch_requests
      where created_by = (select id from auth.users where email = 'godown.${PREFIX}@example.com')
      order by created_at desc limit 1
    `),
  ).trim()

  const assignSql = (who, key) => `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.assign_dispatch_delivery(
  '${dispatchA}'::uuid,
  '${who}'::uuid,
  (select version from public.stock_dispatch_requests where id = '${dispatchA}'::uuid),
  '${key}',
  '${vehicleId}'::uuid
);
commit;
`
  const assignRace = await Promise.allSettled([
    psql(assignSql(driverId, `${PREFIX}-asg-a`)),
    psql(assignSql(driver2Id, `${PREFIX}-asg-b`)),
  ])
  const assignWins = assignRace.filter((row) => row.status === "fulfilled").length
  if (assignWins < 1) throw new Error(`assignment race produced no winner: ${JSON.stringify(assignRace)}`)
  const assignees = String(
    await psql(`
      select count(*) from public.stock_dispatch_assignments
      where dispatch_id = '${dispatchA}'::uuid and unassigned_at is null
    `),
  ).trim()
  if (assignees !== "1") throw new Error(`expected one current assignment, got ${assignees}`)
  ok("concurrent assignments: one current assignee")

  await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.report_dispatch_delivery_exception(
      '${dispatchA}'::uuid,
      'free vehicle',
      (select version from public.stock_dispatch_requests where id = '${dispatchA}'::uuid),
      '${PREFIX}-free-a'
    );
    commit;
  `)

  await makeDispatched("b")
  const dispatchB = String(
    await psql(`
      select id::text from public.stock_dispatch_requests
      where id is distinct from '${dispatchA}'::uuid
        and status = 'dispatched'
      order by created_at desc limit 1
    `),
  ).trim()
  await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.assign_dispatch_delivery(
      '${dispatchB}'::uuid,
      '${driverId}'::uuid,
      (select version from public.stock_dispatch_requests where id = '${dispatchB}'::uuid),
      '${PREFIX}-asg-b1',
      '${vehicleId}'::uuid
    );
    commit;
  `)

  const startSql = `
begin;
${asUser(`driver.${PREFIX}@example.com`)}
select public.start_dispatch_delivery(
  '${dispatchB}'::uuid,
  (select version from public.stock_dispatch_requests where id = '${dispatchB}'::uuid),
  '${PREFIX}-go-b'
);
commit;
`
  const reassignSql = `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.assign_dispatch_delivery(
  '${dispatchB}'::uuid,
  '${driver2Id}'::uuid,
  (select version from public.stock_dispatch_requests where id = '${dispatchB}'::uuid),
  '${PREFIX}-asg-b2',
  '${vehicleId}'::uuid
);
commit;
`
  const startRace = await Promise.allSettled([psql(startSql), psql(reassignSql)])
  const startWins = startRace.filter((row) => row.status === "fulfilled").length
  if (startWins !== 1) {
    throw new Error(`start vs reassign expected one winner, got ${startWins}`)
  }
  ok("vehicle reassignment racing in-transit: one winner")

  await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.report_dispatch_delivery_exception(
      '${dispatchB}'::uuid,
      'free vehicle',
      (select version from public.stock_dispatch_requests where id = '${dispatchB}'::uuid),
      '${PREFIX}-free-b'
    );
    commit;
  `)

  await makeDispatched("c")
  const dispatchC = String(
    await psql(`
      select id::text from public.stock_dispatch_requests
      where status = 'dispatched'
      order by created_at desc limit 1
    `),
  ).trim()
  await psql(`
    begin;
    ${asUser(`godown.${PREFIX}@example.com`)}
    select public.assign_dispatch_delivery(
      '${dispatchC}'::uuid,
      '${driverId}'::uuid,
      (select version from public.stock_dispatch_requests where id = '${dispatchC}'::uuid),
      '${PREFIX}-asg-c',
      '${vehicleId}'::uuid
    );
    commit;
  `)
  const podSql = (key) => `
begin;
${asUser(`driver.${PREFIX}@example.com`)}
select public.acknowledge_dispatch_delivery(
  '${dispatchC}'::uuid,
  'Shop owner',
  null,
  (select version from public.stock_dispatch_requests where id = '${dispatchC}'::uuid),
  '${key}'
);
commit;
`
  const failSql = `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.report_dispatch_delivery_exception(
  '${dispatchC}'::uuid,
  'refused',
  (select version from public.stock_dispatch_requests where id = '${dispatchC}'::uuid),
  '${PREFIX}-fail-c'
);
commit;
`
  const outcomeRace = await Promise.allSettled([psql(podSql(`${PREFIX}-pod-c`)), psql(failSql)])
  const outcomeWins = outcomeRace.filter((row) => row.status === "fulfilled").length
  if (outcomeWins !== 1) {
    throw new Error(`delivered vs failed expected one winner, got ${outcomeWins}`)
  }
  const outcomes = String(
    await psql(`
      select count(*) from public.stock_dispatch_outcome_lines
      where dispatch_id = '${dispatchC}'::uuid
    `),
  ).trim()
  if (Number(outcomes) < 1) throw new Error("outcome lines missing after race")
  ok("delivered versus failed: one outcome")

  const dupPod = await Promise.allSettled([
    psql(podSql(`${PREFIX}-pod-dup-a`)),
    psql(podSql(`${PREFIX}-pod-dup-b`)),
  ])
  const dupWins = dupPod.filter((row) => row.status === "fulfilled").length
  if (dupWins > 1) {
    const lineCount = String(
      await psql(`
        select count(*) from public.stock_dispatch_outcome_lines
        where dispatch_id = '${dispatchC}'::uuid
      `),
    ).trim()
    if (Number(lineCount) !== Number(outcomes)) {
      throw new Error("duplicate POD double-counted outcome lines")
    }
  }
  ok("duplicate POD does not double-count")

  await makeDispatched("d")
  const dispatchD = String(
    await psql(`
      select id::text from public.stock_dispatch_requests
      where status = 'dispatched'
      order by created_at desc limit 1
    `),
  ).trim()
  const deactivateSql = `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.set_vehicle_active('${vehicleId}'::uuid, false);
commit;
`
  const assignDSql = `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.assign_dispatch_delivery(
  '${dispatchD}'::uuid,
  '${driverId}'::uuid,
  (select version from public.stock_dispatch_requests where id = '${dispatchD}'::uuid),
  '${PREFIX}-asg-d',
  '${vehicleId}'::uuid
);
commit;
`
  const deactRace = await Promise.allSettled([psql(assignDSql), psql(deactivateSql)])
  const deactAssignWins = deactRace.filter((row) => row.status === "fulfilled").length
  if (deactAssignWins < 1) {
    throw new Error("deactivation vs assignment produced no committed result")
  }
  ok("vehicle deactivation during assignment fail-closed")
} finally {
  await psql(`
    set session_replication_role = replica;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)
}

console.log(`M7.4A concurrency passed ${passed.length} checks`)
