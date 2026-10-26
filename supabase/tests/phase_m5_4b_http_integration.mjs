/**
 * M5.4B local HTTP proofs for list_damage_report_sources against 127.0.0.1:54321.
 * Does not flip damage.stock_hold_ready or lot cutover flags.
 */
import { spawn } from "node:child_process"
import { createClient } from "@supabase/supabase-js"

const API = "http://127.0.0.1:54321"
const PASSWORD = "local-only-m54b"
const PREFIX = "m54bhttp"
const RUN = Date.now().toString(36)

function statusEnv() {
  return new Promise((resolve, reject) => {
    const child = spawn("npx", ["supabase", "status", "-o", "env"], {
      shell: true,
    })
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
      [
        "exec",
        "-i",
        "supabase_db_sherlyos",
        "psql",
        "-U",
        "postgres",
        "-d",
        "postgres",
        "-v",
        "ON_ERROR_STOP=1",
        "-tA",
      ],
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
  return (
    String(text).match(
      /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
    )?.[0] ?? ""
  )
}

function assertLocal(url) {
  const parsed = new URL(url)
  if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") {
    throw new Error(`refusing non-local host ${parsed.hostname}`)
  }
}

async function ensureUser(email, fullName) {
  const existing = firstUuid(
    await psql(`select id from auth.users where email = '${email}'`),
  )
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
  const auth = createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const result = await auth.auth.signInWithPassword({
    email,
    password: PASSWORD,
  })
  if (result.error || !result.data.session) {
    throw new Error(
      `sign-in failed for ${email}: ${result.error?.message ?? "no session"}`,
    )
  }
  return createClient(API, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      headers: { Authorization: `Bearer ${result.data.session.access_token}` },
    },
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
    /not authorized|permission/i.test(error.message || "")
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
  admin: await ensureUser(`admin.${PREFIX}@example.com`, "M54B Admin"),
  godown: await ensureUser(`godown.${PREFIX}@example.com`, "M54B Godown"),
  keeper: await ensureUser(`keeper.${PREFIX}@example.com`, "M54B Keeper"),
  driver: await ensureUser(`driver.${PREFIX}@example.com`, "M54B Driver"),
  sales: await ensureUser(`sales.${PREFIX}@example.com`, "M54B Sales"),
}

await psql(`
  insert into public.profiles (id, full_name, is_active)
  values
    ('${users.admin}', 'M54B Admin', true),
    ('${users.godown}', 'M54B Godown', true),
    ('${users.keeper}', 'M54B Keeper', true),
    ('${users.driver}', 'M54B Driver', true),
    ('${users.sales}', 'M54B Sales', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select u.id, r.id, '${users.admin}'::uuid
  from (values
    ('${users.admin}'::uuid, 'admin'),
    ('${users.godown}'::uuid, 'godown_manager'),
    ('${users.keeper}'::uuid, 'store_keeper'),
    ('${users.driver}'::uuid, 'delivery_person'),
    ('${users.sales}'::uuid, 'salesperson')
  ) u(id, role_code)
  join public.roles r on r.code = u.role_code
  on conflict do nothing;
`)

const admin = await signIn(env.ANON_KEY, `admin.${PREFIX}@example.com`)
const godown = await signIn(env.ANON_KEY, `godown.${PREFIX}@example.com`)
const keeper = await signIn(env.ANON_KEY, `keeper.${PREFIX}@example.com`)
const driver = await signIn(env.ANON_KEY, `driver.${PREFIX}@example.com`)
const sales = await signIn(env.ANON_KEY, `sales.${PREFIX}@example.com`)

const branch = await rpc(admin, "create_branch", {
  branch_code: `${PREFIX}_${RUN}`,
  branch_name: "M54B HTTP Godown",
})
await rpc(admin, "assign_user_branch", {
  target_user: users.godown,
  target_branch: branch,
})
await rpc(admin, "assign_user_branch", {
  target_user: users.keeper,
  target_branch: branch,
})
await rpc(admin, "assign_user_branch", {
  target_user: users.driver,
  target_branch: branch,
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
const product = await rpc(admin, "create_product", {
  product_sku: `${PREFIX}-${RUN}`,
  product_name: "M54B HTTP Soap",
  next_supplier: null,
  next_category: null,
})
const supplier = await rpc(admin, "create_supplier", {
  supplier_name: `M54B supplier ${RUN}`,
  supplier_phone: null,
  supplier_email: null,
})

await psql(`
  set session_replication_role = replica;
  insert into public.stock_balances (crate_id, product_id, quantity)
  values ('${crate}', '${product}', 4)
  on conflict (crate_id, product_id) do nothing;
  insert into public.stock_receipts (
    receipt_number, godown_id, supplier_id, document_reference,
    normalized_document_reference, received_date, status, created_by,
    verified_by, verified_at, posted_at, posting_idempotency_key, posting_fingerprint
  )
  values (
    '${PREFIX}-RCV-${RUN}', '${branch}', '${supplier}', 'M54B-HTTP',
    'm54b-http-${RUN}', current_date, 'posted', '${users.keeper}',
    '${users.godown}', now(), now(), '${PREFIX}-rcv-${RUN}', '${PREFIX}-rcv-fp-${RUN}'
  );
  insert into public.stock_receipt_lines (
    receipt_id, product_id, destination_crate_id, document_cases, counted_cases, damaged_cases
  )
  select id, '${product}', '${crate}', 8, 6, 2
  from public.stock_receipts where receipt_number = '${PREFIX}-RCV-${RUN}';
  set session_replication_role = origin;
`)

try {
  const inbound = await rpc(godown, "list_damage_report_sources", {
    scenario: "refill_supply",
    target_godown: branch,
  })
  if (!inbound.items?.some((row) => row.label === `${PREFIX}-RCV-${RUN}`)) {
    throw new Error(
      `GM inbound picker missed receipt: ${JSON.stringify(inbound)}`,
    )
  }
  ok("gm inbound sources")

  const receiptId = firstUuid(
    await psql(
      `select id from public.stock_receipts where receipt_number = '${PREFIX}-RCV-${RUN}'`,
    ),
  )
  const receiptLine = firstUuid(
    await psql(
      `select id from public.stock_receipt_lines where receipt_id = '${receiptId}'`,
    ),
  )
  const created = await rpc(keeper, "create_damage_report", {
    scenario: "unloading",
    target_godown: branch,
    report_lines: [
      {
        product_id: product,
        quantity_cases: 1,
        damage_reason: "torn wrap",
        receipt_line_id: receiptLine,
      },
    ],
    idempotency_key: `${PREFIX}-upd-${RUN}`,
    notes: "original",
    receipt_id: receiptId,
  })
  const updated = await rpc(keeper, "update_damage_report", {
    target_report: created.id,
    expected_version: created.version,
    report_lines: [
      {
        product_id: product,
        quantity_cases: 1,
        damage_reason: "torn wrap",
        receipt_line_id: receiptLine,
      },
    ],
    notes: "edited via http",
    receipt_id: receiptId,
  })
  if (updated.notes !== "edited via http") {
    throw new Error(`draft update failed: ${JSON.stringify(updated)}`)
  }
  ok("keeper draft update via postgrest")

  const jpeg = Buffer.from("ffd8ffd9", "hex")
  const jpegBinary = Buffer.from("ffd8ff0080ffd9", "hex")
  const png = Buffer.from(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6360000002000100ffff03000006000557bf0d0000000049454e44ae426082",
    "hex",
  )
  const photo = await rpc(keeper, "create_damage_photo_upload", {
    target_report: created.id,
    photo_note: "http photo",
  })
  try {
    await rpc(keeper, "finalize_damage_photo_upload", {
      target_evidence: photo.id,
      image_base64: jpeg.toString("base64"),
    })
    throw new Error("missing storage object finalized")
  } catch (error) {
    if (
      /missing storage object finalized/.test(error.message) ||
      !/could not be verified/i.test(error.message)
    ) {
      throw error
    }
    ok("missing storage object fails closed")
  }
  const uploaded = await keeper.storage
    .from(photo.bucket)
    .upload(photo.path, jpeg, {
      contentType: "image/jpeg",
      upsert: false,
    })
  if (uploaded.error) throw new Error(uploaded.error.message)
  try {
    await rpc(keeper, "finalize_damage_photo_upload", {
      target_evidence: photo.id,
      image_base64: png.toString("base64"),
    })
    throw new Error("mismatched storage payload finalized")
  } catch (error) {
    if (
      /mismatched storage payload finalized/.test(error.message) ||
      !/could not be verified/i.test(error.message)
    ) {
      throw error
    }
    ok("mismatched stored bytes fail closed")
  }
  await rpc(keeper, "finalize_damage_photo_upload", {
    target_evidence: photo.id,
    image_base64: jpeg.toString("base64"),
  })
  ok("matching stored bytes finalize")
  try {
    await rpc(keeper, "finalize_damage_photo_upload", {
      target_evidence: photo.id,
      image_base64: jpeg.toString("base64"),
    })
    throw new Error("replay finalize succeeded")
  } catch (error) {
    if (
      /replay finalize succeeded/.test(error.message) ||
      !/cannot be changed|not authorized/i.test(error.message)
    ) {
      throw error
    }
    ok("replay finalize fails closed")
  }
  const foreign = await rpc(keeper, "create_damage_photo_upload", {
    target_report: created.id,
    photo_note: "wrong uploader",
  })
  const foreignUpload = await keeper.storage
    .from(foreign.bucket)
    .upload(foreign.path, jpeg, {
      contentType: "image/jpeg",
      upsert: false,
    })
  if (foreignUpload.error) throw new Error(foreignUpload.error.message)
  try {
    await rpc(godown, "finalize_damage_photo_upload", {
      target_evidence: foreign.id,
      image_base64: jpeg.toString("base64"),
    })
    throw new Error("wrong uploader finalized")
  } catch (error) {
    if (
      /wrong uploader finalized/.test(error.message) ||
      !/not authorized|cannot be changed/i.test(error.message)
    ) {
      throw error
    }
    ok("wrong uploader fails closed")

    const binaryPhoto = await rpc(keeper, "create_damage_photo_upload", {
      target_report: created.id,
      photo_note: "binary fidelity",
    })
    const binaryUpload = await keeper.storage
      .from(binaryPhoto.bucket)
      .upload(binaryPhoto.path, jpegBinary, {
        contentType: "image/jpeg",
        upsert: false,
      })
    if (binaryUpload.error) throw new Error(binaryUpload.error.message)
    await rpc(keeper, "finalize_damage_photo_upload", {
      target_evidence: binaryPhoto.id,
      image_base64: jpegBinary.toString("base64"),
    })
    ok("stored bytes with NUL and high bytes finalize")
  }

  const storage = await rpc(godown, "list_damage_report_sources", {
    scenario: "storage",
    target_godown: branch,
  })
  if (storage.items?.[0]?.kind !== "godown") {
    throw new Error("GM storage picker must return the godown catalog")
  }
  ok("gm storage sources")

  try {
    await rpc(keeper, "list_damage_report_sources", {
      scenario: "storage",
      target_godown: branch,
    })
    throw new Error("store keeper listed storage sources")
  } catch (error) {
    if (!denied(error)) throw error
    ok("keeper denied storage sources")
  }

  try {
    await rpc(driver, "list_damage_report_sources", {
      scenario: "storage",
      target_godown: branch,
    })
    throw new Error("driver listed storage sources")
  } catch (error) {
    if (!denied(error)) throw error
    ok("driver denied storage sources")
  }

  try {
    await rpc(sales, "list_damage_report_sources", {
      scenario: "refill_supply",
      target_godown: branch,
    })
    throw new Error("salesperson listed inbound sources")
  } catch (error) {
    if (!denied(error)) throw error
    ok("sales denied sources")
  }

  try {
    await rpc(admin, "list_damage_report_sources", {
      scenario: "storage",
      target_godown: branch,
    })
    throw new Error("admin listed operational sources")
  } catch (error) {
    if (!denied(error)) throw error
    ok("admin denied operational sources")
  }

  const flags = await psql(`
    select string_agg(key || '=' || (value #>> '{}'), ',')
    from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    );
  `)
  if (
    !/damage.stock_hold_ready=false/.test(flags) ||
    !/dual_write_enabled=false/.test(flags)
  ) {
    throw new Error(`cutover flags changed: ${flags}`)
  }
  ok("cutover flags unchanged")
} finally {
  await psql(`
    set session_replication_role = replica;
    delete from storage.objects
    where bucket_id = 'stock-damage-evidence'
      and name like '%' || (
        select id::text from public.damage_reports
        where notes = 'edited via http'
        limit 1
      ) || '%';
    delete from public.damage_evidence
    where damage_report_id in (
      select id from public.damage_reports
      where reporter_user_id in ('${users.keeper}', '${users.godown}')
    );
    delete from public.damage_report_events
    where damage_report_id in (
      select id from public.damage_reports where notes like '${PREFIX}%'
         or reporter_user_id in ('${users.keeper}', '${users.godown}')
    );
    delete from public.damage_report_lines
    where damage_report_id in (
      select id from public.damage_reports
      where reporter_user_id in ('${users.keeper}', '${users.godown}')
        and notes in ('original', 'edited via http')
    );
    delete from public.damage_reports
    where notes in ('original', 'edited via http');
    delete from public.stock_receipt_lines
    where receipt_id in (select id from public.stock_receipts where receipt_number like '${PREFIX}-%');
    delete from public.stock_receipts where receipt_number like '${PREFIX}-%';
    delete from public.stock_balances where crate_id = '${crate}';
    set session_replication_role = origin;
  `)
}

console.log(`M5.4B HTTP ${passed.length} passed`)
