import { expect, test, type Page } from "@playwright/test"
import { localPsqlContainer, runLocalSql } from "./disposable-stock"
import { M82C_ISOLATION, M82C_USERS } from "../../src/lib/uat/m82c-manifest"

const password = "local-only-m82c"

test.describe.configure({ mode: "serial", timeout: 90_000 })

test.beforeAll(() => {
  if (localPsqlContainer() !== M82C_ISOLATION.container) {
    throw new Error("m82c e2e refused a non-M82C Postgres container")
  }
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

test("isolated stack is not owner or m81c and dual-write is isolated-only", async () => {
  const sysid = runLocalSql("select system_identifier from pg_control_system();", "sysid")
  expect(sysid).not.toContain(M82C_ISOLATION.forbiddenOwnerSysid)
  expect(sysid).not.toContain(M82C_ISOLATION.forbiddenM81cSysid)
  const flags = runLocalSql(
    `select key || '=' || value::text
     from public.app_configuration
     where key in (
       'stock.lots.dual_write_enabled',
       'stock.lots.aggregate_only_blocked',
       'damage.stock_hold_ready'
     )
     order by 1;`,
    "flags",
  )
  expect(flags).toContain("stock.lots.dual_write_enabled=true")
  expect(flags).toContain("stock.lots.aggregate_only_blocked=false")
  expect(flags).toContain("damage.stock_hold_ready=false")
})

test("scenario E salesperson reaches orders and is denied packing", async ({ page }) => {
  await signIn(page, M82C_USERS.salesperson)
  await page.goto("/orders")
  await expect(page.getByRole("heading", { name: "Orders" })).toBeVisible({ timeout: 20_000 })
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing", exact: true })).toHaveCount(0)
})

test("scenario E store keeper reaches packing and is denied dispatch prepare", async ({ page }) => {
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/dispatch")
  await expect(page.getByRole("heading", { name: "Dispatch", exact: true })).toHaveCount(0)
  await page.goto("/invoices")
  await expect(page.getByRole("heading", { name: "Invoice notes" })).toHaveCount(0)
})

test("scenario E delivery person reaches delivery runs and is denied billing", async ({ page }) => {
  await signIn(page, M82C_USERS.deliveryPerson)
  await page.goto("/delivery-runs")
  await expect(page.getByRole("heading", { name: "Delivery runs" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/invoices")
  await expect(page.getByRole("heading", { name: "Invoice notes" })).toHaveCount(0)
  await page.goto("/orders/new")
  await expect(page.getByRole("heading", { name: "New order" })).toHaveCount(0)
})

test("scenario E accounts reaches orders and is denied packing", async ({ page }) => {
  await signIn(page, M82C_USERS.accounts)
  await page.goto("/orders")
  await expect(page.getByRole("heading", { name: "Orders" })).toBeVisible({ timeout: 20_000 })
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing", exact: true })).toHaveCount(0)
  await page.goto("/inventory/opening")
  await expect(page.getByRole("heading", { name: /Opening stock/i })).toHaveCount(0)
})

test("admin supervisory navigation includes users and opening stock", async ({ page }) => {
  await signIn(page, M82C_USERS.admin)
  await page.goto("/employees")
  await expect(page.getByRole("heading", { name: "Employees" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/inventory/opening")
  await expect(page.getByRole("heading", { name: /Opening stock/i })).toBeVisible({
    timeout: 20_000,
  })
})
