-- Cleanup Phase 4.2B concurrency fixtures.

alter table public.delivery_note_events disable trigger delivery_note_events_append_only;
alter table public.delivery_note_lines disable trigger delivery_note_lines_immutable;
alter table public.order_events disable trigger order_events_append_only;

do $$
declare
  order_ids uuid[];
  note_ids uuid[];
  user_ids uuid[];
begin
  select array_agg(id) into order_ids
  from public.orders
  where idempotency_key like 'p42b-race-order-%'
     or order_number like 'SO-42B-RACE-%';

  select array_agg(id) into note_ids
  from public.delivery_notes
  where order_id = any (coalesce(order_ids, '{}'::uuid[]))
     or idempotency_key like 'p42b-race-%';

  delete from public.delivery_note_events
  where delivery_note_id = any (coalesce(note_ids, '{}'::uuid[]))
     or idempotency_key like 'p42b-race-%';

  delete from public.delivery_note_lines
  where delivery_note_id = any (coalesce(note_ids, '{}'::uuid[]));

  delete from public.delivery_notes
  where id = any (coalesce(note_ids, '{}'::uuid[]));

  delete from public.order_events
  where order_id = any (coalesce(order_ids, '{}'::uuid[]));

  delete from public.order_lines
  where order_id = any (coalesce(order_ids, '{}'::uuid[]));

  delete from public.orders
  where id = any (coalesce(order_ids, '{}'::uuid[]));

  select array_agg(id) into user_ids
  from auth.users
  where email like '%phase42brace@example.com';

  delete from public.user_branch_assignments
  where user_id = any (coalesce(user_ids, '{}'::uuid[]));

  delete from public.user_roles
  where user_id = any (coalesce(user_ids, '{}'::uuid[]));

  delete from public.profiles
  where id = any (coalesce(user_ids, '{}'::uuid[]));

  delete from auth.users
  where id = any (coalesce(user_ids, '{}'::uuid[]));

  delete from public.products where sku = 'p42b-race';
  delete from public.shops where name = 'Phase 42B race shop';
  delete from public.branches where code = 'p42b_race_a';

  drop table if exists public.phase42b_race_target cascade;
  drop function if exists public.phase42b_claim(text);
end;
$$;

alter table public.delivery_note_events enable trigger delivery_note_events_append_only;
alter table public.delivery_note_lines enable trigger delivery_note_lines_immutable;
alter table public.order_events enable trigger order_events_append_only;
