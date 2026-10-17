-- Phase 4.2C delivery-note send and godown acknowledgement.
-- Local-only forward migration. Does not edit earlier Phase 4.1/4.2 migrations.
-- Transitions: generated → sent (Accounts); sent → acknowledged (Godown Manager).
-- No inventory writes. No order status changes.

create or replace function app_private.assert_delivery_note_acknowledger(target_branch uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('delivery_notes.acknowledge');

  if target_branch is null
    or not (select app_private.can_work_at_branch(target_branch))
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_delivery_note_acknowledger(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- send_delivery_note
-- ---------------------------------------------------------------------------

create or replace function public.send_delivery_note(
  target_note uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  selected_order public.orders%rowtype;
  selected public.delivery_notes%rowtype;
  existing_event public.delivery_note_events%rowtype;
  snapshot jsonb;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into existing_event
  from public.delivery_note_events
  where delivery_note_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.delivery_note_id is distinct from target_note
      or existing_event.event_type is distinct from 'sent'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;

    if not (select app_private.can_view_delivery_note(existing_event.delivery_note_id)) then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    return public.get_delivery_note(existing_event.delivery_note_id);
  end if;

  select delivery_notes.*
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected_order
  from public.orders
  where orders.id = selected.order_id
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note
  for update;

  perform app_private.assert_delivery_note_issuer(selected.branch_id);

  if selected.version is distinct from expected_version then
    raise exception 'delivery note was changed by someone else' using errcode = '40001';
  end if;

  if selected.status is distinct from 'generated' then
    raise exception 'delivery note cannot change from % to sent', selected.status
      using errcode = '23514';
  end if;

  if selected_order.status is distinct from 'verified' then
    raise exception 'delivery note requires a verified order' using errcode = '23514';
  end if;

  snapshot := app_private.current_delivery_note_line_snapshot(selected.id);

  update public.delivery_notes
  set
    status = 'sent',
    sent_at = pg_catalog.clock_timestamp(),
    sent_by = (select auth.uid()),
    version = selected.version + 1
  where delivery_notes.id = selected.id;

  insert into public.delivery_note_events (
    delivery_note_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'sent',
    'generated',
    'sent',
    (select auth.uid()),
    selected.version + 1,
    cleaned_key,
    snapshot
  );

  return public.get_delivery_note(selected.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- acknowledge_delivery_note
-- ---------------------------------------------------------------------------

create or replace function public.acknowledge_delivery_note(
  target_note uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  selected_order public.orders%rowtype;
  selected public.delivery_notes%rowtype;
  existing_event public.delivery_note_events%rowtype;
  snapshot jsonb;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into existing_event
  from public.delivery_note_events
  where delivery_note_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.delivery_note_id is distinct from target_note
      or existing_event.event_type is distinct from 'acknowledged'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;

    if not (select app_private.can_view_delivery_note(existing_event.delivery_note_id)) then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    return public.get_delivery_note(existing_event.delivery_note_id);
  end if;

  select delivery_notes.*
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected_order
  from public.orders
  where orders.id = selected.order_id
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note
  for update;

  perform app_private.assert_delivery_note_acknowledger(selected.branch_id);

  if selected.version is distinct from expected_version then
    raise exception 'delivery note was changed by someone else' using errcode = '40001';
  end if;

  if selected.status is distinct from 'sent' then
    raise exception 'delivery note cannot change from % to acknowledged', selected.status
      using errcode = '23514';
  end if;

  if selected_order.status is distinct from 'verified' then
    raise exception 'delivery note requires a verified order' using errcode = '23514';
  end if;

  snapshot := app_private.current_delivery_note_line_snapshot(selected.id);

  update public.delivery_notes
  set
    status = 'acknowledged',
    acknowledged_at = pg_catalog.clock_timestamp(),
    acknowledged_by = (select auth.uid()),
    version = selected.version + 1
  where delivery_notes.id = selected.id;

  insert into public.delivery_note_events (
    delivery_note_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'acknowledged',
    'sent',
    'acknowledged',
    (select auth.uid()),
    selected.version + 1,
    cleaned_key,
    snapshot
  );

  return public.get_delivery_note(selected.id);
end;
$$;

-- Enrich list payload for Godown Manager inbox (order number + total cases).
create or replace function public.list_delivery_notes(
  status_filter text default null,
  shop_filter uuid default null,
  branch_filter uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(status_filter, '')), '');
begin
  if (select auth.uid()) is null
    or not (
      (select app_private.has_permission('operations.monitor'))
      or (select app_private.has_permission('delivery_notes.issue'))
      or (select app_private.has_permission('delivery_notes.acknowledge'))
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if cleaned is not null
    and cleaned not in ('draft', 'generated', 'sent', 'acknowledged', 'voided')
  then
    raise exception 'delivery note status is invalid' using errcode = '23514';
  end if;

  if branch_filter is not null
    and not (
      (select app_private.has_permission('operations.monitor'))
      or (select app_private.can_work_at_branch(branch_filter))
    )
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;

  return coalesce(
    (
      select pg_catalog.jsonb_agg(row_payload order by row_payload ->> 'created_at' desc)
      from (
        select
          to_jsonb(delivery_notes)
          || pg_catalog.jsonb_build_object(
            'order_number', orders.order_number,
            'total_cases', coalesce((
              select sum(delivery_note_lines.requested_cases)
              from public.delivery_note_lines
              where delivery_note_lines.delivery_note_id = delivery_notes.id
            ), 0)
          ) as row_payload
        from public.delivery_notes
        join public.orders on orders.id = delivery_notes.order_id
        where (select app_private.can_view_delivery_note(delivery_notes.id))
          and (cleaned is null or delivery_notes.status = cleaned)
          and (shop_filter is null or delivery_notes.shop_id = shop_filter)
          and (branch_filter is null or delivery_notes.branch_id = branch_filter)
      ) as listed
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.list_delivery_notes(text, uuid, uuid) from public, anon;
grant execute on function public.list_delivery_notes(text, uuid, uuid) to authenticated;

revoke all on function public.send_delivery_note(uuid, integer, text) from public, anon;
revoke all on function public.acknowledge_delivery_note(uuid, integer, text) from public, anon;

grant execute on function public.send_delivery_note(uuid, integer, text) to authenticated;
grant execute on function public.acknowledge_delivery_note(uuid, integer, text) to authenticated;

comment on function public.send_delivery_note(uuid, integer, text) is
  'Accounts sends a generated delivery note to the fulfilling godown. No stock changes.';

comment on function public.acknowledge_delivery_note(uuid, integer, text) is
  'Godown Manager acknowledges a sent delivery note for an assigned godown. No stock, picking, or order status changes.';
