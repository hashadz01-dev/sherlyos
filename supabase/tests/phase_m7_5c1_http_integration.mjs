/**
 * M7.5C.1 local HTTP proofs against 127.0.0.1:54321 only.
 * Does not issue tax invoices, allocate statutory numbers, or leave flags true.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m75c1"
const PREFIX = "m75c1http"
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M75C1 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M75C1 Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M75C1 Godown"),
  verifier: await ensureUser(`verifier.${PREFIX}@example.com`, "M75C1 Verifier"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M75C1 Admin', true),
    ('${users.accounts}', 'M75C1 Accounts', true),
    ('${users.godown}', 'M75C1 Godown', true),
    ('${users.verifier}', 'M75C1 Verifier', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.verifier}'::uuid, 'statutory_verifier')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const verifier = await signIn(env.ANON_KEY, `verifier.${PREFIX}@example.com`)

let ownership = `OWN-${RUN}`
try {
  const operating = await rpc(admin, "upsert_statutory_operating_ownership", {
    p_ownership_code: ownership,
    p_effective_from: new Date().toISOString().slice(0, 10),
    p_expected_version: 1,
  })
  ownership = operating.ownership_code
} catch {
  const listed = await rpc(admin, "list_statutory_operating_ownership")
  const open = (listed ?? []).find((row) =>
    ["draft", "submitted", "verified"].includes(row.status),
  )
  if (!open) throw new Error("operating ownership is required")
  ownership = open.ownership_code
}
let seller
try {
  seller = await rpc(admin, "upsert_statutory_seller_identity", {
    p_ownership_code: ownership,
    p_legal_name: "Local QA Seller",
    p_registered_address: "QA address",
    p_state_code: "27",
    p_gstin: "27AAAAA0000A1Z5",
    p_signature_caption: "QA signatory",
    p_effective_from: new Date().toISOString().slice(0, 10),
    p_expected_version: 1,
  })
} catch (error) {
  if (!/unique|open|duplicate/i.test(error.message)) throw error
  const listedSellers = await rpc(admin, "list_statutory_seller_identities")
  seller = (listedSellers ?? []).find((row) =>
    ["draft", "submitted", "verified"].includes(row.status),
  )
  if (!seller) throw error
}
ok("admin can prepare seller identity")

let submitted = seller
if (seller.status === "draft") {
  submitted = await rpc(admin, "submit_statutory_seller_identity", {
    p_id: seller.id,
    p_expected_version: seller.version,
  })
}
ok("admin can submit seller identity")

let accountsBlocked = false
try {
  await rpc(accounts, "verify_statutory_seller_identity", {
    p_id: submitted.id,
    p_expected_version: submitted.version,
  })
} catch (error) {
  accountsBlocked = /not authorized|permission denied/i.test(error.message)
}
if (!accountsBlocked) throw new Error("accounts must not verify statutory configuration")
ok("accounts cannot verify statutory configuration")

let godownBlocked = false
try {
  await rpc(godown, "list_statutory_seller_identities")
} catch (error) {
  godownBlocked = /not authorized|permission denied/i.test(error.message)
}
if (!godownBlocked) throw new Error("godown must not list statutory configuration")
ok("godown cannot list statutory configuration")

try {
  const verified = await rpc(verifier, "verify_statutory_seller_identity", {
    p_id: submitted.id,
    p_expected_version: submitted.version,
  })
  if (verified.status !== "verified") throw new Error("verifier did not approve seller identity")
  ok("statutory_verifier can approve seller identity")
} catch (error) {
  if (!/overlap/i.test(error.message)) throw error
  ok("statutory_verifier approval remains fail-closed on overlapping verified windows")
}

const listed = await rpc(accounts, "list_invoice_notes", {
  p_status: null,
  p_branch_id: null,
  p_shop_id: null,
})
if (!Array.isArray(listed)) throw new Error("M7.5B list_invoice_notes must still work")
ok("M7.5B invoice-note list still works")

const readiness = await rpc(accounts, "assess_invoice_finalization_readiness", {
  p_invoice_note_id: null,
})
if (readiness.ready !== false) throw new Error("readiness must stay false")
if (readiness.legal_issuance_blocked !== true) throw new Error("issuance must stay blocked")
const codes = (readiness.blockers ?? []).map((row) => row.code)
if (!codes.includes("finalize_rpc_disabled")) {
  throw new Error(`hard issuance blocker missing: ${codes.join(",")}`)
}
if (readiness.ready !== false) throw new Error("readiness must stay false")
ok("readiness stays false with hard C.2 blockers")

const missing = await psql(`
  select
    to_regprocedure('public.finalize_invoice_note(uuid, integer)') is null
    and to_regprocedure('public.issue_tax_invoice(uuid, integer)') is null
    and to_regprocedure('public.allocate_statutory_invoice_number(text)') is null
`)
if (String(missing).trim() !== "t") throw new Error("issuance RPCs must not exist")
ok("no statutory numbering or finalize RPC")

const flags = await psql(`
  select string_agg(key || '=' || value::text, ',')
  from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  )
`)
if (/true/i.test(flags)) throw new Error(`operational flags must stay false: ${flags}`)
ok("operational flags remain false")

console.log(`M7.5C.1 HTTP passed ${passed.length} checks`)
