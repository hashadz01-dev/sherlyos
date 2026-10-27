-- M6.2 review: creator-only create replay, concurrent-create recovery,
-- and submit replay that still requires the original Accounts actor.
-- Forward-only. Zero stock. Does not flip damage/lot flags.

create or replace function app_private.completed_refill_create_payload(
  existing public.stock_refill_requests,
  fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Authorize the caller before comparing fingerprints so a foreign actor
  -- cannot tell whether the key exists with a matching payload.
  if existing.created_by is distinct from auth.uid()
    or not app_private.can_view_refill_at_godown(existing.destination_godown_id)
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if existing.request_fingerprint is distinct from fingerprint then
    raise exception 'idempotency key already used for a different request'
      using errcode = '23505';
  end if;

  return app_private.stock_refill_request_payload(existing.id);
end;
$$;

revoke all on function app_private.completed_refill_create_payload(
  public.stock_refill_requests,
  text
) from public, anon, authenticated, service_role;

create or replace function public.create_stock_refill_request(
  target_supplier uuid,
  target_godown uuid,
  request_lines jsonb,
  idempotency_key text,
  notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  normalized jsonb;
  fingerprint text;
  existing public.stock_refill_requests;
  created_id uuid;
  request_number text;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_refill_notes(notes, false);
  normalized := app_private.normalize_refill_lines(request_lines);
  fingerprint := app_private.refill_request_fingerprint(
    target_supplier, target_godown, cleaned_notes, normalized
  );

  -- Serialize same-key creates. Unique(idempotency_key) remains the safety net.
  perform pg_catalog.pg_advisory_xact_lock(88106220, pg_catalog.hashtext(cleaned_key));

  select *
  into existing
  from public.stock_refill_requests
  where stock_refill_requests.idempotency_key = cleaned_key;

  if found then
    return app_private.completed_refill_create_payload(existing, fingerprint);
  end if;

  perform app_private.assert_refill_catalog(target_supplier, target_godown, normalized);

  request_number := 'RF-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(pg_catalog.nextval('public.stock_refill_request_seq')::text, 6, '0');

  begin
    insert into public.stock_refill_requests (
      request_number, supplier_id, destination_godown_id, status, notes, version,
      created_by, updated_by, idempotency_key, request_fingerprint
    )
    values (
      request_number, target_supplier, target_godown, 'draft', cleaned_notes, 1,
      auth.uid(), auth.uid(), cleaned_key, fingerprint
    )
    returning id into created_id;
  exception
    when unique_violation then
      select *
      into existing
      from public.stock_refill_requests
      where stock_refill_requests.idempotency_key = cleaned_key;

      if not found then
        raise;
      end if;

      return app_private.completed_refill_create_payload(existing, fingerprint);
  end;

  perform app_private.replace_refill_lines(created_id, normalized);
  perform app_private.record_refill_event(
    created_id, 'created', null, 'draft', cleaned_notes, 1
  );

  return app_private.stock_refill_request_payload(created_id);
end;
$$;

create or replace function public.submit_stock_refill_request(
  target_request uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_refill_requests;
  cleaned_key text;
  normalized jsonb;
  next_version integer;
  event_name text;
begin
  perform app_private.assert_permission('refill.request');
  perform app_private.enable_refill_write();
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  selected := app_private.lock_stock_refill_request(target_request);

  if selected.status = 'submitted'
    and selected.submit_idempotency_key is not distinct from cleaned_key
  then
    if selected.created_by is distinct from auth.uid() then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return app_private.stock_refill_request_payload(selected.id);
  end if;

  perform app_private.assert_refill_version(selected, expected_version);

  if selected.created_by is distinct from auth.uid()
    or selected.status not in ('draft', 'held')
  then
    raise exception 'refill request cannot be submitted' using errcode = '42501';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'product_id', stock_refill_request_lines.product_id,
        'requested_cases', stock_refill_request_lines.requested_cases
      )
      order by stock_refill_request_lines.product_id
    ),
    '[]'::jsonb
  )
  into normalized
  from public.stock_refill_request_lines
  where stock_refill_request_lines.refill_request_id = selected.id;

  perform app_private.assert_refill_catalog(
    selected.supplier_id, selected.destination_godown_id, normalized
  );

  next_version := selected.version + 1;
  event_name := case when selected.status = 'held' then 'resubmitted' else 'submitted' end;

  update public.stock_refill_requests
  set
    status = 'submitted',
    version = next_version,
    updated_by = auth.uid(),
    submitted_by = auth.uid(),
    submitted_at = pg_catalog.clock_timestamp(),
    submit_idempotency_key = cleaned_key
  where stock_refill_requests.id = selected.id;

  perform app_private.record_refill_event(
    selected.id, event_name, selected.status, 'submitted', null, next_version
  );

  return app_private.stock_refill_request_payload(selected.id);
end;
$$;

comment on function public.create_stock_refill_request(uuid, uuid, jsonb, text, text) is
  'M6.2. Accounts draft. Zero stock. Same-actor replay after current authorization.';
comment on function public.submit_stock_refill_request(uuid, integer, text) is
  'M6.2. Accounts submit or resubmit. Creator-only replay. Zero stock.';
