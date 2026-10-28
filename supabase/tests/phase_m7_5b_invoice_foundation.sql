-- M7.5B. Pricing overlap, conversion, statutory gate, and privilege proofs.
-- Rolls back. Does not post stock, finalize invoices, or flip operational flags.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('driver', gen_random_uuid()),
  ('product', gen_random_uuid()),
  ('shop', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m75b@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from fixture
where fixture.name in ('admin', 'accounts', 'godown', 'driver');

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'm75b ' || fixture.name, true
from fixture
where fixture.name in ('admin', 'accounts', 'godown', 'driver')
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name
    when 'admin' then 'admin'
    when 'accounts' then 'accounts'
    when 'godown' then 'godown_manager'
    when 'driver' then 'delivery_person'
  end
where fixture.name in ('admin', 'accounts', 'godown', 'driver')
on conflict do nothing;

insert into public.products (id, sku, name, is_active)
select id, 'm75b-sql-sku', 'M75B SQL product', true
from fixture
where name = 'product';

insert into public.shops (id, name, is_active)
select id, 'M75B SQL shop', true
from fixture
where name = 'shop';

do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  accounts_id uuid := (select id from fixture where name = 'accounts');
  driver_id uuid := (select id from fixture where name = 'driver');
  product_id uuid := (select id from fixture where name = 'product');
  shop_id uuid := (select id from fixture where name = 'shop');
  price_id uuid;
  readiness jsonb;
  listed jsonb;
begin
  if exists (
    select 1
    from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    )
      and value = 'true'::jsonb
  ) then
    raise exception 'operational stock flags must remain false';
  end if;

  if to_regprocedure('public.finalize_invoice_note(uuid, integer)') is not null
    or to_regprocedure('public.issue_tax_invoice(uuid, integer)') is not null
  then
    raise exception 'statutory invoice finalization RPC must not exist';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);

  begin
    insert into public.product_selling_prices (
      product_id, unit_amount, effective_from
    ) values (product_id, 10, current_date);
    raise exception 'direct price insert must be blocked';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  perform public.set_product_billing_conversion(product_id, 'nos', 12);

  price_id := (public.upsert_product_selling_price(
    product_id, null, 10.5, current_date, null, null
  ) ->> 'id')::uuid;

  begin
    perform public.upsert_product_selling_price(
      product_id, null, 11, current_date, current_date + 10, null
    );
    raise exception 'overlapping default prices must fail closed';
  exception
    when others then
      if sqlerrm not ilike '%overlap%' then
        raise;
      end if;
  end;

  perform public.upsert_product_selling_price(
    product_id, shop_id, 9.25, current_date, null, null
  );

  -- Private resolver is revoked from authenticated; check as the table owner.
  reset role;
  if (
    select price_scope
    from app_private.resolve_selling_price(product_id, shop_id, current_date)
  ) is distinct from 'shop' then
    raise exception 'shop-specific price must win over default';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);

  readiness := public.assess_invoice_finalization_readiness();
  if coalesce(readiness ->> 'ready', 'true') is distinct from 'false' then
    raise exception 'statutory readiness must stay false';
  end if;
  if readiness -> 'blockers' is null or jsonb_array_length(readiness -> 'blockers') < 4 then
    raise exception 'accountant blockers must be present';
  end if;

  perform set_config('request.jwt.claim.sub', driver_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', driver_id, 'role', 'authenticated')::text,
    true
  );

  begin
    listed := public.list_invoice_notes(null, null, null);
    raise exception 'driver must not list invoice notes';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', accounts_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', accounts_id, 'role', 'authenticated')::text,
    true
  );

  begin
    perform public.prepare_invoice_note(
      gen_random_uuid(), 'm75b-sql', 1, null
    );
    raise exception 'accounts must not prepare invoice notes';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'accounts'
      and permissions.code = 'invoices.review'
  ) then
    raise exception 'accounts must have invoices.review';
  end if;
end;
$$;

rollback;
