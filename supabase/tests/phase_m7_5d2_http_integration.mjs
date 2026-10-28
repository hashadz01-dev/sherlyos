/**
 * M7.5D.2 local HTTP proofs. Eligibility only.
 * Does not issue tax invoices, allocate legal numbers, or flip flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m75d2"
const PREFIX = "m75d2http"
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
      if (code !== 0) reject(new Error(text || `psql exit ${code}`))
      else resolve(text)
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

assertLocal(API)
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M75D2 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M75D2 Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M75D2 Godown"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M75D2 Other GM"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M75D2 Driver"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M75D2 Admin', true),
    ('${users.accounts}', 'M75D2 Accounts', true),
    ('${users.godown}', 'M75D2 Godown', true),
    ('${users.other}', 'M75D2 Other GM', true),
    ('${users.driver}', 'M75D2 Driver', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.accounts}'::uuid, 'accounts'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.other}'::uuid, 'godown_manager'),
    ('${users.driver}'::uuid, 'delivery_person')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const accounts = await signIn(env.ANON_KEY, `accounts.${PREFIX}@example.com`)
const other = await signIn(env.ANON_KEY, `other.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)

const ledgerBefore = await psql("select count(*) from public.stock_ledger")

const noteRow = await psql(`
  select invoice_notes.id || ' ' || invoice_notes.branch_id
  from public.invoice_notes
  join public.invoice_tax_previews
    on invoice_tax_previews.invoice_note_id = invoice_notes.id
   and invoice_tax_previews.is_current
  where invoice_notes.status = 'reviewed'
  order by invoice_notes.created_at desc
  limit 1
`)
const [noteId, noteBranch] = String(noteRow).trim().split(/\s+/)
if (!noteId || !noteBranch) throw new Error("reviewed invoice note with tax preview is required")

const staleNote = firstUuid(
  await psql(`
    select invoice_notes.id
    from public.invoice_notes
    join public.invoice_tax_previews
      on invoice_tax_previews.invoice_note_id = invoice_notes.id
     and invoice_tax_previews.is_current
    where invoice_notes.status = 'reviewed'
      and invoice_tax_previews.invoice_note_version is distinct from invoice_notes.version
    limit 1
  `),
)

function asId(value) {
  if (!value) return ""
  if (typeof value === "string") return value
  return value.id ?? value.branch_id ?? ""
}

await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: noteBranch })
const otherBranch = asId(
  await rpc(admin, "create_branch", {
    branch_code: `${PREFIX}_x_${RUN}`,
    branch_name: "M75D2 other",
  }),
)
await rpc(admin, "assign_user_branch", { target_user: users.other, target_branch: otherBranch })

const org = await rpc(accounts, "assess_invoice_finalization_readiness", {})
if (org.ready !== false || org.legal_issuance_blocked !== true) {
  throw new Error("org eligibility must stay blocked")
}
const orgCodes = (org.blockers ?? []).map((row) => row.code)
for (const code of [
  "finalize_rpc_disabled",
  "statutory_issuance_disabled",
  "legal_numbering_allocation_disabled",
  "tax_preview_is_not_a_tax_invoice",
]) {
  if (!orgCodes.includes(code)) throw new Error(`missing org blocker ${code}`)
}
ok("accounts org eligibility stays blocked")

const noteReady = await rpc(accounts, "assess_invoice_finalization_readiness", {
  p_invoice_note_id: noteId,
})
if (noteReady.ready !== false || noteReady.numbering_allocation_enabled !== false) {
  throw new Error("note eligibility must stay blocked")
}
ok("accounts note eligibility stays blocked")

if (staleNote) {
  const stale = await rpc(admin, "assess_invoice_finalization_readiness", {
    p_invoice_note_id: staleNote,
  })
  if (!(stale.blockers ?? []).some((row) => row.code === "tax_preview_stale")) {
    throw new Error("stale tax preview must be a blocker")
  }
  ok("stale tax preview is rejected")
}

const cancelReady = await rpc(accounts, "assess_statutory_cancellation_readiness", {})
if (cancelReady.ready !== false || cancelReady.legal_cancellation_blocked !== true) {
  throw new Error("cancellation must stay blocked")
}
ok("cancellation foundation stays blocked")

try {
  await rpc(driver, "assess_invoice_finalization_readiness", {})
  throw new Error("driver must be denied eligibility")
} catch (error) {
  if (!/not authorized|permission denied/i.test(error.message)) throw error
}
ok("driver cannot assess eligibility")

try {
  await rpc(other, "assess_invoice_finalization_readiness", {
    p_invoice_note_id: noteId,
  })
  throw new Error("cross-godown manager must be denied")
} catch (error) {
  if (!/not authorized|permission denied/i.test(error.message)) throw error
}
ok("cross-godown eligibility is denied")

const missing = await admin.rpc("finalize_invoice_note", {
  p_invoice_note_id: noteId,
  p_expected_version: 1,
})
if (!missing.error) throw new Error("finalize RPC must not exist")
ok("public finalize RPC is absent")

const allocateMissing = await admin.rpc("allocate_statutory_invoice_number", {
  p_series_code: "SDI",
})
if (!allocateMissing.error) throw new Error("allocate RPC must not exist")
ok("public allocate RPC is absent")

const legalCount = await psql(`
  select count(*) from public.statutory_invoices
  where legal_invoice_number is not null or issued_at is not null
`)
if (String(legalCount).trim() !== "0") throw new Error("no legal invoice numbers may exist")
ok("no legal invoice numbers allocated")

const ledgerAfter = await psql("select count(*) from public.stock_ledger")
if (ledgerBefore !== ledgerAfter) throw new Error("eligibility must not write stock")
const flags = await psql(`
  select string_agg(key || '=' || value::text, ',')
  from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  )
`)
if (/true/.test(flags)) throw new Error(`flags must stay false: ${flags}`)
ok("stock and operational flags unchanged")

console.log(`M7.5D.2 HTTP passed ${passed.length} checks`)
