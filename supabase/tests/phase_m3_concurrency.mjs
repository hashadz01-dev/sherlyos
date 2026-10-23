/**
 * M3 two-session proofs against local Docker only.
 * Two confirm_dispatch calls cannot double-debit one picking request.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m3c_${RUN}`

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

function firstUuid(text) {
  return String(text).match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0] ?? ""
}

const ids = {}

async function setup() {
  const text = await psql(`
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      godown_id uuid;
      keeper_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
      request_id uuid;
      header jsonb;
      res jsonb;
      i int;
      dispatch_id uuid;
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
        ('admin.m3c@example.com'),
        ('accounts.m3c@example.com'),
        ('godown.m3c@example.com'),
        ('keeper.m3c@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m3c@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m3c@example.com';
      select id into godown_id from auth.users where email = 'godown.m3c@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m3c@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M3C Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values (accounts_id, 'accounts', true), (godown_id, 'godown', true), (keeper_id, 'keeper', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts_id, roles.id, admin_id from public.roles where roles.code = 'accounts'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select keeper_id, roles.id, admin_id from public.roles where roles.code = 'store_keeper'
      on conflict do nothing;

      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      branch_id := public.create_branch('${PREFIX}_b', 'M3C');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, 'z', 'Z', null);
      crate_id := public.create_crate(zone_id, 'c', 'C', null);
      perform public.create_crate(zone_id, 'c2', 'C2', null);
      product_id := public.create_product('${PREFIX}', 'M3C product', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('${PREFIX} shop', null, null);

      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');

      perform public.post_opening_stock(
        product_id, crate_id, 6, '${PREFIX}-open', null, 'M3C', null, '2028-01-01'
      );

      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 4)),
        '${PREFIX}-order'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-ver');

      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-res');
      request_id := (header ->> 'id')::uuid;
      header := public.assign_picking_request(request_id, keeper_id, 1, '${PREFIX}-asg');
      header := public.start_picking(request_id, 2, '${PREFIX}-start');
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
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, '${PREFIX}-ho');
      header := public.prepare_dispatch(order_id, (header ->> 'version')::integer, '${PREFIX}-prep');
      dispatch_id := (header ->> 'id')::uuid;

    end $$;
  `)
  void text
  const row = lastLine(
    await psql(`
      select
        d.id::text || ' ' || d.version::text || ' ' || d.picking_request_id::text
        || ' ' || d.order_id::text || ' ' || d.branch_id::text
        || ' ' || p.id::text || ' ' || r.crate_id::text
        || ' ' || r.lot_id::text
        || ' ' || (
          select c2.id::text
          from public.crates c2
          where c2.zone_id = (select src.zone_id from public.crates src where src.id = r.crate_id)
            and c2.code = 'c2'
          limit 1
        )
        || ' ' || pk.version::text
      from public.stock_dispatch_requests d
      join public.stock_picking_requests pk on pk.id = d.picking_request_id
      join public.stock_reservations r on r.picking_request_id = d.picking_request_id
      join public.products p on p.id = r.product_id
      where d.idempotency_key = '${PREFIX}-prep'
      limit 1;
    `),
  )
  const parts = row.split(" ")
  if (parts.length < 10) throw new Error(`setup ids missing: ${row}`)
  ids.dispatch = parts[0]
  ids.version = Number(parts[1])
  ids.request = parts[2]
  ids.order = parts[3]
  ids.product = parts[5]
  ids.crate = parts[6]
  ids.lot = parts[7]
  ids.crate2 = parts[8]
  ids.pickingVersion = Number(parts[9])
}

function confirmSql(key) {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'godown.m3c@example.com'), true);
set local role authenticated;
select public.confirm_dispatch('${ids.dispatch}'::uuid, ${ids.version}::integer, '${key}');
commit;
`
}

function transferSql(qty, key) {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.m3c@example.com'), true);
set local role authenticated;
select public.post_crate_transfer(
  '${ids.product}'::uuid,
  '${ids.crate}'::uuid,
  '${ids.crate2}'::uuid,
  ${qty},
  '${key}',
  null,
  jsonb_build_array(jsonb_build_object('lot_id', '${ids.lot}'::uuid, 'quantity', ${qty}))
);
commit;
`
}

function exclusiveSql() {
  return `
\\set ON_ERROR_STOP on
begin;
select app_private.lot_seed_lock_exclusive();
select pg_sleep(1);
rollback;
`
}

function cancelOrderSql() {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'accounts.m3c@example.com'), true);
set local role authenticated;
select public.cancel_order('${ids.order}'::uuid, 3, 'race cancel', '${PREFIX}-ord-can');
commit;
`
}

function cancelPickingSql() {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'godown.m3c@example.com'), true);
set local role authenticated;
select public.cancel_picking_request('${ids.request}'::uuid, ${ids.pickingVersion}::integer, 'race pick cancel', '${PREFIX}-pick-can');
commit;
`
}

await setup()

const competing = await Promise.allSettled([
  psql(confirmSql(`${PREFIX}-cfm-a`)),
  psql(confirmSql(`${PREFIX}-cfm-b`)),
  psql(transferSql(5, `${PREFIX}-xfer-race`)),
])

const fulfilled = competing.filter((row) => row.status === "fulfilled")
const rejected = competing.filter((row) => row.status === "rejected")
if (fulfilled.length !== 1 && !(fulfilled.length === 2)) {
  throw new Error(`expected one winner or idempotent pair, got ${JSON.stringify(competing, null, 2)}`)
}

const ledger = lastLine(
  await psql(`
    select count(*)::text
    from public.stock_transactions
    where dispatch_request_id = '${ids.dispatch}'::uuid
      and transaction_type = 'DISPATCH';
  `),
)
if (ledger !== "1") {
  throw new Error(`expected exactly one DISPATCH transaction, got ${ledger}`)
}

const qty = lastLine(
  await psql(`
    select quantity::text
    from public.stock_balances
    where crate_id = '${ids.crate}'::uuid
      and product_id = '${ids.product}'::uuid;
  `),
)
if (qty !== "2") {
  throw new Error(`expected remaining 2 cartons after 4 dispatched from 6, got ${qty}`)
}

const replay = await psql(confirmSql(`${PREFIX}-cfm-a`))
if (!firstUuid(replay)) {
  throw new Error("retry after success must replay")
}

console.log("PASS concurrent confirm_dispatch posts stock once")
if (rejected.length === 1) {
  console.log("PASS second confirm serialized or rejected without a second debit")
} else {
  console.log("PASS second confirm replayed the committed dispatch")
}

if (qty !== "2") {
  throw new Error(`transfer race must not oversubscribe reserved stock, remaining ${qty}`)
}
console.log("PASS dispatch versus transfer; reserved grain not oversubscribed")

const vsCancel = await Promise.allSettled([
  psql(confirmSql(`${PREFIX}-cfm-a`)),
  psql(cancelOrderSql()),
])
const orderStatus = lastLine(
  await psql(`select status from public.orders where id = '${ids.order}'::uuid`),
)
if (orderStatus === "cancelled") {
  throw new Error("order cancel must not win against a consumed or ready-for-dispatch dispatch")
}
if (
  lastLine(
    await psql(`
      select count(*)::text from public.stock_transactions
      where dispatch_request_id = '${ids.dispatch}'::uuid and transaction_type = 'DISPATCH'
    `),
  ) !== "1"
) {
  throw new Error("order cancel race posted a second DISPATCH or rolled consumption back")
}
console.log("PASS dispatch versus order cancel; order stays verified, stock posted once")
void vsCancel

const vsPickCancel = await Promise.allSettled([
  psql(confirmSql(`${PREFIX}-cfm-a`)),
  psql(cancelPickingSql()),
])
if (
  lastLine(
    await psql(`
      select count(*)::text from public.stock_transactions
      where dispatch_request_id = '${ids.dispatch}'::uuid and transaction_type = 'DISPATCH'
    `),
  ) !== "1"
) {
  throw new Error(`picking cancel race posted extra DISPATCH: ${JSON.stringify(vsPickCancel)}`)
}
const pickStatus = lastLine(
  await psql(`select status from public.stock_picking_requests where id = '${ids.request}'::uuid`),
)
if (pickStatus === "cancelled") {
  throw new Error("ready-for-dispatch picking must not cancel against a consumed dispatch")
}
console.log("PASS dispatch versus picking cancel; handoff stays ready_for_dispatch, stock posted once")

const vsExclusive = await Promise.allSettled([
  psql(exclusiveSql()),
  psql(confirmSql(`${PREFIX}-cfm-a`)),
])
if (
  lastLine(
    await psql(`
      select count(*)::text from public.stock_transactions
      where dispatch_request_id = '${ids.dispatch}'::uuid and transaction_type = 'DISPATCH'
    `),
  ) !== "1"
) {
  throw new Error(`cutover exclusive race posted extra DISPATCH: ${JSON.stringify(vsExclusive)}`)
}
console.log("PASS dispatch versus cutover exclusive lock; still one DISPATCH")

async function cleanup() {
  await psql(`
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    select set_config('app.dispatch_write', 'on', true);
    update public.stock_reservations
    set status = 'released'
    where order_id in (select id from public.orders where idempotency_key = '${PREFIX}-order')
      and status = 'active';
    update public.stock_ledger
    set lot_id = null
    where product_id = '${ids.product}'::uuid;
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

await cleanup()
console.log("concurrency cleanup restored flags")
