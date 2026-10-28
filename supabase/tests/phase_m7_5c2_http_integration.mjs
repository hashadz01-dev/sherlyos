/**
 * M7.5C.2 local HTTP proofs against 127.0.0.1:54321 only.
 * Replica-enables dual-write for a disposable pick/dispatch seed, then restores flags.
 * Does not finalize invoices or leave operational flags true.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m75c2"
const PREFIX = "m75c2http"
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

function assertLocal(url) {
  const parsed = new URL(url)
  if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") {
    throw new Error(`refusing non-local host ${parsed.hostname}`)
  }
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
  console.log(`PASS ${name}`)
}

const env = await statusEnv()
assertLocal(env.API_URL || API)
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M75B Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M75B Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M75B Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M75B Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M75C2 Driver"),
  verifier: await ensureUser(`verifier.${PREFIX}@example.com`, "M75C2 Verifier"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M75B Admin', true),
    ('${users.accounts}', 'M75B Accounts', true),
    ('${users.godown}', 'M75B Godown', true),
    ('${users.keeper}', 'M75B Keeper', true),
    ('${users.driver}', 'M75C2 Driver', true),
    ('${users.verifier}', 'M75C2 Verifier', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person'),
    ('${users.verifier}'::uuid, 'statutory_verifier')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)
const verifier = await signIn(env.ANON_KEY, `verifier.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M75B QA",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.driver, target_branch: branch })
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
  product_name: "M75B Soap",
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
  shop_name: `M75B shop ${RUN}`,
  shop_phone: null,
  shop_address: null,
})
try {
  await rpc(admin, "upsert_statutory_operating_ownership", {
    p_ownership_code: `C2-${RUN}`,
    p_effective_from: "2020-01-01",
    p_expected_version: 1,
  })
} catch {
  /* singleton may already exist from a prior local test */
}
const ownershipCode = await rpc(admin, "registered_operating_ownership_code")
if (!ownershipCode) throw new Error("operating ownership must exist")
try {
  await rpc(admin, "upsert_statutory_seller_identity", {
    p_ownership_code: "ZZ-OTHER",
    p_legal_name: "Other Co",
    p_registered_address: "x",
    p_effective_from: "2020-01-01",
    p_expected_version: 1,
  })
  throw new Error("arbitrary ownership must fail")
} catch (error) {
  if (!/ownership/i.test(error.message)) throw error
}
ok("arbitrary ownership_code is rejected")

async function submitVerify(submitName, verifyName, row) {
  const submitted = await rpc(admin, submitName, {
    p_id: row.id,
    p_expected_version: row.version,
  })
  try {
    return await rpc(verifier, verifyName, {
      p_id: submitted.id,
      p_expected_version: submitted.version,
    })
  } catch (error) {
    if (!/overlap/i.test(error.message)) throw error
    return submitted
  }
}

try {
  const sellerDraft = await rpc(admin, "upsert_statutory_seller_identity", {
    p_ownership_code: ownershipCode,
    p_legal_name: "C2 Test Seller",
    p_registered_address: "1 Test Road",
    p_state_code: "27",
    p_gstin: "27AAAAA0000A1Z5",
    p_signature_caption: "Signatory",
    p_seal_caption: "Seal",
    p_effective_from: "2020-01-01",
    p_expected_version: 1,
  })
  await submitVerify(
    "submit_statutory_seller_identity",
    "verify_statutory_seller_identity",
    sellerDraft,
  )
} catch (error) {
  if (!/overlap|open|unique|duplicate/i.test(error.message)) throw error
}

const shopTax = await rpc(admin, "upsert_shop_tax_identity", {
  p_shop_id: shop,
  p_billing_name: "C2 Shop",
  p_billing_address: "2 Shop Road",
  p_registration_status: "unregistered",
  p_state_code: "27",
  p_effective_from: "2020-01-01",
  p_expected_version: 1,
})
await submitVerify("submit_shop_tax_identity", "verify_shop_tax_identity", shopTax)

const hsnCode = `9988${String(Date.now()).slice(-4)}`
const hsn = await rpc(admin, "upsert_product_hsn_classification", {
  p_product_id: product,
  p_classification_kind: "hsn",
  p_hsn_sac_code: hsnCode,
  p_effective_from: "2020-01-01",
  p_expected_version: 1,
})
await submitVerify(
  "submit_product_hsn_classification",
  "verify_product_hsn_classification",
  hsn,
)

const intra = await rpc(admin, "upsert_tax_rate_schedule", {
  p_schedule_code: `GST-${hsnCode}-IN`,
  p_treatment: "intra_state",
  p_hsn_sac_code: hsnCode,
  p_cgst_rate: 2.5,
  p_sgst_rate: 2.5,
  p_effective_from: "2020-01-01",
  p_expected_version: 1,
})
await submitVerify("submit_tax_rate_schedule", "verify_tax_rate_schedule", intra)

for (const kind of [
  ["tax_inclusive_exclusive", { pricing: "exclusive" }],
  ["place_of_supply", { basis: "billing_state" }],
  ["rounding", { mode: "nearest_half_up", increment: "0.01", scope: "per_line" }],
  ["gst_component", { intra_state: "cgst_sgst", inter_state: "igst" }],
]) {
  try {
    const policy = await rpc(admin, "upsert_statutory_policy", {
      p_policy_kind: kind[0],
      p_payload: kind[1],
      p_effective_from: "2020-01-01",
      p_expected_version: 1,
    })
    await submitVerify("submit_statutory_policy", "verify_statutory_policy", policy)
  } catch (error) {
    if (!/overlap|open|unique|duplicate/i.test(error.message)) throw error
  }
}

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
    null, 'M75B-HTTP', null, '2028-06-01'
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
  const preview = await rpc(godown, "preview_dispatch", { target_order: created.order.id })
  let header = await rpc(godown, "prepare_dispatch", {
    target_order: created.order.id,
    expected_picking_version: preview.picking_version ?? picking.version,
    idempotency_key: `${PREFIX}-prep-${RUN}`,
  })
  header = await rpc(godown, "confirm_dispatch", {
    target_dispatch: header.id,
    expected_version: header.version,
    idempotency_key: `${PREFIX}-cfm-${RUN}`,
  })

  try {
    await rpc(accounts, "prepare_invoice_note", {
      p_dispatch_id: header.id,
      p_idempotency_key: `${PREFIX}-inv-${RUN}`,
      p_expected_version: 1,
      p_remarks: null,
    })
    throw new Error("accounts must not prepare")
  } catch (error) {
    if (!/not authorized|permission denied/i.test(error.message)) throw error
  }
  ok("Accounts cannot prepare invoice notes")

  try {
    await rpc(driver, "prepare_invoice_note", {
      p_dispatch_id: header.id,
      p_idempotency_key: `${PREFIX}-drv-${RUN}`,
      p_expected_version: 1,
      p_remarks: null,
    })
    throw new Error("driver must not prepare")
  } catch (error) {
    if (!/not authorized|permission denied/i.test(error.message)) throw error
  }
  ok("Driver cannot prepare invoice notes")

  const note = await rpc(godown, "prepare_invoice_note", {
    p_dispatch_id: header.id,
    p_idempotency_key: `${PREFIX}-inv-${RUN}`,
    p_expected_version: 1,
    p_remarks: null,
  })
  if (note.status !== "draft") throw new Error("prepared note must be draft")
  if (note.watermark !== "DRAFT INVOICE NOTE — NOT A TAX INVOICE") {
    throw new Error("draft watermark missing")
  }
  if (note.legal_issuance_blocked !== true || note.has_legal_seal !== false) {
    throw new Error("legal issuance must stay blocked")
  }
  if (Number(note.tax_amount) !== 0) throw new Error("GST must stay zero")
  if (Number(note.billed_cases) !== 2) throw new Error("billed cases must equal dispatched consume")
  if (Number(note.billed_quantity) !== 24) throw new Error("billed qty must be cases * conversion")
  if (Number(note.grand_total) !== 252) throw new Error(`expected 252, got ${note.grand_total}`)
  if (note.statutory?.ready !== false) throw new Error("statutory ready must be false")
  ok("GM prepares a priced draft from DISPATCH consume")

  const replay = await rpc(godown, "prepare_invoice_note", {
    p_dispatch_id: header.id,
    p_idempotency_key: `${PREFIX}-inv-${RUN}`,
    p_expected_version: note.version,
    p_remarks: null,
  })
  if (replay.id !== note.id) throw new Error("idempotent prepare must return the same draft")
  ok("prepare is idempotent for the same dispatch key")

  try {
    await rpc(godown, "prepare_invoice_note", {
      p_dispatch_id: header.id,
      p_idempotency_key: `${PREFIX}-inv-other-${RUN}`,
      p_expected_version: 1,
      p_remarks: null,
    })
    throw new Error("second open note must fail")
  } catch (error) {
    if (!/already exists/i.test(error.message)) throw error
  }
  ok("unique open invoice note per dispatch")

  const submitted = await rpc(godown, "submit_invoice_note", {
    p_invoice_note_id: note.id,
    p_expected_version: note.version,
  })
  if (submitted.status !== "submitted") throw new Error("submit must move to submitted")
  ok("GM submits the draft")

  await rpc(accounts, "upsert_product_selling_price", {
    p_product_id: product,
    p_shop_id: shop,
    p_unit_amount: 99,
    p_effective_from: "2020-01-01",
    p_effective_to: null,
    p_price_id: null,
  })
  try {
    await rpc(accounts, "review_invoice_note", {
      p_invoice_note_id: note.id,
      p_expected_version: submitted.version,
    })
    throw new Error("review must fail after live price change")
  } catch (error) {
    if (!/no longer match/i.test(error.message)) throw error
  }
  ok("review fails closed when the live price fingerprint changes")

  const cancelled = await rpc(accounts, "cancel_invoice_note", {
    p_invoice_note_id: note.id,
    p_expected_version: submitted.version,
  })
  if (cancelled.status !== "cancelled") throw new Error("cancel must close the draft")
  ok("Accounts can cancel a submitted draft")

  const replacement = await rpc(godown, "prepare_invoice_note", {
    p_dispatch_id: header.id,
    p_idempotency_key: `${PREFIX}-inv-2-${RUN}`,
    p_expected_version: 1,
    p_remarks: null,
  })
  if (Number(replacement.grand_total) !== 2376) {
    throw new Error(`replacement must use the shop price, got ${replacement.grand_total}`)
  }
  const resubmitted = await rpc(godown, "submit_invoice_note", {
    p_invoice_note_id: replacement.id,
    p_expected_version: replacement.version,
  })
  const reviewed = await rpc(accounts, "review_invoice_note", {
    p_invoice_note_id: replacement.id,
    p_expected_version: resubmitted.version,
  })
  if (reviewed.status !== "reviewed") throw new Error("review must succeed on a matching fingerprint")
  if (reviewed.statutory.ready !== false) throw new Error("review must not enable issuance")
  ok("Accounts review succeeds when prices still match")

  const printPreview = await rpc(accounts, "get_invoice_note_preview", {
    p_invoice_note_id: replacement.id,
    p_copy: "transporter",
  })
  if (printPreview.copy_label !== "TRANSPORTER / DRIVER COPY") {
    throw new Error("transporter copy label missing")
  }
  if (printPreview.signature_block?.shown !== false) {
    throw new Error("draft preview must not show a legal seal")
  }
  ok("draft preview is watermarked with no legal seal")

  const readiness = await rpc(accounts, "assess_invoice_finalization_readiness")
  if (readiness.ready !== false) throw new Error("readiness must stay false")
  if (readiness.legal_issuance_blocked !== true) throw new Error("issuance must stay blocked")
  ok("statutory readiness RPC never reports ready")

  try {
    await rpc(driver, "preview_invoice_tax", {
      p_invoice_note_id: replacement.id,
      p_expected_version: reviewed.version,
    })
    throw new Error("driver must not preview tax")
  } catch (error) {
    if (!/not authorized|permission denied/i.test(error.message)) throw error
  }
  ok("driver cannot preview tax")

  const taxPreview = await rpc(accounts, "preview_invoice_tax", {
    p_invoice_note_id: replacement.id,
    p_expected_version: reviewed.version,
  })
  if (taxPreview.watermark !== "TAX CALCULATION PREVIEW — NOT A TAX INVOICE") {
    throw new Error("tax preview watermark missing")
  }
  if (taxPreview.ready !== false || taxPreview.legal_issuance_blocked !== true) {
    throw new Error("tax preview must not enable issuance")
  }
  if (taxPreview.calculated !== true) throw new Error(`expected calculated preview, got ${JSON.stringify(taxPreview.blockers)}`)
  if (taxPreview.pricing_treatment !== "exclusive") throw new Error("expected exclusive treatment")
  if (Number(taxPreview.tax_amount) <= 0) throw new Error("nonzero exclusive tax expected on shop-priced note")
  if (Number(reviewed.tax_amount) !== 0) throw new Error("reviewed note tax_amount must remain 0")
  ok("reviewed note tax preview calculates without issuing")

  const duplicate = await rpc(accounts, "preview_invoice_tax", {
    p_invoice_note_id: replacement.id,
    p_expected_version: reviewed.version,
  })
  if (duplicate.id !== taxPreview.id) throw new Error("duplicate preview must reuse the fingerprint snapshot")
  ok("duplicate tax preview is idempotent")

  const previewArgs = {
    p_invoice_note_id: replacement.id,
    p_expected_version: reviewed.version,
  }
  const concurrentPreview = await Promise.allSettled([
    rpc(accounts, "preview_invoice_tax", previewArgs),
    rpc(accounts, "preview_invoice_tax", previewArgs),
  ])
  const concurrentWins = concurrentPreview.filter((row) => row.status === "fulfilled")
  if (concurrentWins.length < 1) {
    throw new Error(`concurrent preview produced no snapshot: ${concurrentPreview.map((row) => row.reason?.message).join("; ")}`)
  }
  const concurrentIds = new Set(concurrentWins.map((row) => row.value.id))
  if (concurrentIds.size !== 1) {
    throw new Error("concurrent previews must not split the current snapshot")
  }
  ok("concurrent duplicate preview requests share one snapshot")

  const snapshotTax = Number(taxPreview.tax_amount)
  await Promise.allSettled([
    rpc(accounts, "preview_invoice_tax", previewArgs),
    rpc(accounts, "upsert_product_selling_price", {
      p_product_id: product,
      p_shop_id: null,
      p_unit_amount: 99,
      p_effective_from: "2099-01-01",
      p_effective_to: null,
      p_price_id: null,
    }),
  ])
  const afterPrice = await rpc(accounts, "preview_invoice_tax", previewArgs)
  if (Number(afterPrice.tax_amount) !== snapshotTax) {
    throw new Error("live price update must not mutate reviewed tax snapshot amounts")
  }
  ok("price update versus preview leaves reviewed snapshots unchanged")

  const policyList = await rpc(admin, "list_statutory_policies")
  const treatment = (Array.isArray(policyList) ? policyList : []).find(
    (row) => row.policy_kind === "tax_inclusive_exclusive" && row.status === "verified",
  )
  if (!treatment) throw new Error("verified tax treatment policy is required for supersession race")
  try {
    const treatmentDraft = await rpc(admin, "upsert_statutory_policy", {
      p_policy_kind: "tax_inclusive_exclusive",
      p_payload: { pricing: "inclusive" },
      p_effective_from: "2020-01-01",
      p_expected_version: treatment.version,
      p_id: treatment.id,
    })
    const submittedTreatment = await rpc(admin, "submit_statutory_policy", {
      p_id: treatmentDraft.id,
      p_expected_version: treatmentDraft.version,
    })
    const policyRace = await Promise.allSettled([
      rpc(accounts, "preview_invoice_tax", previewArgs),
      rpc(verifier, "verify_statutory_policy", {
        p_id: submittedTreatment.id,
        p_expected_version: submittedTreatment.version,
      }),
    ])
    const racedPreview = policyRace[0].status === "fulfilled" ? policyRace[0].value : null
    if (
      racedPreview?.calculated &&
      racedPreview.pricing_treatment !== "exclusive" &&
      racedPreview.pricing_treatment !== "inclusive"
    ) {
      throw new Error("preview mixed an implicit tax treatment")
    }
    if (policyRace.every((row) => row.status === "rejected")) {
      throw new Error("policy supersession versus preview produced no committed outcome")
    }
  } catch (error) {
    if (!/overlap|open|unique|duplicate|changed by someone else/i.test(error.message)) throw error
  }
  ok("tax policy supersession versus preview stays deterministic")

  try {
    const scheduleDraft = await rpc(admin, "upsert_tax_rate_schedule", {
      p_schedule_code: `GST-1905-IN-RACE-${RUN}`,
      p_treatment: "intra_state",
      p_hsn_sac_code: hsnCode,
      p_cgst_rate: 2.5,
      p_sgst_rate: 2.5,
      p_effective_from: "2020-01-01",
      p_expected_version: 1,
    })
    const submittedSchedule = await rpc(admin, "submit_tax_rate_schedule", {
      p_id: scheduleDraft.id,
      p_expected_version: scheduleDraft.version,
    })
    const scheduleRace = await Promise.allSettled([
      rpc(accounts, "preview_invoice_tax", previewArgs),
      rpc(verifier, "verify_tax_rate_schedule", {
        p_id: submittedSchedule.id,
        p_expected_version: submittedSchedule.version,
      }),
    ])
    if (scheduleRace.every((row) => row.status === "rejected")) {
      throw new Error("schedule approval versus preview produced no committed outcome")
    }
  } catch (error) {
    if (!/overlap|open|unique|duplicate|changed by someone else/i.test(error.message)) throw error
  }
  ok("tax schedule approval versus preview stays fail-closed")

  try {
    await rpc(keeper, "preview_invoice_tax", previewArgs)
    throw new Error("store keeper must not preview tax")
  } catch (error) {
    if (!/not authorized|permission denied/i.test(error.message)) throw error
  }
  ok("store keeper cannot preview tax")

  const godown2Id = await ensureUser(`godown2.${PREFIX}@example.com`, "M75C2 Other GM")
  await psql(`
    insert into public.profiles (id, full_name, is_active)
    values ('${godown2Id}', 'M75C2 Other GM', true)
    on conflict (id) do update set is_active = true;
    insert into public.user_roles (user_id, role_id, assigned_by)
    select '${godown2Id}'::uuid, roles.id, '${users.admin}'::uuid
    from public.roles where roles.code = 'godown_manager'
    on conflict do nothing;
  `)
  const branch2 = await rpc(admin, "create_branch", {
    branch_code: `${PREFIX}_x_${RUN}`,
    branch_name: "M75C2 other branch",
  })
  await rpc(admin, "assign_user_branch", { target_user: godown2Id, target_branch: branch2 })
  const godown2 = await signIn(env.ANON_KEY, `godown2.${PREFIX}@example.com`)
  try {
    await rpc(godown2, "preview_invoice_tax", previewArgs)
    throw new Error("cross-godown manager must not preview another branch note")
  } catch (error) {
    if (!/not authorized|permission denied/i.test(error.message)) throw error
  }
  ok("cross-godown manager cannot preview another branch note")

  await Promise.allSettled([
    rpc(accounts, "preview_invoice_tax", previewArgs),
    psql(`
      delete from public.user_roles
      where user_id = '${users.accounts}'::uuid
        and role_id = (select id from public.roles where code = 'accounts')
    `),
  ])
  const currentPreviewCount = Number(
    await psql(`
      select count(*) from public.invoice_tax_previews
      where invoice_note_id = '${replacement.id}'::uuid and is_current
    `),
  )
  if (currentPreviewCount !== 1) {
    throw new Error(`expected one current preview, got ${currentPreviewCount}`)
  }
  await psql(`
    insert into public.user_roles (user_id, role_id, assigned_by)
    select '${users.accounts}'::uuid, roles.id, '${users.admin}'::uuid
    from public.roles where roles.code = 'accounts'
    on conflict do nothing;
  `)
  ok("permission revocation versus preview leaves one current snapshot")
} finally {
  // Invoice-note lines retain lot FKs, so do not delete disposable lots here.
  // Operational flags must still return to false after the dual-write seed.
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

console.log(`M7.5C.2 HTTP passed ${passed.length} checks`)
