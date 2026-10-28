import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m1s2qa"

async function signIn(page: Page, email: string) {
  await page.goto("/login")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

test("statutory workspace is configuration-only for admin", async ({ page }) => {
  await signIn(page, "admin.m1s2qa@example.com")
  await page.goto("/statutory")
  await expect(page.getByRole("heading", { name: "Statutory configuration" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("CONFIGURATION ONLY — TAX INVOICE ISSUANCE DISABLED")).toBeVisible()
  await expect(page.getByText(/ready=false/i)).toBeVisible()
  await expect(
    page.getByText(
      /Tax invoice issuance stays disabled|Issuance stays disabled|cannot enable finalization|Legal numbering allocation stays disabled/i,
    ),
  ).toBeVisible()
  await expect(page.getByRole("button", { name: /finalize|issue tax invoice|allocate/i })).toHaveCount(0)
})

test("godown manager cannot open statutory configuration", async ({ page }) => {
  await signIn(page, "godown.m1s2qa@example.com")
  await page.goto("/statutory")
  await expect(page.getByText("You do not have access to this page")).toBeVisible({
    timeout: 20_000,
  })
})
