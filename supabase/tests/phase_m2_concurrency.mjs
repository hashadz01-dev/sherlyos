/**
 * M2 two-session proofs against local Docker only.
 * Two verified orders cannot oversubscribe the same crate/lot, and a
 * transfer cannot consume a racing reservation.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m2c_${RUN}`

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

function lastLine(text) {
  return String(text).split(/\r?\n/).filter(Boolean).at(-1)
}

const ids = {}

async function setup() {
  const text = await psql(`
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      godown_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_src uuid;
      crate_dst uuid;
      product_id uuid;
      shop_id uuid;
      order_a uuid;
      order_b uuid;
      payload jsonb;
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
        ('admin.m2c@example.com'),
        ('accounts.m2c@example.com'),
        ('godown.m2c@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m2c@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m2c@example.com';
      select id into godown_id from auth.users where email = 'godown.m2c@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M2C Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values (accounts_id, 'M2C Accounts', true), (godown_id, 'M2C Godown', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts_id, roles.id, admin_id from public.roles where roles.code = 'accounts'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;

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

      branch_id := public.create_branch('${PREFIX}', 'M2C ${RUN}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_src := public.create_crate(zone_id, '${PREFIX}_src', 'SRC', null);
      crate_dst := public.create_crate(zone_id, '${PREFIX}_dst', 'DST', null);
      product_id := public.create_product('${PREFIX}', 'M2C soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('M2C shop ${RUN}', null, null);

      perform public.post_opening_stock(
        product_id, crate_src, 5, '${PREFIX}-open', null, 'M2C-LOT', null, '2028-03-01'
      );

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
        true
      );

      order_a := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 5)),
        '${PREFIX}-order-a'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_a, 1, '${PREFIX}-sub-a');
      perform public.verify_order(order_a, 2, '${PREFIX}-ver-a');

      order_b := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 5)),
        '${PREFIX}-order-b'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_b, 1, '${PREFIX}-sub-b');
      perform public.verify_order(order_b, 2, '${PREFIX}-ver-b');

      payload := public.create_delivery_note(order_a, '${PREFIX}-dna');
      perform public.generate_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gena');
      perform public.send_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-snda');
      payload := public.create_delivery_note(order_b, '${PREFIX}-dnb');
      perform public.generate_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-genb');
      perform public.send_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-sndb');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
        true
      );
      perform public.acknowledge_delivery_note(
        (select id from public.delivery_notes where idempotency_key = '${PREFIX}-dna'), 3, '${PREFIX}-acka'
      );
      perform public.acknowledge_delivery_note(
        (select id from public.delivery_notes where idempotency_key = '${PREFIX}-dnb'), 3, '${PREFIX}-ackb'
      );
    end;
    $$;

    select
      (select id::text from public.orders where idempotency_key = '${PREFIX}-order-a') || ' ' ||
      (select id::text from public.orders where idempotency_key = '${PREFIX}-order-b') || ' ' ||
      (select version::text from public.orders where idempotency_key = '${PREFIX}-order-a') || ' ' ||
      (select crates.id::text from public.crates where crates.code = '${PREFIX}_src') || ' ' ||
      (select crates.id::text from public.crates where crates.code = '${PREFIX}_dst') || ' ' ||
      (select products.id::text from public.products where products.sku = '${PREFIX}') || ' ' ||
      (select stock_lots.id::text from public.stock_lots
        where stock_lots.manufacturer_lot_code = 'M2C-LOT'
          and stock_lots.product_id = (select id from public.products where sku = '${PREFIX}')
        limit 1);
  `)
  const parts = lastLine(text).split(/\s+/)
  ids.orderA = parts[0]
  ids.orderB = parts[1]
  ids.version = parts[2]
  ids.crateSrc = parts[3]
  ids.crateDst = parts[4]
  ids.product = parts[5]
  ids.lot = parts[6]
  if (!ids.orderA || !ids.orderB || !ids.product || !ids.lot) {
    throw new Error(`concurrency fixture parse failed: ${text}`)
  }
}

function reserveSql(orderId, key) {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'godown.m2c@example.com'), true);
set local role authenticated;
select public.reserve_order_allocation('${orderId}'::uuid, ${ids.version}::integer, '${key}');
commit;
`
}

function transferSql() {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.m2c@example.com'), true);
set local role authenticated;
select public.post_crate_transfer(
  '${ids.product}'::uuid,
  '${ids.crateSrc}'::uuid,
  '${ids.crateDst}'::uuid,
  5,
  '${PREFIX}-xfer-' || pg_backend_pid()::text,
  null,
  jsonb_build_array(jsonb_build_object('lot_id', '${ids.lot}'::uuid, 'quantity', 5))
);
commit;
`
}

async function cleanup() {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    update public.stock_reservations
    set status = 'released'
    where order_id in (
      select id from public.orders
      where idempotency_key in ('${PREFIX}-order-a', '${PREFIX}-order-b')
    );
    update public.stock_picking_requests
    set status = 'cancelled',
        cancelled_by = created_by,
        cancelled_at = coalesce(cancelled_at, clock_timestamp()),
        cancellation_reason = coalesce(cancellation_reason, 'm2c cleanup')
    where order_id in (
      select id from public.orders
      where idempotency_key in ('${PREFIX}-order-a', '${PREFIX}-order-b')
    )
      and status is distinct from 'cancelled';
    update public.stock_ledger
    set lot_id = null
    where product_id in (select id from public.products where sku = '${PREFIX}');
    delete from public.stock_balances
    where product_id in (select id from public.products where sku = '${PREFIX}');
    delete from public.stock_lot_balances
    where lot_id in (
      select id from public.stock_lots
      where product_id in (select id from public.products where sku = '${PREFIX}')
    );
    delete from public.stock_lots
    where product_id in (select id from public.products where sku = '${PREFIX}');
    update public.app_configuration
    set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)
}

await setup()

try {
  const competing = await Promise.allSettled([
    psql(reserveSql(ids.orderA, `${PREFIX}-res-a`)),
    psql(reserveSql(ids.orderB, `${PREFIX}-res-b`)),
  ])
  const wins = competing.filter((row) => row.status === "fulfilled").length
  const losses = competing.filter((row) => row.status === "rejected").length
  if (wins !== 1 || losses !== 1) {
    throw new Error(`expected one reserve win and one loss, got wins=${wins} losses=${losses}`)
  }
  console.log("M2 competing reserve: one winner")

  const versusTransfer = await Promise.allSettled([
    psql(reserveSql(wins === 1 && competing[0].status === "fulfilled" ? ids.orderB : ids.orderA, `${PREFIX}-res-xfer`)),
    psql(transferSql()),
  ])
  const transferWins = versusTransfer.filter((row) => row.status === "fulfilled").length
  if (transferWins > 0) {
    throw new Error("transfer or second reserve must not consume the held grain")
  }
  console.log("M2 reserve versus transfer: held stock conserved")
} finally {
  await cleanup()
}
