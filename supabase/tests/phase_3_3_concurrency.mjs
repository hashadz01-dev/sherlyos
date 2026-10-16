import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_3_3_concurrency.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(new URL("./phase_3_3_concurrency_cleanup.sql", import.meta.url), "utf8")

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
  await psql("select public.phase33_assert_books();")
  console.log(`PASS ${name}`)
}

const manager2 = "manager2.phase33race@example.com"
const admin = "admin.phase33race@example.com"

function compete(email, body) {
  return `
    set lock_timeout = '8s';
    select public.phase33_claim('${email}');
    ${body}
  `
}

try {
  await psql(setupSql)

  await psql("select public.phase33_prepare('approved');")
  await race(
    "two simultaneous posts",
    "select public.phase33_hold_post();",
    compete(manager2, `
      do $$
      begin
        perform public.post_stock_adjustment(
          (select request_id from public.phase33_race_target),
          (select request_version from public.phase33_race_target),
          'p33racecompetepost'
        );
        raise exception 'second post was accepted';
      exception
        when unique_violation then
          if sqlerrm <> 'adjustment was already posted' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'double post did not finish posted';
        end if;
        if (select count(*) from public.stock_transactions where adjustment_request_id = (select request_id from public.phase33_race_target)) <> 1 then
          raise exception 'double post created more than one transaction';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_same_key();")
  console.log("PASS same idempotency key retry")
  await psql("select public.phase33_other_key();")
  console.log("PASS different idempotency key")

  await psql("select public.phase33_prepare('submitted');")
  await race(
    "approval versus rejection",
    "select public.phase33_hold_approve();",
    compete(manager2, `
      do $$
      begin
        perform public.reject_stock_adjustment(
          (select request_id from public.phase33_race_target),
          (select request_version from public.phase33_race_target),
          'race rejection'
        );
        raise exception 'rejection won against the held approval';
      exception
        when serialization_failure or insufficient_privilege then
          if sqlerrm not in ('adjustment was changed by someone else', 'adjustment cannot be rejected') then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'approved' then
          raise exception 'approval race did not stay approved';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('submitted');")
  await race(
    "approval versus return",
    "select public.phase33_hold_approve();",
    compete(manager2, `
      do $$
      begin
        perform public.return_stock_adjustment(
          (select request_id from public.phase33_race_target),
          (select request_version from public.phase33_race_target),
          'race return'
        );
        raise exception 'return won against the held approval';
      exception
        when serialization_failure or insufficient_privilege then
          if sqlerrm not in ('adjustment was changed by someone else', 'adjustment cannot be returned') then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'approved' then
          raise exception 'return race did not stay approved';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('approved');")
  await race(
    "posting versus return",
    "select public.phase33_hold_post();",
    compete(manager2, `
      do $$
      begin
        perform public.return_stock_adjustment(
          (select request_id from public.phase33_race_target),
          (select request_version from public.phase33_race_target),
          'return during post'
        );
        raise exception 'return won against the held post';
      exception
        when serialization_failure or insufficient_privilege then
          if sqlerrm not in ('adjustment was changed by someone else', 'adjustment cannot be returned') then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'post versus return did not stay posted';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('approved');")
  await race(
    "posting versus rejection",
    "select public.phase33_hold_post();",
    compete(manager2, `
      do $$
      begin
        perform public.reject_stock_adjustment(
          (select request_id from public.phase33_race_target),
          (select request_version from public.phase33_race_target),
          'reject during post'
        );
        raise exception 'rejection won against the held post';
      exception
        when serialization_failure or insufficient_privilege then
          if sqlerrm not in ('adjustment was changed by someone else', 'adjustment cannot be rejected') then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'post versus rejection did not stay posted';
        end if;
        if exists (
          select 1 from public.stock_adjustment_lines
          where request_id = (select request_id from public.phase33_race_target)
            and released
        ) then
          raise exception 'posted line was released';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('approved_with_receipt');")
  await race(
    "concurrent receiving",
    "select public.phase33_hold_locations_post();",
    compete(manager2, `
      select public.verify_stock_receipt(
        (select receipt_id from public.phase33_race_target),
        'p33racerecv' || left(replace(gen_random_uuid()::text, '-', ''), 12)
      );
      do $$
      begin
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'receipt race blocked the held post';
        end if;
        if (select status from public.stock_receipts where id = (select receipt_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'receipt race did not post';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('approved');")
  await race(
    "concurrent crate transfer",
    "select public.phase33_hold_locations_post();",
    compete(manager2, `
      select public.post_crate_transfer(
        (select id from public.products where sku = 'p33-race-soap'),
        (select id from public.crates where code = 'r33a'),
        (select id from public.crates where code = 'r33b'),
        1,
        'p33racemove' || left(replace(gen_random_uuid()::text, '-', ''), 10),
        null
      );
      do $$
      begin
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'transfer race blocked the held post';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('approved');")
  await race(
    "product deactivation",
    "select public.phase33_hold_locations_post();",
    compete(admin, `
      select public.set_product_active((select id from public.products where sku = 'p33-race-soap'), false);
      do $$
      begin
        if (select is_active from public.products where sku = 'p33-race-soap') then
          raise exception 'product stayed active';
        end if;
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'product deactivation blocked the post';
        end if;
      end;
      $$;
    `),
  )
  await psql(`
    select public.phase33_claim('${admin}');
    select public.set_product_active((select id from public.products where sku = 'p33-race-soap'), true);
  `)

  await psql("select public.phase33_prepare('approved');")
  await race(
    "crate deactivation",
    "select public.phase33_hold_locations_post();",
    compete(admin, `
      do $$
      begin
        perform public.set_crate_active((select id from public.crates where code = 'r33a'), false);
        raise exception 'stocked crate was deactivated';
      exception
        when check_violation then
          if sqlerrm <> 'crate still holds stock' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if not (select is_active from public.crates where code = 'r33a') then
          raise exception 'crate deactivation race deactivated a stocked crate';
        end if;
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'crate deactivation blocked the post';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('approved');")
  await race(
    "zone deactivation",
    "select public.phase33_hold_locations_post();",
    compete(admin, `
      do $$
      begin
        perform public.set_zone_active((select id from public.zones where code = 'r33z'), false);
        raise exception 'stocked zone was deactivated';
      exception
        when check_violation then
          if sqlerrm <> 'zone still holds stock' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if not (select is_active from public.zones where code = 'r33z') then
          raise exception 'zone deactivation race deactivated a stocked zone';
        end if;
        if (select status from public.stock_adjustment_requests where id = (select request_id from public.phase33_race_target)) <> 'posted' then
          raise exception 'zone deactivation blocked the post';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('claim');")
  await race(
    "duplicate verification-line claims",
    "select public.phase33_hold_claim();",
    compete("manager.phase33race@example.com", `
      do $$
      begin
        perform public.create_stock_adjustment(
          (select verification_id from public.phase33_race_target),
          'shortage',
          'second claim',
          array[(select line_id from public.phase33_race_target)],
          'p33raceclaimother',
          null
        );
        raise exception 'duplicate verification line was claimed';
      exception
        when unique_violation then
          if sqlerrm not like '%stock_adjustment_lines_active_claim%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select count(*) from public.stock_adjustment_lines where verification_line_id = (select line_id from public.phase33_race_target) and not released) <> 1 then
          raise exception 'duplicate claim left more than one active line';
        end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_prepare('approved');")
  await race(
    "negative stock prevention",
    "select public.phase33_hold_locations_post();",
    compete(manager2, `
      do $$
      begin
        perform public.post_crate_transfer(
          (select id from public.products where sku = 'p33-race-soap'),
          (select id from public.crates where code = 'r33a'),
          (select id from public.crates where code = 'r33b'),
          1000000,
          'p33raceneg' || left(replace(gen_random_uuid()::text, '-', ''), 12),
          null
        );
        raise exception 'oversized transfer was accepted';
      exception
        when check_violation then
          if sqlerrm <> 'insufficient stock' then
            raise;
          end if;
      end;
      $$;
    `),
  )

  await psql("select public.phase33_stale_after_receipt();")
  await psql("select public.phase33_assert_books();")
  console.log("PASS receipt after verification requires a new verification")
  await psql("select public.phase33_stale_after_transfer();")
  await psql("select public.phase33_assert_books();")
  console.log("PASS transfer after verification requires a new verification")

  console.log("CONCURRENCY_EXIT:0")
} catch (error) {
  console.error(`FAIL ${error.message}`)
  console.error("CONCURRENCY_EXIT:1")
  process.exitCode = 1
} finally {
  try {
    await psql(cleanupSql)
    console.log("CLEANUP_EXIT:0")
  } catch (error) {
    console.error(`CLEANUP_FAIL ${error.message}`)
    console.error("CLEANUP_EXIT:1")
    process.exitCode = 1
  }
}
