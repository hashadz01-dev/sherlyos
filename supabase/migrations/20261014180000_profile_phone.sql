-- Phone numbers collected when an administrator onboards a person.
-- Auth account creation stays in the create-employee Edge Function.

alter table public.profiles
  add column phone_number text;

alter table public.profiles
  add constraint profiles_phone_number_shape check (
    phone_number is null
    or (
      char_length(phone_number) between 7 and 24
      and phone_number = btrim(phone_number)
    )
  );

create or replace function app_private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone_number)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone_number', '')), '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;
