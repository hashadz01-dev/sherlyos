import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m4e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m4e2e_${RUN}`

test.describe.configure({ mode: "serial" })

function runLocalSql(sql: string, label: string) {
  const result = spawnSync(
    "docker",
    ["exec", "-i", "supabase_db_sherlyos", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"],
    { input: sql, encoding: "utf8" },
  )
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || `${label} failed`)
  }
  return result.stdout.trim()
}

test.beforeAll(() => {
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      godown_id uuid;
      driver_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      inactive_id uuid;
      inactive_zone uuid;
      inactive_crate uuid;
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
        ('admin.m4e2e@example.com'),
        ('godown.m4e2e@example.com'),
        ('driver.m4e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m4e2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m4e2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m4e2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M4E2E Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values (godown_id, 'M4E2E Godown', true), (driver_id, 'M4E2E Driver', true)
      on conflict (id) do update set is_active = true, full_name = excluded.full_name;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values (godown_id, 'godown_manager'), (driver_id, 'delivery_person')) u(id, code)
      join public.roles r on r.code = u.code
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      execute 'set local role authenticated';

      branch_id := public.create_branch('${PREFIX}', 'M4E2E godown');
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}', 'M4E2E soap', null, null);
      perform public.post_opening_stock(product_id, crate_id, 7, '${PREFIX}-open', null);

      inactive_id := public.create_branch('${PREFIX}_hist', 'M4E2E historical');
      inactive_zone := public.create_zone(inactive_id, '${PREFIX}_hz', 'HZ', null);
      inactive_crate := public.create_crate(inactive_zone, '${PREFIX}_hc', 'HC', null);
      perform public.post_opening_stock(product_id, inactive_crate, 2, '${PREFIX}-hist-open', null);
      perform public.set_branch_active(inactive_id, false);
    end $$;
    `,
    "m4e2e seed",
  )
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    delete from public.stock_balances
    where product_id in (select id from public.products where sku = '${PREFIX}');
    delete from public.stock_lot_balances
    where lot_id in (
      select id from public.stock_lots
      where product_id in (select id from public.products where sku = '${PREFIX}')
    );
    delete from public.stock_lots
    where product_id in (select id from public.products where sku = '${PREFIX}');
    update public.app_configuration
    set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
    `,
    "m4e2e cleanup",
  )
})

async function signIn(page: Page, email: string) {
  await page.goto("/login")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
}

async function signOut(page: Page) {
  await page.getByRole("button", { name: "Account menu" }).click()
  await page.getByRole("menuitem", { name: "Sign out" }).click()
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible({ timeout: 20_000 })
}

test("unauthenticated visitors cannot open reports", async ({ page }) => {
  await page.goto("/reports")
  await expect(page).toHaveURL(/\/login$/)
})

test("godown manager sees dashboard KPIs and inventory without available-to-pick", async ({ page }) => {
  await signIn(page, "godown.m4e2e@example.com")
  await expect(page.getByText("Cartons on hand")).toBeVisible()
  await expect(page.getByText("7").first()).toBeVisible()
  await expect(page.getByText("Available to pick")).toBeVisible()
  await expect(page.getByText(/Lot-aware allocation is inactive/i)).toBeVisible()
  await expect(page.getByText(/Operational lot cutover is inactive/i)).toBeVisible()
  await expect(page.getByText(/include inactive godown stock/i)).toBeVisible()

  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Reports" }).click()
  await expect(page.getByRole("heading", { name: "Reports" })).toBeVisible()
  const reportsNav = page.getByRole("navigation", { name: "Reports" })
  await reportsNav.getByRole("link", { name: "Inventory" }).click()
  await expect(page.getByRole("heading", { name: "Inventory report" })).toBeVisible()
  await expect(page.getByText("M4E2E soap")).toBeVisible()
  await expect(page.getByText("7").first()).toBeVisible()
  await expect(page.getByText(/include inactive godown stock/i)).toBeVisible()

  const downloadPromise = page.waitForEvent("download")
  await page.getByRole("button", { name: "Export CSV" }).click()
  const download = await downloadPromise
  expect(download.suggestedFilename()).toMatch(/inventory/i)

  await reportsNav.getByRole("link", { name: "Lots" }).click()
  await expect(page.getByText("No lot balances")).toBeVisible()

  await reportsNav.getByRole("link", { name: "Movements" }).click()
  await expect(page.getByRole("heading", { name: "Stock movement report" })).toBeVisible()
  await expect(page.getByText("OPENING_STOCK").first()).toBeVisible()

  await reportsNav.getByRole("link", { name: "Orders & picking" }).click()
  await expect(page.getByRole("heading", { name: "Orders and picking report" })).toBeVisible()
  await expect(page.getByText("No orders")).toBeVisible()

  await reportsNav.getByRole("link", { name: "Dispatch & delivery" }).click()
  await expect(page.getByRole("heading", { name: "Dispatch and delivery report" })).toBeVisible()
  await expect(page.getByText("No dispatch rows")).toBeVisible()

  await reportsNav.getByRole("link", { name: "Exceptions" }).click()
  await expect(page.getByRole("heading", { name: "Operational exceptions" })).toBeVisible()
  await signOut(page)
})

test("inventory report stays usable at tablet width", async ({ page }) => {
  await page.setViewportSize({ width: 768, height: 1024 })
  await signIn(page, "godown.m4e2e@example.com")
  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Reports" }).click()
  await page.getByRole("navigation", { name: "Reports" }).getByRole("link", { name: "Inventory" }).click()
  await expect(page.getByRole("heading", { name: "Inventory report" })).toBeVisible()
  await expect(page.getByText("M4E2E soap")).toBeVisible()
  await expect(page.getByRole("button", { name: "Export CSV" })).toBeVisible()
  await signOut(page)
})

test("admin reports include labeled inactive godown stock", async ({ page }) => {
  await signIn(page, "admin.m4e2e@example.com")
  await expect(page.getByText("Cartons on hand")).toBeVisible()
  await expect(page.getByText("9").first()).toBeVisible()
  await expect(page.getByText("M4E2E historical")).toBeVisible()
  await expect(page.getByText("Inactive (historical)")).toBeVisible()
  await expect(page.getByRole("option", { name: /M4E2E historical \(.*\) \(inactive\)/ })).toBeVisible()

  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Opening stock" }).click()
  await expect(page.getByRole("heading", { name: "Opening stock" })).toBeVisible()
  await expect(page.getByRole("option", { name: "M4E2E historical" })).toHaveCount(0)

  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Reports" }).click()
  await page.getByRole("navigation", { name: "Reports" }).getByRole("link", { name: "Inventory" }).click()
  await expect(page.getByRole("option", { name: /M4E2E historical .* \(inactive\)/ })).toBeVisible()
  await signOut(page)
})

test("delivery person cannot open inventory reports", async ({ page }) => {
  await signIn(page, "driver.m4e2e@example.com")
  await expect(page.getByText("Assigned deliveries")).toBeVisible()
  await page.goto("/reports/inventory")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await signOut(page)
})
