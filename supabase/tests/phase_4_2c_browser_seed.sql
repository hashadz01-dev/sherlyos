-- Disposable LOCAL browser fixtures for Phase 4.2C. Not for hosted projects.

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
    ('accounts.phase42cbrowser@example.com', 'Browser Accounts 42C'),
    ('godown.phase42cbrowser@example.com', 'Browser Godown 42C'),
    ('godown_b.phase42cbrowser@example.com', 'Browser Godown B 42C'),
    ('admin.phase42cbrowser@example.com', 'Browser Admin 42C'),
    ('sales.phase42cbrowser@example.com', 'Browser Sales 42C')
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
where email like '%.phase42cbrowser@example.com';

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
where users.email like '%.phase42cbrowser@example.com';

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'accounts.phase42cbrowser@example.com' then 'accounts'
  when 'godown.phase42cbrowser@example.com' then 'godown_manager'
  when 'godown_b.phase42cbrowser@example.com' then 'godown_manager'
  when 'admin.phase42cbrowser@example.com' then 'admin'
  else 'salesperson'
end
where users.email like '%.phase42cbrowser@example.com';

create or replace function public.phase42c_browser_claim(actor_email text)
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

select public.phase42c_browser_claim('admin.phase42cbrowser@example.com');
select public.create_branch('phase42c_browser_a', 'DN Browser Godown A');
select public.create_branch('phase42c_browser_b', 'DN Browser Godown B');
select public.assign_user_branch(
  (select id from auth.users where email = 'accounts.phase42cbrowser@example.com'),
  (select id from public.branches where code = 'phase42c_browser_a')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'godown.phase42cbrowser@example.com'),
  (select id from public.branches where code = 'phase42c_browser_a')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'godown_b.phase42cbrowser@example.com'),
  (select id from public.branches where code = 'phase42c_browser_b')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'sales.phase42cbrowser@example.com'),
  (select id from public.branches where code = 'phase42c_browser_a')
);
select public.create_product('p42c-browser-soap', 'Browser DN Soap', null, null);
select public.create_shop('Phase 42C Browser Shop', '555-0100', '12 Browser Street');
select public.assign_shop_salesperson(
  (select id from public.shops where name = 'Phase 42C Browser Shop'),
  (select id from auth.users where email = 'sales.phase42cbrowser@example.com')
);

insert into public.app_configuration (key, value, description)
values
  ('company.legal_name', '"Local Browser Test Co"'::jsonb, 'Local browser test identity only.'),
  ('company.registered_address', '"99 Local Test Road"'::jsonb, 'Local browser test identity only.')
on conflict (key) do update
  set value = excluded.value,
      description = excluded.description;

-- Verified order ready for DN creation
select public.phase42c_browser_claim('accounts.phase42cbrowser@example.com');

do $$
declare
  order_id uuid;
  detail jsonb;
begin
  detail := public.create_order(
    (select id from public.shops where name = 'Phase 42C Browser Shop'),
    (select id from public.branches where code = 'phase42c_browser_a'),
    'accounts',
    null,
    'phase 42c browser order',
    jsonb_build_array(
      jsonb_build_object(
        'product_id', (select id from public.products where sku = 'p42c-browser-soap'),
        'requested_cases', 4
      )
    ),
    'p42c-browser-create-order'
  );
  order_id := (detail -> 'order' ->> 'id')::uuid;
  perform public.submit_order(order_id, 1, 'p42c-browser-submit');
  -- Opening stock for Rule A verify
end;
$$;

select public.phase42c_browser_claim('admin.phase42cbrowser@example.com');
select public.create_zone(
  (select id from public.branches where code = 'phase42c_browser_a'),
  'b42cz', 'Browser DN Zone', null
);
select public.create_crate(
  (select id from public.zones where code = 'b42cz'),
  'b42cc', 'Browser DN Crate', null
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p42c-browser-soap'),
  (select id from public.crates where code = 'b42cc'),
  20,
  'p42c-browser-open',
  null
);

select public.phase42c_browser_claim('accounts.phase42cbrowser@example.com');
select public.verify_order(
  (select id from public.orders where idempotency_key = 'p42c-browser-create-order'),
  2,
  'p42c-browser-verify'
);
