-- M6.4 REF-07. Optional refill-to-receipt linkage and read-only reconciliation.
-- Multiple partial receipts per approved request. verify_stock_receipt is unchanged.
-- Unlinked Branch 03 receiving stays valid. Zero stock from linkage itself.
-- Does not flip damage.stock_hold_ready or lot cutover flags.

alter table public.stock_receipts
  add column if not exists refill_request_id uuid
    references public.stock_refill_requests (id) on delete restrict;

create index if not exists stock_receipts_refill_request_idx
  on public.stock_receipts (refill_request_id)
  where refill_request_id is not null;

comment on column public.stock_receipts.refill_request_id is
  'Optional approved refill request. Null keeps ordinary unlinked receiving. Linkage does not post stock.';

create or replace function app_private.stock_refill_receiving_snapshot(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  requested integer := 0;
  accepted integer := 0;
  damaged integer := 0;
  pending integer := 0;
  outstanding integer := 0;
  excess integer := 0;
  label text;
begin
  -- Posted accepted only. Draft/submitted/held never count as inventory.
  select coalesce(sum(stock_refill_request_lines.requested_cases), 0)
  into requested
  from public.stock_refill_request_lines
  where stock_refill_request_lines.refill_request_id = target_request;

  select
    coalesce(sum(stock_receipt_lines.accepted_cases) filter (
      where stock_receipts.status = 'posted'
    ), 0),
    coalesce(sum(stock_receipt_lines.damaged_cases) filter (
      where stock_receipts.status = 'posted'
    ), 0),
    coalesce(sum(stock_receipt_lines.counted_cases) filter (
      where stock_receipts.status in ('submitted', 'held')
    ), 0)
  into accepted, damaged, pending
  from public.stock_receipts
  join public.stock_receipt_lines
    on stock_receipt_lines.receipt_id = stock_receipts.id
  where stock_receipts.refill_request_id = target_request;

  outstanding := greatest(requested - accepted, 0);
  excess := greatest(accepted - requested, 0);

  label := case
    when excess > 0 then 'excess_requires_review'
    when accepted > 0 and outstanding = 0 then 'fully_received'
    when accepted > 0 then 'partially_received'
    when pending > 0 then 'pending_verification'
    else 'not_started'
  end;

  return pg_catalog.jsonb_build_object(
    'summary', pg_catalog.jsonb_build_object(
      'requested_cases', requested,
      'accepted_cases', accepted,
      'outstanding_cases', outstanding,
      'excess_cases', excess,
      'damaged_cases', damaged,
      'pending_receipt_cases', pending,
      'completion_label', label
    ),
    'lines', coalesce((
      select pg_catalog.jsonb_agg(line_payload order by line_payload ->> 'product_sku')
      from (
        select pg_catalog.jsonb_build_object(
          'product_id', stock_refill_request_lines.product_id,
          'product_sku', products.sku,
          'product_name', products.name,
          'requested_cases', stock_refill_request_lines.requested_cases,
          'accepted_cases', coalesce(posted.accepted_cases, 0),
          'outstanding_cases', greatest(
            stock_refill_request_lines.requested_cases - coalesce(posted.accepted_cases, 0),
            0
          ),
          'excess_cases', greatest(
            coalesce(posted.accepted_cases, 0) - stock_refill_request_lines.requested_cases,
            0
          ),
          'damaged_cases', coalesce(posted.damaged_cases, 0),
          'pending_receipt_cases', coalesce(open_rows.pending_cases, 0)
        ) as line_payload
        from public.stock_refill_request_lines
        join public.products on products.id = stock_refill_request_lines.product_id
        left join lateral (
          select
            coalesce(sum(stock_receipt_lines.accepted_cases), 0) as accepted_cases,
            coalesce(sum(stock_receipt_lines.damaged_cases), 0) as damaged_cases
          from public.stock_receipts
          join public.stock_receipt_lines
            on stock_receipt_lines.receipt_id = stock_receipts.id
          where stock_receipts.refill_request_id = target_request
            and stock_receipts.status = 'posted'
            and stock_receipt_lines.product_id = stock_refill_request_lines.product_id
        ) posted on true
        left join lateral (
          select coalesce(sum(stock_receipt_lines.counted_cases), 0) as pending_cases
          from public.stock_receipts
          join public.stock_receipt_lines
            on stock_receipt_lines.receipt_id = stock_receipts.id
          where stock_receipts.refill_request_id = target_request
            and stock_receipts.status in ('submitted', 'held')
            and stock_receipt_lines.product_id = stock_refill_request_lines.product_id
        ) open_rows on true
        where stock_refill_request_lines.refill_request_id = target_request
      ) lined
    ), '[]'::jsonb),
    'receipts', coalesce((
      select pg_catalog.jsonb_agg(receipt_payload order by created_at desc, id desc)
      from (
        select
          stock_receipts.created_at,
          stock_receipts.id,
          pg_catalog.jsonb_build_object(
            'id', stock_receipts.id,
            'receipt_number', stock_receipts.receipt_number,
            'status', stock_receipts.status,
            'document_reference', stock_receipts.document_reference,
            'received_date', stock_receipts.received_date,
            'verified_at', stock_receipts.verified_at,
            'posted_at', stock_receipts.posted_at,
            'accepted_cases', coalesce((
              select sum(stock_receipt_lines.accepted_cases)
              from public.stock_receipt_lines
              where stock_receipt_lines.receipt_id = stock_receipts.id
            ), 0),
            'damaged_cases', coalesce((
              select sum(stock_receipt_lines.damaged_cases)
              from public.stock_receipt_lines
              where stock_receipt_lines.receipt_id = stock_receipts.id
            ), 0),
            'counted_cases', coalesce((
              select sum(stock_receipt_lines.counted_cases)
              from public.stock_receipt_lines
              where stock_receipt_lines.receipt_id = stock_receipts.id
            ), 0)
          ) as receipt_payload
        from public.stock_receipts
        where stock_receipts.refill_request_id = target_request
      ) listed
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.stock_refill_receiving_snapshot(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_refill_receipt_header(
  target_request uuid,
  target_godown uuid,
  target_supplier uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  request public.stock_refill_requests;
begin
  if target_request is null then
    return;
  end if;

  -- Lock the request before location grains so create cannot invert verify order.
  select * into request
  from public.stock_refill_requests
  where stock_refill_requests.id = target_request
  for share;

  if request.id is null then
    raise exception 'refill request was not found' using errcode = '42501';
  end if;

  if request.status is distinct from 'approved' then
    raise exception 'refill request is not approved' using errcode = '42501';
  end if;

  if request.supplier_id is distinct from target_supplier
    or request.destination_godown_id is distinct from target_godown
  then
    raise exception 'refill request supplier or godown does not match'
      using errcode = '42501';
  end if;

  perform app_private.assert_operational_active_branch(target_godown);
end;
$$;

create or replace function app_private.assert_refill_receipt_quantities(target_receipt uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
begin
  select * into selected
  from public.stock_receipts
  where stock_receipts.id = target_receipt;

  if selected.refill_request_id is null then
    return;
  end if;

  if exists (
    select 1
    from public.stock_receipt_lines
    left join public.stock_refill_request_lines
      on stock_refill_request_lines.refill_request_id = selected.refill_request_id
     and stock_refill_request_lines.product_id = stock_receipt_lines.product_id
    where stock_receipt_lines.receipt_id = selected.id
      and stock_refill_request_lines.id is null
  ) then
    raise exception 'linked receipt lines must be products on the refill request'
      using errcode = '23514';
  end if;

  -- Linked-workflow excess guard. Does not change verify_stock_receipt.
  -- No refill-header lock here: location locks may already be held.
  if exists (
    select 1
    from public.stock_receipt_lines current_line
    join public.stock_refill_request_lines request_line
      on request_line.refill_request_id = selected.refill_request_id
     and request_line.product_id = current_line.product_id
    where current_line.receipt_id = selected.id
      and current_line.accepted_cases + coalesce((
        select sum(other_line.accepted_cases)
        from public.stock_receipts other_receipt
        join public.stock_receipt_lines other_line
          on other_line.receipt_id = other_receipt.id
        where other_receipt.refill_request_id = selected.refill_request_id
          and other_receipt.status = 'posted'
          and other_receipt.id is distinct from selected.id
          and other_line.product_id = current_line.product_id
      ), 0) > request_line.requested_cases
  ) then
    raise exception 'linked receipt would exceed requested cases'
      using errcode = '23514';
  end if;
end;
$$;

drop function if exists app_private.assert_refill_receipt_link(uuid);
revoke all on function app_private.assert_refill_receipt_header(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_refill_receipt_quantities(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.stock_receipt_payload(target uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'id', stock_receipts.id,
    'receipt_number', stock_receipts.receipt_number,
    'godown_id', stock_receipts.godown_id,
    'godown_code', branches.code,
    'godown_name', branches.name,
    'supplier_id', stock_receipts.supplier_id,
    'supplier_name', suppliers.name,
    'document_reference', stock_receipts.document_reference,
    'received_date', stock_receipts.received_date,
    'status', stock_receipts.status,
    'notes', stock_receipts.notes,
    'hold_reason', stock_receipts.hold_reason,
    'created_by', stock_receipts.created_by,
    'creator_name', creator.full_name,
    'created_at', stock_receipts.created_at,
    'updated_at', stock_receipts.updated_at,
    'verified_by', stock_receipts.verified_by,
    'verifier_name', verifier.full_name,
    'verified_at', stock_receipts.verified_at,
    'posted_at', stock_receipts.posted_at,
    'cancelled_by', stock_receipts.cancelled_by,
    'canceller_name', canceller.full_name,
    'cancelled_at', stock_receipts.cancelled_at,
    'cancellation_reason', stock_receipts.cancellation_reason,
    'refill_request_id', stock_receipts.refill_request_id,
    'refill_request_number', refill.request_number,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_receipt_lines.id,
          'product_id', stock_receipt_lines.product_id,
          'product_sku', products.sku,
          'product_name', products.name,
          'expiry_policy', products.expiry_policy,
          'zone_id', zones.id,
          'zone_code', zones.code,
          'destination_crate_id', stock_receipt_lines.destination_crate_id,
          'crate_code', crates.code,
          'document_cases', stock_receipt_lines.document_cases,
          'counted_cases', stock_receipt_lines.counted_cases,
          'damaged_cases', stock_receipt_lines.damaged_cases,
          'accepted_cases', stock_receipt_lines.accepted_cases,
          'lot_attributions', coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'id', attr.id,
                'carton_quantity', attr.carton_quantity,
                'manufacturer_lot_code', attr.manufacturer_lot_code,
                'manufactured_on', attr.manufactured_on,
                'expiry_date', attr.expiry_date,
                'sort_order', attr.sort_order
              )
              order by attr.sort_order, attr.id
            )
            from public.stock_receipt_line_lot_attributions attr
            where attr.receipt_line_id = stock_receipt_lines.id
          ), '[]'::jsonb)
        )
        order by stock_receipt_lines.created_at, stock_receipt_lines.id
      )
      from public.stock_receipt_lines
      join public.products on products.id = stock_receipt_lines.product_id
      join public.crates on crates.id = stock_receipt_lines.destination_crate_id
      join public.zones on zones.id = crates.zone_id
      where stock_receipt_lines.receipt_id = stock_receipts.id
    ), '[]'::jsonb),
    'transactions', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_transactions.id,
          'reference_number', stock_transactions.reference_number,
          'receipt_line_id', stock_transactions.receipt_line_id,
          'quantity', stock_transactions.quantity
        )
        order by stock_transactions.reference_number
      )
      from public.stock_transactions
      where stock_transactions.receipt_id = stock_receipts.id
    ), '[]'::jsonb),
    'audit', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'action', audit_logs.action,
          'actor_name', profiles.full_name,
          'occurred_at', audit_logs.occurred_at,
          'metadata', audit_logs.metadata
        )
        order by audit_logs.occurred_at, audit_logs.id
      )
      from public.audit_logs
      left join public.profiles on profiles.id = audit_logs.actor_id
      where audit_logs.entity_table = 'stock_receipts'
        and audit_logs.entity_id = stock_receipts.id
    ), '[]'::jsonb)
  )
  from public.stock_receipts
  join public.branches on branches.id = stock_receipts.godown_id
  join public.suppliers on suppliers.id = stock_receipts.supplier_id
  join public.profiles as creator on creator.id = stock_receipts.created_by
  left join public.profiles as verifier on verifier.id = stock_receipts.verified_by
  left join public.profiles as canceller on canceller.id = stock_receipts.cancelled_by
  left join public.stock_refill_requests refill
    on refill.id = stock_receipts.refill_request_id
  where stock_receipts.id = target;
$$;

drop function if exists public.create_stock_receipt(uuid, uuid, text, date, text, jsonb);
drop function if exists public.update_stock_receipt(uuid, uuid, uuid, text, date, text, jsonb);

create or replace function public.create_stock_receipt(
  target_godown uuid,
  target_supplier uuid,
  supplier_document text,
  received_on date,
  receipt_notes text,
  line_items jsonb,
  target_refill_request uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  document_text text;
  normalized_text text;
begin
  perform app_private.assert_permission('receiving.execute');

  if target_godown is null
    or not app_private.can_work_at_branch(target_godown)
    or not exists (
      select 1 from public.branches
      where branches.id = target_godown and branches.is_active
    ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if received_on is null then
    raise exception 'received date is required' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.suppliers
    where suppliers.id = target_supplier and suppliers.is_active
  ) then
    raise exception 'supplier is inactive or missing' using errcode = '23514';
  end if;

  document_text := pg_catalog.btrim(coalesce(supplier_document, ''));
  normalized_text := app_private.normalize_document_reference(document_text);

  perform app_private.assert_refill_receipt_header(
    target_refill_request, target_godown, target_supplier
  );

  insert into public.stock_receipts (
    receipt_number, godown_id, supplier_id, document_reference,
    normalized_document_reference, received_date, notes, created_by, refill_request_id
  )
  values (
    'RC-'
      || pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0'),
    target_godown,
    target_supplier,
    document_text,
    normalized_text,
    received_on,
    app_private.clean_receipt_notes(receipt_notes),
    auth.uid(),
    target_refill_request
  )
  returning id into created_id;

  perform app_private.replace_receipt_lines(created_id, line_items);
  perform app_private.assert_refill_receipt_quantities(created_id);

  perform app_private.write_audit(
    auth.uid(),
    'create_stock_receipt',
    'stock_receipts',
    created_id,
    pg_catalog.jsonb_build_object(
      'godown_id', target_godown,
      'supplier_id', target_supplier,
      'document_reference', document_text,
      'refill_request_id', target_refill_request
    )
  );

  return app_private.stock_receipt_payload(created_id);
exception
  when unique_violation then
    raise exception 'document reference was already used' using errcode = '23505';
end;
$$;

create or replace function public.update_stock_receipt(
  target_receipt uuid,
  target_godown uuid,
  target_supplier uuid,
  supplier_document text,
  received_on date,
  receipt_notes text,
  line_items jsonb,
  target_refill_request uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
  document_text text;
  normalized_text text;
begin
  perform app_private.assert_permission('receiving.execute');
  selected := app_private.lock_stock_receipt(target_receipt);

  if selected.created_by is distinct from auth.uid()
    or selected.status is distinct from 'draft' then
    raise exception 'receipt cannot be edited' using errcode = '42501';
  end if;

  if target_godown is null
    or not app_private.can_work_at_branch(target_godown)
    or not exists (
      select 1 from public.branches
      where branches.id = target_godown and branches.is_active
    ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if received_on is null then
    raise exception 'received date is required' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.suppliers
    where suppliers.id = target_supplier and suppliers.is_active
  ) then
    raise exception 'supplier is inactive or missing' using errcode = '23514';
  end if;

  document_text := pg_catalog.btrim(coalesce(supplier_document, ''));
  normalized_text := app_private.normalize_document_reference(document_text);

  perform app_private.assert_refill_receipt_header(
    target_refill_request, target_godown, target_supplier
  );

  update public.stock_receipts
  set
    godown_id = target_godown,
    supplier_id = target_supplier,
    document_reference = document_text,
    normalized_document_reference = normalized_text,
    received_date = received_on,
    notes = app_private.clean_receipt_notes(receipt_notes),
    refill_request_id = target_refill_request
  where stock_receipts.id = selected.id;

  perform app_private.replace_receipt_lines(selected.id, line_items);
  perform app_private.assert_refill_receipt_quantities(selected.id);

  perform app_private.write_audit(
    auth.uid(),
    'update_stock_receipt',
    'stock_receipts',
    selected.id,
    pg_catalog.jsonb_build_object(
      'document_reference', document_text,
      'refill_request_id', target_refill_request
    )
  );

  return app_private.stock_receipt_payload(selected.id);
exception
  when unique_violation then
    raise exception 'document reference was already used' using errcode = '23505';
end;
$$;

create or replace function public.list_stock_receipts()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(row_payload order by created_at desc)
    from (
      select
        stock_receipts.created_at,
        pg_catalog.jsonb_build_object(
          'id', stock_receipts.id,
          'receipt_number', stock_receipts.receipt_number,
          'godown_id', stock_receipts.godown_id,
          'godown_code', branches.code,
          'godown_name', branches.name,
          'supplier_name', suppliers.name,
          'document_reference', stock_receipts.document_reference,
          'received_date', stock_receipts.received_date,
          'status', stock_receipts.status,
          'creator_name', profiles.full_name,
          'created_by', stock_receipts.created_by,
          'verified_at', stock_receipts.verified_at,
          'posted_at', stock_receipts.posted_at,
          'refill_request_id', stock_receipts.refill_request_id,
          'refill_request_number', refill.request_number
        ) as row_payload
      from public.stock_receipts
      join public.branches on branches.id = stock_receipts.godown_id
      join public.suppliers on suppliers.id = stock_receipts.supplier_id
      join public.profiles on profiles.id = stock_receipts.created_by
      left join public.stock_refill_requests refill
        on refill.id = stock_receipts.refill_request_id
      where app_private.can_view_stock_receipt(stock_receipts)
    ) as visible
  ), '[]'::jsonb);
end;
$$;

create or replace function public.list_receiving_options()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'godowns', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', branches.id, 'code', branches.code, 'name', branches.name)
        order by branches.name
      )
      from public.branches
      where branches.is_active and app_private.can_work_at_branch(branches.id)
    ), '[]'::jsonb),
    'suppliers', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', suppliers.id, 'name', suppliers.name)
        order by suppliers.name
      )
      from public.suppliers where suppliers.is_active
    ), '[]'::jsonb),
    'products', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', products.id, 'sku', products.sku, 'name', products.name,
          'expiry_policy', products.expiry_policy
        )
        order by products.name
      )
      from public.products where products.is_active
    ), '[]'::jsonb),
    'zones', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', zones.id, 'branch_id', zones.branch_id, 'code', zones.code, 'name', zones.name
        )
        order by zones.code
      )
      from public.zones
      where zones.is_active and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb),
    'crates', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', crates.id, 'zone_id', crates.zone_id, 'code', crates.code, 'name', crates.name
        )
        order by crates.code
      )
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.is_active and zones.is_active
        and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb),
    'refill_requests', coalesce((
      select pg_catalog.jsonb_agg(item order by item ->> 'request_number' desc)
      from (
        select pg_catalog.jsonb_build_object(
          'id', stock_refill_requests.id,
          'request_number', stock_refill_requests.request_number,
          'supplier_id', stock_refill_requests.supplier_id,
          'destination_godown_id', stock_refill_requests.destination_godown_id,
          'supplier_name', suppliers.name,
          'godown_name', branches.name
        ) as item
        from public.stock_refill_requests
        join public.suppliers on suppliers.id = stock_refill_requests.supplier_id
        join public.branches on branches.id = stock_refill_requests.destination_godown_id
        where stock_refill_requests.status = 'approved'
          and branches.is_active
          and app_private.can_work_at_branch(stock_refill_requests.destination_godown_id)
          and (
            app_private.has_permission('receiving.execute')
            or app_private.has_permission('receiving.verify')
          )
      ) eligible
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_stock_refill_receiving_reconciliation(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  allowed boolean := false;
begin
  select * into selected
  from public.stock_refill_requests
  where stock_refill_requests.id = target_request;

  if selected.id is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if app_private.can_view_refill_at_godown(selected.destination_godown_id) then
    allowed := true;
  elsif (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
  ) and app_private.can_work_at_branch(selected.destination_godown_id) then
    allowed := true;
  end if;

  if not allowed then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', selected.id,
    'request_number', selected.request_number,
    'supplier_id', selected.supplier_id,
    'destination_godown_id', selected.destination_godown_id,
    'status', selected.status,
    'receiving', app_private.stock_refill_receiving_snapshot(selected.id)
  );
end;
$$;

-- Append receiving snapshot to the existing refill payload without changing approval fields.
create or replace function app_private.stock_refill_request_payload(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  communication public.stock_refill_supplier_communications;
  dispatch public.stock_refill_supplier_dispatches;
  payload jsonb;
begin
  select *
  into selected
  from public.stock_refill_requests
  where stock_refill_requests.id = target_request;

  if not found
    or not app_private.can_view_refill_at_godown(selected.destination_godown_id)
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into communication
  from public.stock_refill_supplier_communications
  where stock_refill_supplier_communications.refill_request_id = selected.id;

  select *
  into dispatch
  from public.stock_refill_supplier_dispatches
  where stock_refill_supplier_dispatches.refill_request_id = selected.id;

  payload := pg_catalog.jsonb_build_object(
    'id', selected.id,
    'request_number', selected.request_number,
    'supplier_id', selected.supplier_id,
    'supplier_name', (select suppliers.name from public.suppliers where suppliers.id = selected.supplier_id),
    'destination_godown_id', selected.destination_godown_id,
    'godown_code', (select branches.code from public.branches where branches.id = selected.destination_godown_id),
    'godown_name', (select branches.name from public.branches where branches.id = selected.destination_godown_id),
    'godown_active', (select branches.is_active from public.branches where branches.id = selected.destination_godown_id),
    'status', selected.status,
    'notes', selected.notes,
    'version', selected.version,
    'created_by', selected.created_by,
    'creator_name', (select profiles.full_name from public.profiles where profiles.id = selected.created_by),
    'created_at', selected.created_at,
    'updated_by', selected.updated_by,
    'updated_at', selected.updated_at,
    'submitted_by', selected.submitted_by,
    'submitted_at', selected.submitted_at,
    'held_by', selected.held_by,
    'held_at', selected.held_at,
    'hold_reason', selected.hold_reason,
    'decided_by', selected.decided_by,
    'decided_at', selected.decided_at,
    'decision_reason', selected.decision_reason,
    'communication_status', case when communication.id is null then 'not_sent' else 'sent' end,
    'acknowledgement_status', case
      when communication.id is null then 'none'
      else communication.acknowledgement_status
    end,
    'dispatch_status', case when dispatch.id is null then 'not_recorded' else 'recorded' end,
    'expected_arrival_on', dispatch.expected_arrival_on,
    'total_requested_cases', coalesce((
      select sum(stock_refill_request_lines.requested_cases)
      from public.stock_refill_request_lines
      where stock_refill_request_lines.refill_request_id = selected.id
    ), 0),
    'communication', case when communication.id is null then null else pg_catalog.jsonb_build_object(
      'id', communication.id,
      'channel', communication.channel,
      'communicated_at', communication.communicated_at,
      'external_reference', communication.external_reference,
      'notes', communication.notes,
      'recorded_by', communication.recorded_by,
      'recorder_name', (select profiles.full_name from public.profiles where profiles.id = communication.recorded_by),
      'recorded_at', communication.recorded_at,
      'acknowledgement_status', communication.acknowledgement_status,
      'acknowledgement_at', communication.acknowledgement_at,
      'acknowledgement_reference', communication.acknowledgement_reference,
      'acknowledgement_notes', communication.acknowledgement_notes,
      'acknowledgement_reason', communication.acknowledgement_reason,
      'acknowledged_by', communication.acknowledged_by,
      'acknowledger_name', (select profiles.full_name from public.profiles where profiles.id = communication.acknowledged_by),
      'acknowledged_recorded_at', communication.acknowledged_recorded_at
    ) end,
    'dispatch', case when dispatch.id is null then null else pg_catalog.jsonb_build_object(
      'id', dispatch.id,
      'supplier_dispatch_reference', dispatch.supplier_dispatch_reference,
      'dispatched_on', dispatch.dispatched_on,
      'expected_arrival_on', dispatch.expected_arrival_on,
      'transport_provider', dispatch.transport_provider,
      'vehicle_reference', dispatch.vehicle_reference,
      'tracking_reference', dispatch.tracking_reference,
      'notes', dispatch.notes,
      'recorded_by', dispatch.recorded_by,
      'recorder_name', (select profiles.full_name from public.profiles where profiles.id = dispatch.recorded_by),
      'recorded_at', dispatch.recorded_at,
      'updated_by', dispatch.updated_by,
      'updated_at', dispatch.updated_at
    ) end,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_refill_request_lines.id,
          'product_id', stock_refill_request_lines.product_id,
          'product_sku', products.sku,
          'product_name', products.name,
          'requested_cases', stock_refill_request_lines.requested_cases
        )
        order by products.sku, stock_refill_request_lines.id
      )
      from public.stock_refill_request_lines
      join public.products on products.id = stock_refill_request_lines.product_id
      where stock_refill_request_lines.refill_request_id = selected.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_refill_request_events.id,
          'action', stock_refill_request_events.action,
          'previous_status', stock_refill_request_events.previous_status,
          'next_status', stock_refill_request_events.next_status,
          'reason', stock_refill_request_events.reason,
          'version', stock_refill_request_events.version,
          'actor_id', stock_refill_request_events.actor_id,
          'actor_name', profiles.full_name,
          'created_at', stock_refill_request_events.created_at
        )
        order by stock_refill_request_events.created_at, stock_refill_request_events.id
      )
      from public.stock_refill_request_events
      join public.profiles on profiles.id = stock_refill_request_events.actor_id
      where stock_refill_request_events.refill_request_id = selected.id
    ), '[]'::jsonb)
  );

  return payload || pg_catalog.jsonb_build_object(
    'receiving', app_private.stock_refill_receiving_snapshot(selected.id)
  );
end;
$$;

revoke all on function public.create_stock_receipt(uuid, uuid, text, date, text, jsonb, uuid)
  from public, anon, service_role;
revoke all on function public.update_stock_receipt(uuid, uuid, uuid, text, date, text, jsonb, uuid)
  from public, anon, service_role;
revoke all on function public.get_stock_refill_receiving_reconciliation(uuid)
  from public, anon, service_role;
revoke all on function public.list_receiving_options() from public, anon, service_role;
revoke all on function public.list_stock_receipts() from public, anon, service_role;

grant execute on function public.create_stock_receipt(uuid, uuid, text, date, text, jsonb, uuid)
  to authenticated;
grant execute on function public.update_stock_receipt(uuid, uuid, uuid, text, date, text, jsonb, uuid)
  to authenticated;
grant execute on function public.get_stock_refill_receiving_reconciliation(uuid)
  to authenticated;
grant execute on function public.list_receiving_options() to authenticated;
grant execute on function public.list_stock_receipts() to authenticated;

comment on function public.create_stock_receipt(uuid, uuid, text, date, text, jsonb, uuid) is
  'Branch 03 draft receipt. Optional refill_request_id. Zero stock until verify_stock_receipt.';
comment on function public.get_stock_refill_receiving_reconciliation(uuid) is
  'M6.4 read-only per-SKU refill vs posted receipt reconciliation. No stock writes.';

notify pgrst, 'reload schema';
