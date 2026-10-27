import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m65e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m65_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  godownName: `M65 Godown ${RUN}`,
  supplierName: `M65 Brand ${RUN}`,
  productSku: `${PREFIX}_sku`,
  openNumber: "",
  sentNumber: "",
  draftReceipt: "",
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
      name: /operations overview|stock refill|refill request|stock receiving|receipt|reports/i,
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
      keeper_id uuid;
      driver_id uuid;
      branch_id uuid;
      supplier_id uuid;
      product_id uuid;
      zone_id uuid;
      crate_id uuid;
      open_req jsonb;
      sent_req jsonb;
      draft jsonb;
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
        ('admin.m65e2e@example.com'),
        ('accounts.m65e2e@example.com'),
        ('keeper.m65e2e@example.com'),
        ('driver.m65e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m65e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m65e2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m65e2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m65e2e@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M65 E2E Admin', true),
        (accounts_id, 'M65 E2E Accounts', true),
        (keeper_id, 'M65 E2E Keeper', true),
        (driver_id, 'M65 E2E Driver', true)
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
      select driver_id, roles.id, admin_id from public.roles where roles.code = 'delivery_person'
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      branch_id := public.create_branch('m65e2e_${RUN}', '${fixture.godownName}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      supplier_id := public.create_supplier('${fixture.supplierName}', null, null);
      product_id := public.create_product('${fixture.productSku}', 'M65 Soap ${RUN}', supplier_id, null);
      zone_id := public.create_zone(branch_id, 'm65e2e_z_${RUN}', 'Z', null);
      crate_id := public.create_crate(zone_id, 'm65e2e_c_${RUN}', 'C', null);

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
        true
      );
      open_req := public.create_stock_refill_request(
        supplier_id, branch_id,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 10)),
        'm65e2e-${RUN}-open-c', null
      );
      open_req := public.submit_stock_refill_request(
        (open_req ->> 'id')::uuid, (open_req ->> 'version')::integer, 'm65e2e-${RUN}-open-s'
      );
      sent_req := public.create_stock_refill_request(
        supplier_id, branch_id,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 6)),
        'm65e2e-${RUN}-sent-c', null
      );
      sent_req := public.submit_stock_refill_request(
        (sent_req ->> 'id')::uuid, (sent_req ->> 'version')::integer, 'm65e2e-${RUN}-sent-s'
      );

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      open_req := public.approve_stock_refill_request(
        (open_req ->> 'id')::uuid, (open_req ->> 'version')::integer, 'm65e2e-${RUN}-open-a', null
      );
      sent_req := public.approve_stock_refill_request(
        (sent_req ->> 'id')::uuid, (sent_req ->> 'version')::integer, 'm65e2e-${RUN}-sent-a', null
      );

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
        true
      );
      sent_req := public.record_stock_refill_supplier_communication(
        (sent_req ->> 'id')::uuid, (sent_req ->> 'version')::integer,
        'email', clock_timestamp(), 'm65e2e-${RUN}-send', 'PO-65', null
      );

      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', keeper_id, 'role', 'authenticated')::text,
        true
      );
      draft := public.create_stock_receipt(
        branch_id, supplier_id, 'm65e2e-${RUN}-van',
        (clock_timestamp() at time zone 'utc')::date, null,
        jsonb_build_array(jsonb_build_object(
          'product_id', product_id,
          'destination_crate_id', crate_id,
          'document_cases', 4,
          'counted_cases', 4,
          'damaged_cases', 0
        )),
        (open_req ->> 'id')::uuid
      );
    end $$;
    `,
    "m65 e2e seed",
  )
  fixture.openNumber =
    runLocalSql(
      `select request_number from public.stock_refill_requests where idempotency_key = 'm65e2e-${RUN}-open-c';`,
      "open number",
    )
      .split(/\r?\n/)
      .filter(Boolean)
      .at(-1) ?? ""
  fixture.sentNumber =
    runLocalSql(
      `select request_number from public.stock_refill_requests where idempotency_key = 'm65e2e-${RUN}-sent-c';`,
      "sent number",
    )
      .split(/\r?\n/)
      .filter(Boolean)
      .at(-1) ?? ""
  fixture.draftReceipt =
    runLocalSql(
      `select receipt_number from public.stock_receipts where document_reference = 'm65e2e-${RUN}-van';`,
      "draft receipt",
    )
      .split(/\r?\n/)
      .filter(Boolean)
      .at(-1) ?? ""
})

test("store keeper cannot open refill queues or reports", async ({ page }) => {
  await login(page, "keeper.m65e2e@example.com")
  await page.goto("/refill")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await page.goto("/reports/refill")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await logout(page)
})

test("accounts filters the queue on the server and sees reserved drafts without receipt links", async ({
  page,
}) => {
  await login(page, "accounts.m65e2e@example.com")
  await page.goto("/refill")
  await expect(page.getByRole("heading", { name: "Stock Refill" })).toBeVisible()
  await expect(page.getByRole("link", { name: fixture.openNumber })).toBeVisible()
  await expect(page.getByRole("link", { name: fixture.sentNumber })).toBeVisible()
  await page.getByLabel("Supplier communication").selectOption("sent")
  await expect(page.getByRole("link", { name: fixture.sentNumber })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("link", { name: fixture.openNumber })).toHaveCount(0)
  await page.getByLabel("Supplier communication").selectOption("all")
  await page.getByRole("link", { name: fixture.openNumber }).click()
  await expect(page.getByRole("heading", { name: "Receiving & reconciliation" })).toBeVisible()
  await expect(page.getByText(/Draft receipts still reserve requested quantity/i)).toBeVisible()
  await expect(page.getByText(fixture.draftReceipt)).toBeVisible()
  await expect(page.getByRole("link", { name: fixture.draftReceipt })).toHaveCount(0)
  await expect(page.getByRole("link", { name: "Supplier communication" })).toBeVisible()
  await logout(page)
})

test("authorized refill report stays on refill permissions and loading/empty filters work", async ({
  page,
}) => {
  await login(page, "accounts.m65e2e@example.com")
  await page.goto("/reports/refill")
  await expect(page.getByRole("heading", { name: "Refill report" })).toBeVisible()
  await expect(page.getByText(/does not post inventory/i)).toBeVisible()
  await expect(page.getByRole("link", { name: fixture.openNumber })).toBeVisible()
  await page.getByLabel("Acknowledgement").selectOption("declined")
  await expect(page.getByText("No refill rows")).toBeVisible({ timeout: 20_000 })
  await logout(page)
})

test("delivery personnel cannot open refill reporting", async ({ page }) => {
  await login(page, "driver.m65e2e@example.com")
  await page.goto("/reports/refill")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await logout(page)
})
