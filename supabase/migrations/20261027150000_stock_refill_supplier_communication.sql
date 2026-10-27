-- M6.3 REF-05 / REF-06. Manual supplier communication and dispatch tracking.
-- Approval status stays draft/submitted/held/approved/rejected.
-- Zero stock. Does not call verify_stock_receipt or add receipt FKs (REF-07 / M6.4).
-- Does not flip damage.stock_hold_ready or lot cutover flags.

alter table public.stock_refill_request_events
  drop constraint if exists stock_refill_request_events_action_check;

alter table public.stock_refill_request_events
  add constraint stock_refill_request_events_action_check check (
    action in (
      'created',
      'updated',
      'submitted',
      'held',
      'resubmitted',
      'approved',
      'rejected',
      'sent_to_supplier',
      'supplier_acknowledged',
      'supplier_declined',
      'supplier_acknowledgement_corrected',
      'supplier_dispatch_recorded',
      'supplier_dispatch_corrected'
    )
  );

create table if not exists public.stock_refill_supplier_communications (
  id uuid primary key default gen_random_uuid(),
  refill_request_id uuid not null
    references public.stock_refill_requests (id) on delete restrict,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  destination_godown_id uuid not null references public.branches (id) on delete restrict,
  channel text not null,
  communicated_at timestamptz not null,
  external_reference text,
  notes text,
  recorded_by uuid not null references public.profiles (id) on delete restrict,
  recorded_at timestamptz not null default pg_catalog.clock_timestamp(),
  acknowledgement_status text not null default 'pending',
  acknowledgement_at timestamptz,
  acknowledgement_reference text,
  acknowledgement_notes text,
  acknowledgement_reason text,
  acknowledged_by uuid references public.profiles (id) on delete restrict,
  acknowledged_recorded_at timestamptz,
  send_idempotency_key text not null,
  send_fingerprint text not null,
  acknowledgement_idempotency_key text,
  acknowledgement_fingerprint text,
  constraint stock_refill_supplier_communications_request_key
    unique (refill_request_id),
  constraint stock_refill_supplier_communications_send_key
    unique (send_idempotency_key),
  constraint stock_refill_supplier_communications_channel_check
    check (channel in ('phone', 'whatsapp', 'email', 'other')),
  constraint stock_refill_supplier_communications_ack_check
    check (acknowledgement_status in ('pending', 'acknowledged', 'declined')),
  constraint stock_refill_supplier_communications_ref_len check (
    external_reference is null
    or (
      char_length(btrim(external_reference)) between 1 and 120
      and external_reference = btrim(external_reference)
    )
  ),
  constraint stock_refill_supplier_communications_notes_len check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  ),
  constraint stock_refill_supplier_communications_ack_ref_len check (
    acknowledgement_reference is null
    or (
      char_length(btrim(acknowledgement_reference)) between 1 and 120
      and acknowledgement_reference = btrim(acknowledgement_reference)
    )
  ),
  constraint stock_refill_supplier_communications_ack_notes_len check (
    acknowledgement_notes is null
    or (
      char_length(btrim(acknowledgement_notes)) between 1 and 500
      and acknowledgement_notes = btrim(acknowledgement_notes)
    )
  ),
  constraint stock_refill_supplier_communications_ack_reason_len check (
    acknowledgement_reason is null
    or (
      char_length(btrim(acknowledgement_reason)) between 1 and 500
      and acknowledgement_reason = btrim(acknowledgement_reason)
    )
  ),
  constraint stock_refill_supplier_communications_ack_shape check (
    (
      acknowledgement_status = 'pending'
      and acknowledged_by is null
      and acknowledged_recorded_at is null
      and acknowledgement_at is null
      and acknowledgement_reason is null
    )
    or (
      acknowledgement_status = 'acknowledged'
      and acknowledged_by is not null
      and acknowledged_recorded_at is not null
      and acknowledgement_at is not null
      and acknowledgement_reason is null
    )
    or (
      acknowledgement_status = 'declined'
      and acknowledged_by is not null
      and acknowledged_recorded_at is not null
      and acknowledgement_at is not null
      and acknowledgement_reason is not null
    )
  )
);

comment on table public.stock_refill_supplier_communications is
  'M6.3 manual REF-05 send plus supplier acknowledgement. Attestation only. Send fields are immutable. Zero stock.';

create table if not exists public.stock_refill_supplier_dispatches (
  id uuid primary key default gen_random_uuid(),
  refill_request_id uuid not null
    references public.stock_refill_requests (id) on delete restrict,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  destination_godown_id uuid not null references public.branches (id) on delete restrict,
  supplier_dispatch_reference text,
  dispatched_on date not null,
  expected_arrival_on date,
  transport_provider text,
  vehicle_reference text,
  tracking_reference text,
  notes text,
  recorded_by uuid not null references public.profiles (id) on delete restrict,
  recorded_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_by uuid references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  idempotency_key text not null,
  fingerprint text not null,
  constraint stock_refill_supplier_dispatches_request_key
    unique (refill_request_id),
  constraint stock_refill_supplier_dispatches_idempotency_key
    unique (idempotency_key),
  constraint stock_refill_supplier_dispatches_arrival_check
    check (
      expected_arrival_on is null
      or expected_arrival_on >= dispatched_on
    ),
  constraint stock_refill_supplier_dispatches_ref_len check (
    supplier_dispatch_reference is null
    or (
      char_length(btrim(supplier_dispatch_reference)) between 1 and 120
      and supplier_dispatch_reference = btrim(supplier_dispatch_reference)
    )
  ),
  constraint stock_refill_supplier_dispatches_transport_len check (
    transport_provider is null
    or (
      char_length(btrim(transport_provider)) between 1 and 120
      and transport_provider = btrim(transport_provider)
    )
  ),
  constraint stock_refill_supplier_dispatches_vehicle_len check (
    vehicle_reference is null
    or (
      char_length(btrim(vehicle_reference)) between 1 and 120
      and vehicle_reference = btrim(vehicle_reference)
    )
  ),
  constraint stock_refill_supplier_dispatches_tracking_len check (
    tracking_reference is null
    or (
      char_length(btrim(tracking_reference)) between 1 and 120
      and tracking_reference = btrim(tracking_reference)
    )
  ),
  constraint stock_refill_supplier_dispatches_notes_len check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  )
);

comment on table public.stock_refill_supplier_dispatches is
  'M6.3 informational REF-06 supplier dispatch. Not a receipt, reservation, or in-transit balance.';

create index if not exists stock_refill_supplier_communications_godown_idx
  on public.stock_refill_supplier_communications (destination_godown_id, recorded_at desc);

create index if not exists stock_refill_supplier_dispatches_godown_idx
  on public.stock_refill_supplier_dispatches (destination_godown_id, dispatched_on desc);

drop trigger if exists stock_refill_supplier_dispatches_set_updated_at
  on public.stock_refill_supplier_dispatches;
create trigger stock_refill_supplier_dispatches_set_updated_at
  before update on public.stock_refill_supplier_dispatches
  for each row execute function app_private.set_updated_at();

drop trigger if exists stock_refill_supplier_communications_write_guard
  on public.stock_refill_supplier_communications;
create trigger stock_refill_supplier_communications_write_guard
  before insert or update or delete on public.stock_refill_supplier_communications
  for each row execute function app_private.guard_refill_write();

drop trigger if exists stock_refill_supplier_dispatches_write_guard
  on public.stock_refill_supplier_dispatches;
create trigger stock_refill_supplier_dispatches_write_guard
  before insert or update or delete on public.stock_refill_supplier_dispatches
  for each row execute function app_private.guard_refill_write();

alter table public.stock_refill_supplier_communications enable row level security;
alter table public.stock_refill_supplier_communications force row level security;
alter table public.stock_refill_supplier_dispatches enable row level security;
alter table public.stock_refill_supplier_dispatches force row level security;

revoke all on public.stock_refill_supplier_communications
  from public, anon, authenticated, service_role;
revoke all on public.stock_refill_supplier_dispatches
  from public, anon, authenticated, service_role;
grant select on public.stock_refill_supplier_communications to authenticated;
grant select on public.stock_refill_supplier_dispatches to authenticated;

drop policy if exists stock_refill_supplier_communications_select_authorized
  on public.stock_refill_supplier_communications;
create policy stock_refill_supplier_communications_select_authorized
  on public.stock_refill_supplier_communications
  for select
  to authenticated
  using (app_private.can_view_refill_at_godown(destination_godown_id));

drop policy if exists stock_refill_supplier_dispatches_select_authorized
  on public.stock_refill_supplier_dispatches;
create policy stock_refill_supplier_dispatches_select_authorized
  on public.stock_refill_supplier_dispatches
  for select
  to authenticated
  using (app_private.can_view_refill_at_godown(destination_godown_id));

create or replace function app_private.clean_refill_short_text(
  raw_value text,
  required boolean
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(raw_value, '')), '');
begin
  if required and cleaned is null then
    raise exception 'a reference is required' using errcode = '23514';
  end if;
  if cleaned is not null and pg_catalog.char_length(cleaned) > 120 then
    raise exception 'reference is too long' using errcode = '23514';
  end if;
  return cleaned;
end;
$$;

revoke all on function app_private.clean_refill_short_text(text, boolean)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_refill_user_datetime(
  supplied timestamptz,
  label text
)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
begin
  if supplied is null then
    raise exception '% is required', label using errcode = '23514';
  end if;
  -- User-attested event time. Reject far-future and pre-2000 values.
  if supplied > pg_catalog.clock_timestamp() + interval '1 day'
    or supplied < timestamptz '2000-01-01+00'
  then
    raise exception '% is not a reasonable date' , label using errcode = '23514';
  end if;
  return supplied;
end;
$$;

revoke all on function app_private.assert_refill_user_datetime(timestamptz, text)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_refill_dispatch_dates(
  dispatched_on date,
  expected_arrival_on date
)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if dispatched_on is null then
    raise exception 'supplier dispatch date is required' using errcode = '23514';
  end if;
  if dispatched_on > ((pg_catalog.clock_timestamp() at time zone 'utc')::date + 7)
    or dispatched_on < date '2000-01-01'
  then
    raise exception 'supplier dispatch date is not reasonable' using errcode = '23514';
  end if;
  if expected_arrival_on is not null then
    if expected_arrival_on < dispatched_on then
      raise exception 'expected arrival cannot be before dispatch' using errcode = '23514';
    end if;
    if expected_arrival_on > dispatched_on + 730 then
      raise exception 'expected arrival is not reasonable' using errcode = '23514';
    end if;
  end if;
end;
$$;

revoke all on function app_private.assert_refill_dispatch_dates(date, date)
  from public, anon, authenticated, service_role;

create or replace function app_private.refill_send_fingerprint(
  target_request uuid,
  communication_channel text,
  communicated_at timestamptz,
  external_reference text,
  cleaned_notes text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select target_request::text
    || '|' || communication_channel
    || '|' || to_char(communicated_at at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS.US')
    || '|' || coalesce(external_reference, '')
    || '|' || coalesce(cleaned_notes, '');
$$;

revoke all on function app_private.refill_send_fingerprint(uuid, text, timestamptz, text, text)
  from public, anon, authenticated, service_role;

create or replace function app_private.refill_acknowledgement_fingerprint(
  target_request uuid,
  acknowledgement_status text,
  response_at timestamptz,
  acknowledgement_reference text,
  cleaned_notes text,
  decline_reason text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select target_request::text
    || '|' || acknowledgement_status
    || '|' || to_char(response_at at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS.US')
    || '|' || coalesce(acknowledgement_reference, '')
    || '|' || coalesce(cleaned_notes, '')
    || '|' || coalesce(decline_reason, '');
$$;

revoke all on function app_private.refill_acknowledgement_fingerprint(
  uuid, text, timestamptz, text, text, text
) from public, anon, authenticated, service_role;

create or replace function app_private.refill_dispatch_fingerprint(
  target_request uuid,
  dispatched_on date,
  expected_arrival_on date,
  supplier_dispatch_reference text,
  transport_provider text,
  vehicle_reference text,
  tracking_reference text,
  cleaned_notes text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select target_request::text
    || '|' || dispatched_on::text
    || '|' || coalesce(expected_arrival_on::text, '')
    || '|' || coalesce(supplier_dispatch_reference, '')
    || '|' || coalesce(transport_provider, '')
    || '|' || coalesce(vehicle_reference, '')
    || '|' || coalesce(tracking_reference, '')
    || '|' || coalesce(cleaned_notes, '');
$$;

revoke all on function app_private.refill_dispatch_fingerprint(
  uuid, date, date, text, text, text, text, text
) from public, anon, authenticated, service_role;

create or replace function app_private.assert_accounts_refill_action(
  selected public.stock_refill_requests,
  require_active_godown boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('refill.request');

  if not app_private.can_view_refill_at_godown(selected.destination_godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if require_active_godown then
    perform app_private.assert_operational_active_branch(selected.destination_godown_id);
  end if;
end;
$$;

revoke all on function app_private.assert_accounts_refill_action(
  public.stock_refill_requests, boolean
) from public, anon, authenticated, service_role;

create or replace function app_private.completed_refill_send_payload(
  existing public.stock_refill_supplier_communications,
  target_request uuid,
  fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Authorize before fingerprint compare so a foreign key cannot leak payload
  -- or distinguish a conflicting send from a missing one.
  if existing.refill_request_id is distinct from target_request
    or existing.recorded_by is distinct from auth.uid()
    or not app_private.has_permission('refill.request')
    or not app_private.can_view_refill_at_godown(existing.destination_godown_id)
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if existing.send_fingerprint is distinct from fingerprint then
    raise exception 'idempotency key already used for a different request'
      using errcode = '23505';
  end if;

  return app_private.stock_refill_request_payload(existing.refill_request_id);
end;
$$;

revoke all on function app_private.completed_refill_send_payload(
  public.stock_refill_supplier_communications, uuid, text
) from public, anon, authenticated, service_role;

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

  return pg_catalog.jsonb_build_object(
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
end;
$$;

create or replace function public.list_stock_refill_requests(
  page integer default 1,
  page_size integer default 25,
  status_filter text default null,
  target_godown uuid default null,
  target_supplier uuid default null,
  search_text text default null
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

  select count(*)
  into total_count
  from public.stock_refill_requests
  join public.suppliers on suppliers.id = stock_refill_requests.supplier_id
  join public.branches on branches.id = stock_refill_requests.destination_godown_id
  where app_private.can_view_refill_at_godown(stock_refill_requests.destination_godown_id)
    and (status_filter is null or stock_refill_requests.status = status_filter)
    and (target_godown is null or stock_refill_requests.destination_godown_id = target_godown)
    and (target_supplier is null or stock_refill_requests.supplier_id = target_supplier)
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
          'total_requested_cases', coalesce((
            select sum(stock_refill_request_lines.requested_cases)
            from public.stock_refill_request_lines
            where stock_refill_request_lines.refill_request_id = stock_refill_requests.id
          ), 0),
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
        where app_private.can_view_refill_at_godown(stock_refill_requests.destination_godown_id)
          and (status_filter is null or stock_refill_requests.status = status_filter)
          and (target_godown is null or stock_refill_requests.destination_godown_id = target_godown)
          and (target_supplier is null or stock_refill_requests.supplier_id = target_supplier)
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

create or replace function public.record_stock_refill_supplier_communication(
  target_request uuid,
  expected_version integer,
  communication_channel text,
  communicated_at timestamptz,
  idempotency_key text,
  external_reference text default null,
  notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  existing public.stock_refill_supplier_communications;
  cleaned_key text;
  cleaned_channel text;
  cleaned_ref text;
  cleaned_notes text;
  event_time timestamptz;
  fingerprint text;
  next_version integer;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_channel := pg_catalog.lower(pg_catalog.btrim(coalesce(communication_channel, '')));
  if cleaned_channel not in ('phone', 'whatsapp', 'email', 'other') then
    raise exception 'communication channel is invalid' using errcode = '23514';
  end if;

  event_time := app_private.assert_refill_user_datetime(communicated_at, 'communication time');
  cleaned_ref := app_private.clean_refill_short_text(external_reference, false);
  cleaned_notes := app_private.clean_refill_notes(notes, false);
  fingerprint := app_private.refill_send_fingerprint(
    target_request, cleaned_channel, event_time, cleaned_ref, cleaned_notes
  );

  -- Header first, then same-key advisory lock. No stock grains.
  selected := app_private.lock_stock_refill_request(target_request);
  perform pg_catalog.pg_advisory_xact_lock(88106305, pg_catalog.hashtext(cleaned_key));

  select *
  into existing
  from public.stock_refill_supplier_communications
  where stock_refill_supplier_communications.send_idempotency_key = cleaned_key;

  if found then
    return app_private.completed_refill_send_payload(existing, target_request, fingerprint);
  end if;

  perform app_private.assert_accounts_refill_action(selected, true);
  perform app_private.assert_refill_version(selected, expected_version);

  if selected.status is distinct from 'approved' then
    raise exception 'refill request is not approved' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.stock_refill_supplier_communications
    where stock_refill_supplier_communications.refill_request_id = selected.id
  ) then
    raise exception 'supplier communication already recorded' using errcode = '23505';
  end if;

  next_version := selected.version + 1;

  begin
    insert into public.stock_refill_supplier_communications (
      refill_request_id, supplier_id, destination_godown_id, channel,
      communicated_at, external_reference, notes, recorded_by, recorded_at,
      acknowledgement_status, send_idempotency_key, send_fingerprint
    )
    values (
      selected.id, selected.supplier_id, selected.destination_godown_id, cleaned_channel,
      event_time, cleaned_ref, cleaned_notes, auth.uid(), pg_catalog.clock_timestamp(),
      'pending', cleaned_key, fingerprint
    );
  exception
    when unique_violation then
      select *
      into existing
      from public.stock_refill_supplier_communications
      where stock_refill_supplier_communications.send_idempotency_key = cleaned_key;

      if not found then
        raise;
      end if;

      return app_private.completed_refill_send_payload(existing, target_request, fingerprint);
  end;

  update public.stock_refill_requests
  set
    version = next_version,
    updated_by = auth.uid()
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id,
    'sent_to_supplier',
    selected.status,
    selected.status,
    cleaned_notes,
    next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

create or replace function public.record_stock_refill_supplier_acknowledgement(
  target_request uuid,
  expected_version integer,
  acknowledgement_status text,
  response_at timestamptz,
  idempotency_key text,
  acknowledgement_reference text default null,
  notes text default null,
  decline_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  communication public.stock_refill_supplier_communications;
  cleaned_key text;
  cleaned_status text;
  cleaned_ref text;
  cleaned_notes text;
  cleaned_reason text;
  event_time timestamptz;
  fingerprint text;
  next_version integer;
  event_name text;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_status := pg_catalog.lower(pg_catalog.btrim(coalesce(acknowledgement_status, '')));
  if cleaned_status not in ('acknowledged', 'declined') then
    raise exception 'acknowledgement status is invalid' using errcode = '23514';
  end if;

  event_time := app_private.assert_refill_user_datetime(response_at, 'supplier response time');
  cleaned_ref := app_private.clean_refill_short_text(acknowledgement_reference, false);
  cleaned_notes := app_private.clean_refill_notes(notes, false);
  cleaned_reason := app_private.clean_refill_notes(decline_reason, cleaned_status = 'declined');
  if cleaned_status = 'acknowledged' then
    cleaned_reason := null;
  end if;

  fingerprint := app_private.refill_acknowledgement_fingerprint(
    target_request, cleaned_status, event_time, cleaned_ref, cleaned_notes, cleaned_reason
  );

  selected := app_private.lock_stock_refill_request(target_request);

  select *
  into communication
  from public.stock_refill_supplier_communications
  where stock_refill_supplier_communications.refill_request_id = selected.id
  for update;

  if communication.id is not null
    and communication.acknowledgement_idempotency_key is not distinct from cleaned_key
  then
    if communication.acknowledged_by is distinct from auth.uid()
      or not app_private.has_permission('refill.request')
      or not app_private.can_view_refill_at_godown(selected.destination_godown_id)
    then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if communication.acknowledgement_fingerprint is distinct from fingerprint then
      raise exception 'idempotency key already used for a different request'
        using errcode = '23505';
    end if;
    return app_private.stock_refill_request_payload(selected.id);
  end if;

  perform app_private.assert_accounts_refill_action(selected, true);
  perform app_private.assert_refill_version(selected, expected_version);

  if selected.status is distinct from 'approved' or communication.id is null then
    raise exception 'supplier communication has not been recorded' using errcode = '42501';
  end if;

  next_version := selected.version + 1;
  event_name := case
    when communication.acknowledgement_status = 'pending' and cleaned_status = 'acknowledged'
      then 'supplier_acknowledged'
    when communication.acknowledgement_status = 'pending' and cleaned_status = 'declined'
      then 'supplier_declined'
    else 'supplier_acknowledgement_corrected'
  end;

  update public.stock_refill_supplier_communications
  set
    acknowledgement_status = cleaned_status,
    acknowledgement_at = event_time,
    acknowledgement_reference = cleaned_ref,
    acknowledgement_notes = cleaned_notes,
    acknowledgement_reason = cleaned_reason,
    acknowledged_by = auth.uid(),
    acknowledged_recorded_at = pg_catalog.clock_timestamp(),
    acknowledgement_idempotency_key = cleaned_key,
    acknowledgement_fingerprint = fingerprint
  where stock_refill_supplier_communications.id = communication.id;

  update public.stock_refill_requests
  set
    version = next_version,
    updated_by = auth.uid()
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id,
    event_name,
    selected.status,
    selected.status,
    coalesce(cleaned_reason, cleaned_notes),
    next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

create or replace function public.record_stock_refill_supplier_dispatch(
  target_request uuid,
  expected_version integer,
  dispatched_on date,
  idempotency_key text,
  supplier_dispatch_reference text default null,
  expected_arrival_on date default null,
  transport_provider text default null,
  vehicle_reference text default null,
  tracking_reference text default null,
  notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  communication public.stock_refill_supplier_communications;
  existing public.stock_refill_supplier_dispatches;
  cleaned_key text;
  cleaned_ref text;
  cleaned_transport text;
  cleaned_vehicle text;
  cleaned_tracking text;
  cleaned_notes text;
  dispatch_fp text;
  next_version integer;
  event_name text;
  -- Locals avoid UPDATE SET column = parameter/variable shadowing.
  dispatch_date date := dispatched_on;
  arrival_date date := expected_arrival_on;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  perform app_private.assert_refill_dispatch_dates(dispatch_date, arrival_date);
  cleaned_ref := app_private.clean_refill_short_text(supplier_dispatch_reference, false);
  cleaned_transport := app_private.clean_refill_short_text(transport_provider, false);
  cleaned_vehicle := app_private.clean_refill_short_text(vehicle_reference, false);
  cleaned_tracking := app_private.clean_refill_short_text(tracking_reference, false);
  cleaned_notes := app_private.clean_refill_notes(notes, false);
  dispatch_fp := app_private.refill_dispatch_fingerprint(
    target_request,
    dispatch_date,
    arrival_date,
    cleaned_ref,
    cleaned_transport,
    cleaned_vehicle,
    cleaned_tracking,
    cleaned_notes
  );

  selected := app_private.lock_stock_refill_request(target_request);

  select *
  into communication
  from public.stock_refill_supplier_communications
  where stock_refill_supplier_communications.refill_request_id = selected.id
  for update;

  select *
  into existing
  from public.stock_refill_supplier_dispatches
  where stock_refill_supplier_dispatches.refill_request_id = selected.id
  for update;

  if existing.id is not null
    and existing.idempotency_key is not distinct from cleaned_key
  then
    if (
      existing.recorded_by is distinct from auth.uid()
      and existing.updated_by is distinct from auth.uid()
    )
      or not app_private.has_permission('refill.request')
      or not app_private.can_view_refill_at_godown(selected.destination_godown_id)
    then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if existing.fingerprint is distinct from dispatch_fp then
      raise exception 'idempotency key already used for a different request'
        using errcode = '23505';
    end if;
    return app_private.stock_refill_request_payload(selected.id);
  end if;

  perform app_private.assert_accounts_refill_action(selected, true);
  perform app_private.assert_refill_version(selected, expected_version);

  if selected.status is distinct from 'approved' or communication.id is null then
    raise exception 'supplier communication has not been recorded' using errcode = '42501';
  end if;

  if communication.acknowledgement_status = 'declined' then
    raise exception 'supplier declined this request' using errcode = '42501';
  end if;

  next_version := selected.version + 1;

  if existing.id is null then
    event_name := 'supplier_dispatch_recorded';
    insert into public.stock_refill_supplier_dispatches (
      refill_request_id, supplier_id, destination_godown_id,
      supplier_dispatch_reference, dispatched_on, expected_arrival_on,
      transport_provider, vehicle_reference, tracking_reference, notes,
      recorded_by, recorded_at, updated_by, idempotency_key, fingerprint
    )
    values (
      selected.id, selected.supplier_id, selected.destination_godown_id,
      cleaned_ref, dispatch_date, arrival_date,
      cleaned_transport, cleaned_vehicle, cleaned_tracking, cleaned_notes,
      auth.uid(), pg_catalog.clock_timestamp(), auth.uid(), cleaned_key, dispatch_fp
    );
  else
    -- Correction updates the current dispatch row. The original recorded event stays.
    event_name := 'supplier_dispatch_corrected';
    update public.stock_refill_supplier_dispatches
    set
      supplier_dispatch_reference = cleaned_ref,
      dispatched_on = dispatch_date,
      expected_arrival_on = arrival_date,
      transport_provider = cleaned_transport,
      vehicle_reference = cleaned_vehicle,
      tracking_reference = cleaned_tracking,
      notes = cleaned_notes,
      updated_by = auth.uid(),
      idempotency_key = cleaned_key,
      fingerprint = dispatch_fp
    where stock_refill_supplier_dispatches.id = existing.id;
  end if;

  update public.stock_refill_requests
  set
    version = next_version,
    updated_by = auth.uid()
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id,
    event_name,
    selected.status,
    selected.status,
    cleaned_notes,
    next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

revoke all on function public.record_stock_refill_supplier_communication(
  uuid, integer, text, timestamptz, text, text, text
) from public, anon, service_role;
revoke all on function public.record_stock_refill_supplier_acknowledgement(
  uuid, integer, text, timestamptz, text, text, text, text
) from public, anon, service_role;
revoke all on function public.record_stock_refill_supplier_dispatch(
  uuid, integer, date, text, text, date, text, text, text, text
) from public, anon, service_role;

grant execute on function public.record_stock_refill_supplier_communication(
  uuid, integer, text, timestamptz, text, text, text
) to authenticated;
grant execute on function public.record_stock_refill_supplier_acknowledgement(
  uuid, integer, text, timestamptz, text, text, text, text
) to authenticated;
grant execute on function public.record_stock_refill_supplier_dispatch(
  uuid, integer, date, text, text, date, text, text, text, text
) to authenticated;

comment on function public.record_stock_refill_supplier_communication(
  uuid, integer, text, timestamptz, text, text, text
) is
  'M6.3 REF-05. Accounts attests an approved request was sent externally. Not a message send. Zero stock.';
comment on function public.record_stock_refill_supplier_acknowledgement(
  uuid, integer, text, timestamptz, text, text, text, text
) is
  'M6.3. Manual supplier acknowledgement. Does not change Admin approval. Zero stock.';
comment on function public.record_stock_refill_supplier_dispatch(
  uuid, integer, date, text, text, date, text, text, text, text
) is
  'M6.3 REF-06. Informational supplier dispatch. Not a receipt or in-transit stock.';
