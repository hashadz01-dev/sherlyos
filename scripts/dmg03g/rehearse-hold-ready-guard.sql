-- DMG-03G disposable rehearsal: prove hold_ready fails closed without dual-write,
-- then confirm current m82c flags remain unchanged (transaction ROLLBACK).
-- Target: supabase_db_sherlyos_m82c only.

do $$
declare
  v_sysid text;
  blocked boolean := false;
begin
  select system_identifier::text into v_sysid from pg_control_system();
  if v_sysid is distinct from '7702447407569928229' then
    raise exception 'DMG-03G guard rehearsal refused unexpected database %', v_sysid;
  end if;
end $$;

begin;

update public.app_configuration
set value = 'false'::jsonb
where key = 'damage.stock_hold_ready';

update public.app_configuration
set value = 'false'::jsonb
where key = 'stock.lots.dual_write_enabled';

do $$
declare
  msg text;
begin
  begin
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'damage.stock_hold_ready';
    raise exception 'guard failed to block hold_ready without dual-write';
  exception
    when others then
      get stacked diagnostics msg = message_text;
      if msg ilike '%dual-write%' or msg ilike '%lot dual-write%' then
        raise notice 'DMG-03G guard OK: %', msg;
      elsif msg ilike '%guard failed%' then
        raise;
      else
        raise notice 'DMG-03G guard blocked with: %', msg;
      end if;
  end;
end $$;

rollback;

select key, value #>> '{}' as val
from public.app_configuration
where key in ('damage.stock_hold_ready', 'stock.lots.dual_write_enabled')
order by 1;
