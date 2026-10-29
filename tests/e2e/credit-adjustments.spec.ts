import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m1s2qa"
const driverEmail = "driver.m75d1e2e@example.com"

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

test("credit adjustments stay preview-only and are not GST credit notes", async ({ page }) => {
  await signIn(page)
  await page.goto("/credit-adjustments")
  await expect(page.getByRole("heading", { name: "Credit adjustments" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE")).toBeVisible()
  await expect(page.getByRole("button", { name: /issue|finalize|post credit|allocate/i })).toHaveCount(0)
  await expect(page.getByRole("link", { name: /issue|finalize/i })).toHaveCount(0)
})

test("delivery personnel cannot open credit-adjustment URLs", async ({ page }) => {
  await signIn(page, driverEmail)
  await page.goto("/credit-adjustments")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await page.goto("/credit-adjustments/00000000-0000-4000-8000-000000000001")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
})
