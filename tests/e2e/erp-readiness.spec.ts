import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m1s2qa"

test.describe.configure({ mode: "serial", timeout: 90_000 })

async function signIn(page: Page, email = "admin.m1s2qa@example.com") {
  await page.goto("/login")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

test("dashboard stays cutover-inactive and reports remain read-only", async ({ page }) => {
  await signIn(page)
  await expect(
    page.getByText(/Operational lot cutover is inactive/i),
  ).toBeVisible()
  await expect(page.getByText(/available-to-pick stay empty or not applicable/i)).toBeVisible()

  await page.goto("/reports")
  await expect(page.getByRole("heading", { name: "Reports" })).toBeVisible({ timeout: 20_000 })
  await page.goto("/reports/movements")
  await expect(page.getByRole("heading", { name: "Stock movement report" })).toBeVisible()
  await expect(page.getByLabel("Movement type")).toContainText("Dispatch")
  await expect(page.getByLabel("Movement type")).not.toContainText("Delivery return")

  await page.goto("/invoices")
  await expect(page.getByText("DRAFT INVOICE NOTE — NOT A TAX INVOICE")).toBeVisible()
  await page.goto("/credit-adjustments")
  await expect(page.getByText("CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE")).toBeVisible()
  await expect(page.getByRole("button", { name: /issue|finalize|allocate/i })).toHaveCount(0)
})
