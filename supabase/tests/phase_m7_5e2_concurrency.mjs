/**
 * M7.5E.2 concurrent review uniqueness and synthetic credit-note numbering.
 * Replica-enables dual-write only to seed one dispatch, then restores flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m75e1"
const PREFIX = "m75e2conc"
const RUN = Date.now().toString(36)

function statusEnv() {
  return new Promise((resolve, reject) => {
    const child = spawn("npx", ["supabase", "status", "-o", "env"], { shell: true })
    let output = ""
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    child.stderr.on("data", (chunk) => {
      output += chunk
    })
    child.on("close", (code) => {
      if (code !== 0) reject(new Error(output || "supabase status failed"))
      else {
        const env = {}
        for (const line of output.split(/\r?\n/)) {
          const cut = line.indexOf("=")
          if (cut < 1) continue
          env[line.slice(0, cut)] = line.slice(cut + 1).replace(/^"|"$/g, "")
        }
        resolve(env)
      }
    })
  })
}

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

function firstUuid(text) {
  return String(text).match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0] ?? ""
}

async function ensureUser(email, fullName) {
  const existing = firstUuid(await psql(`select id from auth.users where email = '${email}'`))
  if (existing) return existing
  return firstUuid(
    await psql(`
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      values (
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        '${email}', extensions.crypt('${PASSWORD}', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('full_name', '${fullName}'), now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      )
      returning id;
    `),
  )
}

async function signIn(anonKey, email) {
  const auth = createClient(API, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const result = await auth.auth.signInWithPassword({ email, password: PASSWORD })
  if (result.error || !result.data.session) {
    throw new Error(`sign-in failed for ${email}: ${result.error?.message ?? "no session"}`)
  }
  return createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${result.data.session.access_token}` } },
  })
}

async function rpc(client, name, args = {}) {
  const result = await client.rpc(name, args)
  if (result.error) {
    const error = new Error(result.error.message)
    error.code = result.error.code
    throw error
  }
  return result.data
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log("PASS", name)
}

const env = await statusEnv()
if (!env.ANON_KEY) throw new Error("local anon key missing")

await psql(`
  update auth.users
  set
    confirmation_token = coalesce(nullif(confirmation_token, ''), id::text || '-c'),
    recovery_token = coalesce(nullif(recovery_token, ''), id::text || '-r'),
    email_change_token_new = coalesce(nullif(email_change_token_new, ''), id::text || '-n'),
    email_change_token_current = coalesce(nullif(email_change_token_current, ''), id::text || '-e'),
    reauthentication_token = coalesce(nullif(reauthentication_token, ''), id::text || '-a'),
    email_change = coalesce(email_change, ''),
    phone_change = coalesce(phone_change, ''),
    phone_change_token = coalesce(phone_change_token, '');
`)

const users = {
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M75E1C Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M75E1C Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M75E1C Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M75E1C Keeper"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M75E1C Admin', true),
    ('${users.accounts}', 'M75E1C Accounts', true),
    ('${users.godown}', 'M75E1C Godown', true),
    ('${users.keeper}', 'M75E1C Keeper', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const accountsB = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M75E1C QA",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
const zone = await rpc(admin, "create_zone", {
  target_branch: branch,
  zone_code: `${PREFIX}_z_${RUN}`,
  zone_name: "Z",
  zone_description: null,
})
const crate = await rpc(admin, "create_crate", {
  target_zone: zone,
  crate_code: `${PREFIX}_c_${RUN}`,
  crate_name: "C",
  crate_description: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`,
  product_name: "M75E1C Soap",
  next_supplier: null,
  next_category: null,
})
await rpc(admin, "set_product_expiry_policy", {
  target_product: product,
  new_policy: "expiry_controlled",
})
await rpc(admin, "set_product_billing_conversion", {
  p_product_id: product,
  p_billing_unit: "nos",
  p_billed_units_per_case: 12,
})
const shop = await rpc(admin, "create_shop", {
  shop_name: `M75E1C shop ${RUN}`,
  shop_phone: "9876543210",
  shop_address: "16 Concurrent Street",
})
await rpc(accounts, "upsert_product_selling_price", {
  p_product_id: product,
  p_shop_id: null,
  p_unit_amount: 10.5,
  p_effective_from: "2020-01-01",
  p_effective_to: null,
  p_price_id: null,
})

await psql(`
  set session_replication_role = replica;
  update public.app_configuration set value = 'true'::jsonb
  where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
  set session_replication_role = origin;
  begin;
  set local role authenticated;
  select set_config('request.jwt.claim.sub', '${users.admin}', true);
  select set_config(
    'request.jwt.claims',
    json_build_object('sub', '${users.admin}'::uuid, 'role', 'authenticated')::text,
    true
  );
  select public.post_opening_stock(
    '${product}'::uuid, '${crate}'::uuid, 6, '${PREFIX}-open-${RUN}',
    null, 'M75E1C', null, '2028-06-01'
  );
  commit;
`)

async function handshake(orderId, prefix) {
  const dn = await rpc(accounts, "create_delivery_note", {
    target_order: orderId,
    idempotency_key: `${prefix}-dn`,
  })
  await rpc(accounts, "generate_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 1,
    idempotency_key: `${prefix}-gen`,
  })
  await rpc(accounts, "send_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 2,
    idempotency_key: `${prefix}-send`,
  })
  await rpc(godown, "acknowledge_delivery_note", {
    target_note: dn.delivery_note.id,
    expected_version: 3,
    idempotency_key: `${prefix}-ack`,
  })
}

async function pickAll(orderId, prefix, expectedOrderVersion) {
  const reserved = await rpc(godown, "reserve_order_allocation", {
    target_order: orderId,
    expected_order_version: expectedOrderVersion,
    idempotency_key: `${prefix}-res`,
  })
  let picking = await rpc(godown, "assign_picking_request", {
    target_request: reserved.id,
    assignee: users.keeper,
    expected_version: reserved.version,
    idempotency_key: `${prefix}-asg`,
  })
  picking = await rpc(godown, "start_picking", {
    target_request: reserved.id,
    expected_version: picking.version,
    idempotency_key: `${prefix}-start`,
  })
  for (const row of picking.reservations) {
    picking = await rpc(keeper, "confirm_picking_quantity", {
      target_request: reserved.id,
      target_reservation: row.id,
      picked_quantity: row.reserved_cases,
      expected_version: picking.version,
      idempotency_key: `${prefix}-pick-${row.id}`,
    })
  }
  picking = await rpc(keeper, "complete_picking", {
    target_request: reserved.id,
    expected_version: picking.version,
    idempotency_key: `${prefix}-done`,
  })
  return rpc(godown, "confirm_picking_handoff", {
    target_request: reserved.id,
    expected_version: picking.version,
    idempotency_key: `${prefix}-ho`,
  })
}

try {
  const created = await rpc(accounts, "create_order", {
    target_shop: shop,
    target_branch: branch,
    order_source: "accounts",
    source_reference: null,
    order_notes: null,
    order_lines: [{ product_id: product, requested_cases: 2 }],
    idempotency_key: `${PREFIX}-ord-${RUN}`,
  })
  await rpc(accounts, "submit_order", {
    target_order: created.order.id,
    expected_version: created.order.version,
    idempotency_key: `${PREFIX}-sub-${RUN}`,
  })
  await rpc(accounts, "verify_order", {
    target_order: created.order.id,
    expected_version: created.order.version + 1,
    idempotency_key: `${PREFIX}-ver-${RUN}`,
  })
  await handshake(created.order.id, `${PREFIX}-hs-${RUN}`)
  const picking = await pickAll(created.order.id, `${PREFIX}-pk-${RUN}`, 3)
  const previewDispatch = await rpc(godown, "preview_dispatch", { target_order: created.order.id })
  let header = await rpc(godown, "prepare_dispatch", {
    target_order: created.order.id,
    expected_picking_version: previewDispatch.picking_version ?? picking.version,
    idempotency_key: `${PREFIX}-prep-${RUN}`,
  })
  header = await rpc(godown, "confirm_dispatch", {
    target_dispatch: header.id,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-cfm-${RUN}`,
  })
  const note = await rpc(godown, "prepare_invoice_note", {
    p_dispatch_id: header.id,
    p_idempotency_key: `${PREFIX}-inv-${RUN}`,
    p_expected_version: 1,
    p_remarks: null,
  })
  const submitted = await rpc(godown, "submit_invoice_note", {
    p_invoice_note_id: note.id,
    p_expected_version: note.version,
  })
  const reviewed = await rpc(accounts, "review_invoice_note", {
    p_invoice_note_id: note.id,
    p_expected_version: submitted.version,
  })
  const line = await psql(`
    select order_line_id || ',' || product_id || ',' || lot_id || ',' || crate_id || ',' || shipped_cases
    from public.invoice_note_lines
    where invoice_note_id = '${reviewed.id}'
    limit 1
  `)
  const [orderLineId, productId, lotId, crateId, shipped] = line.split(",")
  const returnId = firstUuid(
    await psql(`
      select set_config('app.delivery_return_write', 'on', false);
      insert into public.stock_delivery_returns (
        dispatch_id, branch_id, return_number, status, version,
        counted_at, counted_by, closed_at, closed_by, created_by
      )
      values (
        '${header.id}'::uuid, '${branch}'::uuid, 'RET-E1C-${RUN}', 'closed_missing', 1,
        clock_timestamp(), '${users.admin}'::uuid, clock_timestamp(), '${users.accounts}'::uuid, '${users.admin}'::uuid
      )
      returning id;
    `),
  )
  await psql(`
    select set_config('app.delivery_return_write', 'on', false);
    insert into public.stock_delivery_return_lots (
      return_id, order_line_id, product_id, lot_id, source_crate_id,
      dispatched_cases, delivered_cases, saleable_cases, damaged_cases, uncertain_cases, missing_cases
    )
    values (
      '${returnId}'::uuid, '${orderLineId}'::uuid, '${productId}'::uuid, '${lotId}'::uuid, '${crateId}'::uuid,
      ${Number(shipped)}, 0, 1, 0, 0, 0
    );
    select set_config('app.delivery_return_write', 'off', false);
  `)

  const expectedSubtotal = 12 * 10.5
  const [left, right] = await Promise.all([
    rpc(accounts, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-a-${RUN}`,
      p_expected_version: 1,
    }),
    rpc(accountsB, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-b-${RUN}`,
      p_expected_version: 1,
    }),
  ])
  if (left.id !== right.id) throw new Error("concurrent prepares must collapse to one adjustment")
  if (Number(left.subtotal_amount) !== expectedSubtotal || Number(right.subtotal_amount) !== expectedSubtotal) {
    throw new Error("concurrent prepares must keep independent snapshot totals")
  }
  const count = await psql(
    `select count(*) from public.invoice_credit_adjustments where return_id = '${returnId}'`,
  )
  if (count !== "1") throw new Error(`expected 1 adjustment, got ${count}`)
  ok("two simultaneous requests for one return stay unique")

  const retries = await Promise.all(
    Array.from({ length: 4 }, (_, index) =>
      rpc(index % 2 === 0 ? accounts : accountsB, "prepare_credit_adjustment", {
        p_return_id: returnId,
        p_idempotency_key: `${PREFIX}-retry-${RUN}`,
        p_expected_version: 1,
      }),
    ),
  )
  if (retries.some((row) => row.id !== left.id)) throw new Error("concurrent retries must reuse the original row")
  if (retries.some((row) => Number(row.subtotal_amount) !== expectedSubtotal)) {
    throw new Error("concurrent retries must preserve original financial values")
  }
  ok("repeated retry under concurrent load stays snapshot-stable")

  const [approveLeft, approveRight] = await Promise.allSettled([
    rpc(accounts, "review_credit_adjustment", {
      p_adjustment_id: left.id,
      p_decision: "approve",
      p_reason: "Concurrent internal reconciliation A",
      p_expected_version: left.version,
    }),
    rpc(accountsB, "review_credit_adjustment", {
      p_adjustment_id: left.id,
      p_decision: "approve",
      p_reason: "Concurrent internal reconciliation B",
      p_expected_version: left.version,
    }),
  ])
  const approvedRows = [approveLeft, approveRight].filter((row) => row.status === "fulfilled")
  const rejectedRows = [approveLeft, approveRight].filter((row) => row.status === "rejected")
  if (approvedRows.length !== 1 || rejectedRows.length !== 1) {
    throw new Error("exactly one concurrent approve may succeed")
  }
  if (approvedRows[0].value.status !== "approved") {
    throw new Error("winning review must be approved")
  }
  if (Number(approvedRows[0].value.subtotal_amount) !== expectedSubtotal) {
    throw new Error("concurrent review must keep the financial snapshot")
  }
  const reviewedCount = await psql(
    `select count(*) from public.invoice_credit_adjustments where return_id = '${returnId}' and status = 'approved'`,
  )
  if (reviewedCount !== "1") throw new Error(`expected 1 approved adjustment, got ${reviewedCount}`)
  ok("two simultaneous reviews stay unique")

  const fyId = firstUuid(
    await psql(`
      select id from public.invoice_financial_years
      where status = 'verified' and legal_allocation_enabled = false
      order by created_at
      limit 1
    `),
  )
  if (!fyId) throw new Error("verified financial year is required for synthetic numbering")
  const seriesId = firstUuid(
    await psql(`
      select set_config('app.credit_note_numbering_write', 'on', false);
      insert into public.invoice_credit_note_number_series (
        financial_year_id, series_code, prefix, pad_width, is_synthetic, created_by
      )
      values (
        '${fyId}'::uuid, 'PROOF-${PREFIX}', 'PROOF-CN-${PREFIX}', 5, true, '${users.admin}'::uuid
      )
      returning id;
    `),
  )
  if (!seriesId) throw new Error("synthetic credit-note series insert failed")
  function allocateOnce() {
    return psql(`
      begin;
      select set_config('app.credit_note_number_proof', 'on', true);
      select app_private.allocate_synthetic_credit_note_number('${seriesId}'::uuid) ->> 'formatted_number';
      commit;
    `)
  }
  const [numLeft, numRight] = await Promise.all([allocateOnce(), allocateOnce()])
  const numbers = [numLeft, numRight]
    .map((text) => String(text).split(/\s+/).find((value) => value.startsWith("PROOF-CN-")))
    .filter(Boolean)
  if (numbers.length !== 2) throw new Error(`expected two proof credit-note numbers, got ${numLeft} ${numRight}`)
  if (numbers[0] === numbers[1]) throw new Error(`duplicate synthetic credit-note number ${numbers[0]}`)
  ok("synthetic credit-note numbering stays unique and illegal")
} finally {
  await psql(`
    set session_replication_role = replica;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;
  `)
}

console.log(`M7.5E.2 concurrency passed ${passed.length} checks`)
