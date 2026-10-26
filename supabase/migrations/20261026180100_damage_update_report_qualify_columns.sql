-- M5.4B: qualify update_damage_report SET targets.
-- Function parameters share names with damage_reports columns. Unqualified
-- SET expressions raise "column reference is ambiguous" through PostgREST,
-- which blocked draft edits. Signature, grants, and write behavior are unchanged.

create or replace function public.update_damage_report(
  target_report uuid,
  expected_version integer,
  report_lines jsonb,
  notes text default null,
  receipt_id uuid default null,
  picking_request_id uuid default null,
  dispatch_id uuid default null,
  order_id uuid default null,
  shop_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_notes text;
  fingerprint text;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);

  if selected.status not in ('draft', 'returned')
    or selected.reporter_user_id is distinct from auth.uid()
  then
    raise exception 'damage report cannot be changed' using errcode = '42501';
  end if;

  perform app_private.assert_damage_create_auth(
    selected.scenario,
    selected.godown_id,
    coalesce(update_damage_report.dispatch_id, selected.dispatch_id)
  );
  perform app_private.validate_damage_sources(
    selected.scenario,
    selected.godown_id,
    coalesce(update_damage_report.receipt_id, selected.receipt_id),
    coalesce(update_damage_report.picking_request_id, selected.picking_request_id),
    coalesce(update_damage_report.dispatch_id, selected.dispatch_id),
    coalesce(update_damage_report.order_id, selected.order_id),
    coalesce(update_damage_report.shop_id, selected.shop_id)
  );

  cleaned_notes := app_private.clean_verification_text(notes, false);
  fingerprint := app_private.damage_fingerprint(
    selected.scenario,
    selected.godown_id,
    coalesce(update_damage_report.receipt_id, selected.receipt_id),
    coalesce(update_damage_report.picking_request_id, selected.picking_request_id),
    coalesce(update_damage_report.dispatch_id, selected.dispatch_id),
    coalesce(update_damage_report.order_id, selected.order_id),
    coalesce(update_damage_report.shop_id, selected.shop_id),
    cleaned_notes,
    report_lines
  );

  update public.damage_reports as header
  set
    receipt_id = coalesce(update_damage_report.receipt_id, selected.receipt_id),
    picking_request_id = coalesce(
      update_damage_report.picking_request_id, selected.picking_request_id
    ),
    dispatch_id = coalesce(update_damage_report.dispatch_id, selected.dispatch_id),
    order_id = coalesce(update_damage_report.order_id, selected.order_id),
    shop_id = coalesce(update_damage_report.shop_id, selected.shop_id),
    notes = cleaned_notes,
    request_fingerprint = fingerprint,
    version = selected.version + 1
  where header.id = selected.id;

  perform app_private.replace_damage_lines(
    selected.id,
    selected.scenario,
    selected.godown_id,
    coalesce(update_damage_report.receipt_id, selected.receipt_id),
    coalesce(update_damage_report.picking_request_id, selected.picking_request_id),
    coalesce(update_damage_report.dispatch_id, selected.dispatch_id),
    report_lines
  );
  perform app_private.record_damage_event(
    selected.id, 'updated', selected.status, selected.status, '{}'::jsonb
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;
