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
  await new Promise((resolve) => setTimeout(resolve, 600))
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
const accounts2 = "accounts2.phase41crace@example.com"
const salesperson = "sales.phase41crace@example.com"

try {
  await psql(cleanupSql).catch(() => undefined)
  await psql(setupSql)

  // Duplicate submit with same key
  await psql(`
    ${claim(salesperson)}
    select public.submit_order(
      (select value::uuid from public.phase41c_race_target where name = 'order_id'),
      1,
      'p41c-race-submit'
    );
    select public.submit_order(
      (select value::uuid from public.phase41c_race_target where name = 'order_id'),
      1,
      'p41c-race-submit'
    );
    do $$
    begin
      if (select status from public.orders where id = (select value::uuid from public.phase41c_race_target where name = 'order_id')) <> 'submitted' then
        raise exception 'duplicate submit did not stay submitted';
      end if;
      if (select count(*) from public.order_events where order_id = (select value::uuid from public.phase41c_race_target where name = 'order_id') and event_type = 'submitted') <> 1 then
        raise exception 'duplicate submit wrote extra events';
      end if;
    end;
    $$;
  `)
  console.log("PASS duplicate submit requests")

  // Two Accounts verify the same order
  await race(
    "two Accounts users verifying the same order",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.verify_order(
        (select value::uuid from public.phase41c_race_target where name = 'order_id'),
        2,
        'p41c-race-verify-a'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts2)}
      do $$
      begin
        perform public.verify_order(
          (select value::uuid from public.phase41c_race_target where name = 'order_id'),
          2,
          'p41c-race-verify-b'
        );
        raise exception 'second verify was accepted';
      exception
        when sqlstate 'PT409' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      begin
        if (select status from public.orders where id = (select value::uuid from public.phase41c_race_target where name = 'order_id')) <> 'verified' then
          raise exception 'verify race did not leave verified';
        end if;
        if (select count(*) from public.order_events where order_id = (select value::uuid from public.phase41c_race_target where name = 'order_id') and event_type = 'verified') <> 1 then
          raise exception 'verify race duplicated events';
        end if;
      end;
      $$;
    `,
  )

  // Fresh submitted order for hold versus verify
  await psql(`
    ${claim(salesperson)}
    insert into public.phase41c_race_target(name, value)
    values (
      'order_hv',
      (
        public.create_order(
          (select value::uuid from public.phase41c_race_target where name = 'shop_id'),
          (select value::uuid from public.phase41c_race_target where name = 'branch_a'),
          'salesperson',
          null,
          null,
          jsonb_build_array(jsonb_build_object(
            'product_id', (select value::uuid from public.phase41c_race_target where name = 'product_id'),
            'requested_cases', 2
          )),
          'p41c-race-create-hv'
        ) -> 'order' ->> 'id'
      )
    )
    on conflict (name) do update set value = excluded.value;
    select public.submit_order((select value::uuid from public.phase41c_race_target where name = 'order_hv'), 1, 'p41c-race-submit-hv');
  `)

  await race(
    "hold versus verify",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.hold_order(
        (select value::uuid from public.phase41c_race_target where name = 'order_hv'),
        2,
        'race hold',
        'p41c-race-hold'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts2)}
      do $$
      begin
        perform public.verify_order(
          (select value::uuid from public.phase41c_race_target where name = 'order_hv'),
          2,
          'p41c-race-verify-against-hold'
        );
        raise exception 'verify won against held lock unexpectedly without conflict';
      exception
        when sqlstate 'PT409' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      declare
        selected text;
      begin
        select status into selected from public.orders where id = (select value::uuid from public.phase41c_race_target where name = 'order_hv');
        if selected not in ('held', 'verified') then
          raise exception 'hold/verify race left %', selected;
        end if;
        if (
          select count(*) from public.order_events
          where order_id = (select value::uuid from public.phase41c_race_target where name = 'order_hv')
            and event_type in ('held', 'verified')
        ) <> 1 then
          raise exception 'hold/verify race did not produce exactly one outcome event';
        end if;
      end;
      $$;
    `,
  )

  // Submit versus cancel on a draft
  await psql(`
    ${claim(salesperson)}
    insert into public.phase41c_race_target(name, value)
    values (
      'order_sc',
      (
        public.create_order(
          (select value::uuid from public.phase41c_race_target where name = 'shop_id'),
          (select value::uuid from public.phase41c_race_target where name = 'branch_a'),
          'salesperson',
          null,
          null,
          jsonb_build_array(jsonb_build_object(
            'product_id', (select value::uuid from public.phase41c_race_target where name = 'product_id'),
            'requested_cases', 1
          )),
          'p41c-race-create-sc'
        ) -> 'order' ->> 'id'
      )
    )
    on conflict (name) do update set value = excluded.value;
  `)

  await race(
    "submit versus cancel",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(salesperson)}
      select public.submit_order(
        (select value::uuid from public.phase41c_race_target where name = 'order_sc'),
        1,
        'p41c-race-submit-sc'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(salesperson)}
      do $$
      begin
        perform public.cancel_order(
          (select value::uuid from public.phase41c_race_target where name = 'order_sc'),
          1,
          null,
          'p41c-race-cancel-sc'
        );
        raise exception 'cancel won without conflict';
      exception
        when sqlstate 'PT409' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      declare
        selected text;
      begin
        select status into selected from public.orders where id = (select value::uuid from public.phase41c_race_target where name = 'order_sc');
        if selected not in ('submitted', 'cancelled') then
          raise exception 'submit/cancel race left %', selected;
        end if;
      end;
      $$;
    `,
  )

  // Integrity after races
  await psql(`
    do $$
    begin
      if exists (select 1 from public.stock_balances where quantity < 0) then
        raise exception 'negative balances after order races';
      end if;
      if exists (
        select 1
        from public.stock_balances sb
        left join (
          select crate_id, product_id, sum(quantity)::integer as ledger_qty
          from public.stock_ledger
          group by crate_id, product_id
        ) ledger on ledger.crate_id = sb.crate_id and ledger.product_id = sb.product_id
        where sb.quantity is distinct from coalesce(ledger.ledger_qty, 0)
      ) then
        raise exception 'ledger mismatch after order races';
      end if;
    end;
    $$;
  `)
  console.log("PASS ledger integrity after order races")

  await psql(cleanupSql)
  console.log("CONCURRENCY_EXIT:0")
} catch (error) {
  console.error(error.message)
  try {
    await psql(cleanupSql)
  } catch {
    // ignore cleanup failure after primary error
  }
  process.exit(1)
}
