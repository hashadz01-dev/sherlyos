import { expect, test, type Page } from "@playwright/test"
import { localPsqlContainer, runLocalSql } from "./disposable-stock"
import { M82C_ISOLATION, M82C_USERS, M82C_SITE, M82C_CATALOG } from "../../src/lib/uat/m82c-manifest"

const password = "local-only-m82c"
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
)

test.describe.configure({ mode: "serial", timeout: 120_000 })

const state = {
  reportNumber: "",
  reportId: "",
  physicalBefore: 0,
  availBefore: 0,
}

test.beforeAll(() => {
  if (localPsqlContainer() !== M82C_ISOLATION.container) {
    throw new Error("DMG-03C refused a non-m82c Postgres container")
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

  // Prefer a lot with free cases (DMG-03F replenishment lot after write-offs).
  const grain = runLocalSql(
    `select sb.quantity::text
        || '|' || coalesce((
          select max(app_private.picking_available_cases(sl.id, sb.crate_id))::text
          from public.stock_lots sl
          join public.stock_lot_balances slb
            on slb.lot_id = sl.id and slb.crate_id = sb.crate_id
          where sl.product_id = sb.product_id
        ), '0')
     from public.stock_balances sb
     join public.products p on p.id = sb.product_id
     join public.crates c on c.id = sb.crate_id
     where p.sku = '${M82C_CATALOG.stableSku}'
       and c.code = '${M82C_SITE.crateACode}';`,
    "grain",
  )
  const [physical, avail] = grain.split("|").map((v) => Number(v))
  // Isolation must not change physical; do not hard-require a fixed 17 after write-offs.
  expect(physical).toBeGreaterThanOrEqual(10)
  expect(avail).toBeGreaterThanOrEqual(1)
  state.physicalBefore = physical
  state.availBefore = avail
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

test("environment is disposable m82c with isolation ready", async ({ page }) => {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto("/damage/new")
  await expect(page.getByRole("heading", { name: /New damage report/i })).toBeVisible({
    timeout: 20_000,
  })
  // Banner should not claim isolation is unavailable when ready.
  await expect(page.getByText(/Damage stock isolation not ready/i)).toHaveCount(0)
})

test("store keeper submits storage damage and stock is isolated", async ({ page }) => {
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
  // Wait until storage source catalogs hydrate products into the line editor.
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

  // DMG-03D: dual-write drafts require a lot chosen in the UI (no SQL repair).
  const lotSelect = page.getByLabel("Stock lot")
  await expect(lotSelect).toBeVisible({ timeout: 15_000 })
  await expect
    .poll(async () => lotSelect.locator("option").count(), { timeout: 15_000 })
    .toBeGreaterThan(1)
  const lotValue = await lotSelect.evaluate((el) => {
    const select = el as HTMLSelectElement
    // Prefer the DMG-03F replenishment lot when present; else first real option.
    const preferred = Array.from(select.options).find((opt) =>
      opt.textContent?.includes("TEST-LOT-DMG03F"),
    )
    const match = preferred ?? Array.from(select.options).find((opt) => opt.value)
    return match?.value ?? ""
  })
  expect(lotValue).not.toEqual("")
  await lotSelect.selectOption(lotValue)

  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill("Packaging Damage")

  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 30_000,
  })
  const heading = (await page.getByRole("heading").first().textContent()) ?? ""
  state.reportNumber = heading.replace(/^Edit\s+/, "").trim()
  expect(state.reportNumber).toMatch(/^DMG-/)

  await page.getByLabel("Select photo").setInputFiles({
    name: "dmg03c.png",
    mimeType: "image/png",
    buffer: png,
  })
  // Browser-only evidence finalize — no SQL stamp permitted for PASS.
  await expect(page.getByAltText("Finalized damage evidence")).toBeVisible({
    timeout: 30_000,
  })
  const submitBtn = page.getByRole("button", { name: "Review and submit" })
  await expect(submitBtn).toBeEnabled({ timeout: 10_000 })
  await page.getByRole("button", { name: "Review and submit" }).click()
  await page.getByRole("button", { name: "Submit report" }).click()

  await expect(page.getByText("Submitted", { exact: true }).first()).toBeVisible({
    timeout: 30_000,
  })

  // Reconcile against the lot actually held by this report (multi-lot fixture safe).
  const stock = runLocalSql(
    `select sb.quantity::text
        || '|' || (
          select coalesce(sum(h.quantity_cases),0)::text
          from public.damage_stock_holds h
          join public.damage_reports r on r.id = h.damage_report_id
          where r.report_number = '${state.reportNumber}'
            and h.status = 'active'
        )
        || '|' || app_private.picking_available_cases(h.lot_id, h.crate_id)::text
        || '|' || app_private.active_damage_hold_lot_cases(h.lot_id, h.crate_id)::text
     from public.stock_balances sb
     join public.products p on p.id = sb.product_id
     join public.crates c on c.id = sb.crate_id
     join public.damage_reports r on r.report_number = '${state.reportNumber}'
     join public.damage_stock_holds h
       on h.damage_report_id = r.id and h.status = 'active'
     where p.sku = '${M82C_CATALOG.stableSku}'
       and c.code = '${M82C_SITE.crateACode}'
     limit 1;`,
    "post-submit-stock",
  )
  const [physical, held, avail, lotHeld] = stock.split("|").map((v) => Number(v))
  expect(physical).toBe(state.physicalBefore)
  expect(held).toBe(1)
  expect(lotHeld).toBeGreaterThanOrEqual(1)
  expect(avail).toBeLessThan(state.availBefore)

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
  // Second submit attempt as reporter with a new key must not add holds
  // (already submitted → cannot be submitted / idempotent path).
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
        perform public.submit_damage_report('${state.reportId}'::uuid, v, 'dmg03c-dup-' || gen_random_uuid()::text);
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

test("store keeper cannot verify own report", async ({ page }) => {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto(`/damage/${state.reportId}`)
  await expect(page.getByRole("button", { name: /^Verify$/i })).toHaveCount(0)
})

test("godown manager verifies without changing holds or physical stock", async ({ page }) => {
  test.setTimeout(90_000)
  if (!state.reportId) {
    // Allow focused re-runs against the latest submitted disposable report.
    const latest = runLocalSql(
      `select id::text || '|' || report_number
       from public.damage_reports
       where scenario = 'storage' and status = 'submitted'
       order by created_at desc
       limit 1;`,
      "latest-submitted",
    )
    const [id, number] = latest.split("|")
    state.reportId = id
    state.reportNumber = number
  }
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
     from public.stock_balances sb
     join public.products p on p.id = sb.product_id
     join public.crates c on c.id = sb.crate_id
     where p.sku = '${M82C_CATALOG.stableSku}'
       and c.code = '${M82C_SITE.crateACode}'
     limit 1;`,
    "post-verify",
  )
  const [physical, held, status] = stock.split("|")
  expect(Number(physical)).toBe(state.physicalBefore)
  expect(Number(held)).toBe(1)
  expect(status).toBe("verified")

  const actors = runLocalSql(
    `select string_agg(e.action || ':' || coalesce(p.full_name,'?'), ',' order by e.created_at)
     from public.damage_report_events e
     left join public.profiles p on p.id = e.actor_id
     where e.damage_report_id = '${state.reportId}';`,
    "events",
  )
  expect(actors.toLowerCase()).toMatch(/submitted:/)
  expect(actors.toLowerCase()).toMatch(/verified:/)
})
