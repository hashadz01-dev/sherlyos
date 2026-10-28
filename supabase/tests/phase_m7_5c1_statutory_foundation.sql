-- M7.5C.1 statutory configuration proofs.
-- Rolls back. Does not calculate GST, allocate invoice numbers, finalize invoices,
-- or flip operational flags.

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
  ('verifier', gen_random_uuid()),
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
  fixture.name || '.m75c1@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from fixture
where fixture.name in ('admin', 'accounts', 'godown', 'verifier');

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'm75c1 ' || fixture.name, true
from fixture
where fixture.name in ('admin', 'accounts', 'godown', 'verifier')
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name
    when 'admin' then 'admin'
    when 'accounts' then 'accounts'
    when 'godown' then 'godown_manager'
    when 'verifier' then 'statutory_verifier'
  end
where fixture.name in ('admin', 'accounts', 'godown', 'verifier')
on conflict do nothing;

insert into public.products (id, sku, name, is_active)
select id, 'm75c1-sql-sku', 'M75C1 SQL product', true
from fixture
where name = 'product';

insert into public.shops (id, name, is_active)
select id, 'M75C1 SQL shop', true
from fixture
where name = 'shop';

do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  accounts_id uuid := (select id from fixture where name = 'accounts');
  godown_id uuid := (select id from fixture where name = 'godown');
  verifier_id uuid := (select id from fixture where name = 'verifier');
  product_id uuid := (select id from fixture where name = 'product');
  shop_id uuid := (select id from fixture where name = 'shop');
  seller jsonb;
  shop_tax jsonb;
  hsn jsonb;
  rate jsonb;
  policy jsonb;
  readiness jsonb;
  codes text;
  kind text;
  ownership text;
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
    or to_regprocedure('public.allocate_statutory_invoice_number(text)') is not null
  then
    raise exception 'statutory invoice issuance RPC must not exist';
  end if;

  if to_regprocedure('public.post_delivery_return(uuid, integer, text)') is null then
    raise exception 'M7.4B post_delivery_return must remain';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code in ('admin', 'accounts')
      and permissions.code = 'statutory.config.verify'
  ) then
    raise exception 'admin/accounts must not hold statutory.config.verify';
  end if;

  if exists (
    select 1
    from public.user_roles
    join public.roles on roles.id = user_roles.role_id
    where roles.code = 'statutory_verifier'
      and user_roles.user_id not in (admin_id, accounts_id, godown_id, verifier_id)
      and user_roles.user_id not in (select id from fixture)
  ) then
    null; -- ignore leftover QA users outside this fixture
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);

  if public.registered_operating_ownership_code() is null then
    perform public.upsert_statutory_operating_ownership('SDI', current_date, 1, null);
  end if;
  ownership := public.registered_operating_ownership_code();

  begin
    perform public.upsert_statutory_seller_identity(
      ownership, 'Acme Legal', '1 Road', current_date, 1,
      null, '2', 'BADGSTIN', null, null, null, null, null, null, null, null, null, null, null, null, null
    );
    raise exception 'invalid GSTIN must fail';
  exception
    when others then
      if sqlerrm not ilike '%GSTIN%' then
        raise;
      end if;
  end;

  seller := public.upsert_statutory_seller_identity(
    ownership, 'Acme Legal', '1 Road', current_date, 1,
    null, '27', null, null, null, null, null, null, null, null, null, null,
    'Authorized signatory', 'Common seal', null, null
  );
  begin
    perform public.submit_statutory_seller_identity((seller ->> 'id')::uuid, (seller ->> 'version')::integer);
    raise exception 'seller submit without GSTIN must fail';
  exception
    when others then
      if sqlerrm not ilike '%GSTIN%' then
        raise;
      end if;
  end;

  seller := public.upsert_statutory_seller_identity(
    ownership, 'Acme Legal', '1 Road', current_date, (seller ->> 'version')::integer,
    null, '27', '27AAAAA0000A1Z5', 'AAAAA0000A', null, null, null, null, null, null, null, null,
    'Authorized signatory', 'Common seal', null, (seller ->> 'id')::uuid
  );
  seller := public.submit_statutory_seller_identity((seller ->> 'id')::uuid, (seller ->> 'version')::integer);

  perform set_config('request.jwt.claim.sub', accounts_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', accounts_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.verify_statutory_seller_identity((seller ->> 'id')::uuid, (seller ->> 'version')::integer);
    raise exception 'accounts must not verify statutory configuration';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', godown_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', godown_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.list_statutory_seller_identities();
    raise exception 'godown manager must not read statutory configuration';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  begin
    perform public.submit_statutory_seller_identity((seller ->> 'id')::uuid, 999);
    raise exception 'stale seller version must fail';
  exception
    when others then
      if sqlstate not in ('PT409') and sqlerrm not ilike '%changed by someone else%' then
        raise;
      end if;
  end;

  seller := public.upsert_statutory_seller_identity(
    ownership, 'Acme Legal edited', '1 Road', current_date, (seller ->> 'version')::integer,
    null, '27', '27AAAAA0000A1Z5', 'AAAAA0000A', null, null, null, null, null, null, null, null,
    'Authorized signatory', 'Common seal', null, (seller ->> 'id')::uuid
  );
  if seller ->> 'status' is distinct from 'draft' then
    raise exception 'material edit must invalidate previous approval';
  end if;
  seller := public.submit_statutory_seller_identity((seller ->> 'id')::uuid, (seller ->> 'version')::integer);

  perform set_config('request.jwt.claim.sub', verifier_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', verifier_id, 'role', 'authenticated')::text,
    true
  );
  if not exists (
    select 1
    from public.statutory_seller_identities
    where statutory_seller_identities.ownership_code = ownership
      and statutory_seller_identities.status = 'verified'
  ) then
    seller := public.verify_statutory_seller_identity((seller ->> 'id')::uuid, (seller ->> 'version')::integer);
    if seller ->> 'status' is distinct from 'verified' then
      raise exception 'verifier must be able to approve seller identity';
    end if;
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  shop_tax := public.upsert_shop_tax_identity(
    shop_id, 'Unregistered Shop', '2 Street', 'unregistered', current_date, 1,
    null, null, '27', null, null, null
  );
  if shop_tax ->> 'gstin' is not null then
    raise exception 'unregistered shop must allow missing GSTIN';
  end if;
  shop_tax := public.submit_shop_tax_identity((shop_tax ->> 'id')::uuid, (shop_tax ->> 'version')::integer);

  begin
    perform public.upsert_shop_tax_identity(
      shop_id, 'Registered', '2 Street', 'gst_registered', current_date, 1,
      null, null, '27', null, null, null
    );
    raise exception 'GST-registered shop without GSTIN must fail';
  exception
    when others then
      if sqlerrm not ilike '%GSTIN%' then
        raise;
      end if;
  end;

  begin
    perform public.upsert_product_hsn_classification(
      product_id, 'hsn', '12', current_date, 1, null, null
    );
    raise exception 'short HSN must fail';
  exception
    when others then
      if sqlerrm not ilike '%HSN%' then
        raise;
      end if;
  end;

  hsn := public.upsert_product_hsn_classification(
    product_id, 'hsn', '1905', current_date, 1, null, null
  );
  hsn := public.submit_product_hsn_classification((hsn ->> 'id')::uuid, (hsn ->> 'version')::integer);

  rate := public.upsert_tax_rate_schedule(
    'GST-UNSET', 'unspecified', current_date, 1, '1905', null, null, null, null, null
  );
  rate := public.submit_tax_rate_schedule((rate ->> 'id')::uuid, (rate ->> 'version')::integer);

  perform set_config('request.jwt.claim.sub', verifier_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', verifier_id, 'role', 'authenticated')::text,
    true
  );
  shop_tax := public.verify_shop_tax_identity((shop_tax ->> 'id')::uuid, (shop_tax ->> 'version')::integer);
  hsn := public.verify_product_hsn_classification((hsn ->> 'id')::uuid, (hsn ->> 'version')::integer);
  begin
    perform public.verify_tax_rate_schedule((rate ->> 'id')::uuid, (rate ->> 'version')::integer);
    raise exception 'unspecified tax schedule must not verify';
  exception
    when others then
      if sqlerrm not ilike '%explicit%' and sqlerrm not ilike '%treatment%' then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  rate := public.upsert_tax_rate_schedule(
    'GST-UNSET', 'intra_state', current_date, (rate ->> 'version')::integer, '1905',
    2.5, 2.5, null, null, (rate ->> 'id')::uuid
  );
  rate := public.submit_tax_rate_schedule((rate ->> 'id')::uuid, (rate ->> 'version')::integer);

  perform set_config('request.jwt.claim.sub', verifier_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', verifier_id, 'role', 'authenticated')::text,
    true
  );
  rate := public.verify_tax_rate_schedule((rate ->> 'id')::uuid, (rate ->> 'version')::integer);

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  -- Overlapping verified tax window fails closed.
  rate := public.upsert_tax_rate_schedule(
    'GST-UNSET', 'intra_state', current_date, 1, '1905', 6, 6, null, current_date + 30, null
  );
  rate := public.submit_tax_rate_schedule((rate ->> 'id')::uuid, (rate ->> 'version')::integer);
  perform set_config('request.jwt.claim.sub', verifier_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', verifier_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.verify_tax_rate_schedule((rate ->> 'id')::uuid, (rate ->> 'version')::integer);
    raise exception 'overlapping verified tax window must fail closed';
  exception
    when others then
      if sqlerrm not ilike '%overlap%' then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  foreach kind in array array[
    'invoice_date', 'tax_inclusive_exclusive', 'place_of_supply',
    'gst_component', 'rounding', 'credit_note_tax', 'numbering'
  ]
  loop
    policy := public.upsert_statutory_policy(
      kind, jsonb_build_object('rule', 'pending_accountant'), current_date, 1, null, null
    );
    policy := public.submit_statutory_policy((policy ->> 'id')::uuid, (policy ->> 'version')::integer);
    perform set_config('request.jwt.claim.sub', verifier_id::text, true);
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', verifier_id, 'role', 'authenticated')::text,
      true
    );
    if not exists (
      select 1
      from public.statutory_policies
      where statutory_policies.policy_kind = kind
        and statutory_policies.status = 'verified'
    ) then
      policy := public.verify_statutory_policy((policy ->> 'id')::uuid, (policy ->> 'version')::integer);
    end if;
    perform set_config('request.jwt.claim.sub', admin_id::text, true);
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', admin_id, 'role', 'authenticated')::text,
      true
    );
  end loop;

  readiness := public.assess_invoice_finalization_readiness();
  if coalesce(readiness ->> 'ready', 'true') is distinct from 'false' then
    raise exception 'readiness must stay false after complete configuration';
  end if;
  if coalesce(readiness ->> 'legal_issuance_blocked', 'false') is distinct from 'true' then
    raise exception 'legal issuance must stay blocked';
  end if;
  codes := (
    select string_agg(value ->> 'code', ',')
    from jsonb_array_elements(readiness -> 'blockers')
  );
  if codes not ilike '%finalize_rpc_disabled%' then
    raise exception 'hard issuance blocker must remain: %', codes;
  end if;

  if exists (
    select 1
    from pg_proc
    join pg_namespace on pg_namespace.oid = pg_proc.pronamespace
    where pg_namespace.nspname = 'public'
      and pg_proc.proname like '%statutory%'
      and pg_get_functiondef(pg_proc.oid) ilike '%stock_ledger%'
  ) then
    raise exception 'statutory RPCs must not write stock';
  end if;
end;
$$;

rollback;
