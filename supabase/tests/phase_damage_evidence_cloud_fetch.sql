-- Prove the development cloud Storage host is allowlisted for damage
-- finalize fetch, and that CURLOPT_FOLLOWLOCATION is not configured
-- (pgsql-http 1.6 rejects that option at runtime).
-- Transaction rolls back. Does not upload bytes or flip flags.
-- Run: Get-Content supabase/tests/phase_damage_evidence_cloud_fetch.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

begin;

do $$
declare
  def text;
begin
  select pg_get_functiondef(p.oid)
  into def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app_private'
    and p.proname = 'damage_storage_object_bytes';

  if def is null then
    raise exception 'damage_storage_object_bytes is missing';
  end if;

  if position('http://kong:8000' in def) = 0 then
    raise exception 'local Kong fetch host missing';
  end if;

  if position('https://ypkfondrkhkydkgovwup.supabase.co' in def) = 0 then
    raise exception 'development cloud Storage fetch host missing';
  end if;

  if position('CURLOPT_FOLLOWLOCATION' in def) > 0 then
    raise exception 'CURLOPT_FOLLOWLOCATION must not be set; pgsql-http rejects it';
  end if;

  if position('CURLOPT_TIMEOUT_MS' in def) = 0 then
    raise exception 'CURLOPT_TIMEOUT_MS must remain configured';
  end if;
end $$;

-- Runtime proof: FOLLOWLOCATION is rejected by this extension build.
do $$
begin
  begin
    perform extensions.http_set_curlopt('CURLOPT_FOLLOWLOCATION', '1');
    perform extensions.http_reset_curlopt();
    raise exception 'expected CURLOPT_FOLLOWLOCATION to be unavailable';
  exception
    when others then
      if sqlerrm not ilike '%CURLOPT_FOLLOWLOCATION%'
        and sqlerrm not ilike '%not available%'
      then
        raise;
      end if;
  end;
  perform extensions.http_reset_curlopt();
end $$;

rollback;
