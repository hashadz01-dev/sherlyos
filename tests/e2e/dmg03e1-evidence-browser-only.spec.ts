import { expect, test, type Page } from "@playwright/test"
import { localPsqlContainer, runLocalSql } from "./disposable-stock"
import {
  M82C_ISOLATION,
  M82C_USERS,
  M82C_SITE,
  M82C_CATALOG,
} from "../../src/lib/uat/m82c-manifest"

const password = "local-only-m82c"
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
)

test.describe.configure({ mode: "serial", timeout: 120_000 })

const state = {
  reportNumber: "",
  reportId: "",
  selectedLotCode: "TEST-LOT-DMG03F",
  physicalBefore: 0,
  selectedAvailBefore: 0,
  selectedHeldBefore: 0,
  otherHeldBefore: 0,
  ledgerCountBefore: 0,
}

test.beforeAll(() => {
  if (localPsqlContainer() !== M82C_ISOLATION.container) {
    throw new Error("DMG-03E.1 refused a non-m82c Postgres container")
  }
  const sysid = runLocalSql(
    "select system_identifier from pg_control_system();",
    "sysid",
  )
  expect(sysid).not.toContain(M82C_ISOLATION.forbiddenOwnerSysid)
  expect(sysid).not.toContain(M82C_ISOLATION.forbiddenM81cSysid)

  const flags = runLocalSql(
    `select key || '=' || (value #>> '{}')
     from public.app_configuration
     where key in ('damage.stock_hold_ready', 'stock.lots.dual_write_enabled')
     order by 1;`,
    "flags",
  )
  expect(flags).toContain("damage.stock_hold_ready=true")
  expect(flags).toContain("stock.lots.dual_write_enabled=true")

  const grain = runLocalSql(
    `select
       (select sb.quantity::text
        from public.stock_balances sb
        join public.products p on p.id = sb.product_id
        join public.crates c on c.id = sb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}' and c.code = '${M82C_SITE.crateACode}')
       || '|' ||
       (select app_private.picking_available_cases(sl.id, c.id)::text
          || ':' || app_private.active_damage_hold_lot_cases(sl.id, c.id)::text
        from public.stock_lots sl
        join public.products p on p.id = sl.product_id
        join public.stock_lot_balances slb on slb.lot_id = sl.id
        join public.crates c on c.id = slb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}'
          and c.code = '${M82C_SITE.crateACode}'
          and sl.manufacturer_lot_code = 'TEST-LOT-DMG03F')
       || '|' ||
       (select app_private.active_damage_hold_lot_cases(sl.id, c.id)::text
        from public.stock_lots sl
        join public.products p on p.id = sl.product_id
        join public.stock_lot_balances slb on slb.lot_id = sl.id
        join public.crates c on c.id = slb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}'
          and c.code = '${M82C_SITE.crateACode}'
          and sl.manufacturer_lot_code = 'TEST-LOT-STABLE')
       || '|' ||
       (select count(*)::text from public.stock_ledger);`,
    "baseline",
  )
  const [physical, selectedPair, otherHeld, ledger] = grain.split("|")
  const [selectedAvail, selectedHeld] = selectedPair.split(":").map(Number)
  expect(Number(physical)).toBeGreaterThanOrEqual(10)
  expect(selectedAvail).toBeGreaterThanOrEqual(1)
  state.physicalBefore = Number(physical)
  state.selectedAvailBefore = selectedAvail
  state.selectedHeldBefore = selectedHeld
  state.otherHeldBefore = Number(otherHeld)
  state.ledgerCountBefore = Number(ledger)
})

async function signIn(page: Page, email: string) {
  await page.goto("/login")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

test("invalid mime is rejected in the browser before upload", async ({ page }) => {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto("/damage/new")
  const godown = page.locator("#damage-godown")
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

  // Minimal draft so the uploader can attempt a file without isolation submit.
  const productSelect = page.getByLabel("Product")
  const productValue = await productSelect.evaluate((el, sku) => {
    const select = el as HTMLSelectElement
    return (
      Array.from(select.options).find((opt) => opt.textContent?.includes(sku))
        ?.value ?? ""
    )
  }, M82C_CATALOG.stableSku)
  await productSelect.selectOption(productValue)
  const crateSelect = page.getByLabel(/^Crate/)
  const crateValue = await crateSelect.evaluate((el, code) => {
    const select = el as HTMLSelectElement
    return (
      Array.from(select.options).find((opt) => opt.textContent?.includes(code))
        ?.value ?? ""
    )
  }, M82C_SITE.crateACode)
  await crateSelect.selectOption(crateValue)
  const lotSelect = page.getByLabel("Stock lot")
  const lotValue = await lotSelect.evaluate((el, code) => {
    const select = el as HTMLSelectElement
    return (
      Array.from(select.options).find((opt) => opt.textContent?.includes(code))
        ?.value ?? ""
    )
  }, state.selectedLotCode)
  await lotSelect.selectOption(lotValue)
  await page.getByLabel("Damage reason").fill("Invalid mime probe")
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 30_000,
  })

  await page.getByLabel("Select photo").setInputFiles({
    name: "not-an-image.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("not an image"),
  })
  await expect(
    page.getByRole("alert").filter({ hasText: /Use a JPEG, PNG, or WebP photo/i }),
  ).toBeVisible({ timeout: 10_000 })
  await expect(page.getByRole("button", { name: "Review and submit" })).toBeDisabled()
})

test("store keeper finalizes evidence in browser and submits storage damage", async ({
  page,
}) => {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto("/damage/new")

  const godown = page.locator("#damage-godown")
  await expect(godown.locator(`option:has-text("${M82C_SITE.godownName}")`)).toBeAttached({
    timeout: 15_000,
  })
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

  const productSelect = page.getByLabel("Product")
  const productValue = await productSelect.evaluate((el, sku) => {
    const select = el as HTMLSelectElement
    return (
      Array.from(select.options).find((opt) => opt.textContent?.includes(sku))
        ?.value ?? ""
    )
  }, M82C_CATALOG.stableSku)
  await productSelect.selectOption(productValue)

  const crateSelect = page.getByLabel(/^Crate/)
  const crateValue = await crateSelect.evaluate((el, code) => {
    const select = el as HTMLSelectElement
    return (
      Array.from(select.options).find((opt) => opt.textContent?.includes(code))
        ?.value ?? ""
    )
  }, M82C_SITE.crateACode)
  await crateSelect.selectOption(crateValue)

  const lotSelect = page.getByLabel("Stock lot")
  const lotValue = await lotSelect.evaluate((el, code) => {
    const select = el as HTMLSelectElement
    return (
      Array.from(select.options).find((opt) => opt.textContent?.includes(code))
        ?.value ?? ""
    )
  }, state.selectedLotCode)
  expect(lotValue).not.toEqual("")
  await lotSelect.selectOption(lotValue)
  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill("Packaging Damage")

  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 30_000,
  })
  state.reportNumber =
    ((await page.getByRole("heading").first().textContent()) ?? "")
      .replace(/^Edit\s+/, "")
      .trim()
  expect(state.reportNumber).toMatch(/^DMG-/)

  // Missing evidence keeps submit blocked.
  await expect(page.getByRole("button", { name: "Review and submit" })).toBeDisabled()

  await page.getByLabel("Select photo").setInputFiles({
    name: "dmg03e1.png",
    mimeType: "image/png",
    buffer: png,
  })
  await expect(page.getByAltText("Finalized damage evidence")).toBeVisible({
    timeout: 30_000,
  })
  await expect(page.getByRole("button", { name: "Review and submit" })).toBeEnabled()

  // Prove trusted finalize RPC ran (evidence_attached), not a SQL verified_at stamp.
  const proof = runLocalSql(
    `select
       (select count(*)::text from public.damage_evidence e
        join public.damage_reports r on r.id = e.damage_report_id
        where r.report_number = '${state.reportNumber}'
          and e.verified_at is not null
          and e.mime_type = 'image/png'
          and e.file_size = 70)
       || '|' ||
       (select count(*)::text from public.damage_report_events ev
        join public.damage_reports r on r.id = ev.damage_report_id
        where r.report_number = '${state.reportNumber}'
          and ev.action = 'evidence_attached');`,
    "finalize-proof",
  )
  const [finalized, events] = proof.split("|").map(Number)
  expect(finalized).toBe(1)
  expect(events).toBe(1)

  await page.reload()
  await expect(page.getByAltText("Finalized damage evidence")).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByLabel("Stock lot")).toHaveValue(lotValue)

  await page.getByRole("button", { name: "Review and submit" }).click()
  await page.getByRole("button", { name: "Submit report" }).click()
  await expect(page.getByText("Submitted", { exact: true }).first()).toBeVisible({
    timeout: 30_000,
  })

  const stock = runLocalSql(
    `select
       (select sb.quantity::text
        from public.stock_balances sb
        join public.products p on p.id = sb.product_id
        join public.crates c on c.id = sb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}' and c.code = '${M82C_SITE.crateACode}')
       || '|' ||
       (select app_private.picking_available_cases(sl.id, c.id)::text
          || ':' || app_private.active_damage_hold_lot_cases(sl.id, c.id)::text
        from public.stock_lots sl
        join public.products p on p.id = sl.product_id
        join public.stock_lot_balances slb on slb.lot_id = sl.id
        join public.crates c on c.id = slb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}'
          and c.code = '${M82C_SITE.crateACode}'
          and sl.manufacturer_lot_code = 'TEST-LOT-DMG03F')
       || '|' ||
       (select app_private.active_damage_hold_lot_cases(sl.id, c.id)::text
        from public.stock_lots sl
        join public.products p on p.id = sl.product_id
        join public.stock_lot_balances slb on slb.lot_id = sl.id
        join public.crates c on c.id = slb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}'
          and c.code = '${M82C_SITE.crateACode}'
          and sl.manufacturer_lot_code = 'TEST-LOT-STABLE')
       || '|' ||
       (select coalesce(sum(h.quantity_cases),0)::text
        from public.damage_stock_holds h
        join public.damage_reports r on r.id = h.damage_report_id
        where r.report_number = '${state.reportNumber}' and h.status = 'active')
       || '|' ||
       (select count(*)::text from public.stock_ledger);`,
    "post-submit",
  )
  const [physical, selectedPair, otherHeld, reportHeld, ledger] = stock.split("|")
  const [selectedAvail, selectedHeld] = selectedPair.split(":").map(Number)
  expect(Number(physical)).toBe(state.physicalBefore)
  expect(Number(reportHeld)).toBe(1)
  expect(selectedHeld).toBe(state.selectedHeldBefore + 1)
  expect(selectedAvail).toBe(state.selectedAvailBefore - 1)
  expect(Number(otherHeld)).toBe(state.otherHeldBefore)
  // Isolation holds must not post stock ledger rows.
  expect(Number(ledger)).toBe(state.ledgerCountBefore)

  state.reportId = runLocalSql(
    `select id::text from public.damage_reports where report_number = '${state.reportNumber}';`,
    "report-id",
  )
})

test("duplicate submit and store-keeper self-verify stay blocked", async ({
  page,
}) => {
  expect(state.reportId).toBeTruthy()
  const outcome = runLocalSql(
    `
    do $$
    declare
      v integer;
      holds_before integer;
      holds_after integer;
    begin
      select version into v from public.damage_reports where id = '${state.reportId}'::uuid;
      select coalesce(sum(quantity_cases),0) into holds_before
      from public.damage_stock_holds
      where damage_report_id = '${state.reportId}'::uuid and status = 'active';
      perform set_config('request.jwt.claim.sub',
        (select id::text from auth.users where email = '${M82C_USERS.storeKeeper}'), true);
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', (select id from auth.users where email = '${M82C_USERS.storeKeeper}'),
          'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      begin
        perform public.submit_damage_report('${state.reportId}'::uuid, v, 'dmg03e1-dup-' || gen_random_uuid()::text);
      exception when others then null;
      end;
      select coalesce(sum(quantity_cases),0) into holds_after
      from public.damage_stock_holds
      where damage_report_id = '${state.reportId}'::uuid and status = 'active';
      if holds_after is distinct from holds_before then
        raise exception 'duplicate submit changed holds';
      end if;
    end $$;
    select 'ok';
    `,
    "dup",
  )
  expect(outcome).toContain("ok")

  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto(`/damage/${state.reportId}`)
  await expect(page.getByRole("button", { name: /^Verify$/i })).toHaveCount(0)
})

test("godown manager verifies browser-finalized report", async ({ page }) => {
  await signIn(page, M82C_USERS.godownManager)
  await page.goto(`/damage/${state.reportId}`)
  await expect(page.getByRole("heading", { name: state.reportNumber })).toBeVisible({
    timeout: 20_000,
  })
  await page.getByRole("button", { name: "Verify", exact: true }).click()
  await page.getByLabel("Confirm damage verification").click()
  await expect(page.getByText("Verified", { exact: true }).first()).toBeVisible({
    timeout: 20_000,
  })

  const audit = runLocalSql(
    `select string_agg(action, ',' order by created_at)
     from public.damage_report_events
     where damage_report_id = '${state.reportId}';`,
    "audit",
  )
  expect(audit).toMatch(/evidence_attached/)
  expect(audit).toMatch(/submitted/)
  expect(audit).toMatch(/verified/)
})
