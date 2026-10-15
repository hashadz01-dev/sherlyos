import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(
  new URL("./phase_2c3_concurrency.sql", import.meta.url),
  "utf8",
)

const cleanupSql = `
alter table public.stock_ledger disable trigger stock_ledger_append_only;
alter table public.stock_transactions disable trigger stock_transactions_append_only;
alter table public.stock_balances disable trigger stock_balances_match_ledger;
delete from public.stock_ledger
where product_id in (select id from public.products where sku like 'p2c3-race-%');
delete from public.stock_balances
where product_id in (select id from public.products where sku like 'p2c3-race-%');
delete from public.audit_logs
where actor_id = (select id from auth.users where email = 'admin.phase2c3race@example.com');
delete from public.stock_transactions
where product_id in (select id from public.products where sku like 'p2c3-race-%');
alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;
delete from public.crates
where zone_id in (
  select zones.id from public.zones
  join public.branches on branches.id = zones.branch_id
  where branches.code = 'phase2c3_race'
);
delete from public.zones
where branch_id = (select id from public.branches where code = 'phase2c3_race');
delete from public.branches where code = 'phase2c3_race';
delete from public.products where sku like 'p2c3-race-%';
delete from auth.users where email = 'admin.phase2c3race@example.com';
drop function if exists public.phase2c3_hold_emptying_transfer();
drop function if exists public.phase2c3_hold_stocked_transfer();
drop function if exists public.phase2c3_hold_deactivate();
drop function if exists public.phase2c3_hold_second_opening();
drop function if exists public.phase2c3_hold_opening();
drop function if exists public.phase2c3_hold_transfer();
drop function if exists public.phase2c3_race_claims();
`

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
        "-q",
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
      if (code === 0) resolve(output)
      else reject(new Error(output.trim()))
    })
    child.stdin.end(sql)
  })
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

const results = []

try {
  await psql(setupSql)
  await race(
    "two transfers drawing the same balance",
    "select public.phase2c3_hold_transfer();",
    `
      do $$
      begin
        perform public.phase2c3_race_claims();
        perform public.post_crate_transfer(
          (select id from public.products where sku = 'p2c3-race-move'),
          (select id from public.crates where code = 'race1'),
          (select id from public.crates where code = 'race2'),
          4,
          'race-compete-transfer',
          null
        );
        raise exception 'overlapping transfer was accepted';
      exception
        when check_violation then
          null;
      end;
      $$;
      do $$
      begin
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race1')
            and product_id = (select id from public.products where sku = 'p2c3-race-move')
        ) <> 1 then
          raise exception 'overlapping transfers did not leave one carton case';
        end if;
        if exists (select 1 from public.stock_balances where quantity < 0) then
          raise exception 'a negative balance exists';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "same idempotency key for opening stock",
    "select public.phase2c3_hold_opening();",
    `
      do $$
      declare
        posted jsonb;
      begin
        perform public.phase2c3_race_claims();
        posted := public.post_opening_stock(
          (select id from public.products where sku = 'p2c3-race-open'),
          (select id from public.crates where code = 'race3'),
          1,
          'race-open-same',
          null
        );
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race3')
            and product_id = (select id from public.products where sku = 'p2c3-race-open')
        ) <> 1 then
          raise exception 'idempotent opening race duplicated stock';
        end if;
        if posted ->> 'reference_number' is null then
          raise exception 'idempotent opening race returned no reference';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "two distinct opening requests for one crate and product",
    "select public.phase2c3_hold_second_opening();",
    `
      do $$
      begin
        perform public.phase2c3_race_claims();
        perform public.post_opening_stock(
          (select id from public.products where sku = 'p2c3-race-dup'),
          (select id from public.crates where code = 'race4'),
          1,
          'race-open-second',
          null
        );
        raise exception 'a second opening race was accepted';
      exception
        when unique_violation then
          null;
      end;
      $$;
      do $$
      begin
        if (
          select count(*) from public.stock_transactions
          where product_id = (select id from public.products where sku = 'p2c3-race-dup')
        ) <> 1 then
          raise exception 'distinct opening requests duplicated a transaction';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "in-flight transfer against deactivation of a stocked crate",
    "select public.phase2c3_hold_stocked_transfer();",
    `
      do $$
      begin
        perform public.phase2c3_race_claims();
        perform public.set_crate_active((select id from public.crates where code = 'race6'), false);
        raise exception 'deactivation of a stocked crate was accepted';
      exception
        when check_violation then
          if sqlerrm not like '%still holds stock%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if not exists (
          select 1 from public.crates where code = 'race6' and is_active
        ) then
          raise exception 'stocked crate was deactivated during a partial transfer';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race6')
            and product_id = (select id from public.products where sku = 'p2c3-race-live')
        ) <> 3 then
          raise exception 'stocked source balance changed unexpectedly';
        end if;
        if exists (
          select 1
          from public.stock_balances
          join public.crates on crates.id = stock_balances.crate_id
          where not crates.is_active
            and stock_balances.quantity > 0
        ) then
          raise exception 'positive stock remains in an inactive crate';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "in-flight emptying transfer against deactivation",
    "select public.phase2c3_hold_emptying_transfer();",
    `
      do $$
      begin
        perform public.phase2c3_race_claims();
        perform public.set_crate_active((select id from public.crates where code = 'race6'), false);
      end;
      $$;
      do $$
      begin
        if exists (
          select 1 from public.crates where code = 'race6' and is_active
        ) then
          raise exception 'emptied crate stayed active';
        end if;
        if exists (
          select 1
          from public.stock_balances
          join public.crates on crates.id = stock_balances.crate_id
          where crates.code = 'race6'
            and stock_balances.quantity > 0
        ) then
          raise exception 'deactivated crate still holds stock';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race7')
            and product_id = (select id from public.products where sku = 'p2c3-race-live')
        ) <> 5 then
          raise exception 'emptied stock did not arrive in the destination';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "transfer into a crate deactivated first",
    "select public.phase2c3_hold_deactivate();",
    `
      do $$
      begin
        perform public.phase2c3_race_claims();
        perform public.post_crate_transfer(
          (select id from public.products where sku = 'p2c3-race-live'),
          (select id from public.crates where code = 'race7'),
          (select id from public.crates where code = 'race5'),
          1,
          'race-into-inactive',
          null
        );
        raise exception 'transfer into an inactive crate was accepted';
      exception
        when check_violation then
          if sqlerrm not like '%inactive%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if exists (
          select 1 from public.crates where code = 'race5' and is_active
        ) then
          raise exception 'crate deactivated first became active again';
        end if;
        if exists (
          select 1
          from public.stock_balances
          join public.crates on crates.id = stock_balances.crate_id
          where crates.code = 'race5'
            and stock_balances.quantity > 0
        ) then
          raise exception 'inactive crate received stock';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race7')
            and product_id = (select id from public.products where sku = 'p2c3-race-live')
        ) <> 5 then
          raise exception 'rejected transfer changed the source balance';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "transfer posting against crate deactivation",
    "select public.phase2c3_hold_deactivate();",
    `
      do $$
      begin
        perform public.phase2c3_race_claims();
        perform public.post_opening_stock(
          (select id from public.products where sku = 'p2c3-race-open'),
          (select id from public.crates where code = 'race5'),
          1,
          'race-open-inactive',
          null
        );
        raise exception 'posting won a deactivation race';
      exception
        when check_violation then
          null;
      end;
      $$;
      do $$
      begin
        if exists (
          select 1 from public.stock_balances
          join public.crates on crates.id = stock_balances.crate_id
          where crates.code = 'race5' and stock_balances.quantity > 0
        ) or exists (
          select 1 from public.crates where code = 'race5' and is_active
        ) then
          raise exception 'deactivation race left stock in an active crate';
        end if;
      end;
      $$;
    `,
  )
  results.push("concurrency races passed")
} finally {
  await psql(cleanupSql)
  console.log("cleaned concurrency fixture")
}

console.log(results.join("\n"))
