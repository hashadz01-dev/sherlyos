-- M8.2B.1 shop sales-statement preview. Read-only.
-- Does not post receipts, issue tax invoices, allocate statutory numbers,
-- write stock, or import handwritten register history.

insert into public.permissions (code, description)
values (
  'shops.statement.read',
  'Read a shop sales-statement preview. Does not post receipts, show outstanding as zero, or issue a tax invoice.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'shops.statement.read'
where roles.code in ('admin', 'accounts')
on conflict do nothing;

create or replace function app_private.can_view_shop(target_shop uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.shops
    where shops.id = target_shop
      and (select app_private.has_permission('shops.read'))
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
  );
$$;

revoke all on function app_private.can_view_shop(uuid) from public, anon;
grant execute on function app_private.can_view_shop(uuid) to authenticated;

comment on function app_private.can_view_shop(uuid) is
  'Same visibility as shops_select_authorized. Used by shop statement reads.';

create or replace function public.get_shop_sales_statement(
  p_shop_id uuid,
  p_from date default null,
  p_to date default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  needle text := nullif(pg_catalog.btrim(coalesce(p_search, '')), '');
  shop_row public.shops;
  payload jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if not (select app_private.has_permission('shops.statement.read')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if not (select app_private.can_view_shop(p_shop_id)) then
    raise exception 'shop not found' using errcode = '42501';
  end if;

  select shops.* into shop_row from public.shops where shops.id = p_shop_id;

  payload := (
    with invoice_rows as (
      select
        invoice_notes.id as source_id,
        'invoice_note'::text as source_type,
        invoice_notes.as_of_date as transaction_date,
        'Invoice note (not a tax invoice)'::text as particulars,
        invoice_notes.note_number as reference_number,
        invoice_notes.grand_total as bill_amount,
        true as bill_amount_available,
        invoice_notes.remarks,
        invoice_notes.status,
        case invoice_notes.status
          when 'draft' then 'Draft — not a tax invoice'
          when 'submitted' then 'Submitted — not a tax invoice'
          when 'reviewed' then 'Reviewed — still not a tax invoice'
          when 'cancelled' then 'Cancelled'
          else invoice_notes.status
        end as status_label,
        '/invoices/' || invoice_notes.id::text as href
      from public.invoice_notes
      where invoice_notes.shop_id = p_shop_id
        and (select app_private.can_view_invoice_note())
        and (select app_private.can_work_at_branch(invoice_notes.branch_id))
        and (p_from is null or invoice_notes.as_of_date >= p_from)
        and (p_to is null or invoice_notes.as_of_date <= p_to)
        and (
          needle is null
          or invoice_notes.note_number ilike '%' || needle || '%'
          or coalesce(invoice_notes.remarks, '') ilike '%' || needle || '%'
        )
    ),
    delivery_rows as (
      select
        delivery_notes.id as source_id,
        'delivery_note'::text as source_type,
        (coalesce(delivery_notes.generated_at, delivery_notes.created_at))::date as transaction_date,
        'Delivery note'::text as particulars,
        delivery_notes.delivery_note_number as reference_number,
        null::numeric as bill_amount,
        false as bill_amount_available,
        delivery_notes.void_reason as remarks,
        delivery_notes.status,
        delivery_notes.status as status_label,
        '/deliveries/' || delivery_notes.id::text as href
      from public.delivery_notes
      where delivery_notes.shop_id = p_shop_id
        and (select app_private.can_view_delivery_note(delivery_notes.id))
        and (p_from is null or (coalesce(delivery_notes.generated_at, delivery_notes.created_at))::date >= p_from)
        and (p_to is null or (coalesce(delivery_notes.generated_at, delivery_notes.created_at))::date <= p_to)
        and (
          needle is null
          or delivery_notes.delivery_note_number ilike '%' || needle || '%'
        )
    ),
    credit_rows as (
      select
        invoice_credit_adjustments.id as source_id,
        'credit_adjustment'::text as source_type,
        invoice_credit_adjustments.created_at::date as transaction_date,
        'Credit adjustment preview (not a GST credit note)'::text as particulars,
        invoice_credit_adjustments.adjustment_number as reference_number,
        invoice_credit_adjustments.adjustment_total as bill_amount,
        true as bill_amount_available,
        invoice_credit_adjustments.review_reason as remarks,
        invoice_credit_adjustments.status,
        case invoice_credit_adjustments.status
          when 'preview' then 'Prepared — not a GST credit note'
          when 'blocked' then 'Blocked — not a GST credit note'
          when 'approved' then 'Approved (internal) — not a GST credit note'
          when 'rejected' then 'Rejected'
          else invoice_credit_adjustments.status
        end as status_label,
        '/credit-adjustments/' || invoice_credit_adjustments.id::text as href
      from public.invoice_credit_adjustments
      where invoice_credit_adjustments.shop_id = p_shop_id
        and (select app_private.can_manage_credit_adjustment())
        and (select app_private.can_work_at_branch(invoice_credit_adjustments.branch_id))
        and (p_from is null or invoice_credit_adjustments.created_at::date >= p_from)
        and (p_to is null or invoice_credit_adjustments.created_at::date <= p_to)
        and (
          needle is null
          or invoice_credit_adjustments.adjustment_number ilike '%' || needle || '%'
        )
    ),
    combined as (
      select * from invoice_rows
      union all
      select * from delivery_rows
      union all
      select * from credit_rows
    )
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'source_type', combined.source_type,
          'source_id', combined.source_id,
          'transaction_date', combined.transaction_date,
          'particulars', combined.particulars,
          'reference_number', combined.reference_number,
          'bill_amount', combined.bill_amount,
          'bill_amount_available', combined.bill_amount_available,
          'amount_received', null,
          'amount_received_available', false,
          'running_balance', null,
          'running_balance_available', false,
          'acknowledgement', null,
          'remarks', combined.remarks,
          'status', combined.status,
          'status_label', combined.status_label,
          'href', combined.href
        )
        order by combined.transaction_date, combined.source_type, combined.source_id
      ),
      '[]'::jsonb
    )
    from combined
  );

  return jsonb_build_object(
    'shop', jsonb_build_object(
      'id', shop_row.id,
      'name', shop_row.name,
      'phone', shop_row.phone,
      'address', shop_row.address,
      'is_active', shop_row.is_active
    ),
    'watermark', 'SALES STATEMENT PREVIEW — NOT A TAX LEDGER — PAYMENTS NOT POSTED',
    'payment_accounting', jsonb_build_object(
      'available', false,
      'received_available', false,
      'outstanding_available', false,
      'reason', 'Customer receipts and receivables are not implemented. Cash received and outstanding balance are not shown as zero.'
    ),
    'entries', payload,
    'summary', jsonb_build_object(
      'invoice_note_count', (
        select count(*)
        from jsonb_array_elements(payload) item
        where item ->> 'source_type' = 'invoice_note'
      ),
      'delivery_note_count', (
        select count(*)
        from jsonb_array_elements(payload) item
        where item ->> 'source_type' = 'delivery_note'
      ),
      'credit_adjustment_count', (
        select count(*)
        from jsonb_array_elements(payload) item
        where item ->> 'source_type' = 'credit_adjustment'
      ),
      'reviewed_note_total', (
        select case when count(*) = 0 then null else sum((item ->> 'bill_amount')::numeric) end
        from jsonb_array_elements(payload) item
        where item ->> 'source_type' = 'invoice_note'
          and item ->> 'status' = 'reviewed'
      ),
      'submitted_note_total', (
        select case when count(*) = 0 then null else sum((item ->> 'bill_amount')::numeric) end
        from jsonb_array_elements(payload) item
        where item ->> 'source_type' = 'invoice_note'
          and item ->> 'status' = 'submitted'
      ),
      'draft_note_total', (
        select case when count(*) = 0 then null else sum((item ->> 'bill_amount')::numeric) end
        from jsonb_array_elements(payload) item
        where item ->> 'source_type' = 'invoice_note'
          and item ->> 'status' = 'draft'
      ),
      'credit_adjustment_preview_total', (
        select case when count(*) = 0 then null else sum((item ->> 'bill_amount')::numeric) end
        from jsonb_array_elements(payload) item
        where item ->> 'source_type' = 'credit_adjustment'
      )
    )
  );
end;
$$;

revoke all on function public.get_shop_sales_statement(uuid, date, date, text)
  from public, anon;
grant execute on function public.get_shop_sales_statement(uuid, date, date, text)
  to authenticated;

comment on function public.get_shop_sales_statement(uuid, date, date, text) is
  'Requires shops.statement.read. Returns shop-scoped billing and delivery history. amount_received and running_balance are always null. Does not post payments or issue tax invoices.';
