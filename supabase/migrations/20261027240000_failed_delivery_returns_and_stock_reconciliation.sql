-- M7.4B. Failed/partial delivery returns, keeper count, GM approval, DELIVERY_RETURN writer.
-- Additive. Does not change confirm_dispatch or verify_stock_receipt posting.
-- Does not restock from order-line totals. Does not create M5 reports.
-- Physical return-to-stock is this dedicated writer only.

-- ---------------------------------------------------------------------------
-- 1. Permissions. Separation of duties is grant-level plus actor inequality.
-- ---------------------------------------------------------------------------
insert into public.permissions (code, description)
values
  (
    'deliveries.return_view',
    'View a failed or partial delivery return for an authorized godown. Does not post stock.'
  ),
  (
    'deliveries.return_handback',
    'Declare physical handback of undelivered cases. Assigned driver only. Does not classify lots or post stock.'
  ),
  (
    'deliveries.return_count',
    'Record Store Keeper lot, condition, and receiving-crate counts. Does not approve or post stock.'
  ),
  (
    'deliveries.return_approve',
    'Godown Manager approval of a Store Keeper return count. Does not post stock.'
  ),
  (
    'deliveries.return_post',
    'Post an approved delivery return through the dedicated DELIVERY_RETURN writer.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'deliveries.return_view'),
    ('godown_manager', 'deliveries.return_view'),
    ('godown_manager', 'deliveries.return_approve'),
    ('godown_manager', 'deliveries.return_post'),
    ('store_keeper', 'deliveries.return_view'),
    ('store_keeper', 'deliveries.return_count'),
    ('delivery_person', 'deliveries.return_view'),
    ('delivery_person', 'deliveries.return_handback')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Dispatch header: allow return-status progress without leaving exception.
-- ---------------------------------------------------------------------------
alter table public.stock_dispatch_requests
  drop constraint stock_dispatch_requests_return_check;

alter table public.stock_dispatch_requests
  drop constraint stock_dispatch_requests_exception_shape;

alter table public.stock_dispatch_requests
  add constraint stock_dispatch_requests_return_check check (
    physical_return_status is null
    or physical_return_status in (
      'pending_verification',
      'handed_back',
      'counted',
      'approved',
      'posted',
      'closed_missing',
      'cancelled'
    )
  );

alter table public.stock_dispatch_requests
  add constraint stock_dispatch_requests_exception_shape check (
    status <> 'exception'
    or (
      stock_consumed = true
      and exception_at is not null
      and exception_reason is not null
      and physical_return_status is not null
    )
  );

alter table public.stock_dispatch_events
  drop constraint stock_dispatch_events_type_check;

alter table public.stock_dispatch_events
  add constraint stock_dispatch_events_type_check check (
    event_type in (
      'prepared',
      'cancelled',
      'dispatched',
      'assigned',
      'in_transit',
      'delivered',
      'exception_recorded',
      'partial_recorded',
      'return_posted',
      'return_closed_missing'
    )
  );

-- ---------------------------------------------------------------------------
-- 3. Return documents
-- ---------------------------------------------------------------------------
create sequence public.stock_delivery_return_seq;

create table public.stock_delivery_returns (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null unique
    references public.stock_dispatch_requests (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  return_number text not null unique,
  status text not null,
  version integer not null default 1,
  declared_returned_cases integer not null default 0,
  handed_back_at timestamptz,
  handed_back_by uuid references public.profiles (id) on delete restrict,
  handback_notes text,
  counted_at timestamptz,
  counted_by uuid references public.profiles (id) on delete restrict,
  approved_at timestamptz,
  approved_by uuid references public.profiles (id) on delete restrict,
  approval_fingerprint text,
  posted_at timestamptz,
  posted_by uuid references public.profiles (id) on delete restrict,
  posted_transaction_id uuid references public.stock_transactions (id) on delete restrict,
  closed_at timestamptz,
  closed_by uuid references public.profiles (id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancellation_reason text,
  related_damage_report_ids uuid[] not null default '{}',
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.now(),
  constraint stock_delivery_returns_status_check check (
    status in (
      'awaiting_handback',
      'handed_back',
      'counted',
      'approved',
      'posted',
      'closed_missing',
      'cancelled'
    )
  ),
  constraint stock_delivery_returns_version_check check (version >= 1),
  constraint stock_delivery_returns_declared_check check (
    declared_returned_cases >= 0 and declared_returned_cases <= 1000000
  ),
  constraint stock_delivery_returns_handback_notes_length check (
    handback_notes is null
    or (
      char_length(btrim(handback_notes)) between 1 and 500
      and handback_notes = btrim(handback_notes)
    )
  ),
  constraint stock_delivery_returns_cancel_reason_length check (
    cancellation_reason is null
    or (
      char_length(btrim(cancellation_reason)) between 1 and 500
      and cancellation_reason = btrim(cancellation_reason)
    )
  ),
  constraint stock_delivery_returns_posted_shape check (
    (status <> 'posted')
    or (
      posted_at is not null
      and posted_by is not null
      and posted_transaction_id is not null
      and approved_by is not null
      and counted_by is not null
      and counted_by is distinct from approved_by
    )
  ),
  constraint stock_delivery_returns_missing_shape check (
    (status <> 'closed_missing')
    or (
      closed_at is not null
      and closed_by is not null
      and posted_transaction_id is null
      and counted_by is not null
      and counted_by is distinct from closed_by
    )
  )
);

comment on table public.stock_delivery_returns is
  'M7.4B. One return wave per dispatch. Does not rewrite DISPATCH. Missing closes without a stock transaction.';

create table public.stock_delivery_return_lots (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null
    references public.stock_delivery_returns (id) on delete restrict,
  order_line_id uuid not null references public.order_lines (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  source_crate_id uuid not null references public.crates (id) on delete restrict,
  reservation_id uuid references public.stock_reservations (id) on delete restrict,
  dispatched_cases integer not null,
  delivered_cases integer not null default 0,
  saleable_cases integer not null default 0,
  damaged_cases integer not null default 0,
  uncertain_cases integer not null default 0,
  missing_cases integer not null default 0,
  receiving_crate_id uuid references public.crates (id) on delete restrict,
  posted_crate_id uuid references public.crates (id) on delete restrict,
  constraint stock_delivery_return_lots_qty_check check (
    dispatched_cases >= 1
    and delivered_cases >= 0
    and saleable_cases >= 0
    and damaged_cases >= 0
    and uncertain_cases >= 0
    and missing_cases >= 0
    and delivered_cases + saleable_cases + damaged_cases + uncertain_cases + missing_cases
      <= dispatched_cases
  ),
  constraint stock_delivery_return_lots_grain_key unique (
    return_id, order_line_id, lot_id, source_crate_id
  )
);

comment on table public.stock_delivery_return_lots is
  'M7.4B dispatched grain snapshot plus keeper allocation. unresolved = dispatched - delivered - return buckets.';

create table public.stock_delivery_return_events (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null
    references public.stock_delivery_returns (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  from_status text,
  to_status text not null,
  return_version integer not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_delivery_return_events_type_check check (
    event_type in (
      'opened',
      'handed_back',
      'counted',
      'approved',
      'returned_to_count',
      'posted',
      'closed_missing',
      'cancelled'
    )
  )
);

create index stock_delivery_return_lots_return_idx
  on public.stock_delivery_return_lots (return_id);

create index stock_delivery_return_events_return_idx
  on public.stock_delivery_return_events (return_id, created_at);

create trigger stock_delivery_returns_set_updated_at
  before update on public.stock_delivery_returns
  for each row execute function app_private.set_updated_at();

create or replace function app_private.guard_delivery_return_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('app.delivery_return_write', true) is distinct from 'on' then
    raise exception 'delivery returns cannot be changed directly' using errcode = '42501';
  end if;
  if tg_table_name = 'stock_delivery_return_events' and tg_op <> 'INSERT' then
    raise exception 'delivery return history cannot be changed' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'delivery returns cannot be deleted' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_delivery_return_write()
  from public, anon, authenticated, service_role;

create trigger stock_delivery_returns_guard
  before insert or update or delete on public.stock_delivery_returns
  for each row execute function app_private.guard_delivery_return_write();

create trigger stock_delivery_return_lots_guard
  before insert or update or delete on public.stock_delivery_return_lots
  for each row execute function app_private.guard_delivery_return_write();

create trigger stock_delivery_return_events_guard
  before insert or update or delete on public.stock_delivery_return_events
  for each row execute function app_private.guard_delivery_return_write();

alter table public.stock_delivery_returns enable row level security;
alter table public.stock_delivery_returns force row level security;
alter table public.stock_delivery_return_lots enable row level security;
alter table public.stock_delivery_return_lots force row level security;
alter table public.stock_delivery_return_events enable row level security;
alter table public.stock_delivery_return_events force row level security;

create or replace function app_private.delivery_return_can_view(
  header public.stock_delivery_returns
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dispatch public.stock_dispatch_requests;
begin
  if header.id is null then
    return false;
  end if;
  select * into dispatch
  from public.stock_dispatch_requests
  where stock_dispatch_requests.id = header.dispatch_id;
  if not found then
    return false;
  end if;
  -- Return documents inherit dispatch visibility. Do not let return_view
  -- bypass assigned-driver rules for unassigned historical exceptions.
  if not app_private.dispatch_can_view(dispatch) then
    return false;
  end if;
  return true;
end;
$$;

revoke all on function app_private.delivery_return_can_view(public.stock_delivery_returns)
  from public, anon, authenticated, service_role;

create policy stock_delivery_returns_select
  on public.stock_delivery_returns
  for select
  to authenticated
  using ((select app_private.delivery_return_can_view(stock_delivery_returns)));

create policy stock_delivery_return_lots_select
  on public.stock_delivery_return_lots
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_delivery_returns header
      where header.id = stock_delivery_return_lots.return_id
        and (select app_private.delivery_return_can_view(header))
    )
  );

create policy stock_delivery_return_events_select
  on public.stock_delivery_return_events
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_delivery_returns header
      where header.id = stock_delivery_return_events.return_id
        and (select app_private.delivery_return_can_view(header))
    )
  );

revoke all on table public.stock_delivery_returns
  from public, anon, authenticated, service_role;
revoke all on table public.stock_delivery_return_lots
  from public, anon, authenticated, service_role;
revoke all on table public.stock_delivery_return_events
  from public, anon, authenticated, service_role;
grant select on table public.stock_delivery_returns to authenticated;
grant select on table public.stock_delivery_return_lots to authenticated;
grant select on table public.stock_delivery_return_events to authenticated;

-- Keepers counting returns must see the parent exception document.
create or replace function app_private.dispatch_can_view(
  header public.stock_dispatch_requests
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if header.id is null then
    return false;
  end if;
  if not (
    app_private.can_work_at_branch(header.branch_id)
    or (
      header.stock_consumed
      and app_private.can_complete_consumed_delivery_at_branch(header.branch_id)
    )
  ) then
    return false;
  end if;
  if app_private.has_permission('dispatch.view')
    or app_private.has_permission('dispatch.confirm')
    or app_private.has_permission('dispatch.exception')
    or app_private.has_permission('dispatch.history')
    or app_private.has_permission('deliveries.assign')
    or app_private.has_permission('operations.monitor')
  then
    return true;
  end if;
  -- Store Keeper count / GM approve-post may open origin-godown return
  -- documents. Driver return_view must not leak unassigned exceptions.
  if header.return_required
    and app_private.can_work_at_branch(header.branch_id)
    and (
      app_private.has_permission('deliveries.return_count')
      or app_private.has_permission('deliveries.return_approve')
      or app_private.has_permission('deliveries.return_post')
    )
  then
    return true;
  end if;
  return app_private.has_permission('deliveries.execute')
    and header.assigned_to is not distinct from auth.uid();
end;
$$;

-- Keepers need a return queue without opening the GM dispatch list.
create or replace function public.list_assigned_deliveries()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not (
    app_private.has_permission('deliveries.execute')
    or app_private.has_permission('deliveries.assign')
    or app_private.has_permission('dispatch.view')
    or app_private.has_permission('deliveries.return_view')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'kind', 'dispatch',
      'id', header.id,
      'request_number', header.request_number,
      'order_id', header.order_id,
      'order_number', orders.order_number,
      'branch_id', header.branch_id,
      'status', header.status,
      'version', header.version,
      'stock_consumed', header.stock_consumed,
      'assigned_to', header.assigned_to,
      'assigned_to_name', profiles.full_name,
      'created_at', header.created_at
    ) order by header.assigned_at desc nulls last, header.id)
    from public.stock_dispatch_requests header
    join public.orders on orders.id = header.order_id
    left join public.profiles on profiles.id = header.assigned_to
    where app_private.dispatch_can_view(header)
      and header.stock_consumed
      and header.status in ('dispatched', 'in_transit', 'delivered', 'exception')
      and (
        app_private.has_permission('deliveries.assign')
        or app_private.has_permission('dispatch.view')
        or header.assigned_to is not distinct from auth.uid()
        or (
          header.return_required
          and app_private.has_permission('deliveries.return_view')
        )
      )
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. DELIVERY_RETURN transaction identity. Must not reuse dispatch_request_id.
-- ---------------------------------------------------------------------------
alter table public.stock_transactions
  add column delivery_return_id uuid
    references public.stock_delivery_returns (id) on delete restrict;

alter table public.stock_transactions
  drop constraint stock_transactions_type_check;

alter table public.stock_transactions
  add constraint stock_transactions_type_check
    check (transaction_type in (
      'OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT', 'DISPATCH', 'DELIVERY_RETURN'
    ));

alter table public.stock_transactions
  drop constraint stock_transactions_shape_check;

alter table public.stock_transactions
  add constraint stock_transactions_shape_check check (
    (
      transaction_type = 'OPENING_STOCK'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is null
      and damage_report_id is null
      and delivery_return_id is null
    )
    or (
      transaction_type = 'CRATE_TRANSFER'
      and source_crate_id is not null
      and destination_crate_id is not null
      and source_crate_id <> destination_crate_id
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is null
      and delivery_return_id is null
    )
    or (
      transaction_type = 'RECEIPT'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is not null
      and receipt_line_id is not null
      and adjustment_request_id is null
      and dispatch_request_id is null
      and damage_report_id is null
      and delivery_return_id is null
    )
    or (
      transaction_type = 'ADJUSTMENT'
      and source_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and dispatch_request_id is null
      and delivery_return_id is null
      and (
        (
          adjustment_request_id is not null
          and damage_report_id is null
          and damage_posting_kind is null
        )
        or (
          adjustment_request_id is null
          and damage_report_id is not null
          and destination_crate_id is not null
          and damage_posting_kind in (
            'quarantine_intake', 'ordinary_writeoff', 'exceptional_writeoff'
          )
        )
      )
    )
    or (
      transaction_type = 'DISPATCH'
      and destination_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is not null
      and damage_report_id is null
      and delivery_return_id is null
    )
    or (
      transaction_type = 'DELIVERY_RETURN'
      and source_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is null
      and damage_report_id is null
      and delivery_return_id is not null
    )
  );

create unique index stock_transactions_delivery_return_once
  on public.stock_transactions (delivery_return_id)
  where delivery_return_id is not null;

create or replace function app_private.assert_stock_transaction_complete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  selected_type text;
  entry_count integer;
  entry_sum integer;
  linked_receipt uuid;
  linked_line uuid;
  linked_adjustment uuid;
  linked_dispatch uuid;
  linked_damage uuid;
  linked_kind text;
  linked_return uuid;
  header_qty integer;
  line_count integer;
  line_sum integer;
begin
  select
    stock_transactions.transaction_type,
    stock_transactions.receipt_id,
    stock_transactions.receipt_line_id,
    stock_transactions.adjustment_request_id,
    stock_transactions.dispatch_request_id,
    stock_transactions.damage_report_id,
    stock_transactions.damage_posting_kind,
    stock_transactions.delivery_return_id,
    stock_transactions.quantity
  into
    selected_type, linked_receipt, linked_line, linked_adjustment, linked_dispatch,
    linked_damage, linked_kind, linked_return, header_qty
  from public.stock_transactions
  where stock_transactions.id = new.transaction_id;

  select count(*), coalesce(sum(stock_ledger.quantity), 0)
  into entry_count, entry_sum
  from public.stock_ledger
  where stock_ledger.transaction_id = new.transaction_id;

  if selected_type = 'OPENING_STOCK' and (entry_count <> 1 or entry_sum <= 0) then
    raise exception 'opening stock ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'CRATE_TRANSFER' and (entry_count <> 2 or entry_sum <> 0) then
    raise exception 'transfer ledger must net to zero' using errcode = '23514';
  end if;

  if selected_type = 'RECEIPT' and (
    entry_count <> 1
    or entry_sum <= 0
    or linked_receipt is null
    or linked_line is null
  ) then
    raise exception 'receipt ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'ADJUSTMENT' then
    if linked_adjustment is not null then
      select count(*), coalesce(sum(stock_adjustment_lines.requested_cases), 0)
      into line_count, line_sum
      from public.stock_adjustment_lines
      where stock_adjustment_lines.request_id = linked_adjustment
        and not stock_adjustment_lines.released;

      if entry_count <> line_count
        or entry_sum is distinct from line_sum
        or entry_count < 1
      then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    elsif linked_damage is not null
      and linked_kind = 'quarantine_intake'
    then
      if entry_count < 1 or entry_sum is distinct from header_qty or entry_sum <= 0 then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    elsif linked_damage is not null
      and linked_kind in ('ordinary_writeoff', 'exceptional_writeoff')
    then
      if entry_count < 1 or entry_sum is distinct from (- header_qty) or entry_sum >= 0 then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    else
      raise exception 'adjustment ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type = 'DISPATCH' then
    if linked_dispatch is null
      or entry_count < 1
      or entry_sum >= 0
      or entry_sum is distinct from (- header_qty)
    then
      raise exception 'dispatch ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type = 'DELIVERY_RETURN' then
    if linked_return is null
      or entry_count < 1
      or entry_sum <= 0
      or entry_sum is distinct from header_qty
    then
      raise exception 'delivery return ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type not in (
    'OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT', 'DISPATCH', 'DELIVERY_RETURN'
  ) then
    raise exception 'stock transaction type is not supported' using errcode = '23514';
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grain snapshot, fingerprint, overlap, payload
-- ---------------------------------------------------------------------------
create or replace function app_private.dispatch_return_source_grains(
  header public.stock_dispatch_requests
)
returns table (
  order_line_id uuid,
  product_id uuid,
  lot_id uuid,
  source_crate_id uuid,
  reservation_id uuid,
  dispatched_cases integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  shipment public.order_shipments%rowtype;
begin
  shipment := app_private.open_shipment_for_picking(header.picking_request_id);
  if shipment.id is not null then
    -- One shipped grain per (line, product, lot, crate). Duplicates are
    -- ambiguous provenance even when quantities could be summed.
    if exists (
      select 1
      from public.order_shipment_lots
      where order_shipment_lots.shipment_id = shipment.id
        and order_shipment_lots.shipped_cases > 0
      group by
        order_shipment_lots.order_line_id,
        order_shipment_lots.product_id,
        order_shipment_lots.lot_id,
        order_shipment_lots.crate_id
      having count(*) > 1
    ) then
      raise exception 'shipment lots are ambiguous for return grains'
        using errcode = '23514';
    end if;

    return query
    select
      order_shipment_lots.order_line_id,
      order_shipment_lots.product_id,
      order_shipment_lots.lot_id,
      order_shipment_lots.crate_id,
      order_shipment_lots.reservation_id,
      order_shipment_lots.shipped_cases
    from public.order_shipment_lots
    where order_shipment_lots.shipment_id = shipment.id
      and order_shipment_lots.shipped_cases > 0
      and order_shipment_lots.lot_id is not null;
    return;
  end if;

  -- Consumed-reservation fallback. Do not collapse multiple reservations with
  -- array_agg(id)[1]: that discards reservation identity. Fail closed instead.
  if exists (
    select 1
    from public.stock_reservations
    where stock_reservations.picking_request_id = header.picking_request_id
      and stock_reservations.status = 'consumed'
    group by
      stock_reservations.order_line_id,
      stock_reservations.product_id,
      stock_reservations.lot_id,
      stock_reservations.crate_id
    having count(*) > 1
  ) then
    raise exception 'consumed reservations are ambiguous for return grains'
      using errcode = '23514';
  end if;

  return query
  select
    stock_reservations.order_line_id,
    stock_reservations.product_id,
    stock_reservations.lot_id,
    stock_reservations.crate_id,
    stock_reservations.id,
    stock_reservations.reserved_cases
  from public.stock_reservations
  where stock_reservations.picking_request_id = header.picking_request_id
    and stock_reservations.status = 'consumed'
    and stock_reservations.lot_id is not null;
end;
$$;

revoke all on function app_private.dispatch_return_source_grains(public.stock_dispatch_requests)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_return_grains_match_ledger(
  header public.stock_dispatch_requests
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if header.posted_transaction_id is null then
    raise exception 'dispatch stock transaction is missing' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_ledger
    where stock_ledger.transaction_id = header.posted_transaction_id
      and (
        stock_ledger.quantity >= 0
        or stock_ledger.lot_id is null
      )
  ) then
    raise exception 'dispatch ledger is not a lot-attributed debit' using errcode = '23514';
  end if;

  if exists (
    select 1
    from (
      select
        stock_ledger.product_id,
        stock_ledger.lot_id,
        stock_ledger.crate_id,
        (- stock_ledger.quantity) as dispatched_cases
      from public.stock_ledger
      where stock_ledger.transaction_id = header.posted_transaction_id
    ) ledger
    full join (
      select
        grains.product_id,
        grains.lot_id,
        grains.source_crate_id as crate_id,
        sum(grains.dispatched_cases)::integer as dispatched_cases
      from app_private.dispatch_return_source_grains(header) grains
      group by grains.product_id, grains.lot_id, grains.source_crate_id
    ) grain
      on grain.product_id = ledger.product_id
     and grain.lot_id = ledger.lot_id
     and grain.crate_id = ledger.crate_id
    where ledger.dispatched_cases is distinct from grain.dispatched_cases
  ) then
    raise exception 'return lots cannot be reconciled to the posted dispatch'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_return_grains_match_ledger(public.stock_dispatch_requests)
  from public, anon, authenticated, service_role;

create or replace function app_private.return_lot_fingerprint(target_return uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(coalesce((
    select string_agg(
      concat_ws(
        ':',
        stock_delivery_return_lots.id::text,
        stock_delivery_return_lots.delivered_cases::text,
        stock_delivery_return_lots.saleable_cases::text,
        stock_delivery_return_lots.damaged_cases::text,
        stock_delivery_return_lots.uncertain_cases::text,
        stock_delivery_return_lots.missing_cases::text,
        coalesce(stock_delivery_return_lots.receiving_crate_id::text, '')
      ),
      '|'
      order by stock_delivery_return_lots.id
    )
    from public.stock_delivery_return_lots
    where stock_delivery_return_lots.return_id = target_return
  ), ''));
$$;

revoke all on function app_private.return_lot_fingerprint(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.unresolved_return_cases(target_return uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(
    stock_delivery_return_lots.dispatched_cases
    - stock_delivery_return_lots.delivered_cases
    - stock_delivery_return_lots.saleable_cases
    - stock_delivery_return_lots.damaged_cases
    - stock_delivery_return_lots.uncertain_cases
    - stock_delivery_return_lots.missing_cases
  ), 0)::integer
  from public.stock_delivery_return_lots
  where stock_delivery_return_lots.return_id = target_return;
$$;

revoke all on function app_private.unresolved_return_cases(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_return_matches_outcome(
  dispatch public.stock_dispatch_requests,
  target_return uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.stock_dispatch_outcome_lines outcome
    left join (
      select
        stock_delivery_return_lots.order_line_id,
        sum(stock_delivery_return_lots.delivered_cases)::integer as delivered_cases,
        sum(
          stock_delivery_return_lots.saleable_cases
          + stock_delivery_return_lots.damaged_cases
          + stock_delivery_return_lots.uncertain_cases
          + stock_delivery_return_lots.missing_cases
        )::integer as returned_cases
      from public.stock_delivery_return_lots
      where stock_delivery_return_lots.return_id = target_return
      group by stock_delivery_return_lots.order_line_id
    ) grain on grain.order_line_id = outcome.order_line_id
    where outcome.dispatch_id = dispatch.id
      and (
        coalesce(grain.delivered_cases, 0) is distinct from outcome.delivered_cases
        or coalesce(grain.returned_cases, 0) is distinct from outcome.undelivered_cases
      )
  ) then
    raise exception 'lot allocation does not match the delivery outcome'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_return_matches_outcome(public.stock_dispatch_requests, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_transit_damage_overlap(
  dispatch public.stock_dispatch_requests,
  target_return uuid
)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  report_ids uuid[];
begin
  select coalesce(array_agg(distinct damage_reports.id), '{}')
  into report_ids
  from public.damage_reports
  where damage_reports.dispatch_id = dispatch.id
    and damage_reports.scenario = 'transit'
    and damage_reports.status not in ('cancelled', 'rejected');

  if exists (
    select 1
    from public.damage_reports
    join public.damage_report_lines
      on damage_report_lines.damage_report_id = damage_reports.id
    where damage_reports.id = any (report_ids)
      and damage_report_lines.lot_id is null
  ) then
    raise exception 'unresolved transit damage cannot be mapped to dispatched lots'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.damage_reports
    join public.damage_report_lines
      on damage_report_lines.damage_report_id = damage_reports.id
    join public.stock_delivery_return_lots lots
      on lots.return_id = target_return
     and lots.lot_id = damage_report_lines.lot_id
     and lots.product_id = damage_report_lines.product_id
    where damage_reports.id = any (report_ids)
      and (
        lots.saleable_cases + lots.damaged_cases + lots.uncertain_cases
      ) > 0
  ) then
    raise exception 'unresolved transit damage overlaps this return'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_transactions
    where stock_transactions.damage_report_id = any (report_ids)
      and stock_transactions.delivery_return_id is null
  ) then
    raise exception 'transit damage already posted stock for this dispatch'
      using errcode = '23514';
  end if;

  return report_ids;
end;
$$;

revoke all on function app_private.assert_transit_damage_overlap(public.stock_dispatch_requests, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.delivery_return_event(
  target_return uuid,
  event_type text,
  from_status text,
  to_status text,
  return_version integer,
  payload jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.stock_delivery_return_events (
    return_id, event_type, actor_id, from_status, to_status, return_version, payload
  )
  values (
    target_return,
    event_type,
    coalesce(
      auth.uid(),
      (select created_by from public.stock_delivery_returns where id = target_return)
    ),
    from_status,
    to_status,
    return_version,
    coalesce(payload, '{}'::jsonb)
  );
end;
$$;

revoke all on function app_private.delivery_return_event(uuid, text, text, text, integer, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.delivery_return_payload(target_return uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
begin
  select * into header
  from public.stock_delivery_returns
  where id = target_return;
  if not found or not app_private.delivery_return_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into dispatch
  from public.stock_dispatch_requests
  where id = header.dispatch_id;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'dispatch_id', header.dispatch_id,
    'dispatch_number', dispatch.request_number,
    'branch_id', header.branch_id,
    'return_number', header.return_number,
    'status', header.status,
    'version', header.version,
    'declared_returned_cases', header.declared_returned_cases,
    'handed_back_at', header.handed_back_at,
    'handed_back_by', header.handed_back_by,
    'handback_notes', header.handback_notes,
    'counted_at', header.counted_at,
    'counted_by', header.counted_by,
    'counted_by_name', (
      select profiles.full_name from public.profiles where profiles.id = header.counted_by
    ),
    'approved_at', header.approved_at,
    'approved_by', header.approved_by,
    'posted_at', header.posted_at,
    'posted_by', header.posted_by,
    'posted_transaction_id', header.posted_transaction_id,
    'closed_at', header.closed_at,
    'related_damage_report_ids', to_jsonb(header.related_damage_report_ids),
    'unresolved_cases', app_private.unresolved_return_cases(header.id),
    'cutover', pg_catalog.jsonb_build_object(
      'dual_write_enabled', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      )
    ),
    'lots', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', lots.id,
        'order_line_id', lots.order_line_id,
        'product_id', lots.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'lot_id', lots.lot_id,
        'manufacturer_lot_code', stock_lots.manufacturer_lot_code,
        'expiry_date', stock_lots.expiry_date,
        'lot_status', stock_lots.status,
        'source_crate_id', lots.source_crate_id,
        'source_crate_code', crates.code,
        'dispatched_cases', lots.dispatched_cases,
        'delivered_cases', lots.delivered_cases,
        'saleable_cases', lots.saleable_cases,
        'damaged_cases', lots.damaged_cases,
        'uncertain_cases', lots.uncertain_cases,
        'missing_cases', lots.missing_cases,
        'unresolved_cases', lots.dispatched_cases - lots.delivered_cases
          - lots.saleable_cases - lots.damaged_cases - lots.uncertain_cases
          - lots.missing_cases,
        'receiving_crate_id', lots.receiving_crate_id,
        'receiving_crate_code', receiving.code,
        'posted_crate_id', lots.posted_crate_id,
        'posted_crate_code', posted.code
      ) order by products.sku, stock_lots.id, lots.id)
      from public.stock_delivery_return_lots lots
      join public.products on products.id = lots.product_id
      join public.stock_lots on stock_lots.id = lots.lot_id
      join public.crates on crates.id = lots.source_crate_id
      left join public.crates receiving on receiving.id = lots.receiving_crate_id
      left join public.crates posted on posted.id = lots.posted_crate_id
      where lots.return_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_delivery_return_events.id,
        'event_type', stock_delivery_return_events.event_type,
        'actor_id', stock_delivery_return_events.actor_id,
        'from_status', stock_delivery_return_events.from_status,
        'to_status', stock_delivery_return_events.to_status,
        'return_version', stock_delivery_return_events.return_version,
        'payload', stock_delivery_return_events.payload,
        'created_at', stock_delivery_return_events.created_at
      ) order by stock_delivery_return_events.created_at, stock_delivery_return_events.id)
      from public.stock_delivery_return_events
      where stock_delivery_return_events.return_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.delivery_return_payload(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.ensure_delivery_return(target_dispatch uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_dispatch_requests;
  existing uuid;
  created_id uuid;
  return_number text;
  grain record;
begin
  perform set_config('app.delivery_return_write', 'on', true);

  select * into header
  from public.stock_dispatch_requests
  where id = target_dispatch
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select id into existing
  from public.stock_delivery_returns
  where dispatch_id = header.id;
  if existing is not null then
    return existing;
  end if;

  if header.stock_consumed is distinct from true
    or header.status is distinct from 'exception'
    or header.return_required is distinct from true
  then
    raise exception 'a delivery return requires a failed or partial dispatch'
      using errcode = '23514';
  end if;

  perform app_private.assert_return_grains_match_ledger(header);

  if not exists (
    select 1 from app_private.dispatch_return_source_grains(header)
  ) then
    raise exception 'dispatch has no lot-attributed return grain' using errcode = '23514';
  end if;

  return_number := 'DR-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
    || '-'
    || lpad(pg_catalog.nextval('public.stock_delivery_return_seq')::text, 6, '0');

  insert into public.stock_delivery_returns (
    dispatch_id, branch_id, return_number, status, created_by
  )
  values (
    header.id,
    header.branch_id,
    return_number,
    'awaiting_handback',
    coalesce(auth.uid(), header.created_by)
  )
  returning id into created_id;

  for grain in
    select * from app_private.dispatch_return_source_grains(header)
  loop
    insert into public.stock_delivery_return_lots (
      return_id, order_line_id, product_id, lot_id, source_crate_id,
      reservation_id, dispatched_cases
    )
    values (
      created_id, grain.order_line_id, grain.product_id, grain.lot_id,
      grain.source_crate_id, grain.reservation_id, grain.dispatched_cases
    );
  end loop;

  perform app_private.delivery_return_event(
    created_id, 'opened', null, 'awaiting_handback', 1,
    pg_catalog.jsonb_build_object('dispatch_id', header.id)
  );

  return created_id;
exception
  when unique_violation then
    select id into existing
    from public.stock_delivery_returns
    where dispatch_id = header.id;
    if existing is not null then
      return existing;
    end if;
    raise exception 'a return wave is already recorded for this dispatch'
      using errcode = '23514';
end;
$$;

revoke all on function app_private.ensure_delivery_return(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.tg_open_delivery_return()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.return_required
    and new.status = 'exception'
    and new.stock_consumed
  then
    perform app_private.ensure_delivery_return(new.id);
  end if;
  return new;
end;
$$;

revoke all on function app_private.tg_open_delivery_return()
  from public, anon, authenticated, service_role;

create trigger stock_dispatch_requests_open_return
  after update of return_required, status on public.stock_dispatch_requests
  for each row execute function app_private.tg_open_delivery_return();

do $$
declare
  dispatch_id uuid;
begin
  perform set_config('app.delivery_return_write', 'on', true);
  perform set_config('app.dispatch_write', 'on', true);
  for dispatch_id in
    select stock_dispatch_requests.id
    from public.stock_dispatch_requests
    where stock_dispatch_requests.return_required
      and stock_dispatch_requests.status = 'exception'
      and not exists (
        select 1
        from public.stock_delivery_returns
        where stock_delivery_returns.dispatch_id = stock_dispatch_requests.id
      )
  loop
    begin
      perform app_private.ensure_delivery_return(dispatch_id);
    exception
      when others then
        null;
    end;
  end loop;
end;
$$;

create or replace function app_private.lock_delivery_return(
  target_return uuid,
  expected_version integer
)
returns public.stock_delivery_returns
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
begin
  perform set_config('app.delivery_return_write', 'on', true);
  perform set_config('app.dispatch_write', 'on', true);

  -- Lock the originating dispatch first. FOUND is from this PERFORM.
  perform stock_dispatch_requests.id
  from public.stock_dispatch_requests
  join public.stock_delivery_returns
    on stock_delivery_returns.dispatch_id = stock_dispatch_requests.id
   and stock_delivery_returns.id = target_return
  for update of stock_dispatch_requests;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into header
  from public.stock_delivery_returns
  where id = target_return
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.version is distinct from expected_version then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  if not app_private.can_work_at_branch(header.branch_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_operational_active_branch(header.branch_id);

  return header;
end;
$$;

revoke all on function app_private.lock_delivery_return(uuid, integer)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Public RPCs
-- ---------------------------------------------------------------------------
create or replace function public.get_delivery_return(target_dispatch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected uuid;
begin
  select id into selected
  from public.stock_delivery_returns
  where dispatch_id = target_dispatch;
  if selected is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return app_private.delivery_return_payload(selected);
end;
$$;

create or replace function public.declare_delivery_return_handback(
  target_return uuid,
  declared_returned_cases integer,
  handback_notes text,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  cleaned_notes text;
  undelivered integer;
  declared_qty integer;
begin
  perform app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_permission('deliveries.return_handback');
  header := app_private.lock_delivery_return(target_return, expected_version);

  select * into dispatch
  from public.stock_dispatch_requests
  where id = header.dispatch_id;

  if dispatch.assigned_to is distinct from auth.uid() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.status not in ('awaiting_handback', 'handed_back') then
    raise exception 'handback is no longer allowed' using errcode = '23514';
  end if;

  declared_qty := declared_returned_cases;
  if declared_qty is null
    or declared_qty < 0
    or declared_qty > 1000000
  then
    raise exception 'handback quantity is invalid' using errcode = '23514';
  end if;

  select coalesce(sum(stock_dispatch_outcome_lines.undelivered_cases), 0)
  into undelivered
  from public.stock_dispatch_outcome_lines
  where stock_dispatch_outcome_lines.dispatch_id = dispatch.id;

  if declared_qty > undelivered then
    raise exception 'handback cannot exceed undelivered cases' using errcode = '23514';
  end if;

  cleaned_notes := nullif(btrim(coalesce(handback_notes, '')), '');

  update public.stock_delivery_returns
  set
    status = 'handed_back',
    declared_returned_cases = declared_qty,
    handed_back_at = pg_catalog.clock_timestamp(),
    handed_back_by = auth.uid(),
    handback_notes = cleaned_notes,
    version = header.version + 1
  where id = header.id;

  update public.stock_dispatch_requests
  set
    physical_return_status = 'handed_back',
    version = dispatch.version + 1
  where id = dispatch.id;

  perform app_private.delivery_return_event(
    header.id, 'handed_back', header.status, 'handed_back', header.version + 1,
    pg_catalog.jsonb_build_object('declared_returned_cases', declared_qty)
  );

  return app_private.delivery_return_payload(header.id);
end;
$$;

create or replace function public.count_delivery_return(
  target_return uuid,
  lot_counts jsonb,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  entry jsonb;
  grain public.stock_delivery_return_lots%rowtype;
  selected_lot public.stock_lots%rowtype;
  selected_crate public.crates%rowtype;
  crate_branch uuid;
  crate_role text;
  delivered integer;
  saleable integer;
  damaged integer;
  uncertain integer;
  missing integer;
  receiving uuid;
  today date := (pg_catalog.timezone('UTC', pg_catalog.clock_timestamp()))::date;
begin
  perform app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_permission('deliveries.return_count');
  header := app_private.lock_delivery_return(target_return, expected_version);

  select * into dispatch
  from public.stock_dispatch_requests
  where id = header.dispatch_id;

  if header.status not in ('handed_back', 'counted') then
    raise exception 'count requires a handed-back return' using errcode = '23514';
  end if;

  if jsonb_typeof(lot_counts) is distinct from 'array'
    or jsonb_array_length(lot_counts) < 1
  then
    raise exception 'lot counts are required' using errcode = '23514';
  end if;

  for entry in select jsonb_array_elements(lot_counts)
  loop
    select * into grain
    from public.stock_delivery_return_lots
    where stock_delivery_return_lots.id = (entry ->> 'id')::uuid
      and stock_delivery_return_lots.return_id = header.id
    for update;
    if not found then
      raise exception 'return lot is invalid' using errcode = '23514';
    end if;

    delivered := coalesce((entry ->> 'delivered_cases')::integer, 0);
    saleable := coalesce((entry ->> 'saleable_cases')::integer, 0);
    damaged := coalesce((entry ->> 'damaged_cases')::integer, 0);
    uncertain := coalesce((entry ->> 'uncertain_cases')::integer, 0);
    missing := coalesce((entry ->> 'missing_cases')::integer, 0);
    receiving := nullif(entry ->> 'receiving_crate_id', '')::uuid;

    if delivered < 0 or saleable < 0 or damaged < 0 or uncertain < 0 or missing < 0
      or delivered + saleable + damaged + uncertain + missing <> grain.dispatched_cases
    then
      raise exception 'lot allocation must consume the dispatched grain'
        using errcode = '23514';
    end if;

    select * into selected_lot from public.stock_lots where stock_lots.id = grain.lot_id;
    if (
      selected_lot.status in ('expired_blocked', 'quarantined', 'legacy_unattributed')
      or (selected_lot.expiry_date is not null and selected_lot.expiry_date < today)
    ) and saleable > 0 then
      raise exception 'expired or blocked lots cannot return to saleable stock'
        using errcode = '23514';
    end if;

    if saleable > 0 then
      if receiving is null then
        raise exception 'saleable cases require a storage crate' using errcode = '23514';
      end if;
      select crates.* into selected_crate
      from public.crates
      where crates.id = receiving;
      select zones.branch_id, crates.location_role
      into crate_branch, crate_role
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = receiving;
      if crate_branch is distinct from header.branch_id then
        raise exception 'receiving crate belongs to another godown' using errcode = '23514';
      end if;
      if crate_role is distinct from 'storage'
        or selected_crate.is_active is distinct from true
      then
        raise exception 'saleable cases require an active storage crate'
          using errcode = '23514';
      end if;
    else
      receiving := null;
    end if;

    update public.stock_delivery_return_lots
    set
      delivered_cases = delivered,
      saleable_cases = saleable,
      damaged_cases = damaged,
      uncertain_cases = uncertain,
      missing_cases = missing,
      receiving_crate_id = receiving
    where id = grain.id;
  end loop;

  if exists (
    select 1
    from public.stock_delivery_return_lots
    where return_id = header.id
      and dispatched_cases
        <> delivered_cases + saleable_cases + damaged_cases + uncertain_cases + missing_cases
  ) then
    raise exception 'every dispatched lot must be fully classified' using errcode = '23514';
  end if;

  if (
    select coalesce(sum(
      stock_delivery_return_lots.saleable_cases
      + stock_delivery_return_lots.damaged_cases
      + stock_delivery_return_lots.uncertain_cases
    ), 0)
    from public.stock_delivery_return_lots
    where stock_delivery_return_lots.return_id = header.id
  ) > header.declared_returned_cases then
    raise exception 'physical count cannot exceed the driver handback'
      using errcode = '23514';
  end if;

  perform app_private.assert_return_matches_outcome(dispatch, header.id);

  update public.stock_delivery_returns
  set
    status = 'counted',
    counted_at = pg_catalog.clock_timestamp(),
    counted_by = auth.uid(),
    approved_at = null,
    approved_by = null,
    approval_fingerprint = null,
    version = header.version + 1
  where id = header.id;

  update public.stock_dispatch_requests
  set
    physical_return_status = 'counted',
    version = dispatch.version + 1
  where id = dispatch.id;

  perform app_private.delivery_return_event(
    header.id, 'counted', header.status, 'counted', header.version + 1, '{}'::jsonb
  );

  return app_private.delivery_return_payload(header.id);
end;
$$;

create or replace function public.approve_delivery_return(
  target_return uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  fingerprint text;
  damage_ids uuid[];
begin
  perform app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_permission('deliveries.return_approve');
  header := app_private.lock_delivery_return(target_return, expected_version);

  select * into dispatch
  from public.stock_dispatch_requests
  where id = header.dispatch_id;

  if header.status is distinct from 'counted' then
    raise exception 'approval requires a Store Keeper count' using errcode = '23514';
  end if;
  if header.counted_by is null or header.counted_by is not distinct from auth.uid() then
    raise exception 'godown manager cannot certify their own count' using errcode = '23514';
  end if;
  if app_private.unresolved_return_cases(header.id) <> 0 then
    raise exception 'unresolved return quantities remain' using errcode = '23514';
  end if;

  perform app_private.assert_return_matches_outcome(dispatch, header.id);
  damage_ids := app_private.assert_transit_damage_overlap(dispatch, header.id);
  fingerprint := app_private.return_lot_fingerprint(header.id);

  update public.stock_delivery_returns
  set
    status = 'approved',
    approved_at = pg_catalog.clock_timestamp(),
    approved_by = auth.uid(),
    approval_fingerprint = fingerprint,
    related_damage_report_ids = damage_ids,
    version = header.version + 1
  where id = header.id;

  update public.stock_dispatch_requests
  set
    physical_return_status = 'approved',
    version = dispatch.version + 1
  where id = dispatch.id;

  perform app_private.delivery_return_event(
    header.id, 'approved', 'counted', 'approved', header.version + 1,
    pg_catalog.jsonb_build_object('fingerprint', fingerprint)
  );

  return app_private.delivery_return_payload(header.id);
end;
$$;

create or replace function public.return_delivery_return_to_count(
  target_return uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
begin
  perform app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_permission('deliveries.return_approve');
  header := app_private.lock_delivery_return(target_return, expected_version);
  if header.status is distinct from 'approved' then
    raise exception 'only an approved return can be sent back to count'
      using errcode = '23514';
  end if;

  select * into dispatch from public.stock_dispatch_requests where id = header.dispatch_id;

  update public.stock_delivery_returns
  set
    status = 'counted',
    approved_at = null,
    approved_by = null,
    approval_fingerprint = null,
    version = header.version + 1
  where id = header.id;

  update public.stock_dispatch_requests
  set
    physical_return_status = 'counted',
    version = dispatch.version + 1
  where id = dispatch.id;

  perform app_private.delivery_return_event(
    header.id, 'returned_to_count', 'approved', 'counted', header.version + 1, '{}'::jsonb
  );
  return app_private.delivery_return_payload(header.id);
end;
$$;

create or replace function public.post_delivery_return(
  target_return uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  selected_lot public.stock_lots%rowtype;
  selected_crate public.crates%rowtype;
  crate_branch uuid;
  crate_role text;
  quarantine_crate uuid;
  needs_quarantine boolean := false;
  physical_total integer := 0;
  first_product uuid;
  single_crate uuid;
  crate_count integer;
  created_txn uuid;
  txn_key text;
  fingerprint text;
  lot_deltas jsonb := '[]'::jsonb;
  grain record;
  crate_ids uuid[];
  today date := (pg_catalog.timezone('UTC', pg_catalog.clock_timestamp()))::date;
  damage_ids uuid[];
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_permission('deliveries.return_post');
  perform app_private.acquire_stock_cutover_shared_lock();
  header := app_private.lock_delivery_return(target_return, expected_version);

  select * into dispatch
  from public.stock_dispatch_requests
  where id = header.dispatch_id;

  if header.status = 'posted' and header.posted_transaction_id is not null then
    return app_private.delivery_return_payload(header.id);
  end if;

  if header.status is distinct from 'approved' then
    raise exception 'posting requires godown manager approval' using errcode = '23514';
  end if;
  if header.counted_by is null
    or header.approved_by is null
    or header.counted_by is not distinct from header.approved_by
    or header.counted_by is not distinct from auth.uid()
  then
    raise exception 'godown manager cannot certify their own count' using errcode = '23514';
  end if;
  if header.approval_fingerprint is distinct from app_private.return_lot_fingerprint(header.id) then
    raise exception 'approval is no longer valid for this count' using errcode = '23514';
  end if;
  if app_private.unresolved_return_cases(header.id) <> 0 then
    raise exception 'unresolved return quantities remain' using errcode = '23514';
  end if;
  if not exists (
    select 1 from public.app_configuration
    where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
  ) then
    raise exception 'lot-aware delivery returns require dual-write to be enabled'
      using errcode = '23514';
  end if;

  perform app_private.assert_return_grains_match_ledger(dispatch);
  perform app_private.assert_return_matches_outcome(dispatch, header.id);
  damage_ids := app_private.assert_transit_damage_overlap(dispatch, header.id);

  select
    coalesce(sum(saleable_cases + damaged_cases + uncertain_cases), 0),
    bool_or(damaged_cases + uncertain_cases > 0)
  into physical_total, needs_quarantine
  from public.stock_delivery_return_lots
  where return_id = header.id;

  if physical_total < 1 then
    raise exception 'posting requires physically returned cases; close missing returns separately'
      using errcode = '23514';
  end if;

  if needs_quarantine then
    perform app_private.enable_trusted_guc('app.damage_stock_write');
    perform app_private.enable_trusted_guc('app.quarantine_location_write');
    quarantine_crate := app_private.ensure_godown_quarantine_crate(header.branch_id);
  end if;

  for grain in
    select * from public.stock_delivery_return_lots
    where return_id = header.id
    order by id
    for update
  loop
    select * into selected_lot from public.stock_lots where stock_lots.id = grain.lot_id;
    if grain.saleable_cases > 0 then
      if (
        selected_lot.status in ('expired_blocked', 'quarantined', 'legacy_unattributed')
        or (selected_lot.expiry_date is not null and selected_lot.expiry_date < today)
      ) then
        raise exception 'expired or blocked lots cannot return to saleable stock'
          using errcode = '23514';
      end if;
      if grain.receiving_crate_id is null then
        raise exception 'saleable cases require a storage crate' using errcode = '23514';
      end if;
      select crates.* into selected_crate
      from public.crates
      where crates.id = grain.receiving_crate_id;
      select zones.branch_id, crates.location_role
      into crate_branch, crate_role
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = grain.receiving_crate_id;
      if crate_branch is distinct from header.branch_id then
        raise exception 'receiving crate belongs to another godown' using errcode = '23514';
      end if;
      if crate_role is distinct from 'storage'
        or selected_crate.is_active is distinct from true
      then
        raise exception 'saleable cases require an active storage crate' using errcode = '23514';
      end if;
    end if;
    if grain.damaged_cases + grain.uncertain_cases > 0 and quarantine_crate is null then
      raise exception 'damaged cases require a quarantine crate' using errcode = '23514';
    end if;
  end loop;

  select array_agg(distinct dest.crate_id order by dest.crate_id)
  into crate_ids
  from public.stock_delivery_return_lots lots
  cross join lateral (
    values
      (lots.receiving_crate_id, lots.saleable_cases),
      (quarantine_crate, lots.damaged_cases + lots.uncertain_cases)
  ) dest(crate_id, qty)
  where lots.return_id = header.id
    and dest.qty > 0
    and dest.crate_id is not null;

  perform products.id
  from public.products
  where products.id in (
    select stock_delivery_return_lots.product_id
    from public.stock_delivery_return_lots
    where stock_delivery_return_lots.return_id = header.id
      and stock_delivery_return_lots.saleable_cases
        + stock_delivery_return_lots.damaged_cases
        + stock_delivery_return_lots.uncertain_cases > 0
  )
  order by products.id
  for update;

  perform app_private.prepare_stock_locations(crate_ids);

  perform stock_lots.id
  from public.stock_lots
  where stock_lots.id in (
    select stock_delivery_return_lots.lot_id
    from public.stock_delivery_return_lots
    where stock_delivery_return_lots.return_id = header.id
      and stock_delivery_return_lots.saleable_cases
        + stock_delivery_return_lots.damaged_cases
        + stock_delivery_return_lots.uncertain_cases > 0
  )
  order by stock_lots.id
  for update;

  -- Re-check saleable eligibility after the lot lock so expiry/status cannot
  -- race between the first grain loop and ledger credit.
  if exists (
    select 1
    from public.stock_delivery_return_lots lots
    join public.stock_lots on stock_lots.id = lots.lot_id
    where lots.return_id = header.id
      and lots.saleable_cases > 0
      and (
        stock_lots.status in ('expired_blocked', 'quarantined', 'legacy_unattributed')
        or (
          stock_lots.expiry_date is not null
          and stock_lots.expiry_date < today
        )
      )
  ) then
    raise exception 'expired or blocked lots cannot return to saleable stock'
      using errcode = '23514';
  end if;

  perform stock_lot_balances.lot_id
  from public.stock_lot_balances
  join (
    select
      lots.lot_id,
      dest.crate_id
    from public.stock_delivery_return_lots lots
    cross join lateral (
      values
        (lots.receiving_crate_id, lots.saleable_cases),
        (quarantine_crate, lots.damaged_cases + lots.uncertain_cases)
    ) dest(crate_id, qty)
    where lots.return_id = header.id
      and dest.qty > 0
      and dest.crate_id is not null
  ) dest on dest.lot_id = stock_lot_balances.lot_id
   and dest.crate_id = stock_lot_balances.crate_id
  order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
  for update of stock_lot_balances;

  perform stock_balances.crate_id
  from public.stock_balances
  join (
    select
      lots.product_id,
      dest.crate_id
    from public.stock_delivery_return_lots lots
    cross join lateral (
      values
        (lots.receiving_crate_id, lots.saleable_cases),
        (quarantine_crate, lots.damaged_cases + lots.uncertain_cases)
    ) dest(crate_id, qty)
    where lots.return_id = header.id
      and dest.qty > 0
      and dest.crate_id is not null
  ) dest on dest.product_id = stock_balances.product_id
   and dest.crate_id = stock_balances.crate_id
  order by stock_balances.crate_id, stock_balances.product_id
  for update of stock_balances;

  select
    (array_agg(dest.product_id order by dest.product_id))[1],
    count(distinct dest.crate_id),
    (array_agg(dest.crate_id order by dest.crate_id))[1]
  into first_product, crate_count, single_crate
  from (
    select
      lots.product_id,
      dest.crate_id
    from public.stock_delivery_return_lots lots
    cross join lateral (
      values
        (lots.receiving_crate_id, lots.saleable_cases),
        (quarantine_crate, lots.damaged_cases + lots.uncertain_cases)
    ) dest(crate_id, qty)
    where lots.return_id = header.id
      and dest.qty > 0
      and dest.crate_id is not null
  ) dest;

  txn_key := 'delivery-return:' || header.id::text;
  fingerprint := header.approval_fingerprint;

  begin
    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      notes, product_id, destination_crate_id, quantity, delivery_return_id
    )
    values (
      'DELIVERY_RETURN',
      header.return_number,
      auth.uid(),
      txn_key,
      fingerprint,
      'Delivery return ' || header.return_number,
      first_product,
      case when crate_count = 1 then single_crate else null end,
      physical_total,
      header.id
    )
    returning id into created_txn;
  exception
    when unique_violation then
      if exists (
        select 1
        from public.stock_delivery_returns
        where stock_delivery_returns.id = header.id
          and stock_delivery_returns.status = 'posted'
          and stock_delivery_returns.posted_transaction_id is not null
      ) then
        return app_private.delivery_return_payload(header.id);
      end if;
      raise exception 'idempotency key was already used for a different request'
        using errcode = '23505';
  end;

  for grain in
    select
      lots.product_id,
      lots.lot_id,
      dest.crate_id,
      sum(dest.qty)::integer as credit_cases
    from public.stock_delivery_return_lots lots
    cross join lateral (
      values
        (lots.receiving_crate_id, lots.saleable_cases),
        (quarantine_crate, lots.damaged_cases + lots.uncertain_cases)
    ) dest(crate_id, qty)
    where lots.return_id = header.id
      and dest.qty > 0
      and dest.crate_id is not null
    group by lots.product_id, lots.lot_id, dest.crate_id
    order by dest.crate_id, lots.lot_id, lots.product_id
  loop
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    )
    values (
      created_txn,
      grain.product_id,
      grain.crate_id,
      grain.credit_cases,
      auth.uid(),
      pg_catalog.clock_timestamp(),
      grain.lot_id
    );

    lot_deltas := lot_deltas || jsonb_build_array(jsonb_build_object(
      'product_id', grain.product_id,
      'lot_id', grain.lot_id,
      'crate_id', grain.crate_id,
      'quantity', grain.credit_cases
    ));
  end loop;

  perform app_private.apply_lot_aware_stock_deltas(created_txn, lot_deltas);

  update public.stock_delivery_return_lots lots
  set posted_crate_id = case
    when lots.saleable_cases > 0 and lots.damaged_cases + lots.uncertain_cases = 0
      then lots.receiving_crate_id
    when lots.saleable_cases = 0 and lots.damaged_cases + lots.uncertain_cases > 0
      then quarantine_crate
    else null
  end
  where lots.return_id = header.id
    and lots.saleable_cases + lots.damaged_cases + lots.uncertain_cases > 0;

  update public.stock_delivery_returns
  set
    status = 'posted',
    posted_at = pg_catalog.clock_timestamp(),
    posted_by = auth.uid(),
    posted_transaction_id = created_txn,
    related_damage_report_ids = damage_ids,
    version = header.version + 1
  where id = header.id;

  update public.stock_dispatch_requests
  set
    physical_return_status = 'posted',
    version = dispatch.version + 1
  where id = dispatch.id;

  perform app_private.delivery_return_event(
    header.id, 'posted', 'approved', 'posted', header.version + 1,
    pg_catalog.jsonb_build_object(
      'transaction_id', created_txn,
      'physical_cases', physical_total,
      'fingerprint', fingerprint
    )
  );

  perform app_private.dispatch_event(
    dispatch.id, 'return_posted', 'exception', 'exception', dispatch.version + 1,
    pg_catalog.jsonb_build_object(
      'return_id', header.id,
      'transaction_id', created_txn,
      'physical_cases', physical_total
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'post_delivery_return', 'stock_delivery_returns', header.id,
    pg_catalog.jsonb_build_object(
      'return_number', header.return_number,
      'transaction_id', created_txn,
      'physical_cases', physical_total
    )
  );

  return app_private.delivery_return_payload(header.id);
end;
$$;

create or replace function public.close_delivery_return_missing(
  target_return uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  physical_total integer;
  missing_total integer;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_permission('deliveries.return_post');
  header := app_private.lock_delivery_return(target_return, expected_version);

  select * into dispatch
  from public.stock_dispatch_requests
  where id = header.dispatch_id;

  if header.status = 'closed_missing' then
    return app_private.delivery_return_payload(header.id);
  end if;
  if header.status not in ('counted', 'approved') then
    raise exception 'closing missing returns requires a Store Keeper count'
      using errcode = '23514';
  end if;
  if header.counted_by is null or header.counted_by is not distinct from auth.uid() then
    raise exception 'godown manager cannot certify their own count' using errcode = '23514';
  end if;
  if app_private.unresolved_return_cases(header.id) <> 0 then
    raise exception 'unresolved return quantities remain' using errcode = '23514';
  end if;

  perform app_private.assert_return_matches_outcome(dispatch, header.id);

  select
    coalesce(sum(saleable_cases + damaged_cases + uncertain_cases), 0),
    coalesce(sum(missing_cases), 0)
  into physical_total, missing_total
  from public.stock_delivery_return_lots
  where return_id = header.id;

  if physical_total <> 0 then
    raise exception 'close-all-missing requires no physically returned cases'
      using errcode = '23514';
  end if;
  if missing_total < 1 then
    raise exception 'close-all-missing requires missing cases' using errcode = '23514';
  end if;

  update public.stock_delivery_returns
  set
    status = 'closed_missing',
    closed_at = pg_catalog.clock_timestamp(),
    closed_by = auth.uid(),
    version = header.version + 1
  where id = header.id;

  update public.stock_dispatch_requests
  set
    physical_return_status = 'closed_missing',
    version = dispatch.version + 1
  where id = dispatch.id;

  perform app_private.delivery_return_event(
    header.id, 'closed_missing', header.status, 'closed_missing', header.version + 1,
    pg_catalog.jsonb_build_object('missing_cases', missing_total)
  );

  perform app_private.dispatch_event(
    dispatch.id, 'return_closed_missing', 'exception', 'exception', dispatch.version + 1,
    pg_catalog.jsonb_build_object(
      'return_id', header.id,
      'missing_cases', missing_total
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'close_delivery_return_missing', 'stock_delivery_returns', header.id,
    pg_catalog.jsonb_build_object('missing_cases', missing_total)
  );

  return app_private.delivery_return_payload(header.id);
end;
$$;

create or replace function public.cancel_delivery_return(
  target_return uuid,
  cancel_reason text,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  cleaned_reason text;
begin
  perform app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_permission('deliveries.return_approve');
  header := app_private.lock_delivery_return(target_return, expected_version);
  if header.status not in ('awaiting_handback', 'handed_back', 'counted', 'approved') then
    raise exception 'a posted return cannot be cancelled' using errcode = '23514';
  end if;

  cleaned_reason := nullif(btrim(coalesce(cancel_reason, '')), '');
  if cleaned_reason is null then
    raise exception 'cancellation reason is required' using errcode = '23514';
  end if;

  select * into dispatch from public.stock_dispatch_requests where id = header.dispatch_id;

  update public.stock_delivery_returns
  set
    status = 'cancelled',
    cancelled_at = pg_catalog.clock_timestamp(),
    cancelled_by = auth.uid(),
    cancellation_reason = cleaned_reason,
    version = header.version + 1
  where id = header.id;

  update public.stock_dispatch_requests
  set
    physical_return_status = 'cancelled',
    version = dispatch.version + 1
  where id = dispatch.id;

  perform app_private.delivery_return_event(
    header.id, 'cancelled', header.status, 'cancelled', header.version + 1,
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );
  return app_private.delivery_return_payload(header.id);
end;
$$;

create or replace function public.list_delivery_return_storage_crates(target_return uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.stock_delivery_returns;
begin
  if not (
    app_private.has_permission('deliveries.return_count')
    or app_private.has_permission('deliveries.return_view')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into header
  from public.stock_delivery_returns
  where id = target_return;
  if not found or not app_private.delivery_return_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', crates.id,
      'code', crates.code,
      'name', crates.name,
      'zone_code', zones.code
    ) order by zones.code, crates.code)
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where zones.branch_id = header.branch_id
      and crates.location_role = 'storage'
      and zones.location_role is distinct from 'quarantine'
      and crates.is_active
      and zones.is_active
  ), '[]'::jsonb);
end;
$$;

-- Nested return identity on the dispatch payload. Lot rows stay on get_delivery_return.
create or replace function app_private.dispatch_payload(target_dispatch uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_dispatch_requests;
  selected_order public.orders%rowtype;
  picking public.stock_picking_requests%rowtype;
  shipment public.order_shipments%rowtype;
  selected_vehicle public.vehicles%rowtype;
  return_header public.stock_delivery_returns;
begin
  select * into header
  from public.stock_dispatch_requests
  where id = target_dispatch;

  if not found or not app_private.dispatch_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected_order from public.orders where id = header.order_id;
  select * into picking from public.stock_picking_requests where id = header.picking_request_id;
  shipment := app_private.open_shipment_for_picking(header.picking_request_id);
  if header.vehicle_id is not null then
    select * into selected_vehicle from public.vehicles where vehicles.id = header.vehicle_id;
  end if;
  select * into return_header
  from public.stock_delivery_returns
  where stock_delivery_returns.dispatch_id = header.id;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'request_number', header.request_number,
    'order_id', header.order_id,
    'order_number', selected_order.order_number,
    'order_status', selected_order.status,
    'order_version', selected_order.version,
    'fulfilment_status', selected_order.fulfilment_status,
    'shop_id', selected_order.shop_id,
    'branch_id', header.branch_id,
    'picking_request_id', header.picking_request_id,
    'picking_request_number', picking.request_number,
    'picking_status', picking.status,
    'picking_version', picking.version,
    'delivery_note_id', header.delivery_note_id,
    'delivery_note_number', (
      select delivery_notes.delivery_note_number
      from public.delivery_notes
      where delivery_notes.id = header.delivery_note_id
    ),
    'delivery_note_status', (
      select delivery_notes.status
      from public.delivery_notes
      where delivery_notes.id = header.delivery_note_id
    ),
    'shipment_id', shipment.id,
    'shipment_number', shipment.shipment_number,
    'shipment_status', shipment.status,
    'shipment_revision', shipment.revision,
    'backorder_id', shipment.backorder_id,
    'status', header.status,
    'version', header.version,
    'stock_consumed', header.stock_consumed,
    'posted_transaction_id', header.posted_transaction_id,
    'physical_return_status', header.physical_return_status,
    'return_required', header.return_required,
    'return_id', return_header.id,
    'return_number', return_header.return_number,
    'return_status', return_header.status,
    'return_version', return_header.version,
    'delivery_outcome', header.delivery_outcome,
    'proof_reference', header.proof_reference,
    'attempted_at', header.attempted_at,
    'assigned_to', header.assigned_to,
    'assigned_to_name', (
      select profiles.full_name from public.profiles where profiles.id = header.assigned_to
    ),
    'assigned_at', header.assigned_at,
    'vehicle_id', header.vehicle_id,
    'vehicle_registration', selected_vehicle.registration_number,
    'vehicle_name', selected_vehicle.display_name,
    'vehicle_type', selected_vehicle.vehicle_type
  ) || pg_catalog.jsonb_build_object(
    'dispatched_by', header.dispatched_by,
    'dispatched_at', header.dispatched_at,
    'in_transit_at', header.in_transit_at,
    'delivered_at', header.delivered_at,
    'exception_at', header.exception_at,
    'exception_reason', header.exception_reason,
    'recipient_name', header.recipient_name,
    'acknowledgement_notes', header.acknowledgement_notes,
    'acknowledged_at', header.acknowledged_at,
    'cancelled_at', header.cancelled_at,
    'cancellation_reason', header.cancellation_reason,
    'created_by', header.created_by,
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'cutover', pg_catalog.jsonb_build_object(
      'dual_write_enabled', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ),
      'aggregate_only_blocked', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.aggregate_only_blocked' and value = 'true'::jsonb
      )
    ),
    'total_cases', coalesce((
      select sum(q.dispatched_cases)::integer
      from app_private.dispatch_line_quantities(header) q
    ), 0),
    'reservations', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_reservations.id,
        'order_line_id', stock_reservations.order_line_id,
        'product_id', stock_reservations.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'crate_id', stock_reservations.crate_id,
        'crate_code', crates.code,
        'zone_code', zones.code,
        'lot_id', stock_reservations.lot_id,
        'manufacturer_lot_code', stock_lots.manufacturer_lot_code,
        'expiry_date', stock_lots.expiry_date,
        'received_on', stock_lots.received_on,
        'lot_status', stock_lots.status,
        'reserved_cases', stock_reservations.reserved_cases,
        'picked_cases', stock_reservations.picked_cases,
        'status', stock_reservations.status
      ) order by products.sku, crates.code, stock_lots.id)
      from public.stock_reservations
      join public.products on products.id = stock_reservations.product_id
      join public.crates on crates.id = stock_reservations.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.stock_lots on stock_lots.id = stock_reservations.lot_id
      where stock_reservations.picking_request_id = header.picking_request_id
        and stock_reservations.status in ('active', 'consumed')
    ), '[]'::jsonb),
    'delivery_lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'order_line_id', qty.order_line_id,
        'product_id', qty.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'dispatched_cases', qty.dispatched_cases,
        'delivered_cases', stock_dispatch_outcome_lines.delivered_cases,
        'undelivered_cases', stock_dispatch_outcome_lines.undelivered_cases
      ) order by products.sku, qty.order_line_id)
      from app_private.dispatch_line_quantities(header) qty
      join public.products on products.id = qty.product_id
      left join public.stock_dispatch_outcome_lines
        on stock_dispatch_outcome_lines.dispatch_id = header.id
       and stock_dispatch_outcome_lines.order_line_id = qty.order_line_id
    ), '[]'::jsonb),
    'assignments', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_dispatch_assignments.id,
        'assignee', stock_dispatch_assignments.assignee,
        'assignee_name', profiles.full_name,
        'vehicle_id', stock_dispatch_assignments.vehicle_id,
        'assigned_by', stock_dispatch_assignments.assigned_by,
        'assigned_at', stock_dispatch_assignments.assigned_at,
        'unassigned_at', stock_dispatch_assignments.unassigned_at,
        'reason', stock_dispatch_assignments.reason
      ) order by stock_dispatch_assignments.assigned_at, stock_dispatch_assignments.id)
      from public.stock_dispatch_assignments
      join public.profiles on profiles.id = stock_dispatch_assignments.assignee
      where stock_dispatch_assignments.dispatch_id = header.id
    ), '[]'::jsonb),
    'attempts', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_dispatch_delivery_attempts.id,
        'attempt_number', stock_dispatch_delivery_attempts.attempt_number,
        'outcome', stock_dispatch_delivery_attempts.outcome,
        'actor_id', stock_dispatch_delivery_attempts.actor_id,
        'attempted_at', stock_dispatch_delivery_attempts.attempted_at,
        'reason', stock_dispatch_delivery_attempts.reason
      ) order by stock_dispatch_delivery_attempts.attempt_number, stock_dispatch_delivery_attempts.id)
      from public.stock_dispatch_delivery_attempts
      where stock_dispatch_delivery_attempts.dispatch_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_dispatch_events.id,
        'event_type', stock_dispatch_events.event_type,
        'actor_id', stock_dispatch_events.actor_id,
        'from_status', stock_dispatch_events.from_status,
        'to_status', stock_dispatch_events.to_status,
        'dispatch_version', stock_dispatch_events.dispatch_version,
        'payload', stock_dispatch_events.payload,
        'created_at', stock_dispatch_events.created_at
      ) order by stock_dispatch_events.created_at, stock_dispatch_events.id)
      from public.stock_dispatch_events
      where stock_dispatch_events.dispatch_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_delivery_return(uuid)
  from public, anon, service_role;
revoke all on function public.declare_delivery_return_handback(uuid, integer, text, integer, text)
  from public, anon, service_role;
revoke all on function public.count_delivery_return(uuid, jsonb, integer, text)
  from public, anon, service_role;
revoke all on function public.approve_delivery_return(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.return_delivery_return_to_count(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.post_delivery_return(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.close_delivery_return_missing(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.cancel_delivery_return(uuid, text, integer, text)
  from public, anon, service_role;
revoke all on function public.list_delivery_return_storage_crates(uuid)
  from public, anon, service_role;

grant execute on function public.get_delivery_return(uuid) to authenticated;
grant execute on function public.declare_delivery_return_handback(uuid, integer, text, integer, text)
  to authenticated;
grant execute on function public.count_delivery_return(uuid, jsonb, integer, text)
  to authenticated;
grant execute on function public.approve_delivery_return(uuid, integer, text)
  to authenticated;
grant execute on function public.return_delivery_return_to_count(uuid, integer, text)
  to authenticated;
grant execute on function public.post_delivery_return(uuid, integer, text)
  to authenticated;
grant execute on function public.close_delivery_return_missing(uuid, integer, text)
  to authenticated;
grant execute on function public.cancel_delivery_return(uuid, text, integer, text)
  to authenticated;
grant execute on function public.list_delivery_return_storage_crates(uuid)
  to authenticated;

comment on function public.post_delivery_return(uuid, integer, text) is
  'M7.4B. Sole DELIVERY_RETURN stock-credit writer. Original lot identity only. Fails closed when dual-write is off. Does not reverse DISPATCH.';
comment on function public.count_delivery_return(uuid, jsonb, integer, text) is
  'M7.4B. Store Keeper lot/condition/crate count. Invalidates GM approval. Does not post stock.';
comment on function public.approve_delivery_return(uuid, integer, text) is
  'M7.4B. GM approval of a different Store Keeper count. Does not post stock.';
comment on function public.close_delivery_return_missing(uuid, integer, text) is
  'M7.4B. Close a counted return with no physical cases. Does not credit stock.';

notify pgrst, 'reload schema';




