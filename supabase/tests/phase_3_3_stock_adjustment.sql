-- Local Phase 3.3 checks. The transaction rolls back.

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
  ('godown2', gen_random_uuid()),
  ('godown_b', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('inactive', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase33@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

select app_private.bootstrap_initial_admin(
  (select id from fixture where name = 'admin'),
  'create-initial-administrator'
);

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'godown' then 'godown_manager'
  when 'godown2' then 'godown_manager'
  when 'godown_b' then 'godown_manager'
  when 'accounts' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'delivery' then 'delivery_person'
  when 'keeper' then 'store_keeper'
  when 'inactive' then 'godown_manager'
end
where fixture.name <> 'admin';

update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');

create or replace function public.phase33_claim(actor text)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = actor),
    true
  );
end;
$$;

create or replace function public.phase33_line(target uuid, sku text)
returns uuid
language sql
as $$
  select stock_verification_lines.id
  from public.stock_verification_lines
  join public.products on products.id = stock_verification_lines.product_id
  where stock_verification_lines.verification_id = target
    and products.sku = phase33_line.sku;
$$;

select public.phase33_claim('admin');
set local role authenticated;

do $$
declare
  configured text;
begin
  select app_configuration.value #>> '{}'
  into configured
  from public.app_configuration
  where app_configuration.key = 'stock.adjustment.exceptional_absolute_units';
  if configured is distinct from '10' then
    raise exception 'approved threshold was not 10';
  end if;
end;
$$;

insert into refs (name, id)
values ('branch_a', public.create_branch('phase33_a', 'Phase 33 A')),
       ('branch_b', public.create_branch('phase33_b', 'Phase 33 B'));

insert into refs (name, id)
values
  ('zone_a', public.create_zone((select id from refs where name = 'branch_a'), 'za', 'Zone A', null)),
  ('zone_b', public.create_zone((select id from refs where name = 'branch_b'), 'zb', 'Zone B', null));

insert into refs (name, id)
values
  ('crate_a', public.create_crate((select id from refs where name = 'zone_a'), 'ca', 'Crate A', null)),
  ('crate_b', public.create_crate((select id from refs where name = 'zone_b'), 'cb', 'Crate B', null)),
  ('soap', public.create_product('p33-soap', 'Phase 33 Soap', null, null)),
  ('oil', public.create_product('p33-oil', 'Phase 33 Oil', null, null));

select public.assign_user_branch((select id from fixture where name = 'godown'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'godown2'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'inactive'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'accounts'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'keeper'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'godown_b'), (select id from refs where name = 'branch_b'));

select public.post_opening_stock((select id from refs where name = 'soap'), (select id from refs where name = 'crate_a'), 5, 'p33-open-soap', null);
select public.post_opening_stock((select id from refs where name = 'oil'), (select id from refs where name = 'crate_a'), 12, 'p33-open-oil', null);

select public.phase33_claim('godown');

insert into refs (name, id)
values (
  'verification',
  public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[(select id from refs where name = 'crate_a')]
  )
);

select public.save_verification_count(public.phase33_line((select id from refs where name = 'verification'), 'p33-soap'), '4'::jsonb, 1);
select public.save_verification_count(public.phase33_line((select id from refs where name = 'verification'), 'p33-oil'), '12'::jsonb, 1);
select public.submit_stock_verification((select id from refs where name = 'verification'));
select public.report_stock_discrepancy(public.phase33_line((select id from refs where name = 'verification'), 'p33-soap'), 'soap short');
select public.request_verification_recount(public.phase33_line((select id from refs where name = 'verification'), 'p33-soap'));
select public.save_verification_recount(
  public.phase33_line((select id from refs where name = 'verification'), 'p33-soap'),
  '4'::jsonb,
  2
);
select public.review_verification_discrepancy(
  public.phase33_line((select id from refs where name = 'verification'), 'p33-soap'),
  'recount confirms four',
  '{}'::uuid[]
);

insert into refs (name, id)
select 'photo', (public.create_verification_photo_upload((select id from refs where name = 'verification'), 'count sheet', null) ->> 'id')::uuid;

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

select public.finalize_verification_photo_upload((select id from refs where name = 'photo'), encode(decode('ffd8ffd9', 'hex'), 'base64'));
select public.close_stock_verification((select id from refs where name = 'verification'), 'correction_requested', 'soap remains short');

select public.phase33_claim('keeper');

do $$
begin
  perform public.create_stock_adjustment(
    (select id from refs where name = 'verification'),
    'shortage',
    'keeper request',
    array[public.phase33_line((select id from refs where name = 'verification'), 'p33-soap')],
    'p33-keeper-request',
    null
  );
  raise exception 'store keeper created an adjustment';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase33_claim('admin');

do $$
begin
  perform public.create_stock_adjustment(
    (select id from refs where name = 'verification'),
    'shortage',
    'admin request',
    array[public.phase33_line((select id from refs where name = 'verification'), 'p33-soap')],
    'p33-admin-request',
    null
  );
  raise exception 'admin created an adjustment';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase33_claim('godown');

insert into refs (name, id)
select 'request', (public.create_stock_adjustment(
  (select id from refs where name = 'verification'),
  'shortage',
  'post the recounted shortage',
  array[public.phase33_line((select id from refs where name = 'verification'), 'p33-soap')],
  'p33-request-soap',
  null
) ->> 'id')::uuid;

select public.submit_stock_adjustment((select id from refs where name = 'request'), 1);

do $$
declare
  header public.stock_adjustment_requests;
begin
  select * into header from public.stock_adjustment_requests where id = (select id from refs where name = 'request');
  if header.status <> 'submitted' or header.exceptional is distinct from false or header.version <> 2 then
    raise exception 'ordinary request was not submitted correctly';
  end if;
end;
$$;

do $$
begin
  perform public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'self approval');
  raise exception 'requester approved the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'you cannot approve your own adjustment' then
      raise;
    end if;
end;
$$;

select public.phase33_claim('admin');

do $$
begin
  perform public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'admin ordinary');
  raise exception 'admin approved while another manager exists';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase33_claim('godown2');
select public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'second manager approval');

select public.phase33_claim('godown');
select public.post_stock_adjustment((select id from refs where name = 'request'), 3, 'p33-post-soap');
select public.post_stock_adjustment((select id from refs where name = 'request'), 3, 'p33-post-soap');

do $$
declare
  balance integer;
  ledger_count integer;
begin
  select quantity into balance
  from public.stock_balances
  where crate_id = (select id from refs where name = 'crate_a')
    and product_id = (select id from refs where name = 'soap');
  if balance <> 4 then
    raise exception 'posted adjustment did not leave four soap cases';
  end if;
  select count(*) into ledger_count
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.transaction_type = 'ADJUSTMENT';
  if ledger_count <> 1 then
    raise exception 'adjustment ledger was not a single signed entry';
  end if;
  if (select status from public.stock_adjustment_requests where id = (select id from refs where name = 'request')) <> 'posted' then
    raise exception 'request was not posted';
  end if;
end;
$$;

do $$
begin
  insert into public.stock_adjustment_requests (
    request_number, godown_id, verification_id, evidence_id, status, reason_code, note, requested_by, idempotency_key
  )
  values (
    'AJ-DIRECT',
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'verification'),
    (select id from refs where name = 'photo'),
    'draft',
    'shortage',
    'direct',
    auth.uid(),
    'p33-direct-write'
  );
  raise exception 'direct adjustment insert was allowed';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase33_claim('godown');

insert into refs (name, id)
values (
  'verification_big',
  public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[(select id from refs where name = 'crate_a')]
  )
);

select public.save_verification_count(public.phase33_line((select id from refs where name = 'verification_big'), 'p33-soap'), '4'::jsonb, 1);
select public.save_verification_count(public.phase33_line((select id from refs where name = 'verification_big'), 'p33-oil'), '0'::jsonb, 1);
select public.submit_stock_verification((select id from refs where name = 'verification_big'));
select public.report_stock_discrepancy(public.phase33_line((select id from refs where name = 'verification_big'), 'p33-oil'), 'oil missing');
select public.request_verification_recount(public.phase33_line((select id from refs where name = 'verification_big'), 'p33-oil'));
select public.save_verification_recount(
  public.phase33_line((select id from refs where name = 'verification_big'), 'p33-oil'),
  '0'::jsonb,
  2
);
select public.review_verification_discrepancy(
  public.phase33_line((select id from refs where name = 'verification_big'), 'p33-oil'),
  'none found',
  '{}'::uuid[]
);

insert into refs (name, id)
select 'photo_big', (public.create_verification_photo_upload((select id from refs where name = 'verification_big'), 'second sheet', null) ->> 'id')::uuid;

insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'stock-verification-evidence',
  stock_verification_evidence.storage_path,
  auth.uid(),
  auth.uid()::text,
  jsonb_build_object('size', 4, 'mimetype', 'image/jpeg', 'eTag', encode(extensions.digest(decode('ffd8ffd9', 'hex'), 'md5'), 'hex'))
from public.stock_verification_evidence
where id = (select id from refs where name = 'photo_big');

select public.finalize_verification_photo_upload((select id from refs where name = 'photo_big'), encode(decode('ffd8ffd9', 'hex'), 'base64'));
select public.close_stock_verification((select id from refs where name = 'verification_big'), 'correction_requested', 'oil remains short');

insert into refs (name, id)
select 'big', (public.create_stock_adjustment(
  (select id from refs where name = 'verification_big'),
  'shortage',
  'twelve oil cases are exceptional',
  array[public.phase33_line((select id from refs where name = 'verification_big'), 'p33-oil')],
  'p33-request-oil',
  null
) ->> 'id')::uuid;

select public.submit_stock_adjustment((select id from refs where name = 'big'), 1);

do $$
begin
  if (select exceptional from public.stock_adjustment_requests where id = (select id from refs where name = 'big')) is distinct from true then
    raise exception 'eleven-plus line was not exceptional';
  end if;
end;
$$;

select public.phase33_claim('godown2');

do $$
begin
  perform public.approve_stock_adjustment((select id from refs where name = 'big'), 2, 'manager exceptional');
  raise exception 'manager approved an exceptional request';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase33_claim('admin');
select public.approve_stock_adjustment((select id from refs where name = 'big'), 2, 'admin exceptional approval');

select public.phase33_claim('godown_b');

do $$
begin
  perform public.post_stock_adjustment((select id from refs where name = 'big'), 3, 'p33-post-oil-cross');
  raise exception 'cross-godown post was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase33_claim('admin');
insert into refs (name, id)
values ('crate_a2', public.create_crate((select id from refs where name = 'zone_a'), 'ca2', 'Crate A2', null));

select public.phase33_claim('godown');
select public.post_crate_transfer(
  (select id from refs where name = 'oil'),
  (select id from refs where name = 'crate_a'),
  (select id from refs where name = 'crate_a2'),
  1,
  'p33-move-oil',
  null
);

do $$
begin
  perform public.post_stock_adjustment((select id from refs where name = 'big'), 3, 'p33-post-oil-stale');
  raise exception 'stale adjustment posted';
exception
  when check_violation then
    if sqlerrm <> 'adjustment is stale and needs a new verification' then
      raise;
    end if;
end;
$$;

do $$
declare
  oil_balance integer;
begin
  select quantity into oil_balance
  from public.stock_balances
  where crate_id = (select id from refs where name = 'crate_a')
    and product_id = (select id from refs where name = 'oil');
  if oil_balance <> 11 then
    raise exception 'stale rejection changed the remaining oil balance';
  end if;
end;
$$;

rollback;
