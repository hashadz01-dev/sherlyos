/**
 * M7.5C.1 concurrency: duplicate open statutory drafts fail closed.
 * Local Docker only. Does not flip operational flags.
 */
import { spawn } from "node:child_process"

const PREFIX = `m75c1c_${Date.now().toString(36)}`
const PASSWORD = "local-only-m75c1c"

function psql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "docker",
      ["exec", "-i", "supabase_db_sherlyos", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"],
      { stdio: ["pipe", "pipe", "pipe"] },
    )
    let output = ""
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    child.stderr.on("data", (chunk) => {
      output += chunk
    })
    child.on("close", (code) => {
      const text = output.trim()
      if (code === 0) resolve(text)
      else reject(new Error(text || `psql exit ${code}`))
    })
    child.stdin.end(sql)
  })
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log("PASS", name)
}

await psql(`
  do $$
  declare
    admin_id uuid := gen_random_uuid();
  begin
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new,
      email_change_token_current, reauthentication_token, email_change
    )
    values (
      '00000000-0000-0000-0000-000000000000', admin_id, 'authenticated', 'authenticated',
      'admin.${PREFIX}@example.com', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', 'M75C1 conc'), now(), now(),
      replace(gen_random_uuid()::text, '-', '') || 'c',
      replace(gen_random_uuid()::text, '-', '') || 'r',
      replace(gen_random_uuid()::text, '-', '') || 'n',
      replace(gen_random_uuid()::text, '-', '') || 'e',
      replace(gen_random_uuid()::text, '-', '') || 'a',
      ''
    );
    insert into public.profiles (id, full_name, is_active)
    values (admin_id, 'M75C1 conc', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
    on conflict do nothing;
    insert into public.products (sku, name, is_active)
    values ('${PREFIX}-sku', 'M75C1 conc product', true);
  end;
  $$;
`)

const productId = (await psql(`select id from public.products where sku = '${PREFIX}-sku'`)).trim()

await psql(`
begin;
select set_config('request.jwt.claim.sub',
  (select id::text from auth.users where email = 'admin.${PREFIX}@example.com'), true);
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.${PREFIX}@example.com'), true);
set local role authenticated;
do $own$
begin
  if public.registered_operating_ownership_code() is null then
    perform public.upsert_statutory_operating_ownership('${PREFIX}', current_date, 1, null);
  end if;
end;
$own$;
commit;
`)

function upsertSql(suffix) {
  return `
begin;
select set_config('request.jwt.claim.sub',
  (select id::text from auth.users where email = 'admin.${PREFIX}@example.com'), true);
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.${PREFIX}@example.com'), true);
set local role authenticated;
select public.upsert_product_hsn_classification(
  '${productId}'::uuid, 'hsn', '190${suffix === "a" ? "5" : "6"}', current_date, 1, null, null
);
commit;
`
}

const races = await Promise.allSettled([psql(upsertSql("a")), psql(upsertSql("b"))])
const wins = races.filter((row) => row.status === "fulfilled").length
const losses = races.filter((row) => row.status === "rejected").length
if (wins !== 1 || losses !== 1) {
  throw new Error(`expected 1 open HSN winner, got wins=${wins} losses=${losses}`)
}
ok("duplicate open HSN classifications serialize to one winner")

const flags = await psql(`
  select string_agg(key || '=' || value::text, ',')
  from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  )
`)
if (/true/i.test(flags)) {
  throw new Error(`operational flags must stay false: ${flags}`)
}
ok("concurrency harness left operational flags false")

console.log(`M7.5C.1 concurrency passed ${passed.length} checks`)
