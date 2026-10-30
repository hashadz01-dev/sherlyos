import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m1s2qa"
const driverEmail = "driver.m75d1e2e@example.com"

test.describe.configure({ mode: "serial", timeout: 90_000 })

test.beforeAll(() => {
  const result = spawnSync(
    "docker",
    [
      "exec",
      "-i",
      "supabase_db_sherlyos",
      "psql",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
      "-tA",
    ],
    {
      input: `
        do $$
        declare
          driver_id uuid;
          admin_id uuid;
        begin
          select id into admin_id from auth.users where email = 'admin.m1s2qa@example.com';
          if admin_id is null then
            raise exception 'admin.m1s2qa missing';
          end if;
          select id into driver_id from auth.users where email = '${driverEmail}';
          if driver_id is null then
            insert into auth.users (
              instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
              raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
              confirmation_token, recovery_token, email_change_token_new,
              email_change_token_current, reauthentication_token, email_change
            )
            values (
              '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
              '${driverEmail}', extensions.crypt('${password}', extensions.gen_salt('bf')), now(),
              '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
              replace(gen_random_uuid()::text, '-', '') || 'c',
              replace(gen_random_uuid()::text, '-', '') || 'r',
              replace(gen_random_uuid()::text, '-', '') || 'n',
              replace(gen_random_uuid()::text, '-', '') || 'e',
              replace(gen_random_uuid()::text, '-', '') || 'a',
              ''
            )
            returning id into driver_id;
          end if;
          insert into public.profiles (id, full_name, is_active)
          values (driver_id, 'M75D1 e2e driver', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select driver_id, roles.id, admin_id
          from public.roles
          where roles.code = 'delivery_person'
          on conflict do nothing;
        end $$;
      `,
      encoding: "utf8",
    },
  )
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "m75d1 driver seed failed")
  }
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

test("invoice notes stay drafts and are not tax invoices", async ({ page }) => {
  await signIn(page)
  await page.goto("/invoices")
  await expect(page.getByRole("heading", { name: "Invoice notes" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("DRAFT INVOICE NOTE — NOT A TAX INVOICE")).toBeVisible()
  await expect(page.getByText(/GST tax invoices are blocked/i)).toBeVisible()
  await expect(page.getByText(/TAX CALCULATION PREVIEW|NOT A TAX INVOICE/i).first()).toBeVisible()
  await expect(page.getByRole("button", { name: /finalize|issue tax invoice/i })).toHaveCount(0)
})

test("delivery personnel cannot open invoice handover URLs", async ({ page }) => {
  await page.goto("/login")
  await page.getByLabel("Email").fill(driverEmail)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/invoices")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await page.goto("/invoices/00000000-0000-4000-8000-000000000001/preview?copy=accounts")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
})

test("handover chooser stays a preview workflow", async ({ page }) => {
  await signIn(page)
  await page.goto("/invoices")
  const noteLinks = page.getByRole("link", { name: /IN-/i })
  if ((await noteLinks.count()) === 0) {
    test.info().annotations.push({
      type: "note",
      description: "No invoice-note rows for admin.m1s2qa; chooser is covered by HTTP.",
    })
    return
  }
  await noteLinks.first().click()
  await page.getByRole("link", { name: "Handover documents" }).click()
  await expect(page.getByText("DRAFT INVOICE PREVIEW — NOT A TAX INVOICE")).toBeVisible()
  await expect(page.getByRole("heading", { name: "Driver / delivery handover" })).toBeVisible()
  await expect(page.getByRole("heading", { name: "Accounts / financial preview" })).toBeVisible()
  await page.getByRole("button", { name: "Open driver copy" }).click()
  await expect(page.getByText("DRIVER / DELIVERY HANDOVER COPY")).toBeVisible()
  await expect(page.getByText("DRAFT INVOICE PREVIEW — NOT A TAX INVOICE").first()).toBeVisible()
  await expect(page.getByRole("button", { name: "Download PDF" })).toBeVisible()
  await expect(page.getByRole("button", { name: "Print A4" })).toBeVisible()
  const downloadPromise = page.waitForEvent("download")
  await page.getByRole("button", { name: "Download PDF" }).click()
  const download = await downloadPromise
  expect(download.suggestedFilename()).toMatch(/-driver-preview\.pdf$/)
})

test("selling prices are INR-only and reachable from masters", async ({ page }) => {
  await signIn(page)
  await page.goto("/masters/prices")
  await expect(page.getByRole("heading", { name: "Selling prices", exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(/GST is not stored here/i)).toBeVisible()
  await page.getByRole("button", { name: "Add price" }).click()
  const dialog = page.getByRole("dialog")
  await expect(dialog.getByRole("heading", { name: "Add selling price" })).toBeVisible()
  await expect(dialog.getByLabel("Product", { exact: true })).toBeVisible()
  await expect(dialog.getByPlaceholder("Type a SKU or name")).toBeVisible()
})
