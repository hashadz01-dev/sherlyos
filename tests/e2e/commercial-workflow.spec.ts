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
          values (driver_id, 'M75F e2e driver', true)
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
    throw new Error(result.stderr || result.stdout || "m75f driver seed failed")
  }
})

async function signIn(page: Page, email = "admin.m1s2qa@example.com") {
  await page.goto("/login")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

test("invoice notes and credit adjustments stay non-statutory across the commercial workflow", async ({
  page,
}) => {
  await signIn(page)

  await page.goto("/invoices")
  await expect(page.getByRole("heading", { name: "Invoice notes" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("DRAFT INVOICE NOTE — NOT A TAX INVOICE")).toBeVisible()
  await expect(page.getByRole("button", { name: /finalize|issue tax invoice|allocate/i })).toHaveCount(0)

  const noteLinks = page.getByRole("link", { name: /IN-/i })
  if ((await noteLinks.count()) > 0) {
    await noteLinks.first().click()
    await expect(page.getByText(/DRAFT INVOICE NOTE — NOT A TAX INVOICE/i).first()).toBeVisible()
    await expect(page.getByRole("button", { name: /finalize|issue tax invoice/i })).toHaveCount(0)
    await page.getByRole("link", { name: "Handover documents" }).click()
    await expect(page.getByText("DRAFT INVOICE PREVIEW — NOT A TAX INVOICE")).toBeVisible()
    await expect(page.getByRole("heading", { name: "Driver / delivery handover" })).toBeVisible()
    await expect(page.getByRole("heading", { name: "Accounts / financial preview" })).toBeVisible()
  }

  await page.goto("/credit-adjustments")
  await expect(page.getByRole("heading", { name: "Credit adjustments" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE")).toBeVisible()
  await expect(page.getByRole("button", { name: /issue|finalize|post credit|allocate/i })).toHaveCount(0)
  await expect(page.getByRole("link", { name: /issue|finalize/i })).toHaveCount(0)
})

test("delivery personnel cannot open invoice or credit-adjustment URLs", async ({ page }) => {
  await signIn(page, driverEmail)
  await page.goto("/invoices")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await page.goto("/credit-adjustments")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
})
