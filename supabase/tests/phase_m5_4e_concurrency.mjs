/**
 * M5.4E exceptional request/approval/posting lock-order races. Local Docker only.
 * Dispatch pairings enable stock.lots.dual_write_enabled only for that seed;
 * cleanup restores it false. damage.stock_hold_ready stays false.
 * Shared Docker flags: run sequentially with other M5.2–M5.4E SQL/HTTP/concurrency
 * suites. A held advisory lock serializes this file against 4E SQL/HTTP.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m54ec_${RUN}`
const passed = []
const outcomes = []

function ok(name, detail = "first-pass serialized without deadlock") {
  passed.push(name)
  outcomes.push({ name, result: "passed", detail })
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

/** Holds the suite advisory lock in a dedicated psql session via pg_sleep. */
async function holdStockFlagLock() {
  const child = spawn("docker", [
    "exec",
    "supabase_db_sherlyos",
    "psql",
    "-U",
    "postgres",
    "-d",
    "postgres",
    "-v",
    "ON_ERROR_STOP=1",
    "-tA",
    "-c",
    "select pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests')); select pg_sleep(86400);",
  ])
  for (let i = 0; i < 50; i += 1) {
    const held = await psql(`
      select count(*)::text
      from pg_stat_activity
      where pid <> pg_backend_pid()
        and query like '%sherlyos.m5.stock_flag_tests%'
    `)
    if (Number(String(held).split(/\r?\n/).filter(Boolean).at(-1) ?? "0") > 0) {
      return {
        async release() {
          await psql(`
            select pg_terminate_backend(pid)
            from pg_stat_activity
            where pid <> pg_backend_pid()
              and query like '%sherlyos.m5.stock_flag_tests%'
          `).catch(() => undefined)
          child.kill()
        },
      }
    }
    await delay(100)
  }
  child.kill()
  throw new Error("flag lock timeout")
}

function asUser(userKey, body) {
  return `
    set local statement_timeout = '15s';
    set local role authenticated;
    select set_config('request.jwt.claim.sub', (select value from public.phase_m54e_race_target where name = '${userKey}'), true);
    select set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', (select value::uuid from public.phase_m54e_race_target where name = '${userKey}'),
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
        exit when coalesce((select open from public.phase_m54e_barrier where race = '${race}'), false);
        perform pg_sleep(0.02);
      end loop;
      if not coalesce((select open from public.phase_m54e_barrier where race = '${race}'), false) then
        raise exception 'barrier timeout for ${race}';
      end if;
    end $$;
  `
}

async function raceTwo(name, sqlA, sqlB) {
  await psql(`
    insert into public.phase_m54e_barrier (race, open)
    values ('${name}', false)
    on conflict (race) do update set open = false;
  `)
  const pending = Promise.all([
    session(`begin;\n${sqlA}\ncommit;`),
    session(`begin;\n${sqlB}\ncommit;`),
  ])
  await delay(800)
  await psql(
    `update public.phase_m54e_barrier set open = true where race = '${name}';`,
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

function enableLotDualWrite() {
  return `
    set session_replication_role = replica;
    update public.app_configuration set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    set session_replication_role = origin;
  `
}

function seedVerifiedHold(key, qty, leftover = 0) {
  const opening = qty + leftover
  return `
    do $$
    declare
      admin_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'admin');
      crate_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'crate');
      p_product uuid;
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      p_product := public.create_product('${PREFIX}-${key}', 'M54E ${key}', null, null);
      perform public.post_opening_stock(
        p_product, crate_id, ${opening}, '${PREFIX}-open-${key}', 'M54E ${key}'
      );
      insert into public.phase_m54e_race_target (name, value)
      values ('product_${key}', p_product::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = replica;
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'godown');
      crate_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'crate');
      branch_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'branch');
      p_product uuid := (select value::uuid from public.phase_m54e_race_target where name = 'product_${key}');
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
      insert into public.phase_m54e_race_target (name, value)
      values ('report_${key}', report_id::text)
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
      admin_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'admin');
      crate_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'crate');
      p_product uuid;
      selected_lot uuid;
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      p_product := public.create_product('${PREFIX}-${key}', 'M54E ${key}', null, null);
      perform public.set_product_expiry_policy(p_product, 'expiry_controlled');
      perform public.post_opening_stock(
        p_product, crate_id, ${opening}, '${PREFIX}-open-${key}', null, 'M54E-${key}', null, '2028-06-01'
      );
      select sl.id into selected_lot
      from public.stock_lots sl
      where sl.product_id = p_product
      order by sl.created_at
      limit 1;
      insert into public.phase_m54e_race_target (name, value) values
        ('product_${key}', p_product::text),
        ('lot_${key}', selected_lot::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
    set session_replication_role = replica;
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'godown');
      crate_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'crate');
      branch_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'branch');
      p_product uuid := (select value::uuid from public.phase_m54e_race_target where name = 'product_${key}');
      p_lot uuid := (select value::uuid from public.phase_m54e_race_target where name = 'lot_${key}');
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
      insert into public.phase_m54e_race_target (name, value)
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
      accounts_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'accounts');
      godown_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'godown');
      keeper_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'keeper');
      branch_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'branch');
      shop_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m54e_race_target where name = 'product_${key}');
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
      insert into public.phase_m54e_race_target (name, value) values
        ('order_${key}', order_id::text),
        ('dispatch_${key}', prepared ->> 'id'),
        ('dispatch_ver_${key}', prepared ->> 'version')
      on conflict (name) do update set value = excluded.value;
    end $$;
  `
}

async function seedRequested(key, qty = 2) {
  await psql(seedVerifiedHold(key, qty))
  await psql(`
    begin;
    ${asUser(
      "godown",
      `
      select public.request_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'report_${key}'),
        1, 'destroy', 'race request ${key}', '${PREFIX}-req-${key}'
      );
    `,
    )}
    commit;
  `)
  await psql(`
    insert into public.phase_m54e_race_target (name, value)
    select 'request_${key}', id::text
    from public.damage_exceptional_requests
    where request_idempotency_key = '${PREFIX}-req-${key}'
    on conflict (name) do update set value = excluded.value;
  `)
}

async function seedApproved(key, qty = 2, leftover = 0, lot = false) {
  await psql(lot ? seedLotVerifiedHold(key, qty, leftover) : seedVerifiedHold(key, qty, leftover))
  await psql(`
    begin;
    ${asUser(
      "godown",
      `
      select public.request_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'report_${key}'),
        1, 'destroy', 'race request ${key}', '${PREFIX}-req-${key}'
      );
    `,
    )}
    commit;
  `)
  await psql(`
    insert into public.phase_m54e_race_target (name, value)
    select 'request_${key}', id::text
    from public.damage_exceptional_requests
    where request_idempotency_key = '${PREFIX}-req-${key}'
    on conflict (name) do update set value = excluded.value;
  `)
  await psql(`
    begin;
    ${asUser(
      "admin",
      `
      select public.approve_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_${key}'),
        1
      );
    `,
    )}
    commit;
  `)
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
    drop table if exists public.phase_m54e_race_target;
    drop table if exists public.phase_m54e_barrier;
    create table public.phase_m54e_race_target (name text primary key, value text not null);
    create table public.phase_m54e_barrier (race text primary key, open boolean not null default false);
    grant select on public.phase_m54e_race_target to authenticated;
    grant select on public.phase_m54e_barrier to authenticated;

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
      branch_id := public.create_branch('${PREFIX}_gd', 'M54E Race Godown');
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(verifier_id, branch_id);
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      shop_id := public.create_shop('M54E Race Shop ${RUN}', null, null);
      p_product := public.create_product('${PREFIX}-base', 'M54E base', null, null);

      insert into public.phase_m54e_race_target (name, value) values
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

async function raceRequestRequest() {
  await psql(seedVerifiedHold("rr", 2))
  const [x, y] = await raceTwo(
    "RR",
    asUser(
      "godown",
      `
      ${waitBarrier("RR")}
      select public.request_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'report_rr'),
        1, 'destroy', 'race a', '${PREFIX}-req-rr-a'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("RR")}
      select public.request_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'report_rr'),
        1, 'return_supplier', 'race b', '${PREFIX}-req-rr-b'
      );
    `,
    ),
  )
  rejectDeadlock("request vs request", x, y)
  const open = Number(
    await psql(`
      select count(*) from public.damage_exceptional_requests
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_rr')
        and status in ('requested', 'approved')
    `),
  )
  if (open !== 1) {
    throw new Error(`request vs request open=${open} ${JSON.stringify([x, y])}`)
  }
  if (x.code === 0 && y.code === 0) {
    throw new Error("both concurrent requests succeeded")
  }
  ok("request vs request", "one open request, unique index rejected the other")
}

async function raceApproveReject() {
  await seedRequested("ar")
  const [x, y] = await raceTwo(
    "AR",
    asUser(
      "admin",
      `
      ${waitBarrier("AR")}
      select public.approve_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_ar'),
        1
      );
    `,
    ),
    asUser(
      "admin",
      `
      ${waitBarrier("AR")}
      select public.reject_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_ar'),
        1, 'race reject'
      );
    `,
    ),
  )
  rejectDeadlock("approve vs reject", x, y)
  const status = (
    await psql(`
      select status from public.damage_exceptional_requests
      where id = (select value::uuid from public.phase_m54e_race_target where name = 'request_ar')
    `)
  )
    .split(/\r?\n/)
    .filter(Boolean)
    .at(-1)
  if (!["approved", "rejected"].includes(status)) {
    throw new Error(`approve vs reject status=${status} ${JSON.stringify([x, y])}`)
  }
  if (x.code === 0 && y.code === 0) {
    throw new Error("approve and reject both committed")
  }
  ok("approve vs reject", `winner status=${status}`)
}

async function raceApprovePost() {
  await seedRequested("ap")
  const [x, y] = await raceTwo(
    "AP",
    asUser(
      "admin",
      `
      ${waitBarrier("AP")}
      select public.approve_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_ap'),
        1
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("AP")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_ap'),
        1, '${PREFIX}-post-ap'
      );
    `,
    ),
  )
  rejectDeadlock("approve vs post", x, y)
  const txns = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_ap')
        and damage_posting_kind = 'exceptional_writeoff'
    `),
  )
  if (txns > 1) throw new Error(`approve vs post over-posted ${txns}`)
  if (x.code === 0 && y.code === 0) {
    throw new Error("approve and unapproved post both committed")
  }
  await assertNoNegative()
  ok("approve vs post", `exceptional txns=${txns}; post used requested version`)
}

async function racePostPost() {
  await seedApproved("pp")
  const [x, y] = await raceTwo(
    "PP",
    asUser(
      "godown",
      `
      ${waitBarrier("PP")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_pp'),
        2, '${PREFIX}-post-pp-a'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("PP")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_pp'),
        2, '${PREFIX}-post-pp-b'
      );
    `,
    ),
  )
  rejectDeadlock("post vs post", x, y)
  const txns = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_pp')
        and damage_posting_kind = 'exceptional_writeoff'
    `),
  )
  if (txns !== 1) {
    throw new Error(`post vs post posted ${txns} ${JSON.stringify([x, y])}`)
  }
  await assertNoNegative()
  ok("post vs post exact-once", "request row lock serialized consume")
}

async function racePostOrdinary() {
  await seedApproved("po")
  const [x, y] = await raceTwo(
    "PO",
    asUser(
      "godown",
      `
      ${waitBarrier("PO")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_po'),
        2, '${PREFIX}-post-po'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("PO")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54e_race_target where name = 'report_po'),
        1, '${PREFIX}-wo-po'
      );
    `,
    ),
  )
  rejectDeadlock("exceptional vs ordinary", x, y)
  const kinds = await psql(`
    select string_agg(damage_posting_kind, ',' order by damage_posting_kind)
    from public.stock_transactions
    where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_po')
  `)
  const posted = kinds.split(/\r?\n/).filter(Boolean).at(-1) ?? ""
  if (posted.includes("ordinary_writeoff") && posted.includes("exceptional_writeoff")) {
    throw new Error(`both ordinary and exceptional posted ${posted}`)
  }
  await assertNoNegative()
  ok("exceptional post vs ordinary write-off", `kinds=${posted || "none"}`)
}

async function racePostTransfer() {
  await seedApproved("pt")
  const [x, y] = await raceTwo(
    "PT",
    asUser(
      "godown",
      `
      ${waitBarrier("PT")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_pt'),
        2, '${PREFIX}-post-pt'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("PT")}
      select public.transfer_verified_damage_to_quarantine(
        (select value::uuid from public.phase_m54e_race_target where name = 'report_pt'),
        1, '${PREFIX}-qrn-pt'
      );
    `,
    ),
  )
  rejectDeadlock("exceptional vs transfer", x, y)
  const txns = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_pt')
        and damage_posting_kind = 'exceptional_writeoff'
    `),
  )
  if (txns > 1) throw new Error(`transfer race over-posted exceptional ${txns}`)
  await assertNoNegative()
  ok("exceptional post vs quarantine transfer", `exceptional txns=${txns}`)
}

async function racePostPicking() {
  await seedApproved("pk", 2, 0)
  await psql(`
    do $$
    declare
      accounts_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'accounts');
      branch_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'branch');
      shop_id uuid := (select value::uuid from public.phase_m54e_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m54e_race_target where name = 'product_pk');
      order_id uuid;
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
      insert into public.phase_m54e_race_target (name, value)
      values ('order_pk', order_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  const [x, y] = await raceTwo(
    "PK",
    asUser(
      "godown",
      `
      ${waitBarrier("PK")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_pk'),
        2, '${PREFIX}-post-pk'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("PK")}
      select public.reserve_order_allocation(
        (select value::uuid from public.phase_m54e_race_target where name = 'order_pk'),
        3, '${PREFIX}-res-pk'
      );
    `,
    ),
  )
  rejectDeadlock("exceptional vs picking", x, y)
  const reserved = Number(
    await psql(`
      select coalesce(sum(reserved_cases),0) from public.stock_reservations
      where order_id = (select value::uuid from public.phase_m54e_race_target where name = 'order_pk')
        and status = 'active'
    `),
  )
  if (reserved > 0) {
    throw new Error(`picking reserved held stock reserved=${reserved} ${JSON.stringify([x, y])}`)
  }
  await assertNoNegative()
  ok("exceptional post vs picking", "held quantity stayed unreservable")
}

async function racePostDeact() {
  await seedApproved("deact")
  const [x, y] = await raceTwo(
    "DEACT",
    asUser(
      "godown",
      `
      ${waitBarrier("DEACT")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_deact'),
        2, '${PREFIX}-post-deact'
      );
    `,
    ),
    asUser(
      "admin",
      `
      ${waitBarrier("DEACT")}
      select public.set_branch_active(
        (select value::uuid from public.phase_m54e_race_target where name = 'branch'),
        false
      );
    `,
    ),
  )
  rejectDeadlock("exceptional vs deactivation", x, y)
  const wo = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_deact')
        and damage_posting_kind = 'exceptional_writeoff'
    `),
  )
  if (wo > 1) throw new Error(`deact over-post ${wo}`)
  await assertNoNegative()
  const afterRace = await session(`
    begin;
    ${asUser(
      "godown",
      `
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_deact'),
        2, '${PREFIX}-post-deact-again'
      );
    `,
    )}
    commit;
  `)
  const woAfter = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_deact')
        and damage_posting_kind = 'exceptional_writeoff'
    `),
  )
  if (woAfter > 1) throw new Error(`deact replay duplicated ${woAfter}`)
  if (wo === 0 && afterRace.code === 0) {
    throw new Error("inactive branch accepted a new exceptional posting")
  }
  await assertNoNegative()
  await psql(`
    begin;
    ${asUser(
      "admin",
      `
      select public.set_branch_active(
        (select value::uuid from public.phase_m54e_race_target where name = 'branch'),
        true
      );
    `,
    )}
    commit;
  `).catch(() => undefined)
  ok("exceptional post vs branch deactivation", `exceptional txns=${wo} after=${woAfter}`)
}

async function exceptionalTxnCount(key) {
  return Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_${key}')
        and damage_posting_kind = 'exceptional_writeoff'
    `),
  )
}

async function setRaceBranchActive(active) {
  await psql(`
    begin;
    ${asUser(
      "admin",
      `
      select public.set_branch_active(
        (select value::uuid from public.phase_m54e_race_target where name = 'branch'),
        ${active}
      );
    `,
    )}
    commit;
  `)
}

async function serialPostThenDeactReplay() {
  await seedApproved("pdr")
  await psql(`
    begin;
    ${asUser(
      "godown",
      `
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_pdr'),
        2, '${PREFIX}-post-pdr'
      );
    `,
    )}
    commit;
  `)
  if ((await exceptionalTxnCount("pdr")) !== 1) {
    throw new Error("serial post did not write exactly one exceptional txn")
  }
  await setRaceBranchActive(false)
  const replay = await session(`
    begin;
    ${asUser(
      "godown",
      `
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_pdr'),
        2, '${PREFIX}-post-pdr'
      );
    `,
    )}
    commit;
  `)
  if (replay.code === 0) {
    throw new Error("inactive GM completed-post replay returned payload")
  }
  if ((await exceptionalTxnCount("pdr")) !== 1) {
    throw new Error("replay after deactivation duplicated the ledger")
  }
  await assertNoNegative()
  await setRaceBranchActive(true)
  ok("post then deactivation replay is read-only", "txn=1 denied replay")
}

async function serialDeactThenPost() {
  await seedApproved("dpn")
  await setRaceBranchActive(false)
  const attempt = await session(`
    begin;
    ${asUser(
      "godown",
      `
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_dpn'),
        2, '${PREFIX}-post-dpn'
      );
    `,
    )}
    commit;
  `)
  if (attempt.code === 0) {
    throw new Error("posting after deactivation succeeded")
  }
  if ((await exceptionalTxnCount("dpn")) !== 0) {
    throw new Error("deactivation-before-post wrote a ledger row")
  }
  await assertNoNegative()
  await setRaceBranchActive(true)
  ok("deactivation before posting denies new posting", "txn=0")
}

async function racePostDispatch() {
  await seedApproved("dsp", 2, 2, true)
  await psql(createDispatchReady("dsp", 2))
  const [x, y] = await raceTwo(
    "DSP",
    asUser(
      "godown",
      `
      ${waitBarrier("DSP")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_dsp'),
        2, '${PREFIX}-post-dsp'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("DSP")}
      select public.confirm_dispatch(
        (select value::uuid from public.phase_m54e_race_target where name = 'dispatch_dsp'),
        (select value::integer from public.phase_m54e_race_target where name = 'dispatch_ver_dsp'),
        '${PREFIX}-cnf-dsp'
      );
    `,
    ),
  )
  rejectDeadlock("exceptional vs confirm_dispatch", x, y)
  const wo = Number(
    await psql(`
      select count(*) from public.stock_transactions
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_dsp')
        and damage_posting_kind = 'exceptional_writeoff'
    `),
  )
  const consumed = Number(
    await psql(`
      select count(*) from public.stock_dispatch_requests
      where id = (select value::uuid from public.phase_m54e_race_target where name = 'dispatch_dsp')
        and stock_consumed
    `),
  )
  if (wo > 1) throw new Error(`expected at most one exceptional post, got ${wo}`)
  if (x.code !== 0 && y.code !== 0) {
    throw new Error(`exceptional vs dispatch both failed ${JSON.stringify([x, y])}`)
  }
  await assertNoNegative()
  ok(
    "exceptional post vs confirm_dispatch",
    `exceptional=${wo} dispatch_consumed=${consumed} x=${x.code} y=${y.code}`,
  )
  await psql(`
    set session_replication_role = replica;
    update public.app_configuration set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;
  `)
}

async function racePostConsume() {
  await seedApproved("hc")
  const [x, y] = await raceTwo(
    "HC",
    asUser(
      "godown",
      `
      ${waitBarrier("HC")}
      select public.post_exceptional_damage_disposition(
        (select value::uuid from public.phase_m54e_race_target where name = 'request_hc'),
        2, '${PREFIX}-post-hc-a'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("HC")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m54e_race_target where name = 'report_hc'),
        1, '${PREFIX}-wo-hc'
      );
    `,
    ),
  )
  rejectDeadlock("exceptional vs hold consumption", x, y)
  const holds = Number(
    await psql(`
      select count(*) from public.damage_stock_holds
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_hc')
        and status in ('active', 'transferred')
    `),
  )
  const written = Number(
    await psql(`
      select count(*) from public.damage_stock_holds
      where damage_report_id = (select value::uuid from public.phase_m54e_race_target where name = 'report_hc')
        and status in ('written_off', 'returned_supplier')
    `),
  )
  if (holds > 0 && written > 0) {
    throw new Error("consumed hold reused alongside remaining active hold")
  }
  await assertNoNegative()
  ok("exceptional post vs hold consumption", `remaining=${holds} consumed=${written}`)
}

const flagLock = await holdStockFlagLock()
try {
  await setupShared()
  await raceRequestRequest()
  await raceApproveReject()
  await raceApprovePost()
  await racePostPost()
  await racePostOrdinary()
  await racePostTransfer()
  await racePostPicking()
  await racePostDeact()
  await serialPostThenDeactReplay()
  await serialDeactThenPost()
  await racePostDispatch()
  await racePostConsume()
  console.log(`M5.4E concurrency passed ${passed.length}/12 races`)
  for (const row of outcomes) {
    console.log(`RACE ${row.name}: ${row.result} (${row.detail})`)
  }
} catch (error) {
  console.error(error)
  process.exitCode = 1
} finally {
  try {
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
    drop table if exists public.phase_m54e_barrier;
    drop table if exists public.phase_m54e_race_target;
    set session_replication_role = origin;
  `).catch((error) => {
    console.error("concurrency cleanup failed", error)
    process.exitCode = 1
  })
  } finally {
    await flagLock.release()
  }
}
