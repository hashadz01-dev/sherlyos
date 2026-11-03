-- Owner-directed Branch-1 UAT stock path on development cloud.
-- Enables lot dual-write + aggregate_only_blocked together.
-- Creates Godown-1 UAT zone/crate, classifies GoodLife Milk 500ml,
-- posts 20 opening cases, and assigns GM + Store Keeper to Godown-1.
-- Does not assign Accounts. Does not invent a selling price or delivery user.
-- Does not flip damage.stock_hold_ready. Do not run on local Playwright DB.

do $$
declare
  admin_id uuid;
  gm_id uuid;
  keeper_id uuid;
  godown_id uuid := '798bacf9-2212-43fc-9cbb-2fe1e7367a93';
  product_id uuid := '8ef56e6f-1ea7-428a-8285-15895742959c';
  v_zone_id uuid;
  v_crate_id uuid;
begin
  select id into strict admin_id from auth.users where email = 'jeffinpappachan110@gmail.com';
  select id into strict gm_id from auth.users where email = 'testgodownmanager@gmail.com';
  select id into strict keeper_id from auth.users where email = 'teststorekeeper@gmail.com';

  if not exists (
    select 1 from public.branches
    where id = godown_id and is_active
  ) then
    raise exception 'Godown-1 is missing or inactive';
  end if;

  if not exists (
    select 1 from public.products
    where id = product_id and is_active
  ) then
    raise exception 'GOODLIFE-MILK-500ML is missing or inactive';
  end if;

  -- Rule A: both lot flags must move in one statement.
  update public.app_configuration
  set value = 'true'::jsonb
  where key in (
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  );

  if (select value from public.app_configuration where key = 'damage.stock_hold_ready')
       is distinct from 'false'::jsonb
  then
    raise exception 'damage.stock_hold_ready must stay false';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  perform public.assign_user_branch(gm_id, godown_id);
  perform public.assign_user_branch(keeper_id, godown_id);
  perform public.set_product_expiry_policy(product_id, 'expiry_controlled');

  select zones.id into v_zone_id
  from public.zones
  where zones.branch_id = godown_id
    and zones.code = 'uat_z1';
  if v_zone_id is null then
    v_zone_id := public.create_zone(godown_id, 'uat_z1', 'UAT Zone 1', 'UAT Order-to-Delivery location');
  end if;

  select crates.id into v_crate_id
  from public.crates
  where crates.zone_id = v_zone_id
    and crates.code = 'uat_c1';
  if v_crate_id is null then
    v_crate_id := public.create_crate(v_zone_id, 'uat_c1', 'UAT Crate 1', 'UAT Order-to-Delivery crate');
  end if;

  begin
    perform public.post_opening_stock(
      product_id,
      v_crate_id,
      20,
      'uat-od-opening-gl500-20261102',
      'UAT opening lot so Accounts can verify SO-20261030-000025',
      'UAT-GL500-20261102',
      date '2026-11-01',
      date '2026-12-31'
    );
  exception
    when unique_violation then
      null;
    when sqlstate '23505' then
      null;
  end;
end $$;

select key, value
from public.app_configuration
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
)
order by key;
