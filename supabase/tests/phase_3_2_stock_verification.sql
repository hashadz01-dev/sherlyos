-- Local disposable checks for Phase 3.2. The transaction rolls back.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

create temp table refs (
  name text primary key,
  id uuid not null
);

create temp table marks (
  name text primary key,
  amount bigint not null
);

grant select on fixture to authenticated;
grant select, insert, update, delete on refs to authenticated;
grant select, insert, update, delete on marks to authenticated;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('godown_b', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('keeper_b', gen_random_uuid()),
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
  fixture.name || '.phase32@example.com',
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
  when 'godown_b' then 'godown_manager'
  when 'accounts' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'delivery' then 'delivery_person'
  when 'keeper' then 'store_keeper'
  when 'keeper_b' then 'store_keeper'
  when 'inactive' then 'store_keeper'
end
where fixture.name <> 'admin';

update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');

create or replace function public.phase32_claim(actor text)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (
      select json_build_object('sub', id, 'role', 'authenticated')::text
      from fixture
      where name = actor
    ),
    true
  );
end;
$$;

create or replace function public.phase32_balance(target_crate uuid, target_product uuid)
returns integer
language sql
security definer
set search_path = ''
as $$
  select coalesce((
    select quantity
    from public.stock_balances
    where crate_id = target_crate
      and product_id = target_product
  ), 0);
$$;

create or replace function public.phase32_ledger_count()
returns bigint
language sql
security definer
set search_path = ''
as $$
  select count(*) from public.stock_ledger;
$$;

create or replace function public.phase32_line(target uuid, crate_code text, sku text)
returns jsonb
language sql
as $$
  select item
  from jsonb_array_elements(public.get_stock_verification(target) -> 'lines') item
  where item ->> 'crate_code' = crate_code
    and item ->> 'sku' = sku;
$$;

create or replace function public.phase32_ids(target uuid, crate_code text, sku text)
returns uuid[]
language sql
as $$
  select coalesce(array_agg(value::uuid), '{}'::uuid[])
  from jsonb_array_elements_text(
    coalesce(public.phase32_line(target, crate_code, sku) -> 'movement_ids', '[]'::jsonb)
  ) value;
$$;

create or replace function public.phase32_attach_photo(target uuid)
returns void
language plpgsql
as $$
declare
  created jsonb;
  payload bytea := decode('ffd8ffd9', 'hex');
begin
  created := public.create_verification_photo_upload(target, 'count sheet', null);
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-verification-evidence',
    created ->> 'path',
    auth.uid(),
    auth.uid()::text,
    jsonb_build_object(
      'size', octet_length(payload),
      'mimetype', 'image/jpeg',
      'eTag', encode(extensions.digest(payload, 'md5'), 'hex')
    )
  );
  perform public.finalize_verification_photo_upload((created ->> 'id')::uuid, encode(payload, 'base64'));
end;
$$;

create or replace function public.phase32_force_closed_change(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.stock_verifications
  set status = 'counting'
  where id = target;
end;
$$;

create or replace function public.phase32_force_evidence_delete(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.stock_verification_evidence
  where verification_id = target;
end;
$$;

select public.phase32_claim('admin');
set local role authenticated;

insert into refs (name, id)
values
  ('branch_a', public.create_branch('phase32_a', 'Phase 32 A')),
  ('branch_b', public.create_branch('phase32_b', 'Phase 32 B'));

insert into refs (name, id)
values
  ('zone_a', public.create_zone((select id from refs where name = 'branch_a'), 'za', 'Zone A', null)),
  ('zone_b', public.create_zone((select id from refs where name = 'branch_b'), 'zb', 'Zone B', null));

insert into refs (name, id)
values
  ('crate_a1', public.create_crate((select id from refs where name = 'zone_a'), 'ca1', 'Crate A1', null)),
  ('crate_a2', public.create_crate((select id from refs where name = 'zone_a'), 'ca2', 'Crate A2', null)),
  ('crate_empty', public.create_crate((select id from refs where name = 'zone_a'), 'cempty', 'Crate Empty', null)),
  ('crate_b1', public.create_crate((select id from refs where name = 'zone_b'), 'cb1', 'Crate B1', null)),
  ('soap', public.create_product('p32-soap', 'Phase 32 Soap', null, null)),
  ('oil', public.create_product('p32-oil', 'Phase 32 Oil', null, null)),
  ('extra', public.create_product('p32-extra', 'Phase 32 Extra', null, null)),
  ('supplier', public.create_supplier('Phase 32 Supplier', null, null));

select public.assign_user_branch((select id from fixture where name = 'godown'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'godown_b'), (select id from refs where name = 'branch_b'));
select public.assign_user_branch((select id from fixture where name = 'accounts'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'keeper'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'keeper_b'), (select id from refs where name = 'branch_b'));
select public.assign_user_branch((select id from fixture where name = 'inactive'), (select id from refs where name = 'branch_a'));

select public.post_opening_stock((select id from refs where name = 'soap'), (select id from refs where name = 'crate_a1'), 5, 'p32-open-soap', null);
select public.post_opening_stock((select id from refs where name = 'extra'), (select id from refs where name = 'crate_a2'), 2, 'p32-open-extra', null);

insert into marks (name, amount)
values ('ledger_before', public.phase32_ledger_count());

do $$
begin
  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'stock.verify'
      and roles.code <> 'godown_manager'
  ) or exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'stock.count_assist'
      and roles.code <> 'store_keeper'
  ) then
    raise exception 'verification grants changed';
  end if;
end;
$$;

select public.phase32_claim('godown');

insert into refs (name, id)
values (
  'main',
  public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[
      (select id from refs where name = 'crate_a1'),
      (select id from refs where name = 'crate_empty')
    ]
  )
);

do $$
declare
  line jsonb;
begin
  line := public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap');
  if (line ->> 'expected_cases')::integer <> 5 then
    raise exception 'snapshot did not capture the positive balance';
  end if;
  if line ->> 'counted_cases' is not null then
    raise exception 'an uncounted line was treated as zero';
  end if;
  if public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-oil') is not null then
    raise exception 'a zero balance was included in the snapshot';
  end if;
  if (select status from public.stock_verifications where id = (select id from refs where name = 'main')) <> 'counting' then
    raise exception 'verification did not start in counting';
  end if;
end;
$$;

do $$
begin
  perform public.submit_stock_verification((select id from refs where name = 'main'));
  raise exception 'a missing count was submitted';
exception
  when check_violation then
    if sqlerrm <> 'count is missing' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.start_stock_verification(
    (select id from refs where name = 'branch_b'),
    current_date,
    array[(select id from refs where name = 'zone_b')],
    array[(select id from refs where name = 'crate_b1')]
  );
  raise exception 'another godown was accepted';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[(select id from refs where name = 'crate_a2')]
  );
  raise exception 'a second open verification was accepted';
exception
  when unique_violation then
    if sqlerrm <> 'an open verification already exists for this godown' then
      raise;
    end if;
end;
$$;

select public.phase32_claim('keeper');

do $$
begin
  perform public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[(select id from refs where name = 'crate_a1')]
  );
  raise exception 'store keeper started a verification';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.save_verification_count(
    (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid,
    '-1'::jsonb,
    1
  );
  raise exception 'negative count was accepted';
exception
  when check_violation then
    if sqlerrm <> 'quantity must be a whole number of carton cases' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.save_verification_count(
    (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid,
    '1.5'::jsonb,
    1
  );
  raise exception 'decimal count was accepted';
exception
  when check_violation then
    if sqlerrm <> 'quantity must be a whole number of carton cases' then
      raise;
    end if;
end;
$$;

select public.save_verification_count(
  (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  '0'::jsonb,
  1
);

do $$
declare
  line jsonb;
begin
  line := public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap');
  if (line ->> 'counted_cases')::integer <> 0 or (line ->> 'expected_cases')::integer <> 5 then
    raise exception 'counted zero was not kept separately from expected stock';
  end if;
  if public.phase32_ledger_count() <> (select amount from marks where name = 'ledger_before') then
    raise exception 'a count created a ledger entry';
  end if;
  if public.phase32_balance((select id from refs where name = 'crate_a1'), (select id from refs where name = 'soap')) <> 5 then
    raise exception 'a count changed a balance';
  end if;
end;
$$;

do $$
begin
  perform public.submit_stock_verification((select id from refs where name = 'main'));
  raise exception 'store keeper submitted a verification';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.report_stock_discrepancy(
    (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid,
    'keeper report'
  );
  raise exception 'store keeper reported a discrepancy';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.close_stock_verification((select id from refs where name = 'main'), 'matched', 'keeper close');
  raise exception 'store keeper closed a verification';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('godown');

insert into refs (name, id)
values (
  'oil_line',
  public.add_verification_found_product(
    (select id from refs where name = 'main'),
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'oil')
  )
);

do $$
declare
  line jsonb;
begin
  line := public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-oil');
  if (line ->> 'expected_cases')::integer <> 0 then
    raise exception 'a discovered product did not start at zero expected cases';
  end if;
end;
$$;

do $$
begin
  perform public.add_verification_found_product(
    (select id from refs where name = 'main'),
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'oil')
  );
  raise exception 'duplicate crate and product line was accepted';
exception
  when unique_violation then
    if sqlerrm <> 'verification line already exists' then
      raise;
    end if;
end;
$$;

select public.phase32_claim('keeper');
select public.save_verification_count((select id from refs where name = 'oil_line'), '0'::jsonb, 1);

select public.phase32_claim('godown');

select public.submit_stock_verification((select id from refs where name = 'main'));

do $$
begin
  perform public.close_stock_verification((select id from refs where name = 'main'), 'variance_recorded', 'short soap');
  raise exception 'closure without a recount was accepted';
exception
  when check_violation then
    if sqlerrm <> 'recount is required' then
      raise;
    end if;
end;
$$;

select public.report_stock_discrepancy(
  (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  'soap was short on the first count'
);
select public.request_verification_recount(
  (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid
);

select public.phase32_claim('keeper');
select public.save_verification_recount(
  (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  '4'::jsonb,
  (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'line_version')::integer
);

do $$
declare
  line jsonb;
  initial_count integer;
  recount_count integer;
begin
  line := public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap');
  if (line ->> 'counted_cases')::integer <> 0 or (line ->> 'recount_cases')::integer <> 4 then
    raise exception 'recount replaced the first count';
  end if;
  select count(*) filter (where count_kind = 'initial'), count(*) filter (where count_kind = 'recount')
  into initial_count, recount_count
  from public.stock_verification_counts
  where line_id = (line ->> 'id')::uuid;
  if initial_count <> 1 or recount_count <> 1 then
    raise exception 'count history was not preserved';
  end if;
  if public.phase32_balance((select id from refs where name = 'crate_a1'), (select id from refs where name = 'soap')) <> 5 then
    raise exception 'a recount changed a balance';
  end if;
end;
$$;

select public.phase32_claim('godown');
select public.review_verification_discrepancy(
  (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  'four cases after recount',
  public.phase32_ids((select id from refs where name = 'main'), 'ca1', 'p32-soap')
);

do $$
declare
  line jsonb;
begin
  line := public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-soap');
  if line ->> 'reviewed_by' <> (select id::text from fixture where name = 'godown')
    or line ->> 'discrepancy_reason' <> 'four cases after recount'
    or line ->> 'reviewed_at' is null
  then
    raise exception 'manager review did not record the actor and reason';
  end if;
end;
$$;

do $$
begin
  perform public.close_stock_verification((select id from refs where name = 'main'), 'variance_recorded', 'short soap remains');
  raise exception 'closure without photo evidence was accepted';
exception
  when check_violation then
    if sqlerrm <> 'photo evidence is required' then
      raise;
    end if;
end;
$$;

select public.phase32_claim('accounts');

do $$
begin
  perform public.create_verification_photo_upload((select id from refs where name = 'main'), null, null);
  raise exception 'accounts attached a photo';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.get_stock_verification((select id from refs where name = 'main'));
  raise exception 'accounts read a verification';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('salesperson');

do $$
begin
  perform public.list_stock_verifications();
  raise exception 'salesperson listed verifications';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('delivery');

do $$
begin
  perform public.get_stock_verification((select id from refs where name = 'main'));
  raise exception 'delivery person read a verification';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('inactive');

do $$
begin
  perform public.list_stock_verifications();
  raise exception 'inactive user listed verifications';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('keeper_b');

do $$
begin
  perform public.save_verification_count(
    (public.phase32_line((select id from refs where name = 'main'), 'ca1', 'p32-oil') ->> 'id')::uuid,
    '1'::jsonb,
    2
  );
  raise exception 'cross-godown count was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
declare
  visible integer;
begin
  select count(*)
  into visible
  from public.stock_verifications
  where id = (select id from refs where name = 'main');
  if visible <> 0 then
    raise exception 'another godown could read the verification';
  end if;
end;
$$;

do $$
begin
  perform public.get_stock_verification(gen_random_uuid());
  raise exception 'a guessed verification id was visible';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('godown');
select public.phase32_attach_photo((select id from refs where name = 'main'));

select public.phase32_claim('keeper_b');

do $$
declare
  evidence_id uuid;
begin
  select id
  into evidence_id
  from public.stock_verification_evidence
  where verification_id = (select id from refs where name = 'main')
    and verified_at is not null;
  if evidence_id is not null then
    raise exception 'cross-godown evidence was visible';
  end if;
  perform public.get_verification_photo_url(coalesce(evidence_id, gen_random_uuid()));
  raise exception 'cross-godown photo access was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('admin');

do $$
declare
  visible integer;
  evidence_id uuid;
begin
  select count(*)
  into visible
  from jsonb_array_elements(public.list_stock_verifications() -> 'verifications') item
  where item ->> 'id' = (select id::text from refs where name = 'main');
  if visible <> 1 then
    raise exception 'admin could not monitor the verification';
  end if;

  select id
  into evidence_id
  from public.stock_verification_evidence
  where verification_id = (select id from refs where name = 'main')
    and verified_at is not null;

  if public.get_verification_photo_url(evidence_id) ->> 'bucket' <> 'stock-verification-evidence' then
    raise exception 'admin could not receive an authorized photo reference';
  end if;
end;
$$;

do $$
begin
  perform public.save_verification_count(
    (select id from refs where name = 'oil_line'),
    '1'::jsonb,
    2
  );
  raise exception 'admin changed a count';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.close_stock_verification((select id from refs where name = 'main'), 'variance_recorded', 'admin close');
  raise exception 'admin closed a verification';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  insert into public.stock_verifications (
    verification_number, godown_id, business_date, status, snapshot_at,
    snapshot_ledger_boundary, started_by, started_at
  )
  values (
    'DV-DIRECT',
    (select id from refs where name = 'branch_a'),
    current_date,
    'counting',
    now(),
    'ledger-id-set',
    (select id from fixture where name = 'admin'),
    now()
  );
  raise exception 'direct verification insert was allowed';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase32_claim('godown');

do $$
begin
  perform public.close_stock_verification((select id from refs where name = 'main'), 'matched', 'this should not match');
  raise exception 'matched closure hid a variance';
exception
  when check_violation then
    if sqlerrm <> 'closure result does not match the verification' then
      raise;
    end if;
end;
$$;

select public.close_stock_verification(
  (select id from refs where name = 'main'),
  'correction_requested',
  'soap remains short after recount'
);

do $$
declare
  header public.stock_verifications;
  line jsonb;
begin
  select *
  into header
  from public.stock_verifications
  where id = (select id from refs where name = 'main');

  if header.status <> 'closed'
    or header.closure_result <> 'correction_requested'
    or header.correction_request_status <> 'requested'
    or header.closed_by <> (select id from fixture where name = 'godown')
  then
    raise exception 'closure did not preserve the correction request';
  end if;

  line := public.phase32_line(header.id, 'ca1', 'p32-soap');
  if (line ->> 'expected_cases')::integer <> 5
    or (line ->> 'counted_cases')::integer <> 0
    or (line ->> 'recount_cases')::integer <> 4
    or (line ->> 'final_variance_cases')::integer <> -1
  then
    raise exception 'closure did not preserve the physical variance';
  end if;

  if public.phase32_ledger_count() <> (select amount from marks where name = 'ledger_before') then
    raise exception 'closing a verification changed the ledger';
  end if;
  if public.phase32_balance((select id from refs where name = 'crate_a1'), (select id from refs where name = 'soap')) <> 5 then
    raise exception 'closing a verification changed a balance';
  end if;
end;
$$;

do $$
begin
  perform public.save_verification_count((select id from refs where name = 'oil_line'), '1'::jsonb, 3);
  raise exception 'a closed verification accepted a count';
exception
  when insufficient_privilege then
    if sqlerrm <> 'closed verification cannot be changed' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.phase32_force_closed_change((select id from refs where name = 'main'));
  raise exception 'a closed verification was reopened';
exception
  when insufficient_privilege then
    if sqlerrm <> 'closed verification cannot be changed' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.phase32_force_evidence_delete((select id from refs where name = 'main'));
  raise exception 'closed photo evidence was deleted';
exception
  when insufficient_privilege then
    if sqlerrm <> 'verification evidence cannot be deleted' then
      raise;
    end if;
end;
$$;

select public.phase32_claim('admin');

do $$
begin
  if (
    select count(distinct action)
    from public.audit_logs
    where metadata ->> 'verification_id' = (select id::text from refs where name = 'main')
      and action in (
        'start_stock_verification',
        'close_stock_verification',
        'verification_photo_attached',
        'review_verification_discrepancy'
      )
  ) <> 4 then
    raise exception 'verification audit history is missing';
  end if;
end;
$$;

select public.phase32_claim('godown');

insert into refs (name, id)
values (
  'second',
  public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[(select id from refs where name = 'crate_a1')]
  )
);

do $$
declare
  closed_count integer;
begin
  select count(*)
  into closed_count
  from public.stock_verifications
  where godown_id = (select id from refs where name = 'branch_a')
    and status = 'closed';
  if closed_count <> 1 then
    raise exception 'a closed verification was not retained';
  end if;
  if (
    select count(*)
    from public.stock_verifications
    where godown_id = (select id from refs where name = 'branch_a')
      and status <> 'closed'
  ) <> 1 then
    raise exception 'the godown did not keep exactly one open verification';
  end if;
end;
$$;

select public.phase32_claim('keeper');
select public.save_verification_count(
  (public.phase32_line((select id from refs where name = 'second'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  '5'::jsonb,
  1
);

select public.phase32_claim('godown');
select public.post_crate_transfer(
  (select id from refs where name = 'soap'),
  (select id from refs where name = 'crate_a1'),
  (select id from refs where name = 'crate_a2'),
  1,
  'p32-out-one',
  null
);
select public.post_crate_transfer(
  (select id from refs where name = 'soap'),
  (select id from refs where name = 'crate_a2'),
  (select id from refs where name = 'crate_a1'),
  1,
  'p32-back-one',
  null
);

do $$
declare
  line jsonb;
begin
  line := public.phase32_line((select id from refs where name = 'second'), 'ca1', 'p32-soap');
  if (line ->> 'expected_cases')::integer <> 5 then
    raise exception 'a later transfer changed the frozen expected quantity';
  end if;
  if (line ->> 'ledger_movement_cases')::integer <> 0 then
    raise exception 'opposing movements were collapsed to a net balance';
  end if;
  if jsonb_array_length(line -> 'movement_ids') <> 2 then
    raise exception 'opposing movements were not both detected';
  end if;
  if public.phase32_balance((select id from refs where name = 'crate_a1'), (select id from refs where name = 'soap')) <> 5 then
    raise exception 'opposing transfers did not preserve the balance';
  end if;
end;
$$;

select public.submit_stock_verification((select id from refs where name = 'second'));

select public.phase32_attach_photo((select id from refs where name = 'second'));

do $$
begin
  perform public.close_stock_verification((select id from refs where name = 'second'), 'matched', 'ignored movement');
  raise exception 'closure ignored movement after the snapshot';
exception
  when check_violation then
    if sqlerrm <> 'movement must be reconciled' then
      raise;
    end if;
end;
$$;

select public.review_verification_discrepancy(
  (public.phase32_line((select id from refs where name = 'second'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  null,
  public.phase32_ids((select id from refs where name = 'second'), 'ca1', 'p32-soap')
);
select public.close_stock_verification(
  (select id from refs where name = 'second'),
  'matched',
  'opposing movements reconciled'
);

insert into refs (name, id)
values (
  'inactive_check',
  public.start_stock_verification(
    (select id from refs where name = 'branch_a'),
    current_date,
    array[(select id from refs where name = 'zone_a')],
    array[
      (select id from refs where name = 'crate_a1'),
      (select id from refs where name = 'crate_empty')
    ]
  )
);

select public.phase32_claim('keeper');
select public.save_verification_count(
  (public.phase32_line((select id from refs where name = 'inactive_check'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  '5'::jsonb,
  1
);

select public.phase32_claim('admin');
select public.set_crate_active((select id from refs where name = 'crate_empty'), false);
select public.set_product_active((select id from refs where name = 'soap'), false);

select public.phase32_claim('godown');
select public.submit_stock_verification((select id from refs where name = 'inactive_check'));
select public.phase32_attach_photo((select id from refs where name = 'inactive_check'));

do $$
begin
  perform public.close_stock_verification(
    (select id from refs where name = 'inactive_check'),
    'matched',
    'inactive objects'
  );
  raise exception 'an inactive crate or product closed without review';
exception
  when check_violation then
    if sqlerrm <> 'inactive object must be reviewed' then
      raise;
    end if;
end;
$$;

select public.review_verification_inactive_object(
  'scope',
  (
    select id
    from public.stock_verification_scopes
    where verification_id = (select id from refs where name = 'inactive_check')
      and crate_id = (select id from refs where name = 'crate_empty')
  ),
  'empty crate was deactivated during the count'
);
select public.review_verification_inactive_object(
  'line',
  (public.phase32_line((select id from refs where name = 'inactive_check'), 'ca1', 'p32-soap') ->> 'id')::uuid,
  'soap was deactivated during the count'
);

do $$
declare
  scope_reason text;
  line_reason text;
begin
  select inactive_review_reason
  into scope_reason
  from public.stock_verification_scopes
  where verification_id = (select id from refs where name = 'inactive_check')
    and crate_id = (select id from refs where name = 'crate_empty');
  line_reason := public.phase32_line((select id from refs where name = 'inactive_check'), 'ca1', 'p32-soap') ->> 'inactive_review_reason';
  if scope_reason is null or line_reason is null then
    raise exception 'inactive review did not record a reason';
  end if;
end;
$$;

select public.close_stock_verification(
  (select id from refs where name = 'inactive_check'),
  'matched',
  'inactive objects were reviewed'
);

select public.phase32_claim('admin');
select public.set_product_active((select id from refs where name = 'soap'), true);
select public.set_crate_active((select id from refs where name = 'crate_empty'), true);
select public.post_opening_stock((select id from refs where name = 'oil'), (select id from refs where name = 'crate_a2'), 3, 'p32-open-oil', null);

select public.phase32_claim('keeper');

insert into refs (name, id)
select 'receipt', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier'),
  'P32-INV-1',
  current_date,
  null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from refs where name = 'extra'),
    'destination_crate_id', (select id from refs where name = 'crate_a2'),
    'document_cases', 2,
    'counted_cases', 2,
    'damaged_cases', 0
  ))
) ->> 'id')::uuid;

select public.submit_stock_receipt((select id from refs where name = 'receipt'));
select public.phase32_claim('godown');
select public.verify_stock_receipt((select id from refs where name = 'receipt'), 'p32-verify-extra');

do $$
begin
  if public.phase32_balance((select id from refs where name = 'crate_a2'), (select id from refs where name = 'extra')) <> 4 then
    raise exception 'receipt posting no longer adds accepted cases';
  end if;
  if public.phase32_balance((select id from refs where name = 'crate_a2'), (select id from refs where name = 'oil')) <> 3 then
    raise exception 'opening stock no longer posts';
  end if;
  if (
    select coalesce(sum(quantity), 0)
    from public.stock_balances
  ) <> (
    select coalesce(sum(quantity), 0)
    from public.stock_ledger
  ) then
    raise exception 'ledger and balances no longer reconcile';
  end if;
  perform public.phase32_claim('admin');
  if (
    select count(*)
    from jsonb_array_elements(public.list_stock_verifications() -> 'indicators') item
    where item ->> 'godown_id' = (select id::text from refs where name = 'branch_b')
      and (item ->> 'missing_today')::boolean
  ) <> 1 then
    raise exception 'missing verification day was not reported';
  end if;
end;
$$;

select public.phase32_claim('keeper');

do $$
declare
  visible integer;
begin
  select count(*)
  into visible
  from jsonb_array_elements(public.list_stock_verifications() -> 'verifications') item
  where item ->> 'id' = (select id::text from refs where name = 'main');
  if visible <> 1 then
    raise exception 'store keeper could not view verification history';
  end if;
end;
$$;

rollback;
