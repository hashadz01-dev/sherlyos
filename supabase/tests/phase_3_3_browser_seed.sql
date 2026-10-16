-- Disposable local browser users for Phase 3.3. Not for the hosted project.

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
    ('admin.phase33browser@example.com', 'Browser Admin'),
    ('manager.phase33browser@example.com', 'Browser Manager'),
    ('manager2.phase33browser@example.com', 'Browser Manager 2'),
    ('keeper.phase33browser@example.com', 'Browser Keeper'),
    ('accounts.phase33browser@example.com', 'Browser Accounts'),
    ('sales.phase33browser@example.com', 'Browser Sales'),
    ('delivery.phase33browser@example.com', 'Browser Delivery')
) as address (email, full_name);

update auth.users
set
  confirmation_token = coalesce(confirmation_token, ''),
  recovery_token = coalesce(recovery_token, ''),
  email_change = coalesce(email_change, ''),
  email_change_token_new = coalesce(email_change_token_new, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, ''),
  reauthentication_token = coalesce(reauthentication_token, '')
where email like '%.phase33browser@example.com';

insert into auth.identities (
  provider_id, user_id, identity_data, provider, created_at, updated_at
)
select
  users.id::text,
  users.id,
  jsonb_build_object('sub', users.id::text, 'email', users.email),
  'email',
  now(),
  now()
from auth.users as users
where users.email like '%.phase33browser@example.com';

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'admin.phase33browser@example.com' then 'admin'
  when 'manager.phase33browser@example.com' then 'godown_manager'
  when 'manager2.phase33browser@example.com' then 'godown_manager'
  when 'keeper.phase33browser@example.com' then 'store_keeper'
  when 'accounts.phase33browser@example.com' then 'accounts'
  when 'sales.phase33browser@example.com' then 'salesperson'
  else 'delivery_person'
end
where users.email like '%.phase33browser@example.com';

create or replace function public.phase33_browser_claim(actor_email text)
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

select public.phase33_browser_claim('admin.phase33browser@example.com');
select public.create_branch('phase33_browser', 'Browser Godown');
select public.create_zone(
  (select id from public.branches where code = 'phase33_browser'),
  'b33z', 'Browser Zone', null
);
select public.create_crate(
  (select id from public.zones where code = 'b33z'),
  'b33c', 'Browser Crate', null
);
select public.create_product('p33-browser-soap', 'Browser Soap', null, null);
select public.create_product('p33-browser-oil', 'Browser Oil', null, null);
select public.create_product('p33-browser-rice', 'Browser Rice', null, null);
select public.create_product('p33-browser-tea', 'Browser Tea', null, null);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager.phase33browser@example.com'),
  (select id from public.branches where code = 'phase33_browser')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager2.phase33browser@example.com'),
  (select id from public.branches where code = 'phase33_browser')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'keeper.phase33browser@example.com'),
  (select id from public.branches where code = 'phase33_browser')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'accounts.phase33browser@example.com'),
  (select id from public.branches where code = 'phase33_browser')
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p33-browser-soap'),
  (select id from public.crates where code = 'b33c'),
  20,
  'p33-browser-open-soap',
  null
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p33-browser-oil'),
  (select id from public.crates where code = 'b33c'),
  8,
  'p33-browser-open-oil',
  null
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p33-browser-rice'),
  (select id from public.crates where code = 'b33c'),
  6,
  'p33-browser-open-rice',
  null
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p33-browser-tea'),
  (select id from public.crates where code = 'b33c'),
  4,
  'p33-browser-open-tea',
  null
);

create or replace function public.phase33_browser_close(target_sku text, physical integer, label text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  created uuid;
  line_id uuid;
  version integer;
  expected integer;
  line_sku text;
  payload bytea := pg_catalog.decode('ffd8ffd9', 'hex');
  photo jsonb;
begin
  perform public.phase33_browser_claim('manager.phase33browser@example.com');
  created := public.start_stock_verification(
    (select id from public.branches where code = 'phase33_browser'),
    current_date,
    array[(select id from public.zones where code = 'b33z')],
    array[(select id from public.crates where code = 'b33c')]
  );
  for line_id, version, expected, line_sku in
    select stock_verification_lines.id, stock_verification_lines.line_version, stock_verification_lines.expected_cases, products.sku
    from public.stock_verification_lines
    join public.products on products.id = stock_verification_lines.product_id
    where stock_verification_lines.verification_id = created
  loop
    if line_sku = target_sku then
      perform public.save_verification_count(line_id, pg_catalog.to_jsonb(physical), version);
    else
      perform public.save_verification_count(line_id, pg_catalog.to_jsonb(expected), version);
    end if;
  end loop;
  perform public.submit_stock_verification(created);
  select stock_verification_lines.id into line_id
  from public.stock_verification_lines
  join public.products on products.id = stock_verification_lines.product_id
  where stock_verification_lines.verification_id = created
    and products.sku = target_sku;
  perform public.report_stock_discrepancy(line_id, label);
  perform public.request_verification_recount(line_id);
  select stock_verification_lines.line_version into version
  from public.stock_verification_lines
  where stock_verification_lines.id = line_id;
  perform public.save_verification_recount(line_id, pg_catalog.to_jsonb(physical), version);
  perform public.review_verification_discrepancy(line_id, label, '{}'::uuid[]);
  photo := public.create_verification_photo_upload(created, label, null);
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-verification-evidence',
    photo ->> 'path',
    auth.uid(),
    auth.uid()::text,
    pg_catalog.jsonb_build_object(
      'size', pg_catalog.octet_length(payload),
      'mimetype', 'image/jpeg',
      'eTag', pg_catalog.encode(extensions.digest(payload, 'md5'), 'hex')
    )
  );
  perform public.finalize_verification_photo_upload((photo ->> 'id')::uuid, pg_catalog.encode(payload, 'base64'));
  perform public.close_stock_verification(created, 'correction_requested', label);
  return pg_catalog.jsonb_build_object('verification_id', created, 'line_id', line_id);
end;
$$;

create or replace function public.phase33_browser_request(
  target_sku text,
  physical integer,
  label text,
  reason_code text,
  request_note text,
  idempotency_key text,
  submit_it boolean,
  approve_it boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  closed jsonb;
  request_id uuid;
begin
  closed := public.phase33_browser_close(target_sku, physical, label);
  perform public.phase33_browser_claim('manager.phase33browser@example.com');
  request_id := (public.create_stock_adjustment(
    (closed ->> 'verification_id')::uuid,
    reason_code,
    request_note,
    array[(closed ->> 'line_id')::uuid],
    idempotency_key,
    null
  ) ->> 'id')::uuid;
  if submit_it then
    perform public.submit_stock_adjustment(request_id, 1);
  end if;
  if approve_it then
    perform public.phase33_browser_claim('manager2.phase33browser@example.com');
    perform public.approve_stock_adjustment(request_id, 2, 'browser approval');
  end if;
end;
$$;

select public.phase33_browser_request('p33-browser-soap', 9, 'soap short eleven', 'shortage', 'exceptional browser request', 'p33-browser-soap', true, false);
select public.phase33_browser_request('p33-browser-oil', 7, 'oil short one', 'shortage', 'ordinary browser request', 'p33-browser-oil', true, false);
select public.phase33_browser_request('p33-browser-rice', 5, 'rice short one', 'shortage', 'approved browser request', 'p33-browser-rice', true, true);
select public.phase33_browser_close('p33-browser-tea', 3, 'tea short one');
