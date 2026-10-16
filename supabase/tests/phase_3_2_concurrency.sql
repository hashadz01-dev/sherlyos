-- Disposable fixture for overlapping verification sessions.
-- The runner is supabase/tests/phase_3_2_concurrency.mjs.

create or replace function public.phase32_claim(actor_email text)
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
  gen_random_uuid(),
  'authenticated',
  'authenticated',
  address.email,
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', address.full_name),
  now(),
  now()
from (
  values
    ('admin.phase32race@example.com', 'Phase 32 Race Admin'),
    ('manager.phase32race@example.com', 'Phase 32 Race Manager'),
    ('manager2.phase32race@example.com', 'Phase 32 Race Manager 2'),
    ('keeper.phase32race@example.com', 'Phase 32 Race Keeper')
) as address (email, full_name);

select app_private.bootstrap_initial_admin(
  (select id from auth.users where email = 'admin.phase32race@example.com'),
  'create-initial-administrator'
);

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'manager.phase32race@example.com' then 'godown_manager'
  when 'manager2.phase32race@example.com' then 'godown_manager'
  else 'store_keeper'
end
where users.email in (
  'manager.phase32race@example.com',
  'manager2.phase32race@example.com',
  'keeper.phase32race@example.com'
);

select public.phase32_claim('admin.phase32race@example.com');
select public.create_branch('phase32_race', 'Phase 32 Race');
select public.create_zone(
  (select id from public.branches where code = 'phase32_race'),
  'rz', 'Race Zone', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race')),
  'rca', 'Race Crate A', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race')),
  'rcb', 'Race Crate B', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race')),
  'rempty', 'Race Empty', null
);
select public.create_product('p32-race-soap', 'Phase 32 Race Soap', null, null);
select public.create_product('p32-race-other', 'Phase 32 Race Other', null, null);
select public.create_supplier('Phase 32 Race Supplier', null, null);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager.phase32race@example.com'),
  (select id from public.branches where code = 'phase32_race')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager2.phase32race@example.com'),
  (select id from public.branches where code = 'phase32_race')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'keeper.phase32race@example.com'),
  (select id from public.branches where code = 'phase32_race')
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p32-race-soap'),
  (select id from public.crates where code = 'rca'),
  8,
  'p32-race-open-soap',
  null
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p32-race-soap'),
  (select id from public.crates where code = 'rcb'),
  4,
  'p32-race-open-soap-b',
  null
);

create or replace function public.phase32_clear_open()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  race_branch uuid;
begin
  select id into race_branch from public.branches where code = 'phase32_race';
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects
  where bucket_id = 'stock-verification-evidence'
    and name in (
      select storage_path
      from public.stock_verification_evidence
      where verification_id in (
        select id from public.stock_verifications where godown_id = race_branch
      )
    );

  alter table public.stock_verification_evidence disable trigger stock_verification_evidence_guard;
  alter table public.stock_verification_counts disable trigger stock_verification_counts_guard;
  alter table public.stock_verification_lines disable trigger stock_verification_lines_guard;
  alter table public.stock_verification_snapshot_entries disable trigger stock_verification_snapshot_guard;
  alter table public.stock_verification_scopes disable trigger stock_verification_scopes_guard;
  alter table public.stock_verifications disable trigger stock_verifications_guard;

  delete from public.stock_verification_evidence
  where verification_id in (select id from public.stock_verifications where godown_id = race_branch);
  delete from public.stock_verification_counts
  where verification_id in (select id from public.stock_verifications where godown_id = race_branch);
  delete from public.stock_verification_lines
  where verification_id in (select id from public.stock_verifications where godown_id = race_branch);
  delete from public.stock_verification_snapshot_entries
  where verification_id in (select id from public.stock_verifications where godown_id = race_branch);
  delete from public.stock_verification_scopes
  where verification_id in (select id from public.stock_verifications where godown_id = race_branch);
  delete from public.stock_verifications where godown_id = race_branch;

  alter table public.stock_verification_evidence enable trigger stock_verification_evidence_guard;
  alter table public.stock_verification_counts enable trigger stock_verification_counts_guard;
  alter table public.stock_verification_lines enable trigger stock_verification_lines_guard;
  alter table public.stock_verification_snapshot_entries enable trigger stock_verification_snapshot_guard;
  alter table public.stock_verification_scopes enable trigger stock_verification_scopes_guard;
  alter table public.stock_verifications enable trigger stock_verifications_guard;
end;
$$;

create or replace function public.phase32_open_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id
  from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_race')
    and status <> 'closed'
  limit 1;
$$;

create or replace function public.phase32_attach_photo(target uuid)
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

create or replace function public.phase32_prepare_counted(submit_it boolean, include_empty boolean)
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
  crates uuid[];
begin
  perform public.phase32_clear_open();
  perform public.phase32_claim('manager.phase32race@example.com');
  if include_empty then
    crates := array[
      (select id from public.crates where code = 'rca'),
      (select id from public.crates where code = 'rempty')
    ];
  else
    crates := array[(select id from public.crates where code = 'rca')];
  end if;
  created := public.start_stock_verification(
    (select id from public.branches where code = 'phase32_race'),
    current_date,
    array[(select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race'))],
    crates
  );
  select id, line_version, expected_cases
  into line_id, version, expected
  from public.stock_verification_lines
  where verification_id = created
    and product_id = (select id from public.products where sku = 'p32-race-soap');
  perform public.save_verification_count(line_id, pg_catalog.to_jsonb(expected), version);
  perform public.phase32_attach_photo(created);
  if submit_it then
    perform public.submit_stock_verification(created);
  end if;
  return created;
end;
$$;

create or replace function public.phase32_prepare_receipt()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created jsonb;
begin
  perform public.phase32_claim('keeper.phase32race@example.com');
  created := public.create_stock_receipt(
    (select id from public.branches where code = 'phase32_race'),
    (select id from public.suppliers where name = 'Phase 32 Race Supplier'),
    'RACE-' || pg_catalog.left(pg_catalog.gen_random_uuid()::text, 8),
    current_date,
    null,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id', (select id from public.products where sku = 'p32-race-soap'),
      'destination_crate_id', (select id from public.crates where code = 'rca'),
      'document_cases', 2,
      'counted_cases', 2,
      'damaged_cases', 0
    ))
  );
  perform public.submit_stock_receipt((created ->> 'id')::uuid);
  return (created ->> 'id')::uuid;
end;
$$;

create or replace function public.phase32_stage_pending()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  created jsonb;
  payload bytea := pg_catalog.decode('ffd8ffd9', 'hex');
begin
  perform public.phase32_claim('manager.phase32race@example.com');
  created := public.create_verification_photo_upload(public.phase32_open_id(), 'pending', null);
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
end;
$$;

create or replace function public.phase32_hold_start()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase32_claim('manager.phase32race@example.com');
  perform public.start_stock_verification(
    (select id from public.branches where code = 'phase32_race'),
    current_date,
    array[(select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race'))],
    array[(select id from public.crates where code = 'rca')]
  );
  perform pg_catalog.pg_sleep(1.5);
end;
$$;

create or replace function public.phase32_hold_count()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  line_id uuid;
  version integer;
begin
  perform public.phase32_claim('keeper.phase32race@example.com');
  select id, line_version into line_id, version
  from public.stock_verification_lines
  where verification_id = public.phase32_open_id();
  perform public.save_verification_count(line_id, '3'::jsonb, version);
  perform pg_catalog.pg_sleep(1.5);
end;
$$;

create or replace function public.phase32_hold_close()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
begin
  perform public.phase32_claim('manager.phase32race@example.com');
  target := public.phase32_open_id();
  perform id from public.stock_verifications where id = target for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.close_stock_verification(target, 'matched', 'race close');
end;
$$;

create or replace function public.phase32_hold_locations()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase32_claim('manager.phase32race@example.com');
  perform app_private.prepare_stock_locations(array[
    (select id from public.crates where code = 'rca'),
    (select id from public.crates where code = 'rcb')
  ]);
  perform pg_catalog.pg_sleep(1.5);
end;
$$;

create or replace function public.phase32_hold_product()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase32_claim('admin.phase32race@example.com');
  perform id
  from public.stock_verifications
  where id = public.phase32_open_id()
  for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.set_product_active((select id from public.products where sku = 'p32-race-soap'), false);
end;
$$;

create or replace function public.phase32_hold_crate()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase32_claim('admin.phase32race@example.com');
  perform stock_verifications.id
  from public.stock_verifications
  where stock_verifications.id in (
    select stock_verification_scopes.verification_id
    from public.stock_verification_scopes
    where stock_verification_scopes.crate_id = (select id from public.crates where code = 'rempty')
  )
    and stock_verifications.status <> 'closed'
  order by stock_verifications.id
  for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.set_crate_active((select id from public.crates where code = 'rempty'), false);
end;
$$;

create or replace function public.phase32_prepare_open(include_empty boolean)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created uuid;
  crates uuid[];
begin
  perform public.phase32_clear_open();
  perform public.phase32_claim('manager.phase32race@example.com');
  if include_empty then
    crates := array[
      (select id from public.crates where code = 'rca'),
      (select id from public.crates where code = 'rempty')
    ];
  else
    crates := array[(select id from public.crates where code = 'rca')];
  end if;
  created := public.start_stock_verification(
    (select id from public.branches where code = 'phase32_race'),
    current_date,
    array[(select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race'))],
    crates
  );
  return created;
end;
$$;

create or replace function public.phase32_hold_recount()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  line_id uuid;
  version integer;
  expected integer;
begin
  perform public.phase32_claim('manager.phase32race@example.com');
  select id, line_version, expected_cases into line_id, version, expected
  from public.stock_verification_lines
  where verification_id = public.phase32_open_id();
  perform public.request_verification_recount(line_id);
  select line_version into version
  from public.stock_verification_lines
  where id = line_id;
  perform public.save_verification_recount(line_id, pg_catalog.to_jsonb(expected), version);
  perform pg_catalog.pg_sleep(1.5);
end;
$$;

create or replace function public.phase32_hold_transfer()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase32_claim('manager.phase32race@example.com');
  perform app_private.prepare_stock_locations(array[
    (select id from public.crates where code = 'rca'),
    (select id from public.crates where code = 'rcb')
  ]);
  perform pg_catalog.pg_sleep(1.5);
  perform public.post_crate_transfer(
    (select id from public.products where sku = 'p32-race-soap'),
    (select id from public.crates where code = 'rca'),
    (select id from public.crates where code = 'rcb'),
    1,
    'race-move-' || pg_catalog.left(pg_catalog.gen_random_uuid()::text, 8),
    null
  );
end;
$$;

create or replace function public.phase32_hold_product_row()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase32_claim('admin.phase32race@example.com');
  perform id from public.products where sku = 'p32-race-soap' for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.set_product_active((select id from public.products where sku = 'p32-race-soap'), false);
end;
$$;

create or replace function public.phase32_hold_close_locations()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
begin
  perform public.phase32_claim('manager.phase32race@example.com');
  target := public.phase32_open_id();
  perform id from public.stock_verifications where id = target for update;
  perform zones.id
  from public.zones
  where zones.id in (
    select zone_id from public.stock_verification_scopes where verification_id = target
  )
  order by zones.id
  for update;
  perform crates.id
  from public.crates
  where crates.id in (
    select crate_id from public.stock_verification_scopes where verification_id = target
  )
  order by crates.id
  for update;
  perform pg_catalog.pg_sleep(1.5);
  perform public.close_stock_verification(target, 'matched', 'locations close');
end;
$$;

create or replace function public.phase32_hold_receipt_locations()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  receipt_id uuid;
begin
  receipt_id := public.phase32_prepare_receipt();
  perform app_private.prepare_stock_locations(array[(select id from public.crates where code = 'rca')]);
  perform pg_catalog.pg_sleep(1.5);
  perform public.phase32_claim('manager.phase32race@example.com');
  perform public.verify_stock_receipt(
    receipt_id,
    'race-recv-' || pg_catalog.left(pg_catalog.gen_random_uuid()::text, 8)
  );
end;
$$;

create or replace function public.phase32_post_other()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  created jsonb;
begin
  perform public.phase32_claim('keeper.phase32race@example.com');
  created := public.create_stock_receipt(
    (select id from public.branches where code = 'phase32_race'),
    (select id from public.suppliers where name = 'Phase 32 Race Supplier'),
    'OTHER-' || pg_catalog.left(pg_catalog.gen_random_uuid()::text, 8),
    current_date,
    null,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id', (select id from public.products where sku = 'p32-race-other'),
      'destination_crate_id', (select id from public.crates where code = 'rca'),
      'document_cases', 1,
      'counted_cases', 1,
      'damaged_cases', 0
    ))
  );
  perform public.submit_stock_receipt((created ->> 'id')::uuid);
  perform public.phase32_claim('manager.phase32race@example.com');
  perform public.verify_stock_receipt(
    (created ->> 'id')::uuid,
    'race-other-' || pg_catalog.left(pg_catalog.gen_random_uuid()::text, 8)
  );
end;
$$;
