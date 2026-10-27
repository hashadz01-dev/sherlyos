/**
 * M6.6 local HTTP proofs against 127.0.0.1:54321 only.
 * Authenticated sessions for REF-01–07 plus permission denials.
 * Stock posts only through verify_stock_receipt.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m66"
const PREFIX = "m66http"
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
    const error = new Error(
      `${name}: ${result.error.message} [${result.error.code}] ${result.error.details || ""} ${result.error.hint || ""}`,
    )
    error.code = result.error.code
    throw error
  }
  return result.data
}

function denied(error) {
  return (
    error.code === "42501" ||
    error.code === "PGRST301" ||
    /not authorized|permission|cannot be/i.test(error.message || "")
  )
}

const passed = []
function ok(name) {
  passed.push(name)
  console.log(`PASS ${name}`)
}

const env = await statusEnv()
assertLocal(env.API_URL || API)
if (!env.ANON_KEY) throw new Error("local anon key missing")

await psql(`notify pgrst, 'reload schema';`)
await psql(`
  update auth.users
  set
    confirmation_token = coalesce(nullif(confirmation_token, ''), id::text || '-c'),
    recovery_token = coalesce(nullif(recovery_token, ''), id::text || '-r'),
    email_change_token_new = coalesce(nullif(email_change_token_new, ''), id::text || '-n'),
    email_change_token_current = coalesce(nullif(email_change_token_current, ''), id::text || '-e'),
    reauthentication_token = coalesce(nullif(reauthentication_token, ''), id::text || '-a'),
    email_change = coalesce(email_change, '');
`)

const users = {
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M66 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M66 Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M66 Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M66 Keeper"),
  sales: await ensureUser(`sales.${PREFIX}@example.com`, "M66 Sales"),
  delivery: await ensureUser(`delivery.${PREFIX}@example.com`, "M66 Delivery"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M66 Admin', true),
    ('${users.accounts}', 'M66 Accounts', true),
    ('${users.godown}', 'M66 Godown', true),
    ('${users.keeper}', 'M66 Keeper', true),
    ('${users.sales}', 'M66 Sales', true),
    ('${users.delivery}', 'M66 Delivery', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.sales}'::uuid, 'salesperson'),
    ('${users.delivery}'::uuid, 'delivery_person')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const sales = await signIn(env.ANON_KEY, `sales.${PREFIX}@example.com`)
const delivery = await signIn(env.ANON_KEY, `delivery.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M66 HTTP A",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.sales, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.delivery, target_branch: branch })
const supplier = await rpc(admin, "create_supplier", {
  supplier_name: `M66 brand ${RUN}`,
  supplier_phone: null,
  supplier_email: null,
})
const productA = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-a-${RUN}`,
  product_name: "M66 HTTP A",
  next_supplier: supplier,
  next_category: null,
})
const productB = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-b-${RUN}`,
  product_name: "M66 HTTP B",
  next_supplier: supplier,
  next_category: null,
})
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

const today = new Date().toISOString().slice(0, 10)
const stockBefore = await psql(`
  select concat_ws(',',
    (select coalesce(sum(quantity),0) from public.stock_balances where product_id in ('${productA}'::uuid, '${productB}'::uuid)),
    (select count(*) from public.stock_transactions where product_id in ('${productA}'::uuid, '${productB}'::uuid)),
    (select count(*) from public.stock_ledger where product_id in ('${productA}'::uuid, '${productB}'::uuid))
  );
`)

function line(product, counted, damaged = 0) {
  return {
    product_id: product,
    destination_crate_id: crate,
    document_cases: counted,
    counted_cases: counted,
    damaged_cases: damaged,
  }
}

async function approveRequest(key, qtyA = 10, qtyB = 6) {
  const created = await rpc(accounts, "create_stock_refill_request", {
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [
      { product_id: productA, requested_cases: qtyA },
      { product_id: productB, requested_cases: qtyB },
    ],
    idempotency_key: `${key}-c`,
    notes: null,
  })
  const submitted = await rpc(accounts, "submit_stock_refill_request", {
    target_request: created.id,
    expected_version: created.version,
    idempotency_key: `${key}-s`,
  })
  return rpc(admin, "approve_stock_refill_request", {
    target_request: submitted.id,
    expected_version: submitted.version,
    idempotency_key: `${key}-a`,
    decision_reason: null,
  })
}

try {
  try {
    await rpc(sales, "list_stock_refill_requests", {})
    throw new Error("salesperson must not list refill")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("salesperson refill list denied")

  try {
    await rpc(delivery, "list_stock_refill_report", {})
    throw new Error("delivery must not read refill report")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("delivery refill report denied")

  const approved = await approveRequest(`${PREFIX}-std-${RUN}`)
  try {
    await rpc(admin, "record_stock_refill_supplier_communication", {
      target_request: approved.id,
      expected_version: approved.version,
      communication_channel: "email",
      communicated_at: new Date().toISOString(),
      idempotency_key: `${PREFIX}-admin-send-${RUN}`,
      external_reference: null,
      notes: null,
    })
    throw new Error("admin must not send")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("admin cannot impersonate supplier send")

  const sent = await rpc(accounts, "record_stock_refill_supplier_communication", {
    target_request: approved.id,
    expected_version: approved.version,
    communication_channel: "whatsapp",
    communicated_at: new Date().toISOString(),
    idempotency_key: `${PREFIX}-send-${RUN}`,
    external_reference: "WA-66",
    notes: null,
  })
  const ack = await rpc(accounts, "record_stock_refill_supplier_acknowledgement", {
    target_request: approved.id,
    expected_version: sent.version,
    acknowledgement_status: "acknowledged",
    response_at: new Date().toISOString(),
    idempotency_key: `${PREFIX}-ack-${RUN}`,
    acknowledgement_reference: "ACK-66",
    notes: null,
    decline_reason: null,
  })
  await rpc(accounts, "record_stock_refill_supplier_dispatch", {
    target_request: approved.id,
    expected_version: ack.version,
    dispatched_on: today,
    idempotency_key: `${PREFIX}-disp-${RUN}`,
    supplier_dispatch_reference: "DN-66",
    expected_arrival_on: today,
    transport_provider: null,
    vehicle_reference: null,
    tracking_reference: null,
    notes: null,
  })
  const midStock = await psql(`
    select concat_ws(',',
      (select coalesce(sum(quantity),0) from public.stock_balances where product_id in ('${productA}'::uuid, '${productB}'::uuid)),
      (select count(*) from public.stock_transactions where product_id in ('${productA}'::uuid, '${productB}'::uuid))
    );
  `)
  if (midStock !== stockBefore.split(",").slice(0, 2).join(",")) {
    throw new Error("supplier communication posted stock")
  }
  ok("create through dispatch posted zero stock")

  const first = await rpc(keeper, "create_stock_receipt", {
    target_godown: branch,
    target_supplier: supplier,
    supplier_document: `${PREFIX}-r1-${RUN}`,
    received_on: today,
    receipt_notes: null,
    line_items: [line(productA, 6, 1), line(productB, 3)],
    target_refill_request: approved.id,
  })
  await rpc(keeper, "submit_stock_receipt", { target_receipt: first.id })
  try {
    await rpc(accounts, "verify_stock_receipt", {
      target_receipt: first.id,
      idempotency_key: `${PREFIX}-acct-v-${RUN}`,
    })
    throw new Error("accounts must not verify")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("accounts cannot verify linked receipts")

  await rpc(godown, "verify_stock_receipt", {
    target_receipt: first.id,
    idempotency_key: `${PREFIX}-v1-${RUN}`,
  })
  const replay = await rpc(godown, "verify_stock_receipt", {
    target_receipt: first.id,
    idempotency_key: `${PREFIX}-v1-${RUN}`,
  })
  if (replay.status !== "posted") throw new Error("verify replay failed")
  ok("gm verify + duplicate recovery")

  const recon = await rpc(accounts, "get_stock_refill_receiving_reconciliation", {
    target_request: approved.id,
  })
  if (recon.receiving.summary.accepted_cases !== 8 || recon.receiving.summary.damaged_cases !== 1) {
    throw new Error(`recon mismatch ${JSON.stringify(recon.receiving.summary)}`)
  }
  const listed = await rpc(accounts, "list_stock_refill_requests", {
    search_text: approved.request_number,
  })
  const report = await rpc(accounts, "list_stock_refill_report", {
    search_text: approved.request_number,
  })
  const exported = await rpc(accounts, "export_stock_refill_report", {
    search_text: approved.request_number,
  })
  if (
    listed.items[0]?.accepted_cases !== 8 ||
    report.rows[0]?.accepted_cases !== 8 ||
    !String(exported.csv).includes(approved.request_number)
  ) {
    throw new Error("queue/report/export accepted mismatch")
  }
  ok("queue detail report export reconcile")

  const stockAfter = await psql(`
    select concat_ws(',',
      (select coalesce(sum(quantity),0) from public.stock_balances where product_id in ('${productA}'::uuid, '${productB}'::uuid)),
      (select count(*) from public.stock_transactions where product_id in ('${productA}'::uuid, '${productB}'::uuid)),
      (select count(*) from public.stock_ledger where product_id in ('${productA}'::uuid, '${productB}'::uuid))
    );
  `)
  const [beforeQty, beforeTx, beforeLedger] = stockBefore.split(",")
  const [afterQty, afterTx, afterLedger] = stockAfter.split(",")
  // Accepted A=5, B=3. Two RECEIPT rows. Ledger mirrors transactions.
  if (Number(afterQty) !== Number(beforeQty) + 8) {
    throw new Error(`balance delta expected +8, ${beforeQty} -> ${afterQty}`)
  }
  if (Number(afterTx) !== Number(beforeTx) + 2 || Number(afterLedger) !== Number(beforeLedger) + 2) {
    throw new Error(`tx/ledger expected +2, ${beforeTx}/${beforeLedger} -> ${afterTx}/${afterLedger}`)
  }
  ok("verify posted accepted cases once")

  const flags = await psql(`
    select count(*) from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  `)
  if (Number(flags.split(/\r?\n/).filter(Boolean).at(-1)) !== 0) {
    throw new Error("cutover flags flipped")
  }
  ok("cutover flags remain false")
} catch (error) {
  console.error(error)
  process.exitCode = 1
}

console.log(`M6.6 HTTP passed ${passed.length}`)
if (process.exitCode !== 1 && passed.length < 8) {
  throw new Error("expected at least 8 HTTP proofs")
}
