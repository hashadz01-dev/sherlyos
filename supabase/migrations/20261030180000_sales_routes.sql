-- M8.2A geographic sales-visit routes. Not godown zones and not salesperson runs.
-- Does not write stock, prices, orders, or salesperson assignments.

create table public.sales_routes (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  weekday text,
  sort_order integer not null,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint sales_routes_code_length check (
    char_length(btrim(code)) between 1 and 40
    and code = btrim(code)
  ),
  constraint sales_routes_name_length check (
    char_length(btrim(name)) between 1 and 160
    and name = btrim(name)
  ),
  constraint sales_routes_weekday_shape check (
    weekday is null
    or weekday in ('monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday')
  ),
  constraint sales_routes_sort_order_positive check (sort_order >= 1),
  constraint sales_routes_code_key unique (code)
);

create trigger sales_routes_set_updated_at
  before update on public.sales_routes
  for each row execute function app_private.set_updated_at();

comment on table public.sales_routes is
  'Geographic sales-visit route. Not a delivery vehicle run and not a godown zone. Weekday may be null (Chullikkal). No salesperson FK.';

create table public.shop_sales_route_memberships (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops (id) on delete restrict,
  route_id uuid not null references public.sales_routes (id) on delete restrict,
  visit_sequence integer not null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint shop_sales_route_memberships_sequence_positive check (visit_sequence >= 1),
  constraint shop_sales_route_memberships_shop_route_key unique (shop_id, route_id)
);

create index shop_sales_route_memberships_route_id_idx
  on public.shop_sales_route_memberships (route_id, visit_sequence);

create trigger shop_sales_route_memberships_set_updated_at
  before update on public.shop_sales_route_memberships
  for each row execute function app_private.set_updated_at();

comment on table public.shop_sales_route_memberships is
  'A shop may belong to more than one sales route. Visit sequence is per route. Salesperson ownership stays on shop_salesperson_assignments.';

alter table public.sales_routes enable row level security;
alter table public.sales_routes force row level security;
alter table public.shop_sales_route_memberships enable row level security;
alter table public.shop_sales_route_memberships force row level security;

revoke all on table public.sales_routes from public, anon, service_role;
revoke all on table public.shop_sales_route_memberships from public, anon, service_role;
grant select on table public.sales_routes to authenticated;
grant select on table public.shop_sales_route_memberships to authenticated;

create policy sales_routes_select_readers
  on public.sales_routes
  for select
  to authenticated
  using ((select app_private.has_permission('shops.read')));

create policy shop_sales_route_memberships_select_authorized
  on public.shop_sales_route_memberships
  for select
  to authenticated
  using (
    (select app_private.has_permission('shops.read'))
    and exists (
      select 1
      from public.shops
      where shops.id = shop_sales_route_memberships.shop_id
        and (
          (select app_private.has_permission('shops.assign'))
          or (
            (select app_private.has_permission('shops.read_all'))
            and shops.is_active
          )
          or exists (
            select 1
            from public.shop_salesperson_assignments
            where shop_salesperson_assignments.shop_id = shops.id
              and shop_salesperson_assignments.salesperson_id = (select auth.uid())
              and shop_salesperson_assignments.is_active
          )
        )
    )
  );

create or replace function public.set_shop_sales_route(
  target_shop uuid,
  target_route uuid,
  visit_sequence integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership_id uuid;
  next_sequence integer;
begin
  perform app_private.assert_permission('shops.assign');

  if not exists (select 1 from public.shops where shops.id = target_shop) then
    raise exception 'shop not found' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.sales_routes
    where sales_routes.id = target_route
      and sales_routes.is_active
  ) then
    raise exception 'sales route not found' using errcode = '42501';
  end if;

  next_sequence := visit_sequence;
  if next_sequence is null then
    select coalesce(max(shop_sales_route_memberships.visit_sequence), 0) + 1
      into next_sequence
    from public.shop_sales_route_memberships
    where shop_sales_route_memberships.route_id = target_route;
  end if;

  if next_sequence < 1 then
    raise exception 'visit sequence is invalid' using errcode = '23514';
  end if;

  insert into public.shop_sales_route_memberships (shop_id, route_id, visit_sequence)
  values (target_shop, target_route, next_sequence)
  on conflict (shop_id, route_id) do update
    set visit_sequence = excluded.visit_sequence
  returning id into membership_id;

  perform app_private.write_audit(
    auth.uid(),
    'set_shop_sales_route',
    'shop_sales_route_memberships',
    membership_id,
    pg_catalog.jsonb_build_object(
      'shop_id', target_shop,
      'route_id', target_route,
      'visit_sequence', next_sequence
    )
  );

  return membership_id;
end;
$$;

revoke all on function public.set_shop_sales_route(uuid, uuid, integer) from public, anon;
grant execute on function public.set_shop_sales_route(uuid, uuid, integer) to authenticated;

comment on function public.set_shop_sales_route(uuid, uuid, integer) is
  'Requires shops.assign. Adds or updates one route membership. Does not assign a salesperson or a godown.';

insert into public.sales_routes (code, name, weekday, sort_order)
values
  ('thevara', 'Thevara', 'monday', 1),
  ('vyttila', 'Vyttila', 'tuesday', 2),
  ('nettoor-panangad', 'Nettoor / Panangad', 'wednesday', 3),
  ('manjummel-vennala', 'Manjummel / Vennala', 'thursday', 4),
  ('karukappally', 'Karukappally', 'friday', 5),
  ('thripunithura', 'Thripunithura', 'saturday', 6),
  ('palarivattom', 'Palarivattom', 'monday', 7),
  ('kadavanthra', 'Kadavanthra', 'tuesday', 8),
  ('kaloor', 'Kaloor', 'wednesday', 9),
  ('kalamassery', 'Kalamassery', 'thursday', 10),
  ('kkd-1', 'KKD-1', 'friday', 11),
  ('ernakulam', 'Ernakulam', 'saturday', 12),
  ('market', 'Market', 'saturday', 13),
  ('chullikkal', 'Chullikkal', null, 14)
on conflict (code) do update
  set
    name = excluded.name,
    weekday = excluded.weekday,
    sort_order = excluded.sort_order;
