-- Lot-aware adjustment posting. Disposable. Rolls back.
-- Proves two allocation rows on one line post as two signed ledger rows,
-- and that a one-row ledger is still rejected when allocations exist.
-- The cutover configuration row is not updated. A transaction-local function
-- stand-in makes stock_lots_dual_write_enabled() return true, then rollback
-- restores the real function.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

create temp table refs (
  name text primary key,
  id uuid not null
);

create temp table preserved_balance as
select crate_id, product_id, quantity
from public.stock_balances
limit 1;

create temp table preserved_tally as
select
  (select count(*)::integer from public.damage_stock_holds) as holds,
  (select count(*)::integer from public.stock_reservations) as reservations,
  (select audit_logs.id from public.audit_logs order by audit_logs.occurred_at limit 1) as audit_id;

grant select on fixture to authenticated;
grant select, insert, update, delete on refs to authenticated;
grant select on preserved_balance to authenticated;
grant select on preserved_tally to authenticated;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.postadj@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'),
      'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values ((select id from fixture where name = 'admin'), 'Post Adj Admin', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select
        (select id from fixture where name = 'admin'),
        roles.id,
        (select id from fixture where name = 'admin')
      from public.roles
      where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
end
where fixture.name <> 'admin';

create or replace function public.postadj_claim(actor text)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = actor),
    true
  );
  perform set_config(
    'request.jwt.claim.sub',
    (select id::text from fixture where name = actor),
    true
  );
end;
$$;

do $$
begin
  if position(
    'stock_adjustment_line_lot_allocations' in pg_get_functiondef(
      'app_private.assert_stock_transaction_complete()'::regprocedure
    )
  ) = 0 then
    raise exception 'completeness function does not accept lot allocation rows';
  end if;
  if position(
    'app.adjustment_write' in pg_get_functiondef(
      'public.set_stock_adjustment_line_lot_allocations(uuid,jsonb)'::regprocedure
    )
  ) = 0 then
    raise exception 'lot allocation writer does not open the adjustment guard';
  end if;
end $$;

-- Stand-in only. app_configuration.stock.lots.dual_write_enabled stays unchanged.
create or replace function app_private.stock_lots_dual_write_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select true;
$$;

select public.postadj_claim('admin');
set local role authenticated;

insert into refs (name, id)
values ('branch', public.create_branch('postadj_a', 'Post Adj A'));

insert into refs (name, id)
values (
  'zone',
  public.create_zone((select id from refs where name = 'branch'), 'pz', 'Post Zone', null)
);

insert into refs (name, id)
values
  (
    'crate_a',
    public.create_crate((select id from refs where name = 'zone'), 'pca', 'Post Crate A', null)
  ),
  (
    'crate_b',
    public.create_crate((select id from refs where name = 'zone'), 'pcb', 'Post Crate B', null)
  ),
  (
    'product',
    public.create_product('postadj-sku', 'Post Adj Product', null, null)
  );

select public.set_product_expiry_policy((select id from refs where name = 'product'), 'non_expiring');
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  (select id from refs where name = 'branch')
);

select public.post_opening_stock(
  (select id from refs where name = 'product'),
  (select id from refs where name = 'crate_a'),
  2,
  'postadj-open-a',
  'small lot',
  'POSTADJ-SMALL',
  null,
  null
);

select public.post_opening_stock(
  (select id from refs where name = 'product'),
  (select id from refs where name = 'crate_b'),
  8,
  'postadj-open-b',
  'large lot',
  'POSTADJ-LARGE',
  null,
  null
);

insert into refs (name, id)
select 'lot_small', stock_lots.id
from public.stock_lots
where stock_lots.manufacturer_lot_code = 'POSTADJ-SMALL'
  and stock_lots.product_id = (select id from refs where name = 'product');

insert into refs (name, id)
select 'lot_large', stock_lots.id
from public.stock_lots
where stock_lots.manufacturer_lot_code = 'POSTADJ-LARGE'
  and stock_lots.product_id = (select id from refs where name = 'product');

select public.post_crate_transfer(
  (select id from refs where name = 'product'),
  (select id from refs where name = 'crate_b'),
  (select id from refs where name = 'crate_a'),
  8,
  'postadj-xfer',
  null,
  jsonb_build_array(
    jsonb_build_object(
      'lot_id', (select id from refs where name = 'lot_large'),
      'quantity', 8
    )
  )
);

select public.postadj_claim('godown');

insert into refs (name, id)
values (
  'verification',
  public.start_stock_verification(
    (select id from refs where name = 'branch'),
    current_date,
    array[(select id from refs where name = 'zone')],
    array[(select id from refs where name = 'crate_a')]
  )
);

select public.save_verification_count(
  (
    select stock_verification_lines.id
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = (select id from refs where name = 'verification')
      and stock_verification_lines.product_id = (select id from refs where name = 'product')
  ),
  '8'::jsonb,
  1
);
select public.submit_stock_verification((select id from refs where name = 'verification'));
select public.report_stock_discrepancy(
  (
    select stock_verification_lines.id
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = (select id from refs where name = 'verification')
      and stock_verification_lines.product_id = (select id from refs where name = 'product')
  ),
  'two cases short'
);
select public.request_verification_recount(
  (
    select stock_verification_lines.id
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = (select id from refs where name = 'verification')
      and stock_verification_lines.product_id = (select id from refs where name = 'product')
  )
);
select public.save_verification_recount(
  (
    select stock_verification_lines.id
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = (select id from refs where name = 'verification')
      and stock_verification_lines.product_id = (select id from refs where name = 'product')
  ),
  '8'::jsonb,
  2
);
select public.review_verification_discrepancy(
  (
    select stock_verification_lines.id
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = (select id from refs where name = 'verification')
      and stock_verification_lines.product_id = (select id from refs where name = 'product')
  ),
  'recount confirms eight',
  '{}'::uuid[]
);

insert into refs (name, id)
select 'photo', (
  public.create_verification_photo_upload(
    (select id from refs where name = 'verification'),
    'count sheet',
    null
  ) ->> 'id'
)::uuid;

insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'stock-verification-evidence',
  stock_verification_evidence.storage_path,
  auth.uid(),
  auth.uid()::text,
  jsonb_build_object(
    'size', 4,
    'mimetype', 'image/jpeg',
    'eTag', encode(extensions.digest(decode('ffd8ffd9', 'hex'), 'md5'), 'hex')
  )
from public.stock_verification_evidence
where id = (select id from refs where name = 'photo');

select public.finalize_verification_photo_upload(
  (select id from refs where name = 'photo'),
  encode(decode('ffd8ffd9', 'hex'), 'base64')
);
select public.close_stock_verification(
  (select id from refs where name = 'verification'),
  'correction_requested',
  'two cases remain short'
);

insert into refs (name, id)
select 'request', (
  public.create_stock_adjustment(
    (select id from refs where name = 'verification'),
    'shortage',
    'attribute both lots',
    array[(
      select stock_verification_lines.id
      from public.stock_verification_lines
      where stock_verification_lines.verification_id = (select id from refs where name = 'verification')
        and stock_verification_lines.product_id = (select id from refs where name = 'product')
    )],
    'postadj-request',
    null
  ) ->> 'id'
)::uuid;

insert into refs (name, id)
select 'line', stock_adjustment_lines.id
from public.stock_adjustment_lines
where stock_adjustment_lines.request_id = (select id from refs where name = 'request');

insert into refs (name, id)
select 'created_event', stock_adjustment_events.id
from public.stock_adjustment_events
where stock_adjustment_events.request_id = (select id from refs where name = 'request')
  and stock_adjustment_events.event_type = 'created';

select public.set_stock_adjustment_line_lot_allocations(
  (select id from refs where name = 'line'),
  jsonb_build_array(
    jsonb_build_object('lot_id', (select id from refs where name = 'lot_small'), 'quantity', -1),
    jsonb_build_object('lot_id', (select id from refs where name = 'lot_large'), 'quantity', -1)
  )
);

-- One combined row matches the line count and the signed sum, but not the two allocations.
reset role;

do $$
declare
  txn uuid;
begin
  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity, adjustment_request_id
  ) values (
    'ADJUSTMENT',
    'AJ-POSTADJ-INCOMPLETE',
    (select id from fixture where name = 'admin'),
    'postadj-incomplete',
    'incomplete-shape',
    (select id from refs where name = 'product'),
    (select id from refs where name = 'crate_a'),
    2,
    (select id from refs where name = 'request')
  )
  returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at
  ) values (
    txn,
    (select id from refs where name = 'product'),
    (select id from refs where name = 'crate_a'),
    -2,
    (select id from fixture where name = 'admin'),
    pg_catalog.clock_timestamp()
  );

  set constraints stock_ledger_complete immediate;
  raise exception 'one ledger row was accepted for two lot allocations';
exception
  when check_violation then
    if sqlerrm <> 'adjustment ledger is incomplete' then
      raise;
    end if;
end $$;

-- Aggregate shape still passes when the line has no saved allocations.
do $$
declare
  txn uuid;
begin
  delete from public.stock_adjustment_line_lot_allocations
  where adjustment_line_id = (select id from refs where name = 'line');

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity, adjustment_request_id
  ) values (
    'ADJUSTMENT',
    'AJ-POSTADJ-AGGREGATE',
    (select id from fixture where name = 'admin'),
    'postadj-aggregate',
    'aggregate-shape',
    (select id from refs where name = 'product'),
    (select id from refs where name = 'crate_a'),
    2,
    (select id from refs where name = 'request')
  )
  returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at
  ) values (
    txn,
    (select id from refs where name = 'product'),
    (select id from refs where name = 'crate_a'),
    -2,
    (select id from fixture where name = 'admin'),
    pg_catalog.clock_timestamp()
  );

  set constraints stock_ledger_complete immediate;
  raise exception 'rollback aggregate probe' using errcode = 'P0001';
exception
  when sqlstate 'P0001' then
    if sqlerrm <> 'rollback aggregate probe' then
      raise;
    end if;
end $$;

set constraints stock_ledger_complete deferred;

select public.postadj_claim('godown');
set local role authenticated;

do $$
begin
  perform public.approve_stock_adjustment(
    (select id from refs where name = 'request'),
    (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request')),
    'requester approval'
  );
  raise exception 'requester approved the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'you cannot approve your own adjustment' then
      raise;
    end if;
end $$;

select public.postadj_claim('admin');

do $$
begin
  perform public.post_stock_adjustment(
    (select id from refs where name = 'request'),
    (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request')),
    'postadj-admin-post'
  );
  raise exception 'admin posted the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end $$;

select public.postadj_claim('godown');
select public.submit_stock_adjustment(
  (select id from refs where name = 'request'),
  (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request'))
);

select public.postadj_claim('keeper');

do $$
begin
  perform public.post_stock_adjustment(
    (select id from refs where name = 'request'),
    (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request')),
    'postadj-keeper-post'
  );
  raise exception 'store keeper posted the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end $$;

select public.postadj_claim('admin');
select public.approve_stock_adjustment(
  (select id from refs where name = 'request'),
  (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request')),
  'ordinary approval'
);

select public.postadj_claim('godown');

insert into refs (name, id)
select 'posted', (
  public.post_stock_adjustment(
    (select id from refs where name = 'request'),
    (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request')),
    'postadj-post'
  ) ->> 'id'
)::uuid;

do $$
declare
  replay uuid;
begin
  replay := (
    public.post_stock_adjustment(
      (select id from refs where name = 'request'),
      (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request')),
      'postadj-post'
    ) ->> 'id'
  )::uuid;
  if replay is distinct from (select id from refs where name = 'posted') then
    raise exception 'repeat post created another transaction';
  end if;
end $$;

do $$
begin
  perform public.post_stock_adjustment(
    (select id from refs where name = 'request'),
    (select version from public.stock_adjustment_requests where id = (select id from refs where name = 'request')),
    'postadj-post-again'
  );
  raise exception 'a second posting key was accepted';
exception
  when unique_violation then
    if sqlerrm <> 'adjustment was already posted' then
      raise;
    end if;
end $$;

set constraints stock_ledger_complete immediate;

reset role;

do $$
declare
  header public.stock_adjustment_requests;
  txn_count integer;
  ledger_count integer;
  book_quantity integer;
  small_qty integer;
  large_qty integer;
  other_qty integer;
  hold_count integer;
  reservation_count integer;
  audit_exists boolean;
begin
  select * into header
  from public.stock_adjustment_requests
  where id = (select id from refs where name = 'request');
  if header.status <> 'posted' or header.posted_transaction_id is distinct from (select id from refs where name = 'posted') then
    raise exception 'adjustment did not record the single posted transaction';
  end if;

  select count(*) into txn_count
  from public.stock_transactions
  where adjustment_request_id = header.id
     or id = header.posted_transaction_id;
  if txn_count <> 1 then
    raise exception 'posting created % adjustment transactions', txn_count;
  end if;

  select count(*) into ledger_count
  from public.stock_ledger
  where transaction_id = header.posted_transaction_id;
  if ledger_count <> 2 then
    raise exception 'posting created % ledger rows', ledger_count;
  end if;

  if (
    select quantity from public.stock_ledger
    where transaction_id = header.posted_transaction_id
      and lot_id = (select id from refs where name = 'lot_small')
  ) is distinct from -1
  or (
    select quantity from public.stock_ledger
    where transaction_id = header.posted_transaction_id
      and lot_id = (select id from refs where name = 'lot_large')
  ) is distinct from -1
  then
    raise exception 'lot ledger quantities did not match the allocations';
  end if;

  select quantity into book_quantity
  from public.stock_balances
  where crate_id = (select id from refs where name = 'crate_a')
    and product_id = (select id from refs where name = 'product');
  if book_quantity is distinct from 8 then
    raise exception 'aggregate book quantity is %', book_quantity;
  end if;

  select quantity into small_qty
  from public.stock_lot_balances
  where lot_id = (select id from refs where name = 'lot_small')
    and crate_id = (select id from refs where name = 'crate_a');
  select quantity into large_qty
  from public.stock_lot_balances
  where lot_id = (select id from refs where name = 'lot_large')
    and crate_id = (select id from refs where name = 'crate_a');
  if small_qty is distinct from 1 or large_qty is distinct from 7 then
    raise exception 'lot balances are % and %', small_qty, large_qty;
  end if;

  select balances.quantity into other_qty
  from public.stock_balances balances
  join preserved_balance preserved
    on preserved.crate_id = balances.crate_id
   and preserved.product_id = balances.product_id;
  if other_qty is distinct from (select quantity from preserved_balance limit 1) then
    raise exception 'unrelated stock balance changed';
  end if;

  select holds, reservations into hold_count, reservation_count from preserved_tally;
  if hold_count is distinct from (select count(*) from public.damage_stock_holds)
    or reservation_count is distinct from (select count(*) from public.stock_reservations)
  then
    raise exception 'holds or reservations changed';
  end if;

  select exists (
    select 1 from public.audit_logs where id = (select audit_id from preserved_tally)
  ) into audit_exists;
  if (select audit_id from preserved_tally) is not null and not audit_exists then
    raise exception 'existing audit row was removed';
  end if;

  if not exists (
    select 1 from public.stock_adjustment_events
    where id = (select id from refs where name = 'created_event')
      and event_type = 'created'
  ) then
    raise exception 'created adjustment event was not preserved';
  end if;
end $$;

rollback;
