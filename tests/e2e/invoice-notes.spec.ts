import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m1s2qa"

test.describe.configure({ mode: "serial", timeout: 90_000 })

async function signIn(page: Page) {
  await page.goto("/login")
  await page.getByLabel("Email").fill("admin.m1s2qa@example.com")
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

test("invoice notes stay drafts and are not tax invoices", async ({ page }) => {
  await signIn(page)
  await page.goto("/invoices")
  await expect(page.getByRole("heading", { name: "Invoice notes" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("DRAFT INVOICE NOTE — NOT A TAX INVOICE")).toBeVisible()
  await expect(page.getByText(/GST tax invoices are blocked/i)).toBeVisible()
})

test("selling prices are INR-only and reachable from masters", async ({ page }) => {
  await signIn(page)
  await page.goto("/masters/prices")
  await expect(page.getByRole("heading", { name: "Selling prices", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(/GST is not stored here/i)).toBeVisible()
})
