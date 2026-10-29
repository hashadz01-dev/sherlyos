-- M8.1C clean migration baseline. Read-only. Refuses the owner identifier.

do $$
declare
  sysid bigint;
  unvalidated integer;
  migs integer;
begin
  select system_identifier into sysid from pg_control_system();
  if sysid = 7699785797738577957 then
    raise exception 'M8.1C baseline must not run against the owner database';
  end if;

  select count(*) into migs from supabase_migrations.schema_migrations;
  if migs is distinct from 75 then
    raise exception 'expected 75 migrations, got %', migs;
  end if;
  if (select version from supabase_migrations.schema_migrations order by version desc limit 1)
       is distinct from '20261028253000' then
    raise exception 'migration tip mismatch';
  end if;

  select count(*) into unvalidated
  from pg_constraint
  where contype = 'f' and not convalidated;
  if unvalidated <> 0 then
    raise exception 'clean baseline has % NOT VALID foreign keys', unvalidated;
  end if;

  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
       is distinct from 'false'::jsonb
     or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
       is distinct from 'false'::jsonb
     or (select value from public.app_configuration where key = 'damage.stock_hold_ready')
       is distinct from 'false'::jsonb
  then
    raise exception 'clean baseline flags must start false';
  end if;

  if exists (
    select 1 from public.invoice_financial_years where legal_allocation_enabled
    union all
    select 1 from public.invoice_number_series where legal_allocation_enabled
    union all
    select 1 from public.invoice_credit_note_number_series where legal_allocation_enabled
  ) then
    raise exception 'legal allocation must be off on a clean database';
  end if;
end $$;

select 'M8.1C clean baseline PASS' as status;
