/**
 * M6.2 local HTTP proofs against 127.0.0.1:54321 only.
 * Does not flip damage.stock_hold_ready or lot cutover flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m62"
const PREFIX = "m62http"
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M62 Admin"),
  accounts: await ensureUser(`accounts.${PREFIX}@example.com`, "M62 Accounts"),
  other: await ensureUser(`other.${PREFIX}@example.com`, "M62 Other Accounts"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M62 Godown"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M62 Admin', true),
    ('${users.accounts}', 'M62 Accounts', true),
    ('${users.other}', 'M62 Other Accounts', true),
    ('${users.godown}', 'M62 Godown', true)
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
  branch_name: "M62 HTTP A",
})
const branchB = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}b_${RUN}`,
  branch_name: "M62 HTTP B",
})
await rpc(admin, "assign_user_branch", { target_user: users.accounts, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.godown, target_branch: branch })
await rpc(admin, "assign_user_branch", { target_user: users.other, target_branch: branchB })
const supplier = await rpc(admin, "create_supplier", {
  supplier_name: `M62 brand ${RUN}`,
  supplier_phone: null,
  supplier_email: null,
})
const otherSupplier = await rpc(admin, "create_supplier", {
  supplier_name: `M62 other brand ${RUN}`,
  supplier_phone: null,
  supplier_email: null,
})
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`,
  product_name: "M62 HTTP Soap",
  next_supplier: supplier,
  next_category: null,
})
const otherProduct = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-o-${RUN}`,
  product_name: "M62 Other Soap",
  next_supplier: otherSupplier,
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
  values ('${crate}'::uuid, '${product}'::uuid, 11)
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

try {
  try {
    await rpc(admin, "create_stock_refill_request", {
      target_supplier: supplier,
      target_godown: branch,
      request_lines: [{ product_id: product, requested_cases: 2 }],
      idempotency_key: `${PREFIX}-adm-${RUN}`,
      notes: null,
    })
    throw new Error("admin must not create refill requests")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("admin cannot create")

  try {
    await rpc(godown, "list_stock_refill_requests", {})
    throw new Error("godown manager must not list refill requests")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("godown manager cannot list")

  try {
    await rpc(accounts, "create_stock_refill_request", {
      target_supplier: supplier,
      target_godown: branch,
      request_lines: [{ product_id: otherProduct, requested_cases: 1 }],
      idempotency_key: `${PREFIX}-badsku-${RUN}`,
      notes: null,
    })
    throw new Error("wrong-brand SKU must fail")
  } catch (error) {
    if (!/product must be an active SKU|23514/i.test(error.message)) throw error
  }
  ok("supplier/product consistency")

  const created = await rpc(accounts, "create_stock_refill_request", {
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [{ product_id: product, requested_cases: 4 }],
    idempotency_key: `${PREFIX}-create-${RUN}`,
    notes: "http draft",
  })
  if (created.status !== "draft") throw new Error(`expected draft, got ${created.status}`)
  const replay = await rpc(accounts, "create_stock_refill_request", {
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [{ product_id: product, requested_cases: 4 }],
    idempotency_key: `${PREFIX}-create-${RUN}`,
    notes: "http draft",
  })
  if (replay.id !== created.id) throw new Error("create idempotency replay mismatch")
  ok("accounts create + idempotent replay")

  try {
    await rpc(accounts, "create_stock_refill_request", {
      target_supplier: supplier,
      target_godown: branch,
      request_lines: [{ product_id: product, requested_cases: 9 }],
      idempotency_key: `${PREFIX}-create-${RUN}`,
      notes: "http draft",
    })
    throw new Error("conflicting payload must not replay")
  } catch (error) {
    if (!/already used for a different request|23505/i.test(error.message)) throw error
  }
  ok("same key different payload refused")

  try {
    await rpc(other, "create_stock_refill_request", {
      target_supplier: supplier,
      target_godown: branchB,
      request_lines: [{ product_id: product, requested_cases: 4 }],
      idempotency_key: `${PREFIX}-create-${RUN}`,
      notes: "http draft",
    })
    throw new Error("foreign actor must not reuse another creator key")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("foreign actor create key is 42501")

  const [createA, createB] = await Promise.allSettled([
    rpc(accounts, "create_stock_refill_request", {
      target_supplier: supplier,
      target_godown: branch,
      request_lines: [{ product_id: product, requested_cases: 2 }],
      idempotency_key: `${PREFIX}-http-race-${RUN}`,
      notes: null,
    }),
    rpc(accounts, "create_stock_refill_request", {
      target_supplier: supplier,
      target_godown: branch,
      request_lines: [{ product_id: product, requested_cases: 2 }],
      idempotency_key: `${PREFIX}-http-race-${RUN}`,
      notes: null,
    }),
  ])
  const httpWins = [createA, createB].filter((row) => row.status === "fulfilled")
  const httpIds = [...new Set(httpWins.map((row) => row.value.id))]
  if (httpWins.length < 1 || httpIds.length !== 1) {
    throw new Error(`HTTP concurrent create must persist one request: ${JSON.stringify([createA, createB])}`)
  }
  const httpRaceCount = await psql(
    `select count(*) from public.stock_refill_requests where idempotency_key = '${PREFIX}-http-race-${RUN}'`,
  )
  if (httpRaceCount !== "1") throw new Error(`expected one HTTP raced row, got ${httpRaceCount}`)
  ok("HTTP concurrent create persists one request")

  const listed = await rpc(accounts, "list_stock_refill_requests", {
    page: 1,
    page_size: 25,
    status_filter: "draft",
    target_godown: branch,
    target_supplier: supplier,
    search_text: created.request_number,
  })
  if (!listed.items.some((row) => row.id === created.id)) {
    throw new Error("list missing created request")
  }
  const options = await rpc(accounts, "list_stock_refill_options", {})
  if (!options.products.some((row) => row.id === product)) {
    throw new Error("options missing supplier SKU")
  }
  ok("list and options")

  try {
    await rpc(other, "get_stock_refill_request", { target_request: created.id })
    throw new Error("cross-godown accounts must not read")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("godown-scoped read")

  const updated = await rpc(accounts, "update_stock_refill_request", {
    target_request: created.id,
    expected_version: created.version,
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [{ product_id: product, requested_cases: 6 }],
    notes: "revised",
  })
  try {
    await rpc(accounts, "update_stock_refill_request", {
      target_request: created.id,
      expected_version: created.version,
      target_supplier: supplier,
      target_godown: branch,
      request_lines: [{ product_id: product, requested_cases: 1 }],
      notes: "stale",
    })
    throw new Error("stale update must conflict")
  } catch (error) {
    if (!/PT409|changed by someone else/i.test(error.message)) throw error
  }
  ok("optimistic version")

  const submitted = await rpc(accounts, "submit_stock_refill_request", {
    target_request: updated.id,
    expected_version: updated.version,
    idempotency_key: `${PREFIX}-sub-${RUN}`,
  })
  if (submitted.status !== "submitted") throw new Error(`expected submitted, got ${submitted.status}`)
  const submitReplay = await rpc(accounts, "submit_stock_refill_request", {
    target_request: updated.id,
    expected_version: updated.version,
    idempotency_key: `${PREFIX}-sub-${RUN}`,
  })
  if (submitReplay.status !== "submitted") throw new Error("submit replay must stay submitted")
  ok("submit + replay")

  const held = await rpc(admin, "hold_stock_refill_request", {
    target_request: submitted.id,
    expected_version: submitted.version,
    decision_reason: "need fewer cases",
    idempotency_key: `${PREFIX}-hold-${RUN}`,
  })
  if (held.status !== "held") throw new Error(`expected held, got ${held.status}`)
  const revised = await rpc(accounts, "update_stock_refill_request", {
    target_request: held.id,
    expected_version: held.version,
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [{ product_id: product, requested_cases: 3 }],
    notes: "held revision",
  })
  const resubmitted = await rpc(accounts, "submit_stock_refill_request", {
    target_request: revised.id,
    expected_version: revised.version,
    idempotency_key: `${PREFIX}-resub-${RUN}`,
  })
  if (resubmitted.status !== "submitted") throw new Error("resubmit must return submitted")
  ok("hold, edit, resubmit")

  const approved = await rpc(admin, "approve_stock_refill_request", {
    target_request: resubmitted.id,
    expected_version: resubmitted.version,
    idempotency_key: `${PREFIX}-apr-${RUN}`,
    decision_reason: "send later",
  })
  if (approved.status !== "approved") throw new Error(`expected approved, got ${approved.status}`)
  try {
    await rpc(accounts, "update_stock_refill_request", {
      target_request: approved.id,
      expected_version: approved.version,
      target_supplier: supplier,
      target_godown: branch,
      request_lines: [{ product_id: product, requested_cases: 1 }],
      notes: "after approve",
    })
    throw new Error("approved request must be immutable")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("admin approve is immutable")

  const rejectDraft = await rpc(accounts, "create_stock_refill_request", {
    target_supplier: supplier,
    target_godown: branch,
    request_lines: [{ product_id: product, requested_cases: 1 }],
    idempotency_key: `${PREFIX}-rej-c-${RUN}`,
    notes: null,
  })
  const rejectSubmitted = await rpc(accounts, "submit_stock_refill_request", {
    target_request: rejectDraft.id,
    expected_version: rejectDraft.version,
    idempotency_key: `${PREFIX}-rej-s-${RUN}`,
  })
  const rejected = await rpc(admin, "reject_stock_refill_request", {
    target_request: rejectSubmitted.id,
    expected_version: rejectSubmitted.version,
    decision_reason: "out of season",
    idempotency_key: `${PREFIX}-rej-${RUN}`,
  })
  if (rejected.status !== "rejected") throw new Error(`expected rejected, got ${rejected.status}`)
  try {
    await rpc(accounts, "submit_stock_refill_request", {
      target_request: rejected.id,
      expected_version: rejected.version,
      idempotency_key: `${PREFIX}-rej-again-${RUN}`,
    })
    throw new Error("rejected request must be terminal")
  } catch (error) {
    if (!denied(error)) throw error
  }
  ok("reject is terminal")

  const stockAfter = await psql(`
    select concat_ws(',',
      (select count(*) from public.stock_transactions),
      (select count(*) from public.stock_ledger),
      (select coalesce(sum(quantity),0) from public.stock_balances where product_id = '${product}'::uuid),
      (select count(*) from public.stock_reservations),
      (select count(*) from public.stock_receipts)
    );
  `)
  if (stockAfter !== stockBefore) {
    throw new Error(`zero stock effects failed ${stockBefore} -> ${stockAfter}`)
  }
  ok("zero stock effects")

  const flags = await psql(`
    select string_agg(key || '=' || value::text, ',' order by key)
    from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    );
  `)
  if (/true/i.test(flags)) throw new Error(`flags must stay false: ${flags}`)
  ok("cutover flags remain false")
} finally {
  // Disposable HTTP rows stay local; flags are asserted false above.
}

console.log(`M6.2 HTTP passed ${passed.length}`)
