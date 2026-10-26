-- M5.2 Damage management database and security foundation.
-- Local-first, forward-only. Does not post stock, create holds, or expose disposition RPCs.
-- Hold-required submit always calls apply_damage_stock_isolation (M5.2 stub raises).
-- damage.stock_hold_ready cannot be true until damage_stock_isolation_installed() is true.

-- ---------------------------------------------------------------------------
-- 1. Permissions and readiness gate
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values
  (
    'damage.read',
    'View authorized damage reports, lines, events, and finalized evidence metadata.'
  ),
  (
    'damage.verify',
    'Verify submitted damage quantities and evidence. Does not post stock.'
  ),
  (
    'damage.dispose',
    'Exceptional damage disposition approval. M5.3 posting only. Does not grant ordinary stock posting.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'damage.read'),
    ('admin', 'damage.dispose'),
    ('godown_manager', 'damage.read'),
    ('godown_manager', 'damage.verify'),
    ('store_keeper', 'damage.read')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code
on conflict do nothing;

insert into public.app_configuration (key, value, description)
values (
  'damage.stock_hold_ready',
  'false'::jsonb,
  'M5.3 kill-switch only. Cannot be true until app_private.damage_stock_isolation_installed() returns true. Hold-required submit always calls apply_damage_stock_isolation; toggling this flag cannot bypass isolation.'
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------

create sequence public.damage_report_seq;

revoke all on sequence public.damage_report_seq
  from public, anon, authenticated, service_role;

create table public.damage_reports (
  id uuid primary key default gen_random_uuid(),
  report_number text not null,
  scenario text not null,
  godown_id uuid not null references public.branches (id) on delete restrict,
  status text not null default 'draft',
  receipt_id uuid references public.stock_receipts (id) on delete restrict,
  picking_request_id uuid references public.stock_picking_requests (id) on delete restrict,
  dispatch_id uuid references public.stock_dispatch_requests (id) on delete restrict,
  order_id uuid references public.orders (id) on delete restrict,
  shop_id uuid references public.shops (id) on delete restrict,
  reporter_user_id uuid not null references public.profiles (id) on delete restrict,
  verifier_user_id uuid references public.profiles (id) on delete restrict,
  version integer not null default 1,
  idempotency_key text not null,
  request_fingerprint text not null,
  submit_idempotency_key text,
  notes text,
  submitted_at timestamptz,
  submitted_by uuid references public.profiles (id) on delete restrict,
  returned_at timestamptz,
  returned_by uuid references public.profiles (id) on delete restrict,
  return_reason text,
  verified_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancellation_reason text,
  rejected_at timestamptz,
  rejected_by uuid references public.profiles (id) on delete restrict,
  rejection_reason text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint damage_reports_number_key unique (report_number),
  constraint damage_reports_idempotency_key unique (idempotency_key),
  constraint damage_reports_version_check check (version >= 1),
  constraint damage_reports_scenario_check check (
    scenario in (
      'refill_supply',
      'unloading',
      'storage',
      'loading',
      'transit',
      'shop_return'
    )
  ),
  constraint damage_reports_status_check check (
    status in (
      'draft',
      'submitted',
      'returned',
      'verified',
      'cancelled',
      'rejected'
    )
  ),
  constraint damage_reports_notes_length check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  )
);

comment on table public.damage_reports is
  'M5.2 damage report header. Document lifecycle only. Does not hold or post stock. Future disposition states are not operational.';

create table public.damage_report_lines (
  id uuid primary key default gen_random_uuid(),
  damage_report_id uuid not null
    references public.damage_reports (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  crate_id uuid references public.crates (id) on delete restrict,
  lot_id uuid references public.stock_lots (id) on delete restrict,
  receipt_line_id uuid references public.stock_receipt_lines (id) on delete restrict,
  quantity_cases integer not null,
  damage_reason text not null,
  notes text,
  sort_order integer not null default 1,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint damage_report_lines_qty_check
    check (quantity_cases >= 1 and quantity_cases <= 1000000),
  constraint damage_report_lines_reason_length check (
    char_length(btrim(damage_reason)) between 1 and 80
    and damage_reason = btrim(damage_reason)
  ),
  constraint damage_report_lines_notes_length check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  )
);

comment on table public.damage_report_lines is
  'M5.2 damage lines. Positive carton cases. lot_id is optional while lot cutover is disabled. Multi-SKU crates are allowed as separate product lines.';

create table public.damage_report_events (
  id uuid primary key default gen_random_uuid(),
  damage_report_id uuid not null
    references public.damage_reports (id) on delete restrict,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  action text not null,
  previous_status text,
  next_status text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint damage_report_events_action_length check (
    char_length(btrim(action)) between 1 and 80
  )
);

comment on table public.damage_report_events is
  'M5.2 append-only damage lifecycle history.';

create table public.damage_evidence (
  id uuid primary key default gen_random_uuid(),
  damage_report_id uuid not null
    references public.damage_reports (id) on delete restrict,
  storage_path text not null,
  uploaded_by uuid not null references public.profiles (id) on delete restrict,
  uploaded_at timestamptz not null default pg_catalog.clock_timestamp(),
  note text,
  mime_type text,
  file_size integer,
  verified_at timestamptz,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint damage_evidence_path_key unique (storage_path),
  constraint damage_evidence_path_shape check (
    storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}$'
  ),
  constraint damage_evidence_note_length check (
    note is null
    or (
      char_length(btrim(note)) between 1 and 500
      and note = btrim(note)
    )
  )
);

comment on table public.damage_evidence is
  'M5.2 private photographic evidence metadata. Bytes live in the private stock-damage-evidence bucket. verified_at marks finalized magic-byte validation.';

create index damage_reports_godown_status_idx
  on public.damage_reports (godown_id, status, created_at desc);

create index damage_reports_reporter_idx
  on public.damage_reports (reporter_user_id);

create index damage_reports_dispatch_idx
  on public.damage_reports (dispatch_id)
  where dispatch_id is not null;

create index damage_report_lines_report_idx
  on public.damage_report_lines (damage_report_id, sort_order);

create unique index damage_report_lines_grain_idx
  on public.damage_report_lines (
    damage_report_id,
    product_id,
    coalesce(crate_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(lot_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(receipt_line_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index damage_report_events_report_idx
  on public.damage_report_events (damage_report_id, created_at);

create index damage_evidence_report_idx
  on public.damage_evidence (damage_report_id);

create unique index damage_reports_open_transit_dispatch_idx
  on public.damage_reports (dispatch_id)
  where scenario = 'transit'
    and dispatch_id is not null
    and status not in ('cancelled', 'rejected');

create unique index damage_reports_open_loading_picking_idx
  on public.damage_reports (picking_request_id)
  where scenario = 'loading'
    and picking_request_id is not null
    and status not in ('cancelled', 'rejected');

create unique index damage_reports_open_loading_dispatch_idx
  on public.damage_reports (dispatch_id)
  where scenario = 'loading'
    and dispatch_id is not null
    and status not in ('cancelled', 'rejected');

-- ---------------------------------------------------------------------------
-- 3. Trusted-writer guards
-- ---------------------------------------------------------------------------

create or replace function app_private.guard_damage_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('app.damage_write', true) is distinct from 'on' then
    raise exception 'damage records cannot be changed directly'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger damage_reports_write_guard
  before insert or update or delete on public.damage_reports
  for each row execute function app_private.guard_damage_write();

create trigger damage_report_lines_write_guard
  before insert or update or delete on public.damage_report_lines
  for each row execute function app_private.guard_damage_write();

create trigger damage_report_events_write_guard
  before insert or update or delete on public.damage_report_events
  for each row execute function app_private.guard_damage_write();

create trigger damage_evidence_write_guard
  before insert or update or delete on public.damage_evidence
  for each row execute function app_private.guard_damage_write();

create or replace function app_private.guard_damage_report_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'damage reports cannot be deleted' using errcode = '42501';
  end if;

  if new.id is distinct from old.id
    or new.report_number is distinct from old.report_number
    or new.godown_id is distinct from old.godown_id
    or new.scenario is distinct from old.scenario
    or new.reporter_user_id is distinct from old.reporter_user_id
    or new.idempotency_key is distinct from old.idempotency_key
    or new.created_at is distinct from old.created_at
  then
    raise exception 'damage report identity cannot be changed' using errcode = '42501';
  end if;

  if old.status = new.status then
    if old.status in ('verified', 'cancelled', 'rejected') then
      raise exception 'verified damage report cannot be changed' using errcode = '42501';
    end if;
    new.updated_at := pg_catalog.clock_timestamp();
    return new;
  end if;

  if old.status = 'draft' and new.status in ('submitted', 'cancelled') then
    null;
  elsif old.status = 'submitted' and new.status in ('returned', 'verified', 'rejected') then
    null;
  elsif old.status = 'returned' and new.status in ('submitted', 'cancelled') then
    null;
  else
    raise exception 'damage report cannot change status' using errcode = '42501';
  end if;

  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$$;

create trigger damage_reports_identity_guard
  before update or delete on public.damage_reports
  for each row execute function app_private.guard_damage_report_identity();

create or replace function app_private.guard_damage_events()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception 'damage events cannot be changed' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger damage_report_events_append_only
  before update or delete on public.damage_report_events
  for each row execute function app_private.guard_damage_events();

create or replace function app_private.guard_damage_evidence()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'damage evidence cannot be deleted' using errcode = '42501';
  end if;

  if old.verified_at is not null then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  if new.damage_report_id is distinct from old.damage_report_id
    or new.storage_path is distinct from old.storage_path
    or new.uploaded_by is distinct from old.uploaded_by
    or new.uploaded_at is distinct from old.uploaded_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger damage_evidence_guard
  before update or delete on public.damage_evidence
  for each row execute function app_private.guard_damage_evidence();

create trigger damage_reports_set_updated_at
  before update on public.damage_reports
  for each row execute function app_private.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Private helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.damage_stock_hold_ready()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select public.app_configuration.value
      from public.app_configuration
      where public.app_configuration.key = 'damage.stock_hold_ready'
    ),
    'false'::jsonb
  ) = 'true'::jsonb;
$$;

create or replace function app_private.damage_requires_stock_hold(scenario text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select scenario in ('storage', 'loading', 'shop_return');
$$;

-- Returns false in M5.2. M5.3 replaces this to true only after the isolation
-- body actually deducts allocatable stock in the same transaction as submit.
create or replace function app_private.damage_stock_isolation_installed()
returns boolean
language sql
immutable
security definer
set search_path = ''
as $$
  select false;
$$;

create or replace function app_private.guard_damage_hold_configuration()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op in ('INSERT', 'UPDATE')
    and new.key = 'damage.stock_hold_ready'
    and new.value = 'true'::jsonb
    and not app_private.damage_stock_isolation_installed()
  then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger app_configuration_damage_hold_guard
  before insert or update on public.app_configuration
  for each row execute function app_private.guard_damage_hold_configuration();

-- M5.2 stub always fails. Submit for hold-required scenarios must call this.
-- M5.3 replaces the body to lock grains and isolate quantity before returning.
create or replace function app_private.apply_damage_stock_isolation(target_report uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if target_report is null then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;
  raise exception 'damage stock isolation is not ready' using errcode = '23514';
end;
$$;

create or replace function app_private.can_view_damage_report(
  target_godown uuid,
  scenario text,
  reporter uuid,
  target_dispatch uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  if app_private.has_permission('operations.monitor') then
    return true;
  end if;

  if app_private.has_permission('damage.read')
    and app_private.can_work_at_branch(target_godown)
  then
    return true;
  end if;

  if scenario = 'transit'
    and reporter = auth.uid()
    and app_private.has_permission('deliveries.execute')
    and target_dispatch is not null
    and exists (
      select 1
      from public.stock_dispatch_requests
      where stock_dispatch_requests.id = target_dispatch
        and stock_dispatch_requests.assigned_to = auth.uid()
        and stock_dispatch_requests.branch_id = target_godown
    )
  then
    return true;
  end if;

  return false;
end;
$$;

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

  perform app_private.assert_operational_active_branch(target_godown);

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

create or replace function app_private.lock_damage_report(target_report uuid)
returns public.damage_reports
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.damage_reports
  where damage_reports.id = target_report
  for update;

  if not found
    or not app_private.can_view_damage_report(
      selected.godown_id,
      selected.scenario,
      selected.reporter_user_id,
      selected.dispatch_id
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return selected;
end;
$$;

create or replace function app_private.assert_damage_version(
  selected public.damage_reports,
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

create or replace function app_private.record_damage_event(
  target_report uuid,
  action_name text,
  previous_status text,
  next_status text,
  details jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.damage_report_events (
    damage_report_id, actor_id, action, previous_status, next_status, metadata
  )
  values (
    target_report,
    auth.uid(),
    action_name,
    previous_status,
    next_status,
    coalesce(details, '{}'::jsonb)
  );
end;
$$;

create or replace function app_private.assert_crate_in_godown(
  target_crate uuid,
  target_godown uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if target_crate is null then
    raise exception 'crate is required' using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = target_crate
      and zones.branch_id = target_godown
  ) then
    raise exception 'crate is not in this godown' using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.assert_optional_damage_lot(
  target_lot uuid,
  target_product uuid,
  target_godown uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if target_lot is null then
    return;
  end if;

  if not exists (
    select 1
    from public.stock_lots
    where stock_lots.id = target_lot
      and stock_lots.product_id = target_product
      and stock_lots.branch_id = target_godown
  ) then
    raise exception 'stock lot not found for product/godown' using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.damage_open_receipt_qty(
  target_receipt_line uuid,
  exclude_report uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(damage_report_lines.quantity_cases), 0)::integer
  from public.damage_report_lines
  join public.damage_reports
    on damage_reports.id = damage_report_lines.damage_report_id
  where damage_report_lines.receipt_line_id = target_receipt_line
    and damage_reports.status not in ('cancelled', 'rejected')
    and (
      exclude_report is null
      or damage_reports.id is distinct from exclude_report
    );
$$;

create or replace function app_private.validate_damage_sources(
  scenario text,
  target_godown uuid,
  receipt_id uuid,
  picking_request_id uuid,
  dispatch_id uuid,
  order_id uuid,
  shop_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  receipt public.stock_receipts;
  picking public.stock_picking_requests;
  header public.stock_dispatch_requests;
  shop_order public.orders;
begin
  if scenario in ('refill_supply', 'unloading') then
    if receipt_id is null
      or picking_request_id is not null
      or dispatch_id is not null
      or order_id is not null
      or shop_id is not null
    then
      raise exception 'inbound damage requires a receipt only' using errcode = '23514';
    end if;

    select *
    into receipt
    from public.stock_receipts
    where stock_receipts.id = receipt_id;

    if not found
      or receipt.godown_id is distinct from target_godown
      or receipt.status is distinct from 'posted'
    then
      raise exception 'receipt is not eligible for damage reporting'
        using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'storage' then
    if receipt_id is not null
      or picking_request_id is not null
      or dispatch_id is not null
      or order_id is not null
      or shop_id is not null
    then
      raise exception 'storage damage cannot reference another document'
        using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'loading' then
    if receipt_id is not null or shop_id is not null or order_id is not null then
      raise exception 'loading damage cannot reference a receipt or shop'
        using errcode = '23514';
    end if;

    if picking_request_id is null and dispatch_id is null then
      raise exception 'loading damage requires picking or dispatch preparation'
        using errcode = '23514';
    end if;

    if dispatch_id is not null then
      select *
      into header
      from public.stock_dispatch_requests
      where stock_dispatch_requests.id = dispatch_id;

      if not found
        or header.branch_id is distinct from target_godown
        or header.stock_consumed
        or header.status is distinct from 'preparing'
      then
        raise exception 'dispatch is not eligible for loading damage'
          using errcode = '23514';
      end if;

      if picking_request_id is not null
        and header.picking_request_id is distinct from picking_request_id
      then
        raise exception 'loading damage dispatch does not match picking'
          using errcode = '23514';
      end if;
    end if;

    select *
    into picking
    from public.stock_picking_requests
    where stock_picking_requests.id = coalesce(
      picking_request_id,
      header.picking_request_id
    );

    if not found
      or picking.branch_id is distinct from target_godown
      or picking.status not in ('allocated', 'picking', 'picked', 'ready_for_dispatch')
    then
      raise exception 'picking is not eligible for loading damage'
        using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'transit' then
    if dispatch_id is null
      or receipt_id is not null
      or picking_request_id is not null
      or order_id is not null
      or shop_id is not null
    then
      raise exception 'transit damage requires a dispatch only' using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'shop_return' then
    if shop_id is null
      or receipt_id is not null
      or picking_request_id is not null
      or dispatch_id is not null
    then
      raise exception 'shop-return damage requires a shop and no inbound source'
        using errcode = '23514';
    end if;

    if not exists (
      select 1 from public.shops
      where shops.id = shop_id
        and shops.is_active
    ) then
      raise exception 'shop is inactive or missing' using errcode = '23514';
    end if;

    if order_id is not null then
      select *
      into shop_order
      from public.orders
      where orders.id = order_id;

      if not found
        or shop_order.shop_id is distinct from shop_id
        or shop_order.branch_id is distinct from target_godown
      then
        raise exception 'shop return order does not match this godown'
          using errcode = '23514';
      end if;
    end if;
    return;
  end if;

  raise exception 'damage scenario is invalid' using errcode = '23514';
end;
$$;

create or replace function app_private.replace_damage_lines(
  target_report uuid,
  scenario text,
  target_godown uuid,
  source_receipt uuid,
  source_picking uuid,
  source_dispatch uuid,
  report_lines jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  line_product uuid;
  line_crate uuid;
  line_lot uuid;
  line_receipt uuid;
  line_qty integer;
  line_reason text;
  line_notes text;
  sort_no integer := 0;
  picking uuid;
  reserved_qty integer;
  reported_qty integer;
  damaged_qty integer;
  already_qty integer;
begin
  if report_lines is null or pg_catalog.jsonb_typeof(report_lines) is distinct from 'array'
    or pg_catalog.jsonb_array_length(report_lines) < 1
  then
    raise exception 'a damage report needs at least one line' using errcode = '23514';
  end if;

  delete from public.damage_report_lines
  where damage_report_lines.damage_report_id = target_report;

  if scenario = 'loading' then
    select coalesce(source_picking, stock_dispatch_requests.picking_request_id)
    into picking
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = source_dispatch;

    picking := coalesce(source_picking, picking);
  elsif scenario = 'transit' then
    select stock_dispatch_requests.picking_request_id
    into picking
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = source_dispatch;
  end if;

  for item in
    select value from jsonb_array_elements(report_lines)
  loop
    sort_no := sort_no + 1;
    begin
      line_product := (item ->> 'product_id')::uuid;
    exception
      when others then
        raise exception 'product is required' using errcode = '23514';
    end;

    if line_product is null or not exists (
      select 1 from public.products where products.id = line_product
    ) then
      raise exception 'product is inactive or missing' using errcode = '23514';
    end if;

    begin
      line_crate := nullif(item ->> 'crate_id', '')::uuid;
    exception
      when others then
        raise exception 'crate is invalid' using errcode = '23514';
    end;

    begin
      line_lot := nullif(item ->> 'lot_id', '')::uuid;
    exception
      when others then
        raise exception 'stock lot is invalid' using errcode = '23514';
    end;

    begin
      line_receipt := nullif(item ->> 'receipt_line_id', '')::uuid;
    exception
      when others then
        raise exception 'receipt line is invalid' using errcode = '23514';
    end;

    line_qty := app_private.receipt_case_count(item -> 'quantity_cases');
    if line_qty < 1 then
      raise exception 'quantity must be a whole number of carton cases'
        using errcode = '23514';
    end if;

    line_reason := pg_catalog.btrim(coalesce(item ->> 'damage_reason', ''));
    if pg_catalog.char_length(line_reason) < 1
      or pg_catalog.char_length(line_reason) > 80
    then
      raise exception 'damage reason is required' using errcode = '23514';
    end if;

    line_notes := app_private.clean_verification_text(item ->> 'notes', false);
    perform app_private.assert_optional_damage_lot(line_lot, line_product, target_godown);

    if scenario in ('refill_supply', 'unloading') then
      if line_receipt is null then
        raise exception 'inbound damage requires a receipt line' using errcode = '23514';
      end if;

      select stock_receipt_lines.damaged_cases, stock_receipt_lines.destination_crate_id
      into damaged_qty, line_crate
      from public.stock_receipt_lines
      join public.stock_receipts
        on stock_receipts.id = stock_receipt_lines.receipt_id
      where stock_receipt_lines.id = line_receipt
        and stock_receipt_lines.receipt_id = source_receipt
        and stock_receipt_lines.product_id = line_product
        and stock_receipts.godown_id = target_godown;

      if not found then
        raise exception 'receipt line does not match this damage report'
          using errcode = '23514';
      end if;

      already_qty := app_private.damage_open_receipt_qty(line_receipt, target_report);
      if already_qty + line_qty > damaged_qty then
        raise exception 'damaged quantity exceeds the receipt line'
          using errcode = '23514';
      end if;
    elsif scenario in ('storage', 'loading') then
      perform app_private.assert_crate_in_godown(line_crate, target_godown);
    elsif scenario = 'shop_return' then
      if line_crate is not null then
        perform app_private.assert_crate_in_godown(line_crate, target_godown);
      end if;
    elsif scenario = 'transit' then
      if line_crate is not null then
        perform app_private.assert_crate_in_godown(line_crate, target_godown);
      end if;
    end if;

    if scenario in ('loading', 'transit') then
      if picking is null then
        raise exception 'loading damage requires a reserved grain' using errcode = '23514';
      end if;

      select coalesce(sum(stock_reservations.reserved_cases), 0)
      into reserved_qty
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking
        and stock_reservations.product_id = line_product
        and (
          line_crate is null
          or stock_reservations.crate_id = line_crate
        );

      if reserved_qty < 1 then
        raise exception 'loading damage requires a reserved grain' using errcode = '23514';
      end if;
    end if;

    insert into public.damage_report_lines (
      damage_report_id, product_id, crate_id, lot_id, receipt_line_id,
      quantity_cases, damage_reason, notes, sort_order
    )
    values (
      target_report, line_product, line_crate, line_lot, line_receipt,
      line_qty, line_reason, line_notes, sort_no
    );
  end loop;

  if scenario in ('loading', 'transit') then
    for line_product in
      select distinct damage_report_lines.product_id
      from public.damage_report_lines
      where damage_report_lines.damage_report_id = target_report
    loop
      select coalesce(sum(damage_report_lines.quantity_cases), 0)
      into reported_qty
      from public.damage_report_lines
      where damage_report_lines.damage_report_id = target_report
        and damage_report_lines.product_id = line_product;

      select coalesce(sum(stock_reservations.reserved_cases), 0)
      into reserved_qty
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking
        and stock_reservations.product_id = line_product;

      if reported_qty > reserved_qty then
        raise exception 'damaged quantity exceeds the source document'
          using errcode = '23514';
      end if;
    end loop;
  end if;
end;
$$;

create or replace function app_private.damage_fingerprint(
  scenario text,
  target_godown uuid,
  receipt_id uuid,
  picking_request_id uuid,
  dispatch_id uuid,
  order_id uuid,
  shop_id uuid,
  notes text,
  report_lines jsonb
)
returns text
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.encode(
    extensions.digest(
      coalesce(scenario, '')
      || '|' || coalesce(target_godown::text, '')
      || '|' || coalesce(receipt_id::text, '')
      || '|' || coalesce(picking_request_id::text, '')
      || '|' || coalesce(dispatch_id::text, '')
      || '|' || coalesce(order_id::text, '')
      || '|' || coalesce(shop_id::text, '')
      || '|' || coalesce(notes, '')
      || '|' || coalesce(report_lines::text, ''),
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function app_private.damage_report_payload(target_report uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
begin
  select *
  into header
  from public.damage_reports
  where damage_reports.id = target_report;

  if not found
    or not app_private.can_view_damage_report(
      header.godown_id,
      header.scenario,
      header.reporter_user_id,
      header.dispatch_id
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'report_number', header.report_number,
    'scenario', header.scenario,
    'godown_id', header.godown_id,
    'godown_name', (select branches.name from public.branches where branches.id = header.godown_id),
    'status', header.status,
    'version', header.version,
    'receipt_id', header.receipt_id,
    'picking_request_id', header.picking_request_id,
    'dispatch_id', header.dispatch_id,
    'order_id', header.order_id,
    'shop_id', header.shop_id,
    'notes', header.notes,
    'reporter_user_id', header.reporter_user_id,
    'reporter_name', (
      select profiles.full_name from public.profiles where profiles.id = header.reporter_user_id
    ),
    'created_at', header.created_at,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_report_lines.id,
        'product_id', damage_report_lines.product_id,
        'product_sku', products.sku,
        'product_name', products.name,
        'crate_id', damage_report_lines.crate_id,
        'crate_code', crates.code,
        'lot_id', damage_report_lines.lot_id,
        'quantity_cases', damage_report_lines.quantity_cases,
        'damage_reason', damage_report_lines.damage_reason,
        'notes', damage_report_lines.notes,
        'receipt_line_id', damage_report_lines.receipt_line_id
      ) order by damage_report_lines.sort_order, damage_report_lines.id)
      from public.damage_report_lines
      join public.products on products.id = damage_report_lines.product_id
      left join public.crates on crates.id = damage_report_lines.crate_id
      where damage_report_lines.damage_report_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'action', damage_report_events.action,
        'actor_name', profiles.full_name,
        'previous_status', damage_report_events.previous_status,
        'next_status', damage_report_events.next_status,
        'created_at', damage_report_events.created_at,
        'metadata', damage_report_events.metadata
      ) order by damage_report_events.created_at, damage_report_events.id)
      from public.damage_report_events
      join public.profiles on profiles.id = damage_report_events.actor_id
      where damage_report_events.damage_report_id = header.id
    ), '[]'::jsonb),
    'evidence', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_evidence.id,
        'finalized', damage_evidence.verified_at is not null,
        'mime_type', damage_evidence.mime_type,
        'uploaded_at', damage_evidence.uploaded_at
      ) order by damage_evidence.uploaded_at, damage_evidence.id)
      from public.damage_evidence
      where damage_evidence.damage_report_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Public RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_damage_report(
  scenario text,
  target_godown uuid,
  report_lines jsonb,
  idempotency_key text,
  notes text default null,
  receipt_id uuid default null,
  picking_request_id uuid default null,
  dispatch_id uuid default null,
  order_id uuid default null,
  shop_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  cleaned_scenario text;
  fingerprint text;
  existing public.damage_reports;
  created_id uuid;
  report_number text;
begin
  perform set_config('app.damage_write', 'on', true);
  cleaned_scenario := pg_catalog.lower(pg_catalog.btrim(coalesce(scenario, '')));
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_verification_text(notes, false);
  fingerprint := app_private.damage_fingerprint(
    cleaned_scenario, target_godown, receipt_id, picking_request_id,
    dispatch_id, order_id, shop_id, cleaned_notes, report_lines
  );

  select *
  into existing
  from public.damage_reports
  where damage_reports.idempotency_key = cleaned_key;

  if found then
    if existing.request_fingerprint is distinct from fingerprint then
      raise exception 'idempotency key already used for a different request'
        using errcode = '23505';
    end if;
    if not app_private.can_view_damage_report(
      existing.godown_id,
      existing.scenario,
      existing.reporter_user_id,
      existing.dispatch_id
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return app_private.damage_report_payload(existing.id);
  end if;

  perform app_private.assert_damage_create_auth(cleaned_scenario, target_godown, dispatch_id);
  perform app_private.validate_damage_sources(
    cleaned_scenario, target_godown, receipt_id, picking_request_id,
    dispatch_id, order_id, shop_id
  );

  report_number := 'DMG-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(pg_catalog.nextval('public.damage_report_seq')::text, 6, '0');

  insert into public.damage_reports (
    report_number, scenario, godown_id, status, receipt_id, picking_request_id,
    dispatch_id, order_id, shop_id, reporter_user_id, version, idempotency_key,
    request_fingerprint, notes
  )
  values (
    report_number, cleaned_scenario, target_godown, 'draft', receipt_id,
    picking_request_id, dispatch_id, order_id, shop_id, auth.uid(), 1,
    cleaned_key, fingerprint, cleaned_notes
  )
  returning id into created_id;

  perform app_private.replace_damage_lines(
    created_id, cleaned_scenario, target_godown, receipt_id,
    picking_request_id, dispatch_id, report_lines
  );
  perform app_private.record_damage_event(
    created_id, 'created', null, 'draft',
    pg_catalog.jsonb_build_object('scenario', cleaned_scenario)
  );
  perform app_private.write_audit(
    auth.uid(),
    'create_damage_report',
    'damage_reports',
    created_id,
    pg_catalog.jsonb_build_object('scenario', cleaned_scenario)
  );

  return app_private.damage_report_payload(created_id);
end;
$$;

create or replace function public.update_damage_report(
  target_report uuid,
  expected_version integer,
  report_lines jsonb,
  notes text default null,
  receipt_id uuid default null,
  picking_request_id uuid default null,
  dispatch_id uuid default null,
  order_id uuid default null,
  shop_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_notes text;
  fingerprint text;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);

  if selected.status not in ('draft', 'returned')
    or selected.reporter_user_id is distinct from auth.uid()
  then
    raise exception 'damage report cannot be changed' using errcode = '42501';
  end if;

  perform app_private.assert_damage_create_auth(
    selected.scenario,
    selected.godown_id,
    coalesce(dispatch_id, selected.dispatch_id)
  );
  perform app_private.validate_damage_sources(
    selected.scenario,
    selected.godown_id,
    coalesce(receipt_id, selected.receipt_id),
    coalesce(picking_request_id, selected.picking_request_id),
    coalesce(dispatch_id, selected.dispatch_id),
    coalesce(order_id, selected.order_id),
    coalesce(shop_id, selected.shop_id)
  );

  cleaned_notes := app_private.clean_verification_text(notes, false);
  fingerprint := app_private.damage_fingerprint(
    selected.scenario,
    selected.godown_id,
    coalesce(receipt_id, selected.receipt_id),
    coalesce(picking_request_id, selected.picking_request_id),
    coalesce(dispatch_id, selected.dispatch_id),
    coalesce(order_id, selected.order_id),
    coalesce(shop_id, selected.shop_id),
    cleaned_notes,
    report_lines
  );

  update public.damage_reports
  set
    receipt_id = coalesce(receipt_id, selected.receipt_id),
    picking_request_id = coalesce(picking_request_id, selected.picking_request_id),
    dispatch_id = coalesce(dispatch_id, selected.dispatch_id),
    order_id = coalesce(order_id, selected.order_id),
    shop_id = coalesce(shop_id, selected.shop_id),
    notes = cleaned_notes,
    request_fingerprint = fingerprint,
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.replace_damage_lines(
    selected.id,
    selected.scenario,
    selected.godown_id,
    coalesce(receipt_id, selected.receipt_id),
    coalesce(picking_request_id, selected.picking_request_id),
    coalesce(dispatch_id, selected.dispatch_id),
    report_lines
  );
  perform app_private.record_damage_event(
    selected.id, 'updated', selected.status, selected.status, '{}'::jsonb
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.submit_damage_report(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_key text;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  if selected.status = 'submitted'
    and selected.submit_idempotency_key = cleaned_key
  then
    return app_private.damage_report_payload(selected.id);
  end if;

  perform app_private.assert_damage_version(selected, expected_version);

  if selected.status not in ('draft', 'returned')
    or selected.reporter_user_id is distinct from auth.uid()
  then
    raise exception 'damage report cannot be submitted' using errcode = '42501';
  end if;

  if selected.submit_idempotency_key is not null
    and selected.submit_idempotency_key is distinct from cleaned_key
    and selected.status = 'submitted'
  then
    raise exception 'idempotency key already used for a different request'
      using errcode = '23505';
  end if;

  perform app_private.assert_damage_create_auth(
    selected.scenario, selected.godown_id, selected.dispatch_id
  );
  perform app_private.validate_damage_sources(
    selected.scenario, selected.godown_id, selected.receipt_id,
    selected.picking_request_id, selected.dispatch_id, selected.order_id,
    selected.shop_id
  );

  -- Isolation is a required function, not a configuration bypass. The M5.2
  -- stub always raises. Enabling damage.stock_hold_ready cannot skip this.
  if app_private.damage_requires_stock_hold(selected.scenario) then
    perform app_private.apply_damage_stock_isolation(selected.id);
  end if;

  if not exists (
    select 1 from public.damage_report_lines
    where damage_report_lines.damage_report_id = selected.id
  ) then
    raise exception 'a damage report needs at least one line' using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'submitted',
    submitted_at = pg_catalog.clock_timestamp(),
    submitted_by = auth.uid(),
    submit_idempotency_key = cleaned_key,
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'submitted', selected.status, 'submitted', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'submit_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.return_damage_report(
  target_report uuid,
  expected_version integer,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(reason, true);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be returned' using errcode = '42501';
  end if;

  update public.damage_reports
  set
    status = 'returned',
    returned_at = pg_catalog.clock_timestamp(),
    returned_by = auth.uid(),
    return_reason = cleaned_reason,
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'returned', selected.status, 'returned',
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.verify_damage_report(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be verified' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.damage_evidence
    where damage_evidence.damage_report_id = selected.id
      and damage_evidence.verified_at is not null
  ) then
    raise exception 'photographic evidence is required' using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'verified',
    verifier_user_id = auth.uid(),
    verified_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'verified', selected.status, 'verified', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'verify_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.cancel_damage_report(
  target_report uuid,
  expected_version integer,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_reason text;
  manager_cancel boolean;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  cleaned_reason := app_private.clean_verification_text(reason, true);
  manager_cancel := app_private.has_permission('damage.verify')
    and app_private.can_work_at_branch(selected.godown_id);

  if selected.status not in ('draft', 'returned') then
    raise exception 'damage report cannot be cancelled' using errcode = '42501';
  end if;

  if not manager_cancel and selected.reporter_user_id is distinct from auth.uid() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not manager_cancel then
    perform app_private.assert_damage_create_auth(
      selected.scenario, selected.godown_id, selected.dispatch_id
    );
  else
    perform app_private.assert_operational_active_branch(selected.godown_id);
  end if;

  update public.damage_reports
  set
    status = 'cancelled',
    cancelled_at = pg_catalog.clock_timestamp(),
    cancelled_by = auth.uid(),
    cancellation_reason = cleaned_reason,
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'cancelled', selected.status, 'cancelled',
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.reject_damage_report(
  target_report uuid,
  expected_version integer,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(reason, true);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be rejected' using errcode = '42501';
  end if;

  update public.damage_reports
  set
    status = 'rejected',
    rejected_at = pg_catalog.clock_timestamp(),
    rejected_by = auth.uid(),
    rejection_reason = cleaned_reason,
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'rejected', selected.status, 'rejected',
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.get_damage_report(target_report uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return app_private.damage_report_payload(target_report);
end;
$$;

create or replace function public.list_damage_reports(
  page integer default 1,
  page_size integer default 50,
  target_godown uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  safe_page integer := greatest(coalesce(page, 1), 1);
  safe_size integer := least(greatest(coalesce(page_size, 50), 1), 100);
  total_count integer;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select count(*)
  into total_count
  from public.damage_reports
  where (target_godown is null or damage_reports.godown_id = target_godown)
    and app_private.can_view_damage_report(
      damage_reports.godown_id,
      damage_reports.scenario,
      damage_reports.reporter_user_id,
      damage_reports.dispatch_id
    );

  return pg_catalog.jsonb_build_object(
    'total', total_count,
    'page', safe_page,
    'page_size', safe_size,
    'items', coalesce((
      select pg_catalog.jsonb_agg(item)
      from (
        select pg_catalog.jsonb_build_object(
          'id', damage_reports.id,
          'report_number', damage_reports.report_number,
          'scenario', damage_reports.scenario,
          'godown_id', damage_reports.godown_id,
          'godown_name', branches.name,
          'status', damage_reports.status,
          'version', damage_reports.version,
          'reporter_name', profiles.full_name,
          'created_at', damage_reports.created_at
        ) as item
        from public.damage_reports
        join public.branches on branches.id = damage_reports.godown_id
        join public.profiles on profiles.id = damage_reports.reporter_user_id
        where (target_godown is null or damage_reports.godown_id = target_godown)
          and app_private.can_view_damage_report(
            damage_reports.godown_id,
            damage_reports.scenario,
            damage_reports.reporter_user_id,
            damage_reports.dispatch_id
          )
        order by damage_reports.created_at desc, damage_reports.id desc
        offset (safe_page - 1) * safe_size
        limit safe_size
      ) listed
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Evidence RPCs and private storage
-- ---------------------------------------------------------------------------

create or replace function app_private.can_store_damage_photo(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.damage_evidence
    join public.damage_reports
      on damage_reports.id = damage_evidence.damage_report_id
    where damage_evidence.storage_path = object_name
      and damage_evidence.verified_at is null
      and damage_evidence.uploaded_by = auth.uid()
      and damage_reports.status in ('draft', 'returned', 'submitted')
      and app_private.can_view_damage_report(
        damage_reports.godown_id,
        damage_reports.scenario,
        damage_reports.reporter_user_id,
        damage_reports.dispatch_id
      )
  );
$$;

create or replace function app_private.can_read_damage_photo(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.damage_evidence
    join public.damage_reports
      on damage_reports.id = damage_evidence.damage_report_id
    where damage_evidence.storage_path = object_name
      and damage_evidence.verified_at is not null
      and app_private.can_view_damage_report(
        damage_reports.godown_id,
        damage_reports.scenario,
        damage_reports.reporter_user_id,
        damage_reports.dispatch_id
      )
  );
$$;

create or replace function public.create_damage_photo_upload(
  target_report uuid,
  photo_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  evidence_id uuid := pg_catalog.gen_random_uuid();
  object_path text;
  note text;
  manager_upload boolean;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  manager_upload := app_private.has_permission('damage.verify')
    and app_private.can_work_at_branch(selected.godown_id);

  if selected.status not in ('draft', 'returned', 'submitted') then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  if not manager_upload and selected.reporter_user_id is distinct from auth.uid() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  note := app_private.clean_verification_text(photo_note, false);
  object_path := selected.id::text || '/' || evidence_id::text;

  insert into public.damage_evidence (
    id, damage_report_id, storage_path, uploaded_by, note
  )
  values (evidence_id, selected.id, object_path, auth.uid(), note);

  return pg_catalog.jsonb_build_object(
    'id', evidence_id,
    'bucket', 'stock-damage-evidence',
    'path', object_path
  );
end;
$$;

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

  detected_mime := app_private.detected_image_mime(payload);
  if detected_mime is null then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  object_size := pg_catalog.octet_length(payload);
  object_etag := pg_catalog.encode(extensions.digest(payload, 'md5'), 'hex');
  object_mime := detected_mime;
  object_metadata := pg_catalog.jsonb_build_object(
    'size', object_size,
    'mimetype', object_mime,
    'eTag', object_etag
  );

  -- Require a Storage catalog row from an actual upload. Postgres cannot read
  -- S3 object bytes, so ownership is checked and catalog metadata is rewritten
  -- from the verified payload rather than trusted as supplied by the client.
  select storage.objects.owner
  into object_owner
  from storage.objects
  where storage.objects.bucket_id = 'stock-damage-evidence'
    and storage.objects.name = evidence.storage_path;

  if not found then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  if object_owner is not null and object_owner is distinct from evidence.uploaded_by then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  update storage.objects
  set
    owner = evidence.uploaded_by,
    owner_id = evidence.uploaded_by::text,
    metadata = object_metadata
  where storage.objects.bucket_id = 'stock-damage-evidence'
    and storage.objects.name = evidence.storage_path;

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

create or replace function public.get_damage_photo_url(target_evidence uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  evidence public.damage_evidence;
  header public.damage_reports;
begin
  select *
  into evidence
  from public.damage_evidence
  where damage_evidence.id = target_evidence;

  if not found or evidence.verified_at is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into header
  from public.damage_reports
  where damage_reports.id = evidence.damage_report_id;

  if not found
    or not app_private.can_view_damage_report(
      header.godown_id,
      header.scenario,
      header.reporter_user_id,
      header.dispatch_id
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'bucket', 'stock-damage-evidence',
    'path', evidence.storage_path,
    'mime_type', evidence.mime_type
  );
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'stock-damage-evidence',
  'stock-damage-evidence',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
);

create policy stock_damage_evidence_insert
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'stock-damage-evidence'
    and app_private.can_store_damage_photo(name)
  );

create policy stock_damage_evidence_select
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'stock-damage-evidence'
    and app_private.can_read_damage_photo(name)
  );

-- ---------------------------------------------------------------------------
-- 7. RLS, grants, and revokes
-- ---------------------------------------------------------------------------

alter table public.damage_reports enable row level security;
alter table public.damage_reports force row level security;
alter table public.damage_report_lines enable row level security;
alter table public.damage_report_lines force row level security;
alter table public.damage_report_events enable row level security;
alter table public.damage_report_events force row level security;
alter table public.damage_evidence enable row level security;
alter table public.damage_evidence force row level security;

revoke all on public.damage_reports from public, anon, authenticated, service_role;
revoke all on public.damage_report_lines from public, anon, authenticated, service_role;
revoke all on public.damage_report_events from public, anon, authenticated, service_role;
revoke all on public.damage_evidence from public, anon, authenticated, service_role;

grant select on public.damage_reports to authenticated;
grant select on public.damage_report_lines to authenticated;
grant select on public.damage_report_events to authenticated;
grant select on public.damage_evidence to authenticated;

create policy damage_reports_select on public.damage_reports
  for select to authenticated
  using (
    app_private.can_view_damage_report(
      godown_id, scenario, reporter_user_id, dispatch_id
    )
  );

create policy damage_report_lines_select on public.damage_report_lines
  for select to authenticated
  using (
    exists (
      select 1
      from public.damage_reports
      where damage_reports.id = damage_report_lines.damage_report_id
        and app_private.can_view_damage_report(
          damage_reports.godown_id,
          damage_reports.scenario,
          damage_reports.reporter_user_id,
          damage_reports.dispatch_id
        )
    )
  );

create policy damage_report_events_select on public.damage_report_events
  for select to authenticated
  using (
    exists (
      select 1
      from public.damage_reports
      where damage_reports.id = damage_report_events.damage_report_id
        and app_private.can_view_damage_report(
          damage_reports.godown_id,
          damage_reports.scenario,
          damage_reports.reporter_user_id,
          damage_reports.dispatch_id
        )
    )
  );

create policy damage_evidence_select on public.damage_evidence
  for select to authenticated
  using (
    exists (
      select 1
      from public.damage_reports
      where damage_reports.id = damage_evidence.damage_report_id
        and app_private.can_view_damage_report(
          damage_reports.godown_id,
          damage_reports.scenario,
          damage_reports.reporter_user_id,
          damage_reports.dispatch_id
        )
    )
  );

revoke all on function app_private.guard_damage_write() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_damage_report_identity() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_damage_events() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_damage_evidence() from public, anon, authenticated, service_role;
revoke all on function app_private.damage_stock_hold_ready() from public, anon, authenticated, service_role;
revoke all on function app_private.damage_requires_stock_hold(text) from public, anon, authenticated, service_role;
revoke all on function app_private.damage_stock_isolation_installed() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_damage_hold_configuration() from public, anon, authenticated, service_role;
revoke all on function app_private.apply_damage_stock_isolation(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_damage_create_auth(text, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.lock_damage_report(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_damage_version(public.damage_reports, integer) from public, anon, authenticated, service_role;
revoke all on function app_private.record_damage_event(uuid, text, text, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_crate_in_godown(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_optional_damage_lot(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.damage_open_receipt_qty(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.validate_damage_sources(text, uuid, uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.replace_damage_lines(uuid, text, uuid, uuid, uuid, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function app_private.damage_fingerprint(text, uuid, uuid, uuid, uuid, uuid, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function app_private.damage_report_payload(uuid) from public, anon, authenticated, service_role;

revoke all on function app_private.can_view_damage_report(uuid, text, uuid, uuid) from public, anon, service_role;
revoke all on function app_private.can_store_damage_photo(text) from public, anon, service_role;
revoke all on function app_private.can_read_damage_photo(text) from public, anon, service_role;

grant execute on function app_private.can_view_damage_report(uuid, text, uuid, uuid) to authenticated;
grant execute on function app_private.can_store_damage_photo(text) to authenticated;
grant execute on function app_private.can_read_damage_photo(text) to authenticated;

revoke all on function public.create_damage_report(text, uuid, jsonb, text, text, uuid, uuid, uuid, uuid, uuid) from public, anon, service_role;
revoke all on function public.update_damage_report(uuid, integer, jsonb, text, uuid, uuid, uuid, uuid, uuid) from public, anon, service_role;
revoke all on function public.submit_damage_report(uuid, integer, text) from public, anon, service_role;
revoke all on function public.return_damage_report(uuid, integer, text) from public, anon, service_role;
revoke all on function public.verify_damage_report(uuid, integer) from public, anon, service_role;
revoke all on function public.cancel_damage_report(uuid, integer, text) from public, anon, service_role;
revoke all on function public.reject_damage_report(uuid, integer, text) from public, anon, service_role;
revoke all on function public.get_damage_report(uuid) from public, anon, service_role;
revoke all on function public.list_damage_reports(integer, integer, uuid) from public, anon, service_role;
revoke all on function public.create_damage_photo_upload(uuid, text) from public, anon, service_role;
revoke all on function public.finalize_damage_photo_upload(uuid, text) from public, anon, service_role;
revoke all on function public.get_damage_photo_url(uuid) from public, anon, service_role;

grant execute on function public.create_damage_report(text, uuid, jsonb, text, text, uuid, uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.update_damage_report(uuid, integer, jsonb, text, uuid, uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.submit_damage_report(uuid, integer, text) to authenticated;
grant execute on function public.return_damage_report(uuid, integer, text) to authenticated;
grant execute on function public.verify_damage_report(uuid, integer) to authenticated;
grant execute on function public.cancel_damage_report(uuid, integer, text) to authenticated;
grant execute on function public.reject_damage_report(uuid, integer, text) to authenticated;
grant execute on function public.get_damage_report(uuid) to authenticated;
grant execute on function public.list_damage_reports(integer, integer, uuid) to authenticated;
grant execute on function public.create_damage_photo_upload(uuid, text) to authenticated;
grant execute on function public.finalize_damage_photo_upload(uuid, text) to authenticated;
grant execute on function public.get_damage_photo_url(uuid) to authenticated;

