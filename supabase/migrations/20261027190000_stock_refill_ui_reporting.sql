-- M6.5 read-only refill queue/reporting. Zero stock writers.
-- verify_stock_receipt is unchanged. Unlinked receiving is unchanged.
-- Does not flip damage.stock_hold_ready or lot cutover flags.

-- Progress totals used by list, snapshot, and the refill report.
-- Reserved = accepted cases on every non-cancelled linked receipt.
-- Accepted = posted only. Drafts reserve requested quantity, not inventory.
create or replace function app_private.stock_refill_progress_totals(target_request uuid)
returns table (
  requested_cases integer,
  reserved_cases integer,
  draft_reserved_cases integer,
  accepted_cases integer,
  outstanding_cases integer,
  excess_cases integer,
  damaged_cases integer,
  pending_receipt_cases integer,
  completion_label text
)
language sql
stable
security definer
set search_path = ''
as $$
  with requested as (
    select coalesce(sum(stock_refill_request_lines.requested_cases), 0)::integer as requested_cases
    from public.stock_refill_request_lines
    where stock_refill_request_lines.refill_request_id = target_request
  ),
  receipts as (
    select
      coalesce(sum(stock_receipt_lines.accepted_cases) filter (
        where stock_receipts.status is distinct from 'cancelled'
      ), 0)::integer as reserved_cases,
      coalesce(sum(stock_receipt_lines.accepted_cases) filter (
        where stock_receipts.status = 'draft'
      ), 0)::integer as draft_reserved_cases,
      coalesce(sum(stock_receipt_lines.accepted_cases) filter (
        where stock_receipts.status = 'posted'
      ), 0)::integer as accepted_cases,
      coalesce(sum(stock_receipt_lines.damaged_cases) filter (
        where stock_receipts.status = 'posted'
      ), 0)::integer as damaged_cases,
      coalesce(sum(stock_receipt_lines.counted_cases) filter (
        where stock_receipts.status in ('submitted', 'held')
      ), 0)::integer as pending_receipt_cases
    from public.stock_receipts
    join public.stock_receipt_lines
      on stock_receipt_lines.receipt_id = stock_receipts.id
    where stock_receipts.refill_request_id = target_request
  )
  select
    requested.requested_cases,
    receipts.reserved_cases,
    receipts.draft_reserved_cases,
    receipts.accepted_cases,
    greatest(requested.requested_cases - receipts.accepted_cases, 0),
    greatest(receipts.accepted_cases - requested.requested_cases, 0),
    receipts.damaged_cases,
    receipts.pending_receipt_cases,
    case
      when greatest(receipts.accepted_cases - requested.requested_cases, 0) > 0
        then 'excess_requires_review'
      when receipts.accepted_cases > 0
        and greatest(requested.requested_cases - receipts.accepted_cases, 0) = 0
        then 'fully_received'
      when receipts.accepted_cases > 0 then 'partially_received'
      when receipts.pending_receipt_cases > 0 then 'pending_verification'
      else 'not_started'
    end
  from requested, receipts;
$$;

revoke all on function app_private.stock_refill_progress_totals(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.stock_refill_receiving_snapshot(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  progress record;
begin
  select * into progress
  from app_private.stock_refill_progress_totals(target_request);

  return pg_catalog.jsonb_build_object(
    'summary', pg_catalog.jsonb_build_object(
      'requested_cases', progress.requested_cases,
      'reserved_cases', progress.reserved_cases,
      'draft_reserved_cases', progress.draft_reserved_cases,
      'accepted_cases', progress.accepted_cases,
      'outstanding_cases', progress.outstanding_cases,
      'excess_cases', progress.excess_cases,
      'damaged_cases', progress.damaged_cases,
      'pending_receipt_cases', progress.pending_receipt_cases,
      'completion_label', progress.completion_label
    ),
    'lines', coalesce((
      select pg_catalog.jsonb_agg(line_payload order by line_payload ->> 'product_sku')
      from (
        select pg_catalog.jsonb_build_object(
          'product_id', stock_refill_request_lines.product_id,
          'product_sku', products.sku,
          'product_name', products.name,
          'requested_cases', stock_refill_request_lines.requested_cases,
          'reserved_cases', coalesce(open_rows.reserved_cases, 0),
          'draft_reserved_cases', coalesce(open_rows.draft_reserved_cases, 0),
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
          select
            coalesce(sum(stock_receipt_lines.accepted_cases) filter (
              where stock_receipts.status is distinct from 'cancelled'
            ), 0) as reserved_cases,
            coalesce(sum(stock_receipt_lines.accepted_cases) filter (
              where stock_receipts.status = 'draft'
            ), 0) as draft_reserved_cases,
            coalesce(sum(stock_receipt_lines.counted_cases) filter (
              where stock_receipts.status in ('submitted', 'held')
            ), 0) as pending_cases
          from public.stock_receipts
          join public.stock_receipt_lines
            on stock_receipt_lines.receipt_id = stock_receipts.id
          where stock_receipts.refill_request_id = target_request
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

-- Extra default args require DROP. Positional M6.2/M6.3 callers stay valid.
drop function if exists public.list_stock_refill_requests(
  integer, integer, text, uuid, uuid, text
);

create or replace function public.list_stock_refill_requests(
  page integer default 1,
  page_size integer default 25,
  status_filter text default null,
  target_godown uuid default null,
  target_supplier uuid default null,
  search_text text default null,
  communication_filter text default null,
  acknowledgement_filter text default null,
  dispatch_filter text default null,
  receiving_filter text default null,
  created_from timestamptz default null,
  created_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  safe_page integer := greatest(coalesce(page, 1), 1);
  safe_size integer := least(greatest(coalesce(page_size, 25), 1), 50);
  cleaned_search text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(search_text, ''))), '');
  total_count integer;
begin
  if auth.uid() is null
    or (
      not app_private.has_permission('refill.request')
      and not app_private.has_permission('refill.approve')
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if status_filter is not null
    and status_filter not in ('draft', 'submitted', 'held', 'approved', 'rejected')
  then
    raise exception 'status filter is invalid' using errcode = '23514';
  end if;
  if communication_filter is not null
    and communication_filter not in ('not_sent', 'sent')
  then
    raise exception 'communication filter is invalid' using errcode = '23514';
  end if;
  if acknowledgement_filter is not null
    and acknowledgement_filter not in ('none', 'pending', 'acknowledged', 'declined')
  then
    raise exception 'acknowledgement filter is invalid' using errcode = '23514';
  end if;
  if dispatch_filter is not null
    and dispatch_filter not in ('not_recorded', 'recorded')
  then
    raise exception 'dispatch filter is invalid' using errcode = '23514';
  end if;
  if receiving_filter is not null
    and receiving_filter not in (
      'not_started',
      'pending_verification',
      'partially_received',
      'fully_received',
      'excess_requires_review'
    )
  then
    raise exception 'receiving filter is invalid' using errcode = '23514';
  end if;

  select count(*)
  into total_count
  from public.stock_refill_requests
  join public.suppliers on suppliers.id = stock_refill_requests.supplier_id
  join public.branches on branches.id = stock_refill_requests.destination_godown_id
  left join public.stock_refill_supplier_communications
    on stock_refill_supplier_communications.refill_request_id = stock_refill_requests.id
  left join public.stock_refill_supplier_dispatches
    on stock_refill_supplier_dispatches.refill_request_id = stock_refill_requests.id
  cross join lateral app_private.stock_refill_progress_totals(stock_refill_requests.id) progress
  where app_private.can_view_refill_at_godown(stock_refill_requests.destination_godown_id)
    and (status_filter is null or stock_refill_requests.status = status_filter)
    and (target_godown is null or stock_refill_requests.destination_godown_id = target_godown)
    and (target_supplier is null or stock_refill_requests.supplier_id = target_supplier)
    and (created_from is null or stock_refill_requests.created_at >= created_from)
    and (created_to is null or stock_refill_requests.created_at < created_to)
    and (
      communication_filter is null
      or (communication_filter = 'not_sent' and stock_refill_supplier_communications.id is null)
      or (communication_filter = 'sent' and stock_refill_supplier_communications.id is not null)
    )
    and (
      acknowledgement_filter is null
      or (acknowledgement_filter = 'none' and stock_refill_supplier_communications.id is null)
      or (
        acknowledgement_filter is distinct from 'none'
        and stock_refill_supplier_communications.acknowledgement_status = acknowledgement_filter
      )
    )
    and (
      dispatch_filter is null
      or (dispatch_filter = 'not_recorded' and stock_refill_supplier_dispatches.id is null)
      or (dispatch_filter = 'recorded' and stock_refill_supplier_dispatches.id is not null)
    )
    and (receiving_filter is null or progress.completion_label = receiving_filter)
    and (
      cleaned_search is null
      or pg_catalog.lower(stock_refill_requests.request_number) like '%' || cleaned_search || '%'
      or pg_catalog.lower(suppliers.name) like '%' || cleaned_search || '%'
      or pg_catalog.lower(branches.name) like '%' || cleaned_search || '%'
      or pg_catalog.lower(branches.code) like '%' || cleaned_search || '%'
    );

  return pg_catalog.jsonb_build_object(
    'total', total_count,
    'page', safe_page,
    'page_size', safe_size,
    'items', coalesce((
      select pg_catalog.jsonb_agg(item)
      from (
        select pg_catalog.jsonb_build_object(
          'id', stock_refill_requests.id,
          'request_number', stock_refill_requests.request_number,
          'supplier_id', stock_refill_requests.supplier_id,
          'supplier_name', suppliers.name,
          'destination_godown_id', stock_refill_requests.destination_godown_id,
          'godown_code', branches.code,
          'godown_name', branches.name,
          'godown_active', branches.is_active,
          'status', stock_refill_requests.status,
          'communication_status', case
            when stock_refill_supplier_communications.id is null then 'not_sent'
            else 'sent'
          end,
          'acknowledgement_status', case
            when stock_refill_supplier_communications.id is null then 'none'
            else stock_refill_supplier_communications.acknowledgement_status
          end,
          'dispatch_status', case
            when stock_refill_supplier_dispatches.id is null then 'not_recorded'
            else 'recorded'
          end,
          'expected_arrival_on', stock_refill_supplier_dispatches.expected_arrival_on,
          'version', stock_refill_requests.version,
          'total_requested_cases', progress.requested_cases,
          'reserved_cases', progress.reserved_cases,
          'draft_reserved_cases', progress.draft_reserved_cases,
          'accepted_cases', progress.accepted_cases,
          'outstanding_cases', progress.outstanding_cases,
          'pending_receipt_cases', progress.pending_receipt_cases,
          'completion_label', progress.completion_label,
          'created_at', stock_refill_requests.created_at,
          'submitted_at', stock_refill_requests.submitted_at,
          'created_by', stock_refill_requests.created_by
        ) as item
        from public.stock_refill_requests
        join public.suppliers on suppliers.id = stock_refill_requests.supplier_id
        join public.branches on branches.id = stock_refill_requests.destination_godown_id
        left join public.stock_refill_supplier_communications
          on stock_refill_supplier_communications.refill_request_id = stock_refill_requests.id
        left join public.stock_refill_supplier_dispatches
          on stock_refill_supplier_dispatches.refill_request_id = stock_refill_requests.id
        cross join lateral app_private.stock_refill_progress_totals(stock_refill_requests.id) progress
        where app_private.can_view_refill_at_godown(stock_refill_requests.destination_godown_id)
          and (status_filter is null or stock_refill_requests.status = status_filter)
          and (target_godown is null or stock_refill_requests.destination_godown_id = target_godown)
          and (target_supplier is null or stock_refill_requests.supplier_id = target_supplier)
          and (created_from is null or stock_refill_requests.created_at >= created_from)
          and (created_to is null or stock_refill_requests.created_at < created_to)
          and (
            communication_filter is null
            or (communication_filter = 'not_sent' and stock_refill_supplier_communications.id is null)
            or (communication_filter = 'sent' and stock_refill_supplier_communications.id is not null)
          )
          and (
            acknowledgement_filter is null
            or (acknowledgement_filter = 'none' and stock_refill_supplier_communications.id is null)
            or (
              acknowledgement_filter is distinct from 'none'
              and stock_refill_supplier_communications.acknowledgement_status = acknowledgement_filter
            )
          )
          and (
            dispatch_filter is null
            or (dispatch_filter = 'not_recorded' and stock_refill_supplier_dispatches.id is null)
            or (dispatch_filter = 'recorded' and stock_refill_supplier_dispatches.id is not null)
          )
          and (receiving_filter is null or progress.completion_label = receiving_filter)
          and (
            cleaned_search is null
            or pg_catalog.lower(stock_refill_requests.request_number) like '%' || cleaned_search || '%'
            or pg_catalog.lower(suppliers.name) like '%' || cleaned_search || '%'
            or pg_catalog.lower(branches.name) like '%' || cleaned_search || '%'
            or pg_catalog.lower(branches.code) like '%' || cleaned_search || '%'
          )
        order by stock_refill_requests.created_at desc, stock_refill_requests.id desc
        offset (safe_page - 1) * safe_size
        limit safe_size
      ) listed
    ), '[]'::jsonb)
  );
end;
$$;

-- Inactive suppliers stay visible for historical report filters. Create UI still
-- filters is_active on the client.
create or replace function public.list_stock_refill_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
    or (
      not app_private.has_permission('refill.request')
      and not app_private.has_permission('refill.approve')
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'godowns', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', branches.id,
          'code', branches.code,
          'name', branches.name,
          'is_active', branches.is_active
        )
        order by branches.name
      )
      from public.branches
      where app_private.can_view_refill_at_godown(branches.id)
    ), '[]'::jsonb),
    'suppliers', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', suppliers.id,
          'name', suppliers.name,
          'is_active', suppliers.is_active
        )
        order by suppliers.name
      )
      from public.suppliers
    ), '[]'::jsonb),
    'products', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', products.id,
          'sku', products.sku,
          'name', products.name,
          'supplier_id', products.supplier_id,
          'is_active', products.is_active
        )
        order by products.sku
      )
      from public.products
      where products.supplier_id is not null
        and products.is_active
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.list_stock_refill_report(
  page integer default 1,
  page_size integer default 50,
  status_filter text default null,
  target_godown uuid default null,
  target_supplier uuid default null,
  search_text text default null,
  communication_filter text default null,
  acknowledgement_filter text default null,
  dispatch_filter text default null,
  receiving_filter text default null,
  created_from timestamptz default null,
  created_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  listed jsonb;
  summary jsonb;
begin
  listed := public.list_stock_refill_requests(
    page,
    page_size,
    status_filter,
    target_godown,
    target_supplier,
    search_text,
    communication_filter,
    acknowledgement_filter,
    dispatch_filter,
    receiving_filter,
    created_from,
    created_to
  );

  -- Totals cover the authorized filtered set, not only the current page.
  select pg_catalog.jsonb_build_object(
    'requested_cases', coalesce(sum(progress.requested_cases), 0),
    'reserved_cases', coalesce(sum(progress.reserved_cases), 0),
    'draft_reserved_cases', coalesce(sum(progress.draft_reserved_cases), 0),
    'accepted_cases', coalesce(sum(progress.accepted_cases), 0),
    'outstanding_cases', coalesce(sum(progress.outstanding_cases), 0),
    'pending_receipt_cases', coalesce(sum(progress.pending_receipt_cases), 0),
    'fully_received_requests', coalesce(count(*) filter (
      where progress.completion_label = 'fully_received'
    ), 0)
  )
  into summary
  from public.stock_refill_requests
  join public.suppliers on suppliers.id = stock_refill_requests.supplier_id
  join public.branches on branches.id = stock_refill_requests.destination_godown_id
  left join public.stock_refill_supplier_communications
    on stock_refill_supplier_communications.refill_request_id = stock_refill_requests.id
  left join public.stock_refill_supplier_dispatches
    on stock_refill_supplier_dispatches.refill_request_id = stock_refill_requests.id
  cross join lateral app_private.stock_refill_progress_totals(stock_refill_requests.id) progress
  where app_private.can_view_refill_at_godown(stock_refill_requests.destination_godown_id)
    and (status_filter is null or stock_refill_requests.status = status_filter)
    and (target_godown is null or stock_refill_requests.destination_godown_id = target_godown)
    and (target_supplier is null or stock_refill_requests.supplier_id = target_supplier)
    and (created_from is null or stock_refill_requests.created_at >= created_from)
    and (created_to is null or stock_refill_requests.created_at < created_to)
    and (
      communication_filter is null
      or (communication_filter = 'not_sent' and stock_refill_supplier_communications.id is null)
      or (communication_filter = 'sent' and stock_refill_supplier_communications.id is not null)
    )
    and (
      acknowledgement_filter is null
      or (acknowledgement_filter = 'none' and stock_refill_supplier_communications.id is null)
      or (
        acknowledgement_filter is distinct from 'none'
        and stock_refill_supplier_communications.acknowledgement_status = acknowledgement_filter
      )
    )
    and (
      dispatch_filter is null
      or (dispatch_filter = 'not_recorded' and stock_refill_supplier_dispatches.id is null)
      or (dispatch_filter = 'recorded' and stock_refill_supplier_dispatches.id is not null)
    )
    and (receiving_filter is null or progress.completion_label = receiving_filter)
    and (
      nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(search_text, ''))), '') is null
      or pg_catalog.lower(stock_refill_requests.request_number)
        like '%' || pg_catalog.lower(pg_catalog.btrim(search_text)) || '%'
      or pg_catalog.lower(suppliers.name)
        like '%' || pg_catalog.lower(pg_catalog.btrim(search_text)) || '%'
      or pg_catalog.lower(branches.name)
        like '%' || pg_catalog.lower(pg_catalog.btrim(search_text)) || '%'
      or pg_catalog.lower(branches.code)
        like '%' || pg_catalog.lower(pg_catalog.btrim(search_text)) || '%'
    );

  return pg_catalog.jsonb_build_object(
    'timezone', 'UTC',
    'page', listed -> 'page',
    'page_size', listed -> 'page_size',
    'total_count', listed -> 'total',
    'summary', coalesce(summary, '{}'::jsonb),
    'rows', coalesce(listed -> 'items', '[]'::jsonb)
  );
end;
$$;

create or replace function public.export_stock_refill_report(
  status_filter text default null,
  target_godown uuid default null,
  target_supplier uuid default null,
  search_text text default null,
  communication_filter text default null,
  acknowledgement_filter text default null,
  dispatch_filter text default null,
  receiving_filter text default null,
  created_from timestamptz default null,
  created_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  payload jsonb;
  header text;
  body text := '';
  row_count integer := 0;
  truncated boolean := false;
  item jsonb;
  page_no integer := 1;
  total integer := 0;
  export_cap integer := 5000;
begin
  header := 'request_number,status,supplier_name,godown_code,godown_name,godown_active,communication_status,acknowledgement_status,dispatch_status,requested_cases,reserved_cases,draft_reserved_cases,accepted_cases,outstanding_cases,pending_receipt_cases,completion_label,created_at_utc,submitted_at_utc,expected_arrival_on';

  loop
    payload := public.list_stock_refill_report(
      page_no,
      100,
      status_filter,
      target_godown,
      target_supplier,
      search_text,
      communication_filter,
      acknowledgement_filter,
      dispatch_filter,
      receiving_filter,
      created_from,
      created_to
    );
    total := coalesce((payload ->> 'total_count')::integer, 0);

    for item in select value from jsonb_array_elements(coalesce(payload -> 'rows', '[]'::jsonb))
    loop
      row_count := row_count + 1;
      if row_count > export_cap then
        truncated := true;
        exit;
      end if;
      body := body || E'\n' || concat_ws(',',
        app_private.report_csv_cell(item ->> 'request_number'),
        app_private.report_csv_cell(item ->> 'status'),
        app_private.report_csv_cell(item ->> 'supplier_name'),
        app_private.report_csv_cell(item ->> 'godown_code'),
        app_private.report_csv_cell(item ->> 'godown_name'),
        app_private.report_csv_cell(item ->> 'godown_active'),
        app_private.report_csv_cell(item ->> 'communication_status'),
        app_private.report_csv_cell(item ->> 'acknowledgement_status'),
        app_private.report_csv_cell(item ->> 'dispatch_status'),
        app_private.report_csv_cell(item ->> 'total_requested_cases'),
        app_private.report_csv_cell(item ->> 'reserved_cases'),
        app_private.report_csv_cell(item ->> 'draft_reserved_cases'),
        app_private.report_csv_cell(item ->> 'accepted_cases'),
        app_private.report_csv_cell(item ->> 'outstanding_cases'),
        app_private.report_csv_cell(item ->> 'pending_receipt_cases'),
        app_private.report_csv_cell(item ->> 'completion_label'),
        app_private.report_csv_cell(item ->> 'created_at'),
        app_private.report_csv_cell(item ->> 'submitted_at'),
        app_private.report_csv_cell(item ->> 'expected_arrival_on')
      );
    end loop;

    exit when truncated or page_no * 100 >= greatest(total, 1) or jsonb_array_length(coalesce(payload -> 'rows', '[]'::jsonb)) = 0;
    page_no := page_no + 1;
  end loop;

  return pg_catalog.jsonb_build_object(
    'timezone', 'UTC',
    'report_kind', 'refill',
    'row_count', least(row_count, export_cap),
    'total_count', total,
    'truncated', truncated,
    'csv', header || body
  );
end;
$$;

revoke all on function public.list_stock_refill_requests(
  integer, integer, text, uuid, uuid, text, text, text, text, text, timestamptz, timestamptz
) from public, anon, service_role;
revoke all on function public.list_stock_refill_options() from public, anon, service_role;
revoke all on function public.list_stock_refill_report(
  integer, integer, text, uuid, uuid, text, text, text, text, text, timestamptz, timestamptz
) from public, anon, service_role;
revoke all on function public.export_stock_refill_report(
  text, uuid, uuid, text, text, text, text, text, timestamptz, timestamptz
) from public, anon, service_role;

grant execute on function public.list_stock_refill_requests(
  integer, integer, text, uuid, uuid, text, text, text, text, text, timestamptz, timestamptz
) to authenticated;
grant execute on function public.list_stock_refill_options() to authenticated;
grant execute on function public.list_stock_refill_report(
  integer, integer, text, uuid, uuid, text, text, text, text, text, timestamptz, timestamptz
) to authenticated;
grant execute on function public.export_stock_refill_report(
  text, uuid, uuid, text, text, text, text, text, timestamptz, timestamptz
) to authenticated;

comment on function public.list_stock_refill_report(
  integer, integer, text, uuid, uuid, text, text, text, text, text, timestamptz, timestamptz
) is
  'M6.5 authorized refill reporting. Read-only. Zero stock.';

notify pgrst, 'reload schema';
