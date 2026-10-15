-- Phase 3.1 stock receiving.
-- Extends the Phase 2C.3 ledger with RECEIPT movements. Does not change
-- earlier migrations, role grants, or opening-stock and transfer rules.
-- A receipt increases available stock only when a Godown Manager verifies it.
-- Accepted cases are counted cases minus damaged cases. Damaged cases are
-- recorded and are not posted. Cancelled receipts keep their supplier
-- document identity so the same document cannot be posted again.

create table public.stock_receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_number text not null,
  godown_id uuid not null references public.branches (id) on delete restrict,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  document_reference text not null,
  normalized_document_reference text not null,
  received_date date not null,
  status text not null default 'draft',
  notes text,
  hold_reason text,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  verified_by uuid references public.profiles (id) on delete restrict,
  verified_at timestamptz,
  posted_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  posting_idempotency_key text,
  posting_fingerprint text,
  constraint stock_receipts_number_key unique (receipt_number),
  constraint stock_receipts_posting_key unique (posting_idempotency_key),
  constraint stock_receipts_status_check
    check (status in ('draft', 'submitted', 'held', 'posted', 'cancelled')),
  constraint stock_receipts_notes_check
    check (notes is null or char_length(notes) <= 500),
  constraint stock_receipts_posted_check check (
    status <> 'posted'
    or (
      verified_by is not null
      and verified_at is not null
      and posted_at is not null
      and posting_idempotency_key is not null
      and posting_fingerprint is not null
    )
  ),
  constraint stock_receipts_held_check check (
    status <> 'held'
    or char_length(btrim(hold_reason)) between 1 and 500
  ),
  constraint stock_receipts_cancelled_check check (
    status <> 'cancelled'
    or (
      cancelled_by is not null
      and cancelled_at is not null
      and char_length(btrim(cancellation_reason)) between 1 and 500
    )
  )
);

create unique index stock_receipts_document_key
  on public.stock_receipts (godown_id, supplier_id, normalized_document_reference);

create index stock_receipts_godown_status_idx
  on public.stock_receipts (godown_id, status, created_at desc);

create index stock_receipts_created_by_idx
  on public.stock_receipts (created_by, created_at desc);

comment on table public.stock_receipts is
  'Supplier receipts. Posted and cancelled rows stay in place. The document key includes cancelled receipts so the same supplier document cannot be posted twice.';

create table public.stock_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.stock_receipts (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  destination_crate_id uuid not null references public.crates (id) on delete restrict,
  document_cases integer not null,
  counted_cases integer not null,
  damaged_cases integer not null,
  accepted_cases integer generated always as (counted_cases - damaged_cases) stored,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_receipt_lines_document_check
    check (document_cases between 0 and 1000000),
  constraint stock_receipt_lines_counted_check
    check (counted_cases between 0 and 1000000),
  constraint stock_receipt_lines_damaged_check
    check (damaged_cases between 0 and 1000000 and damaged_cases <= counted_cases)
);

create index stock_receipt_lines_receipt_idx
  on public.stock_receipt_lines (receipt_id, id);

comment on table public.stock_receipt_lines is
  'Receipt lines. accepted_cases is counted_cases minus damaged_cases and is not client-supplied.';

alter table public.stock_transactions
  add column receipt_id uuid references public.stock_receipts (id) on delete restrict,
  add column receipt_line_id uuid references public.stock_receipt_lines (id) on delete restrict;

alter table public.stock_transactions
  drop constraint stock_transactions_type_check,
  add constraint stock_transactions_type_check
    check (transaction_type in ('OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT'));

alter table public.stock_transactions
  drop constraint stock_transactions_shape_check,
  add constraint stock_transactions_shape_check check (
    (
      transaction_type = 'OPENING_STOCK'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is null
      and receipt_line_id is null
    )
    or (
      transaction_type = 'CRATE_TRANSFER'
      and source_crate_id is not null
      and destination_crate_id is not null
      and source_crate_id <> destination_crate_id
      and receipt_id is null
      and receipt_line_id is null
    )
    or (
      transaction_type = 'RECEIPT'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is not null
      and receipt_line_id is not null
    )
  );

create unique index stock_transactions_receipt_line_once
  on public.stock_transactions (receipt_line_id)
  where receipt_line_id is not null;

create index stock_transactions_receipt_idx
  on public.stock_transactions (receipt_id);

comment on column public.stock_transactions.receipt_line_id is
  'Source receipt line for a RECEIPT movement. Opening stock and transfers leave this empty.';

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
begin
  select
    stock_transactions.transaction_type,
    stock_transactions.receipt_id,
    stock_transactions.receipt_line_id
  into selected_type, linked_receipt, linked_line
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

  if selected_type not in ('OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT') then
    raise exception 'stock transaction type is not supported' using errcode = '23514';
  end if;

  return null;
end;
$$;

create or replace function app_private.normalize_document_reference(raw_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.lower(
    pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(raw_value, '')), '\s+', ' ', 'g')
  );
begin
  if cleaned = '' or pg_catalog.char_length(cleaned) > 80 then
    raise exception 'document reference is invalid' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.receipt_case_count(raw_value jsonb)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  text_value text;
begin
  if raw_value is null or pg_catalog.jsonb_typeof(raw_value) <> 'number' then
    raise exception 'quantity must be a whole number of carton cases' using errcode = '23514';
  end if;

  text_value := raw_value #>> '{}';
  if text_value !~ '^[0-9]+$' or pg_catalog.char_length(text_value) > 7 then
    raise exception 'quantity must be a whole number of carton cases' using errcode = '23514';
  end if;

  if text_value::integer > 1000000 then
    raise exception 'quantity is too large' using errcode = '23514';
  end if;

  return text_value::integer;
end;
$$;

create or replace function app_private.touch_stock_receipt()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$$;

create trigger stock_receipts_touch
  before update on public.stock_receipts
  for each row execute function app_private.touch_stock_receipt();

create or replace function app_private.reject_closed_receipt_line()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_status text;
  receipt_godown uuid;
begin
  select stock_receipts.status, stock_receipts.godown_id
  into current_status, receipt_godown
  from public.stock_receipts
  where stock_receipts.id = case
    when tg_op = 'DELETE' then old.receipt_id
    else new.receipt_id
  end;

  if current_status is distinct from 'draft' then
    raise exception 'receipt lines are closed' using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  if not exists (
    select 1
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = new.destination_crate_id
      and zones.branch_id = receipt_godown
  ) then
    raise exception 'destination crate is outside this godown' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger stock_receipt_lines_closed
  before insert or update or delete on public.stock_receipt_lines
  for each row execute function app_private.reject_closed_receipt_line();

create or replace function app_private.can_view_stock_receipt(candidate public.stock_receipts)
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

  if app_private.has_permission('receiving.verify')
    and app_private.can_work_at_branch(candidate.godown_id) then
    return true;
  end if;

  return app_private.has_permission('receiving.execute')
    and candidate.created_by = auth.uid()
    and app_private.can_work_at_branch(candidate.godown_id);
end;
$$;

create or replace function app_private.lock_stock_receipt(target uuid)
returns public.stock_receipts
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
begin
  select *
  into selected
  from public.stock_receipts
  where stock_receipts.id = target
  for update;

  if selected.id is null or not app_private.can_view_stock_receipt(selected) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return selected;
end;
$$;

create or replace function app_private.receipt_posting_fingerprint(target uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select stock_receipts.godown_id::text
    || '|' || stock_receipts.supplier_id::text
    || '|' || stock_receipts.normalized_document_reference
    || '|' || coalesce((
      select pg_catalog.string_agg(
        stock_receipt_lines.product_id::text
          || ':' || stock_receipt_lines.destination_crate_id::text
          || ':' || stock_receipt_lines.document_cases::text
          || ':' || stock_receipt_lines.counted_cases::text
          || ':' || stock_receipt_lines.damaged_cases::text,
        ','
        order by stock_receipt_lines.id
      )
      from public.stock_receipt_lines
      where stock_receipt_lines.receipt_id = stock_receipts.id
    ), '')
  from public.stock_receipts
  where stock_receipts.id = target;
$$;

create or replace function app_private.stock_receipt_payload(target uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'id', stock_receipts.id,
    'receipt_number', stock_receipts.receipt_number,
    'godown_id', stock_receipts.godown_id,
    'godown_code', branches.code,
    'godown_name', branches.name,
    'supplier_id', stock_receipts.supplier_id,
    'supplier_name', suppliers.name,
    'document_reference', stock_receipts.document_reference,
    'received_date', stock_receipts.received_date,
    'status', stock_receipts.status,
    'notes', stock_receipts.notes,
    'hold_reason', stock_receipts.hold_reason,
    'created_by', stock_receipts.created_by,
    'creator_name', creator.full_name,
    'created_at', stock_receipts.created_at,
    'updated_at', stock_receipts.updated_at,
    'verified_by', stock_receipts.verified_by,
    'verifier_name', verifier.full_name,
    'verified_at', stock_receipts.verified_at,
    'posted_at', stock_receipts.posted_at,
    'cancelled_by', stock_receipts.cancelled_by,
    'canceller_name', canceller.full_name,
    'cancelled_at', stock_receipts.cancelled_at,
    'cancellation_reason', stock_receipts.cancellation_reason,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_receipt_lines.id,
          'product_id', stock_receipt_lines.product_id,
          'product_sku', products.sku,
          'product_name', products.name,
          'zone_id', zones.id,
          'zone_code', zones.code,
          'destination_crate_id', stock_receipt_lines.destination_crate_id,
          'crate_code', crates.code,
          'document_cases', stock_receipt_lines.document_cases,
          'counted_cases', stock_receipt_lines.counted_cases,
          'damaged_cases', stock_receipt_lines.damaged_cases,
          'accepted_cases', stock_receipt_lines.accepted_cases
        )
        order by stock_receipt_lines.created_at, stock_receipt_lines.id
      )
      from public.stock_receipt_lines
      join public.products on products.id = stock_receipt_lines.product_id
      join public.crates on crates.id = stock_receipt_lines.destination_crate_id
      join public.zones on zones.id = crates.zone_id
      where stock_receipt_lines.receipt_id = stock_receipts.id
    ), '[]'::jsonb),
    'transactions', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_transactions.id,
          'reference_number', stock_transactions.reference_number,
          'receipt_line_id', stock_transactions.receipt_line_id,
          'quantity', stock_transactions.quantity
        )
        order by stock_transactions.reference_number
      )
      from public.stock_transactions
      where stock_transactions.receipt_id = stock_receipts.id
    ), '[]'::jsonb),
    'audit', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'action', audit_logs.action,
          'actor_name', profiles.full_name,
          'occurred_at', audit_logs.occurred_at,
          'metadata', audit_logs.metadata
        )
        order by audit_logs.occurred_at, audit_logs.id
      )
      from public.audit_logs
      left join public.profiles on profiles.id = audit_logs.actor_id
      where audit_logs.entity_table = 'stock_receipts'
        and audit_logs.entity_id = stock_receipts.id
    ), '[]'::jsonb)
  )
  from public.stock_receipts
  join public.branches on branches.id = stock_receipts.godown_id
  join public.suppliers on suppliers.id = stock_receipts.supplier_id
  join public.profiles as creator on creator.id = stock_receipts.created_by
  left join public.profiles as verifier on verifier.id = stock_receipts.verified_by
  left join public.profiles as canceller on canceller.id = stock_receipts.cancelled_by
  where stock_receipts.id = target;
$$;

create or replace function app_private.replace_receipt_lines(
  target uuid,
  line_items jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  product_ids uuid[] := '{}'::uuid[];
  crate_ids uuid[] := '{}'::uuid[];
  document_counts integer[] := '{}'::integer[];
  counted_counts integer[] := '{}'::integer[];
  damaged_counts integer[] := '{}'::integer[];
  receipt_godown uuid;
  selected_branch uuid;
  product_id uuid;
  crate_id uuid;
  document_cases integer;
  counted_cases integer;
  damaged_cases integer;
begin
  if line_items is null
    or pg_catalog.jsonb_typeof(line_items) <> 'array'
    or pg_catalog.jsonb_array_length(line_items) < 1
    or pg_catalog.jsonb_array_length(line_items) > 100 then
    raise exception 'a receipt needs at least one line' using errcode = '23514';
  end if;

  select stock_receipts.godown_id
  into receipt_godown
  from public.stock_receipts
  where stock_receipts.id = target;

  for item in
    select value
    from pg_catalog.jsonb_array_elements(line_items)
  loop
    begin
      product_id := (item ->> 'product_id')::uuid;
      crate_id := (item ->> 'destination_crate_id')::uuid;
    exception
      when invalid_text_representation then
        raise exception 'product or crate is invalid' using errcode = '23514';
    end;

    document_cases := app_private.receipt_case_count(item -> 'document_cases');
    counted_cases := app_private.receipt_case_count(item -> 'counted_cases');
    damaged_cases := app_private.receipt_case_count(item -> 'damaged_cases');

    if damaged_cases > counted_cases then
      raise exception 'damaged cases cannot exceed counted cases' using errcode = '23514';
    end if;

    if not exists (
      select 1
      from public.products
      where products.id = product_id
        and products.is_active
    ) then
      raise exception 'product is inactive or missing' using errcode = '23514';
    end if;

    product_ids := product_ids || product_id;
    crate_ids := crate_ids || crate_id;
    document_counts := document_counts || document_cases;
    counted_counts := counted_counts || counted_cases;
    damaged_counts := damaged_counts || damaged_cases;
  end loop;

  selected_branch := app_private.prepare_stock_locations(
    array(
      select distinct parsed_crate
      from pg_catalog.unnest(crate_ids) as parsed_crate
    )
  );

  if selected_branch is distinct from receipt_godown then
    raise exception 'destination crate is outside this godown' using errcode = '23514';
  end if;

  delete from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = target;

  for line_index in 1..coalesce(pg_catalog.array_length(product_ids, 1), 0) loop
    insert into public.stock_receipt_lines (
      receipt_id,
      product_id,
      destination_crate_id,
      document_cases,
      counted_cases,
      damaged_cases
    )
    values (
      target,
      product_ids[line_index],
      crate_ids[line_index],
      document_counts[line_index],
      counted_counts[line_index],
      damaged_counts[line_index]
    );
  end loop;
end;
$$;

create or replace function app_private.clean_receipt_notes(raw_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.btrim(coalesce(raw_value, ''));
begin
  if cleaned = '' then
    return null;
  end if;

  if pg_catalog.char_length(cleaned) > 500 then
    raise exception 'notes are too long' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function public.create_stock_receipt(
  target_godown uuid,
  target_supplier uuid,
  supplier_document text,
  received_on date,
  receipt_notes text,
  line_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  document_text text;
  normalized_text text;
begin
  perform app_private.assert_permission('receiving.execute');

  if target_godown is null
    or not app_private.can_work_at_branch(target_godown)
    or not exists (
      select 1
      from public.branches
      where branches.id = target_godown
        and branches.is_active
    ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if received_on is null then
    raise exception 'received date is required' using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.suppliers
    where suppliers.id = target_supplier
      and suppliers.is_active
  ) then
    raise exception 'supplier is inactive or missing' using errcode = '23514';
  end if;

  document_text := pg_catalog.btrim(coalesce(supplier_document, ''));
  normalized_text := app_private.normalize_document_reference(document_text);

  insert into public.stock_receipts (
    receipt_number,
    godown_id,
    supplier_id,
    document_reference,
    normalized_document_reference,
    received_date,
    notes,
    created_by
  )
  values (
    'RC-'
      || pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0'),
    target_godown,
    target_supplier,
    document_text,
    normalized_text,
    received_on,
    app_private.clean_receipt_notes(receipt_notes),
    auth.uid()
  )
  returning id into created_id;

  perform app_private.replace_receipt_lines(created_id, line_items);

  perform app_private.write_audit(
    auth.uid(),
    'create_stock_receipt',
    'stock_receipts',
    created_id,
    pg_catalog.jsonb_build_object(
      'godown_id', target_godown,
      'supplier_id', target_supplier,
      'document_reference', document_text
    )
  );

  return app_private.stock_receipt_payload(created_id);
exception
  when unique_violation then
    raise exception 'document reference was already used' using errcode = '23505';
end;
$$;

create or replace function public.update_stock_receipt(
  target_receipt uuid,
  target_godown uuid,
  target_supplier uuid,
  supplier_document text,
  received_on date,
  receipt_notes text,
  line_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
  document_text text;
  normalized_text text;
begin
  perform app_private.assert_permission('receiving.execute');
  selected := app_private.lock_stock_receipt(target_receipt);

  if selected.created_by is distinct from auth.uid()
    or selected.status is distinct from 'draft' then
    raise exception 'receipt cannot be edited' using errcode = '42501';
  end if;

  if target_godown is null
    or not app_private.can_work_at_branch(target_godown)
    or not exists (
      select 1 from public.branches
      where branches.id = target_godown and branches.is_active
    ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if received_on is null then
    raise exception 'received date is required' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.suppliers
    where suppliers.id = target_supplier and suppliers.is_active
  ) then
    raise exception 'supplier is inactive or missing' using errcode = '23514';
  end if;

  document_text := pg_catalog.btrim(coalesce(supplier_document, ''));
  normalized_text := app_private.normalize_document_reference(document_text);

  update public.stock_receipts
  set
    godown_id = target_godown,
    supplier_id = target_supplier,
    document_reference = document_text,
    normalized_document_reference = normalized_text,
    received_date = received_on,
    notes = app_private.clean_receipt_notes(receipt_notes)
  where stock_receipts.id = selected.id;

  perform app_private.replace_receipt_lines(selected.id, line_items);

  perform app_private.write_audit(
    auth.uid(),
    'update_stock_receipt',
    'stock_receipts',
    selected.id,
    pg_catalog.jsonb_build_object('document_reference', document_text)
  );

  return app_private.stock_receipt_payload(selected.id);
exception
  when unique_violation then
    raise exception 'document reference was already used' using errcode = '23505';
end;
$$;

create or replace function public.submit_stock_receipt(target_receipt uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
begin
  perform app_private.assert_permission('receiving.execute');
  selected := app_private.lock_stock_receipt(target_receipt);

  if selected.created_by is distinct from auth.uid()
    or selected.status is distinct from 'draft'
    or not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'receipt cannot be submitted' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = selected.id
  ) then
    raise exception 'a receipt needs at least one line' using errcode = '23514';
  end if;

  update public.stock_receipts
  set status = 'submitted'
  where stock_receipts.id = selected.id;

  perform app_private.write_audit(
    auth.uid(),
    'submit_stock_receipt',
    'stock_receipts',
    selected.id,
    '{}'::jsonb
  );

  return app_private.stock_receipt_payload(selected.id);
end;
$$;

create or replace function public.hold_stock_receipt(
  target_receipt uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
  cleaned_reason text := pg_catalog.btrim(coalesce(reason, ''));
begin
  perform app_private.assert_permission('receiving.verify');
  selected := app_private.lock_stock_receipt(target_receipt);

  if not app_private.can_work_at_branch(selected.godown_id)
    or selected.status not in ('draft', 'submitted') then
    raise exception 'receipt cannot be held' using errcode = '42501';
  end if;

  if pg_catalog.char_length(cleaned_reason) < 1
    or pg_catalog.char_length(cleaned_reason) > 500 then
    raise exception 'hold reason is required' using errcode = '23514';
  end if;

  update public.stock_receipts
  set
    status = 'held',
    hold_reason = cleaned_reason
  where stock_receipts.id = selected.id;

  perform app_private.write_audit(
    auth.uid(),
    'hold_stock_receipt',
    'stock_receipts',
    selected.id,
    pg_catalog.jsonb_build_object('hold_reason', cleaned_reason)
  );

  return app_private.stock_receipt_payload(selected.id);
end;
$$;

create or replace function public.release_stock_receipt(target_receipt uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
  manager_release boolean;
begin
  selected := app_private.lock_stock_receipt(target_receipt);
  manager_release := app_private.has_permission('receiving.verify')
    and app_private.can_work_at_branch(selected.godown_id);

  if selected.status is distinct from 'held' then
    raise exception 'receipt cannot be released' using errcode = '42501';
  end if;

  if not manager_release and not (
    app_private.has_permission('receiving.execute')
    and selected.created_by = auth.uid()
    and app_private.can_work_at_branch(selected.godown_id)
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  update public.stock_receipts
  set status = 'draft'
  where stock_receipts.id = selected.id;

  perform app_private.write_audit(
    auth.uid(),
    'release_stock_receipt',
    'stock_receipts',
    selected.id,
    '{}'::jsonb
  );

  return app_private.stock_receipt_payload(selected.id);
end;
$$;

create or replace function public.cancel_stock_receipt(
  target_receipt uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
  cleaned_reason text := pg_catalog.btrim(coalesce(reason, ''));
  manager_cancel boolean;
begin
  selected := app_private.lock_stock_receipt(target_receipt);
  manager_cancel := app_private.has_permission('receiving.verify')
    and app_private.can_work_at_branch(selected.godown_id);

  if selected.status in ('posted', 'cancelled')
    or not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'receipt cannot be cancelled' using errcode = '42501';
  end if;

  if manager_cancel then
    null;
  elsif app_private.has_permission('receiving.execute')
    and selected.created_by = auth.uid()
    and selected.status = 'draft' then
    null;
  else
    raise exception 'receipt cannot be cancelled' using errcode = '42501';
  end if;

  if pg_catalog.char_length(cleaned_reason) < 1
    or pg_catalog.char_length(cleaned_reason) > 500 then
    raise exception 'cancellation reason is required' using errcode = '23514';
  end if;

  update public.stock_receipts
  set
    status = 'cancelled',
    cancelled_by = auth.uid(),
    cancelled_at = pg_catalog.clock_timestamp(),
    cancellation_reason = cleaned_reason
  where stock_receipts.id = selected.id;

  perform app_private.write_audit(
    auth.uid(),
    'cancel_stock_receipt',
    'stock_receipts',
    selected.id,
    pg_catalog.jsonb_build_object('cancellation_reason', cleaned_reason)
  );

  return app_private.stock_receipt_payload(selected.id);
end;
$$;

create or replace function public.verify_stock_receipt(
  target_receipt uuid,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
  cleaned_key text;
  fingerprint text;
  selected_branch uuid;
  crate_ids uuid[];
  line_record record;
  created_id uuid;
  reference_number text;
begin
  perform app_private.assert_permission('receiving.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  selected := app_private.lock_stock_receipt(target_receipt);

  if not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  fingerprint := app_private.receipt_posting_fingerprint(selected.id);

  if selected.status = 'posted' then
    if selected.posting_idempotency_key = cleaned_key
      and selected.posting_fingerprint = fingerprint then
      return app_private.stock_receipt_payload(selected.id);
    end if;

    raise exception 'idempotency key was already used for a different request'
      using errcode = '23505';
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'receipt cannot be verified' using errcode = '42501';
  end if;

  perform suppliers.id
  from public.suppliers
  where suppliers.id = selected.supplier_id
  for update;

  if not exists (
    select 1
    from public.suppliers
    where suppliers.id = selected.supplier_id
      and suppliers.is_active
  ) then
    raise exception 'supplier is inactive or missing' using errcode = '23514';
  end if;

  perform products.id
  from public.products
  where products.id in (
    select stock_receipt_lines.product_id
    from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = selected.id
  )
  order by products.id
  for update;

  if exists (
    select 1
    from public.stock_receipt_lines
    left join public.products on products.id = stock_receipt_lines.product_id
    where stock_receipt_lines.receipt_id = selected.id
      and (products.id is null or not products.is_active)
  ) then
    raise exception 'product is inactive or missing' using errcode = '23514';
  end if;

  select coalesce(array_agg(distinct stock_receipt_lines.destination_crate_id), '{}')
  into crate_ids
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = selected.id;

  selected_branch := app_private.prepare_stock_locations(crate_ids);
  if selected_branch is distinct from selected.godown_id then
    raise exception 'destination crate is outside this godown' using errcode = '23514';
  end if;

  -- Re-read after location locks so a deactivation cannot pass between checks.
  if exists (
    select 1
    from public.stock_receipt_lines
    join public.crates on crates.id = stock_receipt_lines.destination_crate_id
    join public.zones on zones.id = crates.zone_id
    join public.branches on branches.id = zones.branch_id
    where stock_receipt_lines.receipt_id = selected.id
      and (
        not crates.is_active
        or not zones.is_active
        or not branches.is_active
        or zones.branch_id is distinct from selected.godown_id
      )
  ) then
    raise exception 'location is inactive' using errcode = '23514';
  end if;

  for line_record in
    select
      stock_receipt_lines.id,
      stock_receipt_lines.product_id,
      stock_receipt_lines.destination_crate_id,
      stock_receipt_lines.accepted_cases
    from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = selected.id
      and stock_receipt_lines.accepted_cases > 0
    order by
      stock_receipt_lines.destination_crate_id,
      stock_receipt_lines.product_id,
      stock_receipt_lines.id
  loop
    reference_number := 'RR-'
      || pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0');

    insert into public.stock_transactions (
      transaction_type,
      reference_number,
      actor_id,
      idempotency_key,
      request_fingerprint,
      notes,
      product_id,
      destination_crate_id,
      quantity,
      receipt_id,
      receipt_line_id
    )
    values (
      'RECEIPT',
      reference_number,
      auth.uid(),
      selected.id::text || '-' || line_record.id::text,
      fingerprint || '|' || line_record.id::text,
      selected.receipt_number,
      line_record.product_id,
      line_record.destination_crate_id,
      line_record.accepted_cases,
      selected.id,
      line_record.id
    )
    returning id into created_id;

    insert into public.stock_ledger (
      transaction_id,
      product_id,
      crate_id,
      quantity,
      actor_id,
      posted_at
    )
    select
      created_id,
      line_record.product_id,
      line_record.destination_crate_id,
      line_record.accepted_cases,
      stock_transactions.actor_id,
      stock_transactions.posted_at
    from public.stock_transactions
    where stock_transactions.id = created_id;

    perform app_private.apply_stock_delta(
      line_record.destination_crate_id,
      line_record.product_id,
      line_record.accepted_cases
    );
  end loop;

  update public.stock_receipts
  set
    status = 'posted',
    verified_by = auth.uid(),
    verified_at = pg_catalog.clock_timestamp(),
    posted_at = pg_catalog.clock_timestamp(),
    posting_idempotency_key = cleaned_key,
    posting_fingerprint = fingerprint
  where stock_receipts.id = selected.id;

  perform app_private.write_audit(
    auth.uid(),
    'verify_stock_receipt',
    'stock_receipts',
    selected.id,
    pg_catalog.jsonb_build_object(
      'receipt_number', selected.receipt_number,
      'idempotency_key', cleaned_key
    )
  );

  return app_private.stock_receipt_payload(selected.id);
exception
  when unique_violation then
    raise exception 'idempotency key was already used for a different request'
      using errcode = '23505';
end;
$$;

create or replace function public.list_stock_receipts()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(row_payload order by created_at desc)
    from (
      select
        stock_receipts.created_at,
        pg_catalog.jsonb_build_object(
          'id', stock_receipts.id,
          'receipt_number', stock_receipts.receipt_number,
          'godown_id', stock_receipts.godown_id,
          'godown_code', branches.code,
          'godown_name', branches.name,
          'supplier_name', suppliers.name,
          'document_reference', stock_receipts.document_reference,
          'received_date', stock_receipts.received_date,
          'status', stock_receipts.status,
          'creator_name', profiles.full_name,
          'created_by', stock_receipts.created_by,
          'verified_at', stock_receipts.verified_at,
          'posted_at', stock_receipts.posted_at
        ) as row_payload
      from public.stock_receipts
      join public.branches on branches.id = stock_receipts.godown_id
      join public.suppliers on suppliers.id = stock_receipts.supplier_id
      join public.profiles on profiles.id = stock_receipts.created_by
      where app_private.can_view_stock_receipt(stock_receipts)
    ) as visible
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_stock_receipt(target_receipt uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
begin
  if not (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.stock_receipts
  where stock_receipts.id = target_receipt;

  if selected.id is null or not app_private.can_view_stock_receipt(selected) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return app_private.stock_receipt_payload(selected.id);
end;
$$;

create or replace function public.list_receiving_options()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'godowns', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', branches.id,
          'code', branches.code,
          'name', branches.name
        )
        order by branches.name
      )
      from public.branches
      where branches.is_active
        and app_private.can_work_at_branch(branches.id)
    ), '[]'::jsonb),
    'suppliers', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', suppliers.id, 'name', suppliers.name)
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
          'name', products.name
        )
        order by products.name
      )
      from public.products
      where products.is_active
    ), '[]'::jsonb),
    'zones', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', zones.id,
          'branch_id', zones.branch_id,
          'code', zones.code,
          'name', zones.name
        )
        order by zones.code
      )
      from public.zones
      join public.branches on branches.id = zones.branch_id
      where zones.is_active
        and branches.is_active
        and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb),
    'crates', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', crates.id,
          'zone_id', crates.zone_id,
          'code', crates.code,
          'name', crates.name
        )
        order by crates.code
      )
      from public.crates
      join public.zones on zones.id = crates.zone_id
      join public.branches on branches.id = zones.branch_id
      where crates.is_active
        and zones.is_active
        and branches.is_active
        and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.normalize_document_reference(text) from public, anon, authenticated, service_role;
revoke all on function app_private.receipt_case_count(jsonb) from public, anon, authenticated, service_role;
revoke all on function app_private.touch_stock_receipt() from public, anon, authenticated, service_role;
revoke all on function app_private.reject_closed_receipt_line() from public, anon, authenticated, service_role;
revoke all on function app_private.can_view_stock_receipt(public.stock_receipts) from public, anon, authenticated, service_role;
revoke all on function app_private.lock_stock_receipt(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.receipt_posting_fingerprint(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.stock_receipt_payload(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.replace_receipt_lines(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function app_private.clean_receipt_notes(text) from public, anon, authenticated, service_role;

revoke all on function public.create_stock_receipt(uuid, uuid, text, date, text, jsonb) from public, anon, service_role;
revoke all on function public.update_stock_receipt(uuid, uuid, uuid, text, date, text, jsonb) from public, anon, service_role;
revoke all on function public.submit_stock_receipt(uuid) from public, anon, service_role;
revoke all on function public.hold_stock_receipt(uuid, text) from public, anon, service_role;
revoke all on function public.release_stock_receipt(uuid) from public, anon, service_role;
revoke all on function public.cancel_stock_receipt(uuid, text) from public, anon, service_role;
revoke all on function public.verify_stock_receipt(uuid, text) from public, anon, service_role;
revoke all on function public.list_stock_receipts() from public, anon, service_role;
revoke all on function public.get_stock_receipt(uuid) from public, anon, service_role;
revoke all on function public.list_receiving_options() from public, anon, service_role;

grant execute on function public.create_stock_receipt(uuid, uuid, text, date, text, jsonb) to authenticated;
grant execute on function public.update_stock_receipt(uuid, uuid, uuid, text, date, text, jsonb) to authenticated;
grant execute on function public.submit_stock_receipt(uuid) to authenticated;
grant execute on function public.hold_stock_receipt(uuid, text) to authenticated;
grant execute on function public.release_stock_receipt(uuid) to authenticated;
grant execute on function public.cancel_stock_receipt(uuid, text) to authenticated;
grant execute on function public.verify_stock_receipt(uuid, text) to authenticated;
grant execute on function public.list_stock_receipts() to authenticated;
grant execute on function public.get_stock_receipt(uuid) to authenticated;
grant execute on function public.list_receiving_options() to authenticated;

alter table public.stock_receipts enable row level security;
alter table public.stock_receipts force row level security;
alter table public.stock_receipt_lines enable row level security;
alter table public.stock_receipt_lines force row level security;

revoke all on public.stock_receipts from public, anon, authenticated, service_role;
revoke all on public.stock_receipt_lines from public, anon, authenticated, service_role;
grant select on public.stock_receipts to authenticated;
grant select on public.stock_receipt_lines to authenticated;

create policy stock_receipts_select on public.stock_receipts
  for select to authenticated
  using (
    (
      app_private.has_permission('receiving.execute')
      and created_by = (select auth.uid())
      and app_private.can_work_at_branch(godown_id)
    )
    or (
      app_private.has_permission('receiving.verify')
      and app_private.can_work_at_branch(godown_id)
    )
    or app_private.has_permission('operations.monitor')
  );

create policy stock_receipt_lines_select on public.stock_receipt_lines
  for select to authenticated
  using (
    exists (
      select 1
      from public.stock_receipts
      where stock_receipts.id = stock_receipt_lines.receipt_id
        and (
          (
            app_private.has_permission('receiving.execute')
            and stock_receipts.created_by = (select auth.uid())
            and app_private.can_work_at_branch(stock_receipts.godown_id)
          )
          or (
            app_private.has_permission('receiving.verify')
            and app_private.can_work_at_branch(stock_receipts.godown_id)
          )
          or app_private.has_permission('operations.monitor')
        )
    )
  );

comment on function public.verify_stock_receipt(uuid, text) is
  'Godown Manager verification. Posts accepted cases in the same transaction or rolls the receipt back. An exact idempotency retry returns the posted receipt. A conflicting retry fails.';
