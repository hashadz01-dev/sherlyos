-- Disposable fixture for overlapping adjustment sessions.
-- The runner is supabase/tests/phase_3_3_concurrency.mjs.

create or replace function public.phase33_claim(actor_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (
      select pg_catalog.json_build_object('sub', id, 'role', 'authenticated')::text
      from auth.users
      where email = actor_email
    ),
    false
  );
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  pg_catalog.gen_random_uuid(),
  'authenticated',
  'authenticated',
  address.email,
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  pg_catalog.jsonb_build_object('full_name', address.full_name),
  now(),
  now()
from (
  values
    ('admin.phase33race@example.com', 'Phase 33 Race Admin'),
    ('manager.phase33race@example.com', 'Phase 33 Race Manager'),
    ('manager2.phase33race@example.com', 'Phase 33 Race Manager 2'),
    ('keeper.phase33race@example.com', 'Phase 33 Race Keeper')
) as address (email, full_name);

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'admin.phase33race@example.com' then 'admin'
  when 'keeper.phase33race@example.com' then 'store_keeper'
  else 'godown_manager'
end
where users.email like '%.phase33race@example.com';

select public.phase33_claim('admin.phase33race@example.com');
select public.create_branch('phase33_race', 'Phase 33 Race');
select public.create_zone(
  (select id from public.branches where code = 'phase33_race'),
  'r33z', 'Race Zone 33', null
);
select public.create_crate(
  (select id from public.zones where code = 'r33z'),
  'r33a', 'Race Crate 33 A', null
);
select public.create_crate(
  (select id from public.zones where code = 'r33z'),
  'r33b', 'Race Crate 33 B', null
);
select public.create_product('p33-race-soap', 'Phase 33 Race Soap', null, null);
select public.create_supplier('Phase 33 Race Supplier', null, null);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager.phase33race@example.com'),
  (select id from public.branches where code = 'phase33_race')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager2.phase33race@example.com'),
  (select id from public.branches where code = 'phase33_race')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'keeper.phase33race@example.com'),
  (select id from public.branches where code = 'phase33_race')
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p33-race-soap'),
  (select id from public.crates where code = 'r33a'),
  40,
  'p33-race-open-soap',
  null
);

create table public.phase33_race_target (
  singleton boolean primary key default true check (singleton),
  request_id uuid,
  request_version integer,
  verification_id uuid,
  line_id uuid,
  receipt_id uuid
);

insert into public.phase33_race_target (singleton) values (true);

create or replace function public.phase33_attach_photo(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  created jsonb;
  payload bytea := pg_catalog.decode('ffd8ffd9', 'hex');
begin
  created := public.create_verification_photo_upload(target, 'race sheet', null);
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-verification-evidence',
    created ->> 'path',
    auth.uid(),
    auth.uid()::text,
    pg_catalog.jsonb_build_object(
      'size', pg_catalog.octet_length(payload),
      'mimetype', 'image/jpeg',
      'eTag', pg_catalog.encode(extensions.digest(payload, 'md5'), 'hex')
    )
  );
  perform public.finalize_verification_photo_upload((created ->> 'id')::uuid, pg_catalog.encode(payload, 'base64'));
end;
$$;

create or replace function public.phase33_close_short()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created uuid;
  line_id uuid;
  version integer;
  expected integer;
begin
  perform public.phase33_claim('manager.phase33race@example.com');
  created := public.start_stock_verification(
    (select id from public.branches where code = 'phase33_race'),
    current_date,
    array[(select id from public.zones where code = 'r33z')],
    array[(select id from public.crates where code = 'r33a')]
  );
  select stock_verification_lines.id, stock_verification_lines.line_version, stock_verification_lines.expected_cases
  into line_id, version, expected
  from public.stock_verification_lines
  where stock_verification_lines.verification_id = created
    and stock_verification_lines.product_id = (select id from public.products where sku = 'p33-race-soap');
  perform public.save_verification_count(line_id, pg_catalog.to_jsonb(expected - 1), version);
  perform public.submit_stock_verification(created);
  perform public.report_stock_discrepancy(line_id, 'race short one');
  perform public.request_verification_recount(line_id);
  select stock_verification_lines.line_version into version
  from public.stock_verification_lines
  where stock_verification_lines.id = line_id;
  perform public.save_verification_recount(line_id, pg_catalog.to_jsonb(expected - 1), version);
  perform public.review_verification_discrepancy(line_id, 'race recount confirms', '{}'::uuid[]);
  perform public.phase33_attach_photo(created);
  perform public.close_stock_verification(created, 'correction_requested', 'race remains short');
  return created;
end;
$$;

create or replace function public.phase33_prepare(kind text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  created uuid;
  selected_line uuid;
  created_request uuid;
  version integer;
  receipt jsonb;
begin
  perform public.phase33_claim('manager.phase33race@example.com');
  created := public.phase33_close_short();
  select stock_verification_lines.id
  into selected_line
  from public.stock_verification_lines
  where stock_verification_lines.verification_id = created
    and stock_verification_lines.product_id = (select id from public.products where sku = 'p33-race-soap');

  if kind = 'claim' then
    update public.phase33_race_target
    set request_id = null, request_version = null, verification_id = created, line_id = selected_line, receipt_id = null
    where singleton;
    return;
  end if;

  created_request := (public.create_stock_adjustment(
    created,
    'shortage',
    'race adjustment',
    array[selected_line],
    'p33r' || pg_catalog.left(pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', ''), 20),
    null
  ) ->> 'id')::uuid;
  perform public.submit_stock_adjustment(created_request, 1);
  version := 2;

  if kind in ('approved', 'approved_with_receipt') then
    perform public.phase33_claim('manager2.phase33race@example.com');
    perform public.approve_stock_adjustment(created_request, 2, 'race approval');
    version := 3;
  end if;

  if kind = 'approved_with_receipt' then
    perform public.phase33_claim('keeper.phase33race@example.com');
    receipt := public.create_stock_receipt(
      (select id from public.branches where code = 'phase33_race'),
      (select id from public.suppliers where name = 'Phase 33 Race Supplier'),
      'R33-' || pg_catalog.left(pg_catalog.gen_random_uuid()::text, 8),
      current_date,
      null,
      pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'product_id', (select id from public.products where sku = 'p33-race-soap'),
        'destination_crate_id', (select id from public.crates where code = 'r33a'),
        'document_cases', 2,
        'counted_cases', 2,
        'damaged_cases', 0
      ))
    );
    perform public.submit_stock_receipt((receipt ->> 'id')::uuid);
  end if;

  update public.phase33_race_target
  set
    request_id = created_request,
    request_version = version,
    verification_id = created,
    line_id = selected_line,
    receipt_id = case when kind = 'approved_with_receipt' then (receipt ->> 'id')::uuid else null end
  where singleton;
end;
$$;

create or replace function public.phase33_hold_post()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
begin
  perform public.phase33_claim('manager.phase33race@example.com');
  select * into target from public.phase33_race_target where singleton;
  perform stock_adjustment_requests.id
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target.request_id
  for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.post_stock_adjustment(
    target.request_id,
    target.request_version,
    'p33h' || pg_catalog.left(pg_catalog.replace(target.request_id::text, '-', ''), 20)
  );
end;
$$;

create or replace function public.phase33_hold_approve()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
begin
  perform public.phase33_claim('manager2.phase33race@example.com');
  select * into target from public.phase33_race_target where singleton;
  perform stock_adjustment_requests.id
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target.request_id
  for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.approve_stock_adjustment(target.request_id, target.request_version, 'held approval');
end;
$$;

create or replace function public.phase33_hold_locations_post()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
begin
  perform public.phase33_claim('manager.phase33race@example.com');
  select * into target from public.phase33_race_target where singleton;
  perform stock_adjustment_requests.id
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target.request_id
  for update;
  perform products.id
  from public.products
  where products.id = (select id from public.products where sku = 'p33-race-soap')
  for update;
  perform app_private.prepare_stock_locations(array[(select id from public.crates where code = 'r33a')]);
  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.crate_id = (select id from public.crates where code = 'r33a')
    and stock_balances.product_id = (select id from public.products where sku = 'p33-race-soap')
  for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.post_stock_adjustment(
    target.request_id,
    target.request_version,
    'p33l' || pg_catalog.left(pg_catalog.replace(target.request_id::text, '-', ''), 20)
  );
end;
$$;

create or replace function public.phase33_hold_claim()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
begin
  perform public.phase33_claim('manager.phase33race@example.com');
  select * into target from public.phase33_race_target where singleton;
  perform public.create_stock_adjustment(
    target.verification_id,
    'shortage',
    'first claim',
    array[target.line_id],
    'p33raceclaimhold',
    null
  );
  perform pg_catalog.pg_sleep(1.5);
end;
$$;

create or replace function public.phase33_assert_books()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.stock_balances where quantity < 0) then
    raise exception 'negative balance' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.stock_balances balances
    where balances.quantity is distinct from (
      select coalesce(sum(stock_ledger.quantity), 0)
      from public.stock_ledger
      where stock_ledger.crate_id = balances.crate_id
        and stock_ledger.product_id = balances.product_id
    )
  ) then
    raise exception 'balance does not match the ledger' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.stock_adjustment_requests
    where godown_id = (select id from public.branches where code = 'phase33_race')
    group by id
    having (
      select count(*) from public.stock_transactions
      where stock_transactions.adjustment_request_id = stock_adjustment_requests.id
    ) > 1
  ) then
    raise exception 'adjustment posted more than once' using errcode = '23514';
  end if;
end;
$$;

create or replace function public.phase33_same_key()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
  first_id uuid;
  replay_id uuid;
begin
  perform public.phase33_claim('manager.phase33race@example.com');
  select * into target from public.phase33_race_target where singleton;
  select stock_transactions.id into first_id
  from public.stock_transactions
  where stock_transactions.adjustment_request_id = target.request_id;
  replay_id := (public.post_stock_adjustment(
    target.request_id,
    target.request_version,
    'p33h' || pg_catalog.left(pg_catalog.replace(target.request_id::text, '-', ''), 20)
  ) ->> 'id')::uuid;
  if replay_id is distinct from first_id then
    raise exception 'same idempotency key created another posting' using errcode = '23514';
  end if;
end;
$$;

create or replace function public.phase33_other_key()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
begin
  perform public.phase33_claim('manager.phase33race@example.com');
  select * into target from public.phase33_race_target where singleton;
  perform public.post_stock_adjustment(target.request_id, target.request_version, 'p33raceotherkey');
  raise exception 'different idempotency key posted again';
exception
  when unique_violation then
    if sqlerrm <> 'adjustment was already posted' then
      raise;
    end if;
end;
$$;

create or replace function public.phase33_stale_after_receipt()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
  before_quantity integer;
  receipt jsonb;
begin
  perform public.phase33_prepare('approved');
  select quantity into before_quantity
  from public.stock_balances
  where crate_id = (select id from public.crates where code = 'r33a')
    and product_id = (select id from public.products where sku = 'p33-race-soap');
  perform public.phase33_claim('keeper.phase33race@example.com');
  receipt := public.create_stock_receipt(
    (select id from public.branches where code = 'phase33_race'),
    (select id from public.suppliers where name = 'Phase 33 Race Supplier'),
    'R33S-' || pg_catalog.left(pg_catalog.gen_random_uuid()::text, 8),
    current_date,
    null,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id', (select id from public.products where sku = 'p33-race-soap'),
      'destination_crate_id', (select id from public.crates where code = 'r33a'),
      'document_cases', 2,
      'counted_cases', 2,
      'damaged_cases', 0
    ))
  );
  perform public.submit_stock_receipt((receipt ->> 'id')::uuid);
  perform public.phase33_claim('manager2.phase33race@example.com');
  perform public.verify_stock_receipt((receipt ->> 'id')::uuid, 'p33stale' || pg_catalog.left(pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', ''), 12));
  select * into target from public.phase33_race_target where singleton;
  begin
    perform public.phase33_claim('manager.phase33race@example.com');
    perform public.post_stock_adjustment(target.request_id, target.request_version, 'p33racestalerecv');
    raise exception 'receipt left the adjustment postable';
  exception
    when check_violation then
      if sqlerrm <> 'adjustment is stale and needs a new verification' then
        raise;
      end if;
  end;
  if (select status from public.stock_adjustment_requests where id = target.request_id) <> 'approved' then
    raise exception 'stale receipt changed the request status' using errcode = '23514';
  end if;
  if (select requested_cases from public.stock_adjustment_lines where request_id = target.request_id and not released) <> -1 then
    raise exception 'stale receipt changed the approved quantity' using errcode = '23514';
  end if;
  if (select quantity from public.stock_balances
      where crate_id = (select id from public.crates where code = 'r33a')
        and product_id = (select id from public.products where sku = 'p33-race-soap'))
    is distinct from before_quantity + 2 then
    raise exception 'stale receipt adjustment changed stock' using errcode = '23514';
  end if;
end;
$$;

create or replace function public.phase33_stale_after_transfer()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.phase33_race_target;
  before_quantity integer;
begin
  perform public.phase33_prepare('approved');
  select quantity into before_quantity
  from public.stock_balances
  where crate_id = (select id from public.crates where code = 'r33a')
    and product_id = (select id from public.products where sku = 'p33-race-soap');
  perform public.phase33_claim('manager2.phase33race@example.com');
  perform public.post_crate_transfer(
    (select id from public.products where sku = 'p33-race-soap'),
    (select id from public.crates where code = 'r33a'),
    (select id from public.crates where code = 'r33b'),
    1,
    'p33stalemove' || pg_catalog.left(pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', ''), 10),
    null
  );
  select * into target from public.phase33_race_target where singleton;
  begin
    perform public.phase33_claim('manager.phase33race@example.com');
    perform public.post_stock_adjustment(target.request_id, target.request_version, 'p33racestalemove');
    raise exception 'transfer left the adjustment postable';
  exception
    when check_violation then
      if sqlerrm <> 'adjustment is stale and needs a new verification' then
        raise;
      end if;
  end;
  if (select status from public.stock_adjustment_requests where id = target.request_id) <> 'approved' then
    raise exception 'stale transfer changed the request status' using errcode = '23514';
  end if;
  if (select requested_cases from public.stock_adjustment_lines where request_id = target.request_id and not released) <> -1 then
    raise exception 'stale transfer changed the approved quantity' using errcode = '23514';
  end if;
  if (select quantity from public.stock_balances
      where crate_id = (select id from public.crates where code = 'r33a')
        and product_id = (select id from public.products where sku = 'p33-race-soap'))
    is distinct from before_quantity - 1 then
    raise exception 'stale transfer adjustment changed stock' using errcode = '23514';
  end if;
end;
$$;
