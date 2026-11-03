-- Invoice notes queue for Accounts review as well as Godown Manager prepare.
-- list_invoice_eligible_dispatches was prepare-only, so Accounts saw an empty
-- Invoice notes page after a confirmed dispatch. This does not grant prepare,
-- review, or statutory issuance. Tax invoices stay blocked.

create or replace function public.list_invoice_eligible_dispatches()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_view_invoice_note() then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  return coalesce(
    (
      select jsonb_agg(item order by item ->> 'dispatched_at' desc)
      from (
        select jsonb_build_object(
          'dispatch_id', stock_dispatch_requests.id,
          'dispatch_number', stock_dispatch_requests.request_number,
          'order_id', stock_dispatch_requests.order_id,
          'order_number', orders.order_number,
          'shop_id', orders.shop_id,
          'shop_name', shops.name,
          'branch_id', stock_dispatch_requests.branch_id,
          'status', stock_dispatch_requests.status,
          'dispatched_at', stock_dispatch_requests.dispatched_at
        ) as item
        from public.stock_dispatch_requests
        join public.orders on orders.id = stock_dispatch_requests.order_id
        join public.shops on shops.id = orders.shop_id
        where stock_dispatch_requests.stock_consumed
          and stock_dispatch_requests.posted_transaction_id is not null
          and stock_dispatch_requests.status in (
            'dispatched', 'in_transit', 'delivered', 'exception'
          )
          and app_private.can_work_at_branch(stock_dispatch_requests.branch_id)
          and not exists (
            select 1
            from public.invoice_notes
            where invoice_notes.dispatch_id = stock_dispatch_requests.id
              and invoice_notes.status in ('draft', 'submitted', 'reviewed')
          )
        order by stock_dispatch_requests.dispatched_at desc
        limit 100
      ) listed
    ),
    '[]'::jsonb
  );
end;
$$;

comment on function public.list_invoice_eligible_dispatches() is
  'Posted dispatches with no open invoice-note draft. Readable by invoice-note viewers; prepare remains invoice_notes.prepare.';

-- Surface order/dispatch numbers on existing drafts so Invoice notes search
-- matches the sales order the operator just delivered.
create or replace function public.list_invoice_notes(
  p_status text default null,
  p_branch_id uuid default null,
  p_shop_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_view_invoice_note() then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_status is not null
    and p_status not in ('draft', 'submitted', 'reviewed', 'cancelled')
  then
    raise exception 'invoice-note status is not valid' using errcode = '23514';
  end if;

  return coalesce(
    (
      select jsonb_agg(item order by item ->> 'created_at' desc)
      from (
        select jsonb_build_object(
          'id', invoice_notes.id,
          'note_number', invoice_notes.note_number,
          'status', invoice_notes.status,
          'version', invoice_notes.version,
          'dispatch_id', invoice_notes.dispatch_id,
          'dispatch_number', stock_dispatch_requests.request_number,
          'order_id', invoice_notes.order_id,
          'order_number', orders.order_number,
          'shop_id', invoice_notes.shop_id,
          'shop_name', shops.name,
          'branch_id', invoice_notes.branch_id,
          'billed_cases', invoice_notes.billed_cases,
          'grand_total', invoice_notes.grand_total,
          'currency_code', invoice_notes.currency_code,
          'watermark', 'DRAFT INVOICE NOTE — NOT A TAX INVOICE',
          'legal_issuance_blocked', true,
          'created_at', invoice_notes.created_at
        ) as item
        from public.invoice_notes
        join public.shops on shops.id = invoice_notes.shop_id
        join public.orders on orders.id = invoice_notes.order_id
        join public.stock_dispatch_requests
          on stock_dispatch_requests.id = invoice_notes.dispatch_id
        where app_private.can_work_at_branch(invoice_notes.branch_id)
          and (p_status is null or invoice_notes.status = p_status)
          and (p_branch_id is null or invoice_notes.branch_id = p_branch_id)
          and (p_shop_id is null or invoice_notes.shop_id = p_shop_id)
        order by invoice_notes.created_at desc
        limit 100
      ) listed
    ),
    '[]'::jsonb
  );
end;
$$;
