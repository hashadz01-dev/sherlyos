-- Archived copy of an already-applied development-cloud migration statement.
-- Do not move this file into supabase/migrations and do not apply it again.

create or replace function public.submit_damage_report(
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
  cleaned_key text;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  if selected.status = 'submitted'
    and selected.submit_idempotency_key = cleaned_key
  then
    return app_private.damage_report_payload(selected.id);
  end if;

  perform app_private.assert_damage_version(selected, expected_version);

  if selected.status not in ('draft', 'returned')
    or selected.reporter_user_id is distinct from auth.uid()
  then
    raise exception 'damage report cannot be submitted' using errcode = '42501';
  end if;

  if selected.submit_idempotency_key is not null
    and selected.submit_idempotency_key is distinct from cleaned_key
    and selected.status = 'submitted'
  then
    raise exception 'idempotency key already used for a different request'
      using errcode = '23505';
  end if;

  perform app_private.assert_damage_create_auth(
    selected.scenario, selected.godown_id, selected.dispatch_id
  );
  perform app_private.validate_damage_sources(
    selected.scenario, selected.godown_id, selected.receipt_id,
    selected.picking_request_id, selected.dispatch_id, selected.order_id,
    selected.shop_id
  );

  -- Shop-return claim only. Quarantine intake posts on independent verify.
  if app_private.damage_requires_stock_hold(selected.scenario)
    and selected.scenario is distinct from 'shop_return'
  then
    perform app_private.apply_damage_stock_isolation(selected.id);
  end if;

  if not exists (
    select 1 from public.damage_report_lines
    where damage_report_lines.damage_report_id = selected.id
  ) then
    raise exception 'a damage report needs at least one line' using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'submitted',
    submitted_at = pg_catalog.clock_timestamp(),
    submitted_by = auth.uid(),
    submit_idempotency_key = cleaned_key,
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'submitted', selected.status, 'submitted', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'submit_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.submit_damage_report(uuid, integer, text) is
  'Submit draft/returned reports. Storage/loading isolate on submit. Shop-return does not post stock; quarantine intake occurs on verify after custody.';

-- ---------------------------------------------------------------------------
-- 6. Custody on submitted shop_return (GM only; no stock)
-- ---------------------------------------------------------------------------

create or replace function public.confirm_shop_return_custody(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);

  perform app_private.assert_permission('damage.record');
  perform app_private.assert_permission('damage.verify');
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);

  if selected.scenario is distinct from 'shop_return'
    or selected.status is distinct from 'submitted'
  then
    raise exception 'physical custody cannot be confirmed' using errcode = '42501';
  end if;

  -- Salesperson cannot reach this RPC (needs damage.record + damage.verify).
  -- A Godown Manager who created a shop_return may confirm their own report.

  if selected.physical_custody_confirmed_at is not null then
    return app_private.damage_report_payload(selected.id);
  end if;

  update public.damage_reports
  set
    physical_custody_confirmed_at = pg_catalog.clock_timestamp(),
    physical_custody_confirmed_by = auth.uid(),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'custody_confirmed', selected.status, selected.status, '{}'::jsonb
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.confirm_shop_return_custody(uuid, integer) is
  'GM confirms physical receipt of submitted shop-return goods. Requires damage.record+damage.verify. No stock posting. Idempotent when already confirmed.';

-- ---------------------------------------------------------------------------
-- 7. Verify posts shop_return quarantine intake once
-- ---------------------------------------------------------------------------

create or replace function public.verify_damage_report(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be verified' using errcode = '42501';
  end if;

  if selected.reporter_user_id is not distinct from auth.uid() then
    raise exception 'the reporter cannot verify this damage report' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.damage_evidence
    where damage_evidence.damage_report_id = selected.id
      and damage_evidence.verified_at is not null
  ) then
    raise exception 'photographic evidence is required' using errcode = '23514';
  end if;

  if selected.scenario = 'shop_return' then
    if selected.physical_custody_confirmed_at is null
      or selected.physical_custody_confirmed_by is null
    then
      raise exception 'shop-return damage requires confirmed physical custody'
        using errcode = '23514';
    end if;

    -- Post quarantine intake exactly once (existing holds short-circuit).
    perform app_private.apply_damage_stock_isolation(selected.id);
  end if;

  if app_private.damage_requires_stock_hold(selected.scenario)
    and not exists (
      select 1 from public.damage_stock_holds
      where damage_report_id = selected.id
        and status in ('active', 'transferred')
    )
  then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.damage_report_lines
    where damage_report_id = selected.id
      and quantity_cases is distinct from (
        select coalesce(sum(damage_stock_holds.quantity_cases), 0)
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_line_id = damage_report_lines.id
          and damage_stock_holds.status in ('active', 'transferred')
      )
      and app_private.damage_requires_stock_hold(selected.scenario)
  ) then
    raise exception 'verified quantities cannot exceed isolated quantities'
      using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'verified',
    verifier_user_id = auth.uid(),
    verified_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'verified', selected.status, 'verified', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'verify_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.verify_damage_report(uuid, integer) is
  'Independent verification. Shop-return posts quarantine intake once after custody. Reporter cannot self-verify. Storage/loading still require holds from submit.';