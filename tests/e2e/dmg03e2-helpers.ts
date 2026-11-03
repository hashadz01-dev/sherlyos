import { expect, type Page } from "@playwright/test"
import { runLocalSql } from "./disposable-stock"
import { M82C_USERS, M82C_SITE, M82C_CATALOG } from "../../src/lib/uat/m82c-manifest"

export const DMG03E2_PASSWORD = "local-only-m82c"

export const DMG03E2_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
)

export async function signIn(page: Page, email: string) {
  await page.goto("/login")
  if ((await page.getByLabel("Email").count()) === 0) {
    await page.getByRole("button", { name: "Account menu" }).click()
    await page.getByRole("menuitem", { name: "Sign out" }).click()
    await expect(page.getByLabel("Email")).toBeVisible({ timeout: 20_000 })
  }
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(DMG03E2_PASSWORD)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(
    page.getByRole("heading", {
      name: /Operations Overview|Damage Management|Exceptional approvals/i,
    }),
  ).toBeVisible({ timeout: 20_000 })
}

async function selectOptionContaining(
  page: Page,
  label: string | RegExp,
  text: string,
) {
  const select = page.getByLabel(label)
  const value = await select.evaluate((el, needle) => {
    const node = el as HTMLSelectElement
    return (
      Array.from(node.options).find((opt) => opt.textContent?.includes(needle))
        ?.value ?? ""
    )
  }, text)
  expect(value).not.toEqual("")
  await select.selectOption(value)
  return value
}

/**
 * Browser-only Storage Damage draft → evidence → submit → GM verify.
 * Returns report id/number and selected lot code. No SQL repair.
 */
export async function createVerifiedStorageDamage(
  page: Page,
  input: {
    lotCode: string
    reason: string
  },
) {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto("/damage/new")

  const godown = page.locator("#damage-godown")
  await expect(
    godown.locator(`option:has-text("${M82C_SITE.godownName}")`),
  ).toBeAttached({ timeout: 15_000 })
  await godown.selectOption({ label: M82C_SITE.godownName })
  await page.getByRole("radio", { name: /Storage/i }).click()

  await expect
    .poll(async () => {
      await page.getByRole("button", { name: "Add line" }).click()
      const count = await page.getByLabel("Product").locator("option").count()
      if (count <= 1) await page.getByRole("button", { name: "Remove" }).click()
      return count
    }, { timeout: 20_000 })
    .toBeGreaterThan(1)

  await selectOptionContaining(page, "Product", M82C_CATALOG.stableSku)
  await selectOptionContaining(page, /^Crate/, M82C_SITE.crateACode)
  await selectOptionContaining(page, "Stock lot", input.lotCode)
  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill(input.reason)

  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 30_000,
  })
  const reportNumber =
    ((await page.getByRole("heading").first().textContent()) ?? "")
      .replace(/^Edit\s+/, "")
      .trim()
  expect(reportNumber).toMatch(/^DMG-/)

  await page.getByLabel("Select photo").setInputFiles({
    name: "dmg03e2.png",
    mimeType: "image/png",
    buffer: DMG03E2_PNG,
  })
  await expect(page.getByAltText("Finalized damage evidence")).toBeVisible({
    timeout: 30_000,
  })
  await page.getByRole("button", { name: "Review and submit" }).click()
  await page.getByRole("button", { name: "Submit report" }).click()
  await expect(page.getByText("Submitted", { exact: true }).first()).toBeVisible({
    timeout: 30_000,
  })

  const reportId = runLocalSql(
    `select id::text from public.damage_reports where report_number = '${reportNumber}';`,
    "report-id",
  )

  await signIn(page, M82C_USERS.godownManager)
  await page.goto(`/damage/${reportId}`)
  await expect(page.getByRole("heading", { name: reportNumber })).toBeVisible({
    timeout: 20_000,
  })
  await page.getByRole("button", { name: "Verify", exact: true }).click()
  await page.getByLabel("Confirm damage verification").click()
  await expect(page.getByText("Verified", { exact: true }).first()).toBeVisible({
    timeout: 20_000,
  })

  return { reportId, reportNumber, lotCode: input.lotCode }
}

/**
 * Free picking capacity on disposable m82c stock by rejecting leftover
 * submitted reports through the trusted return/reject RPCs (GM JWT).
 * Verified holds cannot be cancelled; those are consumed by disposition UATs.
 */
export function releaseSubmittedDisposableHolds() {
  return runLocalSql(
    `
    do $$
    declare
      r record;
      gm uuid;
      msg text;
    begin
      select id into gm from auth.users where email = '${M82C_USERS.godownManager}';
      perform set_config('request.jwt.claim.sub', gm::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', gm, 'role', 'authenticated')::text,
        true
      );
      perform set_config('role', 'authenticated', true);

      for r in
        select dr.id, dr.version, dr.report_number
        from public.damage_reports dr
        join public.products p on p.id = (
          select dli.product_id from public.damage_report_lines dli
          where dli.damage_report_id = dr.id limit 1
        )
        where dr.status = 'submitted'
          and p.sku = '${M82C_CATALOG.stableSku}'
      loop
        begin
          perform public.reject_damage_report(
            r.id, r.version, 'DMG-03E.2 fixture capacity release'
          );
        exception
          when others then
            get stacked diagnostics msg = message_text;
            raise notice 'skip %: %', r.report_number, msg;
        end;
      end loop;
    end $$;
    select 'ok';
    `,
    "release-submitted",
  )
}

/** Prefer an existing verified active hold for exceptional UAT when avail is 0. */
export function findVerifiedActiveHoldReport(lotCode: string) {
  return runLocalSql(
    `select r.id::text || '|' || r.report_number || '|' || r.version::text
     from public.damage_reports r
     join public.damage_stock_holds h on h.damage_report_id = r.id
     join public.stock_lots sl on sl.id = h.lot_id
     join public.products p on p.id = h.product_id
     where r.status = 'verified'
       and h.status = 'active'
       and p.sku = '${M82C_CATALOG.stableSku}'
       and sl.manufacturer_lot_code = '${lotCode}'
       and not exists (
         select 1 from public.damage_exceptional_requests ex
         where ex.damage_report_id = r.id
           and ex.status in ('requested', 'approved', 'posted')
       )
     order by r.created_at desc
     limit 1;`,
    `find-hold-${lotCode}`,
  )
}

export function stockSnapshot(lotCode: string) {
  return runLocalSql(
    `select
       (select sb.quantity::text
        from public.stock_balances sb
        join public.products p on p.id = sb.product_id
        join public.crates c on c.id = sb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}' and c.code = '${M82C_SITE.crateACode}')
       || '|' ||
       coalesce((
         select sb.quantity::text
         from public.stock_balances sb
         join public.crates c on c.id = sb.crate_id
         join public.products p on p.id = sb.product_id
         where p.sku = '${M82C_CATALOG.stableSku}'
           and c.location_role = 'quarantine'
         limit 1
       ), '0')
       || '|' ||
       (select slb.quantity::text
          || ':' || app_private.active_damage_hold_lot_cases(sl.id, c.id)::text
          || ':' || app_private.picking_available_cases(sl.id, c.id)::text
        from public.stock_lots sl
        join public.products p on p.id = sl.product_id
        join public.stock_lot_balances slb on slb.lot_id = sl.id
        join public.crates c on c.id = slb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}'
          and c.code = '${M82C_SITE.crateACode}'
          and sl.manufacturer_lot_code = '${lotCode}')
       || '|' ||
       coalesce((
         select slb.quantity::text
         from public.stock_lot_balances slb
         join public.stock_lots sl on sl.id = slb.lot_id
         join public.crates c on c.id = slb.crate_id
         join public.products p on p.id = sl.product_id
         where p.sku = '${M82C_CATALOG.stableSku}'
           and sl.manufacturer_lot_code = '${lotCode}'
           and c.location_role = 'quarantine'
         limit 1
       ), '0')
       || '|' ||
       (select count(*)::text from public.stock_ledger);`,
    `snap-${lotCode}`,
  )
}
