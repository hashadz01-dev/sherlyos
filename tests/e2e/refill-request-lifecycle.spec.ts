import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m62e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m62_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  godownName: `M62 Godown ${RUN}`,
  supplierName: `M62 Brand ${RUN}`,
  productSku: `${PREFIX}_sku`,
  productName: `M62 Soap ${RUN}`,
  requestNumber: "",
}

function runLocalSql(sql: string, label: string) {
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
    { input: sql, encoding: "utf8" },
  )
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || `${label} failed`)
  }
  return result.stdout.trim()
}

async function login(page: Page, email: string) {
  await page.goto("/login")
  await page.getByLabel(/email/i).fill(email)
  await page.getByLabel(/password/i).fill(password)
  await page.getByRole("button", { name: /sign in/i }).click()
  await expect(
    page.getByRole("heading", {
      name: /operations overview|stock refill|refill request/i,
    }),
  ).toBeVisible({ timeout: 20_000 })
}

async function logout(page: Page) {
  await page.getByRole("button", { name: "Account menu" }).click()
  await page.getByRole("menuitem", { name: "Sign out" }).click()
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible({
    timeout: 20_000,
  })
}

test.beforeAll(() => {
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      godown_id uuid;
      branch_id uuid;
      supplier_id uuid;
      product_id uuid;
    begin
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new,
        email_change_token_current, reauthentication_token, email_change
      )
      select
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
        email, extensions.crypt('${password}', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', email),
        now(), now(),
        replace(gen_random_uuid()::text, '-', '') || 'c',
        replace(gen_random_uuid()::text, '-', '') || 'r',
        replace(gen_random_uuid()::text, '-', '') || 'n',
        replace(gen_random_uuid()::text, '-', '') || 'e',
        replace(gen_random_uuid()::text, '-', '') || 'a',
        ''
      from (values
        ('admin.m62e2e@example.com'),
        ('accounts.m62e2e@example.com'),
        ('godown.m62e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m62e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m62e2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m62e2e@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M62 E2E Admin', true),
        (accounts_id, 'M62 E2E Accounts', true),
        (godown_id, 'M62 E2E Godown', true)
      on conflict (id) do update set is_active = true;

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where roles.code = 'admin'
          on conflict do nothing;
      end;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select accounts_id, roles.id, admin_id from public.roles where roles.code = 'accounts'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      branch_id := public.create_branch('m62e2e_${RUN}', '${fixture.godownName}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      supplier_id := public.create_supplier('${fixture.supplierName}', null, null);
      product_id := public.create_product('${fixture.productSku}', '${fixture.productName}', supplier_id, null);
    end $$;
    `,
    "m62 e2e seed",
  )
})

test("godown managers cannot open the refill queue", async ({ page }) => {
  await login(page, "godown.m62e2e@example.com")
  await expect(page.getByRole("link", { name: "Refill", exact: true })).toHaveCount(0)
  await page.goto("/refill")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await logout(page)
})

test("accounts creates and submits a refill request without changing stock", async ({ page }) => {
  const ledgerBefore = runLocalSql(`select count(*) from public.stock_ledger;`, "ledger before")
  await login(page, "accounts.m62e2e@example.com")
  await expect(
    page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Refill" }),
  ).toBeVisible()
  await page.goto("/refill")
  await expect(page.getByRole("heading", { name: "Stock Refill" })).toBeVisible()
  await page.getByRole("link", { name: "New request" }).click()
  await expect(page.getByRole("heading", { name: "New refill request" })).toBeVisible()
  await page.getByLabel("Supplier").selectOption({ label: fixture.supplierName })
  await page.getByLabel("Destination godown").selectOption({
    label: await page
      .getByLabel("Destination godown")
      .locator("option")
      .filter({ hasText: fixture.godownName })
      .first()
      .textContent()
      .then((text) => text?.trim() ?? ""),
  })
  await page.getByLabel("Product line 1").selectOption({
    label: await page
      .getByLabel("Product line 1")
      .locator("option")
      .filter({ hasText: fixture.productSku })
      .first()
      .textContent()
      .then((text) => text?.trim() ?? ""),
  })
  await page.getByLabel("Requested cases line 1").fill("5")
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /^RF-/ })).toBeVisible({ timeout: 20_000 })
  fixture.requestNumber = (await page.getByRole("heading", { name: /^RF-/ }).innerText()).trim()
  await expect(page.getByText(/Admin approval is not a stock receipt/i)).toBeVisible()
  await page.getByRole("button", { name: "Submit to Admin" }).click()
  await expect(page.getByText("Submitted", { exact: true })).toBeVisible({ timeout: 20_000 })
  const ledgerAfter = runLocalSql(`select count(*) from public.stock_ledger;`, "ledger after submit")
  expect(ledgerAfter).toBe(ledgerBefore)
  await logout(page)
})

test("admin approves without receiving stock", async ({ page }) => {
  const ledgerBefore = runLocalSql(`select count(*) from public.stock_ledger;`, "ledger before approve")
  await login(page, "admin.m62e2e@example.com")
  await page.goto("/refill")
  await page.getByRole("link", { name: fixture.requestNumber }).click()
  await expect(page.getByText(/Admin approval is not a stock receipt/i)).toBeVisible()
  await page.getByRole("button", { name: "Approve" }).click()
  await page.getByRole("button", { name: "Confirm refill approval" }).click()
  await expect(page.getByText("Approved", { exact: true })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText("Approved — not a stock receipt")).toBeVisible()
  const status = runLocalSql(
    `select status from public.stock_refill_requests where request_number = '${fixture.requestNumber}';`,
    "approved status",
  )
  expect(status.split(/\r?\n/).filter(Boolean).at(-1)).toBe("approved")
  const ledgerAfter = runLocalSql(`select count(*) from public.stock_ledger;`, "ledger after approve")
  expect(ledgerAfter).toBe(ledgerBefore)
  const flags = runLocalSql(
    `
    select count(*) from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb;
    `,
    "flags",
  )
  expect(flags.split(/\r?\n/).filter(Boolean).at(-1)).toBe("0")
})
