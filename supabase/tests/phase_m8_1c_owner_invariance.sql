-- M8.1C owner invariance. Read-only. Must run only on the owner identifier.

do $$
declare
  sysid bigint;
begin
  select system_identifier into sysid from pg_control_system();
  if sysid is distinct from 7699785797738577957 then
    raise exception 'M8.1C owner invariance must run against the owner database, got %', sysid;
  end if;
end $$;

select 'sysid' as check, system_identifier::text as value from pg_control_system();
select key as check, value::text as value
from public.app_configuration
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked',
  'damage.stock_hold_ready'
)
order by 1;
select 'migration_tip' as check, version as value
from supabase_migrations.schema_migrations
order by version desc
limit 1;
select 'migration_count' as check, count(*)::text as value from supabase_migrations.schema_migrations;
select 'products' as check, count(*)::text as value from public.products;
select 'auth_users' as check, count(*)::text as value from auth.users;
select 'agg_qty' as check, coalesce(sum(quantity), 0)::text as value from public.stock_balances;
select 'lot_qty' as check, coalesce(sum(quantity), 0)::text as value from public.stock_lot_balances;
select 'legal_years_on' as check, count(*)::text as value from public.invoice_financial_years where legal_allocation_enabled;
select 'legal_invoice_on' as check, count(*)::text as value from public.invoice_number_series where legal_allocation_enabled;
select 'legal_credit_on' as check, count(*)::text as value from public.invoice_credit_note_number_series where legal_allocation_enabled;
select 'not_valid_fks' as check, count(*)::text as value from pg_constraint where contype = 'f' and not convalidated;
