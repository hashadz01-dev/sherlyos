import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m64e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m64_${RUN}`

test.describe.configure({ mode: "serial", timeout: 120_000 })

const fixture = {
  godownName: `M64 Godown ${RUN}`,
  supplierName: `M64 Brand ${RUN}`,
  productA: `${PREFIX}_a`,
  productB: `${PREFIX}_b`,
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
      name: /operations overview|stock refill|refill request|stock receiving|receipt/i,
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

async function chooseRefillRequest(page: Page) {
  const combo = page.getByLabel("Approved refill request")
  const optionText =
    (await combo.locator("option").filter({ hasText: fixture.requestNumber }).textContent()) ?? ""
  await combo.selectOption({ label: optionText.trim() })
}

async function fillLinkedLines(page: Page, countedA: string, countedB: string) {
  const zones = page.getByLabel("Zone")
  const crates = page.getByLabel("Destination crate")
  const counted = page.getByLabel("Counted cases")
  const damaged = page.getByLabel("Damaged cases")
  await zones.nth(0).selectOption({ index: 1 })
  await crates.nth(0).selectOption({ index: 1 })
  await counted.nth(0).fill(countedA)
  await damaged.nth(0).fill("0")
  await zones.nth(1).selectOption({ index: 1 })
  await crates.nth(1).selectOption({ index: 1 })
  await counted.nth(1).fill(countedB)
  await damaged.nth(1).fill("0")
}

test.beforeAll(() => {
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      keeper_id uuid;
      gm_id uuid;
      branch_id uuid;
      supplier_id uuid;
      product_a uuid;
      product_b uuid;
      zone_id uuid;
      created jsonb;
      submitted jsonb;
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
        ('admin.m64e2e@example.com'),
        ('accounts.m64e2e@example.com'),
        ('keeper.m64e2e@example.com'),
        ('gm.m64e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m64e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m64e2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m64e2e@example.com';
      select id into gm_id from auth.users where email = 'gm.m64e2e@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M64 E2E Admin', true),
        (accounts_id, 'M64 E2E Accounts', true),
        (keeper_id, 'M64 E2E Keeper', true),
        (gm_id, 'M64 E2E GM', true)
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
      select keeper_id, roles.id, admin_id from public.roles where roles.code = 'store_keeper'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select gm_id, roles.id, admin_id from public.roles where roles.code = 'godown_manager'
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      branch_id := public.create_branch('m64e2e_${RUN}', '${fixture.godownName}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(gm_id, branch_id);
      zone_id := public.create_zone(branch_id, 'm64z', 'M64 Zone', null);
      perform public.create_crate(zone_id, 'm64c', 'M64 Crate', null);
      supplier_id := public.create_supplier('${fixture.supplierName}', null, null);
      product_a := public.create_product('${fixture.productA}', 'M64 Soap A ${RUN}', supplier_id, null);
      product_b := public.create_product('${fixture.productB}', 'M64 Soap B ${RUN}', supplier_id, null);

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
        true
      );
      created := public.create_stock_refill_request(
        supplier_id, branch_id,
        jsonb_build_array(
          jsonb_build_object('product_id', product_a, 'requested_cases', 10),
          jsonb_build_object('product_id', product_b, 'requested_cases', 6)
        ),
        'm64e2e-${RUN}-c', null
      );
      submitted := public.submit_stock_refill_request(
        (created ->> 'id')::uuid, (created ->> 'version')::integer, 'm64e2e-${RUN}-s'
      );
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      perform public.approve_stock_refill_request(
        (submitted ->> 'id')::uuid, (submitted ->> 'version')::integer, 'm64e2e-${RUN}-a', null
      );
    end $$;
    `,
    "m64 e2e seed",
  )
  fixture.requestNumber =
    runLocalSql(
      `select request_number from public.stock_refill_requests where idempotency_key = 'm64e2e-${RUN}-c';`,
      "request number",
    )
      .split(/\r?\n/)
      .filter(Boolean)
      .at(-1) ?? ""
})

test("accounts cannot open receiving creation", async ({ page }) => {
  await login(page, "accounts.m64e2e@example.com")
  await page.goto("/receiving/new")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await logout(page)
})

test("godown managers cannot approve refill from the refill module", async ({ page }) => {
  await login(page, "gm.m64e2e@example.com")
  await page.goto("/refill")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await logout(page)
})

test("first partial receipt is counted and verified", async ({ page }) => {
  await login(page, "keeper.m64e2e@example.com")
  await page.goto("/receiving/new")
  await expect(page.getByRole("heading", { name: "New receipt" })).toBeVisible()
  await chooseRefillRequest(page)
  await expect(page.getByText(/Remaining against/i)).toBeVisible({ timeout: 20_000 })
  await expect(page.getByLabel("Zone")).toHaveCount(2, { timeout: 20_000 })
  await page.getByLabel("Supplier document reference").fill(`M64-E2E-1-${RUN}`)
  await fillLinkedLines(page, "4", "2")
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /^RC-/ })).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Submit for verification" }).click()
  await expect(page.getByText("submitted", { exact: false }).first()).toBeVisible({ timeout: 20_000 })
  await logout(page)

  await login(page, "gm.m64e2e@example.com")
  await page.goto("/receiving")
  await page.getByRole("link", { name: /^RC-/ }).first().click()
  await page.getByRole("button", { name: "Verify and post" }).click()
  await page.getByRole("button", { name: "Verify and post" }).last().click()
  await expect(page.getByText("posted", { exact: false }).first()).toBeVisible({ timeout: 20_000 })
  const qty = runLocalSql(
    `select coalesce(sum(quantity),0)::text from public.stock_balances
     join public.products on products.id = stock_balances.product_id
     where products.sku in ('${fixture.productA}', '${fixture.productB}');`,
    "qty after first verify",
  )
    .split(/\r?\n/)
    .filter(Boolean)
    .at(-1)
  expect(Number(qty)).toBeGreaterThanOrEqual(6)
  await logout(page)
})

test("second partial receipt updates reconciliation totals", async ({ page }) => {
  await login(page, "keeper.m64e2e@example.com")
  await page.goto("/receiving/new")
  await chooseRefillRequest(page)
  await expect(page.getByText(/Remaining against/i)).toBeVisible({ timeout: 20_000 })
  await expect(page.getByLabel("Zone")).toHaveCount(2, { timeout: 20_000 })
  await page.getByLabel("Supplier document reference").fill(`M64-E2E-2-${RUN}`)
  await fillLinkedLines(page, "3", "2")
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /^RC-/ })).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Submit for verification" }).click()
  await expect(page.getByText("submitted", { exact: false }).first()).toBeVisible({ timeout: 20_000 })
  await logout(page)

  await login(page, "gm.m64e2e@example.com")
  await page.goto("/receiving")
  await page.getByRole("link", { name: /^RC-/ }).first().click()
  await page.getByRole("button", { name: "Verify and post" }).click()
  await page.getByRole("button", { name: "Verify and post" }).last().click()
  await expect(page.getByText("posted", { exact: false }).first()).toBeVisible({ timeout: 20_000 })
  await logout(page)

  await login(page, "accounts.m64e2e@example.com")
  await page.goto("/refill")
  await page.getByRole("link", { name: fixture.requestNumber }).click()
  await expect(page.getByRole("heading", { name: "Receiving & reconciliation" })).toBeVisible()
  await expect(page.getByText("Partially received")).toBeVisible()
  await expect(page.getByText(/Verified accepted cases/i)).toBeVisible()
  await logout(page)
})

test("excess quantity is refused on a linked receipt", async ({ page }) => {
  await login(page, "keeper.m64e2e@example.com")
  await page.goto("/receiving/new")
  await chooseRefillRequest(page)
  await expect(page.getByText(/Remaining against/i)).toBeVisible({ timeout: 20_000 })
  await expect(page.getByLabel("Zone")).toHaveCount(2, { timeout: 20_000 })
  await page.getByLabel("Supplier document reference").fill(`M64-E2E-X-${RUN}`)
  await fillLinkedLines(page, "99", "99")
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByText(/exceed requested cases|too large|would exceed/i)).toBeVisible({
    timeout: 20_000,
  })
  await logout(page)
})

test("unlinked receiving still posts accepted cases", async ({ page }) => {
  const before = runLocalSql(
    `select coalesce(sum(quantity),0)::text from public.stock_balances
     join public.products on products.id = stock_balances.product_id
     where products.sku = '${fixture.productA}';`,
    "unlinked before",
  )
    .split(/\r?\n/)
    .filter(Boolean)
    .at(-1)
  await login(page, "keeper.m64e2e@example.com")
  await page.goto("/receiving/new")
  await expect(page.getByRole("heading", { name: "New receipt" })).toBeVisible()
  await page.locator("select").filter({ has: page.getByRole("option", { name: "Choose a godown" }) }).selectOption({ index: 1 })
  await page.locator("select").filter({ has: page.getByRole("option", { name: "Choose a supplier" }) }).selectOption({ label: fixture.supplierName })
  await page.getByLabel("Supplier document reference").fill(`M64-E2E-U-${RUN}`)
  const productSelect = page.locator("select").filter({ has: page.getByRole("option", { name: "Choose a product" }) })
  const productLabel =
    (await productSelect.locator("option").filter({ hasText: fixture.productA }).textContent()) ?? ""
  await productSelect.selectOption({ label: productLabel.trim() })
  await page.locator("select").filter({ has: page.getByRole("option", { name: "Choose a zone" }) }).selectOption({ index: 1 })
  await page.locator("select").filter({ has: page.getByRole("option", { name: "Choose a crate" }) }).selectOption({ index: 1 })
  await page.getByLabel("Document cases").fill("1")
  await page.getByLabel("Counted cases").fill("1")
  await page.getByLabel("Damaged cases").fill("0")
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /^RC-/ })).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Submit for verification" }).click()
  await logout(page)
  await login(page, "gm.m64e2e@example.com")
  await page.goto("/receiving")
  await page.getByRole("link", { name: /^RC-/ }).first().click()
  await page.getByRole("button", { name: "Verify and post" }).click()
  await page.getByRole("button", { name: "Verify and post" }).last().click()
  await expect(page.getByText("posted", { exact: false }).first()).toBeVisible({ timeout: 20_000 })
  const after = runLocalSql(
    `select coalesce(sum(quantity),0)::text from public.stock_balances
     join public.products on products.id = stock_balances.product_id
     where products.sku = '${fixture.productA}';`,
    "unlinked after",
  )
    .split(/\r?\n/)
    .filter(Boolean)
    .at(-1)
  expect(Number(after)).toBe(Number(before) + 1)
})
