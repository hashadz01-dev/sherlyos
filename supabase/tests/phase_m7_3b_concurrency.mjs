/**
 * M7.3B concurrency: concurrent approve, concurrent dispatch, replay.
 * Local Docker only. Flags restored in finally.
 */
import { spawn } from "node:child_process"

const PREFIX = `m73bc_${Date.now().toString(36)}`
const PASSWORD = "local-only-m73bc"

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
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
      payload jsonb;
      header jsonb;
      res jsonb;
      note_id uuid;
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
          now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M73BC Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values (accounts_id, 'A', true), (godown_id, 'G', true), (keeper_id, 'K', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values (accounts_id, 'accounts'), (godown_id, 'godown_manager'), (keeper_id, 'store_keeper')) u(id, code)
      join public.roles r on r.code = u.code
      on conflict do nothing;

      execute 'reset role';
      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';

      branch_id := public.create_branch('${PREFIX}', 'M73BC');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}-sku', 'Soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      shop_id := public.create_shop('${PREFIX} shop', null, null);
      perform public.post_opening_stock(product_id, crate_id, 6, '${PREFIX}-open', null, 'M73BC', null, null);

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 2)),
        '${PREFIX}-ord'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-ver');
      payload := public.create_delivery_note(order_id, '${PREFIX}-dn');
      note_id := (payload -> 'delivery_note' ->> 'id')::uuid;
      perform public.generate_delivery_note(note_id, 1, '${PREFIX}-gen');
      perform public.send_delivery_note(note_id, 2, '${PREFIX}-send');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note(note_id, 3, '${PREFIX}-ack');

      header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-res');
      header := public.assign_picking_request((header ->> 'id')::uuid, keeper_id, (header ->> 'version')::integer, '${PREFIX}-asg');
      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
      header := public.start_picking((header ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-start');
      res := header -> 'reservations' -> 0;
      header := public.confirm_picking_quantity((header ->> 'id')::uuid, (res ->> 'id')::uuid, 1, (header ->> 'version')::integer, '${PREFIX}-pick');
      header := public.report_picking_shortage((header ->> 'id')::uuid, (res ->> 'id')::uuid, 1, 'missing', (header ->> 'version')::integer, '${PREFIX}-short');
      header := public.complete_picking((header ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-complete');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      payload := public.create_short_shipment((header ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-sh');
      perform public.confirm_short_shipment_quantities((payload ->> 'id')::uuid, (payload ->> 'version')::integer, '${PREFIX}-gm');
    end;
    $$;
  `)
  ok("fixture ready for concurrent approve")

  const approveSql = (idem) => `
begin;
${asUser(`accounts.${PREFIX}@example.com`)}
select public.approve_short_shipment(
  (select id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh'),
  (select version from public.order_shipments where create_idempotency_key = '${PREFIX}-sh'),
  null,
  '${idem}'
);
commit;
`

  const approvePair = await Promise.allSettled([
    psql(approveSql(`${PREFIX}-ap1`)),
    psql(approveSql(`${PREFIX}-ap2`)),
  ])
  const approveWins = approvePair.filter((row) => row.status === "fulfilled").length
  if (approveWins !== 1) {
    throw new Error(`expected one approve winner, got ${JSON.stringify(approvePair)}`)
  }
  ok("concurrent Accounts approval: one winner")

  await psql(`
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.confirm_picking_handoff(
  (select picking_request_id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh'),
  (select version from public.stock_picking_requests
    where id = (select picking_request_id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh')),
  '${PREFIX}-hand'
);
select public.prepare_dispatch(
  (select order_id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh'),
  (select version from public.stock_picking_requests
    where id = (select picking_request_id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh')),
  '${PREFIX}-prep'
);
commit;
`)

  const dispatchSql = (idem) => `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.confirm_dispatch(
  (select id from public.stock_dispatch_requests
    where order_id = (select order_id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh')
      and status is distinct from 'cancelled'
    order by created_at desc limit 1),
  (select version from public.stock_dispatch_requests
    where order_id = (select order_id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh')
      and status is distinct from 'cancelled'
    order by created_at desc limit 1),
  '${idem}'
);
commit;
`

  const dispatchPair = await Promise.allSettled([
    psql(dispatchSql(`${PREFIX}-cfm1`)),
    psql(dispatchSql(`${PREFIX}-cfm2`)),
  ])
  const dispatchWins = dispatchPair.filter((row) => row.status === "fulfilled").length
  if (dispatchWins < 1) {
    throw new Error(`expected a dispatch result, got ${JSON.stringify(dispatchPair)}`)
  }
  const txnIds = [...new Set(
    dispatchPair
      .filter((row) => row.status === "fulfilled")
      .map((row) => row.value.match(/"posted_transaction_id": "([^"]+)"/)?.[1])
      .filter(Boolean),
  )]
  if (txnIds.length !== 1) {
    throw new Error(`concurrent dispatch must share one transaction, got ${txnIds.join(",")}`)
  }
  ok("concurrent confirm_dispatch: one stock transaction")

  const replay = await Promise.allSettled([
    psql(dispatchSql(`${PREFIX}-cfm1`)),
    psql(dispatchSql(`${PREFIX}-cfm1`)),
  ])
  if (!replay.every((row) => row.status === "fulfilled")) {
    throw new Error(`dispatch replay failed: ${JSON.stringify(replay)}`)
  }
  const ledger = await psql(`
    select coalesce(sum(sl.quantity), 0)
    from public.stock_ledger sl
    join public.stock_transactions st on st.id = sl.transaction_id
    join public.stock_dispatch_requests d on d.id = st.dispatch_request_id
    join public.order_shipments s on s.order_id = d.order_id
    where s.create_idempotency_key = '${PREFIX}-sh';
  `)
  if (String(ledger).trim() !== "-1") {
    throw new Error(`replay must not double-post, ledger=${ledger}`)
  }
  const backorders = await psql(`
    select count(*) from public.orders
    where originating_shipment_id = (
      select id from public.order_shipments where create_idempotency_key = '${PREFIX}-sh'
    )
    and status is distinct from 'cancelled';
  `)
  if (String(backorders).trim() !== "1") {
    throw new Error(`duplicate backorder: ${backorders}`)
  }
  ok("dispatch replay does not double-post or duplicate backorder")

  await psql(`
    do $$
    declare
      admin_id uuid := (select id from auth.users where email = 'admin.${PREFIX}@example.com');
      accounts_id uuid := (select id from auth.users where email = 'accounts.${PREFIX}@example.com');
      godown_id uuid := (select id from auth.users where email = 'godown.${PREFIX}@example.com');
      keeper_id uuid := (select id from auth.users where email = 'keeper.${PREFIX}@example.com');
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
      payload jsonb;
      header jsonb;
      res jsonb;
      note_id uuid;
    begin
      select o.branch_id, o.shop_id into branch_id, shop_id
      from public.orders o
      join public.order_shipments s on s.order_id = o.id
      where s.create_idempotency_key = '${PREFIX}-sh';
      select crates.zone_id, crates.id into zone_id, crate_id
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where zones.branch_id = (
        select o.branch_id
        from public.orders o
        join public.order_shipments s on s.order_id = o.id
        where s.create_idempotency_key = '${PREFIX}-sh'
      )
      limit 1;
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      product_id := public.create_product('${PREFIX}-g-sku', '${PREFIX} race G', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      perform public.post_opening_stock(product_id, crate_id, 4, '${PREFIX}-g-open', null, 'G-LOT', null, null);
      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      payload := public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 2)),
        '${PREFIX}-g-order'
      );
      order_id := (payload -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-g-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-g-ver');
      payload := public.create_delivery_note(order_id, '${PREFIX}-g-dn');
      note_id := (payload -> 'delivery_note' ->> 'id')::uuid;
      payload := public.generate_delivery_note(note_id, 1, '${PREFIX}-g-gen');
      payload := public.send_delivery_note(note_id, 2, '${PREFIX}-g-send');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note(note_id, 3, '${PREFIX}-g-ack');
      header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-g-res');
      header := public.assign_picking_request((header ->> 'id')::uuid, keeper_id, (header ->> 'version')::integer, '${PREFIX}-g-asg');
      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
      header := public.start_picking((header ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-g-start');
      res := header -> 'reservations' -> 0;
      header := public.confirm_picking_quantity((header ->> 'id')::uuid, (res ->> 'id')::uuid, 1, (header ->> 'version')::integer, '${PREFIX}-g-pick');
      header := public.report_picking_shortage((header ->> 'id')::uuid, (res ->> 'id')::uuid, 1, 'missing', (header ->> 'version')::integer, '${PREFIX}-g-short');
      header := public.complete_picking((header ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-g-complete');
    end;
    $$;
  `)

  const createSql = (idem) => `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.create_short_shipment(
  (select id from public.stock_picking_requests where idempotency_key = '${PREFIX}-g-res'),
  (select version from public.stock_picking_requests where idempotency_key = '${PREFIX}-g-res'),
  '${idem}'
);
commit;
`
  const createPair = await Promise.allSettled([
    psql(createSql(`${PREFIX}-g-a`)),
    psql(createSql(`${PREFIX}-g-b`)),
  ])
  const createWins = createPair.filter((row) => row.status === "fulfilled").length
  if (createWins !== 1) {
    throw new Error(
      `expected one shipment create winner, got ${JSON.stringify(
        createPair.map((row) =>
          row.status === "fulfilled" ? row.value : String(row.reason?.message ?? row.reason),
        ),
      )}`,
    )
  }
  const openShipments = await psql(`
    select count(*) from public.order_shipments
    where picking_request_id = (
      select id from public.stock_picking_requests where idempotency_key = '${PREFIX}-g-res'
    )
      and status is distinct from 'cancelled';
  `)
  if (String(openShipments).trim() !== "1") {
    throw new Error(`competing remainder shipments: ${openShipments}`)
  }
  ok("concurrent create_short_shipment: one open document")

  await psql(`
    do $$
    declare
      godown_id uuid := (select id from auth.users where email = 'godown.${PREFIX}@example.com');
      accounts_id uuid := (select id from auth.users where email = 'accounts.${PREFIX}@example.com');
      header jsonb;
      shipment uuid;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      select id into shipment from public.order_shipments
      where create_idempotency_key in ('${PREFIX}-g-a', '${PREFIX}-g-b');
      header := public.confirm_short_shipment_quantities(
        shipment,
        (select version from public.order_shipments where id = shipment),
        '${PREFIX}-g-gm'
      );
      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      perform public.approve_short_shipment(
        shipment,
        (select version from public.order_shipments where id = shipment),
        null,
        '${PREFIX}-g-ap'
      );
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      header := public.get_picking_request(
        (select picking_request_id from public.order_shipments where id = shipment)
      );
      header := public.confirm_picking_handoff(
        (header ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-g-hand'
      );
      perform public.prepare_dispatch(
        (select order_id from public.order_shipments where id = shipment),
        (header ->> 'version')::integer,
        '${PREFIX}-g-prep'
      );
    end;
    $$;
  `)

  const cancelSql = `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.cancel_picking_request(
  (select picking_request_id from public.order_shipments
    where create_idempotency_key in ('${PREFIX}-g-a', '${PREFIX}-g-b')),
  (select version from public.stock_picking_requests
    where id = (select picking_request_id from public.order_shipments
      where create_idempotency_key in ('${PREFIX}-g-a', '${PREFIX}-g-b'))),
  'race cancel',
  '${PREFIX}-g-cancel'
);
commit;
`
  const gDispatchSql = `
begin;
${asUser(`godown.${PREFIX}@example.com`)}
select public.confirm_dispatch(
  (select id from public.stock_dispatch_requests
    where picking_request_id = (
      select id from public.stock_picking_requests where idempotency_key = '${PREFIX}-g-res'
    )
      and status is distinct from 'cancelled'
    order by created_at desc limit 1),
  (select version from public.stock_dispatch_requests
    where picking_request_id = (
      select id from public.stock_picking_requests where idempotency_key = '${PREFIX}-g-res'
    )
      and status is distinct from 'cancelled'
    order by created_at desc limit 1),
  '${PREFIX}-g-cfm'
);
commit;
`
  const releaseRace = await Promise.allSettled([psql(gDispatchSql), psql(cancelSql)])
  const dispatchOk = releaseRace[0].status === "fulfilled"
  const cancelOk = releaseRace[1].status === "fulfilled"
  if (dispatchOk && cancelOk) {
    throw new Error("dispatch and cancel must not both succeed")
  }
  if (!dispatchOk && !cancelOk) {
    throw new Error(`release race both failed: ${JSON.stringify(releaseRace)}`)
  }
  const gLedger = await psql(`
    select coalesce(sum(sl.quantity), 0)
    from public.stock_ledger sl
    join public.stock_transactions st on st.id = sl.transaction_id
    join public.stock_dispatch_requests d on d.id = st.dispatch_request_id
    where d.picking_request_id = (
      select id from public.stock_picking_requests where idempotency_key = '${PREFIX}-g-res'
    );
  `)
  const gLedgerN = Number(String(gLedger).trim())
  if (dispatchOk && gLedgerN !== -1) {
    throw new Error(`dispatch winner must debit 1, ledger=${gLedger}`)
  }
  if (!dispatchOk && gLedgerN !== 0) {
    throw new Error(`cancel winner must not debit, ledger=${gLedger}`)
  }
  ok("reservation release racing with dispatch: one winner")
} finally {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    select set_config('app.shipment_write', 'on', true);
    delete from public.order_shipment_events
    where shipment_id in (
      select id from public.order_shipments where create_idempotency_key like '${PREFIX}%'
    );
    delete from public.order_shipment_lots
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    delete from public.order_shipment_lines
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    delete from public.order_shipments where create_idempotency_key like '${PREFIX}%';
    delete from public.stock_picking_exceptions
    where reservation_id in (
      select id from public.stock_reservations
      where product_id in (select id from public.products where sku like '${PREFIX}%')
    );
    delete from public.stock_reservations
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    update public.stock_picking_requests
    set status = 'cancelled', cancelled_by = created_by, cancelled_at = clock_timestamp(),
        cancellation_reason = 'm73bc cleanup'
    where order_id in (select id from public.orders where idempotency_key like '${PREFIX}%')
      and status is distinct from 'cancelled';
    delete from public.stock_ledger
    where product_id in (select id from public.products where sku like '${PREFIX}%')
      and lot_id is not null;
    update public.app_configuration set value = 'false'::jsonb
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    );
    set session_replication_role = origin;
  `)
}

console.log(`M7.3B concurrency ${passed.length}/${passed.length} passed`)
