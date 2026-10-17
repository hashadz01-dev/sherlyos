-- Disposable LOCAL browser users for Phase 4.1D. Not for hosted projects.

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
    ('admin.phase41dbrowser@example.com', 'Browser Admin'),
    ('accounts.phase41dbrowser@example.com', 'Browser Accounts'),
    ('sales.phase41dbrowser@example.com', 'Browser Sales'),
    ('godown.phase41dbrowser@example.com', 'Browser Godown'),
    ('keeper.phase41dbrowser@example.com', 'Browser Keeper'),
    ('delivery.phase41dbrowser@example.com', 'Browser Delivery')
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
where email like '%.phase41dbrowser@example.com';

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
where users.email like '%.phase41dbrowser@example.com';

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'admin.phase41dbrowser@example.com' then 'admin'
  when 'accounts.phase41dbrowser@example.com' then 'accounts'
  when 'sales.phase41dbrowser@example.com' then 'salesperson'
  when 'godown.phase41dbrowser@example.com' then 'godown_manager'
  when 'keeper.phase41dbrowser@example.com' then 'store_keeper'
  else 'delivery_person'
end
where users.email like '%.phase41dbrowser@example.com';

create or replace function public.phase41d_browser_claim(actor_email text)
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

select public.phase41d_browser_claim('admin.phase41dbrowser@example.com');
select public.create_branch('phase41d_browser', 'Orders Browser Godown');
select public.assign_user_branch(
  (select id from auth.users where email = 'accounts.phase41dbrowser@example.com'),
  (select id from public.branches where code = 'phase41d_browser')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'sales.phase41dbrowser@example.com'),
  (select id from public.branches where code = 'phase41d_browser')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'godown.phase41dbrowser@example.com'),
  (select id from public.branches where code = 'phase41d_browser')
);
select public.create_zone(
  (select id from public.branches where code = 'phase41d_browser'),
  'b41z', 'Browser Zone', null
);
select public.create_crate(
  (select id from public.zones where code = 'b41z'),
  'b41c', 'Browser Crate', null
);
select public.create_product('p41d-browser-soap', 'Browser Soap', null, null);
select public.create_shop('Phase 41D Browser Shop', null, null);
select public.assign_shop_salesperson(
  (select id from public.shops where name = 'Phase 41D Browser Shop'),
  (select id from auth.users where email = 'sales.phase41dbrowser@example.com')
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p41d-browser-soap'),
  (select id from public.crates where code = 'b41c'),
  25,
  'p41d-browser-open',
  null
);
