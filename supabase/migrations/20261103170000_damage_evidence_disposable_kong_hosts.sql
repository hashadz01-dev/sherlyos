-- DMG-03E.1: Allowlist disposable Kong hostnames for private evidence byte
-- fetch. Finalize still compares Storage bytes to the client payload through
-- the trusted RPC; this only expands reachability for isolated local stacks
-- (m82c) where the DB container may not resolve the generic kong alias.
-- Does not weaken MIME/size checks, ownership, or private-bucket policies.

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
  stored bytea;
  declared_length bigint;
  content_type text;
  header_row extensions.http_header;
  bases text[] := array[
    'http://kong:8000',
    'http://supabase_kong_sherlyos:8000',
    'http://supabase_kong_sherlyos_m82c:8000',
    'http://supabase_kong_sherlyos_m81c:8000',
    'https://ypkfondrkhkydkgovwup.supabase.co'
  ];
begin
  -- Path is taken from damage_evidence.storage_path, never from the client.
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

  -- Only set options this pgsql-http / libcurl build accepts. Do not set
  -- CURLOPT_FOLLOWLOCATION; Storage object GETs use absolute allowlisted URLs.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

  foreach base_url in array bases
  loop
    declared_length := null;
    content_type := null;
    stored := null;
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
      content_type := pg_catalog.lower(coalesce(response.content_type, ''));
      if content_type like '%json%' or content_type like '%text/%' then
        continue;
      end if;

      stored := extensions.text_to_bytea(response.content);
      if stored is null
        or pg_catalog.octet_length(stored) < 3
        or pg_catalog.octet_length(stored) > 10485760
      then
        stored := null;
        continue;
      end if;

      if response.headers is not null then
        foreach header_row in array response.headers
        loop
          if pg_catalog.lower(header_row.field) in ('content-length', 'contentlength') then
            begin
              declared_length := btrim(header_row.value)::bigint;
            exception
              when others then
                declared_length := null;
            end;
          end if;
        end loop;
      end if;

      if declared_length is not null
        and declared_length is distinct from pg_catalog.octet_length(stored)
      then
        stored := null;
        continue;
      end if;

      perform extensions.http_reset_curlopt();
      return stored;
    end if;
  end loop;

  perform extensions.http_reset_curlopt();
  return null;
end;
$$;

revoke all on function app_private.damage_storage_object_bytes(text)
  from public, anon, authenticated, service_role;

comment on function app_private.damage_storage_object_bytes(text) is
  'Fetches private stock-damage-evidence bytes via allowlisted Kong/Storage hosts for finalize compare. Never trusts client bytes alone.';
