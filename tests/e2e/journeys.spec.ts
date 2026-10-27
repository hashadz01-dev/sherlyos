import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m14e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m14e2e_${RUN}`

test.describe.configure({ mode: "serial" })

const fixture = {
  orderId: "",
  orderNumber: "",
}

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

function lastLine(text: string) {
  return text.split(/\r?\n/).filter(Boolean).at(-1) ?? ""
}

test.beforeAll(() => {
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      godown_id uuid;
      driver_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
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
        ('admin.m14e2e@example.com'),
        ('accounts.m14e2e@example.com'),
        ('godown.m14e2e@example.com'),
        ('driver.m14e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m14e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m14e2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m14e2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m14e2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M14E2E Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M14E2E Admin', true),
        (accounts_id, 'M14E2E Accounts', true),
        (godown_id, 'M14E2E Godown', true),
        (driver_id, 'M14E2E Driver', true)
      on conflict (id) do update set is_active = true, full_name = excluded.full_name;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values
        (admin_id, 'admin'),
        (accounts_id, 'accounts'),
        (godown_id, 'godown_manager'),
        (driver_id, 'delivery_person')
      ) u(id, code)
      join public.roles r on r.code = u.code
      on conflict do nothing;

      update public.app_configuration
      set value = 'false'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      execute 'set local role authenticated';

      branch_id := public.create_branch('${PREFIX}', 'M14E2E godown');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}', 'M14E2E journey soap', null, null);
      shop_id := public.create_shop('M14E2E shop ${RUN}', null, null);
      perform public.post_opening_stock(product_id, crate_id, 5, '${PREFIX}-open', null);

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
        true
      );
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 2)),
        '${PREFIX}-order'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-sub');
      -- M7.2: verify is picking-eligible and fail-closed while dual-write is off.
      -- Test I only needs a submitted order for the allocate preview blockers.
    end $$;
    `,
    "m14e2e seed",
  )

  const parsed = lastLine(
    runLocalSql(
      `
      select
        (select id::text from public.orders where idempotency_key = '${PREFIX}-order') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-order');
      `,
      "m14e2e ids",
    ),
  ).split("|")
  fixture.orderId = parsed[0] ?? ""
  fixture.orderNumber = parsed[1] ?? ""
  if (!fixture.orderId) {
    throw new Error(`m14e2e fixture parse failed: ${parsed.join("|")}`)
  }
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
    "m14e2e cleanup",
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

test("A: login, refresh, logout, then protected routes stay closed", async ({ page }) => {
  await signIn(page, "admin.m14e2e@example.com")
  await expect(page.getByText("Cartons on hand")).toBeVisible()
  await page.reload()
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("Cartons on hand")).toBeVisible()
  await signOut(page)
  await page.goto("/orders")
  await expect(page).toHaveURL(/\/login$/)
  await expect(page.getByText("Operations Overview")).toHaveCount(0)
})

test("H: switching to a delivery person cannot reuse admin cached data", async ({ page }) => {
  await signIn(page, "admin.m14e2e@example.com")
  await page.goto("/inventory")
  await expect(page.getByRole("heading", { name: "Inventory" })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText("M14E2E journey soap")).toBeVisible()
  await signOut(page)
  await signIn(page, "driver.m14e2e@example.com")
  await expect(page.getByText("M14E2E journey soap")).toHaveCount(0)
  await expect(page.getByText("Cartons on hand")).toHaveCount(0)
  await page.goto("/inventory")
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("M14E2E journey soap")).toHaveCount(0)
  await signOut(page)
})

test("I: cutover-inactive allocation stays fail-closed and does not consume stock", async ({ page }) => {
  const flags = lastLine(
    runLocalSql(
      `
      select concat_ws('|',
        (select value::text from public.app_configuration where key = 'stock.lots.dual_write_enabled'),
        (select value::text from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
      );
      `,
      "m14e2e flags",
    ),
  )
  expect(flags).toBe("false|false")

  await signIn(page, "godown.m14e2e@example.com")
  await page.goto(`/picking/allocate/${fixture.orderId}`)
  await expect(page.getByRole("heading", { name: new RegExp(`Allocate ${fixture.orderNumber}`) })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("alert").filter({ hasText: /dual-write/i })).toBeVisible()
  await expect(page.getByRole("button", { name: "Confirm reservation" })).toBeDisabled()
  await signOut(page)

  const ledger = lastLine(
    runLocalSql(
      `
      select concat_ws('|',
        (select count(*)::text from public.stock_reservations r
          join public.products p on p.id = r.product_id
          where p.sku = '${PREFIX}'),
        (select count(*)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'DISPATCH' and p.sku = '${PREFIX}')
      );
      `,
      "m14e2e cutover ledger",
    ),
  )
  expect(ledger).toBe("0|0")
})

test("J: delivery person is denied protected operational URLs", async ({ page }) => {
  await signIn(page, "driver.m14e2e@example.com")
  await page.goto("/reports")
  await expect(page.getByRole("heading", { name: "Reports" })).toBeVisible({ timeout: 20_000 })
  for (const path of ["/reports/inventory", "/picking", "/dispatch", "/inventory", "/orders", "/masters"]) {
    await page.goto(path)
    await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
      timeout: 20_000,
    })
  }
  await signOut(page)
})
