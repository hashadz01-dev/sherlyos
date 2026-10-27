/**
 * M4.1 two-session proof: deactivating a godown cannot race past reserve.
 * Local Docker only. Restores cutover flags in cleanup.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m41c_${RUN}`

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
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
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
        ('admin.m41c@example.com'),
        ('accounts.m41c@example.com'),
        ('godown.m41c@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m41c@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m41c@example.com';
      select id into godown_id from auth.users where email = 'godown.m41c@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M41C Admin', true),
        (accounts_id, 'M41C Accounts', true),
        (godown_id, 'M41C Godown', true)
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
      select u.id, roles.id, admin_id
      from (values (accounts_id, 'accounts'), (godown_id, 'godown_manager')) u(id, role_code)
      join public.roles on roles.code = u.role_code
      on conflict do nothing;

      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', admin_id::text, true);

      branch_id := public.create_branch('${PREFIX}', 'M41C A');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}', 'M41C Soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('M41C shop', null, null);

      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;

      perform public.post_opening_stock(
        product_id, crate_id, 5, '${PREFIX}-open', null, 'M41C', null, '2028-06-01'
      );

      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 1)),
        '${PREFIX}-order'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-ver');
      payload := public.create_delivery_note(order_id, '${PREFIX}-dn');
      perform public.generate_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen');
      perform public.send_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-send');
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform public.acknowledge_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack');

      raise notice 'IDS % % % %', admin_id, branch_id, product_id, order_id;
    end $$;
    select
      (select id::text from auth.users where email = 'admin.m41c@example.com')
      || ' ' || (select id::text from public.branches where code = '${PREFIX}')
      || ' ' || (select id::text from public.products where sku = '${PREFIX}')
      || ' ' || (select id::text from public.orders where idempotency_key = '${PREFIX}-order')
      || ' ' || (select version::text from public.orders where idempotency_key = '${PREFIX}-order');
  `)
  const parts = lastLine(text).trim().split(/\s+/)
  ids.admin = parts[0]
  ids.branch = parts[1]
  ids.product = parts[2]
  ids.order = parts[3]
  ids.version = parts[4]
}

function deactivateSql() {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.m41c@example.com'), true);
set local role authenticated;
select public.set_branch_active('${ids.branch}'::uuid, false);
commit;
`
}

function reserveSql() {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.m41c@example.com'), true);
set local role authenticated;
select public.reserve_order_allocation('${ids.order}'::uuid, ${ids.version}::integer, '${PREFIX}-res');
commit;
`
}

async function cleanup() {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    update public.stock_reservations set status = 'released'
    where order_id = '${ids.order}'::uuid;
    update public.stock_picking_requests
    set status = 'cancelled', cancelled_by = created_by, cancelled_at = clock_timestamp(),
        cancellation_reason = 'm41c cleanup'
    where order_id = '${ids.order}'::uuid
      and status is distinct from 'cancelled';
    update public.stock_ledger set lot_id = null where product_id = '${ids.product}'::uuid;
    delete from public.stock_balances where product_id = '${ids.product}'::uuid;
    delete from public.stock_lot_balances
    where lot_id in (select id from public.stock_lots where product_id = '${ids.product}'::uuid);
    delete from public.stock_lots where product_id = '${ids.product}'::uuid;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)
}

await setup()

try {
  const racing = await Promise.allSettled([psql(deactivateSql()), psql(reserveSql())])
  const reserve = racing[1]
  const pickingCount = Number(
    lastLine(
      await psql(`
        select count(*) from public.stock_picking_requests
        where order_id = '${ids.order}'::uuid and status is distinct from 'cancelled';
      `),
    ),
  )
  const active = lastLine(
    await psql(`select is_active::text from public.branches where id = '${ids.branch}'::uuid`),
  )

  if (active !== "f" && active !== "false") {
    throw new Error(`expected branch inactive after race, got ${active}`)
  }

  if (reserve.status === "fulfilled") {
    if (pickingCount !== 1) {
      throw new Error("reserve won the race but picking was not persisted")
    }
    console.log("M4.1 race: reserve committed first; godown then inactive. In-flight allocation kept.")
  } else {
    if (pickingCount !== 0) {
      throw new Error("reserve lost the race but a picking request was still created")
    }
    if (!/inactive|not authorized/i.test(reserve.reason?.message || String(reserve.reason))) {
      throw new Error(`reserve failed for the wrong reason: ${reserve.reason}`)
    }
    console.log("M4.1 race: deactivate committed first; reserve denied on inactive godown.")
  }

  if (racing[0].status !== "fulfilled") {
    throw new Error(`deactivation failed: ${racing[0].reason}`)
  }
  console.log("M4.1 concurrent deactivation and reserve: no bypass")
} finally {
  await cleanup()
}
