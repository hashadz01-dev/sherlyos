/**
 * M7.3 concurrency: two allocations of the same stock, reserve after ack,
 * voided DN, reservation replay. Local Docker only. Flags restored in finally.
 */
import { spawn } from "node:child_process"

const PREFIX = `m73c_${Date.now().toString(36)}`
const PASSWORD = "local-only-m73c"

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

await psql(`
  do $$
  declare
    admin_id uuid := gen_random_uuid();
    accounts_id uuid := gen_random_uuid();
    godown_id uuid := gen_random_uuid();
    godown2_id uuid := gen_random_uuid();
    branch_id uuid;
    zone_id uuid;
    crate_id uuid;
    product_id uuid;
    shop_id uuid;
    order_a uuid;
    order_b uuid;
    order_void uuid;
    note_a uuid;
    note_b uuid;
    note_void uuid;
    payload jsonb;
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
      ('00000000-0000-0000-0000-000000000000', godown2_id, 'authenticated', 'authenticated',
        'godown2.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')),
        now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

    begin
      perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
    exception
      when sqlstate '42501' then
        insert into public.profiles (id, full_name, is_active)
        values (admin_id, 'M73C Admin', true)
        on conflict (id) do update set is_active = true;
        insert into public.user_roles (user_id, role_id, assigned_by)
        select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
        on conflict do nothing;
    end;

    insert into public.profiles (id, full_name, is_active)
    values
      (accounts_id, 'M73C Accounts', true),
      (godown_id, 'M73C Godown', true),
      (godown2_id, 'M73C Godown2', true)
    on conflict (id) do update set is_active = true;

    insert into public.user_roles (user_id, role_id, assigned_by)
    select u.id, r.id, admin_id
    from (values
      (accounts_id, 'accounts'),
      (godown_id, 'godown_manager'),
      (godown2_id, 'godown_manager')
    ) u(id, code)
    join public.roles r on r.code = u.code
    on conflict do nothing;

    perform set_config('request.jwt.claim.sub', admin_id::text, true);
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
      true
    );
    execute 'set local role authenticated';

    branch_id := public.create_branch('${PREFIX}', 'M73C');
    perform public.assign_user_branch(accounts_id, branch_id);
    perform public.assign_user_branch(godown_id, branch_id);
    perform public.assign_user_branch(godown2_id, branch_id);
    zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
    crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
    product_id := public.create_product('${PREFIX}-sku', 'M73C soap', null, null);
    perform public.set_product_expiry_policy(product_id, 'non_expiring');
    shop_id := public.create_shop('M73C shop', null, null);

    execute 'reset role';
    set session_replication_role = replica;
    update public.app_configuration set value = 'true'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;

    perform set_config('request.jwt.claim.sub', admin_id::text, true);
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
      true
    );
    execute 'set local role authenticated';
    perform public.post_opening_stock(
      product_id, crate_id, 3, '${PREFIX}-open', null, 'M73C-LOT', null, null
    );

    perform set_config('request.jwt.claim.sub', accounts_id::text, true);
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
      true
    );

    order_a := (public.create_order(
      shop_id, branch_id, 'accounts', null, null,
      jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 3)),
      '${PREFIX}-oa'
    ) -> 'order' ->> 'id')::uuid;
    perform public.submit_order(order_a, 1, '${PREFIX}-sub-a');
    perform public.verify_order(order_a, 2, '${PREFIX}-ver-a');

    order_b := (public.create_order(
      shop_id, branch_id, 'accounts', null, null,
      jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 3)),
      '${PREFIX}-ob'
    ) -> 'order' ->> 'id')::uuid;
    perform public.submit_order(order_b, 1, '${PREFIX}-sub-b');
    perform public.verify_order(order_b, 2, '${PREFIX}-ver-b');

    order_void := (public.create_order(
      shop_id, branch_id, 'accounts', null, null,
      jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 1)),
      '${PREFIX}-ov'
    ) -> 'order' ->> 'id')::uuid;
    perform public.submit_order(order_void, 1, '${PREFIX}-sub-v');
    perform public.verify_order(order_void, 2, '${PREFIX}-ver-v');

    payload := public.create_delivery_note(order_a, '${PREFIX}-dna');
    note_a := (payload -> 'delivery_note' ->> 'id')::uuid;
    perform public.generate_delivery_note(note_a, 1, '${PREFIX}-gena');
    perform public.send_delivery_note(note_a, 2, '${PREFIX}-snda');

    payload := public.create_delivery_note(order_b, '${PREFIX}-dnb');
    note_b := (payload -> 'delivery_note' ->> 'id')::uuid;
    perform public.generate_delivery_note(note_b, 1, '${PREFIX}-genb');
    perform public.send_delivery_note(note_b, 2, '${PREFIX}-sndb');

    payload := public.create_delivery_note(order_void, '${PREFIX}-dnv');
    note_void := (payload -> 'delivery_note' ->> 'id')::uuid;
    perform public.generate_delivery_note(note_void, 1, '${PREFIX}-genv');
    perform public.send_delivery_note(note_void, 2, '${PREFIX}-sndv');
    perform public.void_delivery_note(note_void, 3, 'stale copy', '${PREFIX}-void');
  end $$;
`)

function ackSql(email, orderKey, idem) {
  return `
begin;
set local lock_timeout = '8s';
select set_config(
  'sherlyos.note',
  (
    select delivery_notes.id::text from public.delivery_notes
    join public.orders on orders.id = delivery_notes.order_id
    where orders.idempotency_key = '${orderKey}'
      and delivery_notes.status is distinct from 'voided'
    order by delivery_notes.created_at desc
    limit 1
  ),
  true
);
select set_config('request.jwt.claim.sub',
  (select id::text from auth.users where email = '${email}'), true);
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = '${email}'), true);
set local role authenticated;
select public.acknowledge_delivery_note(
  current_setting('sherlyos.note')::uuid,
  3,
  '${idem}'
);
commit;
`
}

function reserveSql(email, orderKey, idem) {
  return `
begin;
set local lock_timeout = '8s';
select set_config(
  'sherlyos.order',
  (select id::text from public.orders where idempotency_key = '${orderKey}'),
  true
);
select set_config('request.jwt.claim.sub',
  (select id::text from auth.users where email = '${email}'), true);
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = '${email}'), true);
set local role authenticated;
select public.reserve_order_allocation(
  current_setting('sherlyos.order')::uuid,
  3,
  '${idem}'
);
commit;
`
}

try {
  const voided = await psql(reserveSql(`godown.${PREFIX}@example.com`, `${PREFIX}-ov`, `${PREFIX}-resv`)).then(
    () => "allocated",
    (error) => (error instanceof Error ? error.message : String(error)),
  )
  if (!/acknowledge the delivery note/i.test(voided)) {
    throw new Error(`voided DN allocate unexpected: ${voided}`)
  }
  ok("allocation against voided DN refused")

  await psql(ackSql(`godown.${PREFIX}@example.com`, `${PREFIX}-oa`, `${PREFIX}-acka`))
  await psql(ackSql(`godown.${PREFIX}@example.com`, `${PREFIX}-ob`, `${PREFIX}-ackb`))
  ok("allocation after DN acknowledgement permitted to start")

  const sameOrder = await Promise.allSettled([
    psql(reserveSql(`godown.${PREFIX}@example.com`, `${PREFIX}-oa`, `${PREFIX}-resa`)),
    psql(reserveSql(`godown2.${PREFIX}@example.com`, `${PREFIX}-oa`, `${PREFIX}-resa2`)),
  ])
  const sameWins = sameOrder.filter((row) => row.status === "fulfilled").length
  if (sameWins !== 1) {
    throw new Error(`expected one concurrent same-order reserve winner, got ${JSON.stringify(sameOrder)}`)
  }
  ok("concurrent reservation of one order: one winner")

  const replayPair = await Promise.allSettled([
    psql(reserveSql(`godown.${PREFIX}@example.com`, `${PREFIX}-oa`, `${PREFIX}-resa`)),
    psql(reserveSql(`godown2.${PREFIX}@example.com`, `${PREFIX}-oa`, `${PREFIX}-resa2`)),
  ])
  if (!replayPair.some((row) => row.status === "fulfilled")) {
    throw new Error(`reservation replay failed: ${JSON.stringify(replayPair)}`)
  }
  ok("reservation replay")

  const pair = await Promise.allSettled([
    psql(reserveSql(`godown.${PREFIX}@example.com`, `${PREFIX}-ob`, `${PREFIX}-resb`)),
    psql(reserveSql(`godown2.${PREFIX}@example.com`, `${PREFIX}-ob`, `${PREFIX}-resb2`)),
  ])
  const stockWins = pair.filter((row) => row.status === "fulfilled").length
  if (stockWins !== 0) {
    throw new Error(`order B must not allocate after A took the stock, got ${JSON.stringify(pair)}`)
  }
  ok("second order cannot allocate the same reserved stock")
} finally {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    delete from public.stock_picking_exceptions
    where reservation_id in (
      select id from public.stock_reservations
      where product_id in (select id from public.products where sku = '${PREFIX}-sku')
    );
    delete from public.stock_reservations
    where product_id in (select id from public.products where sku = '${PREFIX}-sku');
    update public.stock_picking_requests
    set status = 'cancelled', cancelled_by = created_by, cancelled_at = clock_timestamp(),
        cancellation_reason = 'm73c cleanup'
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

console.log(`M7.3 concurrency ${passed.length}/${passed.length} passed`)
