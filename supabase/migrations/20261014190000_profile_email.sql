-- Copy the sign-in email onto the profile so staff can read it.
-- auth.users stays the source of the credential; this column is the display copy.

alter table public.profiles
  add column email text;

update public.profiles as profiles
set email = lower(btrim(users.email))
from auth.users as users
where users.id = profiles.id
  and profiles.email is null
  and users.email is not null;

alter table public.profiles
  add constraint profiles_email_shape check (
    email is null
    or (
      char_length(email) between 3 and 320
      and email = lower(btrim(email))
      and position('@' in email) > 1
    )
  );

create unique index profiles_email_key
  on public.profiles (email)
  where email is not null;

create or replace function app_private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone_number, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone_number', '')), ''),
    nullif(lower(btrim(coalesce(new.email, ''))), '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;
