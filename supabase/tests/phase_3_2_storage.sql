-- Disposable local photo fixture. Not for the hosted project.

create or replace function public.phase32_photo_claim(actor_email text)
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
    ('admin.phase32photo@example.com', 'Phase 32 Photo Admin'),
    ('manager.phase32photo@example.com', 'Phase 32 Photo Manager'),
    ('keeper.phase32photo@example.com', 'Phase 32 Photo Keeper'),
    ('other.phase32photo@example.com', 'Phase 32 Photo Other')
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
where email like '%.phase32photo@example.com';

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
where users.email like '%.phase32photo@example.com';

select app_private.bootstrap_initial_admin(
  (select id from auth.users where email = 'admin.phase32photo@example.com'),
  'create-initial-administrator'
);

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'manager.phase32photo@example.com' then 'godown_manager'
  when 'keeper.phase32photo@example.com' then 'store_keeper'
  else 'godown_manager'
end
where users.email in (
  'manager.phase32photo@example.com',
  'keeper.phase32photo@example.com',
  'other.phase32photo@example.com'
);

select public.phase32_photo_claim('admin.phase32photo@example.com');
select public.create_branch('phase32_photo', 'Phase 32 Photo');
select public.create_branch('phase32_photo_b', 'Phase 32 Photo Other');
select public.create_zone(
  (select id from public.branches where code = 'phase32_photo'),
  'pz', 'Photo Zone', null
);
select public.create_crate(
  (select id from public.zones where code = 'pz' and branch_id = (select id from public.branches where code = 'phase32_photo')),
  'pca', 'Photo Crate', null
);
select public.create_product('p32-photo-soap', 'Phase 32 Photo Soap', null, null);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager.phase32photo@example.com'),
  (select id from public.branches where code = 'phase32_photo')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'keeper.phase32photo@example.com'),
  (select id from public.branches where code = 'phase32_photo')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'other.phase32photo@example.com'),
  (select id from public.branches where code = 'phase32_photo_b')
);
select public.post_opening_stock(
  (select id from public.products where sku = 'p32-photo-soap'),
  (select id from public.crates where code = 'pca'),
  5,
  'p32-photo-open-soap',
  null
);
