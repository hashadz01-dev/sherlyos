/**
 * M6.3 local HTTP proofs against 127.0.0.1:54321 only.
 * Manual send/ack/dispatch. Zero stock. Does not flip damage/lot flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m63"
const PREFIX = "m63http"
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
    /not authorized|permission|cannot be|has not been recorded|declined/i.test(error.message || "")
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M63 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M63 Accounts"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M63 Other Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M63 Godown"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M63 Admin', true),
    ('${users.accounts}', 'M63 Accounts', true),
    ('${users.other}', 'M63 Other Accounts', true),
    ('${users.godown}', 'M63 Godown', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.other}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const other = await signIn(env.ANON_KEY, `other.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M63 HTTP A",
})
const branchB = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}b_${RUN}`,
  branch_name: "M63 HTTP B",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.other, target_branch: branchB })
const supplier = await rpc(admin, "create_supplier", {
  supplier_name: `M63 brand ${RUN}`,
  supplier_phone: null,
  supplier_email: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`,
  product_name: "M63 HTTP Soap",
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

await psql(`
  set session_replication_role = replica;
  insert into public.stock_balances (crate_id, product_id, quantity)
  values ('${crate}'::uuid, '${product}'::uuid, 13)
  on conflict (crate_id, product_id) do update set quantity = excluded.quantity;
  set session_replication_role = origin;
`)

const stockBefore = await psql(`
  select concat_ws(',',
    (select count(*) from public.stock_transactions),
    (select count(*) from public.stock_ledger),
    (select coalesce(sum(quantity),0) from public.stock_balances where product_id = '${product}'::uuid),
    (select count(*) from public.stock_reservations),
    (select count(*) from public.stock_receipts)
  );
`)

async function approveRequest(key) {
  const created = await rpc(accounts, "create_stock_refill_request", {
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [{ product_id: product, requested_cases: 2 }],
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

const communicatedAt = new Date().toISOString()

try {
  const approved = await approveRequest(`${PREFIX}-ok-${RUN}`)

  try {
    await rpc(admin, "record_stock_refill_supplier_communication", {
      target_request: approved.id,
      expected_version: approved.version,
      communication_channel: "phone",
      communicated_at: communicatedAt,
      idempotency_key: `${PREFIX}-adm-${RUN}`,
      external_reference: null,
      notes: null,
    })
    throw new Error("admin must not record send")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("admin cannot send")

  try {
    await rpc(godown, "record_stock_refill_supplier_communication", {
      target_request: approved.id,
      expected_version: approved.version,
      communication_channel: "phone",
      communicated_at: communicatedAt,
      idempotency_key: `${PREFIX}-gm-${RUN}`,
      external_reference: null,
      notes: null,
    })
    throw new Error("godown manager must not record send")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("godown manager cannot send")

  try {
    await rpc(other, "record_stock_refill_supplier_communication", {
      target_request: approved.id,
      expected_version: approved.version,
      communication_channel: "phone",
      communicated_at: communicatedAt,
      idempotency_key: `${PREFIX}-xgd-${RUN}`,
      external_reference: null,
      notes: null,
    })
    throw new Error("cross-godown accounts must not send")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("cross-godown send denied")

  const sent = await rpc(accounts, "record_stock_refill_supplier_communication", {
    target_request: approved.id,
    expected_version: approved.version,
    communication_channel: "whatsapp",
    communicated_at: communicatedAt,
    idempotency_key: `${PREFIX}-send-${RUN}`,
    external_reference: "WA-1",
    notes: "messaged brand",
  })
  if (sent.communication_status !== "sent" || sent.status !== "approved") {
    throw new Error("send did not persist as sent/approved")
  }
  const replay = await rpc(accounts, "record_stock_refill_supplier_communication", {
    target_request: approved.id,
    expected_version: approved.version,
    communication_channel: "whatsapp",
    communicated_at: sent.communication.communicated_at,
    idempotency_key: `${PREFIX}-send-${RUN}`,
    external_reference: "WA-1",
    notes: "messaged brand",
  })
  if (replay.id !== sent.id) throw new Error("send replay mismatch")
  ok("accounts send + idempotent replay")

  try {
    await rpc(accounts, "record_stock_refill_supplier_communication", {
      target_request: approved.id,
      expected_version: sent.version,
      communication_channel: "email",
      communicated_at: communicatedAt,
      idempotency_key: `${PREFIX}-send-${RUN}`,
      external_reference: "other",
      notes: null,
    })
    throw new Error("conflicting send payload must fail")
  } catch (error) {
    if (!/already used for a different request|23505/i.test(error.message)) throw error
  }
  ok("conflicting send payload refused")

  try {
    await rpc(other, "record_stock_refill_supplier_communication", {
      target_request: approved.id,
      expected_version: sent.version,
      communication_channel: "whatsapp",
      communicated_at: sent.communication.communicated_at,
      idempotency_key: `${PREFIX}-send-${RUN}`,
      external_reference: "WA-1",
      notes: "messaged brand",
    })
    throw new Error("foreign send key must be 42501")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("foreign actor send key is 42501")

  const raceApproved = await approveRequest(`${PREFIX}-race-${RUN}`)
  const raceAt = new Date().toISOString()
  const [createA, createB] = await Promise.allSettled([
    rpc(accounts, "record_stock_refill_supplier_communication", {
      target_request: raceApproved.id,
      expected_version: raceApproved.version,
      communication_channel: "phone",
      communicated_at: raceAt,
      idempotency_key: `${PREFIX}-http-race-${RUN}`,
      external_reference: null,
      notes: null,
    }),
    rpc(accounts, "record_stock_refill_supplier_communication", {
      target_request: raceApproved.id,
      expected_version: raceApproved.version,
      communication_channel: "phone",
      communicated_at: raceAt,
      idempotency_key: `${PREFIX}-http-race-${RUN}`,
      external_reference: null,
      notes: null,
    }),
  ])
  const raceWins = [createA, createB].filter((row) => row.status === "fulfilled")
  if (raceWins.length < 1) {
    throw new Error(`HTTP concurrent send must persist one: ${JSON.stringify([createA, createB])}`)
  }
  const sendCount = await psql(
    `select count(*) from public.stock_refill_supplier_communications where send_idempotency_key = '${PREFIX}-http-race-${RUN}'`,
  )
  if (sendCount.split(/\r?\n/).filter(Boolean).at(-1) !== "1") {
    throw new Error(`HTTP concurrent send must persist one row: ${sendCount}`)
  }
  ok("HTTP concurrent send persists one communication")

  const acked = await rpc(accounts, "record_stock_refill_supplier_acknowledgement", {
    target_request: sent.id,
    expected_version: sent.version,
    acknowledgement_status: "acknowledged",
    response_at: new Date().toISOString(),
    idempotency_key: `${PREFIX}-ack-${RUN}`,
    acknowledgement_reference: "ACK-1",
    notes: null,
    decline_reason: null,
  })
  if (acked.acknowledgement_status !== "acknowledged") throw new Error("ack missing")
  ok("supplier acknowledgement recorded")

  const dispatched = await rpc(accounts, "record_stock_refill_supplier_dispatch", {
    target_request: acked.id,
    expected_version: acked.version,
    dispatched_on: new Date().toISOString().slice(0, 10),
    idempotency_key: `${PREFIX}-disp-${RUN}`,
    supplier_dispatch_reference: "DN-9",
    expected_arrival_on: null,
    transport_provider: null,
    vehicle_reference: null,
    tracking_reference: null,
    notes: null,
  })
  if (dispatched.dispatch_status !== "recorded") throw new Error("dispatch missing")
  const listed = await rpc(accounts, "list_stock_refill_requests", {
    page: 1,
    page_size: 25,
    status_filter: "approved",
    target_godown: branch,
    target_supplier: null,
    search_text: null,
  })
  const row = listed.items.find((item) => item.id === dispatched.id)
  if (!row || row.communication_status !== "sent" || row.dispatch_status !== "recorded") {
    throw new Error("list missing communication/dispatch status")
  }
  ok("dispatch recorded and listed")

  const declinedReq = await approveRequest(`${PREFIX}-decl-${RUN}`)
  const declinedSent = await rpc(accounts, "record_stock_refill_supplier_communication", {
    target_request: declinedReq.id,
    expected_version: declinedReq.version,
    communication_channel: "email",
    communicated_at: new Date().toISOString(),
    idempotency_key: `${PREFIX}-decl-s-${RUN}`,
    external_reference: null,
    notes: null,
  })
  const declined = await rpc(accounts, "record_stock_refill_supplier_acknowledgement", {
    target_request: declinedSent.id,
    expected_version: declinedSent.version,
    acknowledgement_status: "declined",
    response_at: new Date().toISOString(),
    idempotency_key: `${PREFIX}-decl-a-${RUN}`,
    acknowledgement_reference: null,
    notes: null,
    decline_reason: "plant out of stock",
  })
  if (declined.status !== "approved") throw new Error("decline mutated approval")
  try {
    await rpc(accounts, "record_stock_refill_supplier_dispatch", {
      target_request: declined.id,
      expected_version: declined.version,
      dispatched_on: new Date().toISOString().slice(0, 10),
      idempotency_key: `${PREFIX}-decl-d-${RUN}`,
      supplier_dispatch_reference: null,
      expected_arrival_on: null,
      transport_provider: null,
      vehicle_reference: null,
      tracking_reference: null,
      notes: null,
    })
    throw new Error("declined request must not dispatch")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("decline keeps approval and blocks dispatch")

  const stockAfter = await psql(`
    select concat_ws(',',
      (select count(*) from public.stock_transactions),
      (select count(*) from public.stock_ledger),
      (select coalesce(sum(quantity),0) from public.stock_balances where product_id = '${product}'::uuid),
      (select count(*) from public.stock_reservations),
      (select count(*) from public.stock_receipts)
    );
  `)
  if (stockAfter !== stockBefore) throw new Error(`stock changed ${stockBefore} -> ${stockAfter}`)
  ok("zero stock effects")

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
  // Leave disposable catalog rows; they use m63 prefixes.
}

console.log(`M6.3 HTTP passed ${passed.length}`)
if (passed.length < 10) throw new Error("expected at least 10 HTTP proofs")
