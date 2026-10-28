/**
 * M7.5D.2 two-session synthetic numbering uniqueness.
 * Uses an isolated PROOF- series. Does not allocate legal invoice numbers.
 */
import { spawn } from "node:child_process"

const PREFIX = `m75d2c_${Date.now().toString(36)}`

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

const passed = []
function ok(name) {
  passed.push(name)
  console.log("PASS", name)
}

const adminId = (
  await psql(`
    select profiles.id
    from public.profiles
    join auth.users on auth.users.id = profiles.id
    where auth.users.email = 'admin.m1s2qa@example.com'
    limit 1
  `)
).trim()
if (!adminId) throw new Error("admin.m1s2qa is required to own synthetic numbering fixtures")

const seriesId = (
  await psql(`
    select set_config('app.invoice_numbering_write', 'on', false);
    with year_row as (
      insert into public.invoice_financial_years (
        ownership_code, code, label, starts_on, ends_on, status, created_by
      )
      values (
        'PROOF-${PREFIX}', '26-27', 'Proof concurrent FY',
        '2026-04-01', '2027-03-31', 'verified', '${adminId}'::uuid
      )
      returning id
    )
    insert into public.invoice_number_series (
      financial_year_id, series_code, prefix, pad_width, is_synthetic, created_by
    )
    select year_row.id, 'PROOF', 'PROOF-${PREFIX}', 5, true, '${adminId}'::uuid
    from year_row
    returning id;
  `)
)
  .split(/\s+/)
  .filter((value) => /^[0-9a-f-]{36}$/i.test(value))
  .at(-1)
if (!seriesId) throw new Error("synthetic series insert failed")

function allocateOnce() {
  return psql(`
    begin;
    select set_config('app.invoice_number_proof', 'on', true);
    select app_private.allocate_synthetic_invoice_number('${seriesId}'::uuid) ->> 'formatted_number';
    commit;
  `)
}

const [left, right] = await Promise.all([allocateOnce(), allocateOnce()])
const numbers = [left, right]
  .map((text) => text.split(/\s+/).find((value) => value.startsWith("PROOF-")))
  .filter(Boolean)

if (numbers.length !== 2) throw new Error(`expected two proof numbers, got ${textDump(left, right)}`)
if (numbers[0] === numbers[1]) throw new Error(`duplicate synthetic number ${numbers[0]}`)
if (numbers.some((value) => !value.startsWith(`PROOF-${PREFIX}`))) {
  throw new Error(`allocator escaped the synthetic series: ${numbers.join(",")}`)
}
ok("concurrent synthetic allocations are unique")

const legal = (
  await psql(`
    select count(*)
    from public.invoice_number_allocations
    join public.invoice_number_series on invoice_number_series.id = invoice_number_allocations.series_id
    where invoice_number_series.id = '${seriesId}'::uuid
      and (invoice_number_allocations.is_legal or not invoice_number_allocations.proof_only)
  `)
).trim()
if (legal !== "0") throw new Error("concurrent proof must not mark numbers legal")
ok("concurrent allocations remain proof-only")

console.log(`M7.5D.2 concurrency passed ${passed.length} checks`)

function textDump(a, b) {
  return JSON.stringify({ a, b })
}
