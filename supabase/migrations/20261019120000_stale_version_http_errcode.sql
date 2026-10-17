-- Phase 4.2F: replace application-level stale-version SQLSTATE 40001 with PT409.
-- PostgREST 14 retries SQLSTATE 40001 (serialization_failure), causing REST timeouts
-- for optimistic-concurrency mismatches. PT409 maps to HTTP 409 Conflict without retries.
-- Forward-only. Does not edit previously applied migrations.
-- Scope: delivery-note OCC RPCs, cancel_order, and Phase 4.1 order OCC RPCs that used 40001.
-- Does not change business logic, grants baseline, inventory, or idempotency behavior.

CREATE OR REPLACE FUNCTION public.generate_delivery_note(target_note uuid, expected_version integer, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_1$
declare
  cleaned_key text;
  selected_order public.orders%rowtype;
  selected public.delivery_notes%rowtype;
  existing_event public.delivery_note_events%rowtype;
  line_count integer;
  snapshot jsonb;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into existing_event
  from public.delivery_note_events
  where delivery_note_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.delivery_note_id is distinct from target_note
      or existing_event.event_type is distinct from 'generated'
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
    raise exception 'delivery note was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status is distinct from 'draft' then
    raise exception 'delivery note cannot change from % to generated', selected.status
      using errcode = '23514';
  end if;

  if selected_order.status is distinct from 'verified' then
    raise exception 'delivery note requires a verified order' using errcode = '23514';
  end if;

  select count(*)
  into line_count
  from public.delivery_note_lines
  where delivery_note_lines.delivery_note_id = selected.id;

  if line_count < 1 then
    raise exception 'delivery note has no lines' using errcode = '23514';
  end if;

  snapshot := app_private.current_delivery_note_line_snapshot(selected.id);

  update public.delivery_notes
  set
    status = 'generated',
    generated_at = pg_catalog.clock_timestamp(),
    generated_by = (select auth.uid()),
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
    'generated',
    'draft',
    'generated',
    (select auth.uid()),
    selected.version + 1,
    cleaned_key,
    snapshot
  );

  return public.get_delivery_note(selected.id);
end;
$p42f_1$;

CREATE OR REPLACE FUNCTION public.void_delivery_note(target_note uuid, expected_version integer, void_reason text, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_2$
declare
  cleaned_key text;
  cleaned_reason text;
  selected public.delivery_notes%rowtype;
  existing_event public.delivery_note_events%rowtype;
  snapshot jsonb;
  locked_order_id uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_reason := app_private.clean_required_order_text(void_reason, 500);

  select *
  into existing_event
  from public.delivery_note_events
  where delivery_note_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.delivery_note_id is distinct from target_note
      or existing_event.event_type is distinct from 'voided'
      or existing_event.note is distinct from cleaned_reason
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

  select orders.id
  into locked_order_id
  from public.orders
  where orders.id = selected.order_id
  for update;

  if locked_order_id is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note
  for update;

  perform app_private.assert_delivery_note_issuer(selected.branch_id);

  if selected.version is distinct from expected_version then
    raise exception 'delivery note was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status not in ('draft', 'generated', 'sent') then
    raise exception 'delivery note cannot change from % to voided', selected.status
      using errcode = '23514';
  end if;

  snapshot := app_private.current_delivery_note_line_snapshot(selected.id);

  update public.delivery_notes
  set
    status = 'voided',
    voided_at = pg_catalog.clock_timestamp(),
    voided_by = (select auth.uid()),
    void_reason = cleaned_reason,
    version = selected.version + 1
  where delivery_notes.id = selected.id;

  insert into public.delivery_note_events (
    delivery_note_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    note,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'voided',
    selected.status,
    'voided',
    (select auth.uid()),
    cleaned_reason,
    selected.version + 1,
    cleaned_key,
    snapshot
  );

  return public.get_delivery_note(selected.id);
end;
$p42f_2$;

CREATE OR REPLACE FUNCTION public.send_delivery_note(target_note uuid, expected_version integer, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_3$
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
    raise exception 'delivery note was changed by someone else' using errcode = 'PT409';
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
$p42f_3$;

CREATE OR REPLACE FUNCTION public.acknowledge_delivery_note(target_note uuid, expected_version integer, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_4$
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
    raise exception 'delivery note was changed by someone else' using errcode = 'PT409';
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
$p42f_4$;

CREATE OR REPLACE FUNCTION public.cancel_order(target_order uuid, expected_version integer, cancellation_reason text, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_5$
declare
  cleaned_key text;
  cleaned_reason text;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
  open_note public.delivery_notes%rowtype;
  is_creator boolean;
  is_accounts boolean;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  open_note := app_private.lock_open_delivery_note_for_order(selected.id);
  if open_note.id is not null then
    if open_note.status = 'acknowledged' then
      raise exception 'order cannot be cancelled while an acknowledged delivery note exists'
        using errcode = '23514';
    end if;

    raise exception
      'void the active delivery note before cancelling this order'
      using errcode = '23514';
  end if;

  is_creator := selected.created_by = (select auth.uid())
    and (select app_private.has_permission('orders.capture'));
  is_accounts := (select app_private.has_permission('orders.verify'))
    and (select app_private.can_work_at_branch(selected.branch_id));

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'cancelled'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status = 'cancelled' then
    raise exception 'order cannot change from cancelled to cancelled'
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status in ('draft', 'held') then
    if not is_creator then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    cleaned_reason := app_private.clean_optional_order_text(cancellation_reason, 500);
  elsif selected.status in ('submitted', 'verified') then
    if not is_accounts then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    cleaned_reason := app_private.clean_required_order_text(cancellation_reason, 500);
  else
    raise exception 'order cannot change from % to cancelled', selected.status
      using errcode = '23514';
  end if;

  update public.orders
  set
    status = 'cancelled',
    cancelled_at = pg_catalog.clock_timestamp(),
    cancelled_by = (select auth.uid()),
    cancellation_reason = cleaned_reason,
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    note,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'cancelled',
    selected.status,
    'cancelled',
    (select auth.uid()),
    cleaned_reason,
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$p42f_5$;

CREATE OR REPLACE FUNCTION public.set_order(target_order uuid, expected_version integer, target_shop uuid, target_branch uuid, order_source text, source_reference text, order_notes text, order_lines jsonb, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_6$
declare
  cleaned_key text;
  cleaned_source text;
  cleaned_reference text;
  cleaned_notes text;
  normalized_lines jsonb;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
begin
  perform app_private.assert_permission('orders.capture');

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_source := pg_catalog.lower(pg_catalog.btrim(coalesce(order_source, '')));
  cleaned_reference := app_private.clean_optional_order_text(source_reference, 80);
  cleaned_notes := app_private.clean_optional_order_text(order_notes, 500);
  normalized_lines := app_private.normalize_order_lines(order_lines);

  if cleaned_source not in ('salesperson', 'accounts', 'telecalling', 'enquiry') then
    raise exception 'order source is invalid' using errcode = '23514';
  end if;

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or selected.created_by is distinct from (select auth.uid())
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'lines_revised'
      or selected.shop_id is distinct from target_shop
      or selected.branch_id is distinct from target_branch
      or selected.source is distinct from cleaned_source
      or selected.source_reference is distinct from cleaned_reference
      or selected.notes is distinct from cleaned_notes
      or existing_event.line_snapshot is distinct from normalized_lines
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;

    return public.get_order(selected.id);
  end if;

  if selected.status not in ('draft', 'held') then
    raise exception 'order cannot change from % to %', selected.status, selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  perform app_private.assert_order_shop(target_shop);
  perform app_private.assert_order_branch(target_branch);
  perform app_private.assert_order_line_products(normalized_lines);

  update public.orders
  set
    shop_id = target_shop,
    branch_id = target_branch,
    source = cleaned_source,
    source_reference = cleaned_reference,
    notes = cleaned_notes,
    version = selected.version + 1
  where orders.id = selected.id;

  perform app_private.replace_order_lines(selected.id, normalized_lines);

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    note,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'lines_revised',
    selected.status,
    selected.status,
    (select auth.uid()),
    cleaned_notes,
    selected.version + 1,
    cleaned_key,
    normalized_lines
  );

  return public.get_order(selected.id);
end;
$p42f_6$;

CREATE OR REPLACE FUNCTION public.submit_order(target_order uuid, expected_version integer, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_7$
declare
  cleaned_key text;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
begin
  perform app_private.assert_permission('orders.capture');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or selected.created_by is distinct from (select auth.uid())
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'submitted'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status not in ('draft', 'held') then
    raise exception 'order cannot change from % to submitted', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  perform app_private.assert_order_shop(selected.shop_id);
  perform app_private.assert_order_branch(selected.branch_id);
  perform app_private.assert_existing_order_lines(selected.id);

  update public.orders
  set
    status = 'submitted',
    submitted_at = pg_catalog.clock_timestamp(),
    submitted_by = (select auth.uid()),
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
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
    'submitted',
    selected.status,
    'submitted',
    (select auth.uid()),
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$p42f_7$;

CREATE OR REPLACE FUNCTION public.hold_order(target_order uuid, expected_version integer, hold_note text, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_8$
declare
  cleaned_key text;
  cleaned_note text;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
begin
  perform app_private.assert_permission('orders.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_note := app_private.clean_required_order_text(hold_note, 500);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or not (select app_private.can_work_at_branch(selected.branch_id))
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'held'
      or existing_event.note is distinct from cleaned_note
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'order cannot change from % to held', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  update public.orders
  set
    status = 'held',
    held_at = pg_catalog.clock_timestamp(),
    held_by = (select auth.uid()),
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    note,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'held',
    'submitted',
    'held',
    (select auth.uid()),
    cleaned_note,
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$p42f_8$;

CREATE OR REPLACE FUNCTION public.verify_order(target_order uuid, expected_version integer, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $p42f_9$
declare
  cleaned_key text;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
  availability jsonb;
  shortages jsonb;
begin
  perform app_private.assert_permission('orders.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or not (select app_private.can_work_at_branch(selected.branch_id))
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'verified'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'order cannot change from % to verified', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  if not exists (
    select 1
    from public.shops
    where shops.id = selected.shop_id
      and shops.is_active
  ) then
    raise exception 'shop is not active' using errcode = '23514';
  end if;

  perform app_private.assert_existing_order_lines(selected.id);

  availability := app_private.order_line_availability(selected.id, selected.branch_id);

  select coalesce(
    (
      select pg_catalog.jsonb_agg(entry order by entry ->> 'product_id')
      from pg_catalog.jsonb_array_elements(availability) as entry
      where (entry ->> 'shortfall_cases')::integer > 0
    ),
    '[]'::jsonb
  )
  into shortages;

  if pg_catalog.jsonb_array_length(shortages) > 0 then
    raise exception 'insufficient stock'
      using errcode = 'P0001',
            detail = shortages::text;
  end if;

  update public.orders
  set
    status = 'verified',
    verified_at = pg_catalog.clock_timestamp(),
    verified_by = (select auth.uid()),
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    version,
    idempotency_key,
    line_snapshot,
    availability_snapshot
  )
  values (
    selected.id,
    'verified',
    'submitted',
    'verified',
    (select auth.uid()),
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id),
    availability
  );

  return public.get_order(selected.id);
end;
$p42f_9$;
revoke all on function public.generate_delivery_note(uuid, integer, text) from public, anon;
revoke all on function public.void_delivery_note(uuid, integer, text, text) from public, anon;
revoke all on function public.send_delivery_note(uuid, integer, text) from public, anon;
revoke all on function public.acknowledge_delivery_note(uuid, integer, text) from public, anon;
revoke all on function public.cancel_order(uuid, integer, text, text) from public, anon;
revoke all on function public.set_order(uuid, integer, uuid, uuid, text, text, text, jsonb, text) from public, anon;
revoke all on function public.submit_order(uuid, integer, text) from public, anon;
revoke all on function public.hold_order(uuid, integer, text, text) from public, anon;
revoke all on function public.verify_order(uuid, integer, text) from public, anon;

grant execute on function public.generate_delivery_note(uuid, integer, text) to authenticated;
grant execute on function public.void_delivery_note(uuid, integer, text, text) to authenticated;
grant execute on function public.send_delivery_note(uuid, integer, text) to authenticated;
grant execute on function public.acknowledge_delivery_note(uuid, integer, text) to authenticated;
grant execute on function public.cancel_order(uuid, integer, text, text) to authenticated;
grant execute on function public.set_order(uuid, integer, uuid, uuid, text, text, text, jsonb, text) to authenticated;
grant execute on function public.submit_order(uuid, integer, text) to authenticated;
grant execute on function public.hold_order(uuid, integer, text, text) to authenticated;
grant execute on function public.verify_order(uuid, integer, text) to authenticated;
