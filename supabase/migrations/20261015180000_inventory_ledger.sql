-- Phase 2C.3 inventory ledger.
-- Append-only ledger, transactionally maintained balances, Admin opening stock,
-- and same-godown crate transfers. Does not alter earlier migrations.
-- stock.read does not grant access to every godown. Visibility uses
-- app_private.can_work_at_branch: branches.access_all or an active assignment.
-- Accounts and Store Keeper receive stock.read only. They see a godown after an
-- existing site assignment. This migration does not assign them.

insert into public.permissions (code, description)
values (
  'stock.transfer.post',
  'Move whole carton cases between crates in the same authorized godown. Cross-godown transfers are not included.'
);

update public.permissions
set description = 'View crate-level stock in godowns the caller can already work at. This grant does not open every godown.'
where code = 'stock.read';

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'stock.read'),
    ('admin', 'stock.transfer.post'),
    ('accounts', 'stock.read'),
    ('godown_manager', 'stock.read'),
    ('godown_manager', 'stock.transfer.post'),
    ('store_keeper', 'stock.read')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code
on conflict do nothing;

create sequence public.stock_reference_seq;

revoke all on sequence public.stock_reference_seq from public, anon, authenticated, service_role;

create table public.stock_transactions (
  id uuid primary key default gen_random_uuid(),
  transaction_type text not null,
  reference_number text not null,
  actor_id uuid not null,
  posted_at timestamptz not null default pg_catalog.clock_timestamp(),
  idempotency_key text not null,
  request_fingerprint text not null,
  notes text,
  product_id uuid not null references public.products (id) on delete restrict,
  source_crate_id uuid references public.crates (id) on delete restrict,
  destination_crate_id uuid references public.crates (id) on delete restrict,
  quantity integer not null,
  constraint stock_transactions_type_check
    check (transaction_type in ('OPENING_STOCK', 'CRATE_TRANSFER')),
  constraint stock_transactions_reference_key unique (reference_number),
  constraint stock_transactions_idempotency_key unique (idempotency_key),
  constraint stock_transactions_quantity_check
    check (quantity between 1 and 1000000),
  constraint stock_transactions_shape_check check (
    (
      transaction_type = 'OPENING_STOCK'
      and source_crate_id is null
      and destination_crate_id is not null
    )
    or (
      transaction_type = 'CRATE_TRANSFER'
      and source_crate_id is not null
      and destination_crate_id is not null
      and source_crate_id <> destination_crate_id
    )
  )
);

create unique index stock_transactions_opening_once
  on public.stock_transactions (product_id, destination_crate_id)
  where transaction_type = 'OPENING_STOCK';

create index stock_transactions_posted_at_idx
  on public.stock_transactions (posted_at desc);

comment on table public.stock_transactions is
  'Posted inventory documents. Rows are append-only. actor_id and posted_at are set by the posting function.';

create table public.stock_ledger (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.stock_transactions (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  quantity integer not null,
  actor_id uuid not null,
  posted_at timestamptz not null,
  constraint stock_ledger_quantity_check check (quantity <> 0)
);

create index stock_ledger_transaction_id_idx on public.stock_ledger (transaction_id);
create index stock_ledger_crate_product_idx on public.stock_ledger (crate_id, product_id);

comment on table public.stock_ledger is
  'Append-only signed carton-case entries. Opening stock is one positive entry. A transfer is one negative source entry and one positive destination entry that net to zero.';

create table public.stock_balances (
  crate_id uuid not null references public.crates (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  quantity integer not null,
  primary key (crate_id, product_id),
  constraint stock_balances_quantity_check check (quantity >= 0)
);

comment on table public.stock_balances is
  'Read projection of stock_ledger. Posting functions maintain it in the same transaction. Clients cannot write it. A zero row remains after a crate is emptied.';

create or replace function app_private.reject_stock_history_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'stock history is append-only' using errcode = '42501';
end;
$$;

create trigger stock_transactions_append_only
  before update or delete on public.stock_transactions
  for each row execute function app_private.reject_stock_history_change();

create trigger stock_ledger_append_only
  before update or delete on public.stock_ledger
  for each row execute function app_private.reject_stock_history_change();

create or replace function app_private.assert_stock_transaction_complete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  selected_type text;
  entry_count integer;
  entry_sum integer;
begin
  select stock_transactions.transaction_type
  into selected_type
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

  return null;
end;
$$;

create constraint trigger stock_ledger_complete
  after insert on public.stock_ledger
  deferrable initially deferred
  for each row execute function app_private.assert_stock_transaction_complete();

create or replace function app_private.assert_balance_matches_ledger()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  ledger_total integer;
begin
  select coalesce(sum(stock_ledger.quantity), 0)
  into ledger_total
  from public.stock_ledger
  where stock_ledger.crate_id = new.crate_id
    and stock_ledger.product_id = new.product_id;

  if ledger_total <> new.quantity or new.quantity < 0 then
    raise exception 'balance does not match the ledger' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger stock_balances_match_ledger
  before insert or update on public.stock_balances
  for each row execute function app_private.assert_balance_matches_ledger();

revoke all on function app_private.reject_stock_history_change() from public, anon, authenticated, service_role;
revoke all on function app_private.assert_stock_transaction_complete() from public, anon, authenticated, service_role;
revoke all on function app_private.assert_balance_matches_ledger() from public, anon, authenticated, service_role;

create or replace function app_private.clean_idempotency_key(raw_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.btrim(coalesce(raw_value, ''));
begin
  if cleaned !~ '^[A-Za-z0-9_-]{8,80}$' then
    raise exception 'idempotency key must be 8 to 80 letters, numbers, underscores, or hyphens'
      using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.stock_request_fingerprint(
  transaction_type text,
  target_product uuid,
  source_crate uuid,
  destination_crate uuid,
  carton_quantity integer,
  posting_notes text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select transaction_type
    || '|' || target_product::text
    || '|' || coalesce(source_crate::text, '')
    || '|' || coalesce(destination_crate::text, '')
    || '|' || carton_quantity::text
    || '|' || coalesce(posting_notes, '');
$$;

create or replace function app_private.assert_carton_quantity(carton_quantity integer)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if carton_quantity is null or carton_quantity < 1 or carton_quantity > 1000000 then
    raise exception 'quantity must be a whole number of carton cases from 1 to 1000000'
      using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.prepare_stock_locations(crate_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  found_count integer;
  branch_count integer;
  inactive_count integer;
begin
  if crate_ids is null or cardinality(crate_ids) < 1 then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform zones.id
  from public.zones
  where zones.id in (
    select crates.zone_id
    from public.crates
    where crates.id = any (crate_ids)
  )
  order by zones.id
  for update;

  perform crates.id
  from public.crates
  where crates.id = any (crate_ids)
  order by crates.id
  for update;

  select
    count(*),
    count(distinct zones.branch_id),
    count(*) filter (
      where not crates.is_active
        or not zones.is_active
        or not branches.is_active
    )
  into found_count, branch_count, inactive_count
  from public.crates
  join public.zones on zones.id = crates.zone_id
  join public.branches on branches.id = zones.branch_id
  where crates.id = any (crate_ids);

  if found_count is distinct from cardinality(crate_ids) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = any (crate_ids)
      and not app_private.can_work_at_branch(zones.branch_id)
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if branch_count <> 1 then
    raise exception 'crates must belong to the same godown' using errcode = '23514';
  end if;

  if inactive_count > 0 then
    raise exception 'location is inactive' using errcode = '23514';
  end if;

  select zones.branch_id
  into selected_branch
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = crate_ids[1];

  return selected_branch;
end;
$$;

create or replace function app_private.replay_stock_transaction(
  cleaned_key text,
  fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.stock_transactions%rowtype;
  selected_branch uuid;
begin
  select *
  into existing
  from public.stock_transactions
  where stock_transactions.idempotency_key = cleaned_key;

  if not found then
    return null;
  end if;

  if existing.request_fingerprint is distinct from fingerprint then
    raise exception 'idempotency key was already used for a different request'
      using errcode = '23505';
  end if;

  select zones.branch_id
  into selected_branch
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = coalesce(existing.destination_crate_id, existing.source_crate_id);

  if selected_branch is null or not app_private.can_work_at_branch(selected_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', existing.id,
    'reference_number', existing.reference_number
  );
end;
$$;

create or replace function app_private.apply_stock_delta(
  target_crate uuid,
  target_product uuid,
  delta integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_quantity integer;
begin
  select stock_balances.quantity
  into current_quantity
  from public.stock_balances
  where stock_balances.crate_id = target_crate
    and stock_balances.product_id = target_product
  for update;

  if found then
    if current_quantity + delta < 0 then
      raise exception 'insufficient stock' using errcode = '23514';
    end if;

    update public.stock_balances
    set quantity = current_quantity + delta
    where stock_balances.crate_id = target_crate
      and stock_balances.product_id = target_product;
    return;
  end if;

  if delta < 1 then
    raise exception 'insufficient stock' using errcode = '23514';
  end if;

  insert into public.stock_balances (crate_id, product_id, quantity)
  values (target_crate, target_product, delta);
end;
$$;

revoke all on function app_private.clean_idempotency_key(text) from public, anon, authenticated, service_role;
revoke all on function app_private.stock_request_fingerprint(text, uuid, uuid, uuid, integer, text) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_carton_quantity(integer) from public, anon, authenticated, service_role;
revoke all on function app_private.prepare_stock_locations(uuid[]) from public, anon, authenticated, service_role;
revoke all on function app_private.replay_stock_transaction(text, text) from public, anon, authenticated, service_role;
revoke all on function app_private.apply_stock_delta(uuid, uuid, integer) from public, anon, authenticated, service_role;

create or replace function public.post_opening_stock(
  target_product uuid,
  target_crate uuid,
  carton_quantity integer,
  idempotency_key text,
  posting_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  fingerprint text;
  replay jsonb;
  created_id uuid;
  reference_number text;
  conflict_name text;
begin
  perform app_private.assert_permission('stock.opening.post');
  perform app_private.assert_carton_quantity(carton_quantity);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_optional_text(posting_notes, 500);
  fingerprint := app_private.stock_request_fingerprint(
    'OPENING_STOCK',
    target_product,
    null,
    target_crate,
    carton_quantity,
    cleaned_notes
  );
  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);

  if replay is not null then
    return replay;
  end if;

  if not exists (
    select 1
    from public.products
    where products.id = target_product
      and products.is_active
  ) then
    raise exception 'product not found or inactive' using errcode = '23514';
  end if;

  perform app_private.prepare_stock_locations(array[target_crate]);

  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
  if replay is not null then
    return replay;
  end if;

  perform stock_balances.quantity
  from public.stock_balances
  where stock_balances.crate_id = target_crate
    and stock_balances.product_id = target_product
  for update;

  if exists (
    select 1
    from public.stock_transactions
    where stock_transactions.transaction_type = 'OPENING_STOCK'
      and stock_transactions.product_id = target_product
      and stock_transactions.destination_crate_id = target_crate
  ) then
    raise exception 'opening stock was already posted for this product and crate'
      using errcode = '23505';
  end if;

  reference_number := 'OS-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
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
    quantity
  )
  values (
    'OPENING_STOCK',
    reference_number,
    auth.uid(),
    cleaned_key,
    fingerprint,
    cleaned_notes,
    target_product,
    target_crate,
    carton_quantity
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
    target_product,
    target_crate,
    carton_quantity,
    stock_transactions.actor_id,
    stock_transactions.posted_at
  from public.stock_transactions
  where stock_transactions.id = created_id;

  perform app_private.apply_stock_delta(target_crate, target_product, carton_quantity);

  perform app_private.write_audit(
    auth.uid(),
    'post_opening_stock',
    'stock_transactions',
    created_id,
    pg_catalog.jsonb_build_object(
      'reference_number', reference_number,
      'product_id', target_product,
      'crate_id', target_crate,
      'quantity', carton_quantity
    )
  );

  return pg_catalog.jsonb_build_object(
    'id', created_id,
    'reference_number', reference_number
  );
exception
  when unique_violation then
    get stacked diagnostics conflict_name = constraint_name;

    if conflict_name = 'stock_transactions_idempotency_key' then
      replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
      if replay is not null then
        return replay;
      end if;
    end if;

    if conflict_name = 'stock_transactions_opening_once' then
      raise exception 'opening stock was already posted for this product and crate'
        using errcode = '23505';
    end if;

    raise;
end;
$$;

create or replace function public.post_crate_transfer(
  target_product uuid,
  source_crate uuid,
  destination_crate uuid,
  carton_quantity integer,
  idempotency_key text,
  posting_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  fingerprint text;
  replay jsonb;
  created_id uuid;
  reference_number text;
  source_quantity integer;
  first_crate uuid;
  second_crate uuid;
  conflict_name text;
begin
  perform app_private.assert_permission('stock.transfer.post');
  perform app_private.assert_carton_quantity(carton_quantity);

  if source_crate is not distinct from destination_crate then
    raise exception 'source and destination must be different' using errcode = '23514';
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_optional_text(posting_notes, 500);
  fingerprint := app_private.stock_request_fingerprint(
    'CRATE_TRANSFER',
    target_product,
    source_crate,
    destination_crate,
    carton_quantity,
    cleaned_notes
  );
  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);

  if replay is not null then
    return replay;
  end if;

  if not exists (
    select 1
    from public.products
    where products.id = target_product
      and products.is_active
  ) then
    raise exception 'product not found or inactive' using errcode = '23514';
  end if;

  if source_crate < destination_crate then
    first_crate := source_crate;
    second_crate := destination_crate;
  else
    first_crate := destination_crate;
    second_crate := source_crate;
  end if;

  perform app_private.prepare_stock_locations(array[first_crate, second_crate]);

  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
  if replay is not null then
    return replay;
  end if;

  select stock_balances.quantity
  into source_quantity
  from public.stock_balances
  where stock_balances.crate_id = source_crate
    and stock_balances.product_id = target_product
  for update;

  perform stock_balances.quantity
  from public.stock_balances
  where stock_balances.crate_id = destination_crate
    and stock_balances.product_id = target_product
  for update;

  if coalesce(source_quantity, 0) < carton_quantity then
    raise exception 'insufficient stock' using errcode = '23514';
  end if;

  reference_number := 'TR-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
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
    source_crate_id,
    destination_crate_id,
    quantity
  )
  values (
    'CRATE_TRANSFER',
    reference_number,
    auth.uid(),
    cleaned_key,
    fingerprint,
    cleaned_notes,
    target_product,
    source_crate,
    destination_crate,
    carton_quantity
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
    target_product,
    entries.crate_id,
    entries.quantity,
    stock_transactions.actor_id,
    stock_transactions.posted_at
  from public.stock_transactions
  cross join (
    values
      (source_crate, -carton_quantity),
      (destination_crate, carton_quantity)
  ) as entries (crate_id, quantity)
  where stock_transactions.id = created_id;

  perform app_private.apply_stock_delta(source_crate, target_product, -carton_quantity);
  perform app_private.apply_stock_delta(destination_crate, target_product, carton_quantity);

  perform app_private.write_audit(
    auth.uid(),
    'post_crate_transfer',
    'stock_transactions',
    created_id,
    pg_catalog.jsonb_build_object(
      'reference_number', reference_number,
      'product_id', target_product,
      'source_crate_id', source_crate,
      'destination_crate_id', destination_crate,
      'quantity', carton_quantity
    )
  );

  return pg_catalog.jsonb_build_object(
    'id', created_id,
    'reference_number', reference_number
  );
exception
  when unique_violation then
    get stacked diagnostics conflict_name = constraint_name;

    if conflict_name = 'stock_transactions_idempotency_key' then
      replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
      if replay is not null then
        return replay;
      end if;
    end if;

    raise;
end;
$$;

create or replace function public.list_stock_balances(
  filter_branch uuid default null,
  filter_zone uuid default null,
  filter_crate uuid default null,
  filter_product uuid default null
)
returns table (
  godown_id uuid,
  godown_code text,
  godown_name text,
  zone_id uuid,
  zone_code text,
  zone_name text,
  crate_id uuid,
  crate_code text,
  crate_name text,
  product_id uuid,
  product_sku text,
  product_name text,
  quantity integer
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.read');

  return query
  select
    branches.id,
    branches.code,
    branches.name,
    zones.id,
    zones.code,
    zones.name,
    crates.id,
    crates.code,
    crates.name,
    products.id,
    products.sku,
    products.name,
    stock_balances.quantity
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  join public.zones on zones.id = crates.zone_id
  join public.branches on branches.id = zones.branch_id
  join public.products on products.id = stock_balances.product_id
  where stock_balances.quantity > 0
    and app_private.can_work_at_branch(branches.id)
    and (filter_branch is null or branches.id = filter_branch)
    and (filter_zone is null or zones.id = filter_zone)
    and (filter_crate is null or crates.id = filter_crate)
    and (filter_product is null or products.id = filter_product)
  order by branches.name, zones.code, crates.code, products.sku;
end;
$$;

create or replace function public.list_stock_transactions(
  filter_branch uuid default null,
  filter_zone uuid default null,
  filter_crate uuid default null,
  filter_product uuid default null
)
returns table (
  transaction_id uuid,
  reference_number text,
  transaction_type text,
  product_id uuid,
  product_sku text,
  product_name text,
  source_crate_id uuid,
  source_crate_code text,
  source_zone_code text,
  destination_crate_id uuid,
  destination_crate_code text,
  destination_zone_code text,
  quantity integer,
  actor_id uuid,
  actor_name text,
  posted_at timestamptz,
  notes text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.read');

  return query
  select
    stock_transactions.id,
    stock_transactions.reference_number,
    stock_transactions.transaction_type,
    products.id,
    products.sku,
    products.name,
    stock_transactions.source_crate_id,
    source_crate.code,
    source_zone.code,
    stock_transactions.destination_crate_id,
    destination_crate.code,
    destination_zone.code,
    stock_transactions.quantity,
    stock_transactions.actor_id,
    profiles.full_name,
    stock_transactions.posted_at,
    stock_transactions.notes
  from public.stock_transactions
  join public.products on products.id = stock_transactions.product_id
  left join public.crates as source_crate
    on source_crate.id = stock_transactions.source_crate_id
  left join public.zones as source_zone
    on source_zone.id = source_crate.zone_id
  join public.crates as destination_crate
    on destination_crate.id = stock_transactions.destination_crate_id
  join public.zones as destination_zone
    on destination_zone.id = destination_crate.zone_id
  join public.branches on branches.id = destination_zone.branch_id
  left join public.profiles on profiles.id = stock_transactions.actor_id
  where app_private.can_work_at_branch(branches.id)
    and (filter_branch is null or branches.id = filter_branch)
    and (
      filter_zone is null
      or destination_zone.id = filter_zone
      or source_zone.id = filter_zone
    )
    and (
      filter_crate is null
      or destination_crate.id = filter_crate
      or source_crate.id = filter_crate
    )
    and (filter_product is null or products.id = filter_product)
  order by stock_transactions.posted_at desc, stock_transactions.reference_number desc;
end;
$$;

revoke all on function public.post_opening_stock(uuid, uuid, integer, text, text) from public, anon, service_role;
revoke all on function public.post_crate_transfer(uuid, uuid, uuid, integer, text, text) from public, anon, service_role;
revoke all on function public.list_stock_balances(uuid, uuid, uuid, uuid) from public, anon, service_role;
revoke all on function public.list_stock_transactions(uuid, uuid, uuid, uuid) from public, anon, service_role;

grant execute on function public.post_opening_stock(uuid, uuid, integer, text, text) to authenticated;
grant execute on function public.post_crate_transfer(uuid, uuid, uuid, integer, text, text) to authenticated;
grant execute on function public.list_stock_balances(uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.list_stock_transactions(uuid, uuid, uuid, uuid) to authenticated;

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
  where zones.id = target_zone
  for update;

  if selected_branch is null then
    raise exception 'zone not found' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);

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

alter table public.stock_transactions enable row level security;
alter table public.stock_ledger enable row level security;
alter table public.stock_balances enable row level security;

alter table public.stock_transactions force row level security;
alter table public.stock_ledger force row level security;
alter table public.stock_balances force row level security;

create policy stock_transactions_select_authorized
  on public.stock_transactions
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and exists (
      select 1
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = stock_transactions.destination_crate_id
        and (select app_private.can_work_at_branch(zones.branch_id))
    )
  );

create policy stock_ledger_select_authorized
  on public.stock_ledger
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and exists (
      select 1
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = stock_ledger.crate_id
        and (select app_private.can_work_at_branch(zones.branch_id))
    )
  );

create policy stock_balances_select_authorized
  on public.stock_balances
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and exists (
      select 1
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = stock_balances.crate_id
        and (select app_private.can_work_at_branch(zones.branch_id))
    )
  );

revoke all on table public.stock_transactions from public, anon, authenticated, service_role;
revoke all on table public.stock_ledger from public, anon, authenticated, service_role;
revoke all on table public.stock_balances from public, anon, authenticated, service_role;

grant select on table public.stock_transactions to authenticated;
grant select on table public.stock_ledger to authenticated;
grant select on table public.stock_balances to authenticated;

comment on function public.post_opening_stock(uuid, uuid, integer, text, text) is
  'Admin only, through stock.opening.post. One opening posting per product and crate. The caller must be authorized for the crate godown.';

comment on function public.post_crate_transfer(uuid, uuid, uuid, integer, text, text) is
  'Requires stock.transfer.post. Both crates must be active and in the same authorized godown. Cross-godown transfers are rejected.';

comment on function public.list_stock_balances(uuid, uuid, uuid, uuid) is
  'Requires stock.read. Returns positive balances only where can_work_at_branch is true. A filter outside that scope returns no rows.';

comment on function public.set_crate_active(uuid, boolean) is
  'Deactivation is rejected while the crate has a positive balance. There is no admin override.';

comment on function public.set_zone_active(uuid, boolean) is
  'Deactivation is rejected while any crate in the zone has a positive balance. There is no admin override.';
