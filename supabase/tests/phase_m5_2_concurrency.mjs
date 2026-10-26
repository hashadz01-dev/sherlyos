/**
 * M5.2 two-session proof: concurrent verify cannot double-verify.
 * Local Docker only. Restores cutover flags in cleanup.
 */
import { spawn } from "node:child_process"

const RUN = Date.now().toString(36)
const PREFIX = `m52c_${RUN}`

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
    do $$
    declare
      admin_id uuid;
      keeper_id uuid;
      godown_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      supplier_id uuid;
      posted_receipt uuid;
      receipt_line uuid;
      report_id uuid;
      created jsonb;
      payload bytea := decode('ffd8ffd9', 'hex');
    begin
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      select
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        email, extensions.crypt('local-only', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('full_name', email), now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      from (values
        ('admin.${PREFIX}@example.com'),
        ('keeper.${PREFIX}@example.com'),
        ('godown.${PREFIX}@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.${PREFIX}@example.com';
      select id into keeper_id from auth.users where email = 'keeper.${PREFIX}@example.com';
      select id into godown_id from auth.users where email = 'godown.${PREFIX}@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M52C Admin', true),
        (keeper_id, 'M52C Keeper', true),
        (godown_id, 'M52C Godown', true)
      on conflict (id) do update set is_active = true;

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
          on conflict do nothing;
      end;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select keeper_id, roles.id, admin_id from public.roles where roles.code = 'store_keeper'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      branch_id := public.create_branch('${PREFIX}', 'M52C');
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      zone_id := public.create_zone(branch_id, 'z', 'Z', null);
      crate_id := public.create_crate(zone_id, 'c', 'C', null);
      product_id := public.create_product('${PREFIX}-sku', 'M52C soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      supplier_id := public.create_supplier('${PREFIX} supplier', null, null);

      update public.app_configuration set value = 'false'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');

      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', keeper_id, 'role', 'authenticated')::text,
        true
      );

      posted_receipt := (public.create_stock_receipt(
        branch_id, supplier_id, '${PREFIX}-inv', current_date, null,
        jsonb_build_array(jsonb_build_object(
          'product_id', product_id,
          'destination_crate_id', crate_id,
          'document_cases', 4,
          'counted_cases', 3,
          'damaged_cases', 2
        ))
      ) ->> 'id')::uuid;
      perform public.submit_stock_receipt(posted_receipt);

      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
        true
      );
      perform public.verify_stock_receipt(posted_receipt, '${PREFIX}-recv');
      select stock_receipt_lines.id into receipt_line
      from public.stock_receipt_lines
      where stock_receipt_lines.receipt_id = posted_receipt;

      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', keeper_id, 'role', 'authenticated')::text,
        true
      );
      report_id := (public.create_damage_report(
        'refill_supply', branch_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', product_id,
          'quantity_cases', 1,
          'damage_reason', 'crushed',
          'receipt_line_id', receipt_line
        )),
        '${PREFIX}-dmg', null, posted_receipt
      ) ->> 'id')::uuid;
      perform public.submit_damage_report(report_id, 1, '${PREFIX}-sub');

      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
        true
      );
      created := public.create_damage_photo_upload(report_id, 'sheet');
      perform set_config('app.damage_write', 'on', true);
      update public.damage_evidence
      set
        mime_type = 'image/jpeg',
        file_size = octet_length(payload),
        verified_at = clock_timestamp()
      where id = (created ->> 'id')::uuid;
    end $$;
  `)
  ids.godown = lastLine(
    await psql(
      `select id from auth.users where email = 'godown.${PREFIX}@example.com'`,
    ),
  )
  ids.report = lastLine(
    await psql(`
    select id from public.damage_reports
    where idempotency_key = '${PREFIX}-dmg'
  `),
  )
  ids.product = lastLine(
    await psql(`select id from public.products where sku = '${PREFIX}-sku'`),
  )
  ids.ledger = lastLine(
    await psql(`
    select count(*) from public.stock_ledger
    where product_id = '${ids.product}'::uuid
  `),
  )
}

function verifySession(label) {
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
      select set_config('request.jwt.claim.sub', '${ids.godown}', true);
      select set_config(
        'request.jwt.claims',
        json_build_object('sub', '${ids.godown}'::uuid, 'role', 'authenticated')::text,
        true
      );
      select pg_sleep(0.2);
      select public.verify_damage_report('${ids.report}'::uuid, 2);
      commit;
    `)
  })
}

try {
  await setup()
  if (!ids.godown || !ids.report)
    throw new Error(`setup missing ids ${JSON.stringify(ids)}`)

  const [a, b] = await Promise.all([verifySession("a"), verifySession("b")])
  const texts = [a, b]
  const wins = texts.filter((row) => row.code === 0)
  const losses = texts.filter((row) => row.code !== 0)
  if (wins.length !== 1 || losses.length !== 1) {
    throw new Error(
      `expected one verify win and one conflict: ${JSON.stringify(texts)}`,
    )
  }
  if (
    !/changed by someone else|cannot be verified|PT409/i.test(losses[0].text)
  ) {
    throw new Error(`loser was not a conflict: ${losses[0].text}`)
  }
  const status = lastLine(
    await psql(
      `select status from public.damage_reports where id = '${ids.report}'`,
    ),
  )
  if (status !== "verified") throw new Error(`expected verified, got ${status}`)
  const ledgerBefore = Number(ids.ledger || 0)
  const ledgerAfter = Number(
    await psql(`
    select count(*) from public.stock_ledger where product_id = '${ids.product}'::uuid
  `),
  )
  if (ledgerAfter !== ledgerBefore) {
    throw new Error(
      `verify must not write ledger ${ledgerBefore} -> ${ledgerAfter}`,
    )
  }
  console.log("PASS concurrent verify serializes to a single verified report")
} finally {
  await psql(`
    set session_replication_role = replica;
    update public.stock_ledger set lot_id = null
    where product_id = '${ids.product || "00000000-0000-0000-0000-000000000000"}'::uuid;
    delete from public.stock_balances
    where product_id = '${ids.product || "00000000-0000-0000-0000-000000000000"}'::uuid;
    delete from public.stock_lot_balances
    where lot_id in (
      select id from public.stock_lots
      where product_id = '${ids.product || "00000000-0000-0000-0000-000000000000"}'::uuid
    );
    delete from public.stock_lots
    where product_id = '${ids.product || "00000000-0000-0000-0000-000000000000"}'::uuid;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
  `)
}
