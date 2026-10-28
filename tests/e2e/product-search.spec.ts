import { expect, test, type Page } from "@playwright/test"
import { runLocalSql } from "./disposable-stock"

const password = "local-only-m1s2qa"

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  tailSku: "",
  tailName: "",
}

/**
 * Proves catalog search is not limited to PostgREST's first 1,000 rows.
 * Uses an existing active product at offset 1000; does not post stock.
 */
test.beforeAll(() => {
  const row = runLocalSql(
    `
    select sku || E'\\t' || name
    from public.products
    where is_active
    order by name, sku, id
    offset 1000
    limit 1;
    `,
    "catalog tail product",
  )
  const [sku, name] = row.split("\t")
  if (!sku || !name) {
    throw new Error(
      "local catalog has fewer than 1001 active products; cannot prove search beyond PostgREST max_rows",
    )
  }
  fixture.tailSku = sku
  fixture.tailName = name
})

async function signIn(page: Page) {
  await page.goto("/login")
  await page.getByLabel("Email").fill("admin.m1s2qa@example.com")
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

test("product master search finds a SKU beyond the first 1000 names", async ({ page }) => {
  await signIn(page)
  await page.goto("/masters/products")
  await expect(page.getByRole("heading", { name: "Products" })).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Search name or SKU").fill(fixture.tailSku)
  await expect(page.getByText(fixture.tailSku)).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText(fixture.tailName).first()).toBeVisible()
})

test("opening-stock picker can select a product beyond the first 1000 names", async ({ page }) => {
  await signIn(page)
  await page.goto("/inventory/opening")
  await expect(page.getByRole("heading", { name: "Opening stock" })).toBeVisible({ timeout: 20_000 })
  const label = `${fixture.tailSku} · ${fixture.tailName}`
  await page.getByLabel("Product", { exact: true }).fill(fixture.tailSku)
  await page.getByRole("option", { name: label }).click()
  await expect(page.getByLabel("Product", { exact: true })).toHaveValue(label)
})
