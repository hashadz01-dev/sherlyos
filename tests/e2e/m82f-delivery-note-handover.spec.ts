import { expect, test, type Page } from "@playwright/test"
import { runLocalSql } from "./disposable-stock.ts"

const password = "local-only-m82f"
const RUN = Date.now().toString(36)
const PREFIX = `m82f_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  shopName: `M82F Shop ${RUN}`,
  godownName: `M82F Godown ${RUN}`,
  godownBName: `M82F Godown B ${RUN}`,
  sku: `${PREFIX}_sku`,
  productLabel: "",
  openOrderId: "",
  openOrderNumber: "",
  altOrderId: "",
  altOrderNumber: "",
  submittedOrderNumber: "",
  dnOrderNumber: "",
  emails: {
    admin: `admin.${PREFIX}@example.com`,
    accounts: `accounts.${PREFIX}@example.com`,
    accountsNone: `accounts.none.${PREFIX}@example.com`,
    accountsOther: `accounts.other.${PREFIX}@example.com`,
    sales: `sales.${PREFIX}@example.com`,
    keeper: `keeper.${PREFIX}@example.com`,
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
  fixture.productLabel = `${fixture.sku} · M82F milk ${RUN}`
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      accounts_none_id uuid;
      accounts_other_id uuid;
      salesperson_id uuid;
      keeper_id uuid;
      branch_id uuid;
      branch_b uuid;
      product_id uuid;
      shop_id uuid;
      order_open uuid;
      order_alt uuid;
      order_submitted uuid;
      order_dn uuid;
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
        ('${fixture.emails.accountsOther}'),
        ('${fixture.emails.sales}'),
        ('${fixture.emails.keeper}')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = '${fixture.emails.admin}';
      select id into accounts_id from auth.users where email = '${fixture.emails.accounts}';
      select id into accounts_none_id from auth.users where email = '${fixture.emails.accountsNone}';
      select id into accounts_other_id from auth.users where email = '${fixture.emails.accountsOther}';
      select id into salesperson_id from auth.users where email = '${fixture.emails.sales}';
      select id into keeper_id from auth.users where email = '${fixture.emails.keeper}';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M82F Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M82F Admin', true),
        (accounts_id, 'M82F Accounts', true),
        (accounts_none_id, 'M82F Accounts None', true),
        (accounts_other_id, 'M82F Accounts Other', true),
        (salesperson_id, 'M82F Sales', true),
        (keeper_id, 'M82F Keeper', true)
      on conflict (id) do update set is_active = true, full_name = excluded.full_name;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values
        (admin_id, 'admin'),
        (accounts_id, 'accounts'),
        (accounts_none_id, 'accounts'),
        (accounts_other_id, 'accounts'),
        (salesperson_id, 'salesperson'),
        (keeper_id, 'store_keeper')
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

      branch_id := public.create_branch('${PREFIX}_a', '${fixture.godownName}');
      branch_b := public.create_branch('${PREFIX}_b', '${fixture.godownBName}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(accounts_other_id, branch_b);
      perform public.assign_user_branch(salesperson_id, branch_id);
      product_id := public.create_product('${fixture.sku}', 'M82F milk ${RUN}', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      shop_id := public.create_shop('${fixture.shopName}', null, null);
      perform public.assign_shop_salesperson(shop_id, salesperson_id);

      reset role;

      insert into public.orders (
        order_number, shop_id, branch_id, source, created_by, status, version,
        idempotency_key, submitted_at, submitted_by, verified_at, verified_by
      )
      values
        (
          'SO-${PREFIX}-OPEN', shop_id, branch_id, 'salesperson', salesperson_id, 'verified', 3,
          '${PREFIX}-ord-open', now(), salesperson_id, now(), accounts_id
        ),
        (
          'SO-${PREFIX}-ALT', shop_id, branch_id, 'salesperson', salesperson_id, 'verified', 3,
          '${PREFIX}-ord-alt', now(), salesperson_id, now(), accounts_id
        ),
        (
          'SO-${PREFIX}-SUB', shop_id, branch_id, 'salesperson', salesperson_id, 'submitted', 2,
          '${PREFIX}-ord-sub', now(), salesperson_id, null, null
        ),
        (
          'SO-${PREFIX}-DN', shop_id, branch_id, 'salesperson', salesperson_id, 'verified', 3,
          '${PREFIX}-ord-dn', now(), salesperson_id, now(), accounts_id
        );

      select id into order_open from public.orders where idempotency_key = '${PREFIX}-ord-open';
      select id into order_alt from public.orders where idempotency_key = '${PREFIX}-ord-alt';
      select id into order_submitted from public.orders where idempotency_key = '${PREFIX}-ord-sub';
      select id into order_dn from public.orders where idempotency_key = '${PREFIX}-ord-dn';

      insert into public.order_lines (order_id, product_id, requested_cases)
      values
        (order_open, product_id, 2),
        (order_alt, product_id, 1),
        (order_submitted, product_id, 2),
        (order_dn, product_id, 2);

      insert into public.delivery_notes (
        order_id, shop_id, branch_id, status, version, idempotency_key, created_by
      )
      values (order_dn, shop_id, branch_id, 'draft', 1, '${PREFIX}-dn-existing', accounts_id);
    end;
    $$;
    `,
    "m82f fixtures",
  )

  const parsed = lastLine(
    runLocalSql(
      `
      select
        (select id::text from public.orders where idempotency_key = '${PREFIX}-ord-open') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-ord-open') || '|' ||
        (select id::text from public.orders where idempotency_key = '${PREFIX}-ord-alt') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-ord-alt') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-ord-sub') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-ord-dn');
      `,
      "m82f ids",
    ),
  ).split("|")
  fixture.openOrderId = parsed[0] ?? ""
  fixture.openOrderNumber = parsed[1] ?? ""
  fixture.altOrderId = parsed[2] ?? ""
  fixture.altOrderNumber = parsed[3] ?? ""
  fixture.submittedOrderNumber = parsed[4] ?? ""
  fixture.dnOrderNumber = parsed[5] ?? ""
  if (!fixture.openOrderId || !fixture.altOrderId) {
    throw new Error(`m82f fixture parse failed: ${parsed.join("|")}`)
  }
})

test("DN-01 verified order appears in the waiting queue", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto("/deliveries")
  await expect(page.getByRole("heading", { name: "Verified Orders Awaiting Delivery Note" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(fixture.openOrderNumber, { exact: true })).toBeVisible()
  await expect(page.getByText(fixture.godownName).first()).toBeVisible()
  await expect(page.getByRole("link", { name: "Create Delivery Note" }).first()).toBeVisible()
  await logout(page)
})

test("DN-02 submitted order does not appear in the waiting queue", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto("/deliveries")
  await expect(page.getByRole("heading", { name: "Verified Orders Awaiting Delivery Note" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(fixture.submittedOrderNumber, { exact: true })).toHaveCount(0)
  await logout(page)
})

test("DN-03 existing active delivery note excludes the order from the queue", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto("/deliveries")
  await expect(page.getByRole("heading", { name: "Verified Orders Awaiting Delivery Note" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(fixture.dnOrderNumber, { exact: true })).toHaveCount(0)
  await logout(page)
})

test("DN-04 deep link preselects the verified order", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto(`/deliveries/new?orderId=${fixture.openOrderId}`)
  await expect(page.getByRole("heading", { name: "New delivery note" })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByLabel("Verified order")).toHaveValue(fixture.openOrderId)
  await expect(page.getByText("2 cases")).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText(fixture.godownName, { exact: true }).first()).toBeVisible()
  await expect(page.getByRole("button", { name: "Create draft delivery note" })).toBeEnabled()
  await logout(page)
})

test("DN-05 switching order updates the form consistently", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto(`/deliveries/new?orderId=${fixture.openOrderId}`)
  await expect(page.getByLabel("Verified order")).toHaveValue(fixture.openOrderId, { timeout: 20_000 })
  await expect(page.getByText("2 cases")).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Verified order").selectOption(fixture.altOrderId)
  await expect(page.getByLabel("Verified order")).toHaveValue(fixture.altOrderId)
  await expect(page.getByText("1 cases")).toBeVisible({ timeout: 20_000 })
  await expect(page).toHaveURL(new RegExp(`orderId=${fixture.altOrderId}`))
  await logout(page)
})

test("DN-06 invalid order id fails safely", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto("/deliveries/new?orderId=00000000-0000-0000-0000-000000000000")
  await expect(page.getByRole("alert")).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("button", { name: "Create draft delivery note" })).toBeDisabled()
  await logout(page)
})

test("DN-07 salesperson and store keeper cannot create", async ({ page }) => {
  await login(page, fixture.emails.sales)
  await page.goto("/deliveries/new")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await logout(page)

  await login(page, fixture.emails.keeper)
  await page.goto("/deliveries/new")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await logout(page)
})

test("DN-08 valid creation links the draft to the selected order", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto(`/orders/verification/${fixture.openOrderId}`)
  await expect(page.getByRole("link", { name: "Create delivery note" })).toBeVisible({ timeout: 20_000 })
  await page.getByRole("link", { name: "Create delivery note" }).click()
  await expect(page).toHaveURL(new RegExp(`/deliveries/new\\?orderId=${fixture.openOrderId}`))
  await expect(page.getByLabel("Verified order")).toHaveValue(fixture.openOrderId)
  await page.getByRole("button", { name: "Create draft delivery note" }).click()
  await expect(page).toHaveURL(/\/deliveries\/[0-9a-f-]{36}/i, { timeout: 20_000 })
  await expect(page.getByText(fixture.openOrderNumber).first()).toBeVisible()
  await expect(page.getByText("draft", { exact: true }).first()).toBeVisible()
  await logout(page)
})

test("DN-09 / DN-10 duplicate create is blocked and the queue drops the order", async ({ page }) => {
  await login(page, fixture.emails.accounts)
  await page.goto(`/deliveries/new?orderId=${fixture.openOrderId}`)
  await expect(page.getByRole("status")).toContainText(/already has an active delivery note/i, {
    timeout: 20_000,
  })
  await expect(page.getByRole("button", { name: "Create draft delivery note" })).toBeDisabled()
  await page.goto("/deliveries")
  await expect(page.getByText(fixture.openOrderNumber, { exact: true })).toHaveCount(0)
  await expect(page.getByText(fixture.altOrderNumber, { exact: true })).toBeVisible()
  await logout(page)
})

test("DN-12 unassigned Accounts sees company-wide verified orders", async ({ page }) => {
  await login(page, fixture.emails.accountsNone)
  await page.goto("/deliveries")
  await expect(page.getByText("No godown assignment")).toHaveCount(0)
  await expect(page.getByText(fixture.altOrderNumber, { exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.goto(`/orders/verification/${fixture.altOrderId}`)
  await expect(page.getByRole("link", { name: "Create delivery note" })).toBeVisible({
    timeout: 20_000,
  })
  await logout(page)
})
