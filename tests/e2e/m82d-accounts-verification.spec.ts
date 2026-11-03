import { expect, test, type Page } from "@playwright/test"
import { runLocalSql } from "./disposable-stock.ts"

const password = "local-only-m82d"
const RUN = Date.now().toString(36)
const PREFIX = `m82d_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  shopName: `M82D Shop ${RUN}`,
  productLabel: "",
  godownName: `M82D Godown ${RUN}`,
  orderNumber: "",
  emails: {
    admin: `admin.${PREFIX}@example.com`,
    accounts: `accounts.${PREFIX}@example.com`,
    accountsNone: `accounts.none.${PREFIX}@example.com`,
    sales: `sales.${PREFIX}@example.com`,
  },
}

async function login(page: Page, email: string) {
  await page.goto("/login")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

async function logout(page: Page) {
  await page.getByRole("button", { name: "Account menu" }).click()
  await page.getByRole("menuitem", { name: "Sign out" }).click()
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible({ timeout: 20_000 })
}

test.beforeAll(() => {
  const sku = `${PREFIX}_sku`
  fixture.productLabel = `${sku} · M82D milk ${RUN}`
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      accounts_none_id uuid;
      salesperson_id uuid;
      branch_id uuid;
      product_id uuid;
      shop_id uuid;
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
        ('${fixture.emails.admin}'),
        ('${fixture.emails.accounts}'),
        ('${fixture.emails.accountsNone}'),
        ('${fixture.emails.sales}')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = '${fixture.emails.admin}';
      select id into accounts_id from auth.users where email = '${fixture.emails.accounts}';
      select id into accounts_none_id from auth.users where email = '${fixture.emails.accountsNone}';
      select id into salesperson_id from auth.users where email = '${fixture.emails.sales}';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M82D Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M82D Admin', true),
        (accounts_id, 'M82D Accounts', true),
        (accounts_none_id, 'M82D Accounts None', true),
        (salesperson_id, 'M82D Sales', true)
      on conflict (id) do update set is_active = true, full_name = excluded.full_name;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values
        (admin_id, 'admin'),
        (accounts_id, 'accounts'),
        (accounts_none_id, 'accounts'),
        (salesperson_id, 'salesperson')
      ) u(id, code)
      join public.roles r on r.code = u.code
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      execute 'set local role authenticated';

      branch_id := public.create_branch('${PREFIX}', '${fixture.godownName}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(salesperson_id, branch_id);
      product_id := public.create_product('${sku}', 'M82D milk ${RUN}', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      shop_id := public.create_shop('${fixture.shopName}', null, null);
      perform public.assign_shop_salesperson(shop_id, salesperson_id);
    end;
    $$;
    `,
    "m82d fixtures",
  )
})

test("salesperson submits an order", async ({ page }) => {
  await login(page, fixture.emails.sales)
  await expect(page.getByRole("link", { name: "Order verification", exact: true })).toHaveCount(0)
  await page.goto("/orders/verification")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/orders/new")
  await expect(page.getByRole("heading", { name: "New order" })).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Shop").selectOption({ label: fixture.shopName })
  await page.getByLabel("Fulfilling godown").selectOption({ label: fixture.godownName })
  const sku = fixture.productLabel.split(" · ")[0]
  await page.getByLabel("Product", { exact: true }).click()
  await page.getByLabel("Product", { exact: true }).fill(sku)
  await page.getByRole("option", { name: fixture.productLabel }).click()
  await page.getByLabel("Cases").fill("2")
  await page.getByRole("button", { name: "Create draft" }).click()
  await expect(page).toHaveURL(/\/orders\/[0-9a-f-]{36}/i, { timeout: 20_000 })
  await page.getByRole("button", { name: "Submit order" }).click()
  await expect(page.getByText("Submitted / Awaiting Verification").first()).toBeVisible({
    timeout: 20_000,
  })
  fixture.orderNumber = (await page.locator("h1").innerText()).trim()
  await logout(page)
})

test("unassigned Accounts sees submitted salesperson orders and not Admin screens", async ({ page }) => {
  await login(page, fixture.emails.accountsNone)
  await expect(page.getByRole("link", { name: "Order verification", exact: true })).toBeVisible()
  await expect(page.getByRole("link", { name: "Employees" })).toHaveCount(0)
  await expect(page.getByText(/You are not assigned to Godown-1/i)).toHaveCount(0)

  await page.goto("/orders/verification")
  await expect(page.getByRole("heading", { name: "Order verification" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("link", { name: new RegExp(fixture.shopName) })).toBeVisible({
    timeout: 20_000,
  })
  if (fixture.orderNumber) {
    await expect(page.getByText(fixture.orderNumber, { exact: true })).toBeVisible()
  }

  await page.goto("/employees")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing", exact: true })).toHaveCount(0)
  await logout(page)
})

test("assigned Accounts opens the submitted order and stays blocked by stock", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto("/orders/verification")
  await expect(page.getByRole("heading", { name: "Order verification" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("link", { name: new RegExp(fixture.shopName) })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("link", { name: "New order" })).toHaveCount(0)
  await page.getByRole("link", { name: new RegExp(fixture.shopName) }).click()
  await expect(page).toHaveURL(/\/orders\/verification\/[0-9a-f-]{36}/i)
  await expect(page.getByRole("heading", { name: "Packing-eligible availability" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("Blocked by Stock", { exact: true })).toBeVisible()
  await expect(page.getByText(/Lot-aware packing is not operational/i).first()).toBeVisible()
  await page.getByRole("button", { name: "Verify order" }).click()
  await expect(page.getByRole("alert")).toContainText(/insufficient packing-eligible stock/i)
  await expect(page.getByText("Submitted / Awaiting Verification").first()).toBeVisible()
  await expect(page.getByText("Verified", { exact: true })).toHaveCount(0)
  await logout(page)
})
