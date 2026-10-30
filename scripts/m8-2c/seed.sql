-- M8.2C TEST ONLY masters that have no public RPC (sales route).
-- Abort unless the session GUC is set on the isolated UAT database.

do $$
declare
  sysid bigint;
begin
  if current_setting('app.m82c_seed_approved', true) is distinct from 'on' then
    raise exception 'M8.2C seed refused: set app.m82c_seed_approved=on only on the isolated UAT database';
  end if;

  select system_identifier into sysid from pg_control_system();
  if sysid in (7699785797738577957, 7702023892197691429) then
    raise exception 'M8.2C seed refused owner or m81c database (%)', sysid;
  end if;
end $$;

insert into public.sales_routes (code, name, weekday, sort_order)
values ('m82c_rt', 'TEST ONLY Route M82C', 'monday', 99)
on conflict (code) do update
  set name = excluded.name,
      weekday = excluded.weekday,
      is_active = true;

select 'M8.2C TEST ONLY sales route ready' as status;
