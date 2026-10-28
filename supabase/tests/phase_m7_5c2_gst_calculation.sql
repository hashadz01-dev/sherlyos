-- M7.5C.2 GST preview arithmetic, ownership isolation, and issuance block.
-- Rolls back. Does not issue tax invoices or flip operational flags.

begin;

do $$
declare
  exclusive_intra jsonb;
  inclusive_intra jsonb;
  exclusive_inter jsonb;
  zero_rate jsonb;
  rounded numeric;
  ownership jsonb;
  readiness jsonb;
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

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.shop_tax_identities'::regclass
      and pg_get_constraintdef(oid) ilike '%gst_registered%'
      and pg_get_constraintdef(oid) ilike '%gstin%'
  ) then
    raise exception 'GST-registered shop identities must require GSTIN';
  end if;

  exclusive_intra := app_private.gst_line_calc(100, 'exclusive', 'intra_state', 2.5, 2.5, 0, 'nearest_half_up', 0.01);
  if (exclusive_intra ->> 'taxable_value')::numeric is distinct from 100.00
    or (exclusive_intra ->> 'cgst_amount')::numeric is distinct from 2.50
    or (exclusive_intra ->> 'sgst_amount')::numeric is distinct from 2.50
    or (exclusive_intra ->> 'igst_amount')::numeric is distinct from 0
    or (exclusive_intra ->> 'line_total')::numeric is distinct from 105.00
  then
    raise exception 'exclusive CGST/SGST formula failed: %', exclusive_intra;
  end if;

  inclusive_intra := app_private.gst_line_calc(105, 'inclusive', 'intra_state', 2.5, 2.5, 0, 'nearest_half_up', 0.01);
  if (inclusive_intra ->> 'taxable_value')::numeric is distinct from 100.00
    or (inclusive_intra ->> 'tax_amount')::numeric is distinct from 5.00
    or (inclusive_intra ->> 'line_total')::numeric is distinct from 105.00
  then
    raise exception 'inclusive CGST/SGST formula failed: %', inclusive_intra;
  end if;

  exclusive_inter := app_private.gst_line_calc(200, 'exclusive', 'inter_state', 0, 0, 18, 'nearest_half_up', 0.01);
  if (exclusive_inter ->> 'igst_amount')::numeric is distinct from 36.00
    or (exclusive_inter ->> 'cgst_amount')::numeric is distinct from 0
    or (exclusive_inter ->> 'line_total')::numeric is distinct from 236.00
  then
    raise exception 'exclusive IGST formula failed: %', exclusive_inter;
  end if;

  zero_rate := app_private.gst_line_calc(50, 'exclusive', 'intra_state', 0, 0, 0, 'nearest_half_up', 0.01);
  if (zero_rate ->> 'tax_amount')::numeric is distinct from 0
    or (zero_rate ->> 'line_total')::numeric is distinct from 50.00
  then
    raise exception 'explicit zero rate failed: %', zero_rate;
  end if;

  rounded := app_private.gst_round(1.255, 0.01, 'nearest_half_up');
  if rounded is distinct from 1.26 then
    raise exception 'nearest-half-up paisa rounding failed: %', rounded;
  end if;

  -- Inclusive IGST: 118 at 18% reverse-calculates taxable 100.
  exclusive_inter := app_private.gst_line_calc(118, 'inclusive', 'inter_state', 0, 0, 18, 'nearest_half_up', 0.01);
  if (exclusive_inter ->> 'taxable_value')::numeric is distinct from 100.00
    or (exclusive_inter ->> 'igst_amount')::numeric is distinct from 18.00
    or (exclusive_inter ->> 'line_total')::numeric is distinct from 118.00
  then
    raise exception 'inclusive IGST formula failed: %', exclusive_inter;
  end if;

  -- Two HSN lines are summed in NUMERIC, not IEEE floats.
  exclusive_intra := app_private.gst_line_calc(100, 'exclusive', 'intra_state', 2.5, 2.5, 0, 'nearest_half_up', 0.01);
  exclusive_inter := app_private.gst_line_calc(100, 'exclusive', 'inter_state', 0, 0, 18, 'nearest_half_up', 0.01);
  if ((exclusive_intra ->> 'line_total')::numeric + (exclusive_inter ->> 'line_total')::numeric)
    is distinct from 223.00
  then
    raise exception 'multi-line NUMERIC sum failed';
  end if;

  if app_private.gst_round(0.005, 0.01, 'nearest_half_up') is distinct from 0.01
    or app_private.gst_round(1.225, 0.01, 'nearest_half_up') is distinct from 1.23
  then
    raise exception 'rounding boundary failed';
  end if;

  begin
    perform app_private.gst_round(1.25, 0.01, 'floor');
    raise exception 'unapproved rounding mode must fail';
  exception
    when others then
      if sqlerrm not ilike '%approved%' then
        raise;
      end if;
  end;
end;
$$;

create temp table fixture (
  name text primary key,
  id uuid not null
);
insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('driver', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m75c2@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from fixture;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'm75c2 ' || fixture.name, true
from fixture
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name
    when 'admin' then 'admin'
    when 'godown' then 'godown_manager'
    when 'driver' then 'delivery_person'
  end
on conflict do nothing;

do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  godown_id uuid := (select id from fixture where name = 'godown');
  driver_id uuid := (select id from fixture where name = 'driver');
  readiness jsonb;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);

  if public.registered_operating_ownership_code() is null then
    perform public.upsert_statutory_operating_ownership('C2OWN', current_date, 1, null);
  end if;

  begin
    perform public.upsert_statutory_seller_identity(
      'NOT-THE-OWNER', 'Other Co', '9 Road', current_date, 1,
      null, '27', '27AAAAA0000A1Z5', null, null, null, null, null, null, null, null, null,
      'Sign', 'Seal', null, null
    );
    raise exception 'arbitrary ownership_code must be rejected';
  exception
    when others then
      if sqlerrm not ilike '%ownership%' then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', driver_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', driver_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.preview_invoice_tax(gen_random_uuid(), 1);
    raise exception 'driver must not preview tax';
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
  readiness := public.assess_invoice_finalization_readiness();
  if coalesce(readiness ->> 'ready', 'true') is distinct from 'false' then
    raise exception 'readiness must stay false';
  end if;
  if coalesce(readiness ->> 'legal_issuance_blocked', 'false') is distinct from 'true' then
    raise exception 'legal issuance must stay blocked';
  end if;
  if (readiness -> 'blockers')::text not ilike '%finalize_rpc_disabled%' then
    raise exception 'finalize blocker missing: %', readiness;
  end if;

end;
$$;

reset role;

do $$
begin
  begin
    perform app_private.verified_policy('tax_inclusive_exclusive', 'NO-SUCH-OWNER', current_date);
    raise exception 'unapproved policy lookup must fail closed';
  exception
    when others then
      if sqlerrm not ilike '%missing, unapproved, or ambiguous%' then
        raise;
      end if;
  end;
end;
$$;

rollback;
