-- Local Phase 3.3 compensation lock. The transaction rolls back.

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
  ('godown2', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase33comp@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'admin' then 'admin'
  else 'godown_manager'
end;

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

create or replace function public.phase33_close_short(sku text, physical integer, label text)
returns uuid
language plpgsql
as $$
declare
  created uuid;
  line_id uuid;
  version integer;
  payload bytea := decode('ffd8ffd9', 'hex');
  photo jsonb;
begin
  perform public.phase33_claim('godown');
  created := public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[(select id from refs where name = 'crate_a')]
  );

  for line_id, version in
    select stock_verification_lines.id, stock_verification_lines.line_version
    from public.stock_verification_lines
    where stock_verification_lines.verification_id = created
  loop
    if line_id = public.phase33_line(created, sku) then
      perform public.save_verification_count(line_id, to_jsonb(physical), version);
    else
      perform public.save_verification_count(
        line_id,
        to_jsonb((select expected_cases from public.stock_verification_lines where id = line_id)),
        version
      );
    end if;
  end loop;

  perform public.submit_stock_verification(created);
  line_id := public.phase33_line(created, sku);
  perform public.report_stock_discrepancy(line_id, label);
  perform public.request_verification_recount(line_id);
  select line_version into version from public.stock_verification_lines where id = line_id;
  perform public.save_verification_recount(line_id, to_jsonb(physical), version);
  perform public.review_verification_discrepancy(line_id, label, '{}'::uuid[]);
  photo := public.create_verification_photo_upload(created, label, null);
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  select
    'stock-verification-evidence',
    photo ->> 'path',
    auth.uid(),
    auth.uid()::text,
    jsonb_build_object(
      'size', octet_length(payload),
      'mimetype', 'image/jpeg',
      'eTag', encode(extensions.digest(payload, 'md5'), 'hex')
    );
  perform public.finalize_verification_photo_upload((photo ->> 'id')::uuid, encode(payload, 'base64'));
  perform public.close_stock_verification(created, 'correction_requested', label);
  return created;
end;
$$;

select public.phase33_claim('admin');
set local role authenticated;

insert into refs (name, id)
values ('branch_a', public.create_branch('phase33_comp', 'Compensation Lock'));

insert into refs (name, id)
values ('zone_a', public.create_zone((select id from refs where name = 'branch_a'), 'cza', 'Comp Zone', null));

insert into refs (name, id)
values
  ('crate_a', public.create_crate((select id from refs where name = 'zone_a'), 'cca', 'Comp Crate', null)),
  ('soap', public.create_product('p33-comp-soap', 'Comp Soap', null, null));

select public.assign_user_branch((select id from fixture where name = 'godown'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'godown2'), (select id from refs where name = 'branch_a'));
select public.post_opening_stock((select id from refs where name = 'soap'), (select id from refs where name = 'crate_a'), 5, 'p33-comp-open', null);

insert into refs (name, id)
values ('verification', public.phase33_close_short('p33-comp-soap', 4, 'soap short one'));

select public.phase33_claim('godown');

insert into refs (name, id)
select 'request', (public.create_stock_adjustment(
  (select id from refs where name = 'verification'),
  'shortage',
  'ordinary request',
  array[public.phase33_line((select id from refs where name = 'verification'), 'p33-comp-soap')],
  'p33-comp-ordinary',
  null
) ->> 'id')::uuid;

select public.submit_stock_adjustment((select id from refs where name = 'request'), 1);
select public.phase33_claim('godown2');
select public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'ordinary approval');
select public.phase33_claim('godown');
select public.post_stock_adjustment((select id from refs where name = 'request'), 3, 'p33-comp-post');

insert into refs (name, id)
values ('verification_next', public.phase33_close_short('p33-comp-soap', 3, 'soap short again'));

insert into refs (name, id)
select 'draft', (public.create_stock_adjustment(
  (select id from refs where name = 'verification_next'),
  'shortage',
  'second ordinary draft',
  array[public.phase33_line((select id from refs where name = 'verification_next'), 'p33-comp-soap')],
  'p33-comp-draft',
  null
) ->> 'id')::uuid;

do $$
declare
  requests_before integer;
  ledger_before integer;
  events_before integer;
  posted_transaction uuid;
  posted_quantity integer;
begin
  select count(*) into requests_before from public.stock_adjustment_requests;
  select count(*) into ledger_before
  from public.stock_ledger
  where product_id = (select id from refs where name = 'soap');
  select count(*) into events_before
  from public.stock_adjustment_events
  where request_id in (
    (select id from refs where name = 'request'),
    (select id from refs where name = 'draft')
  );
  select posted_transaction_id into posted_transaction
  from public.stock_adjustment_requests
  where id = (select id from refs where name = 'request');
  select quantity into posted_quantity
  from public.stock_transactions
  where id = posted_transaction;

  perform public.phase33_claim('godown');
  begin
    perform public.create_stock_adjustment(
      (select id from refs where name = 'verification_next'),
      'shortage',
      'compensation attempt',
      array[public.phase33_line((select id from refs where name = 'verification_next'), 'p33-comp-soap')],
      'p33-comp-draft',
      (select id from refs where name = 'request')
    );
    raise exception 'existing key turned a compensation into an ordinary request';
  exception
    when check_violation then
      if sqlerrm <> 'compensation is not available' then
        raise;
      end if;
  end;

  begin
    perform public.create_stock_adjustment(
      (select id from refs where name = 'verification_next'),
      'shortage',
      'compensation attempt',
      array[public.phase33_line((select id from refs where name = 'verification_next'), 'p33-comp-soap')],
      'p33-comp-new-key',
      (select id from refs where name = 'request')
    );
    raise exception 'compensation create was accepted';
  exception
    when check_violation then
      if sqlerrm <> 'compensation is not available' then
        raise;
      end if;
  end;

  if (select count(*) from public.stock_adjustment_requests) <> requests_before then
    raise exception 'rejected compensation created a request';
  end if;
  if (select count(*) from public.stock_ledger where product_id = (select id from refs where name = 'soap')) <> ledger_before then
    raise exception 'rejected compensation posted a ledger row';
  end if;
  if (select quantity from public.stock_transactions where id = posted_transaction) is distinct from posted_quantity then
    raise exception 'rejected compensation changed the original transaction';
  end if;
  if (select count(*) from public.stock_adjustment_events where request_id in (
    (select id from refs where name = 'request'),
    (select id from refs where name = 'draft')
  )) <> events_before then
    raise exception 'rejected compensation changed audit history';
  end if;
end;
$$;

reset role;

do $$
begin
  perform set_config('app.adjustment_write', 'on', true);
  update public.stock_adjustment_requests
  set compensates_request_id = (select id from refs where name = 'request')
  where id = (select id from refs where name = 'draft');
  raise exception 'direct compensation update was accepted';
exception
  when check_violation then
    if sqlerrm <> 'compensation is not available' then
      raise;
    end if;
end;
$$;

set local role authenticated;

do $$
begin
  insert into public.stock_adjustment_requests (
    request_number, godown_id, verification_id, evidence_id, compensates_request_id,
    status, reason_code, note, requested_by, idempotency_key
  )
  select
    'AJ-COMP-DIRECT',
    godown_id,
    verification_id,
    evidence_id,
    (select id from refs where name = 'request'),
    'draft',
    'shortage',
    'direct compensation',
    requested_by,
    'p33-comp-direct'
  from public.stock_adjustment_requests
  where id = (select id from refs where name = 'draft');
  raise exception 'direct compensation insert was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

alter table public.stock_adjustment_requests disable trigger stock_adjustment_requests_guard;
alter table public.stock_adjustment_requests drop constraint stock_adjustment_requests_compensation_closed;

update public.stock_adjustment_requests
set compensates_request_id = (select id from refs where name = 'request')
where id = (select id from refs where name = 'draft');

alter table public.stock_adjustment_requests enable trigger stock_adjustment_requests_guard;
alter table public.stock_adjustment_requests
  add constraint stock_adjustment_requests_compensation_closed
  check (compensates_request_id is null) not valid;

set local role authenticated;

do $$
declare
  events_before integer;
  ledger_before integer;
  posted_transaction uuid;
  posted_quantity integer;
begin
  select count(*) into events_before from public.stock_adjustment_events;
  select count(*) into ledger_before from public.stock_ledger;
  select posted_transaction_id, quantity
  into posted_transaction, posted_quantity
  from public.stock_adjustment_requests
  join public.stock_transactions on stock_transactions.id = stock_adjustment_requests.posted_transaction_id
  where stock_adjustment_requests.id = (select id from refs where name = 'request');

  perform public.phase33_claim('godown');
  begin
    perform public.submit_stock_adjustment((select id from refs where name = 'draft'), 1);
    raise exception 'compensation draft was submitted';
  exception
    when check_violation then
      if sqlerrm <> 'compensation is not available' then
        raise;
      end if;
  end;

  perform public.phase33_claim('godown2');
  begin
    perform public.approve_stock_adjustment((select id from refs where name = 'draft'), 1, 'approve compensation');
    raise exception 'compensation draft was approved';
  exception
    when check_violation then
      if sqlerrm <> 'compensation is not available' then
        raise;
      end if;
  end;

  perform public.phase33_claim('godown');
  begin
    perform public.post_stock_adjustment((select id from refs where name = 'draft'), 1, 'p33-comp-bad-post');
    raise exception 'compensation draft was posted';
  exception
    when check_violation then
      if sqlerrm <> 'compensation is not available' then
        raise;
      end if;
  end;

  if (select status from public.stock_adjustment_requests where id = (select id from refs where name = 'draft')) <> 'draft' then
    raise exception 'rejected compensation changed the draft';
  end if;
  if (select count(*) from public.stock_adjustment_events) <> events_before then
    raise exception 'rejected compensation deleted or added audit history';
  end if;
  if (select count(*) from public.stock_ledger) <> ledger_before then
    raise exception 'rejected compensation posted ledger rows';
  end if;
  if (select quantity from public.stock_transactions where id = posted_transaction) is distinct from posted_quantity then
    raise exception 'rejected compensation modified the original posting';
  end if;
  if (select status from public.stock_adjustment_requests where id = (select id from refs where name = 'request')) <> 'posted' then
    raise exception 'rejected compensation changed the original request';
  end if;
end;
$$;

rollback;
