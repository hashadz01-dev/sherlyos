import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_3_2_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(new URL("./phase_3_2_concurrency_cleanup.sql", import.meta.url), "utf8")

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

async function race(name, holdSql, competeSql) {
  const hold = psql(holdSql)
  await new Promise((resolve) => setTimeout(resolve, 800))
  try {
    await psql(competeSql)
  } catch (error) {
    await hold.catch(() => undefined)
    throw new Error(`${name} competing session failed: ${error.message}`)
  }
  await hold
  console.log(`PASS ${name}`)
}

const manager = "manager.phase32race@example.com"
const manager2 = "manager2.phase32race@example.com"
const keeper = "keeper.phase32race@example.com"

function compete(email, body) {
  return `
    set lock_timeout = '8s';
    select public.phase32_claim('${email}');
    ${body}
  `
}

try {
  await psql(setupSql)

  await race(
    "two managers start the same godown",
    "select public.phase32_hold_start();",
    compete(manager2, `
      do $$
      begin
        perform public.start_stock_verification(
          (select id from public.branches where code = 'phase32_race'),
          current_date,
          array[(select id from public.zones where code = 'rz')],
          array[(select id from public.crates where code = 'rca')]
        );
        raise exception 'second open verification was accepted';
      exception
        when unique_violation then
          if sqlerrm <> 'an open verification already exists for this godown' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select count(*) from public.stock_verifications where godown_id = (select id from public.branches where code = 'phase32_race') and status <> 'closed') <> 1 then
          raise exception 'start race left more than one open verification';
        end if;
      end;
      $$;
    `),
  )
  await psql("select public.phase32_clear_open();")

  await psql("select public.phase32_prepare_open(false);")
  await race(
    "two counters edit the same version",
    "select public.phase32_hold_count();",
    compete(keeper, `
      do $$
      declare
        line_id uuid;
        version integer;
      begin
        select id, 1 into line_id, version
        from public.stock_verification_lines
        where verification_id = public.phase32_open_id();
        perform public.save_verification_count(line_id, '3'::jsonb, version);
        raise exception 'stale count was accepted';
      exception
        when serialization_failure then
          if sqlerrm <> 'count was changed by someone else' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select count(*) from public.stock_verification_counts where verification_id = public.phase32_open_id() and count_kind = 'initial') <> 1 then
          raise exception 'count race lost or duplicated a count';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "count save races with close",
    "select public.phase32_hold_close();",
    compete(keeper, `
      do $$
      declare
        line_id uuid;
      begin
        select id into line_id from public.stock_verification_lines where verification_id = public.phase32_open_id();
        perform public.save_verification_count(line_id, '1'::jsonb, 99);
        raise exception 'count changed a closing verification';
      exception
        when insufficient_privilege or serialization_failure or check_violation then
          null;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_verifications where id = (
          select id from public.stock_verifications
          where godown_id = (select id from public.branches where code = 'phase32_race')
          order by started_at desc limit 1
        )) <> 'closed' then
          raise exception 'close race did not finish closed';
        end if;
        if (select counted_cases from public.stock_verification_lines where verification_id = (
          select id from public.stock_verifications
          where godown_id = (select id from public.branches where code = 'phase32_race')
          order by started_at desc limit 1
        )) <> 8 then
          raise exception 'close race lost the original count';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "recount save races with close",
    "select public.phase32_hold_recount();",
    compete(manager2, `
      select public.close_stock_verification(public.phase32_open_id(), 'matched', 'after recount race');
      do $$
      declare
        line public.stock_verification_lines;
      begin
        select * into line
        from public.stock_verification_lines
        where verification_id = (
          select id from public.stock_verifications where closure_note = 'after recount race'
        );
        if line.counted_cases is null or line.recount_cases is null then
          raise exception 'recount race lost a count';
        end if;
        if (select status from public.stock_verifications where id = line.verification_id) <> 'closed' then
          raise exception 'recount race did not close';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_clear_open(); select public.phase32_prepare_receipt();")
  await race(
    "receipt posts during snapshot creation",
    "select public.phase32_hold_start();",
    compete(manager2, `
      select public.verify_stock_receipt((
        select id from public.stock_receipts
        where godown_id = (select id from public.branches where code = 'phase32_race')
          and status = 'submitted'
        order by created_at desc limit 1
      ), 'race-verify-' || left(gen_random_uuid()::text, 8));
      do $$
      declare
        line jsonb;
      begin
        select item into line
        from jsonb_array_elements(public.get_stock_verification(public.phase32_open_id()) -> 'lines') item
        where item ->> 'sku' = 'p32-race-soap';
        if coalesce((line ->> 'ledger_movement_cases')::integer, 0) < 2
          or (line ->> 'expected_cases')::integer + coalesce((line ->> 'ledger_movement_cases')::integer, 0)
             <> (select quantity from public.stock_balances where crate_id = (select id from public.crates where code = 'rca') and product_id = (select id from public.products where sku = 'p32-race-soap'))
        then
          raise exception 'snapshot did not stay behind the receipt';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_clear_open();")
  await race(
    "transfer posts during snapshot creation",
    "select public.phase32_hold_start();",
    compete(manager2, `
      select public.post_crate_transfer(
        (select id from public.products where sku = 'p32-race-soap'),
        (select id from public.crates where code = 'rca'),
        (select id from public.crates where code = 'rcb'),
        1,
        'race-snap-' || left(gen_random_uuid()::text, 8),
        null
      );
      do $$
      declare
        line jsonb;
      begin
        select item into line
        from jsonb_array_elements(public.get_stock_verification(public.phase32_open_id()) -> 'lines') item
        where item ->> 'sku' = 'p32-race-soap';
        if jsonb_array_length(coalesce(line -> 'movement_ids', '[]'::jsonb)) < 1
          or (line ->> 'expected_cases')::integer + (line ->> 'ledger_movement_cases')::integer
             <> (select quantity from public.stock_balances where crate_id = (select id from public.crates where code = 'rca') and product_id = (select id from public.products where sku = 'p32-race-soap'))
        then
          raise exception 'snapshot did not stay behind the transfer';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_prepare_counted(false, false); select public.phase32_prepare_receipt();")
  await race(
    "receipt posts during counting",
    "select public.phase32_claim('manager.phase32race@example.com'); select pg_sleep(1.5);",
    compete(manager2, `
      select public.verify_stock_receipt((
        select id from public.stock_receipts
        where godown_id = (select id from public.branches where code = 'phase32_race') and status = 'submitted'
        order by created_at desc limit 1
      ), 'race-count-' || left(gen_random_uuid()::text, 8));
      do $$
      declare
        line jsonb;
      begin
        select item into line
        from jsonb_array_elements(public.get_stock_verification(public.phase32_open_id()) -> 'lines') item
        where item ->> 'sku' = 'p32-race-soap';
        if (line ->> 'expected_cases')::integer <> (line ->> 'counted_cases')::integer
          or jsonb_array_length(line -> 'movements') < 1 then
          raise exception 'receipt during counting was not kept apart from the snapshot';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_prepare_counted(false, false);")
  await race(
    "transfer into a selected crate",
    "select public.phase32_claim('keeper.phase32race@example.com'); select pg_sleep(1.5);",
    compete(manager, `
      select public.post_crate_transfer(
        (select id from public.products where sku = 'p32-race-soap'),
        (select id from public.crates where code = 'rcb'),
        (select id from public.crates where code = 'rca'),
        1,
        'race-in-' || left(gen_random_uuid()::text, 8),
        null
      );
    `),
  )

  await race(
    "transfer out of a selected crate",
    "select public.phase32_claim('keeper.phase32race@example.com'); select pg_sleep(1.5);",
    compete(manager, `
      select public.post_crate_transfer(
        (select id from public.products where sku = 'p32-race-soap'),
        (select id from public.crates where code = 'rca'),
        (select id from public.crates where code = 'rcb'),
        1,
        'race-out-' || left(gen_random_uuid()::text, 8),
        null
      );
      do $$
      declare
        line jsonb;
      begin
        select item into line
        from jsonb_array_elements(public.get_stock_verification(public.phase32_open_id()) -> 'lines') item
        where item ->> 'sku' = 'p32-race-soap';
        if (line ->> 'expected_cases')::integer is null or jsonb_array_length(line -> 'movement_ids') < 2 then
          raise exception 'in and out transfers were not both recorded';
        end if;
      end;
      $$;
    `),
  )

  await race(
    "opposing transfers during the count",
    "select public.phase32_claim('keeper.phase32race@example.com'); select pg_sleep(1.5);",
    compete(manager, `
      select public.post_crate_transfer(
        (select id from public.products where sku = 'p32-race-soap'),
        (select id from public.crates where code = 'rca'),
        (select id from public.crates where code = 'rcb'),
        1,
        'race-opp-a-' || left(gen_random_uuid()::text, 8),
        null
      );
      select public.post_crate_transfer(
        (select id from public.products where sku = 'p32-race-soap'),
        (select id from public.crates where code = 'rcb'),
        (select id from public.crates where code = 'rca'),
        1,
        'race-opp-b-' || left(gen_random_uuid()::text, 8),
        null
      );
      do $$
      declare
        line jsonb;
      begin
        select item into line
        from jsonb_array_elements(public.get_stock_verification(public.phase32_open_id()) -> 'lines') item
        where item ->> 'sku' = 'p32-race-soap';
        if jsonb_array_length(line -> 'movement_ids') < 2 then
          raise exception 'opposing transfers disappeared from the movement history';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_prepare_counted(true, true);")
  await race(
    "product deactivation races with closure",
    "select public.phase32_hold_product();",
    compete(manager, `
      do $$
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'product race');
        raise exception 'closure ignored a deactivated product';
      exception
        when check_violation then
          if sqlerrm <> 'inactive object must be reviewed' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_verifications where id = public.phase32_open_id()) = 'closed' then
          raise exception 'product race closed the verification';
        end if;
      end;
      $$;
    `),
  )
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), true);")

  await psql("select public.phase32_prepare_counted(true, true);")
  await race(
    "crate deactivation races with closure",
    "select public.phase32_hold_crate();",
    compete(manager, `
      do $$
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'crate race');
        raise exception 'closure ignored a deactivated crate';
      exception
        when check_violation then
          if sqlerrm <> 'inactive object must be reviewed' then
            raise;
          end if;
      end;
      $$;
    `),
  )
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_crate_active((select id from public.crates where code = 'rempty'), true);")

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "two managers close the same verification",
    "select public.phase32_hold_close();",
    compete(manager2, `
      do $$
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'second close');
        raise exception 'second close was accepted';
      exception
        when insufficient_privilege then
          null;
      end;
      $$;
      do $$
      begin
        if (select count(*) from public.stock_verifications where godown_id = (select id from public.branches where code = 'phase32_race') and status = 'closed' and closure_note = 'race close') <> 1 then
          raise exception 'close race did not record one closure';
        end if;
      end;
      $$;
    `),
  )

  await psql(`
    select public.phase32_prepare_counted(true, false);
    select public.phase32_stage_pending();
  `)
  await race(
    "photo finalization races with closure",
    "select public.phase32_hold_close();",
    compete(manager2, `
      do $$
      declare
        evidence_id uuid;
      begin
        select id into evidence_id
        from public.stock_verification_evidence
        where verification_id = (
          select id from public.stock_verifications
          where godown_id = (select id from public.branches where code = 'phase32_race')
          order by started_at desc limit 1
        )
          and verified_at is null
        order by created_at desc
        limit 1;
        perform public.finalize_verification_photo_upload(evidence_id, encode(decode('ffd8ffd9','hex'), 'base64'));
        raise exception 'photo was finalized after closure';
      exception
        when insufficient_privilege or check_violation then
          null;
      end;
      $$;
    `),
  )

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "stock movement races with closure",
    "select public.phase32_hold_transfer();",
    compete(manager2, `
      do $$
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'movement race');
        raise exception 'closure accepted an unreviewed movement';
      exception
        when check_violation then
          if sqlerrm <> 'movement must be reconciled' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_verifications where id = public.phase32_open_id()) = 'closed' then
          raise exception 'movement race closed the verification';
        end if;
        if (select count(*) from public.stock_ledger where product_id = (select id from public.products where sku = 'p32-race-soap')) < 2 then
          raise exception 'movement race blocked the transfer';
        end if;
      end;
      $$;
    `),
  )

  const admin = "admin.phase32race@example.com"

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "product row lock then closure",
    "select public.phase32_hold_product_row();",
    compete(manager, "select public.close_stock_verification(public.phase32_open_id(), 'matched', 'product row close');"),
  )
  await psql(`
    do $$
    begin
      if (select status from public.stock_verifications where closure_note = 'product row close') is distinct from 'closed' then
        raise exception 'closure did not commit before the product change';
      end if;
      if (select is_active from public.products where sku = 'p32-race-soap') then
        raise exception 'product deactivation did not commit after closure';
      end if;
    end;
    $$;
  `)
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), true);")
  console.log("PASS product row lock then closure ordering")

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "closure lock precedes product deactivation",
    "select public.phase32_hold_close();",
    compete(admin, "select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), false);"),
  )
  await psql(`
    do $$
    begin
      if (select status from public.stock_verifications where closure_note = 'race close' order by closed_at desc limit 1) is distinct from 'closed' then
        raise exception 'closure lost the verification lock race';
      end if;
      if (select is_active from public.products where sku = 'p32-race-soap') then
        raise exception 'deactivation did not wait for closure';
      end if;
    end;
    $$;
  `)
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), true);")
  console.log("PASS closure lock precedes product deactivation")

  await psql("select public.phase32_prepare_counted(true, true);")
  await race(
    "closure lock precedes crate deactivation",
    "select public.phase32_hold_close();",
    compete(admin, "select public.set_crate_active((select id from public.crates where code = 'rempty'), false);"),
  )
  await psql(`
    do $$
    begin
      if (select is_active from public.crates where code = 'rempty') then
        raise exception 'crate deactivation did not commit after closure';
      end if;
    end;
    $$;
  `)
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_crate_active((select id from public.crates where code = 'rempty'), true);")
  console.log("PASS closure lock precedes crate deactivation")

  await psql(`
    select public.phase32_prepare_counted(true, false);
    select public.phase32_claim('admin.phase32race@example.com');
    select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), false);
  `)
  await psql(`
    do $$
    begin
      perform public.phase32_claim('manager.phase32race@example.com');
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'after count');
        raise exception 'deactivation after the count was ignored';
      exception
        when check_violation then
          if sqlerrm <> 'inactive object must be reviewed' then
            raise;
          end if;
      end;
    end;
    $$;
  `)
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), true);")
  console.log("PASS deactivation after the count requires review")

  await psql(`
    select public.phase32_prepare_counted(true, false);
    select public.phase32_claim('manager.phase32race@example.com');
    select public.review_verification_inactive_object(
      'line',
      (select id from public.stock_verification_lines where verification_id = public.phase32_open_id() limit 1),
      'reviewed while active'
    );
    select public.phase32_claim('admin.phase32race@example.com');
    select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), false);
  `)
  await psql(`
    do $$
    begin
      perform public.phase32_claim('manager.phase32race@example.com');
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'stale review');
        raise exception 'stale inactive review was accepted';
      exception
        when check_violation then
          if sqlerrm <> 'inactive object must be reviewed' then
            raise;
          end if;
      end;
    end;
    $$;
  `)
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_product_active((select id from public.products where sku = 'p32-race-soap'), true);")
  console.log("PASS deactivation after review requires a new review")

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "unrelated product deactivation proceeds",
    "select public.phase32_hold_close_locations();",
    compete(admin, `
      do $$
      begin
        perform set_config('statement_timeout', '400ms', true);
        perform public.set_product_active((select id from public.products where sku = 'p32-race-other'), false);
      end;
      $$;
    `),
  )
  await psql("select public.phase32_claim('admin.phase32race@example.com'); select public.set_product_active((select id from public.products where sku = 'p32-race-other'), true);")
  console.log("PASS unrelated product deactivation proceeds")

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "zone deactivation waits for closure",
    "select public.phase32_hold_close_locations();",
    compete(admin, `
      do $$
      begin
        perform set_config('lock_timeout', '400ms', true);
        perform public.set_zone_active((select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race')), false);
        raise exception 'zone deactivation did not wait for closure';
      exception
        when lock_not_available then
          null;
      end;
      $$;
    `),
  )
  await psql(`
    do $$
    begin
      if not (select is_active from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase32_race')) then
        raise exception 'stocked zone was deactivated';
      end if;
    end;
    $$;
  `)
  console.log("PASS zone deactivation waits and still rejects stock")

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "receipt waits behind closure location locks",
    "select public.phase32_hold_close_locations();",
    compete(keeper, "select public.phase32_prepare_receipt(); select public.phase32_claim('manager.phase32race@example.com'); select public.verify_stock_receipt((select id from public.stock_receipts where godown_id = (select id from public.branches where code = 'phase32_race') and status = 'submitted' order by created_at desc limit 1), 'race-after-close-' || left(gen_random_uuid()::text, 8));"),
  )
  await psql(`
    do $$
    begin
      if (select ledger_movement_cases from public.stock_verification_lines where verification_id = (select id from public.stock_verifications where closure_note = 'locations close' order by closed_at desc limit 1) limit 1) <> 0 then
        raise exception 'closure stored a receipt that had not committed';
      end if;
    end;
    $$;
  `)
  console.log("PASS receipt waits behind closure location locks")

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "receipt posts before closure sees movements",
    "select public.phase32_hold_receipt_locations();",
    compete(manager2, `
      do $$
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'during receipt');
        raise exception 'closure missed the receipt';
      exception
        when check_violation then
          if sqlerrm <> 'movement must be reconciled' then
            raise;
          end if;
      end;
      $$;
    `),
  )
  console.log("PASS receipt posts before closure sees movements")

  await psql("select public.phase32_prepare_counted(true, false);")
  await race(
    "transfer waits behind closure location locks",
    "select public.phase32_hold_close_locations();",
    compete(manager2, "select public.post_crate_transfer((select id from public.products where sku = 'p32-race-soap'), (select id from public.crates where code = 'rca'), (select id from public.crates where code = 'rcb'), 1, 'race-after-close-' || left(gen_random_uuid()::text, 8), null);"),
  )
  console.log("PASS transfer waits behind closure location locks")

  await psql(`
    select public.phase32_prepare_counted(true, false);
    select public.phase32_post_other();
  `)
  await psql(`
    do $$
    begin
      perform public.phase32_claim('manager.phase32race@example.com');
      begin
        perform public.close_stock_verification(public.phase32_open_id(), 'matched', 'orphan movement');
        raise exception 'zero-balance product movement was missed';
      exception
        when check_violation then
          if sqlerrm <> 'movement must be reconciled' then
            raise;
          end if;
      end;
    end;
    $$;
  `)
  console.log("PASS movement into a zero-balance product blocks closure")

  await psql(`
    do $$
    begin
      if exists (
        select 1 from pg_trigger
        where tgname in (
          'stock_ledger_append_only',
          'stock_transactions_append_only',
          'stock_verifications_guard'
        ) and tgenabled <> 'O'
      ) then
        raise exception 'a race left a trigger disabled';
      end if;
    end;
    $$;
  `)
} finally {
  await psql(cleanupSql)
}
console.log("Phase 3.2 concurrency cleanup completed")
console.log("Phase 3.2 concurrency tests passed")
