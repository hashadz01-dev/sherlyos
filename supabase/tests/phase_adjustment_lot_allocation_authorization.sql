-- Lot allocation authorization. Disposable. Rolls back.
-- Proves a Godown Manager can save a matching shortage allocation, and that
-- save does not approve, post, or duplicate ledger rows.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

create temp table refs (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated;
grant select, insert, update, delete on refs to authenticated;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('salesperson', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.allocfix@example.com',
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
      values ((select id from fixture where name = 'admin'), 'Alloc Admin', true)
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
  when 'salesperson' then 'salesperson'
end
where fixture.name <> 'admin';

create or replace function public.allocfix_claim(actor text)
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

create or replace function public.allocfix_line(target uuid)
returns uuid
language sql
as $$
  select stock_adjustment_lines.id
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = target
  limit 1;
$$;

do $$
begin
  if position(
    'app.adjustment_write' in pg_get_functiondef(
      'public.set_stock_adjustment_line_lot_allocations(uuid,jsonb)'::regprocedure
    )
  ) = 0 then
    raise exception 'lot allocation writer does not open the adjustment guard';
  end if;
end $$;

select public.allocfix_claim('admin');
set local role authenticated;

insert into refs (name, id)
values ('branch', public.create_branch('allocfix_a', 'Alloc Fix A'));

insert into refs (name, id)
values (
  'zone',
  public.create_zone((select id from refs where name = 'branch'), 'az', 'Alloc Zone', null)
);

insert into refs (name, id)
values (
  'crate',
  public.create_crate((select id from refs where name = 'zone'), 'ac', 'Alloc Crate', null)
),
(
  'product',
  public.create_product('allocfix-sku', 'Alloc Fix Product', null, null)
);

select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  (select id from refs where name = 'branch')
);
select public.assign_user_branch(
  (select id from fixture where name = 'keeper'),
  (select id from refs where name = 'branch')
);

insert into refs (name, id)
select 'opening', (
  public.post_opening_stock(
    (select id from refs where name = 'product'),
    (select id from refs where name = 'crate'),
    10,
    'allocfix-open',
    'allocation fixture'
  ) ->> 'id'
)::uuid;

insert into refs (name, id)
select 'opening_audit', audit_logs.id
from public.audit_logs
where audit_logs.entity_id = (select id from refs where name = 'opening')
order by audit_logs.occurred_at
limit 1;

-- Lot rows are fixture attribution only. No lot ledger row is written, so
-- saving an allocation cannot be confused with a stock posting.
reset role;
insert into public.stock_lots (
  id, product_id, branch_id, manufacturer_lot_code, received_on, status, origin, created_by
)
values
  (
    gen_random_uuid(),
    (select id from refs where name = 'product'),
    (select id from refs where name = 'branch'),
    'ALLOC-SMALL',
    clock_timestamp(),
    'available',
    'opening',
    (select id from fixture where name = 'admin')
  ),
  (
    gen_random_uuid(),
    (select id from refs where name = 'product'),
    (select id from refs where name = 'branch'),
    'ALLOC-LARGE',
    clock_timestamp(),
    'available',
    'opening',
    (select id from fixture where name = 'admin')
  );

insert into refs (name, id)
select 'lot_small', id
from public.stock_lots
where manufacturer_lot_code = 'ALLOC-SMALL'
  and branch_id = (select id from refs where name = 'branch');

insert into refs (name, id)
select 'lot_large', id
from public.stock_lots
where manufacturer_lot_code = 'ALLOC-LARGE'
  and branch_id = (select id from refs where name = 'branch');

select app_private.begin_lot_balance_write('helper');
insert into public.stock_lot_balances (lot_id, crate_id, quantity)
values
  ((select id from refs where name = 'lot_small'), (select id from refs where name = 'crate'), 2),
  ((select id from refs where name = 'lot_large'), (select id from refs where name = 'crate'), 8);
select app_private.end_lot_balance_write();

select public.allocfix_claim('godown');
set local role authenticated;

insert into refs (name, id)
values (
  'verification',
  public.start_stock_verification(
    (select id from refs where name = 'branch'),
    current_date,
    array[(select id from refs where name = 'zone')],
    array[(select id from refs where name = 'crate')]
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
    'attribute the shortage',
    array[(
      select stock_verification_lines.id
      from public.stock_verification_lines
      where stock_verification_lines.verification_id = (select id from refs where name = 'verification')
        and stock_verification_lines.product_id = (select id from refs where name = 'product')
    )],
    'allocfix-request',
    null
  ) ->> 'id'
)::uuid;

insert into refs (name, id)
select 'line', public.allocfix_line((select id from refs where name = 'request'));

insert into refs (name, id)
select 'created_event', stock_adjustment_events.id
from public.stock_adjustment_events
where stock_adjustment_events.request_id = (select id from refs where name = 'request')
  and stock_adjustment_events.event_type = 'created';

-- 1. Authorized Godown Manager saves a matching shortage allocation.
select public.set_stock_adjustment_line_lot_allocations(
  (select id from refs where name = 'line'),
  jsonb_build_array(
    jsonb_build_object('lot_id', (select id from refs where name = 'lot_small'), 'quantity', -2)
  )
);

-- 6 and 8. A second save replaces the row. It does not post or duplicate ledger entries.
select public.set_stock_adjustment_line_lot_allocations(
  (select id from refs where name = 'line'),
  jsonb_build_array(
    jsonb_build_object('lot_id', (select id from refs where name = 'lot_small'), 'quantity', -2)
  )
);

reset role;

do $$
declare
  header public.stock_adjustment_requests;
  allocation_count integer;
  allocation_qty integer;
  book_quantity integer;
  ledger_count integer;
  adjustment_txns integer;
  adjustment_audits integer;
  opening_audit_action text;
  event_count integer;
begin
  select * into header
  from public.stock_adjustment_requests
  where id = (select id from refs where name = 'request');

  if header.status <> 'draft' or header.version <> 3 then
    raise exception 'saved allocation left status % version %', header.status, header.version;
  end if;

  select count(*), coalesce(sum(quantity), 0)
  into allocation_count, allocation_qty
  from public.stock_adjustment_line_lot_allocations
  where adjustment_line_id = (select id from refs where name = 'line');

  if allocation_count <> 1 or allocation_qty <> -2 then
    raise exception 'repeated save duplicated or changed allocations (% rows, %)', allocation_count, allocation_qty;
  end if;

  select quantity into book_quantity
  from public.stock_balances
  where crate_id = (select id from refs where name = 'crate')
    and product_id = (select id from refs where name = 'product');
  if book_quantity <> 10 then
    raise exception 'saving allocations changed the book quantity to %', book_quantity;
  end if;

  select count(*) into ledger_count
  from public.stock_ledger
  where crate_id = (select id from refs where name = 'crate')
    and product_id = (select id from refs where name = 'product');
  if ledger_count <> 1 then
    raise exception 'saving allocations wrote ledger rows (% )', ledger_count;
  end if;

  select count(*) into adjustment_txns
  from public.stock_transactions
  where adjustment_request_id = header.id
     or transaction_type = 'ADJUSTMENT' and reference_number = header.request_number;
  if adjustment_txns <> 0 then
    raise exception 'saving allocations created an adjustment transaction';
  end if;

  select count(*) into adjustment_audits
  from public.audit_logs
  where entity_table = 'stock_adjustment_requests'
    and entity_id = header.id;
  if adjustment_audits <> 0 then
    raise exception 'saving allocations wrote an adjustment audit row';
  end if;

  select action into opening_audit_action
  from public.audit_logs
  where id = (select id from refs where name = 'opening_audit');
  if opening_audit_action is null then
    raise exception 'opening stock audit row was removed';
  end if;

  select count(*) into event_count
  from public.stock_adjustment_events
  where request_id = header.id
    and id = (select id from refs where name = 'created_event')
    and event_type = 'created';
  if event_count <> 1 then
    raise exception 'created adjustment event was not preserved';
  end if;

  if (
    select quantity
    from public.stock_lot_balances
    where lot_id = (select id from refs where name = 'lot_small')
      and crate_id = (select id from refs where name = 'crate')
  ) <> 2 then
    raise exception 'saving allocations changed the lot balance';
  end if;
end $$;

-- 2. Absolute allocated quantity must equal the adjustment magnitude.
select public.allocfix_claim('godown');
set local role authenticated;

do $$
begin
  perform public.set_stock_adjustment_line_lot_allocations(
    (select id from refs where name = 'line'),
    jsonb_build_array(
      jsonb_build_object('lot_id', (select id from refs where name = 'lot_small'), 'quantity', -1)
    )
  );
  raise exception 'partial allocation was accepted';
exception
  when check_violation then
    if sqlerrm not like 'allocation quantities (%) must equal requested_cases (%)' then
      raise;
    end if;
end $$;

do $$
begin
  perform public.set_stock_adjustment_line_lot_allocations(
    (select id from refs where name = 'line'),
    jsonb_build_array(
      jsonb_build_object('lot_id', (select id from refs where name = 'lot_small'), 'quantity', 0)
    )
  );
  raise exception 'zero allocation was accepted';
exception
  when check_violation then
    if sqlerrm <> 'each allocation requires lot_id and non-zero quantity' then
      raise;
    end if;
end $$;

-- 3. A shortage cannot take more than the lot still has available.
reset role;
select app_private.begin_lot_balance_write('helper');
update public.stock_lot_balances
set quantity = 1
where lot_id = (select id from refs where name = 'lot_small')
  and crate_id = (select id from refs where name = 'crate');
select app_private.end_lot_balance_write();

select public.allocfix_claim('godown');
set local role authenticated;

do $$
begin
  perform public.set_stock_adjustment_line_lot_allocations(
    (select id from refs where name = 'line'),
    jsonb_build_array(
      jsonb_build_object('lot_id', (select id from refs where name = 'lot_small'), 'quantity', -2)
    )
  );
  raise exception 'allocation above the eligible lot quantity was accepted';
exception
  when check_violation then
    if sqlerrm <> 'allocation exceeds eligible lot quantity' then
      raise;
    end if;
end $$;

reset role;
select app_private.begin_lot_balance_write('helper');
update public.stock_lot_balances
set quantity = 2
where lot_id = (select id from refs where name = 'lot_small')
  and crate_id = (select id from refs where name = 'crate');
select app_private.end_lot_balance_write();

select public.allocfix_claim('godown');
set local role authenticated;

do $$
declare
  allocation_qty integer;
begin
  select quantity into allocation_qty
  from public.stock_adjustment_line_lot_allocations
  where adjustment_line_id = (select id from refs where name = 'line')
    and lot_id = (select id from refs where name = 'lot_small');
  if allocation_qty is distinct from -2 then
    raise exception 'rejected allocation replaced the saved row';
  end if;
end $$;

-- 4. Store Keeper cannot save adjustment allocations.
select public.allocfix_claim('keeper');

do $$
begin
  perform public.set_stock_adjustment_line_lot_allocations(
    (select id from refs where name = 'line'),
    jsonb_build_array(
      jsonb_build_object('lot_id', (select id from refs where name = 'lot_large'), 'quantity', -2)
    )
  );
  raise exception 'store keeper saved an allocation';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end $$;

-- 5. Request permission without godown scope is still refused.
-- The grant is transaction-local and rolls back with this script.
reset role;
insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'stock.adjustment.request'
where roles.code = 'salesperson'
on conflict do nothing;

select public.allocfix_claim('salesperson');
set local role authenticated;

do $$
begin
  if app_private.can_work_at_branch((select id from refs where name = 'branch')) then
    raise exception 'salesperson fixture unexpectedly has godown scope';
  end if;
  perform public.set_stock_adjustment_line_lot_allocations(
    (select id from refs where name = 'line'),
    jsonb_build_array(
      jsonb_build_object('lot_id', (select id from refs where name = 'lot_large'), 'quantity', -2)
    )
  );
  raise exception 'out-of-scope user saved an allocation';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end $$;

select public.allocfix_claim('godown');

-- 7. Approval and posting stay separate. The requester cannot approve.
-- Posting a draft does not write a ledger row.
do $$
begin
  perform public.approve_stock_adjustment(
    (select id from refs where name = 'request'),
    3,
    'self approval'
  );
  raise exception 'requester approved the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'you cannot approve your own adjustment' then
      raise;
    end if;
end $$;

do $$
begin
  perform public.post_stock_adjustment(
    (select id from refs where name = 'request'),
    3,
    'allocfix-must-not-post'
  );
  raise exception 'draft adjustment was posted';
exception
  when insufficient_privilege then
    if sqlerrm <> 'adjustment cannot be posted' then
      raise;
    end if;
end $$;

-- 9. Submitted (and any non-draft, non-returned) requests cannot be reallocated.
select public.submit_stock_adjustment((select id from refs where name = 'request'), 3);

do $$
declare
  header public.stock_adjustment_requests;
begin
  select * into header
  from public.stock_adjustment_requests
  where id = (select id from refs where name = 'request');
  if header.status <> 'submitted' or header.version <> 4 then
    raise exception 'submit did not leave a separate submitted version';
  end if;
end $$;

do $$
begin
  perform public.set_stock_adjustment_line_lot_allocations(
    (select id from refs where name = 'line'),
    jsonb_build_array(
      jsonb_build_object('lot_id', (select id from refs where name = 'lot_small'), 'quantity', -2)
    )
  );
  raise exception 'submitted adjustment accepted a new allocation';
exception
  when insufficient_privilege then
    if sqlerrm <> 'lot allocations cannot change in status submitted' then
      raise;
    end if;
end $$;

do $$
begin
  perform public.post_stock_adjustment(
    (select id from refs where name = 'request'),
    4,
    'allocfix-submitted-must-not-post'
  );
  raise exception 'submitted adjustment was posted';
exception
  when insufficient_privilege then
    if sqlerrm <> 'adjustment cannot be posted' then
      raise;
    end if;
end $$;

reset role;

do $$
declare
  book_quantity integer;
  adjustment_txns integer;
  created_events integer;
  opening_audit_action text;
begin
  select quantity into book_quantity
  from public.stock_balances
  where crate_id = (select id from refs where name = 'crate')
    and product_id = (select id from refs where name = 'product');
  if book_quantity <> 10 then
    raise exception 'book quantity changed to %', book_quantity;
  end if;

  select count(*) into adjustment_txns
  from public.stock_transactions
  where transaction_type = 'ADJUSTMENT'
    and adjustment_request_id = (select id from refs where name = 'request');
  if adjustment_txns <> 0 then
    raise exception 'refused post still wrote an adjustment transaction';
  end if;

  select count(*) into created_events
  from public.stock_adjustment_events
  where id = (select id from refs where name = 'created_event')
    and event_type = 'created'
    and request_version = 1;
  if created_events <> 1 then
    raise exception 'original adjustment history row changed';
  end if;

  select action into opening_audit_action
  from public.audit_logs
  where id = (select id from refs where name = 'opening_audit');
  if opening_audit_action is null then
    raise exception 'opening stock audit row changed';
  end if;
end $$;

rollback;
