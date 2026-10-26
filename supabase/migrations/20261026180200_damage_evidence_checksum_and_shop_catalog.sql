-- M5.4B hardening: bind photo finalization to Storage-recorded checksums
-- (same contract as verification photos) and paginate shop-return products.
-- Does not flip damage.stock_hold_ready or lot cutover flags.
-- Postgres still cannot read S3 bytes; finalize fails closed unless the
-- catalog eTag/size/mime recorded at upload match the submitted payload.

create or replace function public.finalize_damage_photo_upload(
  target_evidence uuid,
  image_base64 text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  evidence public.damage_evidence;
  cleaned text;
  payload bytea;
  object_metadata jsonb;
  object_owner uuid;
  object_size bigint;
  object_etag text;
  object_mime text;
  detected_mime text;
begin
  perform set_config('app.damage_write', 'on', true);

  select *
  into evidence
  from public.damage_evidence
  where damage_evidence.id = target_evidence
  for update;

  if not found or evidence.uploaded_by is distinct from auth.uid() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  selected := app_private.lock_damage_report(evidence.damage_report_id);

  if selected.status not in ('draft', 'returned', 'submitted')
    or evidence.verified_at is not null
  then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  cleaned := pg_catalog.replace(pg_catalog.btrim(coalesce(image_base64, '')), E'\n', '');
  if cleaned like 'data:%' then
    cleaned := pg_catalog.split_part(cleaned, ',', 2);
  end if;

  if cleaned = '' or pg_catalog.char_length(cleaned) > 14000000 then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  begin
    payload := pg_catalog.decode(cleaned, 'base64');
  exception
    when others then
      raise exception 'photo content could not be verified' using errcode = '23514';
  end;

  if payload is null
    or pg_catalog.octet_length(payload) < 3
    or pg_catalog.octet_length(payload) > 10485760
  then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  -- Require the Storage catalog row from an actual upload. Do not rewrite
  -- catalog checksums from the client payload — that would treat base64 as
  -- proof of stored bytes. Compare Storage-recorded size, mime, and eTag.
  select storage.objects.metadata, storage.objects.owner
  into object_metadata, object_owner
  from storage.objects
  where storage.objects.bucket_id = 'stock-damage-evidence'
    and storage.objects.name = evidence.storage_path;

  if not found then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  if object_owner is not null and object_owner is distinct from evidence.uploaded_by then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  begin
    object_size := coalesce(
      object_metadata ->> 'size',
      object_metadata ->> 'contentLength'
    )::bigint;
  exception
    when others then
      object_size := null;
  end;

  object_etag := pg_catalog.lower(pg_catalog.replace(
    coalesce(object_metadata ->> 'eTag', object_metadata ->> 'etag', ''),
    '"',
    ''
  ));
  object_mime := pg_catalog.lower(coalesce(
    object_metadata ->> 'mimetype',
    object_metadata ->> 'mimeType',
    object_metadata ->> 'contentType',
    ''
  ));
  detected_mime := app_private.detected_image_mime(payload);

  if detected_mime is null
    or detected_mime <> object_mime
    or object_size is distinct from pg_catalog.octet_length(payload)
    or object_etag = ''
    or object_etag is distinct from pg_catalog.encode(extensions.digest(payload, 'md5'), 'hex')
  then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  update public.damage_evidence
  set
    mime_type = detected_mime,
    file_size = pg_catalog.octet_length(payload),
    verified_at = pg_catalog.clock_timestamp()
  where damage_evidence.id = evidence.id;

  perform app_private.record_damage_event(
    selected.id, 'evidence_attached', selected.status, selected.status,
    pg_catalog.jsonb_build_object(
      'evidence_id', evidence.id,
      'mime_type', detected_mime
    )
  );
end;
$$;

drop function if exists public.list_damage_report_sources(text, uuid, text, integer, integer);

create function public.list_damage_report_sources(
  scenario text,
  target_godown uuid,
  search_text text default null,
  page integer default 1,
  page_size integer default 50,
  catalog_search text default null,
  catalog_page integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_scenario text := pg_catalog.lower(pg_catalog.btrim(coalesce(scenario, '')));
  cleaned_search text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(search_text, ''))), '');
  cleaned_catalog text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(catalog_search, ''))), '');
  safe_page integer := greatest(coalesce(page, 1), 1);
  safe_size integer := least(greatest(coalesce(page_size, 50), 1), 50);
  safe_catalog_page integer := greatest(coalesce(catalog_page, 1), 1);
  total_count integer := 0;
  product_total integer := 0;
  items jsonb := '[]'::jsonb;
  catalogs jsonb := '{}'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_godown is null then
    raise exception 'godown is required' using errcode = '23514';
  end if;

  if cleaned_scenario not in (
    'refill_supply', 'unloading', 'storage', 'loading', 'transit', 'shop_return'
  ) then
    raise exception 'damage scenario is invalid' using errcode = '23514';
  end if;

  if cleaned_scenario = 'transit' then
    if not (
      app_private.has_permission('damage.record')
      or app_private.has_permission('deliveries.execute')
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if not app_private.can_complete_consumed_delivery_at_branch(target_godown) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  else
    perform app_private.assert_damage_create_auth(cleaned_scenario, target_godown, null);
  end if;

  if cleaned_search is not null then
    cleaned_search := replace(replace(replace(cleaned_search, '\', '\\'), '%', '\%'), '_', '\_');
  end if;
  if cleaned_catalog is not null then
    cleaned_catalog := replace(replace(replace(cleaned_catalog, '\', '\\'), '%', '\%'), '_', '\_');
  end if;

  if cleaned_scenario in ('refill_supply', 'unloading') then
    select count(*) into total_count
    from public.stock_receipts
    where stock_receipts.godown_id = target_godown
      and stock_receipts.status = 'posted'
      and exists (
        select 1 from public.stock_receipt_lines
        where stock_receipt_lines.receipt_id = stock_receipts.id
          and stock_receipt_lines.damaged_cases > 0
      )
      and (
        cleaned_search is null
        or pg_catalog.lower(stock_receipts.receipt_number) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', stock_receipts.id,
        'kind', 'receipt',
        'label', stock_receipts.receipt_number,
        'godown_id', stock_receipts.godown_id,
        'receipt_id', stock_receipts.id,
        'received_date', stock_receipts.received_date,
        'supplier_name', suppliers.name,
        'lines', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'receipt_line_id', stock_receipt_lines.id,
            'product_id', stock_receipt_lines.product_id,
            'product_sku', products.sku,
            'product_name', products.name,
            'crate_id', stock_receipt_lines.destination_crate_id,
            'crate_code', crates.code,
            'damaged_cases', stock_receipt_lines.damaged_cases,
            'already_reported', app_private.damage_open_receipt_qty(stock_receipt_lines.id, null),
            'remaining_cases', greatest(
              stock_receipt_lines.damaged_cases
              - app_private.damage_open_receipt_qty(stock_receipt_lines.id, null),
              0
            )
          ) order by stock_receipt_lines.id)
          from public.stock_receipt_lines
          join public.products on products.id = stock_receipt_lines.product_id
          left join public.crates on crates.id = stock_receipt_lines.destination_crate_id
          where stock_receipt_lines.receipt_id = stock_receipts.id
            and stock_receipt_lines.damaged_cases > 0
        ), '[]'::jsonb)
      ) as item
      from public.stock_receipts
      join public.suppliers on suppliers.id = stock_receipts.supplier_id
      where stock_receipts.godown_id = target_godown
        and stock_receipts.status = 'posted'
        and exists (
          select 1 from public.stock_receipt_lines
          where stock_receipt_lines.receipt_id = stock_receipts.id
            and stock_receipt_lines.damaged_cases > 0
        )
        and (
          cleaned_search is null
          or pg_catalog.lower(stock_receipts.receipt_number) like '%' || cleaned_search || '%' escape '\'
        )
      order by stock_receipts.received_date desc, stock_receipts.id desc
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;
  elsif cleaned_scenario = 'storage' then
    total_count := 1;
    items := pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', target_godown,
        'kind', 'godown',
        'label', (select branches.name from public.branches where branches.id = target_godown),
        'godown_id', target_godown
      )
    );
    catalogs := pg_catalog.jsonb_build_object(
      'crates', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', crates.id,
          'code', crates.code,
          'name', crates.name,
          'zone_code', zones.code
        ) order by crates.code)
        from public.crates
        join public.zones on zones.id = crates.zone_id
        where zones.branch_id = target_godown
          and crates.is_active
          and crates.location_role is distinct from 'quarantine'
      ), '[]'::jsonb),
      'products', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', products.id,
          'sku', products.sku,
          'name', products.name
        ) order by products.sku)
        from public.products
        where products.is_active
          and exists (
            select 1
            from public.stock_balances
            join public.crates on crates.id = stock_balances.crate_id
            join public.zones on zones.id = crates.zone_id
            where stock_balances.product_id = products.id
              and zones.branch_id = target_godown
              and stock_balances.quantity > 0
          )
      ), '[]'::jsonb),
      'balances', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'crate_id', stock_balances.crate_id,
          'product_id', stock_balances.product_id,
          'on_hand_cases', stock_balances.quantity
        ))
        from public.stock_balances
        join public.crates on crates.id = stock_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where zones.branch_id = target_godown
          and stock_balances.quantity > 0
      ), '[]'::jsonb)
    );
  elsif cleaned_scenario = 'loading' then
    select count(*) into total_count
    from public.stock_picking_requests
    where stock_picking_requests.branch_id = target_godown
      and stock_picking_requests.status in ('allocated', 'picking', 'picked', 'ready_for_dispatch')
      and (
        cleaned_search is null
        or pg_catalog.lower(stock_picking_requests.request_number) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', stock_picking_requests.id,
        'kind', 'picking',
        'label', stock_picking_requests.request_number,
        'godown_id', stock_picking_requests.branch_id,
        'picking_request_id', stock_picking_requests.id,
        'dispatch_id', preparing.id,
        'order_id', stock_picking_requests.order_id,
        'status', stock_picking_requests.status,
        'lines', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'product_id', grain.product_id,
            'product_sku', products.sku,
            'product_name', products.name,
            'crate_id', grain.crate_id,
            'crate_code', crates.code,
            'lot_id', grain.lot_id,
            'reserved_cases', grain.reserved_cases
          ) order by products.sku)
          from (
            select
              stock_reservations.product_id,
              stock_reservations.crate_id,
              stock_reservations.lot_id,
              sum(stock_reservations.reserved_cases)::integer as reserved_cases
            from public.stock_reservations
            where stock_reservations.picking_request_id = stock_picking_requests.id
              and stock_reservations.status = 'active'
            group by stock_reservations.product_id, stock_reservations.crate_id, stock_reservations.lot_id
          ) grain
          join public.products on products.id = grain.product_id
          join public.crates on crates.id = grain.crate_id
        ), '[]'::jsonb)
      ) as item
      from public.stock_picking_requests
      left join public.stock_dispatch_requests preparing
        on preparing.picking_request_id = stock_picking_requests.id
        and preparing.status = 'preparing'
        and preparing.stock_consumed = false
      where stock_picking_requests.branch_id = target_godown
        and stock_picking_requests.status in ('allocated', 'picking', 'picked', 'ready_for_dispatch')
        and (
          cleaned_search is null
          or pg_catalog.lower(stock_picking_requests.request_number) like '%' || cleaned_search || '%' escape '\'
        )
      order by stock_picking_requests.created_at desc, stock_picking_requests.id desc
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;
  elsif cleaned_scenario = 'transit' then
    select count(*) into total_count
    from public.stock_dispatch_requests
    where stock_dispatch_requests.branch_id = target_godown
      and stock_dispatch_requests.stock_consumed
      and stock_dispatch_requests.status in ('dispatched', 'in_transit', 'delivered', 'exception')
      and (
        app_private.has_permission('damage.record')
        or stock_dispatch_requests.assigned_to = auth.uid()
      )
      and (
        cleaned_search is null
        or pg_catalog.lower(stock_dispatch_requests.request_number) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', stock_dispatch_requests.id,
        'kind', 'dispatch_consumed',
        'label', stock_dispatch_requests.request_number,
        'godown_id', stock_dispatch_requests.branch_id,
        'dispatch_id', stock_dispatch_requests.id,
        'picking_request_id', stock_dispatch_requests.picking_request_id,
        'order_id', stock_dispatch_requests.order_id,
        'status', stock_dispatch_requests.status,
        'assigned_to', stock_dispatch_requests.assigned_to,
        'lines', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'product_id', grain.product_id,
            'product_sku', products.sku,
            'product_name', products.name,
            'crate_id', grain.crate_id,
            'crate_code', crates.code,
            'lot_id', grain.lot_id,
            'reserved_cases', grain.reserved_cases
          ) order by products.sku)
          from (
            select
              stock_reservations.product_id,
              stock_reservations.crate_id,
              stock_reservations.lot_id,
              sum(stock_reservations.reserved_cases)::integer as reserved_cases
            from public.stock_reservations
            where stock_reservations.picking_request_id = stock_dispatch_requests.picking_request_id
              and stock_reservations.status in ('active', 'consumed')
            group by stock_reservations.product_id, stock_reservations.crate_id, stock_reservations.lot_id
          ) grain
          join public.products on products.id = grain.product_id
          join public.crates on crates.id = grain.crate_id
        ), '[]'::jsonb)
      ) as item
      from public.stock_dispatch_requests
      where stock_dispatch_requests.branch_id = target_godown
        and stock_dispatch_requests.stock_consumed
        and stock_dispatch_requests.status in ('dispatched', 'in_transit', 'delivered', 'exception')
        and (
          app_private.has_permission('damage.record')
          or stock_dispatch_requests.assigned_to = auth.uid()
        )
        and (
          cleaned_search is null
          or pg_catalog.lower(stock_dispatch_requests.request_number) like '%' || cleaned_search || '%' escape '\'
        )
      order by stock_dispatch_requests.created_at desc, stock_dispatch_requests.id desc
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;
  elsif cleaned_scenario = 'shop_return' then
    select count(*) into total_count
    from public.shops
    where shops.is_active
      and (
        cleaned_search is null
        or pg_catalog.lower(shops.name) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', shops.id,
        'kind', 'shop',
        'label', shops.name,
        'godown_id', target_godown,
        'shop_id', shops.id
      ) as item
      from public.shops
      where shops.is_active
        and (
          cleaned_search is null
          or pg_catalog.lower(shops.name) like '%' || cleaned_search || '%' escape '\'
        )
      order by shops.name, shops.id
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;

    select count(*)::integer into product_total
    from public.products
    where products.is_active
      and (
        cleaned_catalog is null
        or pg_catalog.lower(products.sku) like '%' || cleaned_catalog || '%' escape '\'
        or pg_catalog.lower(products.name) like '%' || cleaned_catalog || '%' escape '\'
      );

    catalogs := pg_catalog.jsonb_build_object(
      'crates', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', crates.id,
          'code', crates.code,
          'name', crates.name,
          'zone_code', zones.code
        ) order by crates.code)
        from public.crates
        join public.zones on zones.id = crates.zone_id
        where zones.branch_id = target_godown
          and crates.is_active
          and crates.location_role is distinct from 'quarantine'
      ), '[]'::jsonb),
      'products', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', listed.id,
          'sku', listed.sku,
          'name', listed.name
        ))
        from (
          select products.id, products.sku, products.name
          from public.products
          where products.is_active
            and (
              cleaned_catalog is null
              or pg_catalog.lower(products.sku) like '%' || cleaned_catalog || '%' escape '\'
              or pg_catalog.lower(products.name) like '%' || cleaned_catalog || '%' escape '\'
            )
          order by products.sku, products.id
          offset (safe_catalog_page - 1) * safe_size
          limit safe_size
        ) listed
      ), '[]'::jsonb),
      'products_total', product_total,
      'products_page', safe_catalog_page
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'total', total_count,
    'page', safe_page,
    'page_size', safe_size,
    'items', coalesce(items, '[]'::jsonb),
    'catalogs', catalogs
  );
end;
$$;

revoke all on function public.list_damage_report_sources(text, uuid, text, integer, integer, text, integer)
  from public, anon, service_role;
grant execute on function public.list_damage_report_sources(text, uuid, text, integer, integer, text, integer)
  to authenticated;
