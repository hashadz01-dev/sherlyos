import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_m1_concurrency_setup.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(new URL("./phase_m1_concurrency_cleanup.sql", import.meta.url), "utf8")

function psql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "docker",
      ["exec", "-i", "supabase_db_sherlyos", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-q"],
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
      if (code === 0) resolve(output)
      else reject(new Error(output.trim()))
    })
    child.stdin.end(sql)
  })
}

function transfer(key) {
  return `
    begin;
    set local role authenticated;
    select set_config('request.jwt.claim.sub', (select value from public.phase_m1_race_target where name = 'admin'), true);
    select set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', (select value from public.phase_m1_race_target where name = 'admin'), 'role', 'authenticated')::text,
      true
    );
    select public.post_crate_transfer(
      (select value::uuid from public.phase_m1_race_target where name = 'product'),
      (select value::uuid from public.phase_m1_race_target where name = 'crate_a'),
      (select value::uuid from public.phase_m1_race_target where name = 'crate_b'),
      5,
      '${key}',
      null,
      jsonb_build_array(jsonb_build_object(
        'lot_id', (select value::uuid from public.phase_m1_race_target where name = 'lot'),
        'quantity', 5
      ))
    );
    commit;
  `
}

try {
  await psql(cleanupSql).catch(() => undefined)
  await psql(setupSql)
  const results = await Promise.allSettled([
    psql(transfer("m1-race-xfer-a")),
    psql(transfer("m1-race-xfer-b")),
  ])
  const succeeded = results.filter((result) => result.status === "fulfilled").length
  const failed = results.filter((result) => result.status === "rejected").length
  if (succeeded !== 1 || failed !== 1) {
    const detail = results
      .map((result) => (result.status === "rejected" ? result.reason.message : "ok"))
      .join("\n---\n")
    throw new Error(`expected one transfer success and one rejection, got ${succeeded} ok / ${failed} fail\n${detail}`)
  }
  const check = await psql(`
    select
      (select quantity from public.stock_lot_balances
        where lot_id = (select value::uuid from public.phase_m1_race_target where name = 'lot')
          and crate_id = (select value::uuid from public.phase_m1_race_target where name = 'crate_a')) as source_lot,
      (select quantity from public.stock_lot_balances
        where lot_id = (select value::uuid from public.phase_m1_race_target where name = 'lot')
          and crate_id = (select value::uuid from public.phase_m1_race_target where name = 'crate_b')) as dest_lot,
      (select coalesce(sum(quantity), 0) from public.stock_balances
        where product_id = (select value::uuid from public.phase_m1_race_target where name = 'product')) as aggregate_total,
      (select coalesce(sum(stock_lot_balances.quantity), 0)
        from public.stock_lot_balances
        join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
        where stock_lots.product_id = (select value::uuid from public.phase_m1_race_target where name = 'product')) as lot_total;
  `)
  if (!check.includes("3") || !check.includes("5") || !/8\s*\|\s*8/.test(check.replace(/\s+/g, " ")) && !check.includes("8 | 8") && !check.includes("8|8")) {
    if (!check.includes("|     3 |") && !check.includes(" 3 |") ) {
      throw new Error(`conservation check unexpected:\n${check}`)
    }
  }
  if (!/\b3\b/.test(check) || !/\b5\b/.test(check) || !/\b8\b/.test(check)) {
    throw new Error(`conservation check unexpected:\n${check}`)
  }
  console.log("PASS parallel lot transfer race")
  console.log(check.trim())
} finally {
  await psql(cleanupSql)
  console.log("cleanup complete")
}
