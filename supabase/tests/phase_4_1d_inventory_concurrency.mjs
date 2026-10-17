/**
 * Phase 4.1D inventory interaction races during verify_order.
 * Local Docker only via supabase_db_sherlyos. No cloud hosts.
 */
import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_4_1c_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(new URL("./phase_4_1c_concurrency_cleanup.sql", import.meta.url), "utf8")

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

function claim(email) {
  return `select public.phase41c_claim('${email}');`
}

async function race(name, holdSql, competeSql) {
  const hold = psql(holdSql)
  await new Promise((resolve) => setTimeout(resolve, 700))
  try {
    await psql(competeSql)
  } catch (error) {
    await hold.catch(() => undefined)
    throw new Error(`${name} competing session failed: ${error.message}`)
  }
  await hold
  console.log(`PASS ${name}`)
}

const accounts = "accounts.phase41crace@example.com"
const salesperson = "sales.phase41crace@example.com"
const godown = "godown.phase41crace@example.com"
const admin = "admin.phase41crace@example.com"

try {
  await psql(cleanupSql).catch(() => undefined)
  await psql(setupSql)

  // Extra crate for transfers; godown gets transfer rights via role
  await psql(`
    ${claim(admin)}
    select public.create_zone(
      (select value::uuid from public.phase41c_race_target where name = 'branch_a'),
      'R2', 'Race Zone 2', null
    );
    select public.create_crate(
      (select id from public.zones where code = 'R2'
        and branch_id = (select value::uuid from public.phase41c_race_target where name = 'branch_a')),
      'rc2', 'Race Crate 2', null
    );
    insert into public.phase41c_race_target(name, value)
    values (
      'crate_2',
      (select id::text from public.crates where code = 'rc2'
        and zone_id in (select id from public.zones where code = 'R2')
        order by created_at desc limit 1)
    )
    on conflict (name) do update set value = excluded.value;

    ${claim(salesperson)}
    select public.submit_order(
      (select value::uuid from public.phase41c_race_target where name = 'order_id'),
      1,
      'p41d-inv-submit'
    );
  `)

  // Crate transfer while verify locks the order row
  await race(
    "crate transfer while verify_order runs",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.verify_order(
        (select value::uuid from public.phase41c_race_target where name = 'order_id'),
        2,
        'p41d-verify-during-xfer'
      );
      select pg_sleep(1.5);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(godown)}
      select public.post_crate_transfer(
        (select value::uuid from public.phase41c_race_target where name = 'product_id'),
        (select value::uuid from public.phase41c_race_target where name = 'crate_id'),
        (select value::uuid from public.phase41c_race_target where name = 'crate_2'),
        1,
        'p41d-race-xfer',
        null
      );
      commit;
    `,
  )

  await psql(`
    do $$
    begin
      if (select status from public.orders where id = (select value::uuid from public.phase41c_race_target where name = 'order_id')) <> 'verified' then
        raise exception 'verify did not complete during transfer race';
      end if;
      if (select count(*) from public.order_events
          where order_id = (select value::uuid from public.phase41c_race_target where name = 'order_id')
            and event_type = 'verified') <> 1 then
        raise exception 'duplicate verified events';
      end if;
      if exists (select 1 from public.stock_balances where quantity < 0) then
        raise exception 'negative balances after transfer race';
      end if;
      if exists (
        select 1 from public.stock_balances sb
        left join (
          select crate_id, product_id, sum(quantity)::integer as ledger_qty
          from public.stock_ledger group by 1,2
        ) l on l.crate_id = sb.crate_id and l.product_id = sb.product_id
        where sb.quantity is distinct from coalesce(l.ledger_qty, 0)
      ) then
        raise exception 'ledger mismatch after transfer race';
      end if;
    end;
    $$;
  `)
  console.log("PASS transfer during verify: no deadlock, one event, ledger OK")

  // Fresh submitted order; receiving-style movement = transfer back (or another transfer)
  await psql(`
    ${claim(salesperson)}
    insert into public.phase41c_race_target(name, value)
    values (
      'order_recv',
      (
        public.create_order(
          (select value::uuid from public.phase41c_race_target where name = 'shop_id'),
          (select value::uuid from public.phase41c_race_target where name = 'branch_a'),
          'salesperson', null, null,
          jsonb_build_array(jsonb_build_object(
            'product_id', (select value::uuid from public.phase41c_race_target where name = 'product_id'),
            'requested_cases', 2
          )),
          'p41c-race-create-recv'
        ) -> 'order' ->> 'id'
      )
    )
    on conflict (name) do update set value = excluded.value;
    select public.submit_order(
      (select value::uuid from public.phase41c_race_target where name = 'order_recv'),
      1,
      'p41d-inv-submit-recv'
    );
  `)

  await race(
    "stock movement (transfer reverse) while verify_order runs",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.verify_order(
        (select value::uuid from public.phase41c_race_target where name = 'order_recv'),
        2,
        'p41d-verify-during-recv'
      );
      select pg_sleep(1.5);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(godown)}
      select public.post_crate_transfer(
        (select value::uuid from public.phase41c_race_target where name = 'product_id'),
        (select value::uuid from public.phase41c_race_target where name = 'crate_2'),
        (select value::uuid from public.phase41c_race_target where name = 'crate_id'),
        1,
        'p41d-race-recv-xfer',
        null
      );
      commit;
    `,
  )
  console.log("PASS receiving-style transfer during verify")

  // Adjustment posting during verify: cannot reliably synthesize a full adjustment lifecycle
  // without a closed verification. Report as unverified rather than false-positive.
  console.log("UNVERIFIED adjustment posting during verify (requires closed verification fixture; not scripted)")

  await psql(`
    do $$
    begin
      if exists (select 1 from public.stock_balances where quantity < 0) then
        raise exception 'negative balances at end';
      end if;
    end;
    $$;
  `)

  // Drop extra zone/crate before shared cleanup removes the branch
  await psql(`
    alter table public.stock_ledger disable trigger stock_ledger_append_only;
    alter table public.stock_transactions disable trigger stock_transactions_append_only;
    alter table public.stock_balances disable trigger stock_balances_match_ledger;
    delete from public.stock_ledger
    where crate_id in (select id from public.crates where code in ('rc1', 'rc2'))
       or product_id in (select id from public.products where sku = 'p41c-race-sku');
    delete from public.stock_transactions
    where source_crate_id in (select id from public.crates where code in ('rc1', 'rc2'))
       or destination_crate_id in (select id from public.crates where code in ('rc1', 'rc2'))
       or product_id in (select id from public.products where sku = 'p41c-race-sku');
    delete from public.stock_balances
    where crate_id in (select id from public.crates where code in ('rc1', 'rc2'))
       or product_id in (select id from public.products where sku = 'p41c-race-sku');
    alter table public.stock_balances enable trigger stock_balances_match_ledger;
    alter table public.stock_transactions enable trigger stock_transactions_append_only;
    alter table public.stock_ledger enable trigger stock_ledger_append_only;
    delete from public.crates where code = 'rc2';
    delete from public.zones where code = 'R2';
  `)
  await psql(cleanupSql)

  console.log("INVENTORY_CONCURRENCY_EXIT:0")
} catch (error) {
  console.error(error.message)
  try {
    await psql(cleanupSql)
  } catch {
    // ignore
  }
  process.exit(1)
}
