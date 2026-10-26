-- M5.4B hardening: finalize by comparing the private Storage object bytes
-- to the submitted payload. Catalog eTag/size/MIME are not proof of content.
-- Postgres reads the object through the in-cluster Storage API using the
-- caller's JWT. The uploader may SELECT their own unfinalized object so that
-- fetch can succeed; other users still cannot read pending objects.
-- get_damage_photo_url still requires verified_at. No service-role key is
-- exposed to the browser. Fail closed when the object cannot be fetched.

create extension if not exists http with schema extensions;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'extensions'
      and p.proname in (
        'http', 'http_get', 'http_post', 'http_put', 'http_patch', 'http_delete',
        'http_head', 'http_header', 'http_set_curlopt', 'http_reset_curlopt',
        'http_list_curlopt', 'text_to_bytea', 'bytea_to_text', 'urlencode'
      )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end;
$$;

-- Uploader may read back their own pending object so finalize can hash
-- stored bytes. Cross-user and unverified third-party reads stay denied.
create or replace function app_private.can_read_damage_photo(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.damage_evidence
    join public.damage_reports
      on damage_reports.id = damage_evidence.damage_report_id
    where damage_evidence.storage_path = object_name
      and (
        (
          damage_evidence.verified_at is not null
          and app_private.can_view_damage_report(
            damage_reports.godown_id,
            damage_reports.scenario,
            damage_reports.reporter_user_id,
            damage_reports.dispatch_id
          )
        )
        or (
          damage_evidence.verified_at is null
          and damage_evidence.uploaded_by = auth.uid()
        )
      )
  );
$$;

revoke all on function app_private.can_read_damage_photo(text)
  from public, anon, service_role;
grant execute on function app_private.can_read_damage_photo(text) to authenticated;

-- Fetch private object bytes from in-cluster Storage. Hosts are allowlisted.
-- Returns null on missing JWT, network error, or non-200 so callers fail closed.
create or replace function app_private.damage_storage_object_bytes(object_path text)
returns bytea
language plpgsql
security definer
set search_path = ''
as $$
declare
  headers jsonb := '{}'::jsonb;
  auth_header text;
  api_key text;
  response extensions.http_response;
  base_url text;
  bases text[] := array[
    'http://kong:8000',
    'http://supabase_kong_sherlyos:8000'
  ];
begin
  if object_path is null
    or object_path !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return null;
  end if;

  begin
    headers := pg_catalog.current_setting('request.headers', true)::jsonb;
  exception
    when others then
      headers := '{}'::jsonb;
  end;

  auth_header := coalesce(
    nullif(headers ->> 'authorization', ''),
    nullif(pg_catalog.current_setting('request.header.authorization', true), '')
  );
  api_key := coalesce(
    nullif(headers ->> 'apikey', ''),
    nullif(pg_catalog.current_setting('request.header.apikey', true), '')
  );

  if auth_header is null or btrim(auth_header) = '' then
    return null;
  end if;
  if auth_header not like 'Bearer %' then
    auth_header := 'Bearer ' || auth_header;
  end if;
  if api_key is null or btrim(api_key) = '' then
    api_key := pg_catalog.replace(auth_header, 'Bearer ', '');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

  foreach base_url in array bases
  loop
    begin
      select *
      into response
      from extensions.http((
        'GET',
        base_url || '/storage/v1/object/stock-damage-evidence/' || object_path,
        array[
          extensions.http_header('Authorization', auth_header),
          extensions.http_header('apikey', api_key)
        ],
        null,
        null
      )::extensions.http_request);
    exception
      when others then
        response := null;
    end;

    if response.status = 200 and response.content is not null then
      perform extensions.http_reset_curlopt();
      return extensions.text_to_bytea(response.content);
    end if;
  end loop;

  perform extensions.http_reset_curlopt();
  return null;
end;
$$;

revoke all on function app_private.damage_storage_object_bytes(text)
  from public, anon, authenticated, service_role;

create or replace function public.finalize_damage_photo_upload(
  target_evidence uuid,
  image_base64 text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  evidence public.damage_evidence;
  cleaned text;
  payload bytea;
  stored bytea;
  object_owner uuid;
  detected_mime text;
begin
  perform set_config('app.damage_write', 'on', true);

  select *
  into evidence
  from public.damage_evidence
  where damage_evidence.id = target_evidence
  for update;

  if not found or evidence.uploaded_by is distinct from auth.uid() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  selected := app_private.lock_damage_report(evidence.damage_report_id);

  if selected.status not in ('draft', 'returned', 'submitted')
    or evidence.verified_at is not null
  then
    raise exception 'damage evidence cannot be changed' using errcode = '42501';
  end if;

  cleaned := pg_catalog.replace(pg_catalog.btrim(coalesce(image_base64, '')), E'\n', '');
  if cleaned like 'data:%' then
    cleaned := pg_catalog.split_part(cleaned, ',', 2);
  end if;

  if cleaned = '' or pg_catalog.char_length(cleaned) > 14000000 then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  begin
    payload := pg_catalog.decode(cleaned, 'base64');
  exception
    when others then
      raise exception 'photo content could not be verified' using errcode = '23514';
  end;

  if payload is null
    or pg_catalog.octet_length(payload) < 3
    or pg_catalog.octet_length(payload) > 10485760
  then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  detected_mime := app_private.detected_image_mime(payload);
  if detected_mime is null then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  -- Catalog row is ownership corroboration only. It is not byte proof.
  select storage.objects.owner
  into object_owner
  from storage.objects
  where storage.objects.bucket_id = 'stock-damage-evidence'
    and storage.objects.name = evidence.storage_path;

  if not found then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  if object_owner is not null and object_owner is distinct from evidence.uploaded_by then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  stored := app_private.damage_storage_object_bytes(evidence.storage_path);

  -- Require the actual private object bytes. Client base64, hashes, MIME,
  -- sizes, and catalog eTags are not treated as stored content.
  if stored is null or stored is distinct from payload then
    raise exception 'photo content could not be verified' using errcode = '23514';
  end if;

  update public.damage_evidence
  set
    mime_type = detected_mime,
    file_size = pg_catalog.octet_length(stored),
    verified_at = pg_catalog.clock_timestamp()
  where damage_evidence.id = evidence.id;

  perform app_private.record_damage_event(
    selected.id, 'evidence_attached', selected.status, selected.status,
    pg_catalog.jsonb_build_object(
      'evidence_id', evidence.id,
      'mime_type', detected_mime
    )
  );
end;
$$;
