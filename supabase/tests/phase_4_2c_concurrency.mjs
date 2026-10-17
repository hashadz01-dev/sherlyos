import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_4_2c_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(
  new URL("./phase_4_2c_concurrency_cleanup.sql", import.meta.url),
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
  return `select public.phase42c_claim('${email}');`
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

const accounts = "accounts.phase42crace@example.com"
const accountsB = "accounts_b.phase42crace@example.com"
const godown = "godown.phase42crace@example.com"
const godownB = "godown_b.phase42crace@example.com"

try {
  await psql(cleanupSql).catch(() => undefined)
  await psql(setupSql)

  await race(
    "two simultaneous sends",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.send_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_send'),
        2,
        'p42c-race-send-a'
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
        perform public.send_delivery_note(
          (select value::uuid from public.phase42c_race_target where name = 'note_send'),
          2,
          'p42c-race-send-b'
        );
        raise exception 'second send was accepted';
      exception
        when sqlstate '40001' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      begin
        if (
          select status from public.delivery_notes
          where id = (select value::uuid from public.phase42c_race_target where name = 'note_send')
        ) <> 'sent' then
          raise exception 'send race did not leave sent';
        end if;
        if (
          select count(*) from public.delivery_note_events
          where delivery_note_id = (select value::uuid from public.phase42c_race_target where name = 'note_send')
            and event_type = 'sent'
        ) <> 1 then
          raise exception 'send race duplicated events';
        end if;
      end;
      $$;
    `,
  )

  await race(
    "two simultaneous acknowledgements",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(godown)}
      select public.acknowledge_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_ack'),
        3,
        'p42c-race-ack-a'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(godownB)}
      do $$
      begin
        perform public.acknowledge_delivery_note(
          (select value::uuid from public.phase42c_race_target where name = 'note_ack'),
          3,
          'p42c-race-ack-b'
        );
        raise exception 'second acknowledge was accepted';
      exception
        when sqlstate '40001' then null;
        when sqlstate '23514' then null;
        when sqlstate '42501' then null;
      end;
      $$;
      commit;
      do $$
      begin
        if (
          select status from public.delivery_notes
          where id = (select value::uuid from public.phase42c_race_target where name = 'note_ack')
        ) <> 'acknowledged' then
          raise exception 'ack race did not leave acknowledged';
        end if;
        if (
          select count(*) from public.delivery_note_events
          where delivery_note_id = (select value::uuid from public.phase42c_race_target where name = 'note_ack')
            and event_type = 'acknowledged'
        ) <> 1 then
          raise exception 'ack race duplicated events';
        end if;
      end;
      $$;
    `,
  )

  await race(
    "send versus void",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.send_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_sv'),
        2,
        'p42c-race-sv-send'
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
        perform public.void_delivery_note(
          (select value::uuid from public.phase42c_race_target where name = 'note_sv'),
          2,
          'race void',
          'p42c-race-sv-void'
        );
      exception
        when sqlstate '40001' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      declare
        current_status text;
      begin
        select status into current_status
        from public.delivery_notes
        where id = (select value::uuid from public.phase42c_race_target where name = 'note_sv');
        if current_status not in ('sent', 'voided') then
          raise exception 'send versus void left unexpected status %', current_status;
        end if;
      end;
      $$;
    `,
  )

  await race(
    "acknowledge versus void",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(godown)}
      select public.acknowledge_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_av'),
        3,
        'p42c-race-av-ack'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      do $$
      begin
        perform public.void_delivery_note(
          (select value::uuid from public.phase42c_race_target where name = 'note_av'),
          3,
          'race void ack',
          'p42c-race-av-void'
        );
      exception
        when sqlstate '40001' then null;
        when sqlstate '23514' then null;
      end;
      $$;
      commit;
      do $$
      declare
        current_status text;
      begin
        select status into current_status
        from public.delivery_notes
        where id = (select value::uuid from public.phase42c_race_target where name = 'note_av');
        if current_status not in ('acknowledged', 'voided') then
          raise exception 'ack versus void left unexpected status %', current_status;
        end if;
        if current_status = 'acknowledged' and exists (
          select 1 from public.delivery_notes
          where id = (select value::uuid from public.phase42c_race_target where name = 'note_av')
            and status = 'voided'
        ) then
          raise exception 'acknowledged and voided simultaneously';
        end if;
      end;
      $$;
    `,
  )

  await race(
    "send versus cancel",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      select public.send_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_sc'),
        2,
        'p42c-race-sc-send'
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
        where id = (select value::uuid from public.phase42c_race_target where name = 'order_sc');
        begin
          perform public.cancel_order(
            (select value::uuid from public.phase42c_race_target where name = 'order_sc'),
            current_version,
            'race cancel',
            'p42c-race-sc-cancel'
          );
        exception
          when sqlstate '23514' then null;
          when sqlstate '40001' then null;
        end;
      end;
      $$;
      commit;
      do $$
      begin
        if exists (
          select 1 from public.orders
          where id = (select value::uuid from public.phase42c_race_target where name = 'order_sc')
            and status = 'cancelled'
        ) and exists (
          select 1 from public.delivery_notes
          where id = (select value::uuid from public.phase42c_race_target where name = 'note_sc')
            and status <> 'voided'
        ) then
          raise exception 'cancelled order still has active DN after send/cancel race';
        end if;
      end;
      $$;
    `,
  )

  await race(
    "acknowledge versus cancel",
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(godown)}
      select public.acknowledge_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_ac'),
        3,
        'p42c-race-ac-ack'
      );
      select pg_sleep(1.2);
      commit;
    `,
    `
      begin;
      set local lock_timeout = '8s';
      ${claim(accounts)}
      do $$
      declare
        current_version integer;
      begin
        select version into current_version
        from public.orders
        where id = (select value::uuid from public.phase42c_race_target where name = 'order_ac');
        begin
          perform public.cancel_order(
            (select value::uuid from public.phase42c_race_target where name = 'order_ac'),
            current_version,
            'race cancel ack',
            'p42c-race-ac-cancel'
          );
        exception
          when sqlstate '23514' then null;
          when sqlstate '40001' then null;
        end;
      end;
      $$;
      commit;
      do $$
      begin
        if (
          select status from public.orders
          where id = (select value::uuid from public.phase42c_race_target where name = 'order_ac')
        ) = 'cancelled' then
          raise exception 'acknowledge versus cancel cancelled an acknowledged order';
        end if;
        if (
          select status from public.delivery_notes
          where id = (select value::uuid from public.phase42c_race_target where name = 'note_ac')
        ) <> 'acknowledged' then
          raise exception 'acknowledge versus cancel did not leave acknowledged';
        end if;
      end;
      $$;
    `,
  )

  // Idempotency replay and mismatched fingerprint
  await psql(`
    ${claim(accounts)}
    do $$
    declare
      first jsonb;
      second jsonb;
    begin
      -- recreate a generated note for replay checks using acknowledged-safe order already sent path:
      -- use note_send which is now sent; replay send with same key
      first := public.send_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_send'),
        2,
        'p42c-race-send-a'
      );
      second := public.send_delivery_note(
        (select value::uuid from public.phase42c_race_target where name = 'note_send'),
        2,
        'p42c-race-send-a'
      );
      if first -> 'delivery_note' ->> 'version' is distinct from second -> 'delivery_note' ->> 'version' then
        raise exception 'idempotent send versions diverged';
      end if;

      begin
        perform public.send_delivery_note(
          (select value::uuid from public.phase42c_race_target where name = 'note_send'),
          99,
          'p42c-race-send-a'
        );
        raise exception 'mismatched fingerprint accepted';
      exception
        when sqlstate '23514' then null;
      end;
    end;
    $$;
  `)
  console.log("PASS repeated idempotency keys")

  await psql(`
    do $$
    begin
      if exists (select 1 from public.stock_balances where quantity < 0) then
        raise exception 'negative balances after 4.2C races';
      end if;
    end;
    $$;
  `)
  console.log("PASS ledger integrity after handover races")

  await psql(cleanupSql)
  console.log("CONCURRENCY_EXIT:0")
} catch (error) {
  console.error(error.message)
  await psql(cleanupSql).catch(() => undefined)
  process.exit(1)
}
