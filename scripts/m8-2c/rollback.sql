-- M8.2C isolated teardown helper. Does not delete ledger rows.
-- Preferred cleanup is destroying the isolated volume, not reversing stock.

do $$
declare
  sysid bigint;
begin
  if current_setting('app.m82c_seed_approved', true) is distinct from 'on' then
    raise exception 'M8.2C rollback refused: missing app.m82c_seed_approved=on';
  end if;

  select system_identifier into sysid from pg_control_system();
  if sysid in (7699785797738577957, 7702023892197691429) then
    raise exception 'M8.2C rollback refused owner or m81c database (%)', sysid;
  end if;

  update public.app_configuration
  set value = 'false'::jsonb
  where key = 'stock.lots.dual_write_enabled';
end $$;

select 'M8.2C dual-write returned to false on isolated database' as status;
select 'Destroy supabase_db_sherlyos_m82c volume to remove TEST ONLY rows' as next_step;
