import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m1s2qa"

test.describe.configure({ timeout: 90_000 })

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
          admin_id uuid;
        begin
          insert into auth.users (
            instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
            confirmation_token, recovery_token, email_change_token_new,
            email_change_token_current, reauthentication_token, email_change
          )
          select
            '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
            'admin.m1s2qa@example.com', extensions.crypt('${password}', extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', 'QA Admin'),
            now(), now(),
            replace(gen_random_uuid()::text, '-', '') || 'c',
            replace(gen_random_uuid()::text, '-', '') || 'r',
            replace(gen_random_uuid()::text, '-', '') || 'n',
            replace(gen_random_uuid()::text, '-', '') || 'e',
            replace(gen_random_uuid()::text, '-', '') || 'a',
            ''
          where not exists (
            select 1 from auth.users where email = 'admin.m1s2qa@example.com'
          );

          update auth.users
          set
            encrypted_password = extensions.crypt('${password}', extensions.gen_salt('bf')),
            email_confirmed_at = coalesce(email_confirmed_at, now())
          where email = 'admin.m1s2qa@example.com';

          select id into admin_id from auth.users where email = 'admin.m1s2qa@example.com';

          begin
            perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
          exception
            when sqlstate '42501' then
              insert into public.profiles (id, full_name, is_active)
              values (admin_id, 'QA Admin', true)
              on conflict (id) do update set is_active = true;
              insert into public.user_roles (user_id, role_id, assigned_by)
              select admin_id, roles.id, admin_id from public.roles where code = 'admin'
              on conflict do nothing;
          end;
        end $$;
      `,
      encoding: "utf8",
    },
  )
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "local QA admin seed failed")
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

test("shop detail opens with a statement that does not invent payments", async ({ page }) => {
  await signIn(page)
  await page.goto("/masters/shops")
  await expect(page.getByRole("heading", { name: "Shops" })).toBeVisible({ timeout: 20_000 })

  const shopLink = page.locator("a[href^='/masters/shops/']").first()
  await expect(shopLink).toBeVisible()
  await shopLink.click()

  await expect(page.getByRole("navigation", { name: "Shop sections" })).toBeVisible()
  await expect(page.getByRole("button", { name: "Overview" })).toBeVisible()
  await expect(page.getByRole("button", { name: "Sales Statement" })).toBeVisible()

  await page.getByRole("button", { name: "Sales Statement" }).click()
  await expect(
    page.getByText(/SALES STATEMENT PREVIEW — NOT A TAX LEDGER — PAYMENTS NOT POSTED/),
  ).toBeVisible()
  await expect(page.getByText("Cash received").first()).toBeVisible()
  await expect(page.getByText("Unavailable").first()).toBeVisible()
  await expect(page.getByText("Outstanding", { exact: true })).toBeVisible()

  await page.getByRole("button", { name: "Payments" }).click()
  await expect(page.getByRole("heading", { name: "Payments are not posted" })).toBeVisible()
})
