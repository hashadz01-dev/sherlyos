-- M5.4B stabilization.
-- 1) Align damage isolation lock order with confirm_dispatch:
--    source documents → products → prepare_stock_locations
--    (zones → crates → branch). Do not FOR UPDATE branches before
--    picking/dispatch/products; that deadlocked race C.
-- 2) Reject JSON Storage error bodies even on HTTP 200, and compare
--    Content-Length when present. Hosts stay allowlisted to local Kong.
-- Observed deadlock (race C, loading submit vs confirm_dispatch):
--   T_submit held branches via assert_operational_active_branch /
--   lock_damage_stock_grains, then waited on picking/dispatch.
--   T_confirm held order → picking → dispatch → reservations → products
--   → zones → crates, then waited on branches in prepare_stock_locations.

create or replace function app_private.assert_damage_create_auth(
  scenario text,
  target_godown uuid,
  target_dispatch uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_dispatch_requests;
  gm_transit boolean;
  driver_transit boolean;
  godown_active boolean;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if scenario = 'transit' then
    select *
    into header
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = target_dispatch;

    if not found or header.branch_id is distinct from target_godown then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    if not header.stock_consumed then
      raise exception 'transit damage requires a consumed dispatch'
        using errcode = '23514';
    end if;

    if header.status not in ('dispatched', 'in_transit', 'delivered', 'exception') then
      raise exception 'dispatch is not eligible for transit damage'
        using errcode = '23514';
    end if;

    if not app_private.can_complete_consumed_delivery_at_branch(target_godown) then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    gm_transit := app_private.has_permission('damage.record');
    driver_transit := app_private.has_permission('deliveries.execute')
      and header.assigned_to is not distinct from auth.uid();

    if not gm_transit and not driver_transit then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    return;
  end if;

  if not app_private.has_permission('damage.record') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- Inbound does not lock picking/dispatch/products, so a branch row lock
  -- cannot invert confirm_dispatch. Hold scenarios freeze the branch later
  -- inside prepare_stock_locations (zones → crates → branch).
  if scenario in ('refill_supply', 'unloading') then
    perform app_private.assert_operational_active_branch(target_godown);
  else
    if not app_private.can_work_at_branch(target_godown) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    select branches.is_active
    into godown_active
    from public.branches
    where branches.id = target_godown;
    if godown_active is not true then
      raise exception 'godown is inactive' using errcode = '23514';
    end if;
  end if;

  if scenario in ('refill_supply', 'unloading') then
    if not (
      app_private.has_permission('receiving.execute')
      or app_private.has_permission('damage.verify')
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  elsif scenario = 'loading' then
    if not (
      app_private.has_permission('loading.assist')
      or app_private.has_permission('damage.verify')
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  elsif scenario in ('storage', 'shop_return') then
    if not app_private.has_permission('damage.verify') then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  else
    raise exception 'damage scenario is invalid' using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.lock_damage_stock_grains(
  target_godown uuid,
  crate_ids uuid[],
  product_ids uuid[],
  lot_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  locked_branch uuid;
begin
  perform app_private.acquire_stock_cutover_shared_lock();

  -- Match confirm_dispatch / apply_lot_aware_stock_deltas:
  -- products, then zones → crates → branch, then lots.
  if product_ids is not null and cardinality(product_ids) > 0 then
    perform products.id
    from public.products
    where products.id = any (product_ids)
    order by products.id
    for update;
  end if;

  if crate_ids is not null and cardinality(crate_ids) > 0 then
    locked_branch := app_private.prepare_stock_locations(crate_ids);
    if locked_branch is distinct from target_godown then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  end if;

  if lot_ids is not null and cardinality(lot_ids) > 0 then
    perform stock_lots.id
    from public.stock_lots
    where stock_lots.id = any (lot_ids)
    order by stock_lots.id
    for update;
  end if;
end;
$$;

create or replace function app_private.damage_storage_object_bytes(object_path text)
returns bytea
language plpgsql
security definer
set search_path = ''
as $$
declare
  headers jsonb := '{}'::jsonb;
  auth_header text;
  api_key text;
  response extensions.http_response;
  base_url text;
  stored bytea;
  declared_length bigint;
  content_type text;
  header_row extensions.http_header;
  bases text[] := array[
    'http://kong:8000',
    'http://supabase_kong_sherlyos:8000'
  ];
begin
  -- Path is taken from damage_evidence.storage_path, never from the client.
  if object_path is null
    or object_path !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return null;
  end if;

  begin
    headers := pg_catalog.current_setting('request.headers', true)::jsonb;
  exception
    when others then
      headers := '{}'::jsonb;
  end;

  auth_header := coalesce(
    nullif(headers ->> 'authorization', ''),
    nullif(pg_catalog.current_setting('request.header.authorization', true), '')
  );
  api_key := coalesce(
    nullif(headers ->> 'apikey', ''),
    nullif(pg_catalog.current_setting('request.header.apikey', true), '')
  );

  if auth_header is null or btrim(auth_header) = '' then
    return null;
  end if;
  if auth_header not like 'Bearer %' then
    auth_header := 'Bearer ' || auth_header;
  end if;
  if api_key is null or btrim(api_key) = '' then
    api_key := pg_catalog.replace(auth_header, 'Bearer ', '');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

  foreach base_url in array bases
  loop
    declared_length := null;
    content_type := null;
    stored := null;
    begin
      select *
      into response
      from extensions.http((
        'GET',
        base_url || '/storage/v1/object/stock-damage-evidence/' || object_path,
        array[
          extensions.http_header('Authorization', auth_header),
          extensions.http_header('apikey', api_key)
        ],
        null,
        null
      )::extensions.http_request);
    exception
      when others then
        response := null;
    end;

    if response.status = 200 and response.content is not null then
      content_type := pg_catalog.lower(coalesce(response.content_type, ''));
      if content_type like '%json%' or content_type like '%text/%' then
        continue;
      end if;

      stored := extensions.text_to_bytea(response.content);
      if stored is null
        or pg_catalog.octet_length(stored) < 3
        or pg_catalog.octet_length(stored) > 10485760
      then
        stored := null;
        continue;
      end if;

      if response.headers is not null then
        foreach header_row in array response.headers
        loop
          if pg_catalog.lower(header_row.field) in ('content-length', 'contentlength') then
            begin
              declared_length := btrim(header_row.value)::bigint;
            exception
              when others then
                declared_length := null;
            end;
          end if;
        end loop;
      end if;

      if declared_length is not null
        and declared_length is distinct from pg_catalog.octet_length(stored)
      then
        stored := null;
        continue;
      end if;

      perform extensions.http_reset_curlopt();
      return stored;
    end if;
  end loop;

  perform extensions.http_reset_curlopt();
  return null;
end;
$$;
