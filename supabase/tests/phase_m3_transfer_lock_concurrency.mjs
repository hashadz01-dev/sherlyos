/**
 * M3 transfer lock-order regression.
 *
 * Dual-write post_crate_transfer used to lock stock_balances before lots.
 * Racing confirm_dispatch (lots → lot_balances → stock_balances) could
 * deadlock; aborting the transfer still looked like a reservation reject.
 * This race moves the unreserved remainder so both writers must commit
 * without 40P01. Local Docker only.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m3t_${RUN}`

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
  await psql(`
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
        ('admin.m3t@example.com'),
        ('accounts.m3t@example.com'),
        ('godown.m3t@example.com'),
        ('keeper.m3t@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m3t@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m3t@example.com';
      select id into godown_id from auth.users where email = 'godown.m3t@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m3t@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M3T Admin', true)
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
      branch_id := public.create_branch('${PREFIX}_b', 'M3T');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, 'z', 'Z', null);
      crate_id := public.create_crate(zone_id, 'c', 'C', null);
      perform public.create_crate(zone_id, 'c2', 'C2', null);
      product_id := public.create_product('${PREFIX}', 'M3T product', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('${PREFIX} shop', null, null);

      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;

      -- 6 on source: 4 reserved for dispatch, 2 unreserved for a concurrent transfer.
      perform public.post_opening_stock(
        product_id, crate_id, 6, '${PREFIX}-open', null, 'M3T', null, '2028-01-01'
      );

      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 4)),
        '${PREFIX}-order'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-ver');
      header := public.create_delivery_note(order_id, '${PREFIX}-dn');
      perform public.generate_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen');
      perform public.send_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-send');
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack');

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
    end $$;
  `)

  const row = lastLine(
    await psql(`
      select
        d.id::text || ' ' || d.version::text || ' ' || p.id::text || ' ' || r.crate_id::text
        || ' ' || r.lot_id::text || ' ' || (
          select c2.id::text
          from public.crates c2
          where c2.zone_id = (select src.zone_id from public.crates src where src.id = r.crate_id)
            and c2.code = 'c2'
          limit 1
        )
      from public.stock_dispatch_requests d
      join public.stock_reservations r on r.picking_request_id = d.picking_request_id
      join public.products p on p.id = r.product_id
      where d.idempotency_key = '${PREFIX}-prep'
      limit 1;
    `),
  )
  const parts = row.split(" ")
  if (parts.length < 6) throw new Error(`setup ids missing: ${row}`)
  ids.dispatch = parts[0]
  ids.version = Number(parts[1])
  ids.product = parts[2]
  ids.crate = parts[3]
  ids.lot = parts[4]
  ids.crate2 = parts[5]
}

function confirmSql() {
  return `
\\set ON_ERROR_STOP on
begin;
set local lock_timeout = '8s';
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'godown.m3t@example.com'), true);
set local role authenticated;
select public.confirm_dispatch('${ids.dispatch}'::uuid, ${ids.version}::integer, '${PREFIX}-cfm');
commit;
`
}

function transferSql() {
  return `
\\set ON_ERROR_STOP on
begin;
set local lock_timeout = '8s';
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.m3t@example.com'), true);
set local role authenticated;
select public.post_crate_transfer(
  '${ids.product}'::uuid,
  '${ids.crate}'::uuid,
  '${ids.crate2}'::uuid,
  2,
  '${PREFIX}-xfer',
  null,
  jsonb_build_array(jsonb_build_object('lot_id', '${ids.lot}'::uuid, 'quantity', 2))
);
commit;
`
}

function describeOutcome(row) {
  if (row.status === "fulfilled") return "ok"
  return String(row.reason?.message ?? row.reason ?? "rejected")
}

await setup()

const competing = await Promise.allSettled([psql(confirmSql()), psql(transferSql())])
const messages = competing.map(describeOutcome)
if (messages.some((text) => /40P01|deadlock detected/i.test(text))) {
  throw new Error(`reachable lock-order deadlock: ${JSON.stringify(messages)}`)
}
if (competing.some((row) => row.status !== "fulfilled")) {
  throw new Error(`unreserved remainder race must commit both writers: ${JSON.stringify(messages)}`)
}

const sourceQty = lastLine(
  await psql(`
    select coalesce((
      select quantity::text from public.stock_balances
      where crate_id = '${ids.crate}'::uuid and product_id = '${ids.product}'::uuid
    ), '0');
  `),
)
const destQty = lastLine(
  await psql(`
    select coalesce((
      select quantity::text from public.stock_balances
      where crate_id = '${ids.crate2}'::uuid and product_id = '${ids.product}'::uuid
    ), '0');
  `),
)
const dispatchCount = lastLine(
  await psql(`
    select count(*)::text from public.stock_transactions
    where dispatch_request_id = '${ids.dispatch}'::uuid and transaction_type = 'DISPATCH';
  `),
)
const transferCount = lastLine(
  await psql(`
    select count(*)::text from public.stock_transactions
    where idempotency_key = '${PREFIX}-xfer' and transaction_type = 'CRATE_TRANSFER';
  `),
)
const negatives = lastLine(
  await psql(`
    select count(*)::text from public.stock_balances
    where product_id = '${ids.product}'::uuid and quantity < 0;
  `),
)

if (dispatchCount !== "1") throw new Error(`expected one DISPATCH, got ${dispatchCount}`)
if (transferCount !== "1") throw new Error(`expected one CRATE_TRANSFER, got ${transferCount}`)
if (sourceQty !== "0") throw new Error(`source remaining must be 0 after dispatch 4 + transfer 2, got ${sourceQty}`)
if (destQty !== "2") throw new Error(`destination must hold the transferred 2, got ${destQty}`)
if (negatives !== "0") throw new Error(`negative balances after lock-order race: ${negatives}`)

console.log("PASS confirm_dispatch versus unreserved post_crate_transfer; no deadlock, conserved 4+2")

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
console.log("concurrency cleanup restored flags")
