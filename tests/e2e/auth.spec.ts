import { expect, test } from "@playwright/test"

test("unauthenticated visitors stay on the login page", async ({ page }) => {
  await page.goto("/orders")

  await expect(page).toHaveURL(/\/login$/)
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible()
  await expect(page.getByRole("status")).toHaveCount(0)
  await expect(page.getByText("Operations Overview")).toHaveCount(0)
})

test("invalid credentials do not create a session", async ({ page }) => {
  await page.goto("/login")
  await page.getByRole("textbox", { name: "Email" }).fill("ada@example.com")
  await page.getByLabel("Password", { exact: true }).fill("secret")
  await page.getByRole("button", { name: "Sign in" }).click()

  await expect(page.getByRole("alert")).toContainText(
    "Invalid login credentials",
    { timeout: 20_000 },
  )
  await expect(page).toHaveURL(/\/login$/)
  await expect(page.getByText("Operations Overview")).toHaveCount(0)
})

test("the original logo is served from branding", async ({ page }) => {
  const response = await page.request.get("/branding/sherlys-logo.png")

  expect(response.status()).toBe(200)
  expect(response.headers()["content-type"] ?? "").toContain("image/png")

  await page.goto("/login")
  await expect(
    page.getByRole("img", { name: "Sherly's" }).first(),
  ).toBeVisible()
})

test("the login page fits a phone width", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto("/login")

  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible()
  await expect(page.getByRole("button", { name: "Sign in" })).toBeVisible()
})
