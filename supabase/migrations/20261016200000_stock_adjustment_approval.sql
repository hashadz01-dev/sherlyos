-- Phase 3.3 stock adjustment approval. Local migration. It does not run on
-- development until Phase 3.2 is deployed there. Closing a verification still
-- does not change stock. Approval does not post. Posting is a separate action.
--
-- Posting locks the request, then the line products, then zones and crates
-- through prepare_stock_locations, then balance rows. Product locks come
-- before locations so a receipt, which locks products before locations,
-- cannot deadlock with the post. A transfer locks locations first and then
-- waits; the post does not take a location lock while waiting on a product
-- the transfer already passed.
--
-- Movement rule at post: the close baseline for a line is the snapshot ledger
-- ids for that crate and product plus the line's acknowledged ledger ids.
-- Any later ledger row for that crate and product makes the discrepancy
-- unprovable. The request stays approved and must not post. A fresh
-- verification is required. Net-zero movements are not treated as safe.
-- The posted quantity is the stored variance, never a recalculated remainder.
--
-- Compensation is closed in this phase. compensates_request_id stays in the
-- table for a later approved reversal design, and it must stay null. A
-- non-null value is rejected by the check, the write guard, and every
-- request function. Nothing rewrites it into an ordinary adjustment.

update public.app_configuration
set
  value = '10'::jsonb,
  description = 'Approved Phase 3.3 rule. Whole carton cases per line. A line whose absolute quantity is greater than this value makes the whole request exceptional. 10 is ordinary. 11 is exceptional. The earlier placeholder 50 is not used.'
where key = 'stock.adjustment.exceptional_absolute_units';

create sequence public.stock_adjustment_seq as bigint;

revoke all on sequence public.stock_adjustment_seq from public, anon, authenticated, service_role;

create table public.stock_adjustment_requests (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  request_number text not null,
  godown_id uuid not null references public.branches (id) on delete restrict,
  verification_id uuid not null references public.stock_verifications (id) on delete restrict,
  evidence_id uuid not null references public.stock_verification_evidence (id) on delete restrict,
  compensates_request_id uuid references public.stock_adjustment_requests (id) on delete restrict,
  status text not null,
  exceptional boolean,
  version integer not null default 1,
  reason_code text not null,
  note text not null,
  requested_by uuid not null references public.profiles (id) on delete restrict,
  approved_by uuid references public.profiles (id) on delete restrict,
  approved_at timestamptz,
  posted_by uuid references public.profiles (id) on delete restrict,
  posted_at timestamptz,
  posted_transaction_id uuid,
  idempotency_key text not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_adjustment_requests_number_key unique (request_number),
  constraint stock_adjustment_requests_idempotency_key unique (idempotency_key),
  constraint stock_adjustment_requests_version_check check (version > 0),
  constraint stock_adjustment_requests_status_check check (
    status in ('draft', 'submitted', 'returned', 'approved', 'rejected', 'posted')
  ),
  constraint stock_adjustment_requests_reason_check check (
    reason_code in ('shortage', 'surplus', 'mixed')
  ),
  constraint stock_adjustment_requests_note_check check (
    pg_catalog.char_length(note) between 1 and 500
  ),
  constraint stock_adjustment_requests_compensation_closed check (
    compensates_request_id is null
  ),
  constraint stock_adjustment_requests_approval_check check (
    (
      status in ('approved', 'posted')
      and approved_by is not null
      and approved_at is not null
      and exceptional is not null
    )
    or (
      status not in ('approved', 'posted')
      and approved_by is null
      and approved_at is null
    )
  ),
  constraint stock_adjustment_requests_post_check check (
    (
      status = 'posted'
      and posted_by is not null
      and posted_at is not null
      and posted_transaction_id is not null
    )
    or (
      status <> 'posted'
      and posted_by is null
      and posted_at is null
      and posted_transaction_id is null
    )
  )
);

create index stock_adjustment_requests_godown_idx
  on public.stock_adjustment_requests (godown_id, created_at desc);

create index stock_adjustment_requests_verification_idx
  on public.stock_adjustment_requests (verification_id);

comment on table public.stock_adjustment_requests is
  'A request to post a reviewed verification variance. Approval does not change stock.';

comment on column public.stock_adjustment_requests.compensates_request_id is
  'Reserved for a future approved reversal. Phase 3.3 rejects every non-null value.';

create table public.stock_adjustment_lines (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null references public.stock_adjustment_requests (id) on delete restrict,
  verification_line_id uuid not null references public.stock_verification_lines (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  variance_cases integer not null,
  requested_cases integer not null,
  released boolean not null default false,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_adjustment_lines_request_line_key unique (request_id, verification_line_id),
  constraint stock_adjustment_lines_quantity_check check (
    variance_cases <> 0
    and requested_cases = variance_cases
    and requested_cases between -1000000 and 1000000
  )
);

create unique index stock_adjustment_lines_active_claim
  on public.stock_adjustment_lines (verification_line_id)
  where not released;

create index stock_adjustment_lines_request_idx
  on public.stock_adjustment_lines (request_id);

comment on table public.stock_adjustment_lines is
  'Full verification variances claimed by a request. Rejected requests release the claim. Posted claims stay.';

create table public.stock_adjustment_events (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null references public.stock_adjustment_requests (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  from_status text,
  to_status text not null,
  request_version integer not null,
  note text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_adjustment_events_type_check check (
    event_type in (
      'created', 'lines_revised', 'submitted', 'returned', 'approved', 'rejected', 'posted'
    )
  ),
  constraint stock_adjustment_events_version_check check (request_version > 0),
  constraint stock_adjustment_events_note_check check (
    note is null or pg_catalog.char_length(note) between 1 and 500
  )
);

create index stock_adjustment_events_request_idx
  on public.stock_adjustment_events (request_id, created_at);

comment on table public.stock_adjustment_events is
  'Append-only adjustment history. Rows cannot be updated or deleted.';

alter table public.stock_transactions
  add column adjustment_request_id uuid references public.stock_adjustment_requests (id) on delete restrict;

alter table public.stock_adjustment_requests
  add constraint stock_adjustment_requests_transaction_fk
  foreign key (posted_transaction_id) references public.stock_transactions (id) on delete restrict;

alter table public.stock_transactions
  drop constraint stock_transactions_type_check,
  add constraint stock_transactions_type_check
    check (transaction_type in ('OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT'));

alter table public.stock_transactions
  drop constraint stock_transactions_shape_check,
  add constraint stock_transactions_shape_check check (
    (
      transaction_type = 'OPENING_STOCK'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
    )
    or (
      transaction_type = 'CRATE_TRANSFER'
      and source_crate_id is not null
      and destination_crate_id is not null
      and source_crate_id <> destination_crate_id
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
    )
    or (
      transaction_type = 'RECEIPT'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is not null
      and receipt_line_id is not null
      and adjustment_request_id is null
    )
    or (
      transaction_type = 'ADJUSTMENT'
      and source_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is not null
    )
  );

create unique index stock_transactions_adjustment_once
  on public.stock_transactions (adjustment_request_id)
  where adjustment_request_id is not null;

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
  line_count integer;
  line_sum integer;
begin
  select
    stock_transactions.transaction_type,
    stock_transactions.receipt_id,
    stock_transactions.receipt_line_id,
    stock_transactions.adjustment_request_id
  into selected_type, linked_receipt, linked_line, linked_adjustment
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
    select count(*), coalesce(sum(stock_adjustment_lines.requested_cases), 0)
    into line_count, line_sum
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = linked_adjustment
      and not stock_adjustment_lines.released;

    if linked_adjustment is null or entry_count <> line_count or entry_sum is distinct from line_sum or entry_count < 1 then
      raise exception 'adjustment ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type not in ('OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT') then
    raise exception 'stock transaction type is not supported' using errcode = '23514';
  end if;

  return null;
end;
$$;

create or replace function app_private.guard_adjustment_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'stock_adjustment_requests' and tg_op in ('INSERT', 'UPDATE') then
    if (pg_catalog.to_jsonb(new) ->> 'compensates_request_id') is not null then
      raise exception 'compensation is not available' using errcode = '23514';
    end if;
  end if;

  if pg_catalog.current_setting('app.adjustment_write', true) is distinct from 'on' then
    raise exception 'adjustment records cannot be changed directly' using errcode = '42501';
  end if;

  if tg_table_name = 'stock_adjustment_events' and tg_op <> 'INSERT' then
    raise exception 'adjustment history cannot be changed' using errcode = '42501';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger stock_adjustment_requests_guard
  before insert or update or delete on public.stock_adjustment_requests
  for each row execute function app_private.guard_adjustment_write();

create trigger stock_adjustment_lines_guard
  before insert or update or delete on public.stock_adjustment_lines
  for each row execute function app_private.guard_adjustment_write();

create trigger stock_adjustment_events_guard
  before insert or update or delete on public.stock_adjustment_events
  for each row execute function app_private.guard_adjustment_write();

revoke all on function app_private.guard_adjustment_write() from public, anon, authenticated, service_role;

create or replace function app_private.adjustment_threshold()
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  configured integer;
begin
  select (app_configuration.value #>> '{}')::integer
  into configured
  from public.app_configuration
  where app_configuration.key = 'stock.adjustment.exceptional_absolute_units';

  if configured is distinct from 10 then
    raise exception 'adjustment threshold is not the approved value' using errcode = '23514';
  end if;

  return configured;
end;
$$;

create or replace function app_private.can_view_stock_adjustment(target_godown uuid)
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
        app_private.has_permission('stock.read')
        or app_private.has_permission('stock.adjustment.request')
        or app_private.has_permission('stock.adjustment.post')
        or app_private.has_permission('stock.adjustment.approve_exceptional')
      )
      and app_private.can_work_at_branch(target_godown)
    );
$$;

create or replace function app_private.other_adjustment_manager_exists(
  target_godown uuid,
  requester uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles
    join public.roles on roles.id = user_roles.role_id
    join public.profiles on profiles.id = user_roles.user_id
    join public.user_branch_assignments
      on user_branch_assignments.user_id = user_roles.user_id
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code = 'stock.adjustment.post'
      and profiles.is_active
      and user_branch_assignments.branch_id = target_godown
      and user_roles.user_id <> requester
  );
$$;

create or replace function app_private.adjustment_event(
  target_request uuid,
  event_name text,
  from_status text,
  to_status text,
  request_version integer,
  event_note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.stock_adjustment_events (
    request_id, event_type, actor_id, from_status, to_status, request_version, note
  )
  values (
    target_request, event_name, auth.uid(), from_status, to_status, request_version, event_note
  );
end;
$$;



create or replace function app_private.adjustment_event(
  target_request uuid,
  event_name text,
  from_status text,
  to_status text,
  request_version integer,
  event_note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.stock_adjustment_events (
    request_id, event_type, actor_id, from_status, to_status, request_version, note
  )
  values (
    target_request, event_name, auth.uid(), from_status, to_status, request_version, event_note
  );
end;
$$;

create or replace function app_private.lock_adjustment_request(
  target_request uuid,
  expected_version integer
)
returns public.stock_adjustment_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
begin
  perform set_config('app.adjustment_write', 'on', true);

  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request
  for update;

  if not found or not app_private.can_view_stock_adjustment(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'adjustment was changed by someone else' using errcode = '40001';
  end if;

  return selected;
end;
$$;

create or replace function app_private.assert_adjustment_approver(
  selected public.stock_adjustment_requests
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  other_manager boolean;
begin
  if auth.uid() is null or auth.uid() = selected.requested_by then
    raise exception 'you cannot approve your own adjustment' using errcode = '42501';
  end if;

  other_manager := app_private.other_adjustment_manager_exists(selected.godown_id, selected.requested_by);

  if selected.exceptional then
    perform app_private.assert_permission('stock.adjustment.approve_exceptional');
    return;
  end if;

  if other_manager then
    perform app_private.assert_permission('stock.adjustment.post');
    if not app_private.can_work_at_branch(selected.godown_id) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if app_private.has_permission('stock.adjustment.approve_exceptional')
      and not app_private.has_permission('stock.adjustment.post') then
      raise exception 'an assigned godown manager must approve this request' using errcode = '42501';
    end if;
    return;
  end if;

  perform app_private.assert_permission('stock.adjustment.approve_exceptional');
end;
$$;

create or replace function app_private.adjustment_reason_for(target_request uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when bool_and(stock_adjustment_lines.requested_cases < 0) then 'shortage'
    when bool_and(stock_adjustment_lines.requested_cases > 0) then 'surplus'
    else 'mixed'
  end
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = target_request
    and not stock_adjustment_lines.released;
$$;

create or replace function app_private.replace_adjustment_lines(
  selected public.stock_adjustment_requests,
  line_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  evidence uuid;
  line public.stock_verification_lines;
  selected_id uuid;
  reason text;
begin
  if line_ids is null or pg_catalog.cardinality(line_ids) < 1 then
    raise exception 'an adjustment line is required' using errcode = '23514';
  end if;

  if (
    select count(distinct selected_line)
    from pg_catalog.unnest(line_ids) selected_line
  ) <> pg_catalog.cardinality(line_ids) then
    raise exception 'adjustment line is repeated' using errcode = '23514';
  end if;

  select stock_verification_evidence.id
  into evidence
  from public.stock_verification_evidence
  where stock_verification_evidence.verification_id = selected.verification_id
    and stock_verification_evidence.verified_at is not null
  order by stock_verification_evidence.verified_at, stock_verification_evidence.id
  limit 1;

  if evidence is null then
    raise exception 'photo evidence is required' using errcode = '23514';
  end if;

  delete from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id;

  foreach selected_id in array line_ids loop
    select *
    into line
    from public.stock_verification_lines
    where stock_verification_lines.id = selected_id
      and stock_verification_lines.verification_id = selected.verification_id;

    if not found
      or line.counted_cases is null
      or line.recount_cases is null
      or line.discrepancy_status <> 'reviewed'
      or line.reviewed_by is null
      or line.final_variance_cases is null
      or line.final_variance_cases = 0
      or line.reconciled_expected_cases is null
      or line.final_variance_cases is distinct from (line.recount_cases - line.reconciled_expected_cases)
    then
      raise exception 'verification line cannot be adjusted' using errcode = '23514';
    end if;

    insert into public.stock_adjustment_lines (
      request_id, verification_line_id, crate_id, product_id, variance_cases, requested_cases
    )
    values (
      selected.id, line.id, line.crate_id, line.product_id, line.final_variance_cases, line.final_variance_cases
    );
  end loop;

  reason := app_private.adjustment_reason_for(selected.id);
  if reason is null or selected.reason_code is distinct from reason then
    raise exception 'adjustment reason does not match the lines' using errcode = '23514';
  end if;

  update public.stock_adjustment_requests
  set evidence_id = evidence, updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;
end;
$$;

create or replace function public.create_stock_adjustment(
  target_verification uuid,
  reason_code text,
  request_note text,
  line_ids uuid[],
  idempotency_key text,
  compensates_request uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  cleaned_key text;
  cleaned_note text;
  cleaned_reason text;
  request_id uuid;
  request_number text;
  existing public.stock_adjustment_requests;
begin
  perform set_config('app.adjustment_write', 'on', true);
  perform app_private.assert_permission('stock.adjustment.request');
  if compensates_request is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_note := app_private.clean_verification_text(request_note, true);
  cleaned_reason := pg_catalog.lower(pg_catalog.btrim(coalesce(reason_code, '')));

  if cleaned_reason not in ('shortage', 'surplus', 'mixed') then
    raise exception 'adjustment reason is invalid' using errcode = '23514';
  end if;

  select *
  into existing
  from public.stock_adjustment_requests
  where stock_adjustment_requests.idempotency_key = cleaned_key;

  if found then
    if not app_private.can_view_stock_adjustment(existing.godown_id) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return pg_catalog.jsonb_build_object('id', existing.id, 'request_number', existing.request_number);
  end if;

  select *
  into header
  from public.stock_verifications
  where stock_verifications.id = target_verification;

  if not found or header.status <> 'closed' or not app_private.can_work_at_branch(header.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  request_number := 'AJ-' || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
    || '-' || pg_catalog.lpad(pg_catalog.nextval('public.stock_adjustment_seq')::text, 6, '0');

  insert into public.stock_adjustment_requests (
    request_number, godown_id, verification_id, evidence_id, compensates_request_id,
    status, reason_code, note, requested_by, idempotency_key
  )
  select
    request_number,
    header.godown_id,
    header.id,
    stock_verification_evidence.id,
    compensates_request,
    'draft',
    cleaned_reason,
    cleaned_note,
    auth.uid(),
    cleaned_key
  from public.stock_verification_evidence
  where stock_verification_evidence.verification_id = header.id
    and stock_verification_evidence.verified_at is not null
  order by stock_verification_evidence.verified_at, stock_verification_evidence.id
  limit 1
  returning id into request_id;

  if request_id is null then
    raise exception 'photo evidence is required' using errcode = '23514';
  end if;

  perform app_private.replace_adjustment_lines(
    (select stock_adjustment_requests from public.stock_adjustment_requests where id = request_id),
    line_ids
  );
  perform app_private.adjustment_event(request_id, 'created', null, 'draft', 1, cleaned_note);

  return pg_catalog.jsonb_build_object('id', request_id, 'request_number', request_number);
end;
$$;

create or replace function public.set_stock_adjustment_lines(
  target_request uuid,
  expected_version integer,
  reason_code text,
  request_note text,
  line_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
  cleaned_reason text;
  cleaned_note text;
begin
  perform app_private.assert_permission('stock.adjustment.request');
  selected := app_private.lock_adjustment_request(target_request, expected_version);

  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;

  if selected.requested_by <> auth.uid() or selected.status not in ('draft', 'returned') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  cleaned_reason := pg_catalog.lower(pg_catalog.btrim(coalesce(reason_code, '')));
  cleaned_note := app_private.clean_verification_text(request_note, true);
  if cleaned_reason not in ('shortage', 'surplus', 'mixed') then
    raise exception 'adjustment reason is invalid' using errcode = '23514';
  end if;

  update public.stock_adjustment_requests
  set
    reason_code = cleaned_reason,
    note = cleaned_note,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  selected.reason_code := cleaned_reason;
  selected.version := selected.version + 1;
  perform app_private.replace_adjustment_lines(selected, line_ids);
  perform app_private.adjustment_event(
    selected.id, 'lines_revised', selected.status, selected.status, selected.version, cleaned_note
  );
end;
$$;

create or replace function public.submit_stock_adjustment(
  target_request uuid,
  expected_version integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
  line_count integer;
  is_exceptional boolean;
begin
  perform app_private.assert_permission('stock.adjustment.request');
  selected := app_private.lock_adjustment_request(target_request, expected_version);

  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;

  if selected.requested_by <> auth.uid() or selected.status not in ('draft', 'returned') then
    raise exception 'adjustment cannot be submitted' using errcode = '42501';
  end if;

  select count(*)
  into line_count
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  if line_count < 1 then
    raise exception 'an adjustment line is required' using errcode = '23514';
  end if;

  is_exceptional := exists (
    select 1
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
      and pg_catalog.abs(stock_adjustment_lines.requested_cases) > app_private.adjustment_threshold()
  );

  update public.stock_adjustment_requests
  set
    status = 'submitted',
    exceptional = is_exceptional,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'submitted', selected.status, 'submitted', selected.version + 1, selected.note
  );
end;
$$;

create or replace function public.return_stock_adjustment(
  target_request uuid,
  expected_version integer,
  return_note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
  cleaned_note text;
begin
  selected := app_private.lock_adjustment_request(target_request, expected_version);
  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;
  perform app_private.assert_adjustment_approver(selected);
  cleaned_note := app_private.clean_verification_text(return_note, true);

  if selected.status not in ('submitted', 'approved') then
    raise exception 'adjustment cannot be returned' using errcode = '42501';
  end if;

  update public.stock_adjustment_requests
  set
    status = 'returned',
    approved_by = null,
    approved_at = null,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'returned', selected.status, 'returned', selected.version + 1, cleaned_note
  );
end;
$$;

create or replace function public.reject_stock_adjustment(
  target_request uuid,
  expected_version integer,
  reject_note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
  cleaned_note text;
begin
  selected := app_private.lock_adjustment_request(target_request, expected_version);
  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;
  perform app_private.assert_adjustment_approver(selected);
  cleaned_note := app_private.clean_verification_text(reject_note, true);

  if selected.status not in ('submitted', 'approved') then
    raise exception 'adjustment cannot be rejected' using errcode = '42501';
  end if;

  update public.stock_adjustment_lines
  set released = true
  where stock_adjustment_lines.request_id = selected.id;

  update public.stock_adjustment_requests
  set
    status = 'rejected',
    approved_by = null,
    approved_at = null,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'rejected', selected.status, 'rejected', selected.version + 1, cleaned_note
  );
end;
$$;



create or replace function public.approve_stock_adjustment(
  target_request uuid,
  expected_version integer,
  approval_note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
  cleaned_note text;
begin
  selected := app_private.lock_adjustment_request(target_request, expected_version);
  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;
  perform app_private.assert_adjustment_approver(selected);
  cleaned_note := app_private.clean_verification_text(approval_note, true);

  if selected.status <> 'submitted' then
    raise exception 'adjustment cannot be approved' using errcode = '42501';
  end if;

  update public.stock_adjustment_requests
  set
    status = 'approved',
    approved_by = auth.uid(),
    approved_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'approved', 'submitted', 'approved', selected.version + 1, cleaned_note
  );
end;
$$;

create or replace function public.post_stock_adjustment(
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
  selected public.stock_adjustment_requests;
  cleaned_key text;
  fingerprint text;
  replay jsonb;
  crate_ids uuid[];
  line record;
  baseline_quantity integer;
  later_count integer;
  created_id uuid;
  absolute_quantity integer;
  single_crate uuid;
begin
  perform set_config('app.adjustment_write', 'on', true);
  perform app_private.assert_permission('stock.adjustment.post');

  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request
  for update;

  if not found or not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  if selected.status = 'posted' then
    select pg_catalog.jsonb_build_object('id', stock_transactions.id, 'reference_number', stock_transactions.reference_number)
    into replay
    from public.stock_transactions
    where stock_transactions.adjustment_request_id = selected.id
      and stock_transactions.idempotency_key = cleaned_key;

    if replay is null then
      raise exception 'adjustment was already posted' using errcode = '23505';
    end if;
    return replay;
  end if;

  if selected.version is distinct from expected_version or selected.status <> 'approved' then
    raise exception 'adjustment cannot be posted' using errcode = '42501';
  end if;

  fingerprint := 'ADJUSTMENT:' || selected.id::text || ':' || selected.version::text;

  select coalesce(pg_catalog.array_agg(distinct stock_adjustment_lines.crate_id), '{}')
  into crate_ids
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  if pg_catalog.cardinality(crate_ids) < 1 then
    raise exception 'an adjustment line is required' using errcode = '23514';
  end if;

  perform products.id
  from public.products
  where products.id in (
    select stock_adjustment_lines.product_id
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
  )
  order by products.id
  for update;

  if app_private.prepare_stock_locations(crate_ids) is distinct from selected.godown_id then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform stock_balances.crate_id
  from public.stock_balances
  join public.stock_adjustment_lines
    on stock_adjustment_lines.crate_id = stock_balances.crate_id
    and stock_adjustment_lines.product_id = stock_balances.product_id
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  for line in
    select
      stock_adjustment_lines.requested_cases,
      stock_adjustment_lines.crate_id,
      stock_adjustment_lines.product_id,
      stock_verification_lines.reconciled_expected_cases,
      stock_verification_lines.acknowledged_ledger_ids,
      stock_verification_lines.recount_cases,
      stock_verification_lines.final_variance_cases
    from public.stock_adjustment_lines
    join public.stock_verification_lines
      on stock_verification_lines.id = stock_adjustment_lines.verification_line_id
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  loop
    if line.final_variance_cases is distinct from line.requested_cases
      or line.final_variance_cases is distinct from (line.recount_cases - line.reconciled_expected_cases)
    then
      raise exception 'verification line cannot be adjusted' using errcode = '23514';
    end if;

    select count(*)
    into later_count
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id
      and not (
        stock_ledger.id = any (coalesce(line.acknowledged_ledger_ids, '{}'))
        or exists (
          select 1
          from public.stock_verification_snapshot_entries snapshot_entries
          where snapshot_entries.verification_id = selected.verification_id
            and snapshot_entries.ledger_id = stock_ledger.id
        )
      );

    if later_count > 0 then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;

    select coalesce(sum(stock_ledger.quantity), 0)
    into baseline_quantity
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id;

    if baseline_quantity is distinct from line.reconciled_expected_cases then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;
  end loop;

  select coalesce(sum(pg_catalog.abs(stock_adjustment_lines.requested_cases)), 0)
  into absolute_quantity
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  select case when count(distinct stock_adjustment_lines.crate_id) = 1
    then (pg_catalog.array_agg(stock_adjustment_lines.crate_id))[1] else null end
  into single_crate
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, destination_crate_id, quantity, adjustment_request_id
  )
  select
    'ADJUSTMENT',
    selected.request_number,
    auth.uid(),
    cleaned_key,
    fingerprint,
    selected.note,
    stock_adjustment_lines.product_id,
    single_crate,
    absolute_quantity,
    selected.id
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  limit 1
  returning id into created_id;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at
  )
  select
    created_id,
    stock_adjustment_lines.product_id,
    stock_adjustment_lines.crate_id,
    stock_adjustment_lines.requested_cases,
    auth.uid(),
    pg_catalog.clock_timestamp()
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id;

  for line in
    select stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id, stock_adjustment_lines.requested_cases
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  loop
    perform app_private.apply_stock_delta(line.crate_id, line.product_id, line.requested_cases);
  end loop;

  update public.stock_adjustment_requests
  set
    status = 'posted',
    posted_by = auth.uid(),
    posted_at = pg_catalog.clock_timestamp(),
    posted_transaction_id = created_id,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'posted', 'approved', 'posted', selected.version + 1, selected.note
  );
  perform app_private.write_audit(
    auth.uid(),
    'post_stock_adjustment',
    'stock_adjustment_requests',
    selected.id,
    pg_catalog.jsonb_build_object('transaction_id', created_id, 'request_number', selected.request_number)
  );

  return pg_catalog.jsonb_build_object('id', created_id, 'reference_number', selected.request_number);
end;
$$;

create or replace function public.list_adjustment_candidates()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.adjustment.request');
  return coalesce((
    select pg_catalog.jsonb_agg(row_payload order by business_date desc, verification_number)
    from (
      select pg_catalog.jsonb_build_object(
        'verification_id', stock_verifications.id,
        'verification_number', stock_verifications.verification_number,
        'godown_id', stock_verifications.godown_id,
        'godown_name', branches.name,
        'business_date', stock_verifications.business_date,
        'evidence_id', (
          select stock_verification_evidence.id
          from public.stock_verification_evidence
          where stock_verification_evidence.verification_id = stock_verifications.id
            and stock_verification_evidence.verified_at is not null
          order by stock_verification_evidence.verified_at, stock_verification_evidence.id
          limit 1
        ),
        'lines', (
          select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'line_id', stock_verification_lines.id,
            'crate_code', crates.code,
            'sku', products.sku,
            'product_name', products.name,
            'expected_cases', stock_verification_lines.expected_cases,
            'physical_cases', stock_verification_lines.recount_cases,
            'variance_cases', stock_verification_lines.final_variance_cases
          ) order by crates.code, products.sku), '[]'::jsonb)
          from public.stock_verification_lines
          join public.crates on crates.id = stock_verification_lines.crate_id
          join public.products on products.id = stock_verification_lines.product_id
          where stock_verification_lines.verification_id = stock_verifications.id
            and stock_verification_lines.final_variance_cases <> 0
            and stock_verification_lines.recount_cases is not null
            and stock_verification_lines.discrepancy_status = 'reviewed'
            and not exists (
              select 1
              from public.stock_adjustment_lines
              where stock_adjustment_lines.verification_line_id = stock_verification_lines.id
                and not stock_adjustment_lines.released
            )
        )
      ) as row_payload,
      stock_verifications.business_date,
      stock_verifications.verification_number
      from public.stock_verifications
      join public.branches on branches.id = stock_verifications.godown_id
      where stock_verifications.status = 'closed'
        and app_private.can_work_at_branch(stock_verifications.godown_id)
        and exists (
          select 1
          from public.stock_verification_evidence
          where stock_verification_evidence.verification_id = stock_verifications.id
            and stock_verification_evidence.verified_at is not null
        )
    ) candidates
    where candidates.row_payload -> 'lines' <> '[]'::jsonb
  ), '[]'::jsonb);
end;
$$;

create or replace function public.list_stock_adjustments()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', stock_adjustment_requests.id,
    'request_number', stock_adjustment_requests.request_number,
    'godown_id', stock_adjustment_requests.godown_id,
    'godown_name', branches.name,
    'verification_id', stock_adjustment_requests.verification_id,
    'verification_number', stock_verifications.verification_number,
    'status', stock_adjustment_requests.status,
    'exceptional', stock_adjustment_requests.exceptional,
    'requested_by_name', requester.full_name,
    'created_at', stock_adjustment_requests.created_at,
    'version', stock_adjustment_requests.version
  ) order by stock_adjustment_requests.created_at desc), '[]'::jsonb)
  from public.stock_adjustment_requests
  join public.branches on branches.id = stock_adjustment_requests.godown_id
  join public.stock_verifications on stock_verifications.id = stock_adjustment_requests.verification_id
  join public.profiles requester on requester.id = stock_adjustment_requests.requested_by
  where app_private.can_view_stock_adjustment(stock_adjustment_requests.godown_id);
$$;

create or replace function public.get_stock_adjustment(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
begin
  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request;

  if not found or not app_private.can_view_stock_adjustment(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', selected.id,
    'request_number', selected.request_number,
    'godown_id', selected.godown_id,
    'godown_name', (select branches.name from public.branches where branches.id = selected.godown_id),
    'verification_id', selected.verification_id,
    'verification_number', (
      select stock_verifications.verification_number
      from public.stock_verifications
      where stock_verifications.id = selected.verification_id
    ),
    'evidence_id', selected.evidence_id,
    'compensates_request_id', selected.compensates_request_id,
    'status', selected.status,
    'exceptional', selected.exceptional,
    'version', selected.version,
    'reason_code', selected.reason_code,
    'note', selected.note,
    'requested_by', selected.requested_by,
    'requested_by_name', (select profiles.full_name from public.profiles where profiles.id = selected.requested_by),
    'approved_by_name', (select profiles.full_name from public.profiles where profiles.id = selected.approved_by),
    'posted_by_name', (select profiles.full_name from public.profiles where profiles.id = selected.posted_by),
    'other_manager_exists', app_private.other_adjustment_manager_exists(selected.godown_id, selected.requested_by),
    'lines', (
      select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_adjustment_lines.id,
        'verification_line_id', stock_adjustment_lines.verification_line_id,
        'crate_code', crates.code,
        'sku', products.sku,
        'product_name', products.name,
        'requested_cases', stock_adjustment_lines.requested_cases,
        'current_cases', (
          select stock_balances.quantity
          from public.stock_balances
          where stock_balances.crate_id = stock_adjustment_lines.crate_id
            and stock_balances.product_id = stock_adjustment_lines.product_id
        )
      ) order by crates.code, products.sku), '[]'::jsonb)
      from public.stock_adjustment_lines
      join public.crates on crates.id = stock_adjustment_lines.crate_id
      join public.products on products.id = stock_adjustment_lines.product_id
      where stock_adjustment_lines.request_id = selected.id
    ),
    'events', (
      select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'event_type', stock_adjustment_events.event_type,
        'actor_name', profiles.full_name,
        'from_status', stock_adjustment_events.from_status,
        'to_status', stock_adjustment_events.to_status,
        'request_version', stock_adjustment_events.request_version,
        'note', stock_adjustment_events.note,
        'created_at', stock_adjustment_events.created_at
      ) order by stock_adjustment_events.created_at), '[]'::jsonb)
      from public.stock_adjustment_events
      join public.profiles on profiles.id = stock_adjustment_events.actor_id
      where stock_adjustment_events.request_id = selected.id
    )
  );
end;
$$;

revoke all on function app_private.adjustment_threshold() from public, anon, authenticated, service_role;
revoke all on function app_private.can_view_stock_adjustment(uuid) from public, anon, service_role;
revoke all on function app_private.other_adjustment_manager_exists(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.adjustment_event(uuid, text, text, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function app_private.lock_adjustment_request(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_adjustment_approver(public.stock_adjustment_requests) from public, anon, authenticated, service_role;
revoke all on function app_private.adjustment_reason_for(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.replace_adjustment_lines(public.stock_adjustment_requests, uuid[]) from public, anon, authenticated, service_role;

revoke all on function public.create_stock_adjustment(uuid, text, text, uuid[], text, uuid) from public, anon, service_role;
revoke all on function public.set_stock_adjustment_lines(uuid, integer, text, text, uuid[]) from public, anon, service_role;
revoke all on function public.submit_stock_adjustment(uuid, integer) from public, anon, service_role;
revoke all on function public.return_stock_adjustment(uuid, integer, text) from public, anon, service_role;
revoke all on function public.reject_stock_adjustment(uuid, integer, text) from public, anon, service_role;
revoke all on function public.approve_stock_adjustment(uuid, integer, text) from public, anon, service_role;
revoke all on function public.post_stock_adjustment(uuid, integer, text) from public, anon, service_role;
revoke all on function public.list_adjustment_candidates() from public, anon, service_role;
revoke all on function public.list_stock_adjustments() from public, anon, service_role;
revoke all on function public.get_stock_adjustment(uuid) from public, anon, service_role;

grant execute on function app_private.can_view_stock_adjustment(uuid) to authenticated;
grant execute on function public.create_stock_adjustment(uuid, text, text, uuid[], text, uuid) to authenticated;
grant execute on function public.set_stock_adjustment_lines(uuid, integer, text, text, uuid[]) to authenticated;
grant execute on function public.submit_stock_adjustment(uuid, integer) to authenticated;
grant execute on function public.return_stock_adjustment(uuid, integer, text) to authenticated;
grant execute on function public.reject_stock_adjustment(uuid, integer, text) to authenticated;
grant execute on function public.approve_stock_adjustment(uuid, integer, text) to authenticated;
grant execute on function public.post_stock_adjustment(uuid, integer, text) to authenticated;
grant execute on function public.list_adjustment_candidates() to authenticated;
grant execute on function public.list_stock_adjustments() to authenticated;
grant execute on function public.get_stock_adjustment(uuid) to authenticated;

alter table public.stock_adjustment_requests enable row level security;
alter table public.stock_adjustment_requests force row level security;
alter table public.stock_adjustment_lines enable row level security;
alter table public.stock_adjustment_lines force row level security;
alter table public.stock_adjustment_events enable row level security;
alter table public.stock_adjustment_events force row level security;

revoke all on public.stock_adjustment_requests from public, anon, authenticated, service_role;
revoke all on public.stock_adjustment_lines from public, anon, authenticated, service_role;
revoke all on public.stock_adjustment_events from public, anon, authenticated, service_role;

grant select on public.stock_adjustment_requests to authenticated;
grant select on public.stock_adjustment_lines to authenticated;
grant select on public.stock_adjustment_events to authenticated;

create policy stock_adjustment_requests_select on public.stock_adjustment_requests
  for select to authenticated
  using (app_private.can_view_stock_adjustment(godown_id));

create policy stock_adjustment_lines_select on public.stock_adjustment_lines
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_adjustment_requests
      where stock_adjustment_requests.id = stock_adjustment_lines.request_id
        and app_private.can_view_stock_adjustment(stock_adjustment_requests.godown_id)
    )
  );

create policy stock_adjustment_events_select on public.stock_adjustment_events
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_adjustment_requests
      where stock_adjustment_requests.id = stock_adjustment_events.request_id
        and app_private.can_view_stock_adjustment(stock_adjustment_requests.godown_id)
    )
  );

comment on function public.post_stock_adjustment(uuid, integer, text) is
  'Posts an approved adjustment. Any ledger row after the verification baseline rejects the post and leaves stock unchanged.';
