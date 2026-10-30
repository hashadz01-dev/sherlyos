import { expect, test, type Page } from "@playwright/test"
import { localPsqlContainer, runLocalSql } from "./disposable-stock"

const password = "local-only-m81c"
const emails = {
  admin: "admin.m81cqa@example.com",
  godown: "godown.m81cqa@example.com",
  keeper: "keeper.m81cqa@example.com",
  driver: "driver.m81cqa@example.com",
  accounts: "accounts.m81cqa@example.com",
}

test.describe.configure({ mode: "serial", timeout: 90_000 })

test.beforeAll(() => {
  if (localPsqlContainer() === "supabase_db_sherlyos") {
    throw new Error("m81c e2e refused the owner Postgres container")
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

test("isolated stack is not the owner database", async () => {
  const sysid = runLocalSql("select system_identifier from pg_control_system();", "sysid")
  expect(sysid).not.toContain("7699785797738577957")
  const flags = runLocalSql(
    "select value::text from public.app_configuration where key = 'stock.lots.dual_write_enabled';",
    "flags",
  )
  expect(flags).toContain("true")
})

test("admin session reaches masters and opening stock", async ({ page }) => {
  await signIn(page, emails.admin)
  await page.goto("/masters/products")
  await expect(page.getByRole("heading", { name: "Products" })).toBeVisible({ timeout: 20_000 })
  await page.goto("/inventory/opening")
  await expect(page.getByRole("heading", { name: /Opening stock/i })).toBeVisible({
    timeout: 20_000,
  })
})

test("godown manager reaches picking and dispatch", async ({ page }) => {
  await signIn(page, emails.godown)
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/dispatch")
  await expect(page.getByRole("heading", { name: "Dispatch", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("link", { name: "Users & role" })).toHaveCount(0)
})

test("store keeper reaches picking execute and is denied dispatch prepare", async ({ page }) => {
  await signIn(page, emails.keeper)
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/dispatch")
  await expect(page.getByRole("heading", { name: "Dispatch", exact: true })).toHaveCount(0)
  await page.goto("/inventory/opening")
  await expect(page.getByRole("heading", { name: /Opening stock/i })).toHaveCount(0)
})

test("delivery person reaches delivery runs and is denied orders capture", async ({ page }) => {
  await signIn(page, emails.driver)
  await page.goto("/delivery-runs")
  await expect(page.getByRole("heading", { name: "Delivery runs" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/orders")
  await expect(page.getByRole("heading", { name: "Orders" })).toHaveCount(0)
})

test("accounts reaches orders, delivery notes, and non-statutory financial previews", async ({
  page,
}) => {
  await signIn(page, emails.accounts)
  await page.goto("/orders")
  await expect(page.getByRole("heading", { name: "Orders", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/deliveries")
  await expect(page.getByRole("heading", { name: "Delivery notes", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/invoices")
  await expect(page.getByRole("heading", { name: "Invoice notes", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("DRAFT INVOICE NOTE — NOT A TAX INVOICE")).toBeVisible()
  await expect(page.getByRole("button", { name: /finalize|issue tax invoice|allocate/i })).toHaveCount(0)
  await page.goto("/credit-adjustments")
  await expect(page.getByRole("heading", { name: "Credit adjustments" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing", exact: true })).toHaveCount(0)
})

test("admin inventory shows isolated lot stock after HTTP cutover", async ({ page }) => {
  await signIn(page, emails.admin)
  await page.goto("/inventory")
  await expect(page.getByRole("heading", { name: "Inventory", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("cell", { name: "M81C Expiry" }).first()).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("heading", { name: "No stock" })).toHaveCount(0)
})

test("godown manager reaches lot reconciliation and is denied user administration", async ({
  page,
}) => {
  await signIn(page, emails.godown)
  await page.goto("/stock-lot-reconciliation")
  await expect(page.getByRole("heading", { name: "Lot reconciliation", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/users-roles")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible(
    { timeout: 20_000 },
  )
})

test("delivery person is denied opening-stock writes", async ({ page }) => {
  await signIn(page, emails.driver)
  await page.goto("/inventory/opening")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible(
    { timeout: 20_000 },
  )
  await expect(page.getByRole("heading", { name: "Opening stock" })).toHaveCount(0)
})

test("invalid credentials do not create a session on the isolated stack", async ({ page }) => {
  await page.goto("/login")
  await page.getByRole("textbox", { name: "Email" }).fill("ada@example.com")
  await page.getByLabel("Password", { exact: true }).fill("secret")
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("alert")).toContainText("Invalid login credentials", {
    timeout: 20_000,
  })
  await expect(page).toHaveURL(/\/login$/)
})
