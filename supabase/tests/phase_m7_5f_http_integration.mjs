/**
 * M7.5F local HTTP proofs for the commercial workflow.
 * Replica-enables dual-write only to seed dispatch, then restores flags
 * before invoice, GST preview, return-adjustment, and review.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m75f"
const PREFIX = "m75fhttp"
const RUN = Date.now().toString(36)
const INVOICE_WATERMARK = "DRAFT INVOICE PREVIEW — NOT A TAX INVOICE"
const CREDIT_WATERMARK = "CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE"

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

function billedQuantity(cases, unitsPerCase) {
  return Number(cases) * Number(unitsPerCase)
}

function lineSubtotal(quantity, unitAmount) {
  return Number((Number(quantity) * Number(unitAmount)).toFixed(2))
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M75F Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M75F Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M75F Godown"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M75F Other GM"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M75F Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M75F Driver"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M75F Admin', true),
    ('${users.accounts}', 'M75F Accounts', true),
    ('${users.godown}', 'M75F Godown', true),
    ('${users.other}', 'M75F Other GM', true),
    ('${users.keeper}', 'M75F Keeper', true),
    ('${users.driver}', 'M75F Driver', true)
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
  branch_name: "M75F QA",
})
const otherBranch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_x_${RUN}`,
  branch_name: "M75F other",
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
const productA = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-a-${RUN}`,
  product_name: "M75F shop-priced soap",
  next_supplier: null,
  next_category: null,
})
const productB = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-b-${RUN}`,
  product_name: "M75F default-priced oil",
  next_supplier: null,
  next_category: null,
})
await rpc(admin, "set_product_expiry_policy", {
  target_product: productA,
  new_policy: "expiry_controlled",
})
await rpc(admin, "set_product_expiry_policy", {
  target_product: productB,
  new_policy: "expiry_controlled",
})
await rpc(admin, "set_product_billing_conversion", {
  p_product_id: productA,
  p_billing_unit: "nos",
  p_billed_units_per_case: 12,
})
await rpc(admin, "set_product_billing_conversion", {
  p_product_id: productB,
  p_billing_unit: "nos",
  p_billed_units_per_case: 6,
})
const shop = await rpc(admin, "create_shop", {
  shop_name: `M75F shop ${RUN}`,
  shop_phone: "9876543210",
  shop_address: "18 Integration Street",
})
await rpc(accounts, "upsert_product_selling_price", {
  p_product_id: productA,
  p_shop_id: null,
  p_unit_amount: 10.5,
  p_effective_from: "2020-01-01",
  p_effective_to: null,
  p_price_id: null,
})
await rpc(accounts, "upsert_product_selling_price", {
  p_product_id: productA,
  p_shop_id: shop,
  p_unit_amount: 11,
  p_effective_from: "2020-01-01",
  p_effective_to: null,
  p_price_id: null,
})
await rpc(accounts, "upsert_product_selling_price", {
  p_product_id: productB,
  p_shop_id: null,
  p_unit_amount: 7.25,
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
    '${productA}'::uuid, '${crate}'::uuid, 6, '${PREFIX}-open-a-${RUN}',
    null, 'M75F-HTTP-A', null, '2028-06-01'
  );
  select public.post_opening_stock(
    '${productB}'::uuid, '${crate}'::uuid, 6, '${PREFIX}-open-b-${RUN}',
    null, 'M75F-HTTP-B', null, '2028-06-01'
  );
  commit;
`)

async function restoreFlags() {
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
    order_lines: [
      { product_id: productA, requested_cases: 2 },
      { product_id: productB, requested_cases: 1 },
    ],
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
  const consumed = await psql(`
    select stock_consumed::text || ',' || coalesce(posted_transaction_id::text, '')
    from public.stock_dispatch_requests
    where id = '${header.id}'
  `)
  if (!/^(t|true),/i.test(String(consumed))) {
    throw new Error(`dispatch must post consumption: ${consumed}`)
  }
  ok("posted DISPATCH consumption is present")

  await restoreFlags()
  const flagsOff = await psql(`
    select count(*) from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  `)
  if (flagsOff !== "0") throw new Error("operational flags must be false before financial RPCs")
  ok("operational flags restored before financial RPCs")

  const retryPrepare = await rpc(godown, "prepare_invoice_note", {
    p_dispatch_id: header.id,
    p_idempotency_key: `${PREFIX}-inv-${RUN}`,
    p_expected_version: 1,
    p_remarks: null,
  })
  const note = await rpc(godown, "prepare_invoice_note", {
    p_dispatch_id: header.id,
    p_idempotency_key: `${PREFIX}-inv-${RUN}`,
    p_expected_version: 1,
    p_remarks: null,
  })
  if (note.id !== retryPrepare.id) throw new Error("invoice-note prepare must be idempotent")
  const submitted = await rpc(godown, "submit_invoice_note", {
    p_invoice_note_id: note.id,
    p_expected_version: note.version,
  })
  const reviewed = await rpc(accounts, "review_invoice_note", {
    p_invoice_note_id: note.id,
    p_expected_version: submitted.version,
  })
  try {
    await rpc(accounts, "review_invoice_note", {
      p_invoice_note_id: note.id,
      p_expected_version: reviewed.version,
    })
    throw new Error("duplicate invoice-note review must be rejected")
  } catch (error) {
    if (!/already reviewed|reviewed|23514/i.test(error.message)) throw error
  }
  ok("invoice note prepare and review stay idempotent")

  const linesText = await psql(`
    select string_agg(
      product_id || ':' || shipped_cases || ':' || billed_units_per_case || ':' ||
      billed_quantity || ':' || unit_amount || ':' || line_amount || ':' || price_scope,
      '|'
      order by line_no
    )
    from public.invoice_note_lines
    where invoice_note_id = '${reviewed.id}'
  `)
  const lines = linesText.split("|").map((row) => {
    const [productId, shipped, perCase, billedQty, unit, amount, scope] = row.split(":")
    return { productId, shipped: Number(shipped), perCase, billedQty, unit, amount, scope }
  })
  if (lines.length !== 2) throw new Error(`expected 2 invoice lines, got ${lines.length}`)
  const expectedNoteTotal = lines.reduce((sum, line) => {
    const qty = billedQuantity(line.shipped, line.perCase)
    const subtotal = lineSubtotal(qty, line.unit)
    if (Number(line.billedQty) !== qty) throw new Error(`billed qty drifted for ${line.productId}`)
    if (Number(line.amount) !== subtotal) throw new Error(`line amount drifted for ${line.productId}`)
    return Number((sum + subtotal).toFixed(2))
  }, 0)
  const shopLine = lines.find((line) => line.productId === productA)
  const defaultLine = lines.find((line) => line.productId === productB)
  if (!shopLine || shopLine.scope !== "shop" || Number(shopLine.unit) !== 11) {
    throw new Error(`shop-specific price was not snapshotted: ${JSON.stringify(shopLine)}`)
  }
  if (!defaultLine || defaultLine.scope !== "default" || Number(defaultLine.unit) !== 7.25) {
    throw new Error(`default price fallback was not snapshotted: ${JSON.stringify(defaultLine)}`)
  }
  const noteTotals = await psql(`
    select subtotal_amount::text || ',' || tax_amount::text
    from public.invoice_notes
    where id = '${reviewed.id}'
  `)
  const [noteSubtotal, noteTax] = noteTotals.split(",")
  if (Number(noteSubtotal) !== expectedNoteTotal) {
    throw new Error(`note subtotal ${noteSubtotal} <> independent ${expectedNoteTotal}`)
  }
  if (Number(noteTax) !== 0) throw new Error("invoice-note tax_amount must stay 0")
  ok("shop-specific price, default fallback, and billed-unit conversion match independent math")

  const driverCopy = await rpc(godown, "get_invoice_note_preview", {
    p_invoice_note_id: reviewed.id,
    p_copy: "driver",
  })
  if (driverCopy.watermark !== INVOICE_WATERMARK) throw new Error("driver watermark missing")
  if (driverCopy.legal_invoice_number != null) throw new Error("legal invoice number must stay null")
  if (driverCopy.lines.some((line) => line.unit_amount != null || line.line_amount != null)) {
    throw new Error("driver copy must omit prices")
  }
  if (driverCopy.grand_total != null || driverCopy.tax_preview) {
    throw new Error("driver copy must omit financial totals")
  }
  const accountsCopy = await rpc(accounts, "get_invoice_note_preview", {
    p_invoice_note_id: reviewed.id,
    p_copy: "accounts",
  })
  if (accountsCopy.watermark !== INVOICE_WATERMARK) throw new Error("accounts watermark missing")
  if (Number(accountsCopy.subtotal_amount) !== expectedNoteTotal) {
    throw new Error("accounts copy must keep the reviewed subtotal")
  }
  const replayCopy = await rpc(accounts, "get_invoice_note_preview", {
    p_invoice_note_id: reviewed.id,
    p_copy: "accounts",
  })
  if (Number(replayCopy.subtotal_amount) !== Number(accountsCopy.subtotal_amount)) {
    throw new Error("repeated PDF generation must not mutate snapshots")
  }
  ok("driver and accounts handover documents match immutable snapshots")

  try {
    await rpc(driver, "get_invoice_note_preview", {
      p_invoice_note_id: reviewed.id,
      p_copy: "driver",
    })
    throw new Error("driver must be denied handover RPC")
  } catch (error) {
    if (!denied(error)) throw error
  }
  try {
    await rpc(keeper, "get_invoice_note_preview", {
      p_invoice_note_id: reviewed.id,
      p_copy: "accounts",
    })
    throw new Error("store keeper must be denied accounts copy")
  } catch (error) {
    if (!denied(error)) throw error
  }
  try {
    await rpc(other, "get_invoice_note_preview", {
      p_invoice_note_id: reviewed.id,
      p_copy: "accounts",
    })
    throw new Error("cross-godown manager must be denied")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("unauthorized roles cannot open handover documents")

  let taxPreview = null
  try {
    taxPreview = await rpc(accounts, "preview_invoice_tax", {
      p_invoice_note_id: reviewed.id,
      p_expected_version: reviewed.version,
    })
  } catch (error) {
    if (!/missing|unapproved|ambiguous|not authorized|permission denied|policy|identity|hsn/i.test(error.message)) {
      throw error
    }
  }
  if (taxPreview) {
    if (!/TAX CALCULATION PREVIEW/.test(String(taxPreview.watermark ?? ""))) {
      throw new Error("GST preview must keep the non-statutory watermark")
    }
    if (taxPreview.pricing_treatment === "exclusive") {
      for (const line of taxPreview.lines ?? []) {
        const taxable = Number(Number(line.line_amount).toFixed(2))
        const cgst = Number((taxable * Number(line.cgst_rate) / 100).toFixed(2))
        const sgst = Number((taxable * Number(line.sgst_rate) / 100).toFixed(2))
        const igst = Number((taxable * Number(line.igst_rate) / 100).toFixed(2))
        const tax = Number((cgst + sgst + igst).toFixed(2))
        if (Number(line.tax_amount) !== tax) {
          throw new Error(`GST line failed independent exclusive oracle ${line.tax_amount} <> ${tax}`)
        }
      }
    }
    const taxNote = await psql(`select tax_amount::text from public.invoice_notes where id = '${reviewed.id}'`)
    if (Number(taxNote) !== 0) throw new Error("GST preview must not rewrite invoice-note tax_amount")
    ok("GST preview generated from valid configuration without rewriting the note")
  } else {
    ok("GST preview stays fail-closed without valid statutory configuration")
  }

  const shopPriceId = firstUuid(
    await psql(`
      select id from public.product_selling_prices
      where product_id = '${productA}' and shop_id = '${shop}'
      order by effective_from desc
      limit 1
    `),
  )
  await rpc(accounts, "upsert_product_selling_price", {
    p_product_id: productA,
    p_shop_id: shop,
    p_unit_amount: 99,
    p_effective_from: "2020-01-01",
    p_effective_to: null,
    p_price_id: shopPriceId,
  })

  const grain = await psql(`
    select order_line_id || ',' || product_id || ',' || lot_id || ',' || crate_id || ',' ||
           shipped_cases || ',' || billed_units_per_case || ',' || unit_amount
    from public.invoice_note_lines
    where invoice_note_id = '${reviewed.id}'
      and product_id = '${productA}'
    order by line_no
    limit 1
  `)
  const [orderLineId, productId, lotId, crateId, shipped, billedPerCase, unitAmount] = grain.split(",")
  const creditedCases = 1
  const expectedQty = billedQuantity(creditedCases, billedPerCase)
  const expectedSubtotal = lineSubtotal(expectedQty, unitAmount)
  if (Number(unitAmount) !== 11) throw new Error("historical shop price snapshot drifted")

  const returnId = firstUuid(
    await psql(`
      select set_config('app.delivery_return_write', 'on', false);
      insert into public.stock_delivery_returns (
        dispatch_id, branch_id, return_number, status, created_by
      )
      values (
        '${header.id}'::uuid, '${branch}'::uuid, 'RET-F-${RUN}', 'awaiting_handback', '${users.admin}'::uuid
      )
      returning id;
    `),
  )
  try {
    await psql(`
      select set_config('app.delivery_return_write', 'on', false);
      insert into public.stock_delivery_returns (
        dispatch_id, branch_id, return_number, status, created_by
      )
      values (
        '${header.id}'::uuid, '${branch}'::uuid, 'RET-F-DUP-${RUN}', 'awaiting_handback', '${users.admin}'::uuid
      );
    `)
    throw new Error("second return wave must fail unique dispatch_id")
  } catch (error) {
    if (!/unique|duplicate|already exists|23505/i.test(error.message)) throw error
  }
  ok("one return wave per dispatch remains unique")

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
    select set_config('app.delivery_return_write', 'off', false);
  `)
  try {
    await rpc(accounts, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-empty-${RUN}`,
      p_expected_version: 1,
    })
    throw new Error("return without lots must fail closed")
  } catch (error) {
    if (!/no creditable carton cases|verified return not found|lot/i.test(error.message)) throw error
  }
  ok("posted or closed return without lot grain fails closed")

  await psql(`
    select set_config('app.delivery_return_write', 'on', false);
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
  try {
    await rpc(keeper, "prepare_credit_adjustment", {
      p_return_id: returnId,
      p_idempotency_key: `${PREFIX}-kp-${RUN}`,
      p_expected_version: 1,
    })
    throw new Error("store keeper must be denied")
  } catch (error) {
    if (!denied(error)) throw error
  }
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
  ok("unauthorized roles cannot prepare credit adjustments")

  const preview = await rpc(accounts, "prepare_credit_adjustment", {
    p_return_id: returnId,
    p_idempotency_key: `${PREFIX}-ca-${RUN}`,
    p_expected_version: 1,
  })
  if (preview.watermark !== CREDIT_WATERMARK) throw new Error("credit watermark missing")
  if (preview.legal_credit_note_number != null) throw new Error("legal credit-note number must stay null")
  if (preview.status !== "preview") throw new Error("status must stay preview-only")
  if (Number(preview.credited_cases) !== creditedCases) throw new Error("credited cases drifted")
  if (Number(preview.credited_quantity) !== expectedQty) throw new Error("credit billed quantity drifted")
  if (Number(preview.subtotal_amount) !== expectedSubtotal) {
    throw new Error(`credit subtotal ${preview.subtotal_amount} <> independent ${expectedSubtotal}`)
  }
  if (Number(preview.lines[0].unit_amount) !== 11) {
    throw new Error("historical unit price was replaced by the live selling price")
  }
  if (preview.tax_preview_state !== "tax_preview" && Number(preview.tax_amount) !== 0) {
    throw new Error("missing tax must not invent tax amounts")
  }
  ok("credit adjustment preserves original billed conversion and historical price")

  const retry = await rpc(accounts, "prepare_credit_adjustment", {
    p_return_id: returnId,
    p_idempotency_key: `${PREFIX}-ca-${RUN}`,
    p_expected_version: 1,
  })
  if (retry.id !== preview.id) throw new Error("duplicate key must be idempotent")
  if (Number(retry.subtotal_amount) !== expectedSubtotal) {
    throw new Error("retry must preserve original financial values")
  }
  ok("duplicate credit-adjustment request is idempotent")

  const approved = await rpc(accounts, "review_credit_adjustment", {
    p_adjustment_id: preview.id,
    p_decision: "approve",
    p_reason: "Internal Accounts reconciliation for HTTP F",
    p_expected_version: preview.version,
  })
  if (approved.status !== "approved") throw new Error(`expected approved, got ${approved.status}`)
  if (Number(approved.subtotal_amount) !== expectedSubtotal) {
    throw new Error("review must not mutate financial snapshots")
  }
  if (Number(approved.reconciliation?.remaining_eligible_cases) !== 0) {
    throw new Error("remaining eligible cases must be 0 after occupying the returned case")
  }
  if (approved.tax_readiness?.ready !== false || approved.tax_readiness?.legal_issuance_blocked !== true) {
    throw new Error("credit-note readiness must stay false")
  }
  ok("accounts can approve an internal reconciliation preview")

  try {
    await rpc(accounts, "review_credit_adjustment", {
      p_adjustment_id: preview.id,
      p_decision: "approve",
      p_reason: "duplicate approve",
      p_expected_version: approved.version,
    })
    throw new Error("duplicate approve must be rejected")
  } catch (error) {
    if (!/already reviewed/i.test(error.message)) throw error
  }
  ok("duplicate credit-adjustment approval is rejected")

  const ledgerAfter = await psql("select count(*) from public.stock_ledger")
  if (ledgerBefore !== ledgerAfter) throw new Error("financial RPCs must not write stock")
  const readiness = await rpc(accounts, "assess_invoice_finalization_readiness", {
    p_invoice_note_id: reviewed.id,
  })
  const cnReady = await rpc(accounts, "assess_credit_note_issuance_readiness", {
    p_adjustment_id: preview.id,
  })
  if (readiness.ready !== false || readiness.legal_issuance_blocked !== true) {
    throw new Error("workflow must not enable invoice issuance")
  }
  if (cnReady.ready !== false || cnReady.legal_issuance_blocked !== true) {
    throw new Error("workflow must not enable credit-note issuance")
  }
  ok("stock ledger and statutory issuance remain untouched")
} finally {
  await restoreFlags()
}

console.log(`M7.5F HTTP passed ${passed.length} checks`)
