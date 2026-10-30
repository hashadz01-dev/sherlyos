/**
 * Emits one SQL batch that calls existing master RPCs as Jeffin.
 * Used for the authorized development-cloud apply. Does not flip flags
 * and does not post stock, lots, or prices.
 */
import { writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { CATEGORIES, SUPPLIERS, insertableProducts } from "./m7-7-catalog.mjs"

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..")
const JEFFIN_ID = "cdc087c0-0295-425d-8dbe-9a91030bf012"

function sqlStr(value) {
  return `'${String(value).replaceAll("'", "''")}'`
}

const lines = [
  "-- M7.7 authorized development-cloud master import. Not a schema migration.",
  "-- Calls create_product_category, create_supplier, set_supplier_active,",
  "-- create_product, set_product_billing_conversion. Rolls back on flag or stock drift.",
  "do $$",
  "declare",
  `  admin_id uuid := '${JEFFIN_ID}';`,
  "  ledger_before bigint;",
  "  balance_before bigint;",
  "  lot_before bigint;",
  "  price_before bigint;",
  "  note_before bigint;",
  "  flag_before integer;",
  ...CATEGORIES.map((row) => `  cat_${row.code.toLowerCase()} uuid;`),
  "  product_id uuid;",
  "  supplier_id uuid;",
  "begin",
  "  select count(*) into ledger_before from public.stock_ledger;",
  "  select count(*) into balance_before from public.stock_balances;",
  "  select count(*) into lot_before from public.stock_lots;",
  "  select count(*) into price_before from public.product_selling_prices;",
  "  select count(*) into note_before from public.invoice_notes;",
  "  select count(*) into flag_before from public.app_configuration",
  "    where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked')",
  "      and value = 'true'::jsonb;",
  "  if flag_before is distinct from 0 then",
  "    raise exception 'operational flags must remain false';",
  "  end if;",
  "  if not exists (select 1 from auth.users where id = admin_id and email = 'jeffinpappachan110@gmail.com') then",
  "    raise exception 'Jeffin admin id mismatch';",
  "  end if;",
  "  perform set_config('request.jwt.claim.sub', admin_id::text, true);",
  "  perform set_config('request.jwt.claim.role', 'authenticated', true);",
  "  perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);",
  "",
]

for (const category of CATEGORIES) {
  const ident = `cat_${category.code.toLowerCase()}`
  lines.push(
    `  ${ident} := public.create_product_category(${sqlStr(category.name)}, ${sqlStr(category.description)});`,
  )
}

lines.push("")
for (const supplier of SUPPLIERS) {
  lines.push(`  supplier_id := public.create_supplier(${sqlStr(supplier.name)}, null, null);`)
  lines.push("  perform public.set_supplier_active(supplier_id, false);")
}

lines.push("")
const categoryIdent = Object.fromEntries(
  CATEGORIES.map((row) => [row.code, `cat_${row.code.toLowerCase()}`]),
)
for (const product of insertableProducts()) {
  const cat = categoryIdent[product.categoryCode]
  lines.push(
    `  product_id := public.create_product(${sqlStr(product.sku)}, ${sqlStr(product.name)}, null, ${cat});`,
  )
  lines.push(
    `  perform public.set_product_billing_conversion(product_id, ${sqlStr(product.billingUnit)}, ${product.unitsPerCase});`,
  )
}

lines.push(
  "",
  "  if (select count(*) from public.stock_ledger) is distinct from ledger_before",
  "    or (select count(*) from public.stock_balances) is distinct from balance_before",
  "    or (select count(*) from public.stock_lots) is distinct from lot_before",
  "    or (select count(*) from public.product_selling_prices) is distinct from price_before",
  "    or (select count(*) from public.invoice_notes) is distinct from note_before",
  "  then",
  "    raise exception 'master import changed stock, lots, prices, or invoice notes';",
  "  end if;",
  "  if exists (",
  "    select 1 from public.app_configuration",
  "    where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked')",
  "      and value = 'true'::jsonb",
  "  ) then",
  "    raise exception 'operational flags changed';",
  "  end if;",
  "end;",
  "$$;",
  "",
)

const outPath = join(ROOT, "docs", "m7-7", "development-cloud-apply.sql")
writeFileSync(outPath, lines.join("\n"), "utf8")
console.log(`wrote ${outPath}`)
