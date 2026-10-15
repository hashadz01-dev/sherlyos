import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(
  new URL("./phase_3_1_concurrency.sql", import.meta.url),
  "utf8",
)

const cleanupSql = readFileSync(
  new URL("./phase_3_1_concurrency_cleanup.sql", import.meta.url),
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
    "two managers verify the same receipt",
    "select public.phase31_hold_verify();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager2.phase31race@example.com');
        perform public.verify_stock_receipt(
          (select id from public.stock_receipts where document_reference = 'RACE-VERIFY'),
          'phase31-verify-other'
        );
        raise exception 'second verification was accepted';
      exception
        when unique_violation then
          null;
      end;
      $$;
      do $$
      begin
        if (
          select count(*) from public.stock_transactions
          where receipt_id = (select id from public.stock_receipts where document_reference = 'RACE-VERIFY')
        ) <> 1 then
          raise exception 'verification race did not post exactly once';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race-verify')
            and product_id = (select id from public.products where sku = 'p31-race-verify')
        ) <> 5 then
          raise exception 'verification race posted damaged cases or doubled stock';
        end if;
        if (select status from public.stock_receipts where document_reference = 'RACE-VERIFY') <> 'posted' then
          raise exception 'verification race left an inconsistent receipt';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "editing races with verification",
    "select public.phase31_hold_edit();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('keeper.phase31race@example.com');
        perform public.update_stock_receipt(
          (select id from public.stock_receipts where document_reference = 'RACE-EDIT'),
          (select id from public.branches where code = 'phase31_race'),
          (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
          'RACE-EDIT',
          current_date,
          null,
          jsonb_build_array(jsonb_build_object(
            'product_id', (select id from public.products where sku = 'p31-race-edit'),
            'destination_crate_id', (select id from public.crates where code = 'race-edit'),
            'document_cases', 9, 'counted_cases', 9, 'damaged_cases', 0
          ))
        );
        raise exception 'edit during verification was accepted';
      exception
        when insufficient_privilege then
          null;
      end;
      $$;
      do $$
      begin
        if (
          select counted_cases from public.stock_receipt_lines
          where receipt_id = (select id from public.stock_receipts where document_reference = 'RACE-EDIT')
        ) <> 4 then
          raise exception 'edit race changed the posted line';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race-edit')
            and product_id = (select id from public.products where sku = 'p31-race-edit')
        ) <> 3 then
          raise exception 'edit race posted the wrong quantity';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "cancellation races with verification",
    "select public.phase31_hold_cancel();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager2.phase31race@example.com');
        perform public.cancel_stock_receipt(
          (select id from public.stock_receipts where document_reference = 'RACE-CANCEL'),
          'race cancel'
        );
        raise exception 'cancel during verification was accepted';
      exception
        when insufficient_privilege then
          null;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_receipts where document_reference = 'RACE-CANCEL') <> 'posted' then
          raise exception 'cancel race left the receipt unposted';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race-cancel')
            and product_id = (select id from public.products where sku = 'p31-race-cancel')
        ) <> 2 then
          raise exception 'cancel race lost the posted quantity';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "two receipts add stock to the same crate and product",
    "select public.phase31_hold_add();",
    `
      set lock_timeout = '10s';
      select public.phase31_claim('manager2.phase31race@example.com');
      select public.verify_stock_receipt(
        (select id from public.stock_receipts where document_reference = 'RACE-ADD-2'),
        'phase31-add-other'
      );
      do $$
      begin
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race-add')
            and product_id = (select id from public.products where sku = 'p31-race-add')
        ) <> 9 then
          raise exception 'two receipt posts did not add both accepted quantities';
        end if;
        if exists (select 1 from public.stock_balances where quantity < 0) then
          raise exception 'a negative balance exists';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "posting races with crate deactivation",
    "select public.phase31_hold_crate_post();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager2.phase31race@example.com');
        perform public.set_crate_active((select id from public.crates where code = 'race-crate'), false);
        raise exception 'a stocked crate was deactivated during receipt posting';
      exception
        when check_violation then
          if sqlerrm not like '%holds stock%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if exists (select 1 from public.crates where code = 'race-crate' and not is_active) then
          raise exception 'receipt posting left the crate inactive';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race-crate')
            and product_id = (select id from public.products where sku = 'p31-race-crate')
        ) <> 2 then
          raise exception 'crate race lost the posted quantity';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "deactivation races with receipt posting",
    "select public.phase31_hold_crate_off();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager2.phase31race@example.com');
        perform public.verify_stock_receipt(
          (select id from public.stock_receipts where document_reference = 'RACE-DEAD'),
          'phase31-dead-verify'
        );
        raise exception 'receipt posted into a crate that was being deactivated';
      exception
        when check_violation then
          if sqlerrm not like '%inactive%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if exists (select 1 from public.crates where code = 'race-dead' and is_active) then
          raise exception 'deactivation race left the crate active';
        end if;
        if exists (
          select 1 from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race-dead')
            and quantity > 0
        ) then
          raise exception 'deactivated crate received stock';
        end if;
        if (select status from public.stock_receipts where document_reference = 'RACE-DEAD') <> 'submitted' then
          raise exception 'failed receipt was marked posted';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "posting races with zone deactivation",
    "select public.phase31_hold_zone_post();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager2.phase31race@example.com');
        perform public.set_zone_active(
          (select id from public.zones where code = 'rzoff'),
          false
        );
        raise exception 'a stocked zone was deactivated during receipt posting';
      exception
        when check_violation then
          if sqlerrm not like '%holds stock%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if exists (select 1 from public.zones where code = 'rzoff' and not is_active) then
          raise exception 'receipt posting left the zone inactive';
        end if;
        if (
          select quantity from public.stock_balances
          where crate_id = (select id from public.crates where code = 'race-zone')
            and product_id = (select id from public.products where sku = 'p31-race-zone')
        ) <> 3 then
          raise exception 'zone race lost the posted quantity';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "zone deactivation races with receipt posting",
    "select public.phase31_hold_zone_off();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager2.phase31race@example.com');
        perform public.verify_stock_receipt(
          (select id from public.stock_receipts where document_reference = 'RACE-ZONE-OFF'),
          'phase31-zone-off-verify'
        );
        raise exception 'receipt posted into a zone that was being deactivated';
      exception
        when check_violation then
          if sqlerrm not like '%inactive%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if exists (select 1 from public.zones where code = 'rzempty' and is_active) then
          raise exception 'zone deactivation race left the zone active';
        end if;
        if exists (
          select 1 from public.stock_balances
          join public.crates on crates.id = stock_balances.crate_id
          where crates.code = 'race-zempty' and stock_balances.quantity > 0
        ) then
          raise exception 'inactive zone received stock';
        end if;
        if (select status from public.stock_receipts where document_reference = 'RACE-ZONE-OFF') <> 'submitted' then
          raise exception 'failed zone receipt was marked posted';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "duplicate supplier document submissions",
    "select public.phase31_hold_duplicate();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('keeper.phase31race@example.com');
        perform public.create_stock_receipt(
          (select id from public.branches where code = 'phase31_race'),
          (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
          ' race-dup ',
          current_date,
          null,
          jsonb_build_array(jsonb_build_object(
            'product_id', (select id from public.products where sku = 'p31-race-verify'),
            'destination_crate_id', (select id from public.crates where code = 'race-verify'),
            'document_cases', 1, 'counted_cases', 1, 'damaged_cases', 0
          ))
        );
        raise exception 'duplicate document was accepted';
      exception
        when unique_violation then
          null;
      end;
      $$;
      do $$
      begin
        if (
          select count(*) from public.stock_receipts
          where normalized_document_reference = 'race-dup'
        ) <> 1 then
          raise exception 'duplicate document race left more than one receipt';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "product deactivation races with verification",
    "select public.phase31_hold_product_off();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager.phase31race@example.com');
        perform public.verify_stock_receipt(
          (select id from public.stock_receipts where document_reference = 'RACE-PRODUCT'),
          'phase31-product-verify'
        );
        raise exception 'inactive product was posted';
      exception
        when check_violation then
          if sqlerrm not like '%product is inactive%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_receipts where document_reference = 'RACE-PRODUCT') <> 'submitted' then
          raise exception 'product race changed the receipt status';
        end if;
        if exists (
          select 1 from public.stock_transactions
          where product_id = (select id from public.products where sku = 'p31-race-product')
        ) then
          raise exception 'inactive product created a stock transaction';
        end if;
      end;
      $$;
    `,
  )
  await race(
    "supplier deactivation races with verification",
    "select public.phase31_hold_supplier_off();",
    `
      set lock_timeout = '10s';
      do $$
      begin
        perform public.phase31_claim('manager.phase31race@example.com');
        perform public.verify_stock_receipt(
          (select id from public.stock_receipts where document_reference = 'RACE-SUPPLIER'),
          'phase31-supplier-verify'
        );
        raise exception 'inactive supplier was posted';
      exception
        when check_violation then
          if sqlerrm not like '%supplier is inactive%' then
            raise;
          end if;
      end;
      $$;
      do $$
      begin
        if (select status from public.stock_receipts where document_reference = 'RACE-SUPPLIER') <> 'submitted' then
          raise exception 'supplier race changed the receipt status';
        end if;
        if exists (
          select 1 from public.stock_balances
          where product_id = (select id from public.products where sku = 'p31-race-supplier')
            and quantity > 0
        ) then
          raise exception 'inactive supplier increased stock';
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
