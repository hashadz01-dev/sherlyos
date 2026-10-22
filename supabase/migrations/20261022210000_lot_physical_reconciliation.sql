-- M1-S2.2 physical stock reconciliation (local-first).
-- Evidence and Admin approval only. Does not mutate stock_balances, stock_ledger,
-- stock_lots, stock_lot_balances, or cutover flags. Does not seed lots.
-- apply_legacy_lot_attribution is deferred to M1-S3 (no stub RPC).

-- ---------------------------------------------------------------------------
-- Permission: GM + Admin record/submit. Admin create/approve/reject/cancel.
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values (
  'stock.lots.physical_reconcile',
  'Record and submit physical lot reconciliation for an assigned godown. Does not approve or change live stock.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'stock.lots.physical_reconcile'
where roles.code in ('admin', 'godown_manager')
on conflict do nothing;

create sequence public.stock_lot_reconciliation_seq as bigint;

revoke all on sequence public.stock_lot_reconciliation_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.stock_lot_reconciliations (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  session_number text not null,
  godown_id uuid not null references public.branches (id) on delete restrict,
  status text not null,
  version integer not null default 1,
  idempotency_key text not null,
  notes text,
  created_by uuid not null references public.profiles (id) on delete restrict,
  submitted_by uuid references public.profiles (id) on delete restrict,
  submitted_at timestamptz,
  reviewed_by uuid references public.profiles (id) on delete restrict,
  reviewed_at timestamptz,
  rejection_reason text,
  review_notes text,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  expected_frozen_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_lot_reconciliations_number_key unique (session_number),
  constraint stock_lot_reconciliations_idempotency_key unique (idempotency_key),
  constraint stock_lot_reconciliations_version_check check (version > 0),
  constraint stock_lot_reconciliations_status_check check (
    status in ('draft', 'submitted', 'approved', 'rejected', 'cancelled')
  ),
  constraint stock_lot_reconciliations_notes_check check (
    notes is null or pg_catalog.char_length(notes) between 1 and 500
  ),
  constraint stock_lot_reconciliations_rejection_check check (
    rejection_reason is null
    or pg_catalog.char_length(rejection_reason) between 1 and 500
  ),
  constraint stock_lot_reconciliations_review_notes_check check (
    review_notes is null
    or pg_catalog.char_length(review_notes) between 1 and 500
  ),
  constraint stock_lot_reconciliations_cancel_reason_check check (
    cancellation_reason is null
    or pg_catalog.char_length(cancellation_reason) between 1 and 500
  ),
  constraint stock_lot_reconciliations_submit_shape check (
    (
      submitted_by is null
      and submitted_at is null
    )
    or (
      submitted_by is not null
      and submitted_at is not null
    )
  ),
  constraint stock_lot_reconciliations_review_shape check (
    (
      reviewed_by is null
      and reviewed_at is null
    )
    or (
      reviewed_by is not null
      and reviewed_at is not null
    )
  ),
  constraint stock_lot_reconciliations_cancel_shape check (
    (
      status = 'cancelled'
      and cancelled_by is not null
      and cancelled_at is not null
      and cancellation_reason is not null
    )
    or (
      status <> 'cancelled'
      and cancelled_by is null
      and cancelled_at is null
      and cancellation_reason is null
    )
  )
);

create index stock_lot_reconciliations_godown_idx
  on public.stock_lot_reconciliations (godown_id, created_at desc);

create index stock_lot_reconciliations_status_idx
  on public.stock_lot_reconciliations (status, godown_id);

comment on table public.stock_lot_reconciliations is
  'M1-S2.2. Physical lot evidence session. Approval does not change inventory. Attribution is M1-S3.';

create table public.stock_lot_reconciliation_scope_crates (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  session_id uuid not null references public.stock_lot_reconciliations (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  holds_scope boolean not null default true,
  selected_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_lot_reconciliation_scope_crates_session_crate_key
    unique (session_id, crate_id)
);

-- D14: a crate cannot sit in two non-terminal sessions. Cancelled releases the hold.
create unique index stock_lot_reconciliation_scope_crates_held
  on public.stock_lot_reconciliation_scope_crates (crate_id)
  where holds_scope;

create index stock_lot_reconciliation_scope_crates_session_idx
  on public.stock_lot_reconciliation_scope_crates (session_id);

comment on table public.stock_lot_reconciliation_scope_crates is
  'Selected crates for a session. holds_scope stays true while draft/submitted/rejected/approved.';

create table public.stock_lot_reconciliation_lines (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  session_id uuid not null references public.stock_lot_reconciliations (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  expected_quantity integer not null,
  counted_quantity integer,
  counted_by uuid references public.profiles (id) on delete restrict,
  counted_at timestamptz,
  is_found_product boolean not null default false,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_lot_reconciliation_lines_grain_key
    unique (session_id, crate_id, product_id),
  constraint stock_lot_reconciliation_lines_expected_check
    check (expected_quantity >= 0 and expected_quantity <= 1000000),
  constraint stock_lot_reconciliation_lines_counted_check
    check (
      counted_quantity is null
      or (counted_quantity >= 0 and counted_quantity <= 1000000)
    ),
  constraint stock_lot_reconciliation_lines_count_actor_check check (
    (
      counted_quantity is null
      and counted_by is null
      and counted_at is null
    )
    or (
      counted_quantity is not null
      and counted_by is not null
      and counted_at is not null
    )
  ),
  constraint stock_lot_reconciliation_lines_found_check check (
    not is_found_product or expected_quantity = 0
  )
);

create index stock_lot_reconciliation_lines_session_idx
  on public.stock_lot_reconciliation_lines (session_id, crate_id, product_id);

comment on table public.stock_lot_reconciliation_lines is
  'Frozen expected carton cases plus physical count. Found products are discrepancy evidence only.';

create table public.stock_lot_reconciliation_lot_entries (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  line_id uuid not null references public.stock_lot_reconciliation_lines (id) on delete restrict,
  manufacturer_lot_code text,
  expiry_date date,
  expiry_unknown boolean not null,
  identity_unknown boolean not null,
  quantity integer not null,
  condition text not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_lot_reconciliation_lot_entries_qty_check
    check (quantity > 0 and quantity <= 1000000),
  constraint stock_lot_reconciliation_lot_entries_condition_check
    check (condition in ('available', 'quarantined', 'expired')),
  constraint stock_lot_reconciliation_lot_entries_identity_check check (
    (
      identity_unknown
      and manufacturer_lot_code is null
      and expiry_date is null
      and expiry_unknown
      and condition in ('available', 'quarantined')
    )
    or (
      not identity_unknown
      and manufacturer_lot_code is not null
      and pg_catalog.char_length(manufacturer_lot_code) between 1 and 80
      and manufacturer_lot_code = pg_catalog.btrim(manufacturer_lot_code)
    )
  ),
  constraint stock_lot_reconciliation_lot_entries_expiry_unknown_check check (
    (expiry_unknown and expiry_date is null)
    or (not expiry_unknown)
  ),
  constraint stock_lot_reconciliation_lot_entries_expired_check check (
    condition <> 'expired' or expiry_date is not null
  )
);

create unique index stock_lot_reconciliation_lot_entries_identity
  on public.stock_lot_reconciliation_lot_entries (
    line_id,
    manufacturer_lot_code,
    expiry_date,
    identity_unknown
  )
  nulls not distinct;

create index stock_lot_reconciliation_lot_entries_line_idx
  on public.stock_lot_reconciliation_lot_entries (line_id);

comment on table public.stock_lot_reconciliation_lot_entries is
  'Physical lot breakdown for a counted grain. Unknown identity is explicit; codes and dates are never invented.';

create table public.stock_lot_reconciliation_events (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  session_id uuid not null references public.stock_lot_reconciliations (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  from_status text,
  to_status text not null,
  session_version integer not null,
  idempotency_key text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_lot_reconciliation_events_type_check check (
    event_type in (
      'created',
      'scope_assigned',
      'count_saved',
      'lots_saved',
      'found_product_added',
      'expected_refreshed',
      'submitted',
      'approved',
      'rejected',
      'reopened',
      'cancelled'
    )
  ),
  constraint stock_lot_reconciliation_events_version_check check (session_version > 0)
);

create unique index stock_lot_reconciliation_events_idempotency
  on public.stock_lot_reconciliation_events (idempotency_key)
  where idempotency_key is not null;

create index stock_lot_reconciliation_events_session_idx
  on public.stock_lot_reconciliation_events (session_id, created_at);

comment on table public.stock_lot_reconciliation_events is
  'Append-only reconciliation history. Clients cannot insert, update, or delete rows.';

-- ---------------------------------------------------------------------------
-- Write guards: clients have SELECT only; RPCs set a transaction GUC.
-- ---------------------------------------------------------------------------

create or replace function app_private.guard_lot_reconciliation_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('app.lot_reconciliation_write', true) is distinct from 'on' then
    raise exception 'lot reconciliation records cannot be changed directly'
      using errcode = '42501';
  end if;

  if tg_table_name = 'stock_lot_reconciliation_events' and tg_op <> 'INSERT' then
    raise exception 'lot reconciliation history cannot be changed' using errcode = '42501';
  end if;

  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_lot_reconciliation_write()
  from public, anon, authenticated, service_role;

create trigger stock_lot_reconciliations_guard
  before insert or update or delete on public.stock_lot_reconciliations
  for each row execute function app_private.guard_lot_reconciliation_write();

create trigger stock_lot_reconciliation_scope_crates_guard
  before insert or update or delete on public.stock_lot_reconciliation_scope_crates
  for each row execute function app_private.guard_lot_reconciliation_write();

create trigger stock_lot_reconciliation_lines_guard
  before insert or update or delete on public.stock_lot_reconciliation_lines
  for each row execute function app_private.guard_lot_reconciliation_write();

create trigger stock_lot_reconciliation_lot_entries_guard
  before insert or update or delete on public.stock_lot_reconciliation_lot_entries
  for each row execute function app_private.guard_lot_reconciliation_write();

create trigger stock_lot_reconciliation_events_guard
  before insert or update or delete on public.stock_lot_reconciliation_events
  for each row execute function app_private.guard_lot_reconciliation_write();

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.can_view_lot_reconciliation(target_godown uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    (
      app_private.has_permission('stock.lots.physical_reconcile')
      or app_private.has_permission('stock.lots.legacy.reconcile')
      or app_private.has_permission('operations.monitor')
    )
    and (
      app_private.has_permission('operations.monitor')
      or app_private.can_work_at_branch(target_godown)
    );
$$;

revoke all on function app_private.can_view_lot_reconciliation(uuid)
  from public, anon, service_role;
grant execute on function app_private.can_view_lot_reconciliation(uuid)
  to authenticated;

create or replace function app_private.assert_lot_reconciliation_reader()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
    or not (
      app_private.has_permission('stock.lots.physical_reconcile')
      or app_private.has_permission('stock.lots.legacy.reconcile')
      or app_private.has_permission('operations.monitor')
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_lot_reconciliation_reader()
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_reconciliation_editor(target_godown uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.lots.physical_reconcile');
  if not app_private.can_work_at_branch(target_godown) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_lot_reconciliation_editor(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_reconciliation_admin(target_godown uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.lots.legacy.reconcile');
  if not app_private.can_work_at_branch(target_godown) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_lot_reconciliation_admin(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_lot_reconciliation(
  target_session uuid,
  expected_version integer
)
returns public.stock_lot_reconciliations
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
begin
  perform set_config('app.lot_reconciliation_write', 'on', true);

  select *
  into selected
  from public.stock_lot_reconciliations
  where stock_lot_reconciliations.id = target_session
  for update;

  if not found or not app_private.can_view_lot_reconciliation(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'lot reconciliation was changed by someone else' using errcode = 'PT409';
  end if;

  return selected;
end;
$$;

revoke all on function app_private.lock_lot_reconciliation(uuid, integer)
  from public, anon, authenticated, service_role;

create or replace function app_private.lot_reconciliation_event(
  target_session uuid,
  event_name text,
  from_status text,
  to_status text,
  session_version integer,
  event_payload jsonb,
  event_key text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.stock_lot_reconciliation_events (
    session_id,
    event_type,
    actor_id,
    from_status,
    to_status,
    session_version,
    idempotency_key,
    payload
  )
  values (
    target_session,
    event_name,
    auth.uid(),
    from_status,
    to_status,
    session_version,
    event_key,
    coalesce(event_payload, '{}'::jsonb)
  );
end;
$$;

revoke all on function app_private.lot_reconciliation_event(uuid, text, text, text, integer, jsonb, text)
  from public, anon, authenticated, service_role;

create or replace function app_private.replay_lot_reconciliation_event(
  cleaned_key text,
  expected_type text,
  expected_session uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.stock_lot_reconciliation_events;
begin
  if cleaned_key is null then
    return null;
  end if;

  select *
  into existing
  from public.stock_lot_reconciliation_events
  where stock_lot_reconciliation_events.idempotency_key = cleaned_key;

  if not found then
    return null;
  end if;

  if existing.event_type is distinct from expected_type
    or existing.session_id is distinct from expected_session
  then
    raise exception 'idempotency key does not match the original request'
      using errcode = '23514';
  end if;

  return existing.session_id;
end;
$$;

revoke all on function app_private.replay_lot_reconciliation_event(text, text, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.lot_reconciliation_crate_ids(target_session uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.array_agg(crate_id order by crate_id), '{}'::uuid[])
  from public.stock_lot_reconciliation_scope_crates
  where session_id = target_session;
$$;

revoke all on function app_private.lot_reconciliation_crate_ids(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_lot_reconciliation_inventory(target_session uuid)
returns uuid[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  crate_ids uuid[];
begin
  -- Shared advisory first so this never upgrades into the exclusive seed/flag lock.
  perform app_private.acquire_stock_cutover_shared_lock();

  crate_ids := app_private.lot_reconciliation_crate_ids(target_session);

  perform crates.id
  from public.crates
  where crates.id = any (crate_ids)
  order by crates.id
  for update;

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  return crate_ids;
end;
$$;

revoke all on function app_private.lock_lot_reconciliation_inventory(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_reconciliation_baseline(
  target_session uuid,
  crate_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Live aggregate must still equal the frozen expected grain set and quantities.
  if exists (
    select 1
    from public.stock_lot_reconciliation_lines
    left join public.stock_balances
      on stock_balances.crate_id = stock_lot_reconciliation_lines.crate_id
     and stock_balances.product_id = stock_lot_reconciliation_lines.product_id
    where stock_lot_reconciliation_lines.session_id = target_session
      and coalesce(stock_balances.quantity, 0)
        is distinct from stock_lot_reconciliation_lines.expected_quantity
  ) then
    raise exception 'stock baseline changed; refresh expected quantities and recount'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_balances
    where stock_balances.crate_id = any (crate_ids)
      and stock_balances.quantity > 0
      and not exists (
        select 1
        from public.stock_lot_reconciliation_lines
        where stock_lot_reconciliation_lines.session_id = target_session
          and stock_lot_reconciliation_lines.crate_id = stock_balances.crate_id
          and stock_lot_reconciliation_lines.product_id = stock_balances.product_id
      )
  ) then
    raise exception 'stock baseline changed; refresh expected quantities and recount'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_lot_reconciliation_baseline(uuid, uuid[])
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_reconciliation_counts_complete(target_session uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  lot_sum integer;
  line record;
begin
  if exists (
    select 1
    from public.stock_lot_reconciliation_lines
    where session_id = target_session
      and counted_quantity is null
  ) then
    raise exception 'every reconciliation line must be counted' using errcode = '23514';
  end if;

  for line in
    select *
    from public.stock_lot_reconciliation_lines
    where session_id = target_session
  loop
    select coalesce(sum(quantity), 0)::integer
    into lot_sum
    from public.stock_lot_reconciliation_lot_entries
    where line_id = line.id;

    if line.counted_quantity = 0 then
      if lot_sum <> 0 then
        raise exception 'zero-count lines cannot hold lot entries' using errcode = '23514';
      end if;
    elsif lot_sum is distinct from line.counted_quantity then
      raise exception 'lot quantities must equal the counted carton cases'
        using errcode = '23514';
    end if;
  end loop;
end;
$$;

revoke all on function app_private.assert_lot_reconciliation_counts_complete(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_reconciliation_matched(target_session uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.stock_lot_reconciliation_lines
    where session_id = target_session
      and counted_quantity is distinct from expected_quantity
  ) then
    raise exception 'reconciliation has unresolved quantity discrepancies'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_lot_reconciliation_matched(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_reconciliation_classified(target_session uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.stock_lot_reconciliation_lines
    join public.products on products.id = stock_lot_reconciliation_lines.product_id
    where stock_lot_reconciliation_lines.session_id = target_session
      and products.expiry_policy is distinct from 'expiry_controlled'
      and products.expiry_policy is distinct from 'non_expiring'
  ) then
    raise exception 'every product in the session must have an expiry classification'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_lot_reconciliation_classified(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.replace_lot_reconciliation_lots(
  selected_line public.stock_lot_reconciliation_lines,
  lots jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  product_policy text;
  item jsonb;
  identity_unknown boolean;
  expiry_unknown boolean;
  manufacturer_code text;
  expiry date;
  qty integer;
  lot_condition text;
  lot_sum integer := 0;
begin
  if selected_line.counted_quantity is null then
    raise exception 'count the grain before recording lots' using errcode = '23514';
  end if;

  if lots is null or pg_catalog.jsonb_typeof(lots) is distinct from 'array' then
    raise exception 'lot entries must be an array' using errcode = '23514';
  end if;

  select products.expiry_policy
  into product_policy
  from public.products
  where products.id = selected_line.product_id;

  delete from public.stock_lot_reconciliation_lot_entries
  where line_id = selected_line.id;

  if selected_line.counted_quantity = 0 then
    if pg_catalog.jsonb_array_length(lots) > 0 then
      raise exception 'zero-count lines cannot hold lot entries' using errcode = '23514';
    end if;
    return;
  end if;

  if pg_catalog.jsonb_array_length(lots) < 1 then
    raise exception 'lot quantities must equal the counted carton cases'
      using errcode = '23514';
  end if;

  for item in
    select value
    from pg_catalog.jsonb_array_elements(lots)
  loop
    if pg_catalog.jsonb_typeof(item) is distinct from 'object' then
      raise exception 'lot entry is invalid' using errcode = '23514';
    end if;

    identity_unknown := coalesce((item ->> 'identity_unknown')::boolean, false);
    expiry_unknown := coalesce((item ->> 'expiry_unknown')::boolean, false);
    manufacturer_code := pg_catalog.btrim(coalesce(item ->> 'manufacturer_lot_code', ''));
    lot_condition := pg_catalog.lower(pg_catalog.btrim(coalesce(item ->> 'condition', 'available')));
    qty := (item ->> 'quantity')::integer;

    if item ->> 'expiry_date' is null or pg_catalog.btrim(item ->> 'expiry_date') = '' then
      expiry := null;
    else
      expiry := (item ->> 'expiry_date')::date;
    end if;

    if identity_unknown then
      manufacturer_code := null;
      expiry := null;
      expiry_unknown := true;
      if lot_condition not in ('available', 'quarantined') then
        raise exception 'unknown-identity lots cannot be marked expired without a date'
          using errcode = '23514';
      end if;
    else
      if manufacturer_code = '' then
        raise exception 'manufacturer lot code is required unless identity is unknown'
          using errcode = '23514';
      end if;
      if pg_catalog.char_length(manufacturer_code) > 80 then
        raise exception 'manufacturer lot code is too long' using errcode = '23514';
      end if;
    end if;

    if expiry_unknown then
      expiry := null;
    end if;

    if lot_condition not in ('available', 'quarantined', 'expired') then
      raise exception 'lot condition is invalid' using errcode = '23514';
    end if;

    if lot_condition = 'expired' and expiry is null then
      raise exception 'expired lots require an expiry date' using errcode = '23514';
    end if;

    if expiry is not null and expiry < (pg_catalog.now())::date and lot_condition is distinct from 'expired' then
      raise exception 'past-expiry stock must be recorded as expired' using errcode = '23514';
    end if;

    if lot_condition = 'expired' and (expiry is null or expiry >= (pg_catalog.now())::date) then
      raise exception 'expired condition requires a past expiry date' using errcode = '23514';
    end if;

    -- Unknown identity still records expiry_unknown; do not invent a date.
    if product_policy = 'non_expiring' then
      if expiry is not null then
        raise exception 'non-expiring products cannot carry expiry dates'
          using errcode = '23514';
      end if;
      if expiry_unknown and not identity_unknown then
        raise exception 'non-expiring products cannot carry expiry values'
          using errcode = '23514';
      end if;
    end if;

    if product_policy = 'expiry_controlled' and not identity_unknown and not expiry_unknown and expiry is null then
      raise exception 'expiry-controlled lots need an expiry date or an explicit unknown expiry'
        using errcode = '23514';
    end if;

    insert into public.stock_lot_reconciliation_lot_entries (
      line_id,
      manufacturer_lot_code,
      expiry_date,
      expiry_unknown,
      identity_unknown,
      quantity,
      condition
    )
    values (
      selected_line.id,
      manufacturer_code,
      expiry,
      expiry_unknown,
      identity_unknown,
      qty,
      lot_condition
    );

    lot_sum := lot_sum + qty;
  end loop;

  if lot_sum is distinct from selected_line.counted_quantity then
    raise exception 'lot quantities must equal the counted carton cases'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.replace_lot_reconciliation_lots(public.stock_lot_reconciliation_lines, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.lot_reconciliation_payload(target_session uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_lot_reconciliations;
  unmatched integer;
  uncounted integer;
  found_count integer;
  unidentified integer;
  unclassified integer;
begin
  perform app_private.assert_lot_reconciliation_reader();

  select *
  into header
  from public.stock_lot_reconciliations
  where id = target_session;

  if not found or not app_private.can_view_lot_reconciliation(header.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select
    count(*) filter (
      where counted_quantity is not null
        and counted_quantity is distinct from expected_quantity
    ),
    count(*) filter (where counted_quantity is null),
    count(*) filter (where is_found_product)
  into unmatched, uncounted, found_count
  from public.stock_lot_reconciliation_lines
  where session_id = header.id;

  select coalesce(sum(lot_entries.quantity), 0)::integer
  into unidentified
  from public.stock_lot_reconciliation_lot_entries lot_entries
  join public.stock_lot_reconciliation_lines lines on lines.id = lot_entries.line_id
  where lines.session_id = header.id
    and lot_entries.identity_unknown;

  select count(distinct products.id)::integer
  into unclassified
  from public.stock_lot_reconciliation_lines
  join public.products on products.id = stock_lot_reconciliation_lines.product_id
  where stock_lot_reconciliation_lines.session_id = header.id
    and products.expiry_policy is distinct from 'expiry_controlled'
    and products.expiry_policy is distinct from 'non_expiring';

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'session_number', header.session_number,
    'godown_id', header.godown_id,
    'status', header.status,
    'version', header.version,
    'notes', header.notes,
    'created_by', header.created_by,
    'submitted_by', header.submitted_by,
    'submitted_at', header.submitted_at,
    'reviewed_by', header.reviewed_by,
    'reviewed_at', header.reviewed_at,
    'rejection_reason', header.rejection_reason,
    'review_notes', header.review_notes,
    'cancelled_by', header.cancelled_by,
    'cancelled_at', header.cancelled_at,
    'cancellation_reason', header.cancellation_reason,
    'expected_frozen_at', header.expected_frozen_at,
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'discrepancy', pg_catalog.jsonb_build_object(
      'uncounted_lines', uncounted,
      'unmatched_lines', unmatched,
      'found_product_lines', found_count,
      'unidentified_cases', unidentified,
      'unclassified_products', unclassified
    ),
    'crates', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'crate_id', crates.id,
        'crate_code', crates.code,
        'crate_name', crates.name,
        'zone_id', zones.id,
        'zone_code', zones.code,
        'holds_scope', scope_crates.holds_scope
      ) order by zones.code, crates.code)
      from public.stock_lot_reconciliation_scope_crates scope_crates
      join public.crates on crates.id = scope_crates.crate_id
      join public.zones on zones.id = crates.zone_id
      where scope_crates.session_id = header.id
    ), '[]'::jsonb),
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', lines.id,
        'crate_id', lines.crate_id,
        'product_id', lines.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'expiry_policy', products.expiry_policy,
        'expected_quantity', lines.expected_quantity,
        'counted_quantity', lines.counted_quantity,
        'is_found_product', lines.is_found_product,
        'counted_by', lines.counted_by,
        'counted_at', lines.counted_at,
        'lots', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id', lot_entries.id,
            'manufacturer_lot_code', lot_entries.manufacturer_lot_code,
            'expiry_date', lot_entries.expiry_date,
            'expiry_unknown', lot_entries.expiry_unknown,
            'identity_unknown', lot_entries.identity_unknown,
            'quantity', lot_entries.quantity,
            'condition', lot_entries.condition
          ) order by lot_entries.created_at, lot_entries.id)
          from public.stock_lot_reconciliation_lot_entries lot_entries
          where lot_entries.line_id = lines.id
        ), '[]'::jsonb)
      ) order by products.sku, lines.crate_id)
      from public.stock_lot_reconciliation_lines lines
      join public.products on products.id = lines.product_id
      where lines.session_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', events.id,
        'event_type', events.event_type,
        'actor_id', events.actor_id,
        'from_status', events.from_status,
        'to_status', events.to_status,
        'session_version', events.session_version,
        'payload', events.payload,
        'created_at', events.created_at
      ) order by events.created_at, events.id)
      from public.stock_lot_reconciliation_events events
      where events.session_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.lot_reconciliation_payload(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.snapshot_lot_reconciliation_lines(
  target_session uuid,
  crate_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.stock_lot_reconciliation_lines (
    session_id, crate_id, product_id, expected_quantity, is_found_product
  )
  select
    target_session,
    stock_balances.crate_id,
    stock_balances.product_id,
    stock_balances.quantity,
    false
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
    and stock_balances.quantity > 0
  order by stock_balances.crate_id, stock_balances.product_id;
end;
$$;

revoke all on function app_private.snapshot_lot_reconciliation_lines(uuid, uuid[])
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Public RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_lot_reconciliation(
  target_godown uuid,
  crate_ids uuid[],
  idempotency_key text,
  session_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  existing public.stock_lot_reconciliations;
  selected_branch uuid;
  created_id uuid;
  snapshot_time timestamptz;
  session_number text;
begin
  perform set_config('app.lot_reconciliation_write', 'on', true);
  perform app_private.assert_lot_reconciliation_admin(target_godown);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_verification_text(session_notes, false);

  select *
  into existing
  from public.stock_lot_reconciliations
  where stock_lot_reconciliations.idempotency_key = cleaned_key;

  if found then
    if not app_private.can_view_lot_reconciliation(existing.godown_id) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if existing.godown_id is distinct from target_godown
      or not app_private.same_uuid_set(
        app_private.lot_reconciliation_crate_ids(existing.id),
        crate_ids
      )
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return app_private.lot_reconciliation_payload(existing.id);
  end if;

  perform app_private.assert_distinct_ids(crate_ids, 'crate');
  selected_branch := app_private.prepare_stock_locations(crate_ids);
  if selected_branch is distinct from target_godown then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform stock_lot_reconciliation_scope_crates.crate_id
  from public.stock_lot_reconciliation_scope_crates
  where stock_lot_reconciliation_scope_crates.crate_id = any (crate_ids)
    and stock_lot_reconciliation_scope_crates.holds_scope
  order by stock_lot_reconciliation_scope_crates.crate_id
  for update;

  if exists (
    select 1
    from public.stock_lot_reconciliation_scope_crates
    where crate_id = any (crate_ids)
      and holds_scope
  ) then
    raise exception 'an overlapping lot reconciliation already holds these crates'
      using errcode = '23505';
  end if;

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  snapshot_time := pg_catalog.clock_timestamp();
  session_number :=
    'LR-'
    || pg_catalog.to_char(snapshot_time at time zone 'utc', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(
      pg_catalog.nextval('public.stock_lot_reconciliation_seq')::text,
      6,
      '0'
    );

  insert into public.stock_lot_reconciliations (
    session_number,
    godown_id,
    status,
    idempotency_key,
    notes,
    created_by,
    expected_frozen_at
  )
  values (
    session_number,
    target_godown,
    'draft',
    cleaned_key,
    cleaned_notes,
    auth.uid(),
    snapshot_time
  )
  returning id into created_id;

  insert into public.stock_lot_reconciliation_scope_crates (session_id, crate_id, holds_scope)
  select created_id, crates.id, true
  from public.crates
  where crates.id = any (crate_ids)
  order by crates.id;

  perform app_private.snapshot_lot_reconciliation_lines(created_id, crate_ids);

  perform app_private.lot_reconciliation_event(
    created_id, 'created', null, 'draft', 1,
    pg_catalog.jsonb_build_object('crate_count', pg_catalog.cardinality(crate_ids)),
    null
  );
  perform app_private.lot_reconciliation_event(
    created_id, 'scope_assigned', null, 'draft', 1,
    pg_catalog.jsonb_build_object('crate_ids', crate_ids),
    null
  );
  perform app_private.write_audit(
    auth.uid(),
    'create_lot_reconciliation',
    'stock_lot_reconciliations',
    created_id,
    pg_catalog.jsonb_build_object(
      'godown_id', target_godown,
      'crate_count', pg_catalog.cardinality(crate_ids)
    )
  );

  return app_private.lot_reconciliation_payload(created_id);
exception
  when unique_violation then
    select *
    into existing
    from public.stock_lot_reconciliations
    where stock_lot_reconciliations.idempotency_key = cleaned_key;

    if found then
      if not app_private.can_view_lot_reconciliation(existing.godown_id) then
        raise exception 'not authorized' using errcode = '42501';
      end if;
      if existing.godown_id is distinct from target_godown
        or not app_private.same_uuid_set(
          app_private.lot_reconciliation_crate_ids(existing.id),
          crate_ids
        )
      then
        raise exception 'idempotency key does not match the original request'
          using errcode = '23514';
      end if;
      return app_private.lot_reconciliation_payload(existing.id);
    end if;

    raise exception 'an overlapping lot reconciliation already holds these crates'
      using errcode = '23505';
end;
$$;

create or replace function public.list_lot_reconciliations()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_lot_reconciliation_reader();

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', header.id,
      'session_number', header.session_number,
      'godown_id', header.godown_id,
      'status', header.status,
      'version', header.version,
      'created_at', header.created_at,
      'submitted_at', header.submitted_at,
      'unmatched_lines', (
        select count(*)
        from public.stock_lot_reconciliation_lines
        where session_id = header.id
          and counted_quantity is not null
          and counted_quantity is distinct from expected_quantity
      )
    ) order by header.created_at desc)
    from public.stock_lot_reconciliations header
    where app_private.can_view_lot_reconciliation(header.godown_id)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_lot_reconciliation(target_session uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return app_private.lot_reconciliation_payload(target_session);
end;
$$;

create or replace function public.save_lot_reconciliation_count(
  target_session uuid,
  expected_version integer,
  target_crate uuid,
  target_product uuid,
  counted_quantity integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  selected_line public.stock_lot_reconciliation_lines;
begin
  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_editor(selected.godown_id);

  if selected.status <> 'draft' then
    raise exception 'only a draft reconciliation can be counted' using errcode = '42501';
  end if;

  if counted_quantity is null or counted_quantity < 0 or counted_quantity > 1000000 then
    raise exception 'quantity must be a whole number of carton cases from 0 to 1000000'
      using errcode = '23514';
  end if;

  select *
  into selected_line
  from public.stock_lot_reconciliation_lines
  where session_id = selected.id
    and crate_id = target_crate
    and product_id = target_product
  for update;

  if not found then
    raise exception 'reconciliation line not found' using errcode = '23514';
  end if;

  if selected_line.counted_quantity is distinct from counted_quantity then
    delete from public.stock_lot_reconciliation_lot_entries
    where line_id = selected_line.id;
  end if;

  update public.stock_lot_reconciliation_lines
  set
    counted_quantity = save_lot_reconciliation_count.counted_quantity,
    counted_by = auth.uid(),
    counted_at = pg_catalog.clock_timestamp(),
    updated_at = pg_catalog.clock_timestamp()
  where id = selected_line.id;

  update public.stock_lot_reconciliations
  set
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id,
    'count_saved',
    selected.status,
    selected.status,
    selected.version + 1,
    pg_catalog.jsonb_build_object(
      'line_id', selected_line.id,
      'counted_quantity', counted_quantity
    ),
    null
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.save_lot_reconciliation_lots(
  target_session uuid,
  expected_version integer,
  target_line uuid,
  lots jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  selected_line public.stock_lot_reconciliation_lines;
begin
  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_editor(selected.godown_id);

  if selected.status <> 'draft' then
    raise exception 'only a draft reconciliation can record lots' using errcode = '42501';
  end if;

  select *
  into selected_line
  from public.stock_lot_reconciliation_lines
  where id = target_line
    and session_id = selected.id
  for update;

  if not found then
    raise exception 'reconciliation line not found' using errcode = '23514';
  end if;

  perform app_private.replace_lot_reconciliation_lots(selected_line, lots);

  update public.stock_lot_reconciliations
  set
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id,
    'lots_saved',
    selected.status,
    selected.status,
    selected.version + 1,
    pg_catalog.jsonb_build_object('line_id', selected_line.id),
    null
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.add_lot_reconciliation_found_product(
  target_session uuid,
  expected_version integer,
  target_crate uuid,
  target_product uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  live_qty integer;
  product_active boolean;
begin
  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_editor(selected.godown_id);

  if selected.status <> 'draft' then
    raise exception 'only a draft reconciliation can add found products'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.stock_lot_reconciliation_scope_crates
    where session_id = selected.id
      and crate_id = target_crate
  ) then
    raise exception 'crate is outside the session scope' using errcode = '23514';
  end if;

  select products.is_active
  into product_active
  from public.products
  where products.id = target_product;

  if product_active is not true then
    raise exception 'product not found' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.stock_lot_reconciliation_lines
    where session_id = selected.id
      and crate_id = target_crate
      and product_id = target_product
  ) then
    raise exception 'reconciliation line already exists' using errcode = '23514';
  end if;

  select coalesce(stock_balances.quantity, 0)
  into live_qty
  from public.stock_balances
  where crate_id = target_crate
    and product_id = target_product;

  if coalesce(live_qty, 0) > 0 then
    raise exception 'product already has expected stock on this crate'
      using errcode = '23514';
  end if;

  insert into public.stock_lot_reconciliation_lines (
    session_id, crate_id, product_id, expected_quantity, is_found_product
  )
  values (selected.id, target_crate, target_product, 0, true);

  update public.stock_lot_reconciliations
  set
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id,
    'found_product_added',
    selected.status,
    selected.status,
    selected.version + 1,
    pg_catalog.jsonb_build_object(
      'crate_id', target_crate,
      'product_id', target_product
    ),
    null
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.refresh_lot_reconciliation_expected(
  target_session uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  crate_ids uuid[];
begin
  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_editor(selected.godown_id);

  if selected.status <> 'draft' then
    raise exception 'expected quantities can only be refreshed in draft'
      using errcode = '42501';
  end if;

  crate_ids := app_private.lock_lot_reconciliation_inventory(selected.id);

  delete from public.stock_lot_reconciliation_lot_entries
  where line_id in (
    select id
    from public.stock_lot_reconciliation_lines
    where session_id = selected.id
  );

  delete from public.stock_lot_reconciliation_lines
  where session_id = selected.id;

  perform app_private.snapshot_lot_reconciliation_lines(selected.id, crate_ids);

  update public.stock_lot_reconciliations
  set
    version = selected.version + 1,
    expected_frozen_at = pg_catalog.clock_timestamp(),
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id,
    'expected_refreshed',
    selected.status,
    selected.status,
    selected.version + 1,
    pg_catalog.jsonb_build_object('crate_count', pg_catalog.cardinality(crate_ids)),
    null
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.submit_lot_reconciliation(
  target_session uuid,
  expected_version integer,
  idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  cleaned_key text;
  replay uuid;
  crate_ids uuid[];
begin
  if idempotency_key is not null then
    cleaned_key := app_private.clean_idempotency_key(idempotency_key);
    replay := app_private.replay_lot_reconciliation_event(
      cleaned_key, 'submitted', target_session
    );
    if replay is not null then
      return app_private.lot_reconciliation_payload(replay);
    end if;
  end if;

  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_editor(selected.godown_id);

  if selected.status <> 'draft' then
    raise exception 'reconciliation cannot be submitted' using errcode = '42501';
  end if;

  crate_ids := app_private.lock_lot_reconciliation_inventory(selected.id);
  perform app_private.assert_lot_reconciliation_baseline(selected.id, crate_ids);
  perform app_private.assert_lot_reconciliation_counts_complete(selected.id);

  update public.stock_lot_reconciliations
  set
    status = 'submitted',
    submitted_by = auth.uid(),
    submitted_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id, 'submitted', 'draft', 'submitted', selected.version + 1,
    '{}'::jsonb, cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'submit_lot_reconciliation',
    'stock_lot_reconciliations',
    selected.id,
    pg_catalog.jsonb_build_object('version', selected.version + 1)
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.approve_lot_reconciliation(
  target_session uuid,
  expected_version integer,
  review_notes text default null,
  idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  cleaned_key text;
  cleaned_notes text;
  replay uuid;
  crate_ids uuid[];
begin
  if idempotency_key is not null then
    cleaned_key := app_private.clean_idempotency_key(idempotency_key);
    replay := app_private.replay_lot_reconciliation_event(
      cleaned_key, 'approved', target_session
    );
    if replay is not null then
      return app_private.lot_reconciliation_payload(replay);
    end if;
  end if;

  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_admin(selected.godown_id);
  cleaned_notes := app_private.clean_verification_text(review_notes, false);

  if selected.status <> 'submitted' then
    raise exception 'reconciliation cannot be approved' using errcode = '42501';
  end if;

  if auth.uid() is not distinct from selected.submitted_by then
    raise exception 'you cannot approve your own reconciliation' using errcode = '42501';
  end if;

  crate_ids := app_private.lock_lot_reconciliation_inventory(selected.id);
  perform app_private.assert_lot_reconciliation_baseline(selected.id, crate_ids);
  perform app_private.assert_lot_reconciliation_counts_complete(selected.id);
  perform app_private.assert_lot_reconciliation_matched(selected.id);
  perform app_private.assert_lot_reconciliation_classified(selected.id);

  update public.stock_lot_reconciliations
  set
    status = 'approved',
    reviewed_by = auth.uid(),
    reviewed_at = pg_catalog.clock_timestamp(),
    review_notes = cleaned_notes,
    rejection_reason = null,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id, 'approved', 'submitted', 'approved', selected.version + 1,
    pg_catalog.jsonb_build_object('review_notes', cleaned_notes),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'approve_lot_reconciliation',
    'stock_lot_reconciliations',
    selected.id,
    pg_catalog.jsonb_build_object('version', selected.version + 1)
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.reject_lot_reconciliation(
  target_session uuid,
  expected_version integer,
  reject_reason text,
  idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  cleaned_key text;
  cleaned_reason text;
  replay uuid;
begin
  if idempotency_key is not null then
    cleaned_key := app_private.clean_idempotency_key(idempotency_key);
    replay := app_private.replay_lot_reconciliation_event(
      cleaned_key, 'rejected', target_session
    );
    if replay is not null then
      return app_private.lot_reconciliation_payload(replay);
    end if;
  end if;

  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_admin(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(reject_reason, true);

  if selected.status <> 'submitted' then
    raise exception 'reconciliation cannot be rejected' using errcode = '42501';
  end if;

  update public.stock_lot_reconciliations
  set
    status = 'rejected',
    reviewed_by = auth.uid(),
    reviewed_at = pg_catalog.clock_timestamp(),
    rejection_reason = cleaned_reason,
    review_notes = null,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id, 'rejected', 'submitted', 'rejected', selected.version + 1,
    pg_catalog.jsonb_build_object('rejection_reason', cleaned_reason),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'reject_lot_reconciliation',
    'stock_lot_reconciliations',
    selected.id,
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.reopen_lot_reconciliation(
  target_session uuid,
  expected_version integer,
  idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  cleaned_key text;
  replay uuid;
begin
  if idempotency_key is not null then
    cleaned_key := app_private.clean_idempotency_key(idempotency_key);
    replay := app_private.replay_lot_reconciliation_event(
      cleaned_key, 'reopened', target_session
    );
    if replay is not null then
      return app_private.lot_reconciliation_payload(replay);
    end if;
  end if;

  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_editor(selected.godown_id);

  if selected.status <> 'rejected' then
    raise exception 'only a rejected reconciliation can be reopened' using errcode = '42501';
  end if;

  update public.stock_lot_reconciliations
  set
    status = 'draft',
    submitted_by = null,
    submitted_at = null,
    reviewed_by = null,
    reviewed_at = null,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id, 'reopened', 'rejected', 'draft', selected.version + 1,
    '{}'::jsonb, cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'reopen_lot_reconciliation',
    'stock_lot_reconciliations',
    selected.id,
    '{}'::jsonb
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

create or replace function public.cancel_lot_reconciliation(
  target_session uuid,
  expected_version integer,
  cancel_reason text,
  idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  cleaned_key text;
  cleaned_reason text;
  replay uuid;
begin
  if idempotency_key is not null then
    cleaned_key := app_private.clean_idempotency_key(idempotency_key);
    replay := app_private.replay_lot_reconciliation_event(
      cleaned_key, 'cancelled', target_session
    );
    if replay is not null then
      return app_private.lot_reconciliation_payload(replay);
    end if;
  end if;

  selected := app_private.lock_lot_reconciliation(target_session, expected_version);
  perform app_private.assert_lot_reconciliation_admin(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(cancel_reason, true);

  if selected.status not in ('draft', 'rejected') then
    raise exception 'reconciliation cannot be cancelled' using errcode = '42501';
  end if;

  update public.stock_lot_reconciliation_scope_crates
  set holds_scope = false
  where session_id = selected.id
    and holds_scope;

  update public.stock_lot_reconciliations
  set
    status = 'cancelled',
    cancelled_by = auth.uid(),
    cancelled_at = pg_catalog.clock_timestamp(),
    cancellation_reason = cleaned_reason,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id, 'cancelled', selected.status, 'cancelled', selected.version + 1,
    pg_catalog.jsonb_build_object('cancellation_reason', cleaned_reason),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'cancel_lot_reconciliation',
    'stock_lot_reconciliations',
    selected.id,
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );

  return app_private.lot_reconciliation_payload(selected.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants, RLS
-- ---------------------------------------------------------------------------

revoke all on function public.create_lot_reconciliation(uuid, uuid[], text, text)
  from public, anon, service_role;
revoke all on function public.list_lot_reconciliations()
  from public, anon, service_role;
revoke all on function public.get_lot_reconciliation(uuid)
  from public, anon, service_role;
revoke all on function public.save_lot_reconciliation_count(uuid, integer, uuid, uuid, integer)
  from public, anon, service_role;
revoke all on function public.save_lot_reconciliation_lots(uuid, integer, uuid, jsonb)
  from public, anon, service_role;
revoke all on function public.add_lot_reconciliation_found_product(uuid, integer, uuid, uuid)
  from public, anon, service_role;
revoke all on function public.refresh_lot_reconciliation_expected(uuid, integer)
  from public, anon, service_role;
revoke all on function public.submit_lot_reconciliation(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.approve_lot_reconciliation(uuid, integer, text, text)
  from public, anon, service_role;
revoke all on function public.reject_lot_reconciliation(uuid, integer, text, text)
  from public, anon, service_role;
revoke all on function public.reopen_lot_reconciliation(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.cancel_lot_reconciliation(uuid, integer, text, text)
  from public, anon, service_role;

grant execute on function public.create_lot_reconciliation(uuid, uuid[], text, text)
  to authenticated;
grant execute on function public.list_lot_reconciliations()
  to authenticated;
grant execute on function public.get_lot_reconciliation(uuid)
  to authenticated;
grant execute on function public.save_lot_reconciliation_count(uuid, integer, uuid, uuid, integer)
  to authenticated;
grant execute on function public.save_lot_reconciliation_lots(uuid, integer, uuid, jsonb)
  to authenticated;
grant execute on function public.add_lot_reconciliation_found_product(uuid, integer, uuid, uuid)
  to authenticated;
grant execute on function public.refresh_lot_reconciliation_expected(uuid, integer)
  to authenticated;
grant execute on function public.submit_lot_reconciliation(uuid, integer, text)
  to authenticated;
grant execute on function public.approve_lot_reconciliation(uuid, integer, text, text)
  to authenticated;
grant execute on function public.reject_lot_reconciliation(uuid, integer, text, text)
  to authenticated;
grant execute on function public.reopen_lot_reconciliation(uuid, integer, text)
  to authenticated;
grant execute on function public.cancel_lot_reconciliation(uuid, integer, text, text)
  to authenticated;

alter table public.stock_lot_reconciliations enable row level security;
alter table public.stock_lot_reconciliations force row level security;
alter table public.stock_lot_reconciliation_scope_crates enable row level security;
alter table public.stock_lot_reconciliation_scope_crates force row level security;
alter table public.stock_lot_reconciliation_lines enable row level security;
alter table public.stock_lot_reconciliation_lines force row level security;
alter table public.stock_lot_reconciliation_lot_entries enable row level security;
alter table public.stock_lot_reconciliation_lot_entries force row level security;
alter table public.stock_lot_reconciliation_events enable row level security;
alter table public.stock_lot_reconciliation_events force row level security;

revoke all on table public.stock_lot_reconciliations
  from public, anon, authenticated, service_role;
revoke all on table public.stock_lot_reconciliation_scope_crates
  from public, anon, authenticated, service_role;
revoke all on table public.stock_lot_reconciliation_lines
  from public, anon, authenticated, service_role;
revoke all on table public.stock_lot_reconciliation_lot_entries
  from public, anon, authenticated, service_role;
revoke all on table public.stock_lot_reconciliation_events
  from public, anon, authenticated, service_role;

grant select on table public.stock_lot_reconciliations to authenticated;
grant select on table public.stock_lot_reconciliation_scope_crates to authenticated;
grant select on table public.stock_lot_reconciliation_lines to authenticated;
grant select on table public.stock_lot_reconciliation_lot_entries to authenticated;
grant select on table public.stock_lot_reconciliation_events to authenticated;

create policy stock_lot_reconciliations_select
  on public.stock_lot_reconciliations
  for select to authenticated
  using (app_private.can_view_lot_reconciliation(godown_id));

create policy stock_lot_reconciliation_scope_crates_select
  on public.stock_lot_reconciliation_scope_crates
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_lot_reconciliations
      where stock_lot_reconciliations.id = stock_lot_reconciliation_scope_crates.session_id
        and app_private.can_view_lot_reconciliation(stock_lot_reconciliations.godown_id)
    )
  );

create policy stock_lot_reconciliation_lines_select
  on public.stock_lot_reconciliation_lines
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_lot_reconciliations
      where stock_lot_reconciliations.id = stock_lot_reconciliation_lines.session_id
        and app_private.can_view_lot_reconciliation(stock_lot_reconciliations.godown_id)
    )
  );

create policy stock_lot_reconciliation_lot_entries_select
  on public.stock_lot_reconciliation_lot_entries
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_lot_reconciliation_lines
      join public.stock_lot_reconciliations
        on stock_lot_reconciliations.id = stock_lot_reconciliation_lines.session_id
      where stock_lot_reconciliation_lines.id = stock_lot_reconciliation_lot_entries.line_id
        and app_private.can_view_lot_reconciliation(stock_lot_reconciliations.godown_id)
    )
  );

create policy stock_lot_reconciliation_events_select
  on public.stock_lot_reconciliation_events
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_lot_reconciliations
      where stock_lot_reconciliations.id = stock_lot_reconciliation_events.session_id
        and app_private.can_view_lot_reconciliation(stock_lot_reconciliations.godown_id)
    )
  );

comment on function public.create_lot_reconciliation(uuid, uuid[], text, text) is
  'Admin opens a draft session for selected crates. Does not change stock. Overlapping active/approved crate scope is rejected.';

comment on function public.approve_lot_reconciliation(uuid, integer, text, text) is
  'Admin approval of a fully matched, classified session. Does not post stock, seed lots, or flip cutover flags.';

comment on function public.cancel_lot_reconciliation(uuid, integer, text, text) is
  'Admin cancel of draft or rejected sessions. Releases crate scope. Does not change inventory.';
