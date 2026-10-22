-- Phase 4.3E.1A local disposable checks (rollback). Does not leave seed active.
-- Covers M1 orphan rejection, dual_write enable denial, freeze, conservation.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase43e1a@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'),
      'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values ((select id from fixture where name = 'admin'), 'Phase 4.3E.1A Admin', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select
        (select id from fixture where name = 'admin'),
        roles.id,
        (select id from fixture where name = 'admin')
      from public.roles
      where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true
from fixture
where fixture.name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = 'godown_manager'
where fixture.name = 'godown'
on conflict do nothing;

-- dual_write cannot be enabled prematurely
do $$
begin
  begin
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    raise exception 'dual_write_enabled=true should be rejected';
  exception
    when sqlstate '55000' then null;
  end;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('p43e1a', 'Phase 4.3E.1A')::text, true);
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch')::uuid
);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'z43e1a', 'Z43E1A', null)::text,
  true
);
select set_config(
  'sherlyos.crate',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43e1a', 'C43E1A', null)::text,
  true
);
select set_config(
  'sherlyos.product',
  public.create_product('p43e1a-soap', 'Phase 4.3E.1A Soap', null, null)::text,
  true
);

select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  5,
  'p43e1a-open-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  'pre-seed'
);

reset role;

-- M1: orphan lot balance (incl. zero qty) must block seed for that grain
do $$
declare
  orphan_lot uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  branch uuid := current_setting('sherlyos.branch')::uuid;
begin
  insert into public.stock_lots (
    product_id, branch_id, status, origin, created_by
  )
  values (
    product,
    branch,
    'available',
    'opening',
    (select id from fixture where name = 'admin')
  )
  returning id into orphan_lot;

  insert into public.stock_lot_balances (lot_id, crate_id, quantity)
  values (orphan_lot, crate, 0);
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.seed_legacy_stock_lots();
    raise exception 'seed should refuse orphan lot balances';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%unexpected existing lot balances%' then
        raise exception 'expected orphan rejection, got %', sqlerrm;
      end if;
  end;
end $$;

reset role;

-- Remove orphan and seed successfully
delete from public.stock_lot_balances
where crate_id = current_setting('sherlyos.crate')::uuid;
delete from public.stock_lots
where product_id = current_setting('sherlyos.product')::uuid
  and origin = 'opening';

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
declare
  result jsonb;
  ledger_before integer;
  ledger_after integer;
  bal integer;
  lot_sum integer;
begin
  select count(*)::integer into ledger_before from public.stock_ledger;

  result := public.seed_legacy_stock_lots();
  if coalesce((result ->> 'aggregate_only_blocked')::boolean, false) is not true then
    raise exception 'seed must set aggregate_only_blocked';
  end if;

  select quantity into bal
  from public.stock_balances
  where crate_id = current_setting('sherlyos.crate')::uuid
    and product_id = current_setting('sherlyos.product')::uuid;

  select coalesce(sum(slb.quantity), 0)::integer into lot_sum
  from public.stock_lot_balances slb
  join public.stock_lots sl on sl.id = slb.lot_id
  where slb.crate_id = current_setting('sherlyos.crate')::uuid
    and sl.product_id = current_setting('sherlyos.product')::uuid;

  if bal is distinct from lot_sum then
    raise exception 'conservation failed aggregate % lot_sum %', bal, lot_sum;
  end if;

  select count(*)::integer into ledger_after from public.stock_ledger;
  if ledger_after <> ledger_before then
    raise exception 'seed must not mutate ledger';
  end if;

  -- idempotent
  result := public.seed_legacy_stock_lots();
  if (result ->> 'seeded')::integer <> 0 then
    raise exception 'idempotent seed created lots';
  end if;
end $$;

-- Freeze: new opening on a different product hits apply_stock_delta guard (55000)
select set_config(
  'sherlyos.product_freeze',
  public.create_product('p43e1a-freeze', 'Phase 4.3E.1A Freeze', null, null)::text,
  true
);

do $$
declare
  other_crate uuid;
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product_freeze')::uuid,
      current_setting('sherlyos.crate')::uuid,
      1,
      'p43e1a-blocked-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
      'blocked'
    );
    raise exception 'post-seed opening should freeze';
  exception
    when sqlstate '55000' then null;
  end;

  other_crate := public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43e1a2', 'C43E1A2', null);
  begin
    perform public.post_crate_transfer(
      current_setting('sherlyos.product')::uuid,
      current_setting('sherlyos.crate')::uuid,
      other_crate,
      1,
      'p43e1a-xfer-blocked-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
      'blocked'
    );
    raise exception 'post-seed transfer should freeze';
  exception
    when sqlstate '55000' then null;
  end;
end $$;

reset role;

-- GM denied
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.seed_legacy_stock_lots();
    raise exception 'GM must not seed';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;

select 'phase_4_3e1a_lock_order_hardening ok' as result;

rollback;
