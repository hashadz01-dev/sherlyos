-- M7.5D.2 statutory finalization foundation proofs.
-- Rolls back. Does not issue tax invoices, allocate legal numbers, or flip flags.

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
  fixture.name || '.m75d2sql@example.com',
  extensions.crypt('local-only-m75d2', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from fixture;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'm75d2 ' || fixture.name, true
from fixture
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
on conflict do nothing;

do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  accounts_id uuid := (select id from fixture where name = 'accounts');
  driver_id uuid := (select id from fixture where name = 'driver');
  rel text;
  readiness jsonb;
  cancellation jsonb;
  codes text;
  note_id uuid;
  stale_note uuid;
  cancelled_note uuid;
  preview_id uuid;
  foundation_id uuid;
  year_id uuid;
  series_id uuid;
  first_num jsonb;
  second_num jsonb;
  line_amount numeric;
  snap_amount numeric;
  ledger_before bigint;
  ledger_after bigint;
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
    or to_regprocedure('public.cancel_statutory_invoice(uuid, integer, text)') is not null
  then
    raise exception 'statutory invoice issuance or cancellation RPC must not exist';
  end if;

  foreach rel in array array[
    'invoice_financial_years',
    'invoice_number_series',
    'invoice_number_allocations',
    'statutory_invoices',
    'statutory_invoice_lines',
    'statutory_invoice_tax_components',
    'statutory_invoice_events',
    'statutory_invoice_cancellations'
  ]
  loop
    if not exists (
      select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = rel
        and c.relrowsecurity and c.relforcerowsecurity
    ) then
      raise exception '% must have FORCE RLS', rel;
    end if;
  end loop;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.statutory_invoices'::regclass
      and conname = 'statutory_invoices_not_issued'
  ) then
    raise exception 'statutory invoices must forbid issued_at and legal_invoice_number';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.invoice_number_allocations'::regclass
      and conname = 'invoice_number_allocations_legal_off'
  ) then
    raise exception 'number allocations must forbid legal numbers';
  end if;

  select count(*) into ledger_before from public.stock_ledger;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);

  readiness := public.assess_invoice_finalization_readiness();
  if coalesce(readiness ->> 'ready', 'true') is distinct from 'false'
    or coalesce(readiness ->> 'legal_issuance_blocked', 'false') is distinct from 'true'
    or coalesce(readiness ->> 'numbering_allocation_enabled', 'true') is distinct from 'false'
    or coalesce(readiness ->> 'cancellation_blocked', 'false') is distinct from 'true'
  then
    raise exception 'issuance must stay blocked: %', readiness;
  end if;
  codes := (
    select string_agg(value ->> 'code', ',')
    from jsonb_array_elements(readiness -> 'blockers')
  );
  if codes not ilike '%finalize_rpc_disabled%'
    or codes not ilike '%statutory_issuance_disabled%'
    or codes not ilike '%legal_numbering_allocation_disabled%'
    or codes not ilike '%tax_preview_is_not_a_tax_invoice%'
    or codes not ilike '%numbering_policy_unapproved%'
    or codes not ilike '%financial_year_unconfigured%'
  then
    raise exception 'required foundation blockers missing: %', codes;
  end if;

  cancellation := public.assess_statutory_cancellation_readiness();
  if coalesce(cancellation ->> 'ready', 'true') is distinct from 'false'
    or coalesce(cancellation ->> 'legal_cancellation_blocked', 'false') is distinct from 'true'
    or coalesce(cancellation ->> 'deletes_history', 'true') is distinct from 'false'
  then
    raise exception 'cancellation must stay blocked: %', cancellation;
  end if;

  perform set_config('request.jwt.claim.sub', driver_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', driver_id, 'role', 'authenticated')::text,
    true
  );
  begin
    readiness := public.assess_invoice_finalization_readiness();
    raise exception 'driver must be denied eligibility';
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

  select invoice_notes.id into stale_note
  from public.invoice_notes
  join public.invoice_tax_previews
    on invoice_tax_previews.invoice_note_id = invoice_notes.id
   and invoice_tax_previews.is_current
  where invoice_notes.status = 'reviewed'
    and invoice_tax_previews.invoice_note_version is distinct from invoice_notes.version
  limit 1;
  if stale_note is not null then
    readiness := public.assess_invoice_finalization_readiness(stale_note);
    if (readiness -> 'blockers')::text not ilike '%tax_preview_stale%' then
      raise exception 'stale tax preview must be rejected: %', readiness;
    end if;
    if coalesce(readiness ->> 'ready', 'true') is distinct from 'false' then
      raise exception 'stale preview must not flip ready';
    end if;
  end if;

  select invoice_notes.id into note_id
  from public.invoice_notes
  join public.invoice_tax_previews
    on invoice_tax_previews.invoice_note_id = invoice_notes.id
   and invoice_tax_previews.is_current
  where invoice_notes.status = 'reviewed'
    and invoice_tax_previews.invoice_note_version = invoice_notes.version
  order by invoice_notes.created_at desc
  limit 1;

  select invoice_notes.id into cancelled_note
  from public.invoice_notes
  where invoice_notes.status = 'cancelled'
  limit 1;
  if cancelled_note is not null then
    readiness := public.assess_invoice_finalization_readiness(cancelled_note);
    if (readiness -> 'blockers')::text not ilike '%invoice_note_not_reviewed%' then
      raise exception 'cancelled notes must not be eligible: %', readiness;
    end if;
  end if;

  reset role;
  perform set_config('app.invoice_numbering_write', 'on', true);

  insert into public.invoice_financial_years (
    ownership_code, code, label, starts_on, ends_on, status, created_by
  )
  values (
    'PROOF-M75D2', '26-27', 'Proof FY 26-27', '2026-04-01', '2027-03-31',
    'verified', admin_id
  )
  returning id into year_id;

  insert into public.invoice_number_series (
    financial_year_id, series_code, prefix, pad_width, is_synthetic, created_by
  )
  values (year_id, 'PROOF', 'PROOF-M75D2', 5, true, admin_id)
  returning id into series_id;

  perform set_config('app.invoice_number_proof', 'on', true);
  first_num := app_private.allocate_synthetic_invoice_number(series_id);
  second_num := app_private.allocate_synthetic_invoice_number(series_id);
  if (first_num ->> 'allocated_number')::bigint is distinct from 1
    or (second_num ->> 'allocated_number')::bigint is distinct from 2
  then
    raise exception 'synthetic allocator must be sequential: % %', first_num, second_num;
  end if;
  if first_num ->> 'formatted_number' not like 'PROOF-%'
    or coalesce(first_num ->> 'is_legal', 'true') is distinct from 'false'
  then
    raise exception 'synthetic allocation must not be legal: %', first_num;
  end if;

  begin
    update public.invoice_number_allocations
    set is_legal = true
    where id = (first_num ->> 'id')::uuid;
    raise exception 'legal flag must be rejected';
  exception
    when check_violation then
      null;
  end;

  if note_id is not null then
    select invoice_tax_previews.id into preview_id
    from public.invoice_tax_previews
    where invoice_tax_previews.invoice_note_id = note_id
      and invoice_tax_previews.is_current;

    perform set_config('app.statutory_invoice_write', 'on', true);
    perform set_config('request.jwt.claim.sub', admin_id::text, true);
    foundation_id := app_private.reserve_statutory_invoice_foundation(note_id);

    select invoice_note_lines.line_amount into line_amount
    from public.invoice_note_lines
    where invoice_note_lines.invoice_note_id = note_id
    order by invoice_note_lines.line_no
    limit 1;
    select statutory_invoice_lines.line_amount into snap_amount
    from public.statutory_invoice_lines
    where statutory_invoice_lines.statutory_invoice_id = foundation_id
    order by statutory_invoice_lines.line_no
    limit 1;
    if snap_amount is distinct from line_amount then
      raise exception 'foundation must preserve reviewed line amount % vs %', line_amount, snap_amount;
    end if;

    begin
      perform app_private.reserve_statutory_invoice_foundation(note_id);
      raise exception 'duplicate foundation must be rejected';
    exception
      when unique_violation then
        null;
    end;

    begin
      update public.statutory_invoices
      set price_fingerprint = 'tampered'
      where id = foundation_id;
      raise exception 'immutable snapshot update must be rejected';
    exception
      when others then
        if sqlstate not in ('42501') then
          raise;
        end if;
    end;

    begin
      update public.statutory_invoices
      set legal_invoice_number = 'SDI/26-27/19656', issued_at = now()
      where id = foundation_id;
      raise exception 'legal issuance columns must stay null';
    exception
      when others then
        if sqlstate not in ('23514', '42501') then
          raise;
        end if;
    end;

    insert into public.statutory_invoice_cancellations (
      statutory_invoice_id, reason, status, actor_id
    )
    values (foundation_id, 'proof only, not an issued cancellation', 'blocked_intent', admin_id);

    begin
      update public.statutory_invoice_cancellations
      set status = 'completed'
      where statutory_invoice_id = foundation_id;
      raise exception 'completed cancellation must be rejected';
    exception
      when others then
        if sqlstate not in ('23514', '42501') then
          raise;
        end if;
    end;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claim.sub', admin_id::text, true);
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', admin_id, 'role', 'authenticated')::text,
      true
    );
    readiness := public.assess_invoice_finalization_readiness(note_id);
    if (readiness -> 'blockers')::text not ilike '%conflicting_finalization%' then
      raise exception 'reserved foundation must block duplicate finalization: %', readiness;
    end if;
    if coalesce(readiness ->> 'ready', 'true') is distinct from 'false' then
      raise exception 'foundation reservation must not enable issuance';
    end if;
  end if;

  perform set_config('role', 'postgres', true);
  select count(*) into ledger_after from public.stock_ledger;
  if ledger_after is distinct from ledger_before then
    raise exception 'foundation must not write stock';
  end if;
end;
$$;

rollback;
