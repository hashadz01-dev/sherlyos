/**
 * M5.4D verify/return/reject/write-off lock-order races. Local Docker only.
 * Dispatch pairings enable stock.lots.dual_write_enabled only for that
 * seed; cleanup restores it false. damage.stock_hold_ready stays false.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m54dc_${RUN}`
const passed = []

function ok(name) {
  passed.push(name)
  console.log("PASS", name)
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

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

function session(sql) {
  return new Promise((resolve) => {
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
    child.on("close", (code) => resolve({ code, text: output.trim() }))
    child.stdin.end(sql)
  })
}

function asUser(userKey, body) {
  return `
    set local statement_timeout = '15s';
    set local role authenticated;
    select set_config('request.jwt.claim.sub', (select value from public.phase_m54d_race_target where name = '${userKey}'), true);
    select set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', (select value::uuid from public.phase_m54d_race_target where name = '${userKey}'),
        'role', 'authenticated'
      )::text,
      true
    );
    ${body}
  `
}

function waitBarrier(race) {
  return `
    do $$
    declare
      i integer;
    begin
      for i in 1..250 loop
        exit when coalesce((select open from public.phase_m54d_barrier where race = '${race}'), false);
        perform pg_sleep(0.02);
      end loop;
      if not coalesce((select open from public.phase_m54d_barrier where race = '${race}'), false) then
        raise exception 'barrier timeout for ${race}';
      end if;
    end $$;
  `
}

async function raceTwo(name, sqlA, sqlB) {
  await psql(`
    insert into public.phase_m54d_barrier (race, open)
    values ('${name}', false)
    on conflict (race) do update set open = false;
  `)
  const pending = Promise.all([
    session(`begin;\n${sqlA}\ncommit;`),
    session(`begin;\n${sqlB}\ncommit;`),
  ])
  await delay(800)
  await psql(
    `update public.phase_m54d_barrier set open = true where race = '${name}';`,
  )
  return pending
}

async function assertNoNegative() {
  const count = await psql(`
    select count(*)::text from public.stock_balances sb
    join public.products p on p.id = sb.product_id
    where p.sku like '${PREFIX}-%' and sb.quantity < 0;
  `)
  if (Number(count.split(/\r?\n/).filter(Boolean).at(-1) ?? "1") !== 0) {
    throw new Error("negative stock balance")
  }
}

function seedSubmittedInbound(key) {
  return `
    set session_replication_role = replica;
    do $$
    declare
      keeper_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'keeper');
      branch_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      p_product uuid := (select value::uuid from public.phase_m54d_race_target where name = 'product');
      report_id uuid;
      ev_id uuid := gen_random_uuid();
    begin
      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-${key}', 'refill_supply', branch_id, 'submitted', 2, keeper_id,
        '${PREFIX}-${key}-key', '${PREFIX}-${key}-fp', 'race ${key}'
      ) returning id into report_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, quantity_cases, damage_reason
      ) values (report_id, p_product, 1, 'crushed');
      insert into public.damage_evidence (
        id, damage_report_id, storage_path, mime_type, uploaded_by, verified_at
      ) values (
        ev_id, report_id, report_id::text || '/' || ev_id::text, 'image/jpeg', keeper_id, now()
      );
      insert into public.phase_m54d_race_target (name, value)
      values ('report_${key}', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = origin;
  `
}

function seedVerifiedHold(key, qty, leftover = 0) {
  const opening = qty + leftover
  return `
    do $$
    declare
      admin_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'admin');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      p_product uuid;
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      p_product := public.create_product('${PREFIX}-${key}', 'M54D ${key}', null, null);
      perform public.post_opening_stock(
        p_product, crate_id, ${opening}, '${PREFIX}-open-${key}', 'M54D ${key}'
      );
      insert into public.phase_m54d_race_target (name, value)
      values ('product_${key}', p_product::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = replica;
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'godown');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      branch_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'branch');
      p_product uuid := (select value::uuid from public.phase_m54d_race_target where name = 'product_${key}');
      report_id uuid;
      line_id uuid;
      ev_id uuid := gen_random_uuid();
    begin
      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-${key}', 'storage', branch_id, 'verified', 1, godown_id,
        godown_id, now(), '${PREFIX}-${key}-key', '${PREFIX}-${key}-fp', 'race ${key}'
      ) returning id into report_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      ) values (report_id, p_product, crate_id, ${qty}, 'crushed')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id,
        quantity_cases, hold_kind, status
      ) values (report_id, line_id, p_product, crate_id, ${qty}, 'on_hand_deduction', 'active');
      insert into public.damage_evidence (
        id, damage_report_id, storage_path, mime_type, uploaded_by, verified_at
      ) values (
        ev_id, report_id, report_id::text || '/' || ev_id::text, 'image/jpeg', godown_id, now()
      );
      insert into public.phase_m54d_race_target (name, value)
      values ('report_${key}', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = origin;
  `
}

function enableLotDualWrite() {
  return `
    set session_replication_role = replica;
    update public.app_configuration set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    set session_replication_role = origin;
  `
}

function restoreDualWrite() {
  return `
    set session_replication_role = replica;
    update public.app_configuration set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;
  `
}

function seedLotOpening(key, qty) {
  return `
    ${enableLotDualWrite()}
    do $$
    declare
      admin_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'admin');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      p_product uuid;
      selected_lot uuid;
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      p_product := public.create_product('${PREFIX}-${key}', 'M54D ${key}', null, null);
      perform public.set_product_expiry_policy(p_product, 'expiry_controlled');
      perform public.post_opening_stock(
        p_product, crate_id, ${qty}, '${PREFIX}-open-${key}', null, 'M54D-${key}', null, '2028-06-01'
      );
      select sl.id into selected_lot
      from public.stock_lots sl
      where sl.product_id = p_product
      order by sl.created_at
      limit 1;
      insert into public.phase_m54d_race_target (name, value) values
        ('product_${key}', p_product::text),
        ('lot_${key}', selected_lot::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `
}

function attachStorageHold(key, qty) {
  return `
    set session_replication_role = replica;
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'godown');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      branch_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'branch');
      p_product uuid := (select value::uuid from public.phase_m54d_race_target where name = 'product_${key}');
      p_lot uuid := (select value::uuid from public.phase_m54d_race_target where name = 'lot_${key}');
      report_id uuid;
      line_id uuid;
    begin
      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-${key}', 'storage', branch_id, 'verified', 1, godown_id,
        godown_id, now(), '${PREFIX}-${key}-key', '${PREFIX}-${key}-fp', 'race ${key}'
      ) returning id into report_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, lot_id, quantity_cases, damage_reason
      ) values (report_id, p_product, crate_id, p_lot, ${qty}, 'crushed')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id, lot_id,
        quantity_cases, hold_kind, status
      ) values (report_id, line_id, p_product, crate_id, p_lot, ${qty}, 'on_hand_deduction', 'active');
      insert into public.phase_m54d_race_target (name, value) values
        ('report_${key}', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = origin;
  `
}

function seedLotVerifiedHold(key, qty, leftover = 0) {
  const opening = qty + leftover
  return `
    ${enableLotDualWrite()}
    do $$
    declare
      admin_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'admin');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      p_product uuid;
      selected_lot uuid;
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      p_product := public.create_product('${PREFIX}-${key}', 'M54D ${key}', null, null);
      perform public.set_product_expiry_policy(p_product, 'expiry_controlled');
      perform public.post_opening_stock(
        p_product, crate_id, ${opening}, '${PREFIX}-open-${key}', null, 'M54D-${key}', null, '2028-06-01'
      );
      select sl.id into selected_lot
      from public.stock_lots sl
      where sl.product_id = p_product
      order by sl.created_at
      limit 1;
      insert into public.phase_m54d_race_target (name, value) values
        ('product_${key}', p_product::text),
        ('lot_${key}', selected_lot::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = replica;
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'godown');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      branch_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'branch');
      p_product uuid := (select value::uuid from public.phase_m54d_race_target where name = 'product_${key}');
      p_lot uuid := (select value::uuid from public.phase_m54d_race_target where name = 'lot_${key}');
      report_id uuid;
      line_id uuid;
      ev_id uuid := gen_random_uuid();
    begin
      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-${key}', 'storage', branch_id, 'verified', 1, godown_id,
        godown_id, now(), '${PREFIX}-${key}-key', '${PREFIX}-${key}-fp', 'race ${key}'
      ) returning id into report_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, lot_id, quantity_cases, damage_reason
      ) values (report_id, p_product, crate_id, p_lot, ${qty}, 'crushed')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id, lot_id,
        quantity_cases, hold_kind, status
      ) values (report_id, line_id, p_product, crate_id, p_lot, ${qty}, 'on_hand_deduction', 'active');
      insert into public.damage_evidence (
        id, damage_report_id, storage_path, mime_type, uploaded_by, verified_at
      ) values (
        ev_id, report_id, report_id::text || '/' || ev_id::text, 'image/jpeg', godown_id, now()
      );
      insert into public.phase_m54d_race_target (name, value)
      values ('report_${key}', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = origin;
  `
}

function createDispatchReady(key, qty) {
  return `
    do $$
    declare
      accounts_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'accounts');
      godown_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'godown');
      keeper_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'keeper');
      branch_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'branch');
      shop_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m54d_race_target where name = 'product_${key}');
      order_id uuid;
      payload jsonb;
      reserved jsonb;
      header jsonb;
      res jsonb;
      prepared jsonb;
    begin
      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', p_product, 'requested_cases', ${qty})),
        '${PREFIX}-ord-${key}'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-osub-${key}');
      perform public.verify_order(order_id, 2, '${PREFIX}-over-${key}');
      payload := public.create_delivery_note(order_id, '${PREFIX}-dn-${key}');
      perform public.generate_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen-${key}');
      perform public.send_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-snd-${key}');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack-${key}');

      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      reserved := public.reserve_order_allocation(order_id, 3, '${PREFIX}-res-${key}');
      reserved := public.assign_picking_request(
        (reserved ->> 'id')::uuid, keeper_id, (reserved ->> 'version')::integer, '${PREFIX}-asg-${key}'
      );
      reserved := public.start_picking(
        (reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, '${PREFIX}-start-${key}'
      );
      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
      header := public.get_picking_request((reserved ->> 'id')::uuid);
      res := header -> 'reservations' -> 0;
      header := public.confirm_picking_quantity(
        (reserved ->> 'id')::uuid, (res ->> 'id')::uuid,
        (res ->> 'reserved_cases')::integer, (header ->> 'version')::integer, '${PREFIX}-pick-${key}'
      );
      header := public.complete_picking(
        (reserved ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-cmp-${key}'
      );
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      header := public.confirm_picking_handoff(
        (reserved ->> 'id')::uuid, (header ->> 'version')::integer, '${PREFIX}-hand-${key}'
      );
      prepared := public.prepare_dispatch(order_id, (header ->> 'version')::integer, '${PREFIX}-prep-${key}');
      insert into public.phase_m54d_race_target (name, value) values
        ('order_${key}', order_id::text),
        ('dispatch_${key}', prepared ->> 'id'),
        ('dispatch_ver_${key}', prepared ->> 'version')
      on conflict (name) do update set value = excluded.value;
    end $$;
  `
}

function isDeadlock(result) {
  return /deadlock detected|40P01/i.test(result?.text ?? "")
}

function rejectDeadlock(name, x, y) {
  if (isDeadlock(x) || isDeadlock(y)) {
    throw new Error(`${name} deadlocked on first pass ${JSON.stringify([x, y])}`)
  }
}

async function setupShared() {
  await psql(`
    drop table if exists public.phase_m54d_race_target;
    drop table if exists public.phase_m54d_barrier;
    create table public.phase_m54d_race_target (name text primary key, value text not null);
    create table public.phase_m54d_barrier (race text primary key, open boolean not null default false);
    grant select on public.phase_m54d_race_target to authenticated;
    grant select on public.phase_m54d_barrier to authenticated;

    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      godown_id uuid;
      verifier_id uuid;
      keeper_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      shop_id uuid;
      p_product uuid;
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
        ('admin.${PREFIX}@example.com'),
        ('accounts.${PREFIX}@example.com'),
        ('godown.${PREFIX}@example.com'),
        ('verifier.${PREFIX}@example.com'),
        ('keeper.${PREFIX}@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.${PREFIX}@example.com';
      select id into accounts_id from auth.users where email = 'accounts.${PREFIX}@example.com';
      select id into godown_id from auth.users where email = 'godown.${PREFIX}@example.com';
      select id into verifier_id from auth.users where email = 'verifier.${PREFIX}@example.com';
      select id into keeper_id from auth.users where email = 'keeper.${PREFIX}@example.com';

      insert into public.profiles (id, full_name, is_active) values
        (admin_id, 'admin', true), (accounts_id, 'accounts', true),
        (godown_id, 'godown', true), (verifier_id, 'verifier', true),
        (keeper_id, 'keeper', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select admin_id, roles.id, admin_id from public.roles where code = 'admin' on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts_id, roles.id, admin_id from public.roles where code = 'accounts' on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where code = 'godown_manager' on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select verifier_id, roles.id, admin_id from public.roles where code = 'godown_manager' on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select keeper_id, roles.id, admin_id from public.roles where code = 'store_keeper' on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      branch_id := public.create_branch('${PREFIX}_gd', 'M54D Race Godown');
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(verifier_id, branch_id);
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      shop_id := public.create_shop('M54D Race Shop ${RUN}', null, null);
      p_product := public.create_product('${PREFIX}-base', 'M54D base', null, null);

      insert into public.phase_m54d_race_target (name, value) values
        ('admin', admin_id::text),
        ('accounts', accounts_id::text),
        ('godown', godown_id::text),
        ('verifier', verifier_id::text),
        ('keeper', keeper_id::text),
        ('branch', branch_id::text),
        ('crate', crate_id::text),
        ('shop', shop_id::text),
        ('product', p_product::text);
    end $$;
  `)
}

async function raceVerifyVerify() {
  await psql(seedSubmittedInbound("vv"))
  const [x, y] = await raceTwo(
    "VV",
    asUser(
      "godown",
      `
      ${waitBarrier("VV")}
      select public.verify_damage_report(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_vv'), 2
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("VV")}
      select public.verify_damage_report(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_vv'), 2
      );
    `,
    ),
  )
  rejectDeadlock("verify vs verify", x, y)
  const events = Number(
    await psql(`
      select count(*) from public.damage_report_events
      where damage_report_id = (select value::uuid from public.phase_m54d_race_target where name = 'report_vv')
        and action = 'verified'
    `),
  )
  if (events !== 1) {
    throw new Error(`verify vs verify events=${events} ${JSON.stringify([x, y])}`)
  }
  if (x.code === 0 && y.code === 0) {
    throw new Error("both concurrent verifies succeeded")
  }
  ok("verify vs verify")
}

async function raceVerifyReturn() {
  await psql(seedSubmittedInbound("vr"))
  const [x, y] = await raceTwo(
    "VR",
    asUser(
      "godown",
      `
      ${waitBarrier("VR")}
      select public.verify_damage_report(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_vr'), 2
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("VR")}
      select public.return_damage_report(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_vr'),
        2, 'race return'
      );
    `,
    ),
  )
  rejectDeadlock("verify vs return", x, y)
  const status = (
    await psql(`
      select status from public.damage_reports
      where id = (select value::uuid from public.phase_m54d_race_target where name = 'report_vr')
    `)
  )
    .split(/\r?\n/)
    .filter(Boolean)
    .at(-1)
  if (!["verified", "returned"].includes(status)) {
    throw new Error(`verify vs return status=${status} ${JSON.stringify([x, y])}`)
  }
  if (x.code === 0 && y.code === 0) {
    throw new Error("verify and return both committed")
  }
  ok("verify vs return")
}

async function raceVerifyReject() {
  await psql(seedSubmittedInbound("vj"))
  const [x, y] = await raceTwo(
    "VJ",
    asUser(
      "godown",
      `
      ${waitBarrier("VJ")}
      select public.verify_damage_report(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_vj'), 2
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("VJ")}
      select public.reject_damage_report(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_vj'),
        2, 'race reject'
      );
    `,
    ),
  )
  rejectDeadlock("verify vs reject", x, y)
  const status = (
    await psql(`
      select status from public.damage_reports
      where id = (select value::uuid from public.phase_m54d_race_target where name = 'report_vj')
    `)
  )
    .split(/\r?\n/)
    .filter(Boolean)
    .at(-1)
  if (!["verified", "rejected"].includes(status)) {
    throw new Error(`verify vs reject status=${status} ${JSON.stringify([x, y])}`)
  }
  if (x.code === 0 && y.code === 0) {
    throw new Error("verify and reject both committed")
  }
  ok("verify vs reject")
}

async function raceWriteoffWriteoff() {
  await psql(seedVerifiedHold("ww", 2))
  const [x, y] = await raceTwo(
    "WW",
    asUser(
      "godown",
      `
      ${waitBarrier("WW")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_ww'),
        1, '${PREFIX}-wo-a'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("WW")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_ww'),
        1, '${PREFIX}-wo-b'
      );
    `,
    ),
  )
  rejectDeadlock("write-off vs write-off", x, y)
  const txns = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54d_race_target where name = 'report_ww')
        and damage_posting_kind = 'ordinary_writeoff'
    `),
  )
  if (txns !== 1) {
    throw new Error(`write-off vs write-off posted ${txns} ${JSON.stringify([x, y])}`)
  }
  await assertNoNegative()
  ok("write-off vs write-off exact-once")
}

async function raceWriteoffTransfer() {
  await psql(seedVerifiedHold("wt", 2))
  const [x, y] = await raceTwo(
    "WT",
    asUser(
      "godown",
      `
      ${waitBarrier("WT")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_wt'),
        1, '${PREFIX}-wo-wt'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("WT")}
      select public.transfer_verified_damage_to_quarantine(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_wt'),
        1, '${PREFIX}-qrn-wt'
      );
    `,
    ),
  )
  rejectDeadlock("write-off vs transfer", x, y)
  const kinds = await psql(`
    select string_agg(damage_posting_kind, ',' order by damage_posting_kind)
    from public.stock_transactions
    where damage_report_id = (select value::uuid from public.phase_m54d_race_target where name = 'report_wt')
  `)
  const posted = kinds.split(/\r?\n/).filter(Boolean).at(-1) ?? ""
  const writeoffOnly = posted === "ordinary_writeoff"
  const transferOnly = posted === "quarantine_transfer"
  const transferThenWriteoff =
    posted.includes("quarantine_transfer") && posted.includes("ordinary_writeoff")
  // Unique index is per (report, kind). Transfer-then-write-off consumes
  // remaining transferred holds (documented M5.4D pipeline), not two saleable
  // crate debits. XOR was an incorrect harness expectation.
  if (!writeoffOnly && !transferOnly && !transferThenWriteoff) {
    throw new Error(`unexpected write-off/transfer kinds ${posted} ${JSON.stringify([x, y])}`)
  }
  await assertNoNegative()
  ok("write-off vs quarantine transfer")
}

async function raceWriteoffPicking() {
  await psql(seedLotOpening("pk", 2))
  await psql(`
    do $$
    declare
      accounts_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'accounts');
      godown_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'godown');
      branch_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'branch');
      shop_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m54d_race_target where name = 'product_pk');
      order_id uuid;
      payload jsonb;
    begin
      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', p_product, 'requested_cases', 1)),
        '${PREFIX}-ord-pk'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-osub-pk');
      perform public.verify_order(order_id, 2, '${PREFIX}-over-pk');
      payload := public.create_delivery_note(order_id, '${PREFIX}-dn-pk');
      perform public.generate_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen-pk');
      perform public.send_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-snd-pk');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack-pk');
      insert into public.phase_m54d_race_target (name, value)
      values ('order_pk', order_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  await psql(attachStorageHold("pk", 2))
  const [x, y] = await raceTwo(
    "PK",
    asUser(
      "godown",
      `
      ${waitBarrier("PK")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_pk'),
        1, '${PREFIX}-wo-pk'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("PK")}
      select public.reserve_order_allocation(
        (select value::uuid from public.phase_m54d_race_target where name = 'order_pk'),
        3, '${PREFIX}-res-pk'
      );
    `,
    ),
  )
  rejectDeadlock("write-off vs picking", x, y)
  const reserved = Number(
    await psql(`
      select coalesce(sum(reserved_cases),0) from public.stock_reservations
      where order_id = (select value::uuid from public.phase_m54d_race_target where name = 'order_pk')
        and status = 'active'
    `),
  )
  if (reserved > 0) {
    throw new Error(`picking reserved held stock reserved=${reserved} ${JSON.stringify([x, y])}`)
  }
  await assertNoNegative()
  ok("write-off vs picking")
  await psql(restoreDualWrite())
}

async function raceWriteoffDeact() {
  await psql(seedVerifiedHold("deact", 2))
  const [x, y] = await raceTwo(
    "DEACT",
    asUser(
      "godown",
      `
      ${waitBarrier("DEACT")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_deact'),
        1, '${PREFIX}-wo-deact'
      );
    `,
    ),
    asUser(
      "admin",
      `
      ${waitBarrier("DEACT")}
      select public.set_branch_active(
        (select value::uuid from public.phase_m54d_race_target where name = 'branch'),
        false
      );
    `,
    ),
  )
  rejectDeadlock("write-off vs deactivation", x, y)
  const wo = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54d_race_target where name = 'report_deact')
        and damage_posting_kind = 'ordinary_writeoff'
    `),
  )
  if (wo > 1) throw new Error(`deact over-post ${wo}`)
  await assertNoNegative()
  await psql(`
    begin;
    ${asUser(
      "admin",
      `
      select public.set_branch_active(
        (select value::uuid from public.phase_m54d_race_target where name = 'branch'),
        true
      );
    `,
    )}
    commit;
  `).catch(() => undefined)
  ok("write-off vs branch deactivation")
}

async function raceWriteoffDispatch() {
  await psql(seedLotVerifiedHold("wod", 2, 2))
  await psql(createDispatchReady("wod", 2))
  const [x, y] = await raceTwo(
    "WOD",
    asUser(
      "godown",
      `
      ${waitBarrier("WOD")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_wod'),
        1, '${PREFIX}-wo-dsp'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("WOD")}
      select public.confirm_dispatch(
        (select value::uuid from public.phase_m54d_race_target where name = 'dispatch_wod'),
        (select value::integer from public.phase_m54d_race_target where name = 'dispatch_ver_wod'),
        '${PREFIX}-cnf-wod'
      );
    `,
    ),
  )
  rejectDeadlock("write-off vs confirm_dispatch", x, y)
  if (x.code !== 0 || y.code !== 0) {
    throw new Error(`write-off vs dispatch first pass failed ${JSON.stringify([x, y])}`)
  }
  const wo = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54d_race_target where name = 'report_wod')
        and damage_posting_kind = 'ordinary_writeoff'
    `),
  )
  const consumed = Number(
    await psql(`
      select count(*) from public.stock_dispatch_requests
      where id = (select value::uuid from public.phase_m54d_race_target where name = 'dispatch_wod')
        and stock_consumed
    `),
  )
  if (wo !== 1) throw new Error(`expected exact-once write-off, got ${wo}`)
  if (consumed !== 1) throw new Error(`expected dispatch consumed, got ${consumed}`)
  await assertNoNegative()
  ok("write-off vs confirm_dispatch")
}

function seedSubmittedHold(key, qty, leftover = 0) {
  const opening = qty + leftover
  return `
    ${enableLotDualWrite()}
    do $$
    declare
      admin_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'admin');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      p_product uuid;
      selected_lot uuid;
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      p_product := public.create_product('${PREFIX}-${key}', 'M54D ${key}', null, null);
      perform public.set_product_expiry_policy(p_product, 'expiry_controlled');
      perform public.post_opening_stock(
        p_product, crate_id, ${opening}, '${PREFIX}-open-${key}', null, 'M54D-${key}', null, '2028-06-01'
      );
      select sl.id into selected_lot
      from public.stock_lots sl
      where sl.product_id = p_product
      order by sl.created_at
      limit 1;
      insert into public.phase_m54d_race_target (name, value) values
        ('product_${key}', p_product::text),
        ('lot_${key}', selected_lot::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = replica;
    do $$
    declare
      keeper_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'keeper');
      crate_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'crate');
      branch_id uuid := (select value::uuid from public.phase_m54d_race_target where name = 'branch');
      p_product uuid := (select value::uuid from public.phase_m54d_race_target where name = 'product_${key}');
      p_lot uuid := (select value::uuid from public.phase_m54d_race_target where name = 'lot_${key}');
      report_id uuid;
      line_id uuid;
      ev_id uuid := gen_random_uuid();
    begin
      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-${key}', 'storage', branch_id, 'submitted', 2, keeper_id,
        '${PREFIX}-${key}-key', '${PREFIX}-${key}-fp', 'race ${key}'
      ) returning id into report_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, lot_id, quantity_cases, damage_reason
      ) values (report_id, p_product, crate_id, p_lot, ${qty}, 'crushed')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id, lot_id,
        quantity_cases, hold_kind, status
      ) values (report_id, line_id, p_product, crate_id, p_lot, ${qty}, 'on_hand_deduction', 'active');
      insert into public.damage_evidence (
        id, damage_report_id, storage_path, mime_type, uploaded_by, verified_at
      ) values (
        ev_id, report_id, report_id::text || '/' || ev_id::text, 'image/jpeg', keeper_id, now()
      );
      insert into public.phase_m54d_race_target (name, value)
      values ('report_${key}', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = origin;
  `
}

async function raceReturnDispatch() {
  await psql(seedSubmittedHold("rd", 2, 2))
  await psql(createDispatchReady("rd", 2))
  const [x, y] = await raceTwo(
    "RD",
    asUser(
      "verifier",
      `
      ${waitBarrier("RD")}
      select public.return_damage_report(
        (select value::uuid from public.phase_m54d_race_target where name = 'report_rd'),
        2, 'race return vs dispatch'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("RD")}
      select public.confirm_dispatch(
        (select value::uuid from public.phase_m54d_race_target where name = 'dispatch_rd'),
        (select value::integer from public.phase_m54d_race_target where name = 'dispatch_ver_rd'),
        '${PREFIX}-cnf-rd'
      );
    `,
    ),
  )
  rejectDeadlock("return vs confirm_dispatch", x, y)
  if (x.code !== 0 || y.code !== 0) {
    throw new Error(`return vs dispatch first pass failed ${JSON.stringify([x, y])}`)
  }
  const status = (
    await psql(`
      select status from public.damage_reports
      where id = (select value::uuid from public.phase_m54d_race_target where name = 'report_rd')
    `)
  )
    .split(/\r?\n/)
    .filter(Boolean)
    .at(-1)
  if (status !== "returned") {
    throw new Error(`expected returned, got ${status}`)
  }
  const activeHolds = Number(
    await psql(`
      select count(*) from public.damage_stock_holds
      where damage_report_id = (select value::uuid from public.phase_m54d_race_target where name = 'report_rd')
        and status = 'active'
    `),
  )
  if (activeHolds !== 0) {
    throw new Error(`return left active holds ${activeHolds}`)
  }
  const consumed = Number(
    await psql(`
      select count(*) from public.stock_dispatch_requests
      where id = (select value::uuid from public.phase_m54d_race_target where name = 'dispatch_rd')
        and stock_consumed
    `),
  )
  if (consumed !== 1) throw new Error(`expected dispatch consumed, got ${consumed}`)
  const damageTx = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54d_race_target where name = 'report_rd')
    `),
  )
  if (damageTx !== 0) {
    throw new Error(`return posted stock ${damageTx}`)
  }
  await assertNoNegative()
  ok("return vs confirm_dispatch")
}

try {
  await setupShared()
  await raceVerifyVerify()
  await raceVerifyReturn()
  await raceVerifyReject()
  await raceWriteoffWriteoff()
  await raceWriteoffTransfer()
  await raceWriteoffPicking()
  await raceWriteoffDeact()
  await raceWriteoffDispatch()
  await raceReturnDispatch()
  console.log(`M5.4D concurrency passed ${passed.length}/9 races`)
} catch (error) {
  console.error(error)
  process.exitCode = 1
} finally {
  await psql(`
    set session_replication_role = replica;
    update public.stock_ledger set lot_id = null
    where product_id in (select id from public.products where sku like '${PREFIX}-%');
    delete from public.stock_ledger
    where product_id in (select id from public.products where sku like '${PREFIX}-%');
    delete from public.stock_balances
    where product_id in (select id from public.products where sku like '${PREFIX}-%')
       or crate_id in (
         select crates.id from public.crates
         join public.zones on zones.id = crates.zone_id
         join public.branches on branches.id = zones.branch_id
         where branches.code = '${PREFIX}_gd'
       );
    delete from public.stock_lot_balances
    where lot_id in (
      select id from public.stock_lots
      where product_id in (select id from public.products where sku like '${PREFIX}-%')
    );
    delete from public.stock_lots
    where product_id in (select id from public.products where sku like '${PREFIX}-%');
    update public.app_configuration set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    drop table if exists public.phase_m54d_barrier;
    drop table if exists public.phase_m54d_race_target;
    set session_replication_role = origin;
  `).catch((error) => {
    console.error("concurrency cleanup failed", error)
    process.exitCode = 1
  })
}
