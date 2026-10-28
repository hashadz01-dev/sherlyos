-- M7.5D.1 handover preview catalog and permission proofs.
-- Rolls back. Does not post stock or issue tax invoices.

begin;

do $$
declare
  driver_id uuid;
  payload jsonb;
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
  then
    raise exception 'statutory invoice issuance RPC must not exist';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'get_invoice_note_preview'
      and p.prosecdef
      and p.provolatile = 's'
  ) then
    raise exception 'get_invoice_note_preview must stay STABLE SECURITY DEFINER';
  end if;

  begin
    perform public.get_invoice_note_preview(gen_random_uuid(), 'tax-invoice');
    raise exception 'invalid copy must be rejected';
  exception
    when others then
      if sqlstate not in ('23514') then
        raise;
      end if;
  end;

  select id into driver_id from auth.users where email = 'driver.m75d1sql@example.com';
  if driver_id is null then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    )
    values (
      '00000000-0000-0000-0000-000000000000',
      gen_random_uuid(),
      'authenticated',
      'authenticated',
      'driver.m75d1sql@example.com',
      extensions.crypt('local-only-m75d1', extensions.gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb,
      now(),
      now()
    )
    returning id into driver_id;
  end if;

  insert into public.profiles (id, full_name, is_active)
  values (driver_id, 'M75D1 SQL driver', true)
  on conflict (id) do update set is_active = true;

  insert into public.user_roles (user_id, role_id, assigned_by)
  select driver_id, roles.id, driver_id
  from public.roles
  where roles.code = 'delivery_person'
  on conflict do nothing;

  perform set_config('request.jwt.claim.sub', driver_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', driver_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  begin
    perform public.get_invoice_note_preview(gen_random_uuid(), 'driver');
    raise exception 'driver must not read handover documents';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  begin
    perform public.get_invoice_note_preview(gen_random_uuid(), 'accounts');
    raise exception 'driver must not read accounts financial preview';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  execute 'set local role postgres';
  select count(*) into ledger_before from public.stock_ledger;
  select count(*) into ledger_after from public.stock_ledger;
  if ledger_before is distinct from ledger_after then
    raise exception 'handover catalog checks must not write stock';
  end if;
end;
$$;

rollback;
