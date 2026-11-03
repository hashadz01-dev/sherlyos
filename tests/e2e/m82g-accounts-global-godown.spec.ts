import { expect, test, type Page } from "@playwright/test"
import { runLocalSql } from "./disposable-stock.ts"

const password = "local-only-m82g"
const RUN = Date.now().toString(36)
const PREFIX = `m82g_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  shopName: `M82G Shop ${RUN}`,
  godownName: `M82G Godown ${RUN}`,
  orderNumber: "",
  orderId: "",
  emails: {
    admin: `admin.${PREFIX}@example.com`,
    accounts: `accounts.${PREFIX}@example.com`,
    accountsNone: `accounts.none.${PREFIX}@example.com`,
    sales: `sales.${PREFIX}@example.com`,
  },
}

function lastLine(text: string) {
  return text.split(/\r?\n/).filter(Boolean).at(-1) ?? ""
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
          values (admin_id, 'M82G Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M82G Admin', true),
        (accounts_id, 'M82G Accounts Assigned ${RUN}', true),
        (accounts_none_id, 'M82G Accounts None ${RUN}', true),
        (salesperson_id, 'M82G Sales', true)
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
      product_id := public.create_product('${PREFIX}_sku', 'M82G milk ${RUN}', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      shop_id := public.create_shop('${fixture.shopName}', null, null);
      perform public.assign_shop_salesperson(shop_id, salesperson_id);
      reset role;

      insert into public.orders (
        order_number, shop_id, branch_id, source, created_by, status, version,
        idempotency_key, submitted_at, submitted_by, verified_at, verified_by
      )
      values (
        'SO-${PREFIX}-OPEN', shop_id, branch_id, 'salesperson', salesperson_id, 'verified', 3,
        '${PREFIX}-ord-open', now(), salesperson_id, now(), accounts_id
      );
      insert into public.order_lines (order_id, product_id, requested_cases)
      select id, product_id, 2 from public.orders where idempotency_key = '${PREFIX}-ord-open';
    end;
    $$;
    `,
    "m82g fixtures",
  )

  const parsed = lastLine(
    runLocalSql(
      `
      select
        (select id::text from public.orders where idempotency_key = '${PREFIX}-ord-open') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-ord-open');
      `,
      "m82g ids",
    ),
  ).split("|")
  fixture.orderId = parsed[0] ?? ""
  fixture.orderNumber = parsed[1] ?? ""
  if (!fixture.orderId) throw new Error(`m82g fixture parse failed: ${parsed.join("|")}`)
})

test("ACC-06/17 unassigned Accounts sees the verified delivery-note queue", async ({ page }) => {
  await login(page, fixture.emails.accountsNone)
  await expect(page.getByRole("link", { name: "Employees" })).toHaveCount(0)
  await page.goto("/deliveries")
  await expect(page.getByText("No godown assignment")).toHaveCount(0)
  await expect(page.getByText(fixture.orderNumber, { exact: true })).toBeVisible({ timeout: 20_000 })
  await page.goto(`/orders/verification/${fixture.orderId}`)
  await expect(page.getByRole("link", { name: "Create delivery note" })).toBeVisible({
    timeout: 20_000,
  })
  await page.getByRole("link", { name: "Create delivery note" }).click()
  await expect(page.getByLabel("Verified order")).toHaveValue(fixture.orderId, { timeout: 20_000 })
  await expect(page.getByRole("button", { name: "Create draft delivery note" })).toBeEnabled()
  await logout(page)
})

test("ACC-08/09/11 Accounts cannot open warehouse or employee administration", async ({ page }) => {
  await login(page, fixture.emails.accountsNone)
  await page.goto("/employees")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible()
  await page.goto("/dispatch")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible()
  await page.goto("/inventory/opening")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible()
  await logout(page)
})

test("Employee details show Accounts company-wide godown access", async ({ page }) => {
  await login(page, fixture.emails.admin)
  await page.goto("/employees")
  await expect(page.getByRole("heading", { name: "Employees" })).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Search employees").fill(`M82G Accounts None ${RUN}`)
  await page.getByRole("button", { name: new RegExp(`M82G Accounts None ${RUN}`) }).click()
  await expect(page.getByText("Role: Accounts")).toBeVisible()
  await expect(page.getByText("Godown access: All godowns — Company-wide")).toBeVisible()
  await expect(page.getByText("Explicit assignments: None")).toBeVisible()
  await page.keyboard.press("Escape")
  await logout(page)
})
