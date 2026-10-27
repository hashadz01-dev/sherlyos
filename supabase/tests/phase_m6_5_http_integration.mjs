/**
 * M6.5 local HTTP proofs against 127.0.0.1:54321 only.
 * Read-only refill queue/reporting. Zero stock writers.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m65"
const PREFIX = "m65http"
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M65 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M65 Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M65 Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M65 Keeper"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M65 Admin', true),
    ('${users.accounts}', 'M65 Accounts', true),
    ('${users.godown}', 'M65 Godown', true),
    ('${users.keeper}', 'M65 Keeper', true)
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
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M65 HTTP A",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.keeper, target_branch: branch })
const supplier = await rpc(admin, "create_supplier", {
  supplier_name: `M65 brand ${RUN}`,
  supplier_phone: null,
  supplier_email: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-a-${RUN}`,
  product_name: "M65 HTTP A",
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

const txBefore = await psql(`select count(*) from public.stock_transactions;`)

async function approveRequest(key, qty) {
  const created = await rpc(accounts, "create_stock_refill_request", {
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [{ product_id: product, requested_cases: qty }],
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
  const open = await approveRequest(`${PREFIX}-open-${RUN}`, 12)
  const sent = await approveRequest(`${PREFIX}-sent-${RUN}`, 9)
  await rpc(accounts, "record_stock_refill_supplier_communication", {
    target_request: sent.id,
    expected_version: sent.version,
    communication_channel: "whatsapp",
    communicated_at: new Date().toISOString(),
    idempotency_key: `${PREFIX}-send-${RUN}`,
    external_reference: "WA-65",
    notes: null,
  })
  await rpc(keeper, "create_stock_receipt", {
    target_godown: branch,
    target_supplier: supplier,
    supplier_document: `${PREFIX}-draft-${RUN}`,
    received_on: new Date().toISOString().slice(0, 10),
    receipt_notes: null,
    line_items: [
      {
        product_id: product,
        destination_crate_id: crate,
        document_cases: 4,
        counted_cases: 4,
        damaged_cases: 0,
      },
    ],
    target_refill_request: open.id,
  })

  const recon = await rpc(accounts, "get_stock_refill_receiving_reconciliation", {
    target_request: open.id,
  })
  if (recon.receiving.summary.draft_reserved_cases !== 4) {
    throw new Error("HTTP draft reservation missing")
  }
  if (recon.receiving.summary.accepted_cases !== 0) {
    throw new Error("draft counted as accepted")
  }
  ok("draft reservation is separate from accepted stock")

  const filtered = await rpc(accounts, "list_stock_refill_requests", {
    communication_filter: "sent",
  })
  if (!filtered.items.some((row) => row.id === sent.id) || filtered.items.some((row) => row.id === open.id)) {
    throw new Error("communication filter leaked unsent rows")
  }
  ok("queue communication filter is server-backed")

  const report = await rpc(accounts, "list_stock_refill_report", {
    receiving_filter: "not_started",
  })
  if (report.total_count < 1 || !report.summary) {
    throw new Error("refill report missing summary")
  }
  ok("refill report returns authorized progress totals")

  const csv = await rpc(accounts, "export_stock_refill_report", {})
  if (!String(csv.csv).includes("request_number")) throw new Error("csv header missing")
  ok("refill report export is authorized CSV")

  try {
    await rpc(keeper, "list_stock_refill_report", {})
    throw new Error("keeper must not read refill report")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("store keeper cannot read refill reporting")

  try {
    await rpc(godown, "list_stock_refill_requests", {})
    throw new Error("godown manager must not list refill")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("godown manager cannot list refill requests")

  const txAfter = await psql(`select count(*) from public.stock_transactions;`)
  if (txAfter !== txBefore) throw new Error("M6.5 HTTP posted stock")
  ok("reporting posted zero stock")

  const flags = await psql(`
    select string_agg(value::text, ',' order by key)
    from public.app_configuration
    where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked');
  `)
  if (!flags.split(/\r?\n/).filter(Boolean).at(-1)?.includes("false")) {
    throw new Error("flags missing")
  }
  ok("cutover flags remain false")
} catch (error) {
  console.error(error)
  process.exitCode = 1
}

console.log(`M6.5 HTTP passed ${passed.length}`)
if (process.exitCode !== 1 && passed.length < 7) {
  throw new Error("expected at least 7 HTTP proofs")
}
