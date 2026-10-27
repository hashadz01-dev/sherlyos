/**
 * M5.3A parallel races. Each pair uses independently committed docker/psql
 * sessions, an explicit barrier, and a 15s statement timeout.
 * Local Docker only. Restores cutover and hold flags in cleanup.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m53c_${RUN}`
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

function lastLine(text) {
  return String(text).split(/\r?\n/).filter(Boolean).at(-1) ?? ""
}

function asUser(userKey, body) {
  return `
    set local statement_timeout = '15s';
    set local role authenticated;
    select set_config('request.jwt.claim.sub', (select value from public.phase_m53_race_target where name = '${userKey}'), true);
    select set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', (select value::uuid from public.phase_m53_race_target where name = '${userKey}'),
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
        exit when coalesce((select open from public.phase_m53_barrier where race = '${race}'), false);
        perform pg_sleep(0.02);
      end loop;
      if not coalesce((select open from public.phase_m53_barrier where race = '${race}'), false) then
        raise exception 'barrier timeout for ${race}';
      end if;
    end $$;
  `
}

async function raceTwo(name, sqlA, sqlB) {
  await psql(`
    insert into public.phase_m53_barrier (race, open)
    values ('${name}', false)
    on conflict (race) do update set open = false;
  `)
  const pending = Promise.all([
    session(`begin;\n${sqlA}\ncommit;`),
    session(`begin;\n${sqlB}\ncommit;`),
  ])
  await delay(800)
  await psql(
    `update public.phase_m53_barrier set open = true where race = '${name}';`,
  )
  return pending
}

function negativeStockSql(productKey) {
  return `
    select count(*)::text from public.stock_balances sb
    join public.products p on p.id = sb.product_id
    where (p.sku like '${PREFIX}-%' or p.id = (
      select value::uuid from public.phase_m53_race_target where name = '${productKey}'
    )) and sb.quantity < 0;
  `
}

async function setupShared() {
  await psql(`
    drop table if exists public.phase_m53_race_target;
    drop table if exists public.phase_m53_barrier;
    create table public.phase_m53_race_target (name text primary key, value text not null);
    create table public.phase_m53_barrier (race text primary key, open boolean not null default false);
    grant select on public.phase_m53_race_target to authenticated;
    grant select on public.phase_m53_barrier to authenticated;

    set session_replication_role = replica;
    update public.app_configuration set value = 'true'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;

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
      crate_b uuid;
      shop_id uuid;
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
      select admin_id, roles.id, admin_id from public.roles where code = 'admin'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts_id, roles.id, admin_id from public.roles where code = 'accounts'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where code = 'godown_manager'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select verifier_id, roles.id, admin_id from public.roles where code = 'godown_manager'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select keeper_id, roles.id, admin_id from public.roles where code = 'store_keeper'
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);

      branch_id := public.create_branch('${PREFIX}_b', 'M53C');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(verifier_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      crate_b := public.create_crate(zone_id, '${PREFIX}_c2', 'C2', null);
      shop_id := public.create_shop('M53C shop', null, null);

      insert into public.phase_m53_race_target (name, value) values
        ('admin', admin_id::text),
        ('accounts', accounts_id::text),
        ('godown', godown_id::text),
        ('verifier', verifier_id::text),
        ('keeper', keeper_id::text),
        ('branch', branch_id::text),
        ('crate', crate_id::text),
        ('crate_b', crate_b::text),
        ('shop', shop_id::text);
    end $$;
  `)
}

function seedProductSql(key, qty) {
  return `
    do $$
    declare
      admin_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'admin');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      p_product uuid;
      selected_lot uuid;
    begin
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      p_product := public.create_product('${PREFIX}-${key}', 'M53C ${key}', null, null);
      perform public.set_product_expiry_policy(p_product, 'expiry_controlled');
      perform public.post_opening_stock(
        p_product, crate_id, ${qty}, '${PREFIX}-open-${key}', null, 'M53C-${key}', null, '2028-06-01'
      );
      select sl.id into selected_lot
      from public.stock_lots sl
      where sl.product_id = p_product
      order by sl.created_at
      limit 1;
      insert into public.phase_m53_race_target (name, value) values
        ('product_${key}', p_product::text),
        ('lot_${key}', selected_lot::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `
}

function attachPhotoSql(userKey, reportKey) {
  return `
    begin;
    set local statement_timeout = '15s';
    select set_config('request.jwt.claim.sub', (select value from public.phase_m53_race_target where name = '${userKey}'), true);
    select set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', (select value::uuid from public.phase_m53_race_target where name = '${userKey}'),
        'role', 'authenticated'
      )::text,
      true
    );
    do $$
    declare
      created jsonb;
      payload bytea := decode('ffd8ffd9', 'hex');
      target uuid := (select value::uuid from public.phase_m53_race_target where name = '${reportKey}');
    begin
      created := public.create_damage_photo_upload(target, 'count sheet');
      perform set_config('app.damage_write', 'on', true);
      update public.damage_evidence
      set
        mime_type = 'image/jpeg',
        file_size = octet_length(payload),
        verified_at = clock_timestamp()
      where id = (created ->> 'id')::uuid;
    end $$;
    commit;
  `
}

function createVerifiedOrderSql(key, qty, orderVersionOut) {
  return `
    do $$
    declare
      accounts_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'accounts');
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      keeper_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'keeper');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      shop_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_${key}');
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
      insert into public.phase_m53_race_target (name, value)
      values ('order_${key}', order_id::text)
      on conflict (name) do update set value = excluded.value;
      insert into public.phase_m53_race_target (name, value)
      values ('${orderVersionOut}', '3')
      on conflict (name) do update set value = excluded.value;

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
      insert into public.phase_m53_race_target (name, value) values
        ('picking_${key}', reserved ->> 'id'),
        ('dispatch_${key}', prepared ->> 'id'),
        ('dispatch_ver_${key}', prepared ->> 'version')
      on conflict (name) do update set value = excluded.value;
    end $$;
  `
}

async function assertNoNegative(productKey) {
  const n = Number(await psql(negativeStockSql(productKey)))
  if (n !== 0) throw new Error(`negative balances for ${productKey}: ${n}`)
}

async function raceA() {
  await psql(seedProductSql("a", 1))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      accounts_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'accounts');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      shop_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_a');
      selected_lot uuid := (select value::uuid from public.phase_m53_race_target where name = 'lot_a');
      report_id uuid;
      order_id uuid;
      payload jsonb;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-a'
        )), '${PREFIX}-a'
      ) ->> 'id')::uuid;
      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', p_product, 'requested_cases', 1)),
        '${PREFIX}-ord-a'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-osub-a');
      perform public.verify_order(order_id, 2, '${PREFIX}-over-a');
      payload := public.create_delivery_note(order_id, '${PREFIX}-dn-a');
      perform public.generate_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen-a');
      perform public.send_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-snd-a');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack-a');
      insert into public.phase_m53_race_target (name, value) values
        ('report_a', report_id::text),
        ('order_a', order_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  const [x, y] = await raceTwo(
    "A",
    asUser(
      "godown",
      `
      ${waitBarrier("A")}
      select public.submit_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_a'),
        1, '${PREFIX}-sa'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("A")}
      select public.reserve_order_allocation(
        (select value::uuid from public.phase_m53_race_target where name = 'order_a'),
        3, '${PREFIX}-res-a'
      );
    `,
    ),
  )
  const wins = [x, y].filter((row) => row.code === 0).length
  if (wins < 1)
    throw new Error(`A: expected at least one winner ${JSON.stringify([x, y])}`)
  const held = Number(
    await psql(`
    select coalesce(sum(quantity_cases),0) from public.damage_stock_holds
    where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_a')
      and status = 'active'
  `),
  )
  const reserved = Number(
    await psql(`
    select coalesce(sum(reserved_cases),0) from public.stock_reservations
    where order_id = (select value::uuid from public.phase_m53_race_target where name = 'order_a')
      and status = 'active'
  `),
  )
  if (held + reserved !== 1) {
    throw new Error(
      `A: oversubscription hold=${held} reserved=${reserved} sessions=${JSON.stringify([x, y])}`,
    )
  }
  await assertNoNegative("product_a")
  ok("A storage submit vs picking reservation")
}

async function raceB() {
  await psql(seedProductSql("b", 1))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_b');
      selected_lot uuid := (select value::uuid from public.phase_m53_race_target where name = 'lot_b');
      a uuid;
      b uuid;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      a := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-b1'
        )), '${PREFIX}-b1'
      ) ->> 'id')::uuid;
      b := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-b2'
        )), '${PREFIX}-b2'
      ) ->> 'id')::uuid;
      insert into public.phase_m53_race_target (name, value) values
        ('report_b1', a::text), ('report_b2', b::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  const [x, y] = await raceTwo(
    "B",
    asUser(
      "godown",
      `
      ${waitBarrier("B")}
      select public.submit_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_b1'),
        1, '${PREFIX}-sb1'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("B")}
      select public.submit_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_b2'),
        1, '${PREFIX}-sb2'
      );
    `,
    ),
  )
  const wins = [x, y].filter((row) => row.code === 0)
  const losses = [x, y].filter((row) => row.code !== 0)
  if (wins.length !== 1 || losses.length !== 1) {
    throw new Error(`B: expected one submit win ${JSON.stringify([x, y])}`)
  }
  if (!/insufficient unreserved stock/i.test(losses[0].text)) {
    throw new Error(`B: loser was not a stock conflict: ${losses[0].text}`)
  }
  const held = Number(
    await psql(`
    select coalesce(sum(quantity_cases),0) from public.damage_stock_holds
    where damage_report_id in (
      (select value::uuid from public.phase_m53_race_target where name = 'report_b1'),
      (select value::uuid from public.phase_m53_race_target where name = 'report_b2')
    ) and status = 'active'
  `),
  )
  if (held !== 1) throw new Error(`B: expected one active hold, got ${held}`)
  await assertNoNegative("product_b")
  ok("B two storage submits on one carton")
}

async function raceC() {
  await psql(seedProductSql("c", 2))
  await psql(createVerifiedOrderSql("c", 2, "order_ver_c"))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_c');
      picking uuid := (select value::uuid from public.phase_m53_race_target where name = 'picking_c');
      dispatch uuid := (select value::uuid from public.phase_m53_race_target where name = 'dispatch_c');
      report_id uuid;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'loading', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id,
          'quantity_cases', 1, 'damage_reason', 'crush'
        )), '${PREFIX}-c', null, null, picking, dispatch
      ) ->> 'id')::uuid;
      insert into public.phase_m53_race_target (name, value)
      values ('report_c', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  const [x, y] = await raceTwo(
    "C",
    asUser(
      "godown",
      `
      ${waitBarrier("C")}
      select public.submit_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_c'),
        1, '${PREFIX}-sc'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("C")}
      select public.confirm_dispatch(
        (select value::uuid from public.phase_m53_race_target where name = 'dispatch_c'),
        (select value::integer from public.phase_m53_race_target where name = 'dispatch_ver_c'),
        '${PREFIX}-cfm-c'
      );
    `,
    ),
  )
  const dispatchCount = Number(
    await psql(`
    select count(*) from public.stock_transactions
    where dispatch_request_id = (select value::uuid from public.phase_m53_race_target where name = 'dispatch_c')
      and transaction_type = 'DISPATCH'
  `),
  )
  if (dispatchCount > 1)
    throw new Error(
      `C: double DISPATCH ${dispatchCount} ${JSON.stringify([x, y])}`,
    )
  const held = Number(
    await psql(`
    select coalesce(sum(quantity_cases),0) from public.damage_stock_holds
    where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_c')
      and status in ('active', 'written_off', 'transferred')
  `),
  )
  const consumed = Number(
    await psql(`
    select coalesce(sum(reserved_cases),0) from public.stock_reservations
    where picking_request_id = (select value::uuid from public.phase_m53_race_target where name = 'picking_c')
      and status = 'consumed'
  `),
  )
  if (held + consumed !== 2 && !(held === 0 && consumed === 2)) {
    throw new Error(
      `C: qty mismatch hold=${held} consumed=${consumed} sessions=${JSON.stringify([x, y])}`,
    )
  }
  if (held === 1 && consumed !== 1 && dispatchCount !== 1) {
    throw new Error(
      `C: partial loading must leave one DISPATCH of remaining qty`,
    )
  }
  await assertNoNegative("product_c")
  ok("C loading hold conversion vs confirm_dispatch")
}

async function raceD() {
  await psql(seedProductSql("d", 1))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      verifier_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'verifier');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_d');
      selected_lot uuid := (select value::uuid from public.phase_m53_race_target where name = 'lot_d');
      report_id uuid;
      payload jsonb;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-d'
        )), '${PREFIX}-d'
      ) ->> 'id')::uuid;
      payload := public.submit_damage_report(report_id, 1, '${PREFIX}-sd');
      insert into public.phase_m53_race_target (name, value) values
        ('report_d', report_id::text),
        ('report_d_ver', payload ->> 'version')
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  await psql(attachPhotoSql("verifier", "report_d"))
  await psql(`
    begin;
    ${asUser(
      "verifier",
      `
      select public.verify_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_d'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_d'))
      );
    `,
    )}
    commit;
  `)
  const [x, y] = await raceTwo(
    "D",
    asUser(
      "verifier",
      `
      ${waitBarrier("D")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m53_race_target where name = 'report_d'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_d')),
        '${PREFIX}-wo-d1'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("D")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m53_race_target where name = 'report_d'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_d')),
        '${PREFIX}-wo-d2'
      );
    `,
    ),
  )
  const wins = [x, y].filter((row) => row.code === 0).length
  if (wins < 1)
    throw new Error(`D: no write-off succeeded ${JSON.stringify([x, y])}`)
  const posted = Number(
    await psql(`
    select count(*) from public.stock_transactions
    where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_d')
      and damage_posting_kind = 'ordinary_writeoff'
  `),
  )
  if (posted !== 1)
    throw new Error(
      `D: expected exact-once write-off, got ${posted} ${JSON.stringify([x, y])}`,
    )
  await assertNoNegative("product_d")
  ok("D two ordinary write-offs for the same report")
}

async function raceE() {
  await psql(seedProductSql("e", 1))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      verifier_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'verifier');
      admin_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'admin');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_e');
      selected_lot uuid := (select value::uuid from public.phase_m53_race_target where name = 'lot_e');
      report_id uuid;
      req_id uuid;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-e'
        )), '${PREFIX}-e'
      ) ->> 'id')::uuid;
      perform public.submit_damage_report(report_id, 1, '${PREFIX}-se');
      insert into public.phase_m53_race_target (name, value)
      values ('report_e', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  await psql(attachPhotoSql("verifier", "report_e"))
  await psql(`
    begin;
    ${asUser(
      "verifier",
      `
      select public.verify_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_e'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_e'))
      );
      select public.request_exceptional_damage_disposition(
        (select value::uuid from public.phase_m53_race_target where name = 'report_e'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_e')),
        'destroy', 'destroy leaking carton', '${PREFIX}-ex-req'
      );
    `,
    )}
    commit;
  `)
  await psql(`
    begin;
    ${asUser(
      "admin",
      `
      select public.approve_exceptional_damage_disposition(
        (select id from public.damage_exceptional_requests
          where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_e')
          order by requested_at desc limit 1),
        1
      );
    `,
    )}
    commit;
  `)
  const [x, y] = await raceTwo(
    "E",
    asUser(
      "verifier",
      `
      ${waitBarrier("E")}
      select public.post_exceptional_damage_disposition(
        (select id from public.damage_exceptional_requests
          where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_e')
          order by requested_at desc limit 1),
        (select version from public.damage_exceptional_requests
          where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_e')
          order by requested_at desc limit 1),
        '${PREFIX}-ex-post-1'
      );
    `,
    ),
    asUser(
      "verifier",
      `
      ${waitBarrier("E")}
      select public.post_exceptional_damage_disposition(
        (select id from public.damage_exceptional_requests
          where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_e')
          order by requested_at desc limit 1),
        (select version from public.damage_exceptional_requests
          where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_e')
          order by requested_at desc limit 1),
        '${PREFIX}-ex-post-2'
      );
    `,
    ),
  )
  const posted = Number(
    await psql(`
    select count(*) from public.stock_transactions
    where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_e')
      and damage_posting_kind = 'exceptional_writeoff'
  `),
  )
  if (posted !== 1)
    throw new Error(
      `E: expected exact-once exceptional post, got ${posted} ${JSON.stringify([x, y])}`,
    )
  await assertNoNegative("product_e")
  ok("E two exceptional postings for the same approval")
}

async function raceF() {
  await psql(seedProductSql("f", 1))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      shop_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_f');
      report_id uuid;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'shop_return', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'quantity_cases', 1, 'damage_reason', 'expired'
        )), '${PREFIX}-f', null, null, null, null, null, shop_id
      ) ->> 'id')::uuid;
      perform public.confirm_shop_return_custody(report_id, 1);
      insert into public.phase_m53_race_target (name, value)
      values ('report_f', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  const [x, y] = await raceTwo(
    "F",
    asUser(
      "godown",
      `
      ${waitBarrier("F")}
      select public.submit_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_f'),
        2, '${PREFIX}-sf'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("F")}
      select public.submit_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_f'),
        2, '${PREFIX}-sf'
      );
    `,
    ),
  )
  const wins = [x, y].filter((row) => row.code === 0).length
  if (wins < 1)
    throw new Error(
      `F: no shop-return submit succeeded ${JSON.stringify([x, y])}`,
    )
  const intake = Number(
    await psql(`
    select count(*) from public.stock_transactions
    where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_f')
      and damage_posting_kind = 'quarantine_intake'
  `),
  )
  if (intake !== 1)
    throw new Error(
      `F: expected one quarantine intake, got ${intake} ${JSON.stringify([x, y])}`,
    )
  await assertNoNegative("product_f")
  ok("F shop-return intake replay with identical idempotency key")
}

async function raceG() {
  await psql(seedProductSql("g", 1))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_g');
      selected_lot uuid := (select value::uuid from public.phase_m53_race_target where name = 'lot_g');
      report_id uuid;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-g'
        )), '${PREFIX}-g'
      ) ->> 'id')::uuid;
      perform public.submit_damage_report(report_id, 1, '${PREFIX}-sg');
      insert into public.phase_m53_race_target (name, value)
      values ('report_g', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  await psql(attachPhotoSql("verifier", "report_g"))
  await psql(`
    begin;
    ${asUser(
      "verifier",
      `
      select public.verify_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_g'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_g'))
      );
    `,
    )}
    commit;
  `)
  const [x, y] = await raceTwo(
    "G",
    asUser(
      "verifier",
      `
      ${waitBarrier("G")}
      select public.post_ordinary_damage_writeoff(
        (select value::uuid from public.phase_m53_race_target where name = 'report_g'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_g')),
        '${PREFIX}-wo-g'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("G")}
      select public.post_crate_transfer(
        (select value::uuid from public.phase_m53_race_target where name = 'product_g'),
        (select value::uuid from public.phase_m53_race_target where name = 'crate'),
        (select value::uuid from public.phase_m53_race_target where name = 'crate_b'),
        1, '${PREFIX}-xfer-g', null,
        jsonb_build_array(jsonb_build_object(
          'lot_id', (select value::uuid from public.phase_m53_race_target where name = 'lot_g'),
          'quantity', 1
        ))
      );
    `,
    ),
  )
  const writeoffs = Number(
    await psql(`
    select count(*) from public.stock_transactions
    where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_g')
      and damage_posting_kind = 'ordinary_writeoff'
  `),
  )
  const dest = Number(
    await psql(`
    select coalesce(sum(quantity),0) from public.stock_balances
    where crate_id = (select value::uuid from public.phase_m53_race_target where name = 'crate_b')
      and product_id = (select value::uuid from public.phase_m53_race_target where name = 'product_g')
  `),
  )
  if (writeoffs !== 1)
    throw new Error(
      `G: write-off not exact-once (${writeoffs}) ${JSON.stringify([x, y])}`,
    )
  if (dest !== 0)
    throw new Error(
      `G: held carton must not transfer, dest=${dest} ${JSON.stringify([x, y])}`,
    )
  await assertNoNegative("product_g")
  ok("G hold release vs ordinary stock writer")
}

async function raceH() {
  await psql(seedProductSql("h", 2))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      accounts_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'accounts');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      shop_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'shop');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_h');
      selected_lot uuid := (select value::uuid from public.phase_m53_race_target where name = 'lot_h');
      report_id uuid;
      order_id uuid;
      payload jsonb;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-h'
        )), '${PREFIX}-h'
      ) ->> 'id')::uuid;
      perform public.submit_damage_report(report_id, 1, '${PREFIX}-sh');
      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', p_product, 'requested_cases', 1)),
        '${PREFIX}-ord-h'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-osub-h');
      perform public.verify_order(order_id, 2, '${PREFIX}-over-h');
      payload := public.create_delivery_note(order_id, '${PREFIX}-dn-h');
      perform public.generate_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen-h');
      perform public.send_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-snd-h');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note((payload -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack-h');
      insert into public.phase_m53_race_target (name, value) values
        ('report_h', report_id::text),
        ('order_h', order_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  await psql(attachPhotoSql("verifier", "report_h"))
  await psql(`
    begin;
    ${asUser(
      "verifier",
      `
      select public.verify_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_h'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_h'))
      );
    `,
    )}
    commit;
  `)
  const [x, y] = await raceTwo(
    "H",
    asUser(
      "verifier",
      `
      ${waitBarrier("H")}
      select public.transfer_verified_damage_to_quarantine(
        (select value::uuid from public.phase_m53_race_target where name = 'report_h'),
        (select version from public.damage_reports
          where id = (select value::uuid from public.phase_m53_race_target where name = 'report_h')),
        '${PREFIX}-qrn-h'
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("H")}
      select public.reserve_order_allocation(
        (select value::uuid from public.phase_m53_race_target where name = 'order_h'),
        3, '${PREFIX}-res-h'
      );
    `,
    ),
  )
  const reserved = Number(
    await psql(`
    select coalesce(sum(reserved_cases),0) from public.stock_reservations
    where order_id = (select value::uuid from public.phase_m53_race_target where name = 'order_h')
      and status = 'active'
  `),
  )
  if (reserved > 1)
    throw new Error(
      `H: reserved held stock reserved=${reserved} ${JSON.stringify([x, y])}`,
    )
  const qrn = Number(
    await psql(`
    select coalesce(sum(sb.quantity),0)
    from public.stock_balances sb
    join public.crates c on c.id = sb.crate_id
    where sb.product_id = (select value::uuid from public.phase_m53_race_target where name = 'product_h')
      and c.location_role = 'quarantine'
  `),
  )
  const transferWon = y.code === 0 || x.code === 0
  if (!transferWon && qrn === 0 && reserved === 0) {
    throw new Error(
      `H: neither transfer nor reserve succeeded ${JSON.stringify([x, y])}`,
    )
  }
  if (qrn > 1) throw new Error(`H: quarantine over-intake ${qrn}`)
  await assertNoNegative("product_h")
  ok("H quarantine transfer vs picking reservation")
}

async function raceI() {
  await psql(seedProductSql("i", 1))
  await psql(`
    do $$
    declare
      godown_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'godown');
      branch_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'branch');
      crate_id uuid := (select value::uuid from public.phase_m53_race_target where name = 'crate');
      p_product uuid := (select value::uuid from public.phase_m53_race_target where name = 'product_i');
      selected_lot uuid := (select value::uuid from public.phase_m53_race_target where name = 'lot_i');
      report_id uuid;
    begin
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      report_id := (public.create_damage_report(
        'storage', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', p_product, 'crate_id', crate_id, 'lot_id', selected_lot,
          'quantity_cases', 1, 'damage_reason', 'race-i'
        )), '${PREFIX}-i'
      ) ->> 'id')::uuid;
      insert into public.phase_m53_race_target (name, value)
      values ('report_i', report_id::text)
      on conflict (name) do update set value = excluded.value;
    end $$;
  `)
  const [x, y] = await raceTwo(
    "I",
    asUser(
      "admin",
      `
      ${waitBarrier("I")}
      select public.set_branch_active(
        (select value::uuid from public.phase_m53_race_target where name = 'branch'),
        false
      );
    `,
    ),
    asUser(
      "godown",
      `
      ${waitBarrier("I")}
      select public.submit_damage_report(
        (select value::uuid from public.phase_m53_race_target where name = 'report_i'),
        1, '${PREFIX}-si'
      );
    `,
    ),
  )
  const held = Number(
    await psql(`
    select coalesce(sum(quantity_cases),0) from public.damage_stock_holds
    where damage_report_id = (select value::uuid from public.phase_m53_race_target where name = 'report_i')
      and status = 'active'
  `),
  )
  const active = lastLine(
    await psql(`
    select is_active::text from public.branches
    where id = (select value::uuid from public.phase_m53_race_target where name = 'branch')
  `),
  )
  if (held > 1) throw new Error(`I: hold oversubscription ${held}`)
  if (active === "f" && held === 1 && y.code === 0 && x.code === 0) {
    // Submit committed first, then deactivate. Hold is valid because the godown
    // was active at isolation time.
  } else if (held === 1 && y.code !== 0) {
    throw new Error(
      `I: hold exists but submit reported failure ${JSON.stringify([x, y])}`,
    )
  } else if (held === 0 && y.code === 0) {
    throw new Error(
      `I: submit succeeded without a hold ${JSON.stringify([x, y])}`,
    )
  }
  await assertNoNegative("product_i")
  await psql(`
    begin;
    ${asUser(
      "admin",
      `
      select public.set_branch_active(
        (select value::uuid from public.phase_m53_race_target where name = 'branch'),
        true
      );
    `,
    )}
    commit;
  `).catch(() => undefined)
  ok("I godown deactivation vs damage stock posting")
}

const onlyRace = process.env.M53_ONLY || ""

let productFilter = "00000000-0000-0000-0000-000000000000"
try {
  await setupShared()
  if (onlyRace === "C") {
    await raceC()
  } else {
    await raceA()
    await raceB()
    await raceC()
    await raceD()
    await raceE()
    await raceF()
    await raceG()
    await raceH()
    await raceI()
  }
  productFilter = lastLine(
    await psql(`
    select coalesce(string_agg(id::text, ''','''), '${productFilter}')
    from public.products where sku like '${PREFIX}-%'
  `),
  )
  if (onlyRace === "C") {
    console.log("M5.3 race C passed")
  } else {
    console.log(`M5.3 concurrency passed ${passed.length}/9 races`)
  }
} catch (error) {
  console.error(error)
  process.exitCode = 1
} finally {
  await psql(`
    set session_replication_role = replica;
    update public.stock_ledger set lot_id = null
    where product_id in (select id from public.products where sku like '${PREFIX}-%');
    delete from public.stock_balances
    where product_id in (select id from public.products where sku like '${PREFIX}-%');
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
    drop table if exists public.phase_m53_barrier;
    drop table if exists public.phase_m53_race_target;
    set session_replication_role = origin;
  `).catch((error) => {
    console.error("concurrency cleanup failed", error)
    process.exitCode = 1
  })
}
