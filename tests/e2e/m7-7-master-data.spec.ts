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

test("categories, suppliers, and catalogue products are searchable", async ({ page }) => {
  await signIn(page)

  await page.goto("/masters/categories")
  await expect(page.getByRole("heading", { name: "Categories" })).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Search categories").fill("Tea & Tea Bags")
  await expect(page.getByText("Tea & Tea Bags")).toBeVisible()

  await page.goto("/masters/suppliers")
  await expect(page.getByRole("heading", { name: "Suppliers" })).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Search suppliers").fill("AVT (pending invoicing confirmation)")
  const pendingSupplier = page
    .getByRole("listitem")
    .filter({ hasText: "AVT (pending invoicing confirmation)" })
  await expect(pendingSupplier).toBeVisible()
  // Status <option> also says Inactive; assert the row badge, not the filter.
  await expect(pendingSupplier.getByText("Inactive", { exact: true })).toBeVisible()

  await page.goto("/masters/products")
  await expect(page.getByRole("heading", { name: "Products" })).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Search name or SKU").fill("AVT-PREM-DUST-100G")
  const catalogueProduct = page.getByRole("listitem").filter({ hasText: "AVT-PREM-DUST-100G" })
  await expect(catalogueProduct).toBeVisible({ timeout: 20_000 })
  await expect(catalogueProduct.getByText("AVT Premium Tea Dust 100g", { exact: true })).toBeVisible()
  await expect(catalogueProduct.getByText(/Tea & Tea Bags/)).toBeVisible()
})
