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

test("vehicle master lists the shared fleet and keeps Bolero inactive", async ({ page }) => {
  await signIn(page)

  await page.goto("/masters/vehicles")
  await expect(page.getByRole("heading", { name: "Vehicles", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("Shared delivery fleet")).toBeVisible()
  await page.getByLabel("Search vehicles").fill("KL-43-F-948")
  await expect(page.getByRole("listitem").filter({ hasText: "Benz (B)" })).toBeVisible()
  await expect(page.getByRole("listitem").filter({ hasText: "KL-43-F-948" })).toBeVisible()
  await page.getByLabel("Search vehicles").fill("Bolero")
  await expect(page.getByRole("listitem").filter({ hasText: "KL-43-R-6725" })).toBeVisible()
  await expect(
    page.getByRole("listitem").filter({ hasText: "KL-43-R-6725" }).getByText("Inactive"),
  ).toBeVisible()
})
