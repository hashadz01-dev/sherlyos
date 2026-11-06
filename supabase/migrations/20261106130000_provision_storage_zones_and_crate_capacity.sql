-- Storage zones A–E and crates A-01–E-04 for the seven existing godowns.
-- capacity_cases is the visual target. It does not reject on-hand stock above 50.
-- Zone F, QRN, uat_z1, and uat_c1 are intentionally left unchanged.

alter table public.crates
  add column if not exists capacity_cases integer;

update public.crates
set capacity_cases = 50
where capacity_cases is null;

alter table public.crates
  alter column capacity_cases set default 50;

alter table public.crates
  alter column capacity_cases set not null;

alter table public.crates
  drop constraint if exists crates_capacity_cases_check;

alter table public.crates
  add constraint crates_capacity_cases_check
  check (capacity_cases >= 1);

comment on column public.crates.capacity_cases is
  'Planned cases this crate can show. On-hand stock may exceed it; overflow is reported, not rejected.';

insert into public.zones (branch_id, code, name, location_role)
select branches.id, planned.code, planned.name, 'storage'
from public.branches
cross join (
  values
    ('A', 'Zone A'),
    ('B', 'Zone B'),
    ('C', 'Zone C'),
    ('D', 'Zone D'),
    ('E', 'Zone E')
) as planned(code, name)
where branches.code in ('gd_1', 'gd_2', 'gd_3', 'gd_4', 'gd_5', 'gd_6', 'gd_7')
  and not exists (
    select 1
    from public.zones existing
    where existing.branch_id = branches.id
      and lower(existing.code) = lower(planned.code)
  );

insert into public.crates (zone_id, code, name, location_role, capacity_cases)
select
  zones.id,
  zones.code || '-' || lpad(slot.n::text, 2, '0'),
  'Crate ' || lpad(slot.n::text, 2, '0'),
  'storage',
  50
from public.zones
join public.branches on branches.id = zones.branch_id
cross join (
  values (1), (2), (3), (4)
) as slot(n)
where branches.code in ('gd_1', 'gd_2', 'gd_3', 'gd_4', 'gd_5', 'gd_6', 'gd_7')
  and zones.code in ('A', 'B', 'C', 'D', 'E')
  and zones.location_role = 'storage'
  and not exists (
    select 1
    from public.crates existing
    where existing.zone_id = zones.id
      and lower(existing.code) = lower(zones.code || '-' || lpad(slot.n::text, 2, '0'))
  );
