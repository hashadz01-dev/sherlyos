-- Disposable local browser users for Phase 3.2. Not for the hosted project.

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
    ('admin.phase32browser@example.com', 'Browser Admin'),
    ('manager.phase32browser@example.com', 'Browser Manager'),
    ('keeper.phase32browser@example.com', 'Browser Keeper'),
    ('accounts.phase32browser@example.com', 'Browser Accounts'),
    ('sales.phase32browser@example.com', 'Browser Sales'),
    ('delivery.phase32browser@example.com', 'Browser Delivery')
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
where email like '%.phase32browser@example.com';

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
where users.email like '%.phase32browser@example.com';

select app_private.bootstrap_initial_admin(
  (select id from auth.users where email = 'admin.phase32browser@example.com'),
  'create-initial-administrator'
);

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'keeper.phase32browser@example.com' then 'store_keeper'
  when 'manager.phase32browser@example.com' then 'godown_manager'
  when 'accounts.phase32browser@example.com' then 'accounts'
  when 'sales.phase32browser@example.com' then 'salesperson'
  else 'delivery_person'
end
where users.email like '%.phase32browser@example.com'
  and users.email <> 'admin.phase32browser@example.com';

create or replace function public.phase32_browser_claim(actor_email text)
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

select public.phase32_browser_claim('admin.phase32browser@example.com');
select public.create_branch('phase32_browser', 'Browser Godown');
select public.create_zone(
  (select id from public.branches where code = 'phase32_browser'),
  'bvz', 'Browser Zone', null
);
select public.create_crate(
  (select id from public.zones where code = 'bvz'),
  'bvc', 'Browser Crate', null
);
select public.create_product('p32-browser-soap', 'Browser Soap', null, null);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager.phase32browser@example.com'),
  (select id from public.branches where code = 'phase32_browser')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'keeper.phase32browser@example.com'),
  (select id from public.branches where code = 'phase32_browser')
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p32-browser-soap'),
  (select id from public.crates where code = 'bvc'),
  5,
  'p32-browser-open-soap',
  null
);
drop function public.phase32_browser_claim(text);
