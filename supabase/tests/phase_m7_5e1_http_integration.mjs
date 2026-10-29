/**
 * M7.5E.1 local HTTP proofs for credit-adjustment previews.
 * Replica-enables dual-write only to seed one dispatch, then restores flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m75e1"
const PREFIX = "m75e1http"
const RUN = Date.now().toString(36)
const WATERMARK = "CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE"

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

function denied(error) {
  return /permission denied|not authorized/i.test(error.message)
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M75E1 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M75E1 Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M75E1 Godown"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M75E1 Other GM"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M75E1 Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M75E1 Driver"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M75E1 Admin', true),
    ('${users.accounts}', 'M75E1 Accounts', true),
    ('${users.godown}', 'M75E1 Godown', true),
    ('${users.other}', 'M75E1 Other GM', true),
    ('${users.keeper}', 'M75E1 Keeper', true),
    ('${users.driver}', 'M75E1 Driver', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.other}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const other = await signIn(env.ANON_KEY, `other.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M75E1 QA",
})
const otherBranch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_x_${RUN}`,
  branch_name: "M75E1 other",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.driver, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.other, target_branch: otherBranch })
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
  product_name: "M75E1 Soap with a deliberately long product description for wrapping",
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
  shop_name: `M75E1 shop ${RUN}`,
  shop_phone: "9876543210",
  shop_address: "14 Return Street",
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
    null, 'M75E1-HTTP', null, '2028-06-01'
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
    select order_line_id || ',' || product_id || ',' || lot_id || ',' || crate_id || ',' ||
           shipped_cases || ',' || billed_units_per_case || ',' || unit_amount
    from public.invoice_note_lines
    where invoice_note_id = '${reviewed.id}'
    order by line_no
    limit 1
  `)
  const [orderLineId, productId, lotId, crateId, shipped, billedPerCase, unitAmount] = line.split(",")
  const creditedCases = 1
  const expectedQty = creditedCases * Number(billedPerCase)
  const expectedSubtotal = Number((expectedQty * Number(unitAmount)).toFixed(2))

  const returnId = firstUuid(
    await psql(`
      select set_config('app.delivery_return_write', 'on', false);
      insert into public.stock_delivery_returns (
        dispatch_id, branch_id, return_number, status, created_by
      )
      values (
        '${header.id}'::uuid, '${branch}'::uuid, 'RET-E1-${RUN}', 'awaiting_handback', '${users.admin}'::uuid
      )
      returning id;
    `),
  )

  try {
    await rpc(accounts, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-unv-${RUN}`,
      p_expected_version: 1,
    })
    throw new Error("unverified return must be rejected")
  } catch (error) {
    if (!/verified posted or closed-missing/i.test(error.message)) throw error
  }
  ok("unverified return is rejected")

  try {
    await rpc(accounts, "prepare_credit_adjustment", {
      p_return_id: "00000000-0000-4000-8000-000000000001",
      p_idempotency_key: `${PREFIX}-miss-${RUN}`,
      p_expected_version: 1,
    })
    throw new Error("missing return must be rejected")
  } catch (error) {
    if (!/not found|verified return not found/i.test(error.message)) throw error
  }
  ok("missing source return is rejected")

  await psql(`
    select set_config('app.delivery_return_write', 'on', false);
    update public.stock_delivery_returns
    set
      status = 'closed_missing',
      counted_at = clock_timestamp(),
      counted_by = '${users.admin}'::uuid,
      closed_at = clock_timestamp(),
      closed_by = '${users.accounts}'::uuid
    where id = '${returnId}'::uuid;
    insert into public.stock_delivery_return_lots (
      return_id, order_line_id, product_id, lot_id, source_crate_id,
      dispatched_cases, delivered_cases, saleable_cases, damaged_cases, uncertain_cases, missing_cases
    )
    values (
      '${returnId}'::uuid, '${orderLineId}'::uuid, '${productId}'::uuid, '${lotId}'::uuid, '${crateId}'::uuid,
      ${Number(shipped)}, 0, ${creditedCases}, 0, 0, 0
    );
    select set_config('app.delivery_return_write', 'off', false);
  `)

  const ledgerBefore = await psql("select count(*) from public.stock_ledger")

  try {
    await rpc(godown, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-gm-${RUN}`,
      p_expected_version: 1,
    })
    throw new Error("godown manager must be denied")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("godown manager cannot prepare credit adjustments")

  try {
    await rpc(driver, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-drv-${RUN}`,
      p_expected_version: 1,
    })
    throw new Error("driver must be denied")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("delivery person cannot prepare credit adjustments")

  try {
    await rpc(other, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-x-${RUN}`,
      p_expected_version: 1,
    })
    throw new Error("cross-godown manager must be denied")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("cross-godown credit adjustment is denied")

  const preview = await rpc(accounts, "prepare_credit_adjustment", {
    p_return_id: returnId,
    p_idempotency_key: `${PREFIX}-ca-${RUN}`,
    p_expected_version: 1,
  })
  if (preview.watermark !== WATERMARK) throw new Error("watermark missing")
  if (preview.legal_credit_note_number != null) throw new Error("legal credit-note number must stay null")
  if (preview.legal_issuance_blocked !== true) throw new Error("legal issuance must stay blocked")
  if (preview.status !== "preview") throw new Error("status must stay preview-only")
  if (Number(preview.credited_cases) !== creditedCases) throw new Error("credited cases drifted")
  if (Number(preview.credited_quantity) !== expectedQty) throw new Error("billed quantity drifted")
  if (Number(preview.subtotal_amount) !== expectedSubtotal) {
    throw new Error(`subtotal ${preview.subtotal_amount} <> independent ${expectedSubtotal}`)
  }
  if (Number(preview.lines[0].unit_amount) !== Number(unitAmount)) {
    throw new Error("historical unit price was not preserved")
  }
  if (!["tax_unavailable", "tax_stale", "tax_incomplete", "tax_preview"].includes(preview.tax_preview_state)) {
    throw new Error(`unexpected tax state ${preview.tax_preview_state}`)
  }
  if (preview.tax_preview_state !== "tax_preview" && Number(preview.tax_amount) !== 0) {
    throw new Error("missing tax must not invent tax amounts")
  }
  if (!preview.blockers?.some((row) => row.code === "gst_credit_note_disabled")) {
    throw new Error("gst credit-note blocker missing")
  }
  ok("accounts can prepare a preview-only credit adjustment")

  const retry = await rpc(accounts, "prepare_credit_adjustment", {
    p_return_id: returnId,
    p_idempotency_key: `${PREFIX}-ca-${RUN}`,
    p_expected_version: 1,
  })
  if (retry.id !== preview.id) throw new Error("duplicate key must be idempotent")
  if (Number(retry.subtotal_amount) !== expectedSubtotal) {
    throw new Error("retry must preserve original financial values")
  }
  ok("duplicate request is idempotent")

  const listed = await rpc(accounts, "list_credit_adjustments", { p_status: null, p_branch_id: null })
  if (!listed.some((row) => row.id === preview.id)) throw new Error("list must include the preview")
  ok("accounts can list credit-adjustment previews")

  try {
    await rpc(driver, "get_credit_adjustment", { p_adjustment_id: preview.id })
    throw new Error("driver must not read credit adjustments")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("unauthorized roles cannot read credit adjustments")

  const ledgerAfter = await psql("select count(*) from public.stock_ledger")
  if (ledgerBefore !== ledgerAfter) throw new Error("credit adjustment must not write stock")
  const readiness = await rpc(accounts, "assess_invoice_finalization_readiness", {
    p_invoice_note_id: reviewed.id,
  })
  if (readiness.ready !== false || readiness.legal_issuance_blocked !== true) {
    throw new Error("credit adjustment must not enable issuance")
  }
  ok("stock and statutory issuance remain untouched")
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

console.log(`M7.5E.1 HTTP passed ${passed.length} checks`)
