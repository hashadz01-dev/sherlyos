/**
 * M6.4 local HTTP proofs against 127.0.0.1:54321 only.
 * Multi-partial linked receiving. Stock posts only via verify_stock_receipt.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m64"
const PREFIX = "m64http"
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
    /not authorized|permission|cannot be|not approved|does not match|exceed/i.test(error.message || "")
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M64 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M64 Accounts"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M64 Other Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M64 Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M64 Keeper"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M64 Admin', true),
    ('${users.accounts}', 'M64 Accounts', true),
    ('${users.other}', 'M64 Other Accounts', true),
    ('${users.godown}', 'M64 Godown', true),
    ('${users.keeper}', 'M64 Keeper', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.other}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const other = await signIn(env.ANON_KEY, `other.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M64 HTTP A",
})
const branchB = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}b_${RUN}`,
  branch_name: "M64 HTTP B",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.other, target_branch: branchB })
const supplier = await rpc(admin, "create_supplier", {
  supplier_name: `M64 brand ${RUN}`,
  supplier_phone: null,
  supplier_email: null,
})
const productA = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-a-${RUN}`,
  product_name: "M64 HTTP A",
  next_supplier: supplier,
  next_category: null,
})
const productB = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-b-${RUN}`,
  product_name: "M64 HTTP B",
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
    (select count(*) from public.stock_transactions where product_id in ('${productA}'::uuid, '${productB}'::uuid))
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

async function approveRequest(key, qtyA = 100, qtyB = 60) {
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
    await rpc(godown, "approve_stock_refill_request", {
      target_request: "00000000-0000-0000-0000-000000000001",
      expected_version: 1,
      idempotency_key: `${PREFIX}-gm-apr`,
      decision_reason: null,
    })
    throw new Error("GM must not approve refill")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("unauthorized GM refill approval denied")

  const approved = await approveRequest(`${PREFIX}-ok-${RUN}`)
  if (approved.receiving?.summary?.completion_label !== "not_started") {
    throw new Error("approval must not mark receiving complete")
  }

  try {
    await rpc(accounts, "create_stock_receipt", {
      target_godown: branch,
      target_supplier: supplier,
      supplier_document: `${PREFIX}-acct`,
      received_on: today,
      receipt_notes: null,
      line_items: [line(productA, 1)],
      target_refill_request: approved.id,
    })
    throw new Error("Accounts must not create receipts")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("unauthorized Accounts receiving posting denied")

  try {
    await rpc(other, "get_stock_refill_receiving_reconciliation", {
      target_request: approved.id,
    })
    throw new Error("cross-godown recon must fail")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("cross-godown reconciliation denied")

  const first = await rpc(keeper, "create_stock_receipt", {
    target_godown: branch,
    target_supplier: supplier,
    supplier_document: `${PREFIX}-r1-${RUN}`,
    received_on: today,
    receipt_notes: null,
    line_items: [line(productA, 40, 5), line(productB, 20)],
    target_refill_request: approved.id,
  })
  if (first.refill_request_id !== approved.id || first.status !== "draft") {
    throw new Error("linked draft missing")
  }
  try {
    await rpc(keeper, "create_stock_receipt", {
      target_godown: branch,
      target_supplier: supplier,
      supplier_document: `${PREFIX}-over-${RUN}`,
      received_on: today,
      receipt_notes: null,
      line_items: [line(productA, 70)],
      target_refill_request: approved.id,
    })
    throw new Error("second draft must not exceed remaining requested cases")
  } catch (error) {
    if (/must not exceed remaining/.test(error.message)) throw error
    if (!/exceed requested cases|23514/i.test(error.message)) throw error
  }
  const submitted1 = await rpc(keeper, "submit_stock_receipt", { target_receipt: first.id })
  const verified1 = await rpc(godown, "verify_stock_receipt", {
    target_receipt: submitted1.id,
    idempotency_key: `${PREFIX}-v1-${RUN}`,
  })
  if (verified1.status !== "posted") throw new Error("first verify failed")
  const replay = await rpc(godown, "verify_stock_receipt", {
    target_receipt: submitted1.id,
    idempotency_key: `${PREFIX}-v1-${RUN}`,
  })
  if (replay.status !== "posted") throw new Error("duplicate verify recovery failed")
  ok("store keeper linked receipt + GM verify + duplicate recovery")

  const recon1 = await rpc(accounts, "get_stock_refill_receiving_reconciliation", {
    target_request: approved.id,
  })
  if (recon1.receiving.summary.accepted_cases !== 55) {
    throw new Error(`accepted after first expected 55 got ${recon1.receiving.summary.accepted_cases}`)
  }
  if (recon1.receiving.summary.damaged_cases !== 5) {
    throw new Error("damaged cases missing from posted recon")
  }
  if (recon1.receiving.summary.completion_label !== "partially_received") {
    throw new Error("expected partially received")
  }
  ok("first partial reconciliation")

  const second = await rpc(keeper, "create_stock_receipt", {
    target_godown: branch,
    target_supplier: supplier,
    supplier_document: `${PREFIX}-r2-${RUN}`,
    received_on: today,
    receipt_notes: null,
    line_items: [line(productA, 30), line(productB, 25)],
    target_refill_request: approved.id,
  })
  await rpc(keeper, "submit_stock_receipt", { target_receipt: second.id })
  await rpc(godown, "verify_stock_receipt", {
    target_receipt: second.id,
    idempotency_key: `${PREFIX}-v2-${RUN}`,
  })
  const recon2 = await rpc(keeper, "get_stock_refill_receiving_reconciliation", {
    target_request: approved.id,
  })
  if (recon2.receiving.summary.accepted_cases !== 110) {
    throw new Error(`accepted after second expected 110 got ${recon2.receiving.summary.accepted_cases}`)
  }
  if (recon2.receiving.summary.outstanding_cases !== 50) {
    throw new Error(`outstanding expected 50 got ${recon2.receiving.summary.outstanding_cases}`)
  }
  ok("two partial receipts reconciled")

  const unlinked = await rpc(keeper, "create_stock_receipt", {
    target_godown: branch,
    target_supplier: supplier,
    supplier_document: `${PREFIX}-unl-${RUN}`,
    received_on: today,
    receipt_notes: null,
    line_items: [line(productA, 2)],
  })
  if (unlinked.refill_request_id) throw new Error("unlinked receipt attached")
  await rpc(keeper, "submit_stock_receipt", { target_receipt: unlinked.id })
  await rpc(godown, "verify_stock_receipt", {
    target_receipt: unlinked.id,
    idempotency_key: `${PREFIX}-unl-v-${RUN}`,
  })
  const recon3 = await rpc(accounts, "get_stock_refill_request", {
    target_request: approved.id,
  })
  if (recon3.receiving.summary.accepted_cases !== 110) {
    throw new Error("unlinked posted qty entered refill totals")
  }
  ok("existing unlinked receiving")

  const options = await rpc(keeper, "list_receiving_options")
  if (!options.refill_requests?.some((row) => row.id === approved.id)) {
    throw new Error("keeper options missing approved refill")
  }
  ok("keeper receiving options include approved refill")

  const stockAfter = await psql(`
    select concat_ws(',',
      (select coalesce(sum(quantity),0) from public.stock_balances where product_id in ('${productA}'::uuid, '${productB}'::uuid)),
      (select count(*) from public.stock_transactions where product_id in ('${productA}'::uuid, '${productB}'::uuid))
    );
  `)
  const [beforeQty, beforeTx] = stockBefore.split(",")
  const [afterQty, afterTx] = stockAfter.split(",")
  if (Number(afterQty) !== Number(beforeQty) + 112) {
    throw new Error(`balance delta expected +112 accepted, ${beforeQty} -> ${afterQty}`)
  }
  if (Number(afterTx) !== Number(beforeTx) + 5) {
    throw new Error(`tx count expected +5, ${beforeTx} -> ${afterTx}`)
  }
  ok("stock posted only by verify_stock_receipt")

  const flags = await psql(`
    select count(*) from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  `)
  if (flags.split(/\r?\n/).filter(Boolean).at(-1) !== "0") throw new Error("cutover flags flipped")
  ok("cutover flags remain false")
} finally {
  // Disposable m64http catalog rows stay local.
}

console.log(`M6.4 HTTP passed ${passed.length}`)
if (passed.length < 10) throw new Error("expected at least 10 HTTP proofs")
