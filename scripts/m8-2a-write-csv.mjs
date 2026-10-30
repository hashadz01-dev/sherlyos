import { mkdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { ROUTE_COUNTS, SOURCE_ENTRIES, proposedShopKey } from "./m8-2a-extracted.mjs"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const outDir = join(root, "data", "imports", "shops")
mkdirSync(outDir, { recursive: true })

function csvEscape(value) {
  const text = String(value ?? "")
  if (/[",\n]/.test(text)) return `"${text.replaceAll('"', '""')}"`
  return text
}

function toCsv(headers, rows) {
  return [headers.join(","), ...rows.map((row) => headers.map((key) => csvEscape(row[key])).join(","))].join(
    "\n",
  ) + "\n"
}

const seen = new Map()
const unique = []
for (const row of SOURCE_ENTRIES) {
  const key = row.proposed_shop_key
  if (seen.has(key)) {
    row.review_status = row.review_status === "extracted" ? "duplicate_in_source" : row.review_status
    row.review_notes = [row.review_notes, `same key as sequence ${seen.get(key)}`].filter(Boolean).join("; ")
    continue
  }
  seen.set(key, row.sequence)
  unique.push(row)
}

const shopCsv = toCsv(
  [
    "source_sheet",
    "route_name",
    "weekday",
    "sequence",
    "original_shop_name",
    "normalized_shop_name",
    "proposed_shop_key",
    "review_status",
  ],
  SOURCE_ENTRIES.map((row) => ({
    ...row,
    route_name: row.route_code,
  })),
)

const membershipCsv = toCsv(
  ["source_sheet", "route_name", "weekday", "sequence", "original_shop_name", "proposed_shop_key", "review_status"],
  SOURCE_ENTRIES.map((row) => ({
    source_sheet: row.source_sheet,
    route_name: row.route_code,
    weekday: row.weekday ?? "",
    sequence: row.sequence,
    original_shop_name: row.original_shop_name,
    proposed_shop_key: row.proposed_shop_key,
    review_status: row.review_status,
  })),
)

const reviewCsv = toCsv(
  [
    "source_sheet",
    "route_name",
    "weekday",
    "sequence",
    "original_shop_name",
    "normalized_shop_name",
    "proposed_shop_key",
    "review_status",
    "review_notes",
  ],
  SOURCE_ENTRIES.filter((row) => row.review_status !== "extracted").map((row) => ({
    ...row,
    route_name: row.route_code,
    weekday: row.weekday ?? "",
  })),
)

writeFileSync(join(outDir, "sherlyos_shop_master.csv"), shopCsv)
writeFileSync(join(outDir, "sherlyos_route_shop_memberships.csv"), membershipCsv)
writeFileSync(join(outDir, "shop_import_review.csv"), reviewCsv)

const report = {
  total_source_rows: SOURCE_ENTRIES.length,
  unique_proposed_shops: unique.length,
  shops_per_route: ROUTE_COUNTS,
  ocr_uncertain: SOURCE_ENTRIES.filter((row) => row.review_status === "ocr_uncertain").length,
  duplicate_in_source: SOURCE_ENTRIES.length - unique.length,
  unreadable_names: SOURCE_ENTRIES.filter((row) => row.review_status === "unreadable").map(
    (row) => row.original_shop_name,
  ),
  count_gaps: {
    thevara: { extracted: ROUTE_COUNTS.thevara, listed_heading: 42 },
    kadavanthra: { extracted: ROUTE_COUNTS.kadavanthra, listed_heading: 41 },
    kalamassery: { extracted: ROUTE_COUNTS.kalamassery, listed_heading: 31 },
    chullikkal: { extracted: ROUTE_COUNTS.chullikkal, listed_heading: 40 },
  },
}
writeFileSync(join(outDir, "dry-run-report.json"), JSON.stringify(report, null, 2) + "\n")

function sqlLiteral(value) {
  if (value == null) return "null"
  return `'${String(value).replaceAll("'", "''")}'`
}

const valueRows = unique
  .map((row) => `      (${sqlLiteral(row.route_code)}, ${row.sequence}, ${sqlLiteral(row.original_shop_name)})`)
  .join(",\n")

const sql = `-- M8.2A shop import. Name only. No phone, GSTIN, address, salesperson, or godown.
do $$
declare
  rec record;
  created_shop uuid;
  target_route uuid;
begin
  if exists (select 1 from public.shops) then
    raise exception 'shops already populated';
  end if;

  for rec in
    select * from (values
${valueRows}
    ) as src(route_code, visit_sequence, shop_name)
  loop
    select id into target_route from public.sales_routes where code = rec.route_code;
    if target_route is null then
      raise exception 'missing route %', rec.route_code;
    end if;
    insert into public.shops (name) values (rec.shop_name) returning id into created_shop;
    insert into public.shop_sales_route_memberships (shop_id, route_id, visit_sequence)
    values (created_shop, target_route, rec.visit_sequence);
  end loop;
end $$;
`

writeFileSync(join(outDir, "apply-local-and-cloud.sql"), sql)
console.log(
  JSON.stringify(
    {
      total: SOURCE_ENTRIES.length,
      unique: unique.length,
      routes: ROUTE_COUNTS,
    },
    null,
    2,
  ),
)
void proposedShopKey
