-- Phase 4.2B delivery-note mutations and cancel_order guard.
-- Local-only forward migration. Does not edit 20261017120000 or 20261018120000.
-- Lifecycle: draft → generated → sent → acknowledged; void from draft/generated/sent.
-- No inventory writes. No send/acknowledge RPCs (Phase 4.2C).

-- ---------------------------------------------------------------------------
-- Company print identity (read-only helpers; no fictional seed values)
-- ---------------------------------------------------------------------------

create or replace function app_private.read_company_print_identity()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  legal_name text;
  registered_address text;
  tax_id text;
begin
  select nullif(pg_catalog.btrim(coalesce(app_configuration.value #>> '{}', '')), '')
  into legal_name
  from public.app_configuration
  where app_configuration.key = 'company.legal_name';

  select nullif(pg_catalog.btrim(coalesce(app_configuration.value #>> '{}', '')), '')
  into registered_address
  from public.app_configuration
  where app_configuration.key = 'company.registered_address';

  select nullif(pg_catalog.btrim(coalesce(app_configuration.value #>> '{}', '')), '')
  into tax_id
  from public.app_configuration
  where app_configuration.key = 'company.tax_id';

  return pg_catalog.jsonb_build_object(
    'ready',
    legal_name is not null and registered_address is not null,
    'legal_name',
    legal_name,
    'registered_address',
    registered_address,
    'tax_id',
    tax_id
  );
end;
$$;

revoke all on function app_private.read_company_print_identity()
  from public, anon, authenticated, service_role;

create or replace function public.get_company_print_identity()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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

  return app_private.read_company_print_identity();
end;
$$;

revoke all on function public.get_company_print_identity() from public, anon;
grant execute on function public.get_company_print_identity() to authenticated;

comment on function public.get_company_print_identity() is
  'Non-secret company identity for official DN printing. ready=false when legal_name or registered_address is missing. No fictional defaults.';

-- ---------------------------------------------------------------------------
-- Delivery-note helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.current_delivery_note_line_snapshot(target_note uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'product_id', delivery_note_lines.product_id,
          'requested_cases', delivery_note_lines.requested_cases
        )
        order by delivery_note_lines.product_id
      )
      from public.delivery_note_lines
      where delivery_note_lines.delivery_note_id = target_note
    ),
    '[]'::jsonb
  );
$$;

revoke all on function app_private.current_delivery_note_line_snapshot(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_delivery_note_issuer(target_branch uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('delivery_notes.issue');

  if target_branch is null
    or not (select app_private.can_work_at_branch(target_branch))
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_delivery_note_issuer(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_open_delivery_note_for_order(target_order uuid)
returns public.delivery_notes
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.delivery_notes%rowtype;
begin
  select *
  into selected
  from public.delivery_notes
  where delivery_notes.order_id = target_order
    and delivery_notes.status <> 'voided'
  for update;

  return selected;
end;
$$;

revoke all on function app_private.lock_open_delivery_note_for_order(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- create_delivery_note
-- ---------------------------------------------------------------------------

create or replace function public.create_delivery_note(
  target_order uuid,
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
  existing public.delivery_notes%rowtype;
  open_note public.delivery_notes%rowtype;
  created_id uuid;
  line_count integer;
  snapshot jsonb;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into existing
  from public.delivery_notes
  where delivery_notes.idempotency_key = cleaned_key;

  if found then
    if not (select app_private.can_view_delivery_note(existing.id)) then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    if existing.order_id is distinct from target_order
      or existing.status is distinct from 'draft'
      or existing.created_by is distinct from (select auth.uid())
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;

    return public.get_delivery_note(existing.id);
  end if;

  select *
  into selected_order
  from public.orders
  where orders.id = target_order
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_delivery_note_issuer(selected_order.branch_id);

  if selected_order.status is distinct from 'verified' then
    raise exception 'delivery note requires a verified order' using errcode = '23514';
  end if;

  open_note := app_private.lock_open_delivery_note_for_order(selected_order.id);
  if open_note.id is not null then
    raise exception 'order already has an active delivery note' using errcode = '23505';
  end if;

  select count(*)
  into line_count
  from public.order_lines
  where order_lines.order_id = selected_order.id;

  if line_count < 1 then
    raise exception 'order has no lines' using errcode = '23514';
  end if;

  begin
    insert into public.delivery_notes (
      order_id,
      shop_id,
      branch_id,
      status,
      version,
      idempotency_key,
      created_by
    )
    values (
      selected_order.id,
      selected_order.shop_id,
      selected_order.branch_id,
      'draft',
      1,
      cleaned_key,
      (select auth.uid())
    )
    returning id into created_id;
  exception
    when unique_violation then
      select *
      into existing
      from public.delivery_notes
      where delivery_notes.idempotency_key = cleaned_key;

      if found then
        if not (select app_private.can_view_delivery_note(existing.id)) then
          raise exception 'not authorized' using errcode = '42501';
        end if;
        if existing.order_id is distinct from target_order
          or existing.status is distinct from 'draft'
          or existing.created_by is distinct from (select auth.uid())
        then
          raise exception 'idempotency key does not match the original request'
            using errcode = '23514';
        end if;
        return public.get_delivery_note(existing.id);
      end if;

      raise exception 'order already has an active delivery note' using errcode = '23505';
  end;

  insert into public.delivery_note_lines (delivery_note_id, product_id, requested_cases)
  select created_id, order_lines.product_id, order_lines.requested_cases
  from public.order_lines
  where order_lines.order_id = selected_order.id
  order by order_lines.product_id;

  snapshot := app_private.current_delivery_note_line_snapshot(created_id);

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
    created_id,
    'created',
    null,
    'draft',
    (select auth.uid()),
    1,
    cleaned_key,
    snapshot
  );

  return public.get_delivery_note(created_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- generate_delivery_note
-- ---------------------------------------------------------------------------

create or replace function public.generate_delivery_note(
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
    raise exception 'delivery note was changed by someone else' using errcode = '40001';
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
$$;

-- ---------------------------------------------------------------------------
-- void_delivery_note
-- ---------------------------------------------------------------------------

create or replace function public.void_delivery_note(
  target_note uuid,
  expected_version integer,
  void_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
    raise exception 'delivery note was changed by someone else' using errcode = '40001';
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
$$;

-- ---------------------------------------------------------------------------
-- get_delivery_note_print
-- ---------------------------------------------------------------------------

create or replace function public.get_delivery_note_print(target_note uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.delivery_notes%rowtype;
  identity jsonb;
  detail jsonb;
  total_cases integer;
begin
  if target_note is null or not (select app_private.can_view_delivery_note(target_note)) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note;

  if selected.status not in ('generated', 'sent', 'acknowledged') then
    raise exception 'delivery note is not printable' using errcode = '23514';
  end if;

  identity := app_private.read_company_print_identity();
  detail := public.get_delivery_note(target_note);

  select coalesce(sum(delivery_note_lines.requested_cases), 0)
  into total_cases
  from public.delivery_note_lines
  where delivery_note_lines.delivery_note_id = target_note;

  return pg_catalog.jsonb_build_object(
    'print_ready',
    coalesce((identity ->> 'ready')::boolean, false),
    'company',
    identity,
    'delivery_note',
    detail -> 'delivery_note',
    'order',
    detail -> 'order',
    'shop',
    detail -> 'shop',
    'godown',
    detail -> 'godown',
    'lines',
    detail -> 'lines',
    'total_cases',
    total_cases,
    'created_by_name',
    (
      select profiles.full_name
      from public.profiles
      where profiles.id = selected.created_by
    ),
    'generated_by_name',
    (
      select profiles.full_name
      from public.profiles
      where profiles.id = selected.generated_by
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- cancel_order guard (forward-only replace; does not edit Phase 4.1 migration)
-- ---------------------------------------------------------------------------

create or replace function public.cancel_order(
  target_order uuid,
  expected_version integer,
  cancellation_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
    raise exception 'order was changed by someone else' using errcode = '40001';
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
$$;

revoke all on function public.create_delivery_note(uuid, text) from public, anon;
revoke all on function public.generate_delivery_note(uuid, integer, text) from public, anon;
revoke all on function public.void_delivery_note(uuid, integer, text, text) from public, anon;
revoke all on function public.get_delivery_note_print(uuid) from public, anon;
revoke all on function public.cancel_order(uuid, integer, text, text) from public, anon;

grant execute on function public.create_delivery_note(uuid, text) to authenticated;
grant execute on function public.generate_delivery_note(uuid, integer, text) to authenticated;
grant execute on function public.void_delivery_note(uuid, integer, text, text) to authenticated;
grant execute on function public.get_delivery_note_print(uuid) to authenticated;
grant execute on function public.cancel_order(uuid, integer, text, text) to authenticated;

comment on function public.create_delivery_note(uuid, text) is
  'Accounts creates a draft delivery note from a verified order with a full immutable line snapshot.';

comment on function public.generate_delivery_note(uuid, integer, text) is
  'Accounts transitions draft → generated. Official print requires configured company identity.';

comment on function public.void_delivery_note(uuid, integer, text, text) is
  'Accounts voids draft, generated, or sent delivery notes with a required reason. Acknowledged cannot be voided.';

comment on function public.get_delivery_note_print(uuid) is
  'Print payload for generated/sent/acknowledged DNs. print_ready is false until company.legal_name and company.registered_address are configured.';

comment on function public.cancel_order(uuid, integer, text, text) is
  'Phase 4.2B: voids must happen separately. Active DN blocks cancel; acknowledged DN blocks cancel. No automatic void.';
