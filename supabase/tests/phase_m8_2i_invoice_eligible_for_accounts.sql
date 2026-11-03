-- Accounts may list confirmed dispatches awaiting an invoice-note draft.
-- Prepare, review-to-issue, and statutory numbering stay unchanged. Rolls back.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('driver', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m82i@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'),
      'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values ((select id from fixture where name = 'admin'), 'M82I Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'M82I ' || fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'accounts' then 'accounts'
  when 'godown' then 'godown_manager'
  when 'driver' then 'delivery_person'
end
where fixture.name <> 'admin'
on conflict do nothing;

create or replace function pg_temp.as_user(who text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = who), true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', (select id from fixture where name = who),
      'role', 'authenticated'
    )::text,
    true
  );
  perform set_config('request.jwt.claim.role', 'authenticated', true);
end;
$$;

do $$
declare
  listed jsonb;
begin
  perform pg_temp.as_user('driver');
  begin
    listed := public.list_invoice_eligible_dispatches();
    raise exception 'delivery person must not list invoice-eligible dispatches';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  perform pg_temp.as_user('accounts');
  listed := public.list_invoice_eligible_dispatches();
  if listed is null then
    raise exception 'accounts eligible list must return jsonb';
  end if;

  begin
    perform public.prepare_invoice_note(gen_random_uuid(), 'm82i-sql', 1, null);
    raise exception 'accounts must not prepare invoice notes';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  perform pg_temp.as_user('godown');
  listed := public.list_invoice_eligible_dispatches();
  if listed is null then
    raise exception 'godown manager eligible list must return jsonb';
  end if;
end;
$$;

rollback;
