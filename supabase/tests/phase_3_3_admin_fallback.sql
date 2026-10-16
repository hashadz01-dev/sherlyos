-- Local Phase 3.3 admin-fallback checks. The transaction rolls back.

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
  fixture.name || '.phase33fallback@example.com',
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
  when 'keeper' then 'store_keeper'
  when 'inactive' then 'godown_manager'
end
where fixture.name <> 'admin';

update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');

do $$
begin
  if not exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'admin'
      and permissions.code = 'stock.adjustment.approve_exceptional'
  ) then
    raise exception 'admin is missing exceptional approval';
  end if;

  if exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'admin'
      and permissions.code in ('stock.adjustment.request', 'stock.adjustment.post')
  ) then
    raise exception 'admin can create or post adjustments';
  end if;

  if exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code = 'stock.adjustment.approve_exceptional'
  ) then
    raise exception 'godown manager can approve exceptional adjustments';
  end if;

  if (
    select count(*)
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code in ('stock.adjustment.request', 'stock.adjustment.post')
  ) <> 2 then
    raise exception 'godown manager is missing request or post';
  end if;

  if exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'store_keeper'
      and permissions.code like 'stock.adjustment.%'
  ) then
    raise exception 'store keeper has an adjustment permission';
  end if;
end;
$$;

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
values ('branch_a', public.create_branch('phase33_fallback_a', 'Fallback A')),
       ('branch_b', public.create_branch('phase33_fallback_b', 'Fallback B'));

insert into refs (name, id)
values
  ('zone_a', public.create_zone((select id from refs where name = 'branch_a'), 'fza', 'Fallback Zone A', null)),
  ('zone_b', public.create_zone((select id from refs where name = 'branch_b'), 'fzb', 'Fallback Zone B', null));

insert into refs (name, id)
values
  ('crate_a', public.create_crate((select id from refs where name = 'zone_a'), 'fca', 'Fallback Crate A', null)),
  ('crate_b', public.create_crate((select id from refs where name = 'zone_b'), 'fcb', 'Fallback Crate B', null)),
  ('soap', public.create_product('p33-fallback-soap', 'Fallback Soap', null, null)),
  ('oil', public.create_product('p33-fallback-oil', 'Fallback Oil', null, null));

select public.assign_user_branch((select id from fixture where name = 'godown'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'inactive'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'godown_b'), (select id from refs where name = 'branch_b'));

select public.post_opening_stock((select id from refs where name = 'soap'), (select id from refs where name = 'crate_a'), 5, 'p33-fallback-open-soap', null);
select public.post_opening_stock((select id from refs where name = 'oil'), (select id from refs where name = 'crate_a'), 12, 'p33-fallback-open-oil', null);

insert into refs (name, id)
values ('verification', public.phase33_close_short('p33-fallback-soap', 4, 'soap short one'));

select public.phase33_claim('godown');

insert into refs (name, id)
select 'request', (public.create_stock_adjustment(
  (select id from refs where name = 'verification'),
  'shortage',
  'ordinary fallback request',
  array[public.phase33_line((select id from refs where name = 'verification'), 'p33-fallback-soap')],
  'p33-fallback-create',
  null
) ->> 'id')::uuid;

select public.submit_stock_adjustment((select id from refs where name = 'request'), 1);

do $$
begin
  if (select exceptional from public.stock_adjustment_requests where id = (select id from refs where name = 'request')) is not false then
    raise exception 'one case was classified as exceptional';
  end if;
  if (select status from public.stock_adjustment_requests where id = (select id from refs where name = 'request')) <> 'submitted' then
    raise exception 'ordinary request was not submitted';
  end if;
end;
$$;

do $$
begin
  perform public.phase33_claim('godown');
  perform public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'self approval');
  raise exception 'requester approved the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'you cannot approve your own adjustment' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.phase33_claim('inactive');
  perform public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'inactive approval');
  raise exception 'inactive manager approved the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.phase33_claim('godown_b');
  perform public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'other godown approval');
  raise exception 'wrong-godown manager approved the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

select public.phase33_claim('admin');
select public.approve_stock_adjustment((select id from refs where name = 'request'), 2, 'admin fallback approval');

do $$
begin
  if (select status from public.stock_adjustment_requests where id = (select id from refs where name = 'request')) <> 'approved' then
    raise exception 'admin fallback did not approve';
  end if;
  if (select approved_by from public.stock_adjustment_requests where id = (select id from refs where name = 'request'))
    is distinct from (select id from fixture where name = 'admin') then
    raise exception 'admin was not recorded as approver';
  end if;
end;
$$;

do $$
begin
  perform public.phase33_claim('admin');
  perform public.post_stock_adjustment((select id from refs where name = 'request'), 3, 'p33-fallback-admin-post');
  raise exception 'admin posted the adjustment';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

select public.phase33_claim('godown');
select public.post_stock_adjustment((select id from refs where name = 'request'), 3, 'p33-fallback-post');

do $$
begin
  if (select status from public.stock_adjustment_requests where id = (select id from refs where name = 'request')) <> 'posted' then
    raise exception 'godown manager did not post';
  end if;
  if (select quantity from public.stock_balances
      where crate_id = (select id from refs where name = 'crate_a')
        and product_id = (select id from refs where name = 'soap')) <> 4 then
    raise exception 'posted soap balance was not 4';
  end if;
  if (select count(*) from public.stock_transactions where adjustment_request_id = (select id from refs where name = 'request')) <> 1 then
    raise exception 'posting was not unique';
  end if;
end;
$$;

select public.phase33_claim('admin');
select public.assign_user_branch((select id from fixture where name = 'godown2'), (select id from refs where name = 'branch_a'));

insert into refs (name, id)
values ('verification_oil', public.phase33_close_short('p33-fallback-oil', 11, 'oil short one'));

select public.phase33_claim('godown');

insert into refs (name, id)
select 'request_oil', (public.create_stock_adjustment(
  (select id from refs where name = 'verification_oil'),
  'shortage',
  'ordinary with a second manager',
  array[public.phase33_line((select id from refs where name = 'verification_oil'), 'p33-fallback-oil')],
  'p33-fallback-oil',
  null
) ->> 'id')::uuid;

select public.submit_stock_adjustment((select id from refs where name = 'request_oil'), 1);

do $$
begin
  perform public.phase33_claim('admin');
  perform public.approve_stock_adjustment((select id from refs where name = 'request_oil'), 2, 'admin override');
  raise exception 'admin approved while another manager exists';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.phase33_claim('inactive');
  perform public.approve_stock_adjustment((select id from refs where name = 'request_oil'), 2, 'inactive still present');
  raise exception 'inactive manager counted as an approver';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.phase33_claim('godown_b');
  perform public.approve_stock_adjustment((select id from refs where name = 'request_oil'), 2, 'wrong godown still present');
  raise exception 'wrong-godown manager counted as an approver';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

select public.phase33_claim('godown2');
select public.approve_stock_adjustment((select id from refs where name = 'request_oil'), 2, 'second manager approval');

do $$
begin
  perform public.phase33_claim('godown');
  perform public.create_stock_adjustment(
    (select id from refs where name = 'verification'),
    'shortage',
    'compensation is closed',
    array[public.phase33_line((select id from refs where name = 'verification'), 'p33-fallback-soap')],
    'p33-fallback-closed-comp',
    (select id from refs where name = 'request')
  );
  raise exception 'compensation reference was accepted';
exception
  when check_violation then
    if sqlerrm <> 'compensation is not available' then
      raise;
    end if;
end;
$$;

do $$
begin
  if exists (
    select 1 from pg_proc
    join pg_namespace on pg_namespace.oid = pg_proc.pronamespace
    where pg_namespace.nspname = 'public'
      and pg_proc.proname ilike '%revers%'
  ) then
    raise exception 'a reversal function is exposed';
  end if;
end;
$$;

rollback;
