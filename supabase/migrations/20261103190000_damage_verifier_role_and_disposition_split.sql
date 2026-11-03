-- Restricted damage verifier role + disposition permission split.
-- damage.verify remains inspection (verify/return/reject).
-- Stock-changing disposition RPCs require damage.disposition (GM only).
-- Does not flip operational flags. Does not create Auth users.
-- Preserve godown_manager.godowns.all and existing staff role grants.

insert into public.permissions (code, description)
values (
  'damage.disposition',
  'Post ordinary damage write-off, request/execute exceptional disposition, and transfer verified storage damage to quarantine. Does not grant Admin exceptional approval.'
)
on conflict (code) do nothing;

insert into public.roles (code, name, description)
values (
  'damage_verifier',
  'Damage Verifier',
  'Independent verification of submitted damage at assigned godowns only. No stock posting, dispatch, opening stock, or damage create.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'damage.read'
where roles.code = 'damage_verifier'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'damage.verify'
where roles.code = 'damage_verifier'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'damage.disposition'
where roles.code = 'godown_manager'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Disposition writers: require damage.disposition (not bare damage.verify)
-- Bodies match prior M5.4D/E behaviour with the permission assert updated.
-- ---------------------------------------------------------------------------

create or replace function public.post_ordinary_damage_writeoff(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  posted uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.disposition');
  selected := app_private.lock_damage_report(target_report);

  select stock_transactions.id into posted
  from public.stock_transactions
  where stock_transactions.damage_report_id = selected.id
    and stock_transactions.damage_posting_kind = 'ordinary_writeoff';
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  perform app_private.assert_damage_version(selected, expected_version);

  if not exists (
    select 1
    from public.branches
    where branches.id = selected.godown_id
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
  if not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_damage_disposition_ready(selected);

  if app_private.has_permission('damage.dispose')
    and not app_private.has_permission('damage.disposition')
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.damage_exceptional_requests
    where damage_report_id = selected.id
      and status in ('requested', 'approved')
  ) then
    raise exception 'an exceptional disposition is already open' using errcode = '23514';
  end if;

  posted := app_private.consume_damage_holds(
    selected.id, 'written_off', 'ordinary_writeoff', 'Ordinary damage write-off'
  );

  perform app_private.record_damage_event(
    selected.id, 'ordinary_writeoff', selected.status, selected.status,
    jsonb_build_object('transaction_id', posted, 'idempotency_key', idempotency_key)
  );
  perform app_private.write_audit(
    auth.uid(), 'post_ordinary_damage_writeoff', 'damage_reports', selected.id,
    jsonb_build_object('transaction_id', posted)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.post_ordinary_damage_writeoff(uuid, integer, text) is
  'Ordinary write-off. Requires damage.disposition. Completed postings replay without version. Exact-once by posting kind.';

create or replace function public.request_exceptional_damage_disposition(
  target_report uuid,
  expected_version integer,
  disposition_kind text,
  request_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_key text;
  cleaned_kind text;
  cleaned_reason text;
  existing public.damage_exceptional_requests;
  created_id uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.disposition');
  selected := app_private.lock_damage_report(target_report);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select * into existing
  from public.damage_exceptional_requests
  where request_idempotency_key = cleaned_key;
  if found then
    if existing.damage_report_id is distinct from selected.id then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return app_private.damage_report_payload(selected.id);
  end if;

  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);
  perform app_private.assert_damage_disposition_ready(selected);
  cleaned_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(disposition_kind, '')));
  cleaned_reason := app_private.clean_verification_text(request_reason, true);

  if cleaned_kind not in ('return_supplier', 'destroy') then
    raise exception 'exceptional disposition is invalid' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.stock_transactions
    where stock_transactions.damage_report_id = selected.id
      and stock_transactions.damage_posting_kind = 'ordinary_writeoff'
  ) then
    raise exception 'an ordinary write-off is already posted' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.damage_stock_holds
    where damage_report_id = selected.id
      and status in ('active', 'transferred')
  ) then
    raise exception 'no isolated damage quantity remains' using errcode = '23514';
  end if;

  begin
    insert into public.damage_exceptional_requests (
      damage_report_id, disposition_kind, status, request_reason,
      requested_by, request_idempotency_key
    )
    values (
      selected.id, cleaned_kind, 'requested', cleaned_reason, auth.uid(), cleaned_key
    )
    returning id into created_id;
  exception
    when unique_violation then
      select * into existing
      from public.damage_exceptional_requests
      where request_idempotency_key = cleaned_key;
      if found then
        if existing.damage_report_id is distinct from selected.id then
          raise exception 'not authorized' using errcode = '42501';
        end if;
        return app_private.damage_report_payload(selected.id);
      end if;
      raise exception 'an exceptional disposition is already open'
        using errcode = '23514';
  end;

  perform app_private.record_damage_event(
    selected.id, 'exceptional_requested', selected.status, selected.status,
    jsonb_build_object('request_id', created_id, 'kind', cleaned_kind)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.request_exceptional_damage_disposition(uuid, integer, text, text, text) is
  'Exceptional request. Requires damage.disposition. Remaining holds required. Does not post stock.';

create or replace function public.post_exceptional_damage_disposition(
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
  selected public.damage_exceptional_requests;
  header public.damage_reports;
  posted uuid;
  hold_status text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.disposition');

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);

  if selected.status = 'posted' then
    return app_private.damage_report_payload(header.id);
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;

  if not exists (
    select 1
    from public.branches
    where branches.id = header.godown_id
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
  if not app_private.can_work_at_branch(header.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.status is distinct from 'approved' then
    raise exception 'exceptional request is not approved' using errcode = '42501';
  end if;

  if app_private.has_permission('damage.dispose')
    and not app_private.has_permission('damage.disposition')
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  hold_status := case
    when selected.disposition_kind = 'return_supplier' then 'returned_supplier'
    else 'written_off'
  end;

  posted := app_private.consume_damage_holds(
    header.id, hold_status, 'exceptional_writeoff',
    'Exceptional ' || selected.disposition_kind
  );

  update public.damage_exceptional_requests
  set
    status = 'posted',
    posted_by = auth.uid(),
    posted_at = clock_timestamp(),
    posted_transaction_id = posted,
    post_idempotency_key = app_private.clean_idempotency_key(idempotency_key),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    header.id, 'exceptional_posted', header.status, header.status,
    jsonb_build_object(
      'request_id', selected.id,
      'transaction_id', posted,
      'kind', selected.disposition_kind,
      'idempotency_key', idempotency_key
    )
  );
  perform app_private.write_audit(
    auth.uid(), 'post_exceptional_damage_disposition', 'damage_reports', header.id,
    jsonb_build_object('request_id', selected.id, 'transaction_id', posted)
  );
  return app_private.damage_report_payload(header.id);
end;
$$;

comment on function public.post_exceptional_damage_disposition(uuid, integer, text) is
  'Exceptional execution after admin approval. Requires damage.disposition. Completed postings replay without version.';

create or replace function public.transfer_verified_damage_to_quarantine(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  hold public.damage_stock_holds;
  q_crate uuid;
  cleaned_key text;
  fingerprint text;
  created_id uuid;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  lot_deltas jsonb := '[]'::jsonb;
  crate_ids uuid[];
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.enable_trusted_guc('app.damage_stock_write');
  perform app_private.assert_permission('damage.disposition');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);

  if selected.status is distinct from 'verified' or selected.scenario is distinct from 'storage' then
    raise exception 'quarantine transfer requires verified storage damage' using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.branches
    where branches.id = selected.godown_id
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;

  if not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select stock_transactions.id
  into created_id
  from public.stock_transactions
  where stock_transactions.idempotency_key = cleaned_key;
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  q_crate := app_private.ensure_godown_quarantine_crate(selected.godown_id);

  select array_agg(distinct crate_id) into crate_ids
  from public.damage_stock_holds
  where damage_report_id = selected.id and status = 'active' and hold_kind = 'on_hand_deduction';
  crate_ids := array_append(crate_ids, q_crate);
  perform app_private.lock_damage_stock_grains(
    selected.godown_id, crate_ids,
    array(select distinct product_id from public.damage_stock_holds where damage_report_id = selected.id),
    array(select distinct lot_id from public.damage_stock_holds where damage_report_id = selected.id and lot_id is not null)
  );

  fingerprint := 'quarantine_transfer:' || selected.id::text;
  select stock_transactions.id
  into created_id
  from public.stock_transactions
  where stock_transactions.idempotency_key = cleaned_key;
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, source_crate_id, destination_crate_id, quantity,
    damage_report_id, damage_posting_kind
  )
  select
    'CRATE_TRANSFER',
    'DMG-QRN-' || to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD') || '-'
      || lpad(nextval('public.stock_reference_seq')::text, 6, '0'),
    auth.uid(), cleaned_key, fingerprint, 'Verified damage quarantine transfer',
    (array_agg(product_id))[1],
    (array_agg(crate_id order by crate_id))[1],
    q_crate,
    sum(quantity_cases)::integer,
    selected.id,
    'quarantine_transfer'
  from public.damage_stock_holds
  where damage_report_id = selected.id and status = 'active' and hold_kind = 'on_hand_deduction'
  returning id into created_id;

  if created_id is null then
    raise exception 'no isolated damage quantity remains' using errcode = '23514';
  end if;

  for hold in
    select * from public.damage_stock_holds
    where damage_report_id = selected.id and status = 'active' and hold_kind = 'on_hand_deduction'
    order by crate_id, product_id, id
    for update
  loop
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    )
    values (created_id, hold.product_id, hold.crate_id, -hold.quantity_cases, auth.uid(), clock_timestamp(), hold.lot_id);
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    )
    values (created_id, hold.product_id, q_crate, hold.quantity_cases, auth.uid(), clock_timestamp(), hold.lot_id);

    if dual_write then
      if hold.lot_id is null then
        raise exception 'storage damage requires a lot when lot-aware dual-write is enabled'
          using errcode = '23514';
      end if;
      lot_deltas := lot_deltas || jsonb_build_array(
        jsonb_build_object('product_id', hold.product_id, 'lot_id', hold.lot_id, 'crate_id', hold.crate_id, 'quantity', -hold.quantity_cases),
        jsonb_build_object('product_id', hold.product_id, 'lot_id', hold.lot_id, 'crate_id', q_crate, 'quantity', hold.quantity_cases)
      );
    else
      perform app_private.apply_stock_delta(hold.crate_id, hold.product_id, -hold.quantity_cases);
      perform app_private.apply_stock_delta(q_crate, hold.product_id, hold.quantity_cases);
    end if;

    update public.damage_stock_holds
    set status = 'transferred', crate_id = q_crate, posted_transaction_id = created_id
    where id = hold.id;
  end loop;

  if dual_write then
    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  end if;

  perform app_private.record_damage_event(
    selected.id, 'quarantine_transferred', selected.status, selected.status,
    jsonb_build_object('transaction_id', created_id)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.transfer_verified_damage_to_quarantine(uuid, integer, text) is
  'Verified storage → quarantine transfer. Requires damage.disposition. Exact-once by idempotency key.';

-- Exceptional queue listing: disposition (GM) / dispose / monitor — not bare verify.
-- Keep the M5.4E payload; only the gate permission changes.
do $patch$
declare
  src text;
  patched text;
begin
  select pg_get_functiondef('public.list_exceptional_damage_requests(integer,integer,uuid,text,text,text,text,date,date)'::regprocedure)
  into src;
  if src is null then
    raise exception 'list_exceptional_damage_requests missing';
  end if;
  patched := replace(
    src,
    $$app_private.has_permission('damage.verify')$$,
    $$app_private.has_permission('damage.disposition')$$
  );
  patched := replace(
    patched,
    'damage.dispose, operations.monitor, or damage.verify',
    'damage.dispose, operations.monitor, or damage.disposition'
  );
  if patched = src then
    raise exception 'list_exceptional_damage_requests permission gate was not patched';
  end if;
  execute patched;
end;
$patch$;
