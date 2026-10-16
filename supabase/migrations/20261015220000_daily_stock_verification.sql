-- Phase 3.2 daily stock verification.
-- Local migration only. It does not post stock, change balances, or add a
-- ledger transaction type. Expected quantities are copied once from
-- stock_balances while zone, crate, and balance locks are held. Later
-- movements are ledger rows for that crate and product whose ids were not
-- in that locked set, so opposing entries remain visible when their net is zero.

create sequence public.stock_verification_seq as bigint;

revoke all on sequence public.stock_verification_seq from public, anon, authenticated, service_role;

create table public.stock_verifications (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  verification_number text not null,
  godown_id uuid not null references public.branches (id) on delete restrict,
  business_date date not null,
  status text not null,
  snapshot_at timestamptz not null,
  snapshot_ledger_boundary text not null,
  started_by uuid not null references public.profiles (id) on delete restrict,
  started_at timestamptz not null,
  submitted_by uuid references public.profiles (id) on delete restrict,
  submitted_at timestamptz,
  reviewed_by uuid references public.profiles (id) on delete restrict,
  reviewed_at timestamptz,
  closed_by uuid references public.profiles (id) on delete restrict,
  closed_at timestamptz,
  closure_result text,
  closure_note text,
  correction_request_status text not null default 'none',
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_verifications_number_key unique (verification_number),
  constraint stock_verifications_status_check
    check (status in ('draft', 'counting', 'submitted', 'recount', 'review', 'closed')),
  constraint stock_verifications_boundary_check
    check (snapshot_ledger_boundary = 'ledger-id-set'),
  constraint stock_verifications_date_check
    check (business_date >= date '2020-01-01'),
  constraint stock_verifications_result_check
    check (closure_result is null or closure_result in ('matched', 'variance_recorded', 'correction_requested')),
  constraint stock_verifications_correction_check
    check (
      (closure_result = 'correction_requested' and correction_request_status = 'requested')
      or (closure_result is distinct from 'correction_requested' and correction_request_status = 'none')
    ),
  constraint stock_verifications_note_check
    check (closure_note is null or pg_catalog.char_length(closure_note) between 1 and 500),
  constraint stock_verifications_closure_check check (
    (
      status = 'closed'
      and closed_by is not null
      and closed_at is not null
      and closure_result is not null
      and closure_note is not null
    )
    or (
      status <> 'closed'
      and closed_by is null
      and closed_at is null
      and closure_result is null
    )
  )
);

create unique index stock_verifications_one_open_godown
  on public.stock_verifications (godown_id)
  where status <> 'closed';

create index stock_verifications_godown_date_idx
  on public.stock_verifications (godown_id, business_date desc);

comment on table public.stock_verifications is
  'One open daily stock check per godown. Closing records the physical check and does not change inventory.';

create table public.stock_verification_scopes (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  verification_id uuid not null references public.stock_verifications (id) on delete restrict,
  zone_id uuid not null references public.zones (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  selected_at timestamptz not null default pg_catalog.clock_timestamp(),
  inactive_review_reason text,
  inactive_reviewed_by uuid references public.profiles (id) on delete restrict,
  inactive_reviewed_at timestamptz,
  reviewed_zone_active boolean,
  reviewed_crate_active boolean,
  constraint stock_verification_scopes_crate_key unique (verification_id, crate_id),
  constraint stock_verification_scopes_review_check check (
    (
      inactive_review_reason is null
      and inactive_reviewed_by is null
      and inactive_reviewed_at is null
      and reviewed_zone_active is null
      and reviewed_crate_active is null
    )
    or (
      pg_catalog.char_length(inactive_review_reason) between 1 and 500
      and inactive_reviewed_by is not null
      and inactive_reviewed_at is not null
      and reviewed_zone_active is not null
      and reviewed_crate_active is not null
    )
  )
);

create index stock_verification_scopes_verification_idx
  on public.stock_verification_scopes (verification_id);

comment on table public.stock_verification_scopes is
  'Zones and crates selected at start. The selection cannot be changed after the snapshot.';

create table public.stock_verification_lines (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  verification_id uuid not null references public.stock_verifications (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  expected_cases integer not null,
  counted_cases integer,
  recount_cases integer,
  first_counted_by uuid references public.profiles (id) on delete restrict,
  first_counted_at timestamptz,
  recounted_by uuid references public.profiles (id) on delete restrict,
  recounted_at timestamptz,
  line_version integer not null default 1,
  recount_requested boolean not null default false,
  ledger_movement_cases integer,
  reconciled_expected_cases integer,
  final_variance_cases integer,
  discrepancy_status text not null default 'uncounted',
  discrepancy_reason text,
  reviewed_by uuid references public.profiles (id) on delete restrict,
  reviewed_at timestamptz,
  acknowledged_ledger_ids uuid[] not null default '{}',
  inactive_review_reason text,
  inactive_reviewed_by uuid references public.profiles (id) on delete restrict,
  inactive_reviewed_at timestamptz,
  reviewed_product_active boolean,
  reviewed_crate_active boolean,
  reviewed_zone_active boolean,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_verification_lines_identity_key unique (verification_id, crate_id, product_id),
  constraint stock_verification_lines_expected_check check (expected_cases >= 0),
  constraint stock_verification_lines_counted_check check (counted_cases is null or counted_cases >= 0),
  constraint stock_verification_lines_recount_check check (recount_cases is null or recount_cases >= 0),
  constraint stock_verification_lines_version_check check (line_version > 0),
  constraint stock_verification_lines_status_check
    check (discrepancy_status in ('uncounted', 'counted', 'recount_required', 'reviewed')),
  constraint stock_verification_lines_reason_check
    check (discrepancy_reason is null or pg_catalog.char_length(discrepancy_reason) between 1 and 500),
  constraint stock_verification_lines_first_count_check check (
    (counted_cases is null and first_counted_by is null and first_counted_at is null)
    or (counted_cases is not null and first_counted_by is not null and first_counted_at is not null)
  ),
  constraint stock_verification_lines_recount_actor_check check (
    (recount_cases is null and recounted_by is null and recounted_at is null)
    or (
      recount_cases is not null
      and recounted_by is not null
      and recounted_at is not null
      and counted_cases is not null
    )
  ),
  constraint stock_verification_lines_inactive_review_check check (
    (
      inactive_review_reason is null
      and inactive_reviewed_by is null
      and inactive_reviewed_at is null
      and reviewed_product_active is null
      and reviewed_crate_active is null
      and reviewed_zone_active is null
    )
    or (
      pg_catalog.char_length(inactive_review_reason) between 1 and 500
      and inactive_reviewed_by is not null
      and inactive_reviewed_at is not null
      and reviewed_product_active is not null
      and reviewed_crate_active is not null
      and reviewed_zone_active is not null
    )
  )
);

create index stock_verification_lines_verification_idx
  on public.stock_verification_lines (verification_id, crate_id, product_id);

comment on table public.stock_verification_lines is
  'Frozen expected cases plus the latest physical count and recount. Expected cases never change.';

create table public.stock_verification_counts (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  verification_id uuid not null references public.stock_verifications (id) on delete restrict,
  line_id uuid not null references public.stock_verification_lines (id) on delete restrict,
  count_kind text not null,
  counted_cases integer not null,
  counted_by uuid not null references public.profiles (id) on delete restrict,
  counted_at timestamptz not null default pg_catalog.clock_timestamp(),
  line_version integer not null,
  constraint stock_verification_counts_kind_check check (count_kind in ('initial', 'recount')),
  constraint stock_verification_counts_quantity_check check (counted_cases >= 0),
  constraint stock_verification_counts_version_check check (line_version > 0)
);

create index stock_verification_counts_line_idx
  on public.stock_verification_counts (line_id, counted_at);

comment on table public.stock_verification_counts is
  'Append-only first counts and recounts. A later recount does not remove the earlier value.';

create table public.stock_verification_snapshot_entries (
  verification_id uuid not null references public.stock_verifications (id) on delete restrict,
  ledger_id uuid not null references public.stock_ledger (id) on delete restrict,
  primary key (verification_id, ledger_id)
);

comment on table public.stock_verification_snapshot_entries is
  'Ledger ids visible for the selected crates while location locks were held at start. A later row is a movement.';

create table public.stock_verification_evidence (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  verification_id uuid not null references public.stock_verifications (id) on delete restrict,
  verification_line_id uuid references public.stock_verification_lines (id) on delete restrict,
  storage_path text not null,
  mime_type text,
  file_size bigint,
  uploaded_by uuid not null references public.profiles (id) on delete restrict,
  uploaded_at timestamptz not null default pg_catalog.clock_timestamp(),
  note text,
  verified_at timestamptz,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_verification_evidence_path_key unique (storage_path),
  constraint stock_verification_evidence_path_check
    check (storage_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  constraint stock_verification_evidence_mime_check
    check (mime_type is null or mime_type in ('image/jpeg', 'image/png', 'image/webp')),
  constraint stock_verification_evidence_size_check
    check (file_size is null or (file_size > 0 and file_size <= 10485760)),
  constraint stock_verification_evidence_note_check
    check (note is null or pg_catalog.char_length(note) between 1 and 500),
  constraint stock_verification_evidence_final_check check (
    (verified_at is null and mime_type is null and file_size is null)
    or (verified_at is not null and mime_type is not null and file_size is not null)
  )
);

create index stock_verification_evidence_verification_idx
  on public.stock_verification_evidence (verification_id);

comment on table public.stock_verification_evidence is
  'Photo evidence metadata. Image bytes stay in the private storage bucket. An unfinished upload is not evidence.';

create or replace function app_private.can_view_stock_verification(target_godown uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.has_permission('operations.monitor')
    or (
      (
        app_private.has_permission('stock.verify')
        or app_private.has_permission('stock.count_assist')
      )
      and app_private.can_work_at_branch(target_godown)
    );
$$;

create or replace function app_private.assert_verification_reader()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
    or not (
      app_private.has_permission('operations.monitor')
      or app_private.has_permission('stock.verify')
      or app_private.has_permission('stock.count_assist')
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.assert_verification_counter()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
    or not (
      app_private.has_permission('stock.verify')
      or app_private.has_permission('stock.count_assist')
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.clean_verification_text(raw_value text, required boolean)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.btrim(coalesce(raw_value, ''));
begin
  if cleaned = '' then
    if required then
      raise exception 'a reason is required' using errcode = '23514';
    end if;
    return null;
  end if;

  if pg_catalog.char_length(cleaned) > 500 then
    raise exception 'notes are too long' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.same_uuid_set(left_ids uuid[], right_ids uuid[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    coalesce(left_ids, '{}'::uuid[]) @> coalesce(right_ids, '{}'::uuid[])
    and coalesce(right_ids, '{}'::uuid[]) @> coalesce(left_ids, '{}'::uuid[])
    and coalesce(pg_catalog.cardinality(left_ids), 0) = coalesce(pg_catalog.cardinality(right_ids), 0);
$$;

create or replace function app_private.verification_movement_ids(
  target_verification uuid,
  target_crate uuid,
  target_product uuid
)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.array_agg(movement.ledger_id order by movement.posted_at, movement.ledger_id), '{}'::uuid[])
  from (
    select stock_ledger.id as ledger_id, stock_ledger.posted_at
    from public.stock_ledger
    where stock_ledger.crate_id = target_crate
      and stock_ledger.product_id = target_product
      and not exists (
        select 1
        from public.stock_verification_snapshot_entries snapshot_entries
        where snapshot_entries.verification_id = target_verification
          and snapshot_entries.ledger_id = stock_ledger.id
      )
  ) movement;
$$;

create or replace function app_private.verification_movement_total(
  target_verification uuid,
  target_crate uuid,
  target_product uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(stock_ledger.quantity), 0)::integer
  from public.stock_ledger
  where stock_ledger.crate_id = target_crate
    and stock_ledger.product_id = target_product
    and not exists (
      select 1
      from public.stock_verification_snapshot_entries snapshot_entries
      where snapshot_entries.verification_id = target_verification
        and snapshot_entries.ledger_id = stock_ledger.id
    );
$$;

create or replace function app_private.detected_image_mime(payload bytea)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if payload is null then
    return null;
  end if;

  if pg_catalog.octet_length(payload) >= 3
    and pg_catalog.get_byte(payload, 0) = 255
    and pg_catalog.get_byte(payload, 1) = 216
    and pg_catalog.get_byte(payload, 2) = 255
  then
    return 'image/jpeg';
  end if;

  if pg_catalog.octet_length(payload) >= 8
    and pg_catalog.get_byte(payload, 0) = 137
    and pg_catalog.get_byte(payload, 1) = 80
    and pg_catalog.get_byte(payload, 2) = 78
    and pg_catalog.get_byte(payload, 3) = 71
    and pg_catalog.get_byte(payload, 4) = 13
    and pg_catalog.get_byte(payload, 5) = 10
    and pg_catalog.get_byte(payload, 6) = 26
    and pg_catalog.get_byte(payload, 7) = 10
  then
    return 'image/png';
  end if;

  if pg_catalog.octet_length(payload) >= 12
    and pg_catalog.get_byte(payload, 0) = 82
    and pg_catalog.get_byte(payload, 1) = 73
    and pg_catalog.get_byte(payload, 2) = 70
    and pg_catalog.get_byte(payload, 3) = 70
    and pg_catalog.get_byte(payload, 8) = 87
    and pg_catalog.get_byte(payload, 9) = 69
    and pg_catalog.get_byte(payload, 10) = 66
    and pg_catalog.get_byte(payload, 11) = 80
  then
    return 'image/webp';
  end if;

  return null;
end;
$$;

create or replace function app_private.lock_stock_verification(target_verification uuid)
returns public.stock_verifications
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_verifications;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.stock_verifications
  where stock_verifications.id = target_verification
  for update;

  if not found or not app_private.can_view_stock_verification(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return selected;
end;
$$;

create or replace function app_private.assert_distinct_ids(selected_ids uuid[], label text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if selected_ids is null
    or pg_catalog.cardinality(selected_ids) < 1
    or pg_catalog.array_position(selected_ids, null) is not null
    or (
      select count(*)
      from pg_catalog.unnest(selected_ids) selected_id
    ) <> (
      select count(distinct selected_id)
      from pg_catalog.unnest(selected_ids) selected_id
    )
  then
    raise exception '% selection is invalid', label using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.guard_stock_verification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'verification records cannot be deleted' using errcode = '42501';
  end if;

  if old.status = 'closed' then
    raise exception 'closed verification cannot be changed' using errcode = '42501';
  end if;

  if new.id is distinct from old.id
    or new.verification_number is distinct from old.verification_number
    or new.godown_id is distinct from old.godown_id
    or new.business_date is distinct from old.business_date
    or new.snapshot_at is distinct from old.snapshot_at
    or new.started_by is distinct from old.started_by
    or new.started_at is distinct from old.started_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'verification identity cannot be changed' using errcode = '42501';
  end if;

  if old.status = new.status then
    null;
  elsif old.status = 'counting' and new.status = 'submitted' then
    null;
  elsif old.status = 'submitted' and new.status in ('recount', 'review', 'closed') then
    null;
  elsif old.status = 'recount' and new.status in ('review', 'closed') then
    null;
  elsif old.status = 'review' and new.status in ('recount', 'closed') then
    null;
  else
    raise exception 'verification cannot change status' using errcode = '42501';
  end if;

  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$$;

create trigger stock_verifications_guard
  before update or delete on public.stock_verifications
  for each row execute function app_private.guard_stock_verification();

create or replace function app_private.guard_verification_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  godown uuid;
  crate_zone uuid;
  zone_godown uuid;
begin
  if tg_op = 'DELETE' then
    raise exception 'verification scope cannot be changed' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' then
    if exists (
      select 1
      from public.stock_verifications
      where stock_verifications.id = old.verification_id
        and stock_verifications.status = 'closed'
    ) then
      raise exception 'closed verification cannot be changed' using errcode = '42501';
    end if;

    if new.verification_id is distinct from old.verification_id
      or new.zone_id is distinct from old.zone_id
      or new.crate_id is distinct from old.crate_id
      or new.selected_at is distinct from old.selected_at
    then
      raise exception 'verification scope cannot be changed' using errcode = '42501';
    end if;

    return new;
  end if;

  select stock_verifications.godown_id
  into godown
  from public.stock_verifications
  where stock_verifications.id = new.verification_id;

  select crates.zone_id
  into crate_zone
  from public.crates
  where crates.id = new.crate_id;

  select zones.branch_id
  into zone_godown
  from public.zones
  where zones.id = new.zone_id;

  if crate_zone is distinct from new.zone_id or zone_godown is distinct from godown then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger stock_verification_scopes_guard
  before insert or update or delete on public.stock_verification_scopes
  for each row execute function app_private.guard_verification_scope();

create or replace function app_private.guard_verification_line()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'verification records cannot be deleted' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.stock_verifications
    where stock_verifications.id = old.verification_id
      and stock_verifications.status = 'closed'
  ) then
    raise exception 'closed verification cannot be changed' using errcode = '42501';
  end if;

  if new.verification_id is distinct from old.verification_id
    or new.crate_id is distinct from old.crate_id
    or new.product_id is distinct from old.product_id
    or new.expected_cases is distinct from old.expected_cases
    or new.created_at is distinct from old.created_at
  then
    raise exception 'expected stock cannot be changed' using errcode = '42501';
  end if;

  if old.counted_cases is not null and new.counted_cases is distinct from old.counted_cases then
    raise exception 'count was already recorded' using errcode = '23514';
  end if;

  if old.first_counted_by is not null and new.first_counted_by is distinct from old.first_counted_by then
    raise exception 'count was already recorded' using errcode = '23514';
  end if;

  if old.first_counted_at is not null and new.first_counted_at is distinct from old.first_counted_at then
    raise exception 'count was already recorded' using errcode = '23514';
  end if;

  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$$;

create trigger stock_verification_lines_guard
  before update or delete on public.stock_verification_lines
  for each row execute function app_private.guard_verification_line();

create or replace function app_private.guard_verification_count()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'count history cannot be changed' using errcode = '42501';
end;
$$;

create trigger stock_verification_counts_guard
  before update or delete on public.stock_verification_counts
  for each row execute function app_private.guard_verification_count();

create or replace function app_private.guard_verification_snapshot()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'verification snapshot cannot be changed' using errcode = '42501';
end;
$$;

create trigger stock_verification_snapshot_guard
  before update or delete on public.stock_verification_snapshot_entries
  for each row execute function app_private.guard_verification_snapshot();

create or replace function app_private.guard_verification_evidence()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'verification evidence cannot be deleted' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.stock_verifications
    where stock_verifications.id = old.verification_id
      and stock_verifications.status = 'closed'
  ) then
    raise exception 'closed verification cannot be changed' using errcode = '42501';
  end if;

  if old.verified_at is not null then
    raise exception 'verification evidence cannot be changed' using errcode = '42501';
  end if;

  if new.verification_id is distinct from old.verification_id
    or new.storage_path is distinct from old.storage_path
    or new.uploaded_by is distinct from old.uploaded_by
    or new.uploaded_at is distinct from old.uploaded_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'verification evidence cannot be changed' using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger stock_verification_evidence_guard
  before update or delete on public.stock_verification_evidence
  for each row execute function app_private.guard_verification_evidence();

create or replace function app_private.assert_verification_scope(
  target_godown uuid,
  zone_ids uuid[],
  crate_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_distinct_ids(zone_ids, 'zone');
  perform app_private.assert_distinct_ids(crate_ids, 'crate');

  if (
    select count(*)
    from public.zones
    where zones.id = any (zone_ids)
  ) <> pg_catalog.cardinality(zone_ids)
  or (
    select count(*)
    from public.crates
    where crates.id = any (crate_ids)
  ) <> pg_catalog.cardinality(crate_ids)
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(zone_ids) selected_zone (id)
    where not exists (
      select 1
      from public.zones
      where zones.id = selected_zone.id
        and zones.branch_id = target_godown
        and zones.is_active
    )
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.crates
    where crates.id = any (crate_ids)
      and not (crates.zone_id = any (zone_ids))
  ) then
    raise exception 'crate is outside the selected zones' using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(zone_ids) selected_zone (id)
    where not exists (
      select 1
      from public.crates
      where crates.id = any (crate_ids)
        and crates.zone_id = selected_zone.id
    )
  ) then
    raise exception 'each selected zone needs a crate' using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.verification_movements_json(
  target_verification uuid,
  target_crate uuid,
  target_product uuid,
  only_ids uuid[]
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'ledger_id', stock_ledger.id,
      'quantity', stock_ledger.quantity,
      'posted_at', stock_ledger.posted_at,
      'transaction_type', stock_transactions.transaction_type,
      'reference_number', stock_transactions.reference_number
    )
    order by stock_ledger.posted_at, stock_ledger.id
  ), '[]'::jsonb)
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where (
    only_ids is not null
    and stock_ledger.id = any (only_ids)
  ) or (
    only_ids is null
    and stock_ledger.crate_id = target_crate
    and stock_ledger.product_id = target_product
    and not exists (
      select 1
      from public.stock_verification_snapshot_entries snapshot_entries
      where snapshot_entries.verification_id = target_verification
        and snapshot_entries.ledger_id = stock_ledger.id
    )
  );
$$;

create or replace function app_private.stock_verification_payload(target_verification uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  line record;
  lines jsonb := '[]'::jsonb;
  movement_ids uuid[];
  movement_total integer;
  physical integer;
  reconciled integer;
  variance integer;
  blockers jsonb := '[]'::jsonb;
  line_count integer := 0;
  counted_count integer := 0;
  matched_count integer := 0;
  shortage_count integer := 0;
  overage_count integer := 0;
  movement_count integer := 0;
  unreconciled_count integer := 0;
  recount_missing integer := 0;
  inactive_missing integer := 0;
begin
  perform app_private.assert_verification_reader();

  select *
  into header
  from public.stock_verifications
  where stock_verifications.id = target_verification;

  if not found or not app_private.can_view_stock_verification(header.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  for line in
    select
      stock_verification_lines.*,
      crates.code as crate_code,
      crates.name as crate_name,
      crates.is_active as crate_is_active,
      zones.id as zone_id,
      zones.code as zone_code,
      zones.name as zone_name,
      zones.is_active as zone_is_active,
      products.sku,
      products.name as product_name,
      products.is_active as product_is_active,
      first_counter.full_name as first_counter_name,
      recounter.full_name as recounter_name,
      reviewer.full_name as reviewer_name,
      inactive_reviewer.full_name as inactive_reviewer_name
    from public.stock_verification_lines
    join public.crates on crates.id = stock_verification_lines.crate_id
    join public.zones on zones.id = crates.zone_id
    join public.products on products.id = stock_verification_lines.product_id
    left join public.profiles first_counter on first_counter.id = stock_verification_lines.first_counted_by
    left join public.profiles recounter on recounter.id = stock_verification_lines.recounted_by
    left join public.profiles reviewer on reviewer.id = stock_verification_lines.reviewed_by
    left join public.profiles inactive_reviewer
      on inactive_reviewer.id = stock_verification_lines.inactive_reviewed_by
    where stock_verification_lines.verification_id = header.id
    order by zones.code, crates.code, products.sku
  loop
    if header.status = 'closed' then
      movement_ids := line.acknowledged_ledger_ids;
      movement_total := coalesce(line.ledger_movement_cases, 0);
      reconciled := line.reconciled_expected_cases;
      variance := line.final_variance_cases;
    else
      movement_ids := app_private.verification_movement_ids(header.id, line.crate_id, line.product_id);
      movement_total := app_private.verification_movement_total(header.id, line.crate_id, line.product_id);
      reconciled := line.expected_cases + movement_total;
      physical := coalesce(line.recount_cases, line.counted_cases);
      variance := case when physical is null then null else physical - reconciled end;
    end if;

    line_count := line_count + 1;
    if line.counted_cases is not null then
      counted_count := counted_count + 1;
    end if;
    if variance = 0 then
      matched_count := matched_count + 1;
    elsif variance < 0 then
      shortage_count := shortage_count + 1;
    elsif variance > 0 then
      overage_count := overage_count + 1;
    end if;
    if coalesce(pg_catalog.cardinality(movement_ids), 0) > 0 or coalesce(movement_total, 0) <> 0 then
      movement_count := movement_count + 1;
    end if;
    if header.status <> 'closed'
      and not app_private.same_uuid_set(line.acknowledged_ledger_ids, movement_ids)
      and (
        coalesce(pg_catalog.cardinality(movement_ids), 0) > 0
        or variance is distinct from 0
      )
    then
      unreconciled_count := unreconciled_count + 1;
    end if;
    if variance is not null and variance <> 0 and line.recount_cases is null then
      recount_missing := recount_missing + 1;
    end if;
    if header.status <> 'closed'
      and (
        not line.product_is_active
        or not line.crate_is_active
        or not line.zone_is_active
      )
      and (
        line.inactive_reviewed_at is null
        or line.reviewed_product_active is distinct from line.product_is_active
        or line.reviewed_crate_active is distinct from line.crate_is_active
        or line.reviewed_zone_active is distinct from line.zone_is_active
      )
    then
      inactive_missing := inactive_missing + 1;
    end if;

    lines := lines || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'id', line.id,
      'crate_id', line.crate_id,
      'crate_code', line.crate_code,
      'crate_name', line.crate_name,
      'crate_active', line.crate_is_active,
      'zone_id', line.zone_id,
      'zone_code', line.zone_code,
      'zone_name', line.zone_name,
      'zone_active', line.zone_is_active,
      'product_id', line.product_id,
      'sku', line.sku,
      'product_name', line.product_name,
      'product_active', line.product_is_active,
      'expected_cases', line.expected_cases,
      'counted_cases', line.counted_cases,
      'recount_cases', line.recount_cases,
      'first_counted_by', line.first_counted_by,
      'first_counted_by_name', line.first_counter_name,
      'first_counted_at', line.first_counted_at,
      'recounted_by', line.recounted_by,
      'recounted_by_name', line.recounter_name,
      'recounted_at', line.recounted_at,
      'line_version', line.line_version,
      'recount_requested', line.recount_requested,
      'ledger_movement_cases', movement_total,
      'reconciled_expected_cases', reconciled,
      'final_variance_cases', variance,
      'movement_ids', to_jsonb(movement_ids),
      'acknowledged_ledger_ids', to_jsonb(line.acknowledged_ledger_ids),
      'movements', case
        when header.status = 'closed' then app_private.verification_movements_json(header.id, line.crate_id, line.product_id, line.acknowledged_ledger_ids)
        else app_private.verification_movements_json(header.id, line.crate_id, line.product_id, null)
      end,
      'discrepancy_status', line.discrepancy_status,
      'discrepancy_reason', line.discrepancy_reason,
      'reviewed_by', line.reviewed_by,
      'reviewed_by_name', line.reviewer_name,
      'reviewed_at', line.reviewed_at,
      'inactive_review_reason', line.inactive_review_reason,
      'inactive_reviewed_by_name', line.inactive_reviewer_name,
      'inactive_reviewed_at', line.inactive_reviewed_at
    ));
  end loop;

  if header.status <> 'closed' and counted_count <> line_count then
    blockers := blockers || pg_catalog.jsonb_build_array('count is missing');
  end if;
  if recount_missing > 0 then
    blockers := blockers || pg_catalog.jsonb_build_array('recount is required');
  end if;
  if unreconciled_count > 0 then
    blockers := blockers || pg_catalog.jsonb_build_array('movement must be reconciled');
  end if;
  if inactive_missing > 0 or exists (
    select 1
    from public.stock_verification_scopes
    join public.crates on crates.id = stock_verification_scopes.crate_id
    join public.zones on zones.id = stock_verification_scopes.zone_id
    where stock_verification_scopes.verification_id = header.id
      and header.status <> 'closed'
      and (not crates.is_active or not zones.is_active)
      and (
        stock_verification_scopes.inactive_reviewed_at is null
        or stock_verification_scopes.reviewed_crate_active is distinct from crates.is_active
        or stock_verification_scopes.reviewed_zone_active is distinct from zones.is_active
      )
  ) then
    blockers := blockers || pg_catalog.jsonb_build_array('inactive object must be reviewed');
  end if;
  if not exists (
    select 1
    from public.stock_verification_evidence
    where stock_verification_evidence.verification_id = header.id
      and stock_verification_evidence.verified_at is not null
  ) then
    blockers := blockers || pg_catalog.jsonb_build_array('photo evidence is required');
  end if;
  if exists (
    select 1
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = header.id
      and stock_verification_lines.recount_requested
  ) then
    blockers := blockers || pg_catalog.jsonb_build_array('recount is not finished');
  end if;

  return pg_catalog.jsonb_build_object(
    'verification', pg_catalog.jsonb_build_object(
      'id', header.id,
      'verification_number', header.verification_number,
      'godown_id', header.godown_id,
      'godown_name', (select branches.name from public.branches where branches.id = header.godown_id),
      'business_date', header.business_date,
      'status', header.status,
      'snapshot_at', header.snapshot_at,
      'snapshot_ledger_boundary', header.snapshot_ledger_boundary,
      'started_by', header.started_by,
      'started_by_name', (select profiles.full_name from public.profiles where profiles.id = header.started_by),
      'started_at', header.started_at,
      'submitted_by', header.submitted_by,
      'submitted_at', header.submitted_at,
      'reviewed_by', header.reviewed_by,
      'reviewed_at', header.reviewed_at,
      'closed_by', header.closed_by,
      'closed_by_name', (select profiles.full_name from public.profiles where profiles.id = header.closed_by),
      'closed_at', header.closed_at,
      'closure_result', header.closure_result,
      'closure_note', header.closure_note,
      'correction_request_status', header.correction_request_status
    ),
    'scopes', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_verification_scopes.id,
        'zone_id', zones.id,
        'zone_code', zones.code,
        'zone_name', zones.name,
        'zone_active', zones.is_active,
        'crate_id', crates.id,
        'crate_code', crates.code,
        'crate_name', crates.name,
        'crate_active', crates.is_active,
        'inactive_review_reason', stock_verification_scopes.inactive_review_reason,
        'inactive_reviewed_by_name', reviewers.full_name,
        'inactive_reviewed_at', stock_verification_scopes.inactive_reviewed_at
      ) order by zones.code, crates.code)
      from public.stock_verification_scopes
      join public.zones on zones.id = stock_verification_scopes.zone_id
      join public.crates on crates.id = stock_verification_scopes.crate_id
      left join public.profiles reviewers on reviewers.id = stock_verification_scopes.inactive_reviewed_by
      where stock_verification_scopes.verification_id = header.id
    ), '[]'::jsonb),
    'lines', lines,
    'counts', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_verification_counts.id,
        'line_id', stock_verification_counts.line_id,
        'count_kind', stock_verification_counts.count_kind,
        'counted_cases', stock_verification_counts.counted_cases,
        'counted_by_name', profiles.full_name,
        'counted_at', stock_verification_counts.counted_at,
        'line_version', stock_verification_counts.line_version
      ) order by stock_verification_counts.counted_at, stock_verification_counts.id)
      from public.stock_verification_counts
      join public.profiles on profiles.id = stock_verification_counts.counted_by
      where stock_verification_counts.verification_id = header.id
    ), '[]'::jsonb),
    'evidence', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_verification_evidence.id,
        'verification_line_id', stock_verification_evidence.verification_line_id,
        'mime_type', stock_verification_evidence.mime_type,
        'file_size', stock_verification_evidence.file_size,
        'uploaded_by_name', profiles.full_name,
        'uploaded_at', stock_verification_evidence.uploaded_at,
        'note', stock_verification_evidence.note,
        'verified_at', stock_verification_evidence.verified_at
      ) order by stock_verification_evidence.uploaded_at)
      from public.stock_verification_evidence
      join public.profiles on profiles.id = stock_verification_evidence.uploaded_by
      where stock_verification_evidence.verification_id = header.id
    ), '[]'::jsonb),
    'history', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'action', audit_logs.action,
        'actor_name', profiles.full_name,
        'occurred_at', audit_logs.occurred_at,
        'metadata', audit_logs.metadata
      ) order by audit_logs.occurred_at, audit_logs.id)
      from public.audit_logs
      left join public.profiles on profiles.id = audit_logs.actor_id
      where audit_logs.entity_id = header.id
        or audit_logs.metadata ->> 'verification_id' = header.id::text
    ), '[]'::jsonb),
    'unassigned_movements', case
      when header.status = 'closed' then '[]'::jsonb
      else coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'crate_id', stock_ledger.crate_id,
          'product_id', stock_ledger.product_id,
          'sku', products.sku,
          'product_name', products.name,
          'ledger_id', stock_ledger.id,
          'quantity', stock_ledger.quantity,
          'posted_at', stock_ledger.posted_at,
          'transaction_type', stock_transactions.transaction_type,
          'reference_number', stock_transactions.reference_number
        ) order by stock_ledger.posted_at, stock_ledger.id)
        from public.stock_ledger
        join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
        join public.stock_verification_scopes
          on stock_verification_scopes.verification_id = header.id
         and stock_verification_scopes.crate_id = stock_ledger.crate_id
        join public.products on products.id = stock_ledger.product_id
        where not exists (
          select 1
          from public.stock_verification_snapshot_entries snapshot_entries
          where snapshot_entries.verification_id = header.id
            and snapshot_entries.ledger_id = stock_ledger.id
        )
        and not exists (
          select 1
          from public.stock_verification_lines existing_line
          where existing_line.verification_id = header.id
            and existing_line.crate_id = stock_ledger.crate_id
            and existing_line.product_id = stock_ledger.product_id
        )
      ), '[]'::jsonb)
    end,
    'products', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', products.id,
        'sku', products.sku,
        'name', products.name
      ) order by products.sku)
      from public.products
      where products.is_active
    ), '[]'::jsonb),
    'closure', pg_catalog.jsonb_build_object(
      'lines_total', line_count,
      'lines_counted', counted_count,
      'matched', matched_count,
      'shortages', shortage_count,
      'overages', overage_count,
      'movement_affected', movement_count,
      'unreconciled', unreconciled_count,
      'recount_missing', recount_missing,
      'verified_photos', (
        select count(*)
        from public.stock_verification_evidence
        where stock_verification_evidence.verification_id = header.id
          and stock_verification_evidence.verified_at is not null
      ),
      'blockers', blockers
    )
  );
end;
$$;

create or replace function public.start_stock_verification(
  target_godown uuid,
  verification_date date,
  zone_ids uuid[],
  crate_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  selected_branch uuid;
  snapshot_time timestamptz;
begin
  perform app_private.assert_permission('stock.verify');

  if auth.uid() is null or not app_private.can_work_at_branch(target_godown) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if verification_date is null
    or verification_date < date '2020-01-01'
    or verification_date > current_date + 1
  then
    raise exception 'business date is invalid' using errcode = '23514';
  end if;

  perform app_private.assert_distinct_ids(zone_ids, 'zone');
  perform app_private.assert_distinct_ids(crate_ids, 'crate');

  if exists (
    select 1
    from public.stock_verifications
    where stock_verifications.godown_id = target_godown
      and stock_verifications.status <> 'closed'
  ) then
    raise exception 'an open verification already exists for this godown' using errcode = '23505';
  end if;

  selected_branch := app_private.prepare_stock_locations(crate_ids);
  if selected_branch is distinct from target_godown then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_verification_scope(target_godown, zone_ids, crate_ids);

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  snapshot_time := pg_catalog.clock_timestamp();

  insert into public.stock_verifications (
    verification_number,
    godown_id,
    business_date,
    status,
    snapshot_at,
    snapshot_ledger_boundary,
    started_by,
    started_at
  )
  values (
    'DV-' || pg_catalog.to_char(verification_date, 'YYYYMMDD') || '-' || pg_catalog.lpad(pg_catalog.nextval('public.stock_verification_seq')::text, 6, '0'),
    target_godown,
    verification_date,
    'counting',
    snapshot_time,
    'ledger-id-set',
    auth.uid(),
    snapshot_time
  )
  returning id into created_id;

  insert into public.stock_verification_scopes (verification_id, zone_id, crate_id)
  select created_id, crates.zone_id, crates.id
  from public.crates
  where crates.id = any (crate_ids)
  order by crates.id;

  insert into public.stock_verification_snapshot_entries (verification_id, ledger_id)
  select created_id, stock_ledger.id
  from public.stock_ledger
  where stock_ledger.crate_id = any (crate_ids);

  insert into public.stock_verification_lines (
    verification_id, crate_id, product_id, expected_cases
  )
  select created_id, stock_balances.crate_id, stock_balances.product_id, stock_balances.quantity
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
    and stock_balances.quantity > 0
  order by stock_balances.crate_id, stock_balances.product_id;

  perform app_private.write_audit(
    auth.uid(),
    'start_stock_verification',
    'stock_verifications',
    created_id,
    pg_catalog.jsonb_build_object(
      'verification_id', created_id,
      'godown_id', target_godown,
      'business_date', verification_date,
      'crate_count', pg_catalog.cardinality(crate_ids)
    )
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'an open verification already exists for this godown' using errcode = '23505';
end;
$$;

create or replace function public.preview_verification_scope(
  target_godown uuid,
  zone_ids uuid[],
  crate_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.verify');

  if auth.uid() is null or not app_private.can_work_at_branch(target_godown) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.crates
    join public.zones on zones.id = crates.zone_id
    join public.branches on branches.id = zones.branch_id
    where crates.id = any (crate_ids)
      and (
        not crates.is_active
        or not zones.is_active
        or not branches.is_active
        or zones.branch_id is distinct from target_godown
      )
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_verification_scope(target_godown, zone_ids, crate_ids);

  return pg_catalog.jsonb_build_object(
    'crate_count', pg_catalog.cardinality(crate_ids),
    'product_count', (
      select count(*)
      from public.stock_balances
      where stock_balances.crate_id = any (crate_ids)
        and stock_balances.quantity > 0
    ),
    'expected_cases', coalesce((
      select sum(stock_balances.quantity)::integer
      from public.stock_balances
      where stock_balances.crate_id = any (crate_ids)
        and stock_balances.quantity > 0
    ), 0),
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'zone_code', zones.code,
        'crate_id', crates.id,
        'crate_code', crates.code,
        'product_id', products.id,
        'sku', products.sku,
        'product_name', products.name,
        'expected_cases', stock_balances.quantity
      ) order by zones.code, crates.code, products.sku)
      from public.stock_balances
      join public.crates on crates.id = stock_balances.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.products on products.id = stock_balances.product_id
      where stock_balances.crate_id = any (crate_ids)
        and stock_balances.quantity > 0
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.list_verification_options()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.verify');

  return pg_catalog.jsonb_build_object(
    'godowns', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', branches.id,
        'code', branches.code,
        'name', branches.name
      ) order by branches.code)
      from public.branches
      where branches.is_active
        and app_private.can_work_at_branch(branches.id)
    ), '[]'::jsonb),
    'zones', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', zones.id,
        'branch_id', zones.branch_id,
        'code', zones.code,
        'name', zones.name
      ) order by zones.code)
      from public.zones
      join public.branches on branches.id = zones.branch_id
      where zones.is_active
        and branches.is_active
        and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb),
    'crates', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', crates.id,
        'zone_id', crates.zone_id,
        'code', crates.code,
        'name', crates.name
      ) order by crates.code)
      from public.crates
      join public.zones on zones.id = crates.zone_id
      join public.branches on branches.id = zones.branch_id
      where crates.is_active
        and zones.is_active
        and branches.is_active
        and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb),
    'products', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', products.id,
        'sku', products.sku,
        'name', products.name
      ) order by products.sku)
      from public.products
      where products.is_active
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.add_verification_found_product(
  target_verification uuid,
  target_crate uuid,
  target_product uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  created_id uuid;
begin
  perform app_private.assert_verification_counter();
  header := app_private.lock_stock_verification(target_verification);

  if header.status = 'closed' then
    raise exception 'closed verification cannot be changed' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.stock_verification_scopes
    where stock_verification_scopes.verification_id = header.id
      and stock_verification_scopes.crate_id = target_crate
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform products.id
  from public.products
  where products.id = target_product
    and products.is_active
  for update;

  if not found then
    raise exception 'product not found or inactive' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = header.id
      and stock_verification_lines.crate_id = target_crate
      and stock_verification_lines.product_id = target_product
  ) then
    raise exception 'verification line already exists' using errcode = '23505';
  end if;

  insert into public.stock_verification_lines (
    verification_id, crate_id, product_id, expected_cases
  )
  values (header.id, target_crate, target_product, 0)
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'add_verification_product',
    'stock_verification_lines',
    created_id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'crate_id', target_crate,
      'product_id', target_product,
      'expected_cases', 0
    )
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'verification line already exists' using errcode = '23505';
end;
$$;

create or replace function public.save_verification_count(
  target_line uuid,
  counted_cases jsonb,
  expected_version integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  line public.stock_verification_lines;
  quantity integer;
begin
  perform app_private.assert_verification_counter();

  select stock_verification_lines.verification_id
  into line.verification_id
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_stock_verification(line.verification_id);

  select *
  into line
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line
  for update;

  if header.status = 'closed' then
    raise exception 'closed verification cannot be changed' using errcode = '42501';
  end if;

  if line.line_version is distinct from expected_version then
    raise exception 'count was changed by someone else' using errcode = '40001';
  end if;

  if line.counted_cases is not null then
    raise exception 'count was already recorded' using errcode = '23514';
  end if;

  quantity := app_private.receipt_case_count(counted_cases);

  insert into public.stock_verification_counts (
    verification_id, line_id, count_kind, counted_cases, counted_by, line_version
  )
  values (header.id, line.id, 'initial', quantity, auth.uid(), line.line_version + 1);

  update public.stock_verification_lines
  set
    counted_cases = quantity,
    first_counted_by = auth.uid(),
    first_counted_at = pg_catalog.clock_timestamp(),
    line_version = stock_verification_lines.line_version + 1,
    discrepancy_status = 'counted'
  where stock_verification_lines.id = line.id;

  perform app_private.write_audit(
    auth.uid(),
    'save_verification_count',
    'stock_verification_lines',
    line.id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'counted_cases', quantity,
      'line_version', line.line_version + 1
    )
  );
end;
$$;

create or replace function public.submit_stock_verification(target_verification uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
begin
  perform app_private.assert_permission('stock.verify');
  header := app_private.lock_stock_verification(target_verification);

  if header.status <> 'counting' then
    raise exception 'verification cannot change status' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = header.id
      and stock_verification_lines.counted_cases is null
  ) then
    raise exception 'count is missing' using errcode = '23514';
  end if;

  update public.stock_verifications
  set
    status = 'submitted',
    submitted_by = auth.uid(),
    submitted_at = pg_catalog.clock_timestamp()
  where stock_verifications.id = header.id;

  perform app_private.write_audit(
    auth.uid(),
    'submit_stock_verification',
    'stock_verifications',
    header.id,
    pg_catalog.jsonb_build_object('verification_id', header.id)
  );
end;
$$;

create or replace function public.report_stock_discrepancy(
  target_line uuid,
  discrepancy_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  line public.stock_verification_lines;
  reason text;
  physical integer;
  movement_total integer;
begin
  perform app_private.assert_permission('stock.verify');
  perform app_private.assert_permission('stock.discrepancy.report');

  select stock_verification_lines.verification_id
  into line.verification_id
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_stock_verification(line.verification_id);

  select *
  into line
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line
  for update;

  if header.status not in ('submitted', 'recount', 'review') then
    raise exception 'verification cannot change status' using errcode = '42501';
  end if;

  physical := coalesce(line.recount_cases, line.counted_cases);
  if physical is null then
    raise exception 'count is missing' using errcode = '23514';
  end if;

  movement_total := app_private.verification_movement_total(header.id, line.crate_id, line.product_id);
  if physical = line.expected_cases + movement_total
    and coalesce(pg_catalog.cardinality(app_private.verification_movement_ids(header.id, line.crate_id, line.product_id)), 0) = 0
  then
    raise exception 'there is no discrepancy to report' using errcode = '23514';
  end if;

  reason := app_private.clean_verification_text(discrepancy_reason, true);

  update public.stock_verification_lines
  set discrepancy_reason = reason
  where stock_verification_lines.id = line.id
    and stock_verification_lines.reviewed_at is null;

  perform app_private.write_audit(
    auth.uid(),
    'report_stock_discrepancy',
    'stock_verification_lines',
    line.id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'reason', reason
    )
  );
end;
$$;

create or replace function public.request_verification_recount(target_line uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  line public.stock_verification_lines;
begin
  perform app_private.assert_permission('stock.verify');

  select stock_verification_lines.verification_id
  into line.verification_id
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_stock_verification(line.verification_id);

  select *
  into line
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line
  for update;

  if header.status not in ('submitted', 'recount', 'review') then
    raise exception 'verification cannot change status' using errcode = '42501';
  end if;

  if line.counted_cases is null then
    raise exception 'count is missing' using errcode = '23514';
  end if;

  update public.stock_verification_lines
  set
    recount_requested = true,
    discrepancy_status = 'recount_required'
  where stock_verification_lines.id = line.id;

  update public.stock_verifications
  set status = 'recount'
  where stock_verifications.id = header.id
    and stock_verifications.status is distinct from 'recount';

  perform app_private.write_audit(
    auth.uid(),
    'request_verification_recount',
    'stock_verification_lines',
    line.id,
    pg_catalog.jsonb_build_object('verification_id', header.id)
  );
end;
$$;

create or replace function public.save_verification_recount(
  target_line uuid,
  counted_cases jsonb,
  expected_version integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  line public.stock_verification_lines;
  quantity integer;
  movement_ids uuid[];
begin
  perform app_private.assert_verification_counter();

  select stock_verification_lines.verification_id
  into line.verification_id
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_stock_verification(line.verification_id);

  select *
  into line
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line
  for update;

  if header.status <> 'recount' or not line.recount_requested then
    raise exception 'recount was not requested' using errcode = '42501';
  end if;

  if line.line_version is distinct from expected_version then
    raise exception 'count was changed by someone else' using errcode = '40001';
  end if;

  quantity := app_private.receipt_case_count(counted_cases);
  movement_ids := app_private.verification_movement_ids(header.id, line.crate_id, line.product_id);

  insert into public.stock_verification_counts (
    verification_id, line_id, count_kind, counted_cases, counted_by, line_version
  )
  values (header.id, line.id, 'recount', quantity, auth.uid(), line.line_version + 1);

  update public.stock_verification_lines
  set
    recount_cases = quantity,
    recounted_by = auth.uid(),
    recounted_at = pg_catalog.clock_timestamp(),
    line_version = stock_verification_lines.line_version + 1,
    recount_requested = false,
    acknowledged_ledger_ids = movement_ids,
    reviewed_by = null,
    reviewed_at = null,
    discrepancy_reason = null,
    discrepancy_status = 'counted'
  where stock_verification_lines.id = line.id;

  perform app_private.write_audit(
    auth.uid(),
    'save_verification_recount',
    'stock_verification_lines',
    line.id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'recount_cases', quantity,
      'movement_ids', movement_ids
    )
  );
end;
$$;

create or replace function public.review_verification_discrepancy(
  target_line uuid,
  discrepancy_reason text,
  movement_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  line public.stock_verification_lines;
  current_ids uuid[];
  physical integer;
  variance integer;
  reason text;
begin
  perform app_private.assert_permission('stock.verify');

  select stock_verification_lines.verification_id
  into line.verification_id
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_stock_verification(line.verification_id);

  select *
  into line
  from public.stock_verification_lines
  where stock_verification_lines.id = target_line
  for update;

  if header.status not in ('submitted', 'recount', 'review') then
    raise exception 'verification cannot change status' using errcode = '42501';
  end if;

  if line.recount_requested then
    raise exception 'recount is not finished' using errcode = '23514';
  end if;

  if line.counted_cases is null then
    raise exception 'count is missing' using errcode = '23514';
  end if;

  current_ids := app_private.verification_movement_ids(header.id, line.crate_id, line.product_id);
  if not app_private.same_uuid_set(movement_ids, current_ids) then
    raise exception 'movement must be reconciled' using errcode = '23514';
  end if;

  physical := coalesce(line.recount_cases, line.counted_cases);
  variance := physical - (line.expected_cases + app_private.verification_movement_total(header.id, line.crate_id, line.product_id));

  if variance <> 0 then
    if line.recount_cases is null or not app_private.same_uuid_set(line.acknowledged_ledger_ids, current_ids) then
      raise exception 'recount is required' using errcode = '23514';
    end if;
    reason := app_private.clean_verification_text(discrepancy_reason, true);
  else
    reason := app_private.clean_verification_text(discrepancy_reason, false);
  end if;

  update public.stock_verification_lines
  set
    discrepancy_reason = reason,
    reviewed_by = auth.uid(),
    reviewed_at = pg_catalog.clock_timestamp(),
    acknowledged_ledger_ids = current_ids,
    discrepancy_status = 'reviewed'
  where stock_verification_lines.id = line.id;

  update public.stock_verifications
  set
    status = case
      when exists (
        select 1
        from public.stock_verification_lines pending_line
        where pending_line.verification_id = header.id
          and pending_line.recount_requested
      ) then stock_verifications.status
      else 'review'
    end,
    reviewed_by = auth.uid(),
    reviewed_at = pg_catalog.clock_timestamp()
  where stock_verifications.id = header.id;

  perform app_private.write_audit(
    auth.uid(),
    'review_verification_discrepancy',
    'stock_verification_lines',
    line.id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'reason', reason,
      'variance_cases', variance,
      'movement_ids', current_ids
    )
  );
end;
$$;

create or replace function public.review_verification_inactive_object(
  target_kind text,
  target_id uuid,
  review_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  reason text;
  product_active boolean;
  crate_active boolean;
  zone_active boolean;
  verification_id uuid;
begin
  perform app_private.assert_permission('stock.verify');
  reason := app_private.clean_verification_text(review_reason, true);

  if target_kind = 'line' then
    select stock_verification_lines.verification_id
    into verification_id
    from public.stock_verification_lines
    where stock_verification_lines.id = target_id;

    if not found then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    header := app_private.lock_stock_verification(verification_id);
    if header.status = 'closed' then
      raise exception 'closed verification cannot be changed' using errcode = '42501';
    end if;

    select products.is_active, crates.is_active, zones.is_active
    into product_active, crate_active, zone_active
    from public.stock_verification_lines
    join public.products on products.id = stock_verification_lines.product_id
    join public.crates on crates.id = stock_verification_lines.crate_id
    join public.zones on zones.id = crates.zone_id
    where stock_verification_lines.id = target_id
    for update of stock_verification_lines;

    update public.stock_verification_lines
    set
      inactive_review_reason = reason,
      inactive_reviewed_by = auth.uid(),
      inactive_reviewed_at = pg_catalog.clock_timestamp(),
      reviewed_product_active = product_active,
      reviewed_crate_active = crate_active,
      reviewed_zone_active = zone_active
    where stock_verification_lines.id = target_id;
  elsif target_kind = 'scope' then
    select stock_verification_scopes.verification_id
    into verification_id
    from public.stock_verification_scopes
    where stock_verification_scopes.id = target_id;

    if not found then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    header := app_private.lock_stock_verification(verification_id);
    if header.status = 'closed' then
      raise exception 'closed verification cannot be changed' using errcode = '42501';
    end if;

    select crates.is_active, zones.is_active
    into crate_active, zone_active
    from public.stock_verification_scopes
    join public.crates on crates.id = stock_verification_scopes.crate_id
    join public.zones on zones.id = stock_verification_scopes.zone_id
    where stock_verification_scopes.id = target_id
    for update of stock_verification_scopes;

    update public.stock_verification_scopes
    set
      inactive_review_reason = reason,
      inactive_reviewed_by = auth.uid(),
      inactive_reviewed_at = pg_catalog.clock_timestamp(),
      reviewed_crate_active = crate_active,
      reviewed_zone_active = zone_active
    where stock_verification_scopes.id = target_id;
  else
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'review_verification_inactive',
    'stock_verifications',
    header.id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'target_kind', target_kind,
      'target_id', target_id,
      'reason', reason
    )
  );
end;
$$;

create or replace function public.close_stock_verification(
  target_verification uuid,
  closure_result text,
  closure_note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  line record;
  note text;
  current_ids uuid[];
  movement_total integer;
  physical integer;
  reconciled integer;
  variance integer;
  variance_count integer := 0;
begin
  perform app_private.assert_permission('stock.verify');
  header := app_private.lock_stock_verification(target_verification);

  if header.status not in ('submitted', 'recount', 'review') then
    raise exception 'verification cannot change status' using errcode = '42501';
  end if;

  if closure_result not in ('matched', 'variance_recorded', 'correction_requested') then
    raise exception 'closure result does not match the verification' using errcode = '23514';
  end if;

  note := app_private.clean_verification_text(closure_note, true);

  -- Lock order: this verification row, then its zones, then its crates.
  -- Product, crate, and zone deactivation lock the same open verification
  -- rows, ordered by id, before they change is_active or lock a location.
  perform zones.id
  from public.zones
  where zones.id in (
    select stock_verification_scopes.zone_id
    from public.stock_verification_scopes
    where stock_verification_scopes.verification_id = header.id
  )
  order by zones.id
  for update;

  perform crates.id
  from public.crates
  where crates.id in (
    select stock_verification_scopes.crate_id
    from public.stock_verification_scopes
    where stock_verification_scopes.verification_id = header.id
  )
  order by crates.id
  for update;

  if exists (
    select 1
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = header.id
      and stock_verification_lines.recount_requested
  ) then
    raise exception 'recount is not finished' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = header.id
      and stock_verification_lines.counted_cases is null
  ) then
    raise exception 'count is missing' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_ledger
    join public.stock_verification_scopes
      on stock_verification_scopes.verification_id = header.id
     and stock_verification_scopes.crate_id = stock_ledger.crate_id
    where not exists (
      select 1
      from public.stock_verification_snapshot_entries snapshot_entries
      where snapshot_entries.verification_id = header.id
        and snapshot_entries.ledger_id = stock_ledger.id
    )
    and not exists (
      select 1
      from public.stock_verification_lines
      where stock_verification_lines.verification_id = header.id
        and stock_verification_lines.crate_id = stock_ledger.crate_id
        and stock_verification_lines.product_id = stock_ledger.product_id
    )
  ) then
    raise exception 'movement must be reconciled' using errcode = '23514';
  end if;

  for line in
    select
      stock_verification_lines.id,
      stock_verification_lines.crate_id,
      stock_verification_lines.product_id,
      stock_verification_lines.expected_cases,
      stock_verification_lines.counted_cases,
      stock_verification_lines.recount_cases,
      stock_verification_lines.acknowledged_ledger_ids,
      stock_verification_lines.reviewed_at,
      stock_verification_lines.inactive_reviewed_at,
      stock_verification_lines.reviewed_product_active,
      stock_verification_lines.reviewed_crate_active,
      stock_verification_lines.reviewed_zone_active,
      products.is_active as product_is_active,
      crates.is_active as crate_is_active,
      zones.is_active as zone_is_active
    from public.stock_verification_lines
    join public.products on products.id = stock_verification_lines.product_id
    join public.crates on crates.id = stock_verification_lines.crate_id
    join public.zones on zones.id = crates.zone_id
    where stock_verification_lines.verification_id = header.id
    order by stock_verification_lines.id
    for update of stock_verification_lines
  loop
    current_ids := app_private.verification_movement_ids(header.id, line.crate_id, line.product_id);
    movement_total := app_private.verification_movement_total(header.id, line.crate_id, line.product_id);
    physical := coalesce(line.recount_cases, line.counted_cases);
    reconciled := line.expected_cases + movement_total;
    variance := physical - reconciled;

    if not app_private.same_uuid_set(line.acknowledged_ledger_ids, current_ids)
      and (coalesce(pg_catalog.cardinality(current_ids), 0) > 0 or variance <> 0)
    then
      raise exception 'movement must be reconciled' using errcode = '23514';
    end if;

    if variance <> 0 and (line.recount_cases is null or line.reviewed_at is null) then
      if line.recount_cases is null then
        raise exception 'recount is required' using errcode = '23514';
      end if;
      raise exception 'discrepancy must be reviewed' using errcode = '23514';
    end if;

    if (not line.product_is_active or not line.crate_is_active or not line.zone_is_active)
      and (
        line.inactive_reviewed_at is null
        or line.reviewed_product_active is distinct from line.product_is_active
        or line.reviewed_crate_active is distinct from line.crate_is_active
        or line.reviewed_zone_active is distinct from line.zone_is_active
      )
    then
      raise exception 'inactive object must be reviewed' using errcode = '23514';
    end if;

    if variance <> 0 then
      variance_count := variance_count + 1;
    end if;

    update public.stock_verification_lines
    set
      ledger_movement_cases = movement_total,
      reconciled_expected_cases = reconciled,
      final_variance_cases = variance
    where stock_verification_lines.id = line.id;
  end loop;

  if exists (
    select 1
    from public.stock_verification_scopes
    join public.crates on crates.id = stock_verification_scopes.crate_id
    join public.zones on zones.id = stock_verification_scopes.zone_id
    where stock_verification_scopes.verification_id = header.id
      and (not crates.is_active or not zones.is_active)
      and (
        stock_verification_scopes.inactive_reviewed_at is null
        or stock_verification_scopes.reviewed_crate_active is distinct from crates.is_active
        or stock_verification_scopes.reviewed_zone_active is distinct from zones.is_active
      )
  ) then
    raise exception 'inactive object must be reviewed' using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.stock_verification_evidence
    where stock_verification_evidence.verification_id = header.id
      and stock_verification_evidence.verified_at is not null
  ) then
    raise exception 'photo evidence is required' using errcode = '23514';
  end if;

  if closure_result = 'matched' and variance_count > 0 then
    raise exception 'closure result does not match the verification' using errcode = '23514';
  end if;

  if closure_result <> 'matched' and variance_count = 0 then
    raise exception 'closure result does not match the verification' using errcode = '23514';
  end if;

  update public.stock_verifications
  set
    status = 'closed',
    closed_by = auth.uid(),
    closed_at = pg_catalog.clock_timestamp(),
    closure_result = close_stock_verification.closure_result,
    closure_note = note,
    correction_request_status = case
      when close_stock_verification.closure_result = 'correction_requested' then 'requested'
      else 'none'
    end
  where stock_verifications.id = header.id;

  perform app_private.write_audit(
    auth.uid(),
    'close_stock_verification',
    'stock_verifications',
    header.id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'closure_result', closure_result,
      'variance_lines', variance_count
    )
  );
end;
$$;

create or replace function public.list_stock_verifications()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_verification_reader();

  return pg_catalog.jsonb_build_object(
    'verifications', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_verifications.id,
        'verification_number', stock_verifications.verification_number,
        'godown_id', stock_verifications.godown_id,
        'godown_name', branches.name,
        'business_date', stock_verifications.business_date,
        'status', stock_verifications.status,
        'started_by_name', starters.full_name,
        'started_at', stock_verifications.started_at,
        'closure_result', stock_verifications.closure_result,
        'crate_count', (
          select count(*)
          from public.stock_verification_scopes
          where stock_verification_scopes.verification_id = stock_verifications.id
        ),
        'line_count', (
          select count(*)
          from public.stock_verification_lines
          where stock_verification_lines.verification_id = stock_verifications.id
        ),
        'counted_count', (
          select count(*)
          from public.stock_verification_lines
          where stock_verification_lines.verification_id = stock_verifications.id
            and stock_verification_lines.counted_cases is not null
        ),
        'discrepancy_count', (
          select count(*)
          from public.stock_verification_lines
          where stock_verification_lines.verification_id = stock_verifications.id
            and (
              (
                stock_verifications.status = 'closed'
                and coalesce(stock_verification_lines.final_variance_cases, 0) <> 0
              )
              or (
                stock_verifications.status <> 'closed'
                and stock_verification_lines.counted_cases is not null
                and coalesce(stock_verification_lines.recount_cases, stock_verification_lines.counted_cases)
                  <> stock_verification_lines.expected_cases
                    + app_private.verification_movement_total(
                      stock_verifications.id,
                      stock_verification_lines.crate_id,
                      stock_verification_lines.product_id
                    )
              )
            )
        ),
        'scope_codes', coalesce((
          select pg_catalog.string_agg(crates.code, ', ' order by crates.code)
          from public.stock_verification_scopes
          join public.crates on crates.id = stock_verification_scopes.crate_id
          where stock_verification_scopes.verification_id = stock_verifications.id
        ), '')
      ) order by stock_verifications.business_date desc, stock_verifications.started_at desc)
      from public.stock_verifications
      join public.branches on branches.id = stock_verifications.godown_id
      join public.profiles starters on starters.id = stock_verifications.started_by
      where app_private.can_view_stock_verification(stock_verifications.godown_id)
    ), '[]'::jsonb),
    'indicators', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'godown_id', branches.id,
        'godown_name', branches.name,
        'last_verification_date', (
          select max(stock_verifications.business_date)
          from public.stock_verifications
          where stock_verifications.godown_id = branches.id
            and stock_verifications.status = 'closed'
        ),
        'missing_today', not exists (
          select 1
          from public.stock_verifications
          where stock_verifications.godown_id = branches.id
            and stock_verifications.business_date = current_date
        ),
        'open_verification_id', (
          select stock_verifications.id
          from public.stock_verifications
          where stock_verifications.godown_id = branches.id
            and stock_verifications.status <> 'closed'
          limit 1
        )
      ) order by branches.code)
      from public.branches
      where branches.is_active
        and (
          app_private.has_permission('operations.monitor')
          or app_private.can_work_at_branch(branches.id)
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_stock_verification(target_verification uuid)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select app_private.stock_verification_payload(target_verification);
$$;

create or replace function app_private.can_store_verification_photo(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.stock_verification_evidence
    join public.stock_verifications
      on stock_verifications.id = stock_verification_evidence.verification_id
    where stock_verification_evidence.storage_path = object_name
      and stock_verification_evidence.verified_at is null
      and stock_verification_evidence.uploaded_by = auth.uid()
      and stock_verifications.status <> 'closed'
      and (
        app_private.has_permission('stock.verify')
        or app_private.has_permission('stock.count_assist')
      )
      and app_private.can_work_at_branch(stock_verifications.godown_id)
  );
$$;

create or replace function app_private.can_read_verification_photo(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.stock_verification_evidence
    join public.stock_verifications
      on stock_verifications.id = stock_verification_evidence.verification_id
    where stock_verification_evidence.storage_path = object_name
      and stock_verification_evidence.verified_at is not null
      and app_private.can_view_stock_verification(stock_verifications.godown_id)
  );
$$;

create or replace function public.create_verification_photo_upload(
  target_verification uuid,
  photo_note text,
  target_line uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  evidence_id uuid := pg_catalog.gen_random_uuid();
  object_path text;
  note text;
begin
  perform app_private.assert_verification_counter();
  header := app_private.lock_stock_verification(target_verification);

  if header.status = 'closed' then
    raise exception 'closed verification cannot be changed' using errcode = '42501';
  end if;

  if target_line is not null and not exists (
    select 1
    from public.stock_verification_lines
    where stock_verification_lines.id = target_line
      and stock_verification_lines.verification_id = header.id
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  note := app_private.clean_verification_text(photo_note, false);
  object_path := header.id::text || '/' || evidence_id::text;

  insert into public.stock_verification_evidence (
    id, verification_id, verification_line_id, storage_path, uploaded_by, note
  )
  values (evidence_id, header.id, target_line, object_path, auth.uid(), note);

  return pg_catalog.jsonb_build_object(
    'id', evidence_id,
    'bucket', 'stock-verification-evidence',
    'path', object_path
  );
end;
$$;

create or replace function public.finalize_verification_photo_upload(
  target_evidence uuid,
  image_base64 text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  evidence public.stock_verification_evidence;
  cleaned text;
  payload bytea;
  object_metadata jsonb;
  object_owner uuid;
  object_size bigint;
  object_etag text;
  object_mime text;
  detected_mime text;
begin
  perform app_private.assert_verification_counter();

  select *
  into evidence
  from public.stock_verification_evidence
  where stock_verification_evidence.id = target_evidence
  for update;

  if not found or evidence.uploaded_by is distinct from auth.uid() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_stock_verification(evidence.verification_id);

  if header.status = 'closed' or evidence.verified_at is not null then
    raise exception 'verification evidence cannot be changed' using errcode = '42501';
  end if;

  cleaned := pg_catalog.regexp_replace(coalesce(image_base64, ''), '\s', '', 'g');
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

  select storage.objects.metadata, storage.objects.owner
  into object_metadata, object_owner
  from storage.objects
  where storage.objects.bucket_id = 'stock-verification-evidence'
    and storage.objects.name = evidence.storage_path;

  if not found or (object_owner is not null and object_owner is distinct from evidence.uploaded_by) then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  begin
    object_size := coalesce(object_metadata ->> 'size', object_metadata ->> 'contentLength')::bigint;
  exception
    when others then
      object_size := null;
  end;

  object_etag := pg_catalog.lower(pg_catalog.replace(coalesce(object_metadata ->> 'eTag', object_metadata ->> 'etag', ''), '"', ''));
  object_mime := pg_catalog.lower(coalesce(object_metadata ->> 'mimetype', object_metadata ->> 'mimeType', object_metadata ->> 'contentType', ''));
  detected_mime := app_private.detected_image_mime(payload);

  if detected_mime is null
    or detected_mime <> object_mime
    or object_size is distinct from pg_catalog.octet_length(payload)
    or object_etag = ''
    or object_etag is distinct from pg_catalog.encode(extensions.digest(payload, 'md5'), 'hex')
  then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  update public.stock_verification_evidence
  set
    mime_type = detected_mime,
    file_size = pg_catalog.octet_length(payload),
    verified_at = pg_catalog.clock_timestamp()
  where stock_verification_evidence.id = evidence.id;

  perform app_private.write_audit(
    auth.uid(),
    'verification_photo_attached',
    'stock_verification_evidence',
    evidence.id,
    pg_catalog.jsonb_build_object(
      'verification_id', header.id,
      'mime_type', detected_mime,
      'file_size', pg_catalog.octet_length(payload)
    )
  );
end;
$$;

create or replace function public.get_verification_photo_url(target_evidence uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  evidence public.stock_verification_evidence;
  godown uuid;
begin
  perform app_private.assert_verification_reader();

  select *
  into evidence
  from public.stock_verification_evidence
  where stock_verification_evidence.id = target_evidence;

  if not found or evidence.verified_at is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select stock_verifications.godown_id
  into godown
  from public.stock_verifications
  where stock_verifications.id = evidence.verification_id;

  if godown is null or not app_private.can_view_stock_verification(godown) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'bucket', 'stock-verification-evidence',
    'path', evidence.storage_path,
    'mime_type', evidence.mime_type
  );
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'stock-verification-evidence',
  'stock-verification-evidence',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
);

create policy stock_verification_evidence_insert
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'stock-verification-evidence'
    and app_private.can_store_verification_photo(name)
  );

create policy stock_verification_evidence_select
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'stock-verification-evidence'
    and app_private.can_read_verification_photo(name)
  );

revoke all on function app_private.can_view_stock_verification(uuid) from public, anon, service_role;
revoke all on function app_private.assert_verification_reader() from public, anon, authenticated, service_role;
revoke all on function app_private.assert_verification_counter() from public, anon, authenticated, service_role;
revoke all on function app_private.clean_verification_text(text, boolean) from public, anon, authenticated, service_role;
revoke all on function app_private.same_uuid_set(uuid[], uuid[]) from public, anon, authenticated, service_role;
revoke all on function app_private.verification_movement_ids(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.verification_movement_total(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.detected_image_mime(bytea) from public, anon, authenticated, service_role;
revoke all on function app_private.lock_stock_verification(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_distinct_ids(uuid[], text) from public, anon, authenticated, service_role;
revoke all on function app_private.guard_stock_verification() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_verification_scope() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_verification_line() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_verification_count() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_verification_snapshot() from public, anon, authenticated, service_role;
revoke all on function app_private.guard_verification_evidence() from public, anon, authenticated, service_role;
revoke all on function app_private.assert_verification_scope(uuid, uuid[], uuid[]) from public, anon, authenticated, service_role;
revoke all on function app_private.verification_movements_json(uuid, uuid, uuid, uuid[]) from public, anon, authenticated, service_role;
revoke all on function app_private.stock_verification_payload(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.can_store_verification_photo(text) from public, anon, service_role;
revoke all on function app_private.can_read_verification_photo(text) from public, anon, service_role;

grant execute on function app_private.can_view_stock_verification(uuid) to authenticated;
grant execute on function app_private.can_store_verification_photo(text) to authenticated;
grant execute on function app_private.can_read_verification_photo(text) to authenticated;

revoke all on function public.start_stock_verification(uuid, date, uuid[], uuid[]) from public, anon, service_role;
revoke all on function public.preview_verification_scope(uuid, uuid[], uuid[]) from public, anon, service_role;
revoke all on function public.list_verification_options() from public, anon, service_role;
revoke all on function public.add_verification_found_product(uuid, uuid, uuid) from public, anon, service_role;
revoke all on function public.save_verification_count(uuid, jsonb, integer) from public, anon, service_role;
revoke all on function public.submit_stock_verification(uuid) from public, anon, service_role;
revoke all on function public.report_stock_discrepancy(uuid, text) from public, anon, service_role;
revoke all on function public.request_verification_recount(uuid) from public, anon, service_role;
revoke all on function public.save_verification_recount(uuid, jsonb, integer) from public, anon, service_role;
revoke all on function public.review_verification_discrepancy(uuid, text, uuid[]) from public, anon, service_role;
revoke all on function public.review_verification_inactive_object(text, uuid, text) from public, anon, service_role;
revoke all on function public.close_stock_verification(uuid, text, text) from public, anon, service_role;
revoke all on function public.list_stock_verifications() from public, anon, service_role;
revoke all on function public.get_stock_verification(uuid) from public, anon, service_role;
revoke all on function public.create_verification_photo_upload(uuid, text, uuid) from public, anon, service_role;
revoke all on function public.finalize_verification_photo_upload(uuid, text) from public, anon, service_role;
revoke all on function public.get_verification_photo_url(uuid) from public, anon, service_role;

grant execute on function public.start_stock_verification(uuid, date, uuid[], uuid[]) to authenticated;
grant execute on function public.preview_verification_scope(uuid, uuid[], uuid[]) to authenticated;
grant execute on function public.list_verification_options() to authenticated;
grant execute on function public.add_verification_found_product(uuid, uuid, uuid) to authenticated;
grant execute on function public.save_verification_count(uuid, jsonb, integer) to authenticated;
grant execute on function public.submit_stock_verification(uuid) to authenticated;
grant execute on function public.report_stock_discrepancy(uuid, text) to authenticated;
grant execute on function public.request_verification_recount(uuid) to authenticated;
grant execute on function public.save_verification_recount(uuid, jsonb, integer) to authenticated;
grant execute on function public.review_verification_discrepancy(uuid, text, uuid[]) to authenticated;
grant execute on function public.review_verification_inactive_object(text, uuid, text) to authenticated;
grant execute on function public.close_stock_verification(uuid, text, text) to authenticated;
grant execute on function public.list_stock_verifications() to authenticated;
grant execute on function public.get_stock_verification(uuid) to authenticated;
grant execute on function public.create_verification_photo_upload(uuid, text, uuid) to authenticated;
grant execute on function public.finalize_verification_photo_upload(uuid, text) to authenticated;
grant execute on function public.get_verification_photo_url(uuid) to authenticated;

alter table public.stock_verifications enable row level security;
alter table public.stock_verifications force row level security;
alter table public.stock_verification_scopes enable row level security;
alter table public.stock_verification_scopes force row level security;
alter table public.stock_verification_lines enable row level security;
alter table public.stock_verification_lines force row level security;
alter table public.stock_verification_counts enable row level security;
alter table public.stock_verification_counts force row level security;
alter table public.stock_verification_snapshot_entries enable row level security;
alter table public.stock_verification_snapshot_entries force row level security;
alter table public.stock_verification_evidence enable row level security;
alter table public.stock_verification_evidence force row level security;

revoke all on public.stock_verifications from public, anon, authenticated, service_role;
revoke all on public.stock_verification_scopes from public, anon, authenticated, service_role;
revoke all on public.stock_verification_lines from public, anon, authenticated, service_role;
revoke all on public.stock_verification_counts from public, anon, authenticated, service_role;
revoke all on public.stock_verification_snapshot_entries from public, anon, authenticated, service_role;
revoke all on public.stock_verification_evidence from public, anon, authenticated, service_role;

grant select on public.stock_verifications to authenticated;
grant select on public.stock_verification_scopes to authenticated;
grant select on public.stock_verification_lines to authenticated;
grant select on public.stock_verification_counts to authenticated;
grant select on public.stock_verification_snapshot_entries to authenticated;
grant select on public.stock_verification_evidence to authenticated;

create policy stock_verifications_select on public.stock_verifications
  for select to authenticated
  using (app_private.can_view_stock_verification(godown_id));

create policy stock_verification_scopes_select on public.stock_verification_scopes
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_verifications
      where stock_verifications.id = stock_verification_scopes.verification_id
        and app_private.can_view_stock_verification(stock_verifications.godown_id)
    )
  );

create policy stock_verification_lines_select on public.stock_verification_lines
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_verifications
      where stock_verifications.id = stock_verification_lines.verification_id
        and app_private.can_view_stock_verification(stock_verifications.godown_id)
    )
  );

create policy stock_verification_counts_select on public.stock_verification_counts
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_verifications
      where stock_verifications.id = stock_verification_counts.verification_id
        and app_private.can_view_stock_verification(stock_verifications.godown_id)
    )
  );

create policy stock_verification_snapshot_select on public.stock_verification_snapshot_entries
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_verifications
      where stock_verifications.id = stock_verification_snapshot_entries.verification_id
        and app_private.can_view_stock_verification(stock_verifications.godown_id)
    )
  );

create policy stock_verification_evidence_read on public.stock_verification_evidence
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_verifications
      where stock_verifications.id = stock_verification_evidence.verification_id
        and app_private.can_view_stock_verification(stock_verifications.godown_id)
    )
  );

create or replace function app_private.lock_open_verifications(verification_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if verification_ids is null then
    return;
  end if;

  perform stock_verifications.id
  from public.stock_verifications
  where stock_verifications.id = any (verification_ids)
    and stock_verifications.status <> 'closed'
  order by stock_verifications.id
  for update;
end;
$$;

revoke all on function app_private.lock_open_verifications(uuid[]) from public, anon, authenticated, service_role;

create or replace function public.set_product_active(target_product uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('products.manage');

  perform products.id
  from public.products
  where products.id = target_product
  for update;

  if not found then
    raise exception 'product not found' using errcode = '42501';
  end if;

  perform app_private.lock_open_verifications(array(
    select distinct stock_verification_lines.verification_id
    from public.stock_verification_lines
    where stock_verification_lines.product_id = target_product
  ));

  update public.products
  set is_active = active
  where products.id = target_product;

  perform app_private.write_audit(
    auth.uid(),
    'set_product_active',
    'products',
    target_product,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.set_zone_active(target_zone uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
begin
  perform app_private.assert_permission('locations.manage');

  select zones.branch_id
  into selected_branch
  from public.zones
  where zones.id = target_zone;

  if selected_branch is null then
    raise exception 'zone not found' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);

  perform app_private.lock_open_verifications(array(
    select distinct stock_verification_scopes.verification_id
    from public.stock_verification_scopes
    where stock_verification_scopes.zone_id = target_zone
  ));

  perform zones.id
  from public.zones
  where zones.id = target_zone
  for update;

  if not found then
    raise exception 'zone not found' using errcode = '42501';
  end if;

  perform crates.id
  from public.crates
  where crates.zone_id = target_zone
  order by crates.id
  for update;

  perform stock_balances.crate_id
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  where crates.zone_id = target_zone
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  if not active and exists (
    select 1
    from public.stock_balances
    join public.crates on crates.id = stock_balances.crate_id
    where crates.zone_id = target_zone
      and stock_balances.quantity > 0
  ) then
    raise exception 'zone still holds stock' using errcode = '23514';
  end if;

  update public.zones
  set is_active = active
  where zones.id = target_zone;

  perform app_private.write_audit(
    auth.uid(),
    'set_zone_active',
    'zones',
    target_zone,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.set_crate_active(target_crate uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  selected_zone uuid;
  zone_is_active boolean;
begin
  perform app_private.assert_permission('locations.manage');

  select zones.id, zones.branch_id, zones.is_active
  into selected_zone, selected_branch, zone_is_active
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = target_crate;

  if selected_branch is null then
    raise exception 'crate not found' using errcode = '42501';
  end if;

  if active and not zone_is_active then
    raise exception 'zone not found or inactive' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);

  perform app_private.lock_open_verifications(array(
    select distinct stock_verification_scopes.verification_id
    from public.stock_verification_scopes
    where stock_verification_scopes.crate_id = target_crate
  ));

  perform zones.id
  from public.zones
  where zones.id = selected_zone
  for update;

  perform crates.id
  from public.crates
  where crates.id = target_crate
  for update;

  perform stock_balances.product_id
  from public.stock_balances
  where stock_balances.crate_id = target_crate
  order by stock_balances.product_id
  for update;

  if not active and exists (
    select 1
    from public.stock_balances
    where stock_balances.crate_id = target_crate
      and stock_balances.quantity > 0
  ) then
    raise exception 'crate still holds stock' using errcode = '23514';
  end if;

  update public.crates
  set is_active = active
  where crates.id = target_crate;

  perform app_private.write_audit(
    auth.uid(),
    'set_crate_active',
    'crates',
    target_crate,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

comment on function public.start_stock_verification(uuid, date, uuid[], uuid[]) is
  'Godown Manager freezes expected stock for selected crates. The ledger id set is the movement boundary.';

comment on function public.close_stock_verification(uuid, text, text) is
  'Records the physical check. Does not post stock or change balances.';
