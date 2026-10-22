import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_4_3e2b2_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(
  new URL("./phase_4_3e2b2_concurrency_cleanup.sql", import.meta.url),
  "utf8",
)

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

function claimAdmin() {
  return `
    select set_config(
      'request.jwt.claims',
      (
        select json_build_object('sub', value, 'role', 'authenticated')::text
        from public.phase43e2b2_race_target where name = 'admin'
      ),
      true
    );
    select set_config(
      'request.jwt.claim.sub',
      (select value from public.phase43e2b2_race_target where name = 'admin'),
      true
    );
  `
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

try {
  await psql(cleanupSql).catch(() => undefined)
  await psql(setupSql)

  // 1) Session A creates lot_id ledger + applies; session B races a second apply
  await race(
    "concurrent duplicate lot-aware apply",
    `
      begin;
      set local lock_timeout = '8s';
      ${claimAdmin()}
      do $$
      declare
        admin_id uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'admin');
        product uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'product');
        crate_b uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'crate_b');
        lot_dup uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'lot_dup');
        txn uuid;
      begin
        insert into public.stock_transactions (
          transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
          product_id, destination_crate_id, quantity
        ) values (
          'OPENING_STOCK', 'P43E2B2-RACE-DUP', admin_id,
          'p43e2b2-race-dup', 'fp-race-dup', product, crate_b, 2
        ) returning id into txn;

        insert into public.stock_ledger (
          transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
        ) values (txn, product, crate_b, 2, admin_id, clock_timestamp(), lot_dup);

        insert into public.phase43e2b2_race_target (name, value)
        values ('txn_dup', txn::text)
        on conflict (name) do update set value = excluded.value;

        perform app_private.apply_lot_aware_stock_deltas(
          txn,
          jsonb_build_array(jsonb_build_object(
            'product_id', product, 'lot_id', lot_dup, 'crate_id', crate_b, 'quantity', 2
          ))
        );
      end;
      $$;
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claimAdmin()}
      do $$
      declare
        tries integer := 0;
        txn uuid;
      begin
        loop
          select value::uuid into txn
          from public.phase43e2b2_race_target where name = 'txn_dup';
          exit when txn is not null or tries > 40;
          tries := tries + 1;
          perform pg_sleep(0.1);
        end loop;

        if txn is null then
          raise exception 'txn_dup never published';
        end if;

        begin
          perform app_private.apply_lot_aware_stock_deltas(
            txn,
            jsonb_build_array(jsonb_build_object(
              'product_id', (select value::uuid from public.phase43e2b2_race_target where name = 'product'),
              'lot_id', (select value::uuid from public.phase43e2b2_race_target where name = 'lot_dup'),
              'crate_id', (select value::uuid from public.phase43e2b2_race_target where name = 'crate_b'),
              'quantity', 2
            ))
          );
          raise exception 'second duplicate apply was accepted';
        exception
          when sqlstate '23514' then null;
          when sqlstate '55P03' then null;
        end;
      end;
      $$;
      commit;
      do $$
      begin
        if (
          select count(*) from public.stock_lot_aware_applications
          where transaction_id = (
            select value::uuid from public.phase43e2b2_race_target where name = 'txn_dup'
          )
        ) <> 1 then
          raise exception 'duplicate apply race left unexpected application count';
        end if;
      end;
      $$;
    `,
  )

  // 2) Concurrent competing draws against the same lot quantity
  await race(
    "concurrent competing lot stock draws",
    `
      begin;
      set local lock_timeout = '8s';
      ${claimAdmin()}
      do $$
      declare
        admin_id uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'admin');
        product uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'product');
        crate_a uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'crate_a');
        crate_b uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'crate_b');
        lot uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'lot_main');
        txn uuid;
      begin
        insert into public.stock_transactions (
          transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
          product_id, source_crate_id, destination_crate_id, quantity
        ) values (
          'CRATE_TRANSFER', 'P43E2B2-RACE-A', admin_id,
          'p43e2b2-race-a', 'fp-race-a', product, crate_a, crate_b, 4
        ) returning id into txn;

        insert into public.stock_ledger (
          transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
        ) values
          (txn, product, crate_a, -4, admin_id, clock_timestamp(), lot),
          (txn, product, crate_b, 4, admin_id, clock_timestamp(), lot);

        insert into public.phase43e2b2_race_target (name, value)
        values ('txn_race_a', txn::text)
        on conflict (name) do update set value = excluded.value;

        perform app_private.apply_lot_aware_stock_deltas(
          txn,
          jsonb_build_array(
            jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_a, 'quantity', -4),
            jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', 4)
          )
        );
      end;
      $$;
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claimAdmin()}
      do $$
      declare
        admin_id uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'admin');
        product uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'product');
        crate_a uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'crate_a');
        crate_b uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'crate_b');
        lot uuid := (select value::uuid from public.phase43e2b2_race_target where name = 'lot_main');
        txn uuid;
      begin
        insert into public.stock_transactions (
          transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
          product_id, source_crate_id, destination_crate_id, quantity
        ) values (
          'CRATE_TRANSFER', 'P43E2B2-RACE-B', admin_id,
          'p43e2b2-race-b', 'fp-race-b', product, crate_a, crate_b, 4
        ) returning id into txn;

        insert into public.stock_ledger (
          transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
        ) values
          (txn, product, crate_a, -4, admin_id, clock_timestamp(), lot),
          (txn, product, crate_b, 4, admin_id, clock_timestamp(), lot);

        insert into public.phase43e2b2_race_target (name, value)
        values ('txn_race_b', txn::text)
        on conflict (name) do update set value = excluded.value;

        begin
          perform app_private.apply_lot_aware_stock_deltas(
            txn,
            jsonb_build_array(
              jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_a, 'quantity', -4),
              jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', 4)
            )
          );
          raise exception 'second competing draw was accepted';
        exception
          when sqlstate '23514' then null;
          when sqlstate '55P03' then null;
        end;
      end;
      $$;
      rollback;
      do $$
      declare
        remaining integer;
        applied_count integer;
      begin
        select coalesce(sum(quantity), 0) into remaining
        from public.stock_lot_balances
        where lot_id = (select value::uuid from public.phase43e2b2_race_target where name = 'lot_main');

        if remaining is distinct from 5 then
          raise exception 'competing draw race broke conservation remaining=%', remaining;
        end if;

        select count(*) into applied_count
        from public.stock_lot_aware_applications
        where transaction_id = (
          select value::uuid from public.phase43e2b2_race_target where name = 'txn_race_a'
        );

        if applied_count is distinct from 1 then
          raise exception 'expected race A application got %', applied_count;
        end if;
      end;
      $$;
    `,
  )

  await psql(cleanupSql)
  console.log("PASS phase_4_3e2b2_concurrency")
} catch (error) {
  try {
    await psql(cleanupSql)
  } catch {
    // ignore cleanup failures after primary error
  }
  console.error(error.message || error)
  process.exit(1)
}
