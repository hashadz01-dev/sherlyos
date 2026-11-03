-- Allow reporters (and site verifiers) to discard evidence on editable
-- reports. Finalized photos stay immutable after verify / cancel / reject.
-- Storage bytes are removed with the catalog row so a wrong attach can be
-- replaced before submit or godown verification.

create or replace function app_private.guard_damage_evidence()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    -- Trusted discard_damage_photo only. Direct table deletes stay blocked.
    if pg_catalog.current_setting('app.damage_evidence_discard', true)
      is distinct from 'on'
    then
      raise exception 'damage evidence cannot be deleted' using errcode = '42501';
    end if;
    return old;
  end if;

  if old.verified_at is not null then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  if new.damage_report_id is distinct from old.damage_report_id
    or new.storage_path is distinct from old.storage_path
    or new.uploaded_by is distinct from old.uploaded_by
    or new.uploaded_at is distinct from old.uploaded_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  return new;
end;
$$;

create or replace function public.discard_damage_photo(target_evidence uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  evidence public.damage_evidence;
  manager_discard boolean;
  was_finalized boolean;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform set_config('app.damage_write', 'on', true);
  perform set_config('app.damage_evidence_discard', 'on', true);

  select *
  into evidence
  from public.damage_evidence
  where damage_evidence.id = target_evidence
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  selected := app_private.lock_damage_report(evidence.damage_report_id);
  manager_discard := app_private.has_permission('damage.verify')
    and app_private.can_work_at_branch(selected.godown_id);

  if selected.status not in ('draft', 'returned', 'submitted') then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  if not manager_discard
    and selected.reporter_user_id is distinct from auth.uid()
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- Reporter may discard own uploads. Verifiers may discard site evidence
  -- before they verify the report.
  if not manager_discard
    and evidence.uploaded_by is distinct from auth.uid()
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  was_finalized := evidence.verified_at is not null;

  delete from storage.objects
  where storage.objects.bucket_id = 'stock-damage-evidence'
    and storage.objects.name = evidence.storage_path;

  delete from public.damage_evidence
  where damage_evidence.id = evidence.id;

  perform app_private.record_damage_event(
    selected.id,
    'evidence_discarded',
    selected.status,
    selected.status,
    pg_catalog.jsonb_build_object(
      'evidence_id', evidence.id,
      'was_finalized', was_finalized
    )
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.discard_damage_photo(uuid) is
  'Discard private damage photo evidence on draft, returned, or submitted reports. Verified reports keep evidence immutable.';

revoke all on function public.discard_damage_photo(uuid)
  from public, anon, service_role;
grant execute on function public.discard_damage_photo(uuid) to authenticated;
