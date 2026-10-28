import { expect, test, type Page } from "@playwright/test"
import { runLocalSql } from "./disposable-stock.ts"

const password = "local-only-m72e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m72_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  shopName: `M72 Shop ${RUN}`,
  productLabel: "",
  godownName: `M72 Godown ${RUN}`,
  orderNumber: "",
  noteId: "",
  submittedUrl: "",
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
  const sku = `${PREFIX}_sku`
  fixture.productLabel = `${sku} · M72 soap ${RUN}`
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      salesperson_id uuid;
      godown_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      crate_lot uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
      note_id uuid;
      payload jsonb;
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
        ('admin.m72e2e@example.com'),
        ('accounts.m72e2e@example.com'),
        ('sales.m72e2e@example.com'),
        ('godown.m72e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m72e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m72e2e@example.com';
      select id into salesperson_id from auth.users where email = 'sales.m72e2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m72e2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M72E2E Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M72E2E Admin', true),
        (accounts_id, 'M72E2E Accounts', true),
        (salesperson_id, 'M72E2E Sales', true),
        (godown_id, 'M72E2E Godown', true)
      on conflict (id) do update set is_active = true, full_name = excluded.full_name;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values
        (admin_id, 'admin'),
        (accounts_id, 'accounts'),
        (salesperson_id, 'salesperson'),
        (godown_id, 'godown_manager')
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
      perform public.assign_user_branch(godown_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      crate_lot := public.create_crate(zone_id, '${PREFIX}_cl', 'CL', null);
      product_id := public.create_product('${sku}', 'M72 soap ${RUN}', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      shop_id := public.create_shop('${fixture.shopName}', null, null);
      perform public.assign_shop_salesperson(shop_id, salesperson_id);
      -- Gross opening is informational only. Lot opening uses a second crate
      -- because post_opening_stock cannot post twice for the same product+crate.
      perform public.post_opening_stock(product_id, crate_id, 4, '${PREFIX}-open', null);

      reset role;
      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      execute 'set local role authenticated';
      perform public.post_opening_stock(
        product_id, crate_lot, 4, '${PREFIX}-lot', null, 'M72E2E-LOT', null, null
      );

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
        true
      );
      order_id := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 1)),
        '${PREFIX}-seed-order'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-seed-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-seed-ver');
      payload := public.create_delivery_note(order_id, '${PREFIX}-seed-dn');
      note_id := (payload -> 'delivery_note' ->> 'id')::uuid;
      perform public.generate_delivery_note(note_id, 1, '${PREFIX}-seed-gen');
      perform public.send_delivery_note(note_id, 2, '${PREFIX}-seed-send');

      reset role;
      set session_replication_role = replica;
      update public.app_configuration set value = 'false'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;
    end;
    $$;
    `,
    "m72e2e fixtures",
  )

  const parsed = lastLine(
    runLocalSql(
      `
      select
        (select order_number from public.orders where idempotency_key = '${PREFIX}-seed-order') || '|' ||
        (select id::text from public.delivery_notes where idempotency_key = '${PREFIX}-seed-dn');
      `,
      "m72e2e ids",
    ),
  ).split("|")
  fixture.orderNumber = parsed[0] ?? ""
  fixture.noteId = parsed[1] ?? ""
  if (!fixture.orderNumber || !fixture.noteId) {
    throw new Error(`m72e2e fixture parse failed: ${parsed.join("|")}`)
  }
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    delete from public.stock_ledger
    where product_id in (select id from public.products where sku like '${PREFIX}%')
      and lot_id is not null;
    update public.app_configuration
    set value = 'false'::jsonb
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    );
    set session_replication_role = origin;
    `,
    "m72e2e restore flags",
  )
})

test("unauthenticated visitors cannot open orders", async ({ page }) => {
  await page.goto("/orders/new")
  await expect(page).toHaveURL(/\/login$/)
})

test("salesperson captures a shop order", async ({ page }) => {
  await login(page, "sales.m72e2e@example.com")
  await page.goto("/orders/new")
  await expect(page.getByRole("heading", { name: "New order" })).toBeVisible({ timeout: 20_000 })
  await page.getByLabel("Shop").selectOption({ label: fixture.shopName })
  await page.getByLabel("Fulfilling godown").selectOption({ label: fixture.godownName })
  const sku = fixture.productLabel.split(" · ")[0]
  await page.getByLabel("Product", { exact: true }).click()
  await page.getByLabel("Product", { exact: true }).fill(sku)
  await page.getByRole("option", { name: fixture.productLabel }).click()
  await page.getByLabel("Cases").fill("1")
  await page.getByRole("button", { name: "Create draft" }).click()
  await expect(page).toHaveURL(/\/orders\/[0-9a-f-]{36}/i, { timeout: 20_000 })
  fixture.submittedUrl = new URL(page.url()).pathname
  await expect(page.getByText("draft", { exact: true }).first()).toBeVisible()
  await page.getByRole("button", { name: "Submit order" }).click()
  await expect(page.getByText("submitted", { exact: true }).first()).toBeVisible({ timeout: 20_000 })
  await logout(page)
})

test("accounts verification stays fail-closed before cutover", async ({ page }) => {
  await login(page, "accounts.m72e2e@example.com")
  if (!fixture.submittedUrl) throw new Error("salesperson capture did not record an order URL")
  await page.goto(fixture.submittedUrl)
  await expect(page.getByRole("heading", { name: "Picking-eligible availability" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(/Lot-aware picking is not operational/i)).toBeVisible()
  await page.getByRole("button", { name: "Verify order" }).click()
  await expect(page.getByRole("alert")).toContainText(/insufficient picking-eligible stock/i)
  await expect(page.getByText("submitted", { exact: true }).first()).toBeVisible()
  await logout(page)
})

test("godown manager acknowledges a sent delivery note", async ({ page }) => {
  await login(page, "godown.m72e2e@example.com")
  await page.goto(`/deliveries/${fixture.noteId}`)
  await expect(page.getByRole("heading", { name: /DN-|Delivery note/ })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("sent", { exact: true }).first()).toBeVisible()
  await page.getByRole("button", { name: "Acknowledge receipt" }).click()
  await page.getByRole("button", { name: "Confirm acknowledgement" }).click()
  await expect(page.getByText("Delivery note acknowledged.")).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText("acknowledged", { exact: true }).first()).toBeVisible()
  await logout(page)
})
