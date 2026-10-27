-- M6.2 Stock refill request lifecycle (REF-01–REF-04).
-- Local only. Supplier replenishment request + Admin decision.
-- Does not post stock, create holds, pick, dispatch, or send supplier orders.
-- Does not flip damage.stock_hold_ready or lot cutover flags.

create sequence if not exists public.stock_refill_request_seq as bigint;

revoke all on sequence public.stock_refill_request_seq
  from public, anon, authenticated, service_role;

create table if not exists public.stock_refill_requests (
  id uuid primary key default gen_random_uuid(),
  request_number text not null,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  destination_godown_id uuid not null references public.branches (id) on delete restrict,
  status text not null default 'draft',
  notes text,
  version integer not null default 1,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_by uuid references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  submitted_by uuid references public.profiles (id) on delete restrict,
  submitted_at timestamptz,
  held_by uuid references public.profiles (id) on delete restrict,
  held_at timestamptz,
  hold_reason text,
  decided_by uuid references public.profiles (id) on delete restrict,
  decided_at timestamptz,
  decision_reason text,
  idempotency_key text not null,
  request_fingerprint text not null,
  submit_idempotency_key text,
  decision_idempotency_key text,
  constraint stock_refill_requests_number_key unique (request_number),
  constraint stock_refill_requests_idempotency_key unique (idempotency_key),
  constraint stock_refill_requests_status_check check (
    status in ('draft', 'submitted', 'held', 'approved', 'rejected')
  ),
  constraint stock_refill_requests_version_check check (version >= 1),
  constraint stock_refill_requests_notes_len check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  ),
  constraint stock_refill_requests_hold_reason_len check (
    hold_reason is null
    or (
      char_length(btrim(hold_reason)) between 1 and 500
      and hold_reason = btrim(hold_reason)
    )
  ),
  constraint stock_refill_requests_decision_reason_len check (
    decision_reason is null
    or (
      char_length(btrim(decision_reason)) between 1 and 500
      and decision_reason = btrim(decision_reason)
    )
  ),
  constraint stock_refill_requests_submitted_shape check (
    status in ('draft')
    or (submitted_by is not null and submitted_at is not null)
  ),
  constraint stock_refill_requests_held_shape check (
    status <> 'held'
    or (
      held_by is not null
      and held_at is not null
      and hold_reason is not null
    )
  ),
  constraint stock_refill_requests_decided_shape check (
    status not in ('approved', 'rejected')
    or (
      decided_by is not null
      and decided_at is not null
    )
  )
);

comment on table public.stock_refill_requests is
  'M6.2 FMCG refill request header. Approval is not a stock receipt. No ledger writes.';

create table if not exists public.stock_refill_request_lines (
  id uuid primary key default gen_random_uuid(),
  refill_request_id uuid not null
    references public.stock_refill_requests (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  requested_cases integer not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_refill_request_lines_cases_check
    check (requested_cases between 1 and 1000000),
  constraint stock_refill_request_lines_product_unique
    unique (refill_request_id, product_id)
);

comment on table public.stock_refill_request_lines is
  'M6.2 refill SKU lines. Whole carton cases. Products must match the header supplier.';

create table if not exists public.stock_refill_request_events (
  id uuid primary key default gen_random_uuid(),
  refill_request_id uuid not null
    references public.stock_refill_requests (id) on delete restrict,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  action text not null,
  previous_status text,
  next_status text not null,
  reason text,
  version integer not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_refill_request_events_action_check check (
    action in (
      'created',
      'updated',
      'submitted',
      'held',
      'resubmitted',
      'approved',
      'rejected'
    )
  ),
  constraint stock_refill_request_events_reason_len check (
    reason is null
    or (
      char_length(btrim(reason)) between 1 and 500
      and reason = btrim(reason)
    )
  )
);

create index if not exists stock_refill_requests_godown_status_idx
  on public.stock_refill_requests (destination_godown_id, status, created_at desc);

create index if not exists stock_refill_requests_supplier_idx
  on public.stock_refill_requests (supplier_id, created_at desc);

create index if not exists stock_refill_request_lines_request_idx
  on public.stock_refill_request_lines (refill_request_id, id);

create index if not exists stock_refill_request_events_request_idx
  on public.stock_refill_request_events (refill_request_id, created_at, id);

drop trigger if exists stock_refill_requests_set_updated_at on public.stock_refill_requests;
create trigger stock_refill_requests_set_updated_at
  before update on public.stock_refill_requests
  for each row execute function app_private.set_updated_at();

drop trigger if exists stock_refill_request_lines_set_updated_at
  on public.stock_refill_request_lines;
create trigger stock_refill_request_lines_set_updated_at
  before update on public.stock_refill_request_lines
  for each row execute function app_private.set_updated_at();

create or replace function app_private.guard_refill_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Trusted RPCs set app.refill_write for this transaction only.
  if pg_catalog.current_setting('app.refill_write', true) is distinct from 'on' then
    raise exception 'refill records cannot be changed directly'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists stock_refill_requests_write_guard on public.stock_refill_requests;
create trigger stock_refill_requests_write_guard
  before insert or update or delete on public.stock_refill_requests
  for each row execute function app_private.guard_refill_write();

drop trigger if exists stock_refill_request_lines_write_guard
  on public.stock_refill_request_lines;
create trigger stock_refill_request_lines_write_guard
  before insert or update or delete on public.stock_refill_request_lines
  for each row execute function app_private.guard_refill_write();

drop trigger if exists stock_refill_request_events_write_guard
  on public.stock_refill_request_events;
create trigger stock_refill_request_events_write_guard
  before insert or update or delete on public.stock_refill_request_events
  for each row execute function app_private.guard_refill_write();

alter table public.stock_refill_requests enable row level security;
alter table public.stock_refill_requests force row level security;
alter table public.stock_refill_request_lines enable row level security;
alter table public.stock_refill_request_lines force row level security;
alter table public.stock_refill_request_events enable row level security;
alter table public.stock_refill_request_events force row level security;

revoke all on public.stock_refill_requests from public, anon, authenticated, service_role;
revoke all on public.stock_refill_request_lines from public, anon, authenticated, service_role;
revoke all on public.stock_refill_request_events from public, anon, authenticated, service_role;
grant select on public.stock_refill_requests to authenticated;
grant select on public.stock_refill_request_lines to authenticated;
grant select on public.stock_refill_request_events to authenticated;

create or replace function app_private.can_view_refill_at_godown(target_godown uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- Historical reads keep assignment even after the godown is deactivated.
  -- Operational writes still use assert_operational_active_branch.
  -- D6: operations.monitor is not a refill viewer.
  select
    (
      app_private.has_permission('refill.approve')
      and (
        app_private.has_permission('branches.access_all')
        or exists (
          select 1
          from public.user_branch_assignments
          where user_branch_assignments.user_id = auth.uid()
            and user_branch_assignments.branch_id = target_godown
        )
      )
    )
    or (
      app_private.has_permission('refill.request')
      and exists (
        select 1
        from public.user_branch_assignments
        where user_branch_assignments.user_id = auth.uid()
          and user_branch_assignments.branch_id = target_godown
      )
    );
$$;

revoke all on function app_private.can_view_refill_at_godown(uuid)
  from public, anon, service_role;
grant execute on function app_private.can_view_refill_at_godown(uuid)
  to authenticated;

drop policy if exists stock_refill_requests_select_authorized
  on public.stock_refill_requests;
create policy stock_refill_requests_select_authorized
  on public.stock_refill_requests
  for select
  to authenticated
  using (app_private.can_view_refill_at_godown(destination_godown_id));

drop policy if exists stock_refill_request_lines_select_authorized
  on public.stock_refill_request_lines;
create policy stock_refill_request_lines_select_authorized
  on public.stock_refill_request_lines
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_refill_requests
      where stock_refill_requests.id = stock_refill_request_lines.refill_request_id
        and app_private.can_view_refill_at_godown(
          stock_refill_requests.destination_godown_id
        )
    )
  );

drop policy if exists stock_refill_request_events_select_authorized
  on public.stock_refill_request_events;
create policy stock_refill_request_events_select_authorized
  on public.stock_refill_request_events
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_refill_requests
      where stock_refill_requests.id = stock_refill_request_events.refill_request_id
        and app_private.can_view_refill_at_godown(
          stock_refill_requests.destination_godown_id
        )
    )
  );

create or replace function app_private.enable_refill_write()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('app.refill_write', 'on', true);
end;
$$;

revoke all on function app_private.enable_refill_write()
  from public, anon, authenticated, service_role;

create or replace function app_private.clean_refill_notes(raw_value text, required boolean)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(raw_value, '')), '');
begin
  if required and cleaned is null then
    raise exception 'a reason is required' using errcode = '23514';
  end if;
  if cleaned is not null and pg_catalog.char_length(cleaned) > 500 then
    raise exception 'notes are too long' using errcode = '23514';
  end if;
  return cleaned;
end;
$$;

revoke all on function app_private.clean_refill_notes(text, boolean)
  from public, anon, authenticated, service_role;

create or replace function app_private.normalize_refill_lines(raw_lines jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  normalized jsonb;
begin
  if raw_lines is null or pg_catalog.jsonb_typeof(raw_lines) <> 'array' then
    raise exception 'refill lines are required' using errcode = '23514';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'product_id', item.product_id,
        'requested_cases', item.requested_cases
      )
      order by item.product_id
    ),
    '[]'::jsonb
  )
  into normalized
  from (
    select
      (entry ->> 'product_id')::uuid as product_id,
      (entry ->> 'requested_cases')::integer as requested_cases
    from pg_catalog.jsonb_array_elements(raw_lines) as entry
  ) as item;

  if pg_catalog.jsonb_array_length(normalized) < 1 then
    raise exception 'refill lines are required' using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(normalized) as entry
    where (entry ->> 'product_id') is null
  ) then
    raise exception 'each refill line needs a product' using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(normalized) as entry
    group by entry ->> 'product_id'
    having count(*) > 1
  ) then
    raise exception 'duplicate product lines are not allowed' using errcode = '23514';
  end if;

  perform app_private.assert_carton_quantity((entry ->> 'requested_cases')::integer)
  from pg_catalog.jsonb_array_elements(normalized) as entry;

  return normalized;
end;
$$;

revoke all on function app_private.normalize_refill_lines(jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.refill_request_fingerprint(
  target_supplier uuid,
  target_godown uuid,
  cleaned_notes text,
  normalized_lines jsonb
)
returns text
language sql
immutable
set search_path = ''
as $$
  select target_supplier::text
    || '|' || target_godown::text
    || '|' || coalesce(cleaned_notes, '')
    || '|' || coalesce(normalized_lines::text, '[]');
$$;

revoke all on function app_private.refill_request_fingerprint(uuid, uuid, text, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_refill_catalog(
  target_supplier uuid,
  target_godown uuid,
  normalized_lines jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Branch row lock + active + assignment. Does not lock stock grains.
  perform app_private.assert_operational_active_branch(target_godown);

  if not exists (
    select 1
    from public.suppliers
    where suppliers.id = target_supplier
      and suppliers.is_active
  ) then
    raise exception 'supplier is inactive or missing' using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(normalized_lines) as entry
    left join public.products
      on products.id = (entry ->> 'product_id')::uuid
    where products.id is null
      or not products.is_active
      or products.supplier_id is distinct from target_supplier
  ) then
    raise exception 'product must be an active SKU of the selected supplier'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_refill_catalog(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.replace_refill_lines(
  target_request uuid,
  normalized_lines jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.stock_refill_request_lines
  where stock_refill_request_lines.refill_request_id = target_request;

  insert into public.stock_refill_request_lines (
    refill_request_id, product_id, requested_cases
  )
  select
    target_request,
    (entry ->> 'product_id')::uuid,
    (entry ->> 'requested_cases')::integer
  from pg_catalog.jsonb_array_elements(normalized_lines) as entry;
end;
$$;

revoke all on function app_private.replace_refill_lines(uuid, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.record_refill_event(
  target_request uuid,
  action_name text,
  previous_status text,
  next_status text,
  event_reason text,
  event_version integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.stock_refill_request_events (
    refill_request_id, actor_id, action, previous_status, next_status, reason, version
  )
  values (
    target_request,
    auth.uid(),
    action_name,
    previous_status,
    next_status,
    event_reason,
    event_version
  );

  perform app_private.write_audit(
    auth.uid(),
    'stock_refill_' || action_name,
    'stock_refill_requests',
    target_request,
    pg_catalog.jsonb_build_object(
      'action', action_name,
      'previous_status', previous_status,
      'next_status', next_status,
      'version', event_version
    )
  );
end;
$$;

revoke all on function app_private.record_refill_event(uuid, text, text, text, text, integer)
  from public, anon, authenticated, service_role;

create or replace function app_private.stock_refill_request_payload(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
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
    'total_requested_cases', coalesce((
      select sum(stock_refill_request_lines.requested_cases)
      from public.stock_refill_request_lines
      where stock_refill_request_lines.refill_request_id = selected.id
    ), 0),
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

revoke all on function app_private.stock_refill_request_payload(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_stock_refill_request(target uuid)
returns public.stock_refill_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
begin
  select *
  into selected
  from public.stock_refill_requests
  where stock_refill_requests.id = target
  for update;

  if selected.id is null
    or not app_private.can_view_refill_at_godown(selected.destination_godown_id)
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return selected;
end;
$$;

revoke all on function app_private.lock_stock_refill_request(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_refill_version(
  selected public.stock_refill_requests,
  expected_version integer
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if expected_version is null or selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;
end;
$$;

revoke all on function app_private.assert_refill_version(public.stock_refill_requests, integer)
  from public, anon, authenticated, service_role;

create or replace function public.create_stock_refill_request(
  target_supplier uuid,
  target_godown uuid,
  request_lines jsonb,
  idempotency_key text,
  notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  normalized jsonb;
  fingerprint text;
  existing public.stock_refill_requests;
  created_id uuid;
  request_number text;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_refill_notes(notes, false);
  normalized := app_private.normalize_refill_lines(request_lines);
  fingerprint := app_private.refill_request_fingerprint(
    target_supplier, target_godown, cleaned_notes, normalized
  );

  select *
  into existing
  from public.stock_refill_requests
  where stock_refill_requests.idempotency_key = cleaned_key;

  if found then
    if existing.request_fingerprint is distinct from fingerprint then
      raise exception 'idempotency key already used for a different request'
        using errcode = '23505';
    end if;
    if not app_private.can_view_refill_at_godown(existing.destination_godown_id) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return app_private.stock_refill_request_payload(existing.id);
  end if;

  perform app_private.assert_refill_catalog(target_supplier, target_godown, normalized);

  request_number := 'RF-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(pg_catalog.nextval('public.stock_refill_request_seq')::text, 6, '0');

  insert into public.stock_refill_requests (
    request_number, supplier_id, destination_godown_id, status, notes, version,
    created_by, updated_by, idempotency_key, request_fingerprint
  )
  values (
    request_number, target_supplier, target_godown, 'draft', cleaned_notes, 1,
    auth.uid(), auth.uid(), cleaned_key, fingerprint
  )
  returning id into created_id;

  perform app_private.replace_refill_lines(created_id, normalized);
  perform app_private.record_refill_event(
    created_id, 'created', null, 'draft', cleaned_notes, 1
  );

  return app_private.stock_refill_request_payload(created_id);
end;
$$;

create or replace function public.update_stock_refill_request(
  target_request uuid,
  expected_version integer,
  target_supplier uuid,
  target_godown uuid,
  request_lines jsonb,
  notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  cleaned_notes text;
  normalized jsonb;
  fingerprint text;
  next_version integer;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();
  selected := app_private.lock_stock_refill_request(target_request);
  perform app_private.assert_refill_version(selected, expected_version);

  if selected.created_by is distinct from auth.uid()
    or selected.status not in ('draft', 'held')
  then
    raise exception 'refill request cannot be edited' using errcode = '42501';
  end if;

  cleaned_notes := app_private.clean_refill_notes(notes, false);
  normalized := app_private.normalize_refill_lines(request_lines);
  fingerprint := app_private.refill_request_fingerprint(
    target_supplier, target_godown, cleaned_notes, normalized
  );
  perform app_private.assert_refill_catalog(target_supplier, target_godown, normalized);

  next_version := selected.version + 1;

  update public.stock_refill_requests
  set
    supplier_id = target_supplier,
    destination_godown_id = target_godown,
    notes = cleaned_notes,
    version = next_version,
    updated_by = auth.uid(),
    request_fingerprint = fingerprint
  where stock_refill_requests.id = selected.id;

  perform app_private.replace_refill_lines(selected.id, normalized);
  perform app_private.record_refill_event(
    selected.id, 'updated', selected.status, selected.status, cleaned_notes, next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

create or replace function public.submit_stock_refill_request(
  target_request uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  cleaned_key text;
  normalized jsonb;
  next_version integer;
  event_name text;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  selected := app_private.lock_stock_refill_request(target_request);

  if selected.status = 'submitted'
    and selected.submit_idempotency_key is not distinct from cleaned_key
  then
    return app_private.stock_refill_request_payload(selected.id);
  end if;

  perform app_private.assert_refill_version(selected, expected_version);

  if selected.created_by is distinct from auth.uid()
    or selected.status not in ('draft', 'held')
  then
    raise exception 'refill request cannot be submitted' using errcode = '42501';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'product_id', stock_refill_request_lines.product_id,
        'requested_cases', stock_refill_request_lines.requested_cases
      )
      order by stock_refill_request_lines.product_id
    ),
    '[]'::jsonb
  )
  into normalized
  from public.stock_refill_request_lines
  where stock_refill_request_lines.refill_request_id = selected.id;

  perform app_private.assert_refill_catalog(
    selected.supplier_id, selected.destination_godown_id, normalized
  );

  next_version := selected.version + 1;
  event_name := case when selected.status = 'held' then 'resubmitted' else 'submitted' end;

  update public.stock_refill_requests
  set
    status = 'submitted',
    version = next_version,
    updated_by = auth.uid(),
    submitted_by = auth.uid(),
    submitted_at = pg_catalog.clock_timestamp(),
    submit_idempotency_key = cleaned_key
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id, event_name, selected.status, 'submitted', null, next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

create or replace function public.approve_stock_refill_request(
  target_request uuid,
  expected_version integer,
  idempotency_key text,
  decision_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  cleaned_key text;
  cleaned_reason text;
  next_version integer;
begin
  perform app_private.assert_permission('refill.approve');
  perform app_private.enable_refill_write();
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_reason := app_private.clean_refill_notes(decision_reason, false);
  selected := app_private.lock_stock_refill_request(target_request);

  if selected.status = 'approved'
    and selected.decision_idempotency_key is not distinct from cleaned_key
  then
    return app_private.stock_refill_request_payload(selected.id);
  end if;

  perform app_private.assert_refill_version(selected, expected_version);

  if selected.status is distinct from 'submitted' then
    raise exception 'refill request cannot be approved' using errcode = '42501';
  end if;

  -- Approval still requires an active destination; it does not post stock.
  perform app_private.assert_operational_active_branch(selected.destination_godown_id);

  next_version := selected.version + 1;

  update public.stock_refill_requests
  set
    status = 'approved',
    version = next_version,
    updated_by = auth.uid(),
    decided_by = auth.uid(),
    decided_at = pg_catalog.clock_timestamp(),
    decision_reason = cleaned_reason,
    decision_idempotency_key = cleaned_key
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id, 'approved', selected.status, 'approved', cleaned_reason, next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

create or replace function public.hold_stock_refill_request(
  target_request uuid,
  expected_version integer,
  decision_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  cleaned_key text;
  cleaned_reason text;
  next_version integer;
begin
  perform app_private.assert_permission('refill.approve');
  perform app_private.enable_refill_write();
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_reason := app_private.clean_refill_notes(decision_reason, true);
  selected := app_private.lock_stock_refill_request(target_request);

  if selected.status = 'held'
    and selected.decision_idempotency_key is not distinct from cleaned_key
  then
    return app_private.stock_refill_request_payload(selected.id);
  end if;

  perform app_private.assert_refill_version(selected, expected_version);

  if selected.status is distinct from 'submitted' then
    raise exception 'refill request cannot be held' using errcode = '42501';
  end if;

  next_version := selected.version + 1;

  update public.stock_refill_requests
  set
    status = 'held',
    version = next_version,
    updated_by = auth.uid(),
    held_by = auth.uid(),
    held_at = pg_catalog.clock_timestamp(),
    hold_reason = cleaned_reason,
    decision_idempotency_key = cleaned_key
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id, 'held', selected.status, 'held', cleaned_reason, next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

create or replace function public.reject_stock_refill_request(
  target_request uuid,
  expected_version integer,
  decision_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  cleaned_key text;
  cleaned_reason text;
  next_version integer;
begin
  perform app_private.assert_permission('refill.approve');
  perform app_private.enable_refill_write();
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_reason := app_private.clean_refill_notes(decision_reason, true);
  selected := app_private.lock_stock_refill_request(target_request);

  if selected.status = 'rejected'
    and selected.decision_idempotency_key is not distinct from cleaned_key
  then
    return app_private.stock_refill_request_payload(selected.id);
  end if;

  perform app_private.assert_refill_version(selected, expected_version);

  if selected.status is distinct from 'submitted' then
    raise exception 'refill request cannot be rejected' using errcode = '42501';
  end if;

  next_version := selected.version + 1;

  update public.stock_refill_requests
  set
    status = 'rejected',
    version = next_version,
    updated_by = auth.uid(),
    decided_by = auth.uid(),
    decided_at = pg_catalog.clock_timestamp(),
    decision_reason = cleaned_reason,
    decision_idempotency_key = cleaned_key
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id, 'rejected', selected.status, 'rejected', cleaned_reason, next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

create or replace function public.get_stock_refill_request(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return app_private.stock_refill_request_payload(target_request);
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
      where suppliers.is_active
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
      where products.is_active
        and products.supplier_id is not null
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.create_stock_refill_request(uuid, uuid, jsonb, text, text)
  from public, anon, service_role;
revoke all on function public.update_stock_refill_request(uuid, integer, uuid, uuid, jsonb, text)
  from public, anon, service_role;
revoke all on function public.submit_stock_refill_request(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.approve_stock_refill_request(uuid, integer, text, text)
  from public, anon, service_role;
revoke all on function public.hold_stock_refill_request(uuid, integer, text, text)
  from public, anon, service_role;
revoke all on function public.reject_stock_refill_request(uuid, integer, text, text)
  from public, anon, service_role;
revoke all on function public.get_stock_refill_request(uuid)
  from public, anon, service_role;
revoke all on function public.list_stock_refill_requests(integer, integer, text, uuid, uuid, text)
  from public, anon, service_role;
revoke all on function public.list_stock_refill_options()
  from public, anon, service_role;

grant execute on function public.create_stock_refill_request(uuid, uuid, jsonb, text, text)
  to authenticated;
grant execute on function public.update_stock_refill_request(uuid, integer, uuid, uuid, jsonb, text)
  to authenticated;
grant execute on function public.submit_stock_refill_request(uuid, integer, text)
  to authenticated;
grant execute on function public.approve_stock_refill_request(uuid, integer, text, text)
  to authenticated;
grant execute on function public.hold_stock_refill_request(uuid, integer, text, text)
  to authenticated;
grant execute on function public.reject_stock_refill_request(uuid, integer, text, text)
  to authenticated;
grant execute on function public.get_stock_refill_request(uuid)
  to authenticated;
grant execute on function public.list_stock_refill_requests(integer, integer, text, uuid, uuid, text)
  to authenticated;
grant execute on function public.list_stock_refill_options()
  to authenticated;

comment on function public.create_stock_refill_request(uuid, uuid, jsonb, text, text) is
  'M6.2. Accounts draft. Zero stock. Idempotent on key + fingerprint.';
comment on function public.submit_stock_refill_request(uuid, integer, text) is
  'M6.2. Accounts submit or resubmit. Zero stock.';
comment on function public.approve_stock_refill_request(uuid, integer, text, text) is
  'M6.2. Admin authorization only. Not a stock receipt.';
