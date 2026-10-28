/**
 * M7.5C.2 real two-session price-window races (default and shop-specific).
 * Repeated. Does not delete leftover historical overlaps.
 */
import { spawn } from "node:child_process"

const PREFIX = `m75c2c_${Date.now().toString(36)}`
const PASSWORD = "local-only-m75c2c"

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
      jsonb_build_object('full_name', 'M75C2 conc'), now(), now(),
      replace(gen_random_uuid()::text, '-', '') || 'c',
      replace(gen_random_uuid()::text, '-', '') || 'r',
      replace(gen_random_uuid()::text, '-', '') || 'n',
      replace(gen_random_uuid()::text, '-', '') || 'e',
      replace(gen_random_uuid()::text, '-', '') || 'a',
      ''
    );
    insert into public.profiles (id, full_name, is_active)
    values (admin_id, 'M75C2 conc', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
    on conflict do nothing;
    insert into public.products (sku, name, is_active)
    values ('${PREFIX}-sku', 'M75C2 conc product', true);
    insert into public.shops (name, is_active)
    values ('${PREFIX}-shop', true);
  end;
  $$;
`)

const productId = (await psql(`select id from public.products where sku = '${PREFIX}-sku'`)).trim()
const shopId = (await psql(`select id from public.shops where name = '${PREFIX}-shop'`)).trim()

function upsertSql(amount, shop) {
  const shopSql = shop ? `'${shop}'::uuid` : "null"
  return `
begin;
select set_config('request.jwt.claim.sub',
  (select id::text from auth.users where email = 'admin.${PREFIX}@example.com'), true);
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text
   from auth.users where email = 'admin.${PREFIX}@example.com'), true);
set local role authenticated;
select public.upsert_product_selling_price(
  '${productId}'::uuid, ${shopSql}, ${amount}, current_date, null, null
);
commit;
`
}

async function raceOnce(label, shop) {
  const races = await Promise.allSettled([upsertSql(10, shop), upsertSql(11, shop)].map((sql) => psql(sql)))
  const wins = races.filter((row) => row.status === "fulfilled").length
  const losses = races.filter((row) => row.status === "rejected").length
  if (wins !== 1 || losses !== 1) {
    throw new Error(`${label}: expected 1 winner, got wins=${wins} losses=${losses}`)
  }
  ok(label)
}

for (let i = 1; i <= 3; i += 1) {
  await psql(`
    begin;
    select set_config('app.invoice_write', 'on', true);
    update public.product_selling_prices
    set is_active = false
    where product_id = '${productId}'::uuid
      and shop_id is null
      and is_active;
    commit;
  `)
  await raceOnce(`default overlapping prices attempt ${i} serialize to one winner`, null)
}

await raceOnce("shop-specific overlapping prices serialize to one winner", shopId)

const flags = await psql(`
  select string_agg(key || '=' || value::text, ',')
  from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  )
`)
if (/true/i.test(flags)) throw new Error(`operational flags must stay false: ${flags}`)
ok("concurrency harness left operational flags false")

console.log(`M7.5C.2 concurrency passed ${passed.length} checks`)
