/**
 * M3 dedicated confirm_dispatch versus post_stock_adjustment races.
 * Independent Docker sessions. Local disposable fixtures only.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m3adj_${RUN}`

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

function claims(email) {
  return `(select json_build_object('sub', id, 'role', 'authenticated')::text from auth.users where email = '${email}')`
}

async function setup() {
  await psql(`
    do $$
    #variable_conflict use_variable
    declare
      admin_id uuid;
      accounts_id uuid;
      godown_id uuid;
      godown2_id uuid;
      keeper_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      product_b uuid;
      shop_id uuid;
      order_id uuid;
      request_id uuid;
      header jsonb;
      res jsonb;
      i int;
      verification_id uuid;
      line_a uuid;
      line_b uuid;
      photo_id uuid;
      adj_id uuid;
      adj_b uuid;
      lot_id uuid;
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
        ('admin.m3adj@example.com'),
        ('accounts.m3adj@example.com'),
        ('godown.m3adj@example.com'),
        ('godown2.m3adj@example.com'),
        ('keeper.m3adj@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m3adj@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m3adj@example.com';
      select id into godown_id from auth.users where email = 'godown.m3adj@example.com';
      select id into godown2_id from auth.users where email = 'godown2.m3adj@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m3adj@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M3ADJ Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (accounts_id, 'accounts', true),
        (godown_id, 'godown', true),
        (godown2_id, 'godown2', true),
        (keeper_id, 'keeper', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts_id, roles.id, admin_id from public.roles where roles.code = 'accounts'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown2_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select keeper_id, roles.id, admin_id from public.roles where roles.code = 'store_keeper'
      on conflict do nothing;

      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      branch_id := public.create_branch('${PREFIX}_b', 'M3ADJ');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(godown2_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, 'z', 'Z', null);
      crate_id := public.create_crate(zone_id, 'c', 'C', null);
      product_id := public.create_product('${PREFIX}_a', 'M3ADJ A', null, null);
      product_b := public.create_product('${PREFIX}_b', 'M3ADJ B', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      perform public.set_product_expiry_policy(product_b, 'non_expiring');
      shop_id := public.create_shop('${PREFIX} shop', null, null);

      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');

      perform public.post_opening_stock(
        product_id, crate_id, 6, '${PREFIX}-open-a', null, 'M3ADJ-A', null, '2028-01-01'
      );
      perform public.post_opening_stock(
        product_b, crate_id, 3, '${PREFIX}-open-b', null, 'M3ADJ-B', null, null
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

      verification_id := public.start_stock_verification(
        branch_id, current_date, array[zone_id], array[crate_id]
      );
      select stock_verification_lines.id into line_a
      from public.stock_verification_lines
      where stock_verification_lines.verification_id = verification_id
        and stock_verification_lines.product_id = product_id;
      select stock_verification_lines.id into line_b
      from public.stock_verification_lines
      where stock_verification_lines.verification_id = verification_id
        and stock_verification_lines.product_id = product_b;

      perform public.save_verification_count(line_a, '1'::jsonb, 1);
      perform public.save_verification_count(line_b, '2'::jsonb, 1);
      perform public.submit_stock_verification(verification_id);
      perform public.report_stock_discrepancy(line_a, 'short A');
      perform public.report_stock_discrepancy(line_b, 'short B');
      perform public.request_verification_recount(line_a);
      perform public.request_verification_recount(line_b);
      perform public.save_verification_recount(line_a, '1'::jsonb, 2);
      perform public.save_verification_recount(line_b, '2'::jsonb, 2);
      perform public.review_verification_discrepancy(line_a, 'recount confirms one', '{}'::uuid[]);
      perform public.review_verification_discrepancy(line_b, 'recount confirms two', '{}'::uuid[]);

      photo_id := (public.create_verification_photo_upload(verification_id, 'count sheet', null) ->> 'id')::uuid;
      insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
      select
        'stock-verification-evidence',
        stock_verification_evidence.storage_path,
        godown_id,
        godown_id::text,
        jsonb_build_object(
          'size', 4,
          'mimetype', 'image/jpeg',
          'eTag', encode(extensions.digest(decode('ffd8ffd9', 'hex'), 'md5'), 'hex')
        )
      from public.stock_verification_evidence
      where id = photo_id;
      perform public.finalize_verification_photo_upload(photo_id, encode(decode('ffd8ffd9', 'hex'), 'base64'));
      perform public.close_stock_verification(verification_id, 'correction_requested', 'shortages');

      adj_id := (public.create_stock_adjustment(
        verification_id, 'shortage', 'race A', array[line_a], '${PREFIX}-adj-a', null
      ) ->> 'id')::uuid;
      select stock_lots.id into lot_id
      from public.stock_lots
      where stock_lots.product_id = product_id
      order by stock_lots.created_at
      limit 1;
      perform public.set_stock_adjustment_line_lot_allocations(
        (select stock_adjustment_lines.id from public.stock_adjustment_lines
         where stock_adjustment_lines.request_id = adj_id limit 1),
        jsonb_build_array(jsonb_build_object('lot_id', lot_id, 'quantity', -5))
      );
      perform public.submit_stock_adjustment(adj_id, (
        select version from public.stock_adjustment_requests where id = adj_id
      ));

      adj_b := (public.create_stock_adjustment(
        verification_id, 'shortage', 'inject B', array[line_b], '${PREFIX}-adj-b', null
      ) ->> 'id')::uuid;
      perform public.set_stock_adjustment_line_lot_allocations(
        (select stock_adjustment_lines.id from public.stock_adjustment_lines
         where stock_adjustment_lines.request_id = adj_b limit 1),
        jsonb_build_array(jsonb_build_object(
          'lot_id', (select stock_lots.id from public.stock_lots where stock_lots.product_id = product_b limit 1),
          'quantity', -1
        ))
      );
      perform public.submit_stock_adjustment(adj_b, (
        select version from public.stock_adjustment_requests where id = adj_b
      ));

      perform set_config('request.jwt.claims', json_build_object('sub', godown2_id, 'role', 'authenticated')::text, true);
      perform public.approve_stock_adjustment(adj_id, (
        select version from public.stock_adjustment_requests where id = adj_id
      ), 'second manager A');
      perform public.approve_stock_adjustment(adj_b, (
        select version from public.stock_adjustment_requests where id = adj_b
      ), 'second manager B');
    end $$;
  `)

  const row = lastLine(
    await psql(`
      select
        d.id::text || ' ' || d.version::text || ' ' || d.order_id::text
        || ' ' || a.id::text || ' ' || a.version::text
        || ' ' || b.id::text || ' ' || b.version::text
        || ' ' || p.id::text || ' ' || r.crate_id::text || ' ' || r.lot_id::text
        || ' ' || pb.id::text
      from public.stock_dispatch_requests d
      join public.stock_reservations r on r.picking_request_id = d.picking_request_id
      join public.products p on p.id = r.product_id
      join public.stock_adjustment_requests a on a.idempotency_key = '${PREFIX}-adj-a'
      join public.stock_adjustment_requests b on b.idempotency_key = '${PREFIX}-adj-b'
      join public.products pb on pb.sku = '${PREFIX}_b'
      where d.idempotency_key = '${PREFIX}-prep'
      limit 1;
    `),
  )
  const parts = row.split(" ")
  if (parts.length < 11) throw new Error(`setup ids missing: ${row}`)
  ids.dispatch = parts[0]
  ids.version = Number(parts[1])
  ids.order = parts[2]
  ids.adj = parts[3]
  ids.adjVersion = Number(parts[4])
  ids.adjB = parts[5]
  ids.adjBVersion = Number(parts[6])
  ids.product = parts[7]
  ids.crate = parts[8]
  ids.lot = parts[9]
  ids.productB = parts[10]
}

function confirmSql(key) {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims', ${claims("godown.m3adj@example.com")}, true);
set local role authenticated;
set local lock_timeout = '8s';
select public.confirm_dispatch('${ids.dispatch}'::uuid, ${ids.version}::integer, '${key}');
commit;
`
}

function adjustSql(adjId, version, key, inject = false) {
  return `
\\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims', ${claims("godown.m3adj@example.com")}, true);
${inject ? "select set_config('app.m3_inject_adjust', 'on', true);" : ""}
set local role authenticated;
set local lock_timeout = '8s';
select public.post_stock_adjustment('${adjId}'::uuid, ${version}::integer, '${key}');
commit;
`
}

function assertNoNegatives() {
  return psql(`
    select
      (select count(*) from public.stock_balances where quantity < 0)::text
      || ' ' ||
      (select count(*) from public.stock_lot_balances where quantity < 0)::text;
  `)
}

async function conservation(label) {
  const negatives = lastLine(await assertNoNegatives())
  if (negatives !== "0 0") throw new Error(`${label}: negative stock ${negatives}`)
  const dispatchCount = lastLine(
    await psql(`
      select count(*)::text from public.stock_transactions
      where dispatch_request_id = '${ids.dispatch}'::uuid and transaction_type = 'DISPATCH'
    `),
  )
  if (Number(dispatchCount) > 1) {
    throw new Error(`${label}: duplicate DISPATCH ${dispatchCount}`)
  }
  const partial = lastLine(
    await psql(`
      select count(*)::text from public.stock_reservations
      where product_id = '${ids.product}'::uuid
        and status = 'consumed'
        and not exists (
          select 1 from public.stock_transactions
          where dispatch_request_id = '${ids.dispatch}'::uuid
            and transaction_type = 'DISPATCH'
        )
    `),
  )
  if (partial !== "0") {
    throw new Error(`${label}: consumed reservation without DISPATCH`)
  }
  return { dispatchCount }
}

await setup()

const beforeB = lastLine(
  await psql(`
    select quantity::text from public.stock_balances
    where crate_id = '${ids.crate}'::uuid and product_id = '${ids.product}'::uuid
  `),
)
if (beforeB !== "6") throw new Error(`setup remaining qty ${beforeB}`)

const seqB = await Promise.allSettled([
  psql(adjustSql(ids.adj, ids.adjVersion, `${PREFIX}-post-first`)),
])
if (seqB[0].status === "fulfilled") {
  throw new Error("scenario B: adjustment must not reduce reserved stock before dispatch")
}
const afterB = lastLine(
  await psql(`
    select quantity::text from public.stock_balances
    where crate_id = '${ids.crate}'::uuid and product_id = '${ids.product}'::uuid
  `),
)
if (afterB !== "6") throw new Error(`scenario B changed stock to ${afterB}`)
const holds = lastLine(
  await psql(`
    select count(*)::text from public.stock_reservations
    where product_id = '${ids.product}'::uuid and status = 'active'
  `),
)
if (holds === "0") throw new Error("scenario B must leave active reservations")
const preparing = lastLine(
  await psql(`select status from public.stock_dispatch_requests where id = '${ids.dispatch}'::uuid`),
)
if (preparing !== "preparing") {
  throw new Error(`scenario B must leave dispatch preparing, got ${preparing}`)
}
console.log("PASS B adjustment-first rejected by reservation guards; dispatch still eligible")

const race = await Promise.allSettled([
  psql(confirmSql(`${PREFIX}-cfm-a`)),
  psql(confirmSql(`${PREFIX}-cfm-b`)),
  psql(adjustSql(ids.adj, ids.adjVersion, `${PREFIX}-post-race`)),
])
const { dispatchCount } = await conservation("scenario A")
if (dispatchCount !== "1") {
  throw new Error(`scenario A expected one DISPATCH, got ${dispatchCount} ${JSON.stringify(race)}`)
}
const qtyA = lastLine(
  await psql(`
    select quantity::text from public.stock_balances
    where crate_id = '${ids.crate}'::uuid and product_id = '${ids.product}'::uuid
  `),
)
if (qtyA !== "2") {
  throw new Error(`scenario A remaining qty must be 2 after 4 dispatched from 6, got ${qtyA}`)
}
const lotQty = lastLine(
  await psql(`
    select quantity::text from public.stock_lot_balances
    where crate_id = '${ids.crate}'::uuid and lot_id = '${ids.lot}'::uuid
  `),
)
if (lotQty !== "2") {
  throw new Error(`scenario A lot qty must match aggregate 2, got ${lotQty}`)
}
const adjPosted = lastLine(
  await psql(`select status from public.stock_adjustment_requests where id = '${ids.adj}'::uuid`),
)
if (adjPosted === "posted") {
  throw new Error("scenario A: reserved-stock adjustment must not post against active/consumed hold")
}
console.log("PASS A concurrent confirm vs reducing adjustment; one DISPATCH; remaining 2; no negatives")

const replay = await psql(confirmSql(`${PREFIX}-cfm-a`))
if (!firstUuid(replay)) throw new Error("scenario D: retry after success must replay")
await conservation("scenario D")
console.log("PASS D duplicate confirm during/after adjustment race replays once")

const lateAdjust = await Promise.allSettled([
  psql(adjustSql(ids.adj, ids.adjVersion, `${PREFIX}-post-late`)),
])
if (lateAdjust[0].status === "fulfilled") {
  throw new Error("scenario C: post-dispatch adjustment must not consume remaining or missing cartons")
}
const qtyC = lastLine(
  await psql(`
    select quantity::text from public.stock_balances
    where crate_id = '${ids.crate}'::uuid and product_id = '${ids.product}'::uuid
  `),
)
if (qtyC !== "2") throw new Error(`scenario C changed remaining stock to ${qtyC}`)
await conservation("scenario C")
console.log("PASS C dispatch-first; later adjustment fails without extra debit")

await psql(`
  create or replace function public.m3adj_inject_adjust_fail()
  returns trigger language plpgsql as $f$
  begin
    if current_setting('app.m3_inject_adjust', true) = 'on' and new.quantity < 0 then
      raise exception 'injected adjustment failure' using errcode = 'P0001';
    end if;
    return new;
  end;
  $f$;
  drop trigger if exists m3adj_inject on public.stock_ledger;
  create constraint trigger m3adj_inject
  after insert on public.stock_ledger
  deferrable initially immediate
  for each row execute function public.m3adj_inject_adjust_fail();
`)

const inject = await Promise.allSettled([
  psql(adjustSql(ids.adjB, ids.adjBVersion, `${PREFIX}-post-inject`, true)),
])
if (inject[0].status === "fulfilled") {
  throw new Error("scenario E: injected failure must abort adjustment")
}
const bQty = lastLine(
  await psql(`
    select quantity::text from public.stock_balances
    where crate_id = '${ids.crate}'::uuid and product_id = '${ids.productB}'::uuid
  `),
)
if (bQty !== "3") throw new Error(`scenario E leaked B stock, remaining ${bQty}`)
const bAdj = lastLine(
  await psql(`select status from public.stock_adjustment_requests where id = '${ids.adjB}'::uuid`),
)
if (bAdj === "posted") throw new Error("scenario E posted adjustment after injected failure")
await psql(`
  drop trigger if exists m3adj_inject on public.stock_ledger;
  drop function if exists public.m3adj_inject_adjust_fail();
`)
console.log("PASS E injected adjustment failure rolled back; B stock unchanged")

await psql(`
  set session_replication_role = replica;
  select set_config('app.picking_write', 'on', true);
  select set_config('app.dispatch_write', 'on', true);
  select set_config('app.adjustment_write', 'on', true);
  update public.stock_reservations
  set status = 'released'
  where product_id in ('${ids.product}'::uuid, '${ids.productB}'::uuid)
    and status = 'active';
  update public.stock_ledger set lot_id = null
  where product_id in ('${ids.product}'::uuid, '${ids.productB}'::uuid);
  delete from public.stock_balances
  where product_id in ('${ids.product}'::uuid, '${ids.productB}'::uuid);
  delete from public.stock_lot_balances
  where lot_id in (
    select id from public.stock_lots
    where product_id in ('${ids.product}'::uuid, '${ids.productB}'::uuid)
  );
  delete from public.stock_lots
  where product_id in ('${ids.product}'::uuid, '${ids.productB}'::uuid);
  update public.app_configuration
  set value = 'false'::jsonb
  where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
  set session_replication_role = origin;
`)
console.log("adjustment concurrency cleanup restored flags")
