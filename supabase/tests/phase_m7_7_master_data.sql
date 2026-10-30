-- M7.7 master-data RPC guards. Rolls back.
-- Does not import the Sherlys catalogue and does not flip operational flags.
-- Run: Get-Content supabase/tests/phase_m7_7_master_data.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new,
  email_change_token_current, reauthentication_token, email_change
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m77@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now(),
  replace(gen_random_uuid()::text, '-', '') || 'c',
  replace(gen_random_uuid()::text, '-', '') || 'r',
  replace(gen_random_uuid()::text, '-', '') || 'n',
  replace(gen_random_uuid()::text, '-', '') || 'e',
  replace(gen_random_uuid()::text, '-', '') || 'a',
  ''
from fixture;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true from fixture
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name when 'admin' then 'admin' else 'salesperson' end
on conflict do nothing;

do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  sales_id uuid := (select id from fixture where name = 'sales');
  category_id uuid;
  supplier_id uuid;
  product_id uuid;
  ledger_before bigint;
  balance_before bigint;
  price_before bigint;
  flag_before integer;
begin
  select count(*) into ledger_before from public.stock_ledger;
  select count(*) into balance_before from public.stock_balances;
  select count(*) into price_before from public.product_selling_prices;
  select count(*) into flag_before
  from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  ) and value = 'true'::jsonb;
  if flag_before is distinct from 0 then
    raise exception 'operational flags must remain false';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  category_id := public.create_product_category('M77 Tea & Tea Bags', 'Catalogue code TEA.');
  begin
    perform public.create_product_category('M77 Tea & Tea Bags', 'duplicate');
    raise exception 'duplicate category was accepted';
  exception
    when unique_violation then
      null;
  end;

  supplier_id := public.create_supplier('M77 AVT (pending invoicing confirmation)', null, null);
  perform public.set_supplier_active(supplier_id, false);

  begin
    perform public.create_product('M77-PENDING-SUP', 'M77 blocked product', supplier_id, category_id);
    raise exception 'inactive supplier was accepted';
  exception
    when insufficient_privilege then
      null;
  end;

  product_id := public.create_product('M77-PREM-DUST-100G', 'M77 AVT Premium Tea Dust 100g', null, category_id);
  perform public.set_product_billing_conversion(product_id, 'nos', 240);

  begin
    perform public.create_product('M77-PREM-DUST-100G', 'Again', null, category_id);
    raise exception 'duplicate SKU was accepted';
  exception
    when unique_violation then
      null;
  end;

  perform set_config('request.jwt.claim.sub', sales_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', sales_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.create_product('M77-SALES-SKU', 'Sales product', null, null);
    raise exception 'salesperson product create was accepted';
  exception
    when insufficient_privilege then
      null;
  end;

  if (select count(*) from public.stock_ledger) is distinct from ledger_before
    or (select count(*) from public.stock_balances) is distinct from balance_before
    or (select count(*) from public.product_selling_prices) is distinct from price_before
  then
    raise exception 'master-data RPC test changed stock or prices';
  end if;

  if exists (
    select 1 from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  ) then
    raise exception 'operational flags changed';
  end if;
end;
$$;

rollback;
