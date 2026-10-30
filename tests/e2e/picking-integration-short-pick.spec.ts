import { expect, test, type Page } from "@playwright/test"
import {
  cleanupDisposableTestStock,
  disposableSkuExcludeSql,
  runLocalSql,
} from "./disposable-stock.ts"

const password = "local-only-m73e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m73_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  orderId: "",
  orderNumber: "",
  shopName: `M73 Shop ${RUN}`,
  godownName: `M73 Godown ${RUN}`,
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
  cleanupDisposableTestStock("m73 leftover disposable cleanup")
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      accounts_id uuid;
      godown_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
      payload jsonb;
      note_id uuid;
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
        ('admin.m73e2e@example.com'),
        ('accounts.m73e2e@example.com'),
        ('godown.m73e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m73e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m73e2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m73e2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M73E2E Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'M73E2E Admin', true),
        (accounts_id, 'M73E2E Accounts', true),
        (godown_id, 'M73E2E Godown', true)
      on conflict (id) do update set is_active = true, full_name = excluded.full_name;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values
        (admin_id, 'admin'),
        (accounts_id, 'accounts'),
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

      if exists (
        select 1
        from public.stock_balances sb
        join public.products p on p.id = sb.product_id
        where sb.quantity > 0
          and sb.quantity is distinct from coalesce((
            select sum(lb.quantity)
            from public.stock_lot_balances lb
            join public.stock_lots l on l.id = lb.lot_id
            where lb.crate_id = sb.crate_id
              and l.product_id = sb.product_id
          ), 0)
          and ${disposableSkuExcludeSql("p")}
      ) then
        raise exception 'unmatched non-disposable stock blocks picking flag enable';
      end if;

      if exists (
        select 1
        from public.stock_balances sb
        where sb.quantity > 0
          and sb.quantity is distinct from coalesce((
            select sum(lb.quantity)
            from public.stock_lot_balances lb
            join public.stock_lots l on l.id = lb.lot_id
            where lb.crate_id = sb.crate_id
              and l.product_id = sb.product_id
          ), 0)
      ) then
        perform public.seed_legacy_stock_lots();
      end if;

      execute 'reset role';
      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;
      execute 'set local role authenticated';

      branch_id := public.create_branch('${PREFIX}', '${fixture.godownName}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}_sku', 'M73 soap ${RUN}', null, null);
      perform public.set_product_expiry_policy(product_id, 'non_expiring');
      shop_id := public.create_shop('${fixture.shopName}', null, null);

      perform public.post_opening_stock(
        product_id, crate_id, 4, '${PREFIX}-open', null, 'M73E2E-LOT', null, null
      );

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
      perform public.verify_order(order_id, 2, '${PREFIX}-ver');
      payload := public.create_delivery_note(order_id, '${PREFIX}-dn');
      note_id := (payload -> 'delivery_note' ->> 'id')::uuid;
      perform public.generate_delivery_note(note_id, 1, '${PREFIX}-gen');
      perform public.send_delivery_note(note_id, 2, '${PREFIX}-send');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
        true
      );
      perform public.acknowledge_delivery_note(note_id, 3, '${PREFIX}-ack');
    end;
    $$;
    `,
    "m73e2e fixtures",
  )

  const parsed = lastLine(
    runLocalSql(
      `
      select
        (select id::text from public.orders where idempotency_key = '${PREFIX}-order') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-order');
      `,
      "m73e2e ids",
    ),
  ).split("|")
  fixture.orderId = parsed[0] ?? ""
  fixture.orderNumber = parsed[1] ?? ""
  if (!fixture.orderId || !fixture.orderNumber) {
    throw new Error(`m73e2e fixture parse failed: ${parsed.join("|")}`)
  }
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    select set_config('app.shipment_write', 'on', true);
    delete from public.order_shipment_events
    where shipment_id in (
      select id from public.order_shipments
      where order_id in (select id from public.orders where idempotency_key like '${PREFIX}%')
    );
    delete from public.order_shipment_lots
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    delete from public.order_shipment_lines
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    delete from public.order_shipments
    where order_id in (select id from public.orders where idempotency_key like '${PREFIX}%');
    delete from public.stock_picking_exceptions
    where reservation_id in (
      select id from public.stock_reservations
      where product_id in (select id from public.products where sku like '${PREFIX}%')
    );
    delete from public.stock_reservations
    where product_id in (select id from public.products where sku like '${PREFIX}%');
    update public.stock_picking_requests
    set status = 'cancelled', cancelled_by = created_by, cancelled_at = clock_timestamp(),
        cancellation_reason = 'm73e2e cleanup'
    where order_id in (select id from public.orders where idempotency_key like '${PREFIX}%')
      and status is distinct from 'cancelled';
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
    "m73e2e restore flags",
  )
})

test("unauthenticated visitors cannot open picking", async ({ page }) => {
  await page.goto("/picking")
  await expect(page).toHaveURL(/\/login$/)
})

test("order detail shows DN acknowledgement and does not claim reserved stock", async ({ page }) => {
  await login(page, "accounts.m73e2e@example.com")
  await page.goto(`/orders/${fixture.orderId}`)
  await expect(page.getByRole("heading", { name: fixture.orderNumber })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(/Acknowledged — packing may start/i)).toBeVisible()
  await expect(page.getByText(/does not guarantee reserved stock/i)).toBeVisible()
  await logout(page)
})

test("allocation preview shows ordered and eligible cases", async ({ page }) => {
  await login(page, "godown.m73e2e@example.com")
  await page.goto(`/picking/allocate/${fixture.orderId}`)
  await expect(page.getByRole("heading", { name: new RegExp(`Allocate ${fixture.orderNumber}`) })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText(/Verification does not reserve stock/i)).toBeVisible()
  await expect(page.getByText(/Delivery note status: acknowledged/i)).toBeVisible()
  await expect(page.getByText(/Ordered 2 · Eligible 2 · Shortfall 0/i)).toBeVisible()
  await expect(page.getByRole("button", { name: "Confirm reservation" })).toBeEnabled()
  await logout(page)
})

test("short pick cannot be handed to dispatch", async ({ page }) => {
  await login(page, "godown.m73e2e@example.com")
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Packing" })).toBeVisible()
  await page.getByLabel("Search packing").fill(fixture.orderNumber)
  await page.getByRole("link", { name: "Allocate" }).click()
  await page.getByRole("button", { name: "Confirm reservation" }).click()
  await expect(page.getByRole("heading", { name: /^PK-/ })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText("Ordered 2")).toBeVisible()
  await expect(page.getByText("Reserved 2")).toBeVisible()
  await page.getByRole("button", { name: "Start packing" }).click()
  await expect(page.getByText("Packing started")).toBeVisible({ timeout: 20_000 })
  await page.getByLabel(/Picked cases for/).fill("1")
  await page.getByRole("button", { name: "Confirm pick" }).click()
  await expect(page.getByText("Quantity confirmed")).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Report shortage" }).click()
  await expect(page.getByText("Exception recorded")).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Complete packing" }).click()
  await expect(page.getByText("Packing completed")).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("button", { name: "Create short-shipment" })).toBeVisible()
  await expect(page.getByRole("button", { name: "Ready for dispatch" })).toHaveCount(0)
  await page.getByRole("button", { name: "Create short-shipment" }).click()
  await expect(page.getByText(/Draft shipment/i).first()).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Confirm picked quantities" }).click()
  await expect(page.getByText("GM confirmed", { exact: true })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("button", { name: "Ready for dispatch" })).toHaveCount(0)
  await logout(page)

  await login(page, "accounts.m73e2e@example.com")
  await page.goto(`/orders/${fixture.orderId}`)
  await expect(page.getByRole("heading", { name: fixture.orderNumber })).toBeVisible({
    timeout: 20_000,
  })
  await page.getByRole("button", { name: "Approve short-shipment" }).click()
  await expect(page.getByText(/Accounts approved/i).first()).toBeVisible({ timeout: 20_000 })
  await logout(page)

  await login(page, "godown.m73e2e@example.com")
  await page.goto("/picking")
  await page.getByLabel("Status").selectOption("picked")
  await page.getByLabel("Search packing").fill(fixture.orderNumber)
  await page.getByRole("link", { name: "Open" }).click()
  await expect(page.getByRole("button", { name: "Ready for dispatch" })).toBeVisible()
  await logout(page)
})
