import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_4_2b_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(
  new URL("./phase_4_2b_concurrency_cleanup.sql", import.meta.url),
  "utf8",
)

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
  return `select public.phase42b_claim('${email}');`
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

const accounts = "accounts.phase42brace@example.com"
const accountsB = "accounts_b.phase42brace@example.com"

try {
  await psql(cleanupSql).catch(() => undefined)
  await psql(setupSql)

  // Concurrent duplicate create on the same order (different keys)
  await race(
    "concurrent duplicate create",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.create_delivery_note(
        (select value::uuid from public.phase42b_race_target where name = 'order_a'),
        'p42b-race-create-a'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accountsB)}
      do $$
      begin
        perform public.create_delivery_note(
          (select value::uuid from public.phase42b_race_target where name = 'order_a'),
          'p42b-race-create-b'
        );
        raise exception 'second create was accepted';
      exception
        when sqlstate '23505' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      begin
        if (
          select count(*)
          from public.delivery_notes
          where order_id = (select value::uuid from public.phase42b_race_target where name = 'order_a')
            and status <> 'voided'
        ) <> 1 then
          raise exception 'duplicate create left unexpected open DN count';
        end if;
      end;
      $$;
    `,
  )

  // Concurrent generate on the same draft
  await psql(`
    ${claim(accounts)}
    insert into public.phase42b_race_target(name, value)
    values (
      'note_generate',
      (
        public.create_delivery_note(
          (select value::uuid from public.phase42b_race_target where name = 'order_b'),
          'p42b-race-create-gen'
        ) -> 'delivery_note' ->> 'id'
      )
    )
    on conflict (name) do update set value = excluded.value;
  `)

  await race(
    "concurrent generate",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.generate_delivery_note(
        (select value::uuid from public.phase42b_race_target where name = 'note_generate'),
        1,
        'p42b-race-generate-a'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accountsB)}
      do $$
      begin
        perform public.generate_delivery_note(
          (select value::uuid from public.phase42b_race_target where name = 'note_generate'),
          1,
          'p42b-race-generate-b'
        );
        raise exception 'second generate was accepted';
      exception
        when sqlstate 'PT409' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      begin
        if (
          select status
          from public.delivery_notes
          where id = (select value::uuid from public.phase42b_race_target where name = 'note_generate')
        ) <> 'generated' then
          raise exception 'generate race did not leave generated';
        end if;
        if (
          select count(*)
          from public.delivery_note_events
          where delivery_note_id = (select value::uuid from public.phase42b_race_target where name = 'note_generate')
            and event_type = 'generated'
        ) <> 1 then
          raise exception 'generate race duplicated events';
        end if;
      end;
      $$;
    `,
  )

  // Void versus cancel: cancel must wait / fail while DN is active; after void, cancel may succeed in later txn
  await race(
    "void versus order cancellation",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.void_delivery_note(
        (select value::uuid from public.phase42b_race_target where name = 'note_generate'),
        2,
        'race void',
        'p42b-race-void-a'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accountsB)}
      do $$
      declare
        current_version integer;
      begin
        select version into current_version
        from public.orders
        where id = (select value::uuid from public.phase42b_race_target where name = 'order_b');

        begin
          perform public.cancel_order(
            (select value::uuid from public.phase42b_race_target where name = 'order_b'),
            current_version,
            'race cancel while DN active or after void',
            'p42b-race-cancel-b'
          );
        exception
          when sqlstate '23514' then
            null;
        end;
      end;
      $$;
      commit;
      do $$
      begin
        if (
          select status
          from public.delivery_notes
          where id = (select value::uuid from public.phase42b_race_target where name = 'note_generate')
        ) <> 'voided' then
          raise exception 'void versus cancel did not void DN';
        end if;
        if exists (
          select 1
          from public.orders
          where id = (select value::uuid from public.phase42b_race_target where name = 'order_b')
            and status = 'cancelled'
        ) and exists (
          select 1
          from public.delivery_notes
          where order_id = (select value::uuid from public.phase42b_race_target where name = 'order_b')
            and status <> 'voided'
        ) then
          raise exception 'cancelled order still has active DN';
        end if;
      end;
      $$;
    `,
  )

  await psql(`
    do $$
    begin
      if exists (select 1 from public.stock_balances where quantity < 0) then
        raise exception 'negative balances after DN races';
      end if;
    end;
    $$;
  `)
  console.log("PASS ledger integrity after DN races")

  await psql(cleanupSql)
  console.log("CONCURRENCY_EXIT:0")
} catch (error) {
  console.error(error.message)
  await psql(cleanupSql).catch(() => undefined)
  process.exit(1)
}
