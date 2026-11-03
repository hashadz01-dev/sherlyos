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
  // Fresh replenishment lot from DMG-03F recovery (has free cases after write-offs).
  selectedLotCode: "TEST-LOT-DMG03F",
  otherLotCode: "TEST-LOT-STABLE",
  physicalBefore: 0,
  selectedAvailBefore: 0,
  otherHeldBefore: 0,
  selectedHeldBefore: 0,
}

test.beforeAll(() => {
  if (localPsqlContainer() !== M82C_ISOLATION.container) {
    throw new Error("DMG-03D refused a non-m82c Postgres container")
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
     where key in (
       'damage.stock_hold_ready',
       'stock.lots.dual_write_enabled',
       'stock.lots.aggregate_only_blocked'
     )
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
       (select count(*)::text
        from public.stock_lot_balances slb
        join public.stock_lots sl on sl.id = slb.lot_id
        join public.products p on p.id = sl.product_id
        join public.crates c on c.id = slb.crate_id
        where p.sku = '${M82C_CATALOG.stableSku}'
          and c.code = '${M82C_SITE.crateACode}'
          and slb.quantity > 0)
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
          and sl.manufacturer_lot_code = 'TEST-LOT-STABLE');`,
    "two-lot-grain",
  )
  const [physical, lotCount, selectedPair, otherHeld] = grain.split("|")
  const [selectedAvail, selectedHeld] = selectedPair.split(":").map(Number)
  expect(Number(physical)).toBeGreaterThanOrEqual(10)
  expect(Number(lotCount)).toBeGreaterThanOrEqual(2)
  expect(selectedAvail).toBeGreaterThanOrEqual(1)
  state.physicalBefore = Number(physical)
  state.selectedAvailBefore = selectedAvail
  state.selectedHeldBefore = selectedHeld
  state.otherHeldBefore = Number(otherHeld)
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

test("environment is disposable m82c with lot-aware isolation ready", async ({
  page,
}) => {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto("/damage/new")
  await expect(page.getByRole("heading", { name: /New damage report/i })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(/Damage stock isolation not ready/i)).toHaveCount(0)
})

test("store keeper selects lot in UI and submits storage damage", async ({
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
  await expect(page.getByText(/Authorized godown crates/i)).toBeVisible({
    timeout: 15_000,
  })

  await expect
    .poll(async () => {
      await page.getByRole("button", { name: "Add line" }).click()
      const productSelect = page.getByLabel("Product")
      const count = await productSelect.locator("option").count()
      if (count <= 1) {
        await page.getByRole("button", { name: "Remove" }).click()
      }
      return count
    }, { timeout: 20_000 })
    .toBeGreaterThan(1)

  const productSelect = page.getByLabel("Product")
  const productValue = await productSelect.evaluate((el, sku) => {
    const select = el as HTMLSelectElement
    const match = Array.from(select.options).find((opt) =>
      opt.textContent?.includes(sku),
    )
    return match?.value ?? ""
  }, M82C_CATALOG.stableSku)
  expect(productValue).not.toEqual("")
  await productSelect.selectOption(productValue)

  const crateSelect = page.getByLabel(/^Crate/)
  const crateValue = await crateSelect.evaluate((el, code) => {
    const select = el as HTMLSelectElement
    const match = Array.from(select.options).find((opt) =>
      opt.textContent?.includes(code),
    )
    return match?.value ?? ""
  }, M82C_SITE.crateACode)
  expect(crateValue).not.toEqual("")
  await crateSelect.selectOption(crateValue)

  // Lot selector must appear from catalogs — no SQL lot attribution allowed.
  const lotSelect = page.getByLabel("Stock lot")
  await expect(lotSelect).toBeVisible({ timeout: 15_000 })
  await expect
    .poll(async () => lotSelect.locator("option").count(), { timeout: 15_000 })
    .toBeGreaterThan(1)

  const lotValue = await lotSelect.evaluate((el, code) => {
    const select = el as HTMLSelectElement
    const match = Array.from(select.options).find((opt) =>
      opt.textContent?.includes(code),
    )
    return match?.value ?? ""
  }, state.selectedLotCode)
  expect(lotValue).not.toEqual("")
  await lotSelect.selectOption(lotValue)

  await expect(page.getByText(/Lot physical/i)).toBeVisible()

  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill("Packaging Damage")

  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 30_000,
  })
  const heading = (await page.getByRole("heading").first().textContent()) ?? ""
  state.reportNumber = heading.replace(/^Edit\s+/, "").trim()
  expect(state.reportNumber).toMatch(/^DMG-/)

  // Reload must keep the browser-selected lot — inspect without repairing.
  await page.reload()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByLabel("Stock lot")).toHaveValue(lotValue)

  const persistedLot = runLocalSql(
    `select coalesce(sl.manufacturer_lot_code, 'missing')
     from public.damage_report_lines lines
     join public.damage_reports reports on reports.id = lines.damage_report_id
     left join public.stock_lots sl on sl.id = lines.lot_id
     where reports.report_number = '${state.reportNumber}';`,
    "persisted-lot",
  )
  expect(persistedLot).toBe(state.selectedLotCode)

  await page.getByLabel("Select photo").setInputFiles({
    name: "dmg03d.png",
    mimeType: "image/png",
    buffer: png,
  })
  // Browser-only finalize through create + storage upload + finalize RPC.
  // SQL evidence repair is forbidden for DMG-03E.1 PASS.
  await expect(page.getByAltText("Finalized damage evidence")).toBeVisible({
    timeout: 30_000,
  })
  const submitBtn = page.getByRole("button", { name: "Review and submit" })
  await expect(submitBtn).toBeEnabled({ timeout: 10_000 })

  const evidenceProof = runLocalSql(
    `select
       (select count(*)::text from public.damage_evidence e
        join public.damage_reports r on r.id = e.damage_report_id
        where r.report_number = '${state.reportNumber}' and e.verified_at is not null)
       || '|' ||
       (select count(*)::text from public.damage_report_events ev
        join public.damage_reports r on r.id = ev.damage_report_id
        where r.report_number = '${state.reportNumber}' and ev.action = 'evidence_attached');`,
    "browser-evidence-proof",
  )
  const [finalizedCount, attachedEvents] = evidenceProof.split("|").map(Number)
  expect(finalizedCount).toBeGreaterThanOrEqual(1)
  expect(attachedEvents).toBeGreaterThanOrEqual(1)

  await page.reload()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByLabel("Stock lot")).toHaveValue(lotValue)
  await expect(page.getByAltText("Finalized damage evidence")).toBeVisible({
    timeout: 15_000,
  })
  await expect(submitBtn).toBeEnabled()

  await page.getByRole("button", { name: "Review and submit" }).click()
  await expect(page.getByText(/lot /i).first()).toBeVisible()
  await page.getByRole("button", { name: "Submit report" }).click()

  await expect(page.getByText("Submitted", { exact: true }).first()).toBeVisible({
    timeout: 30_000,
  })
  await expect(page.getByText(/isolated from picking/i)).toBeVisible({
    timeout: 10_000,
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
       (select sl.manufacturer_lot_code
        from public.damage_stock_holds h
        join public.damage_reports r on r.id = h.damage_report_id
        join public.stock_lots sl on sl.id = h.lot_id
        where r.report_number = '${state.reportNumber}' and h.status = 'active'
        limit 1);`,
    "post-submit-stock",
  )
  const [physical, selectedPair, otherHeld, reportHeld, holdLot] = stock.split("|")
  const [selectedAvail, selectedHeld] = selectedPair.split(":").map(Number)
  expect(Number(physical)).toBe(state.physicalBefore)
  expect(Number(reportHeld)).toBe(1)
  expect(holdLot).toBe(state.selectedLotCode)
  expect(selectedHeld).toBe(state.selectedHeldBefore + 1)
  expect(selectedAvail).toBe(state.selectedAvailBefore - 1)
  expect(Number(otherHeld)).toBe(state.otherHeldBefore)

  state.reportId = runLocalSql(
    `select id::text from public.damage_reports where report_number = '${state.reportNumber}';`,
    "report-id",
  )
})

test("duplicate submit does not create a second hold", async () => {
  expect(state.reportId).toBeTruthy()
  const held = Number(
    runLocalSql(
      `select coalesce(sum(quantity_cases),0)::text from public.damage_stock_holds
       where damage_report_id = '${state.reportId}' and status = 'active';`,
      "held-count",
    ),
  )
  expect(held).toBe(1)
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
        perform public.submit_damage_report('${state.reportId}'::uuid, v, 'dmg03d-dup-' || gen_random_uuid()::text);
      exception
        when others then null;
      end;
      select coalesce(sum(quantity_cases),0) into holds_after
      from public.damage_stock_holds
      where damage_report_id = '${state.reportId}'::uuid and status = 'active';
      if holds_after is distinct from holds_before then
        raise exception 'duplicate submit changed holds % -> %', holds_before, holds_after;
      end if;
    end $$;
    select 'ok';
    `,
    "dup-attempt",
  )
  expect(outcome).toContain("ok")
})

test("missing lot is rejected by trusted draft RPC", async () => {
  const outcome = runLocalSql(
    `
    do $$
    declare
      godown uuid;
      product uuid;
      crate uuid;
      msg text;
    begin
      select z.branch_id, p.id, c.id into godown, product, crate
      from public.products p
      join public.stock_balances sb on sb.product_id = p.id
      join public.crates c on c.id = sb.crate_id
      join public.zones z on z.id = c.zone_id
      where p.sku = '${M82C_CATALOG.stableSku}' and c.code = '${M82C_SITE.crateACode}'
      limit 1;
      perform set_config('request.jwt.claim.sub',
        (select id::text from auth.users where email = '${M82C_USERS.storeKeeper}'), true);
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', (select id from auth.users where email = '${M82C_USERS.storeKeeper}'),
          'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      begin
        perform public.create_damage_report(
          'storage',
          godown,
          jsonb_build_array(jsonb_build_object(
            'product_id', product,
            'crate_id', crate,
            'quantity_cases', 1,
            'damage_reason', 'Missing lot negative'
          )),
          'dmg03d-missing-lot-' || gen_random_uuid()::text,
          'negative missing lot'
        );
        raise exception 'missing lot was accepted';
      exception
        when others then
          get stacked diagnostics msg = message_text;
          if msg not ilike '%requires a lot%' and msg not ilike '%stock lot%' then
            raise exception 'unexpected missing-lot error: %', msg;
          end if;
      end;
    end $$;
    select 'ok';
    `,
    "missing-lot",
  )
  expect(outcome).toContain("ok")
})

test("store keeper cannot verify own report", async ({ page }) => {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto(`/damage/${state.reportId}`)
  await expect(page.getByRole("button", { name: /^Verify$/i })).toHaveCount(0)
})

test("godown manager verifies without changing holds or physical stock", async ({
  page,
}) => {
  test.setTimeout(90_000)
  expect(state.reportId).toBeTruthy()

  await signIn(page, M82C_USERS.godownManager)
  await page.goto(`/damage/${state.reportId}`)
  await expect(
    page.getByRole("heading", { name: state.reportNumber }),
  ).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText(/eligible for Godown Manager verification/i)).toBeVisible()
  const verifyOpen = page.getByRole("button", { name: "Verify", exact: true })
  await expect(verifyOpen).toBeEnabled()
  await verifyOpen.click()
  await expect(
    page.getByRole("heading", { name: "Verify damage report" }),
  ).toBeVisible({ timeout: 10_000 })
  await page.getByLabel("Confirm damage verification").click()
  await expect(page.getByText("Verified", { exact: true }).first()).toBeVisible({
    timeout: 20_000,
  })

  const stock = runLocalSql(
    `select sb.quantity::text
        || '|' || (
          select coalesce(sum(h.quantity_cases),0)::text
          from public.damage_stock_holds h
          where h.damage_report_id = '${state.reportId}' and h.status = 'active'
        )
        || '|' || (select status from public.damage_reports where id = '${state.reportId}')
        || '|' || (
          select sl.manufacturer_lot_code
          from public.damage_stock_holds h
          join public.stock_lots sl on sl.id = h.lot_id
          where h.damage_report_id = '${state.reportId}' and h.status = 'active'
          limit 1
        )
     from public.stock_balances sb
     join public.products p on p.id = sb.product_id
     join public.crates c on c.id = sb.crate_id
     where p.sku = '${M82C_CATALOG.stableSku}'
       and c.code = '${M82C_SITE.crateACode}'
     limit 1;`,
    "post-verify",
  )
  const [physical, held, status, holdLot] = stock.split("|")
  expect(Number(physical)).toBe(state.physicalBefore)
  expect(Number(held)).toBe(1)
  expect(status).toBe("verified")
  expect(holdLot).toBe(state.selectedLotCode)
})
