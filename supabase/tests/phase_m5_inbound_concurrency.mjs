/**
 * Two concurrent DMG-01 drafts cannot both claim the same 2 damaged cases.
 * Local Docker only. Leaves cutover flags unchanged.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m5inc_${RUN}`

function psql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "docker",
      [
        "exec",
        "-i",
        "supabase_db_sherlyos",
        "psql",
        "-U",
        "postgres",
        "-d",
        "postgres",
        "-v",
        "ON_ERROR_STOP=1",
        "-tA",
      ],
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

function lastLine(text) {
  return String(text).split(/\r?\n/).filter(Boolean).at(-1)
}

const ids = {}

async function setup() {
  await psql(`
    begin;
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    )
    values (
      '00000000-0000-0000-0000-000000000000', gen_random_uuid(),
      'authenticated', 'authenticated', 'keeper.${PREFIX}@example.com',
      extensions.crypt('local-only', extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', 'keeper'), now(), now()
    );
    insert into public.profiles (id, full_name, is_active)
    select id, 'keeper', true from auth.users where email = 'keeper.${PREFIX}@example.com'
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select auth.users.id, roles.id, auth.users.id
    from auth.users, public.roles
    where auth.users.email = 'keeper.${PREFIX}@example.com'
      and roles.code = 'store_keeper';
    set session_replication_role = replica;
    insert into public.branches (code, name, is_active)
    values ('${PREFIX}_gd', 'M5 inbound race godown', true);
    insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
    select auth.users.id, branches.id, auth.users.id
    from auth.users, public.branches
    where auth.users.email = 'keeper.${PREFIX}@example.com'
      and branches.code = '${PREFIX}_gd';
    insert into public.zones (branch_id, code, name, is_active)
    select id, '${PREFIX}_z', 'zone', true from public.branches where code = '${PREFIX}_gd';
    insert into public.crates (zone_id, code, name, is_active)
    select id, '${PREFIX}_c', 'crate', true from public.zones where code = '${PREFIX}_z';
    insert into public.products (sku, name, is_active)
    values ('${PREFIX}_sku', 'race product', true);
    insert into public.suppliers (name, is_active)
    values ('${PREFIX} supplier', true);
    insert into public.stock_balances (crate_id, product_id, quantity)
    select crates.id, products.id, 8
    from public.crates, public.products
    where crates.code = '${PREFIX}_c' and products.sku = '${PREFIX}_sku';
    insert into public.stock_receipts (
      receipt_number, godown_id, supplier_id, document_reference,
      normalized_document_reference, received_date, status, created_by,
      verified_by, verified_at, posted_at, posting_idempotency_key, posting_fingerprint
    )
    select
      '${PREFIX}-rcv', branches.id, suppliers.id, '${PREFIX}-doc', '${PREFIX}-doc',
      current_date, 'posted', auth.users.id, auth.users.id, now(), now(),
      '${PREFIX}-post', '${PREFIX}-fp'
    from public.branches, public.suppliers, auth.users
    where branches.code = '${PREFIX}_gd'
      and suppliers.name = '${PREFIX} supplier'
      and auth.users.email = 'keeper.${PREFIX}@example.com';
    insert into public.stock_receipt_lines (
      receipt_id, product_id, destination_crate_id, document_cases, counted_cases, damaged_cases
    )
    select stock_receipts.id, products.id, crates.id, 10, 10, 2
    from public.stock_receipts, public.products, public.crates
    where stock_receipts.receipt_number = '${PREFIX}-rcv'
      and products.sku = '${PREFIX}_sku'
      and crates.code = '${PREFIX}_c';
    set session_replication_role = origin;
    commit;
  `)
  ids.keeper = lastLine(
    await psql(
      `select id from auth.users where email = 'keeper.${PREFIX}@example.com'`,
    ),
  )
  ids.branch = lastLine(
    await psql(`select id from public.branches where code = '${PREFIX}_gd'`),
  )
  ids.receipt = lastLine(
    await psql(
      `select id from public.stock_receipts where receipt_number = '${PREFIX}-rcv'`,
    ),
  )
  ids.line = lastLine(
    await psql(`
      select id from public.stock_receipt_lines
      where receipt_id = '${ids.receipt}'::uuid
    `),
  )
  ids.product = lastLine(
    await psql(`select id from public.products where sku = '${PREFIX}_sku'`),
  )
}

function createSession(label) {
  return new Promise((resolve) => {
    const child = spawn(
      "docker",
      [
        "exec",
        "-i",
        "supabase_db_sherlyos",
        "psql",
        "-U",
        "postgres",
        "-d",
        "postgres",
        "-v",
        "ON_ERROR_STOP=1",
        "-tA",
      ],
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
      resolve({ label, code, text: output.trim() })
    })
    child.stdin.end(`
      begin;
      set local role authenticated;
      select set_config('request.jwt.claim.sub', '${ids.keeper}', true);
      select set_config(
        'request.jwt.claims',
        json_build_object('sub', '${ids.keeper}'::uuid, 'role', 'authenticated')::text,
        true
      );
      select pg_sleep(0.15);
      select public.create_damage_report(
        'refill_supply', '${ids.branch}'::uuid,
        jsonb_build_array(jsonb_build_object(
          'product_id', '${ids.product}'::uuid,
          'quantity_cases', 2,
          'damage_reason', 'race ${label}',
          'receipt_line_id', '${ids.line}'::uuid
        )),
        '${PREFIX}-${label}', null, '${ids.receipt}'::uuid
      );
      commit;
    `)
  })
}

async function cleanup() {
  await psql(`
    set session_replication_role = replica;
    delete from public.damage_report_events
    where damage_report_id in (
      select id from public.damage_reports
      where idempotency_key like '${PREFIX}-%'
    );
    delete from public.damage_evidence
    where damage_report_id in (
      select id from public.damage_reports
      where idempotency_key like '${PREFIX}-%'
    );
    delete from public.damage_report_lines
    where damage_report_id in (
      select id from public.damage_reports
      where idempotency_key like '${PREFIX}-%'
    );
    delete from public.damage_reports where idempotency_key like '${PREFIX}-%';
    delete from public.stock_receipt_lines
    where receipt_id in (
      select id from public.stock_receipts where receipt_number = '${PREFIX}-rcv'
    );
    delete from public.stock_receipts where receipt_number = '${PREFIX}-rcv';
    delete from public.stock_balances
    where product_id in (select id from public.products where sku = '${PREFIX}_sku');
    delete from public.crates where code = '${PREFIX}_c';
    delete from public.zones where code = '${PREFIX}_z';
    delete from public.user_branch_assignments
    where branch_id in (select id from public.branches where code = '${PREFIX}_gd');
    delete from public.branches where code = '${PREFIX}_gd';
    delete from public.products where sku = '${PREFIX}_sku';
    delete from public.suppliers where name = '${PREFIX} supplier';
    delete from public.user_roles
    where user_id in (select id from auth.users where email = 'keeper.${PREFIX}@example.com');
    delete from public.profiles
    where id in (select id from auth.users where email = 'keeper.${PREFIX}@example.com');
    delete from auth.users where email = 'keeper.${PREFIX}@example.com';
    set session_replication_role = origin;
  `)
}

try {
  await setup()
  if (!ids.keeper || !ids.receipt || !ids.line) {
    throw new Error(`setup missing ids ${JSON.stringify(ids)}`)
  }
  const [a, b] = await Promise.all([createSession("a"), createSession("b")])
  const wins = [a, b].filter((row) => row.code === 0)
  const losses = [a, b].filter((row) => row.code !== 0)
  if (wins.length !== 1 || losses.length !== 1) {
    throw new Error(
      `expected one create win and one over-claim: ${JSON.stringify([a, b])}`,
    )
  }
  if (!/exceeds the receipt line/i.test(losses[0].text)) {
    throw new Error(`loser was not an over-claim: ${losses[0].text}`)
  }
  const claimed = lastLine(
    await psql(`
      select coalesce(sum(damage_report_lines.quantity_cases), 0)
      from public.damage_report_lines
      join public.damage_reports
        on damage_reports.id = damage_report_lines.damage_report_id
      where damage_reports.idempotency_key like '${PREFIX}-%'
        and damage_reports.status not in ('cancelled', 'rejected')
    `),
  )
  if (Number(claimed) !== 2) {
    throw new Error(`claimed cases must stay 2, got ${claimed}`)
  }
  const onHand = lastLine(
    await psql(`
      select quantity from public.stock_balances
      where product_id = '${ids.product}'::uuid
    `),
  )
  if (Number(onHand) !== 8) {
    throw new Error(`accepted inventory must stay 8, got ${onHand}`)
  }
  console.log("PASS concurrent inbound claims serialize to 2 damaged cases")
} finally {
  await cleanup()
}
