import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m3e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m3e2e_${RUN}`

test.describe.configure({ mode: "serial" })

const fixture = {
  orderId: "",
  orderNumber: "",
  driverId: "",
  failDispatchId: "",
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
      keeper_id uuid;
      driver_id uuid;
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_id uuid;
      request_id uuid;
      header jsonb;
      res jsonb;
      i int;
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
        ('admin.m3e2e@example.com'),
        ('accounts.m3e2e@example.com'),
        ('godown.m3e2e@example.com'),
        ('keeper.m3e2e@example.com'),
        ('driver.m3e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m3e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m3e2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m3e2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m3e2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m3e2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M3E2E Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (accounts_id, 'M3E2E Accounts', true),
        (godown_id, 'M3E2E Godown', true),
        (keeper_id, 'M3E2E Keeper', true),
        (driver_id, 'M3E2E Driver', true)
      on conflict (id) do update
        set is_active = true,
            full_name = excluded.full_name;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values
        (accounts_id, 'accounts'),
        (godown_id, 'godown_manager'),
        (keeper_id, 'store_keeper'),
        (driver_id, 'delivery_person')
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
          and p.sku not like 'm1s2qa-%'
          and p.sku not like 'm1s2c%'
          and p.sku not like 'm1s3c%'
          and p.sku not like 'm1s3qa%'
          and p.sku not like 'm2e2e_%'
          and p.sku not like 'm2pk%'
          and p.sku not like 'm3e2e_%'
          and p.sku not like 'm3qa%'
          and p.sku not like 'm3c_%'
          and p.sku not like 'm3ds%'
      ) then
        raise exception 'unmatched non-disposable stock blocks dispatch flag enable';
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
      -- Replica: dispatch e2e is not proving the unmatched-grain enable trigger.
      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;
      execute 'set local role authenticated';

      branch_id := public.create_branch('${PREFIX}', 'M3E2E ${RUN}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}', 'M3E2E soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('M3E2E shop ${RUN}', null, null);

      perform public.post_opening_stock(
        product_id, crate_id, 4, '${PREFIX}-open', null, 'M3E2E-LOT', null, '2028-04-01'
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

      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
        true
      );
      header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-res');
      request_id := (header ->> 'id')::uuid;
      header := public.assign_picking_request(request_id, keeper_id, 1, '${PREFIX}-asg');
      header := public.start_picking(request_id, 2, '${PREFIX}-start');
      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', keeper_id, 'role', 'authenticated')::text,
        true
      );
      header := public.get_picking_request(request_id);
      for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
        res := header -> 'reservations' -> i;
        header := public.confirm_picking_quantity(
          request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
          (header ->> 'version')::integer, '${PREFIX}-pick-' || i::text
        );
      end loop;
      header := public.complete_picking(request_id, (header ->> 'version')::integer, '${PREFIX}-done');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
        true
      );
      perform public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, '${PREFIX}-ho');
      if not exists (
        select 1
        from jsonb_array_elements(public.list_dispatch_assignees(branch_id)) entry
        where (entry ->> 'id') = driver_id::text
      ) then
        raise exception 'dispatch assignees missing driver: %', public.list_dispatch_assignees(branch_id);
      end if;
    end;
    $$;
    `,
    "m3e2e fixtures",
  )

  const parsed = lastLine(
    runLocalSql(
      `
      select
        (select id::text from public.orders where idempotency_key = '${PREFIX}-order') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-order') || '|' ||
        (select id::text from auth.users where email = 'driver.m3e2e@example.com');
      `,
      "m3e2e ids",
    ),
  ).split("|")
  fixture.orderId = parsed[0] ?? ""
  fixture.orderNumber = parsed[1] ?? ""
  fixture.driverId = parsed[2] ?? ""
  if (!fixture.orderId || !fixture.driverId) {
    throw new Error(`m3e2e fixture parse failed: ${parsed.join("|")}`)
  }

  fixture.failDispatchId = lastLine(
    runLocalSql(
      `
      do $$
      declare
        godown_id uuid;
        keeper_id uuid;
        accounts_id uuid;
        shop_id uuid;
        branch_id uuid;
        product_id uuid;
        order_id uuid;
        request_id uuid;
        header jsonb;
        res jsonb;
        i int;
        prepared jsonb;
      begin
        select id into godown_id from auth.users where email = 'godown.m3e2e@example.com';
        select id into keeper_id from auth.users where email = 'keeper.m3e2e@example.com';
        select id into accounts_id from auth.users where email = 'accounts.m3e2e@example.com';
        select o.shop_id, o.branch_id into shop_id, branch_id
        from public.orders o where o.idempotency_key = '${PREFIX}-order';
        -- Qualify the column so PL/pgSQL does not bind the NULL product_id variable.
        select products.id into product_id from public.products where products.sku = '${PREFIX}';

        perform set_config('request.jwt.claim.sub', accounts_id::text, true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        order_id := (public.create_order(
          shop_id, branch_id, 'accounts', null, null,
          jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 1)),
          '${PREFIX}-order-fail'
        ) -> 'order' ->> 'id')::uuid;
        perform public.submit_order(order_id, 1, '${PREFIX}-sub-fail');
        perform public.verify_order(order_id, 2, '${PREFIX}-ver-fail');

        perform set_config('request.jwt.claim.sub', godown_id::text, true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
        header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-res-fail');
        request_id := (header ->> 'id')::uuid;
        header := public.assign_picking_request(request_id, keeper_id, 1, '${PREFIX}-asg-fail');
        header := public.start_picking(request_id, 2, '${PREFIX}-start-fail');
        perform set_config('request.jwt.claim.sub', keeper_id::text, true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
        header := public.get_picking_request(request_id);
        for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
          res := header -> 'reservations' -> i;
          header := public.confirm_picking_quantity(
            request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
            (header ->> 'version')::integer, '${PREFIX}-pick-fail-' || i::text
          );
        end loop;
        header := public.complete_picking(request_id, (header ->> 'version')::integer, '${PREFIX}-done-fail');
        perform set_config('request.jwt.claim.sub', godown_id::text, true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
        header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, '${PREFIX}-ho-fail');
        prepared := public.prepare_dispatch(order_id, (header ->> 'version')::integer, '${PREFIX}-prep-fail');
        perform public.confirm_dispatch(
          (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, '${PREFIX}-cfm-fail'
        );
      end $$;
      select id::text from public.stock_dispatch_requests
      where idempotency_key = '${PREFIX}-prep-fail';
      `,
      "m3e2e fail fixture",
    ),
  )
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    select set_config('app.dispatch_write', 'on', true);
    update public.stock_reservations
    set status = 'released'
    where order_id in (select id from public.orders where idempotency_key = '${PREFIX}-order')
      and status = 'active';
    update public.stock_ledger
    set lot_id = null
    where product_id in (select id from public.products where sku = '${PREFIX}');
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
    "m3e2e cleanup",
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

test("unauthenticated visitors cannot open dispatch", async ({ page }) => {
  await page.goto("/dispatch")
  await expect(page).toHaveURL(/\/login$/)
})

test("store keeper cannot open dispatch", async ({ page }) => {
  await signIn(page, "keeper.m3e2e@example.com")
  await page.goto(`/dispatch/prepare/${fixture.orderId}`)
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await signOut(page)
})

test("godown manager confirms dispatch and assigns delivery", async ({ page }) => {
  await signIn(page, "godown.m3e2e@example.com")
  await page.goto("/dispatch")
  await expect(page.getByRole("heading", { name: "Dispatch" })).toBeVisible()
  await page.getByLabel("Search dispatch").fill(fixture.orderNumber)
  await page
    .getByRole("row", { name: new RegExp(fixture.orderNumber) })
    .getByRole("link", { name: "Dispatch" })
    .click()
  await expect(page.getByRole("heading", { name: new RegExp(`Dispatch ${fixture.orderNumber}`) })).toBeVisible({
    timeout: 20_000,
  })
  await page.getByRole("button", { name: "Confirm dispatch" }).click()
  await page.getByRole("button", { name: /Dispatch 2 cases/ }).click()
  await expect(page.getByRole("heading", { name: /^DS-/ })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText("Stock consumed").first()).toBeVisible()

  const ledger = lastLine(
    runLocalSql(
      `
      select concat_ws('|',
        (select count(*)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'DISPATCH' and p.sku = '${PREFIX}'),
        (select coalesce(sum(st.quantity), 0)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'DISPATCH' and p.sku = '${PREFIX}'),
        (select count(*)::text from public.stock_reservations r
          join public.products p on p.id = r.product_id
          where r.status = 'consumed' and p.sku = '${PREFIX}')
      );
      `,
      "m3e2e dispatch ledger",
    ),
  )
  expect(ledger).toBe("2|3|2")

  await expect(
    page.locator(`select[aria-label="Delivery assignee"] option[value="${fixture.driverId}"]`),
  ).toBeAttached({ timeout: 20_000 })
  await page.getByLabel("Delivery assignee").selectOption(fixture.driverId)
  await page.getByRole("button", { name: "Assign" }).click()
  await expect(page.getByText("Delivery assigned").first()).toBeVisible({ timeout: 20_000 })
  await signOut(page)
})

test("godown manager records a failed delivery without restocking", async ({ page }) => {
  await signIn(page, "godown.m3e2e@example.com")
  await page.goto(`/dispatch/${fixture.failDispatchId}`)
  await expect(page.getByRole("heading", { name: /^DS-/ })).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Report failed delivery" }).click()
  await page.getByLabel("Failed delivery reason").fill("Customer refused the cartons")
  await page.getByRole("button", { name: "Record exception" }).click()
  await expect(page.getByText("Delivery exception").first()).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText("Pending verification (stock not restored)")).toBeVisible()
  const afterFail = lastLine(
    runLocalSql(
      `
      select concat_ws('|',
        (select count(*)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'DISPATCH' and p.sku = '${PREFIX}'),
        (select count(*)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'RECEIPT' and p.sku = '${PREFIX}')
      );
      `,
      "m3e2e fail delivery ledger",
    ),
  )
  expect(afterFail).toBe("2|0")
  await signOut(page)
})

test("delivery personnel records proof of delivery", async ({ page }) => {
  await signIn(page, "driver.m3e2e@example.com")
  await page.goto("/delivery-runs")
  await expect(page.getByRole("heading", { name: "Delivery runs" })).toBeVisible()
  await page.getByLabel("Search deliveries").fill(fixture.orderNumber)
  await page.getByRole("link", { name: "Open" }).click()
  await expect(page.getByRole("heading", { name: /^DS-/ })).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Start delivery" }).click()
  await expect(page.getByText("Out for delivery").first()).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Record proof of delivery" }).click()
  await page.getByLabel("Recipient name").fill("Shop owner")
  await page.getByRole("button", { name: "Acknowledge delivery" }).click()
  await expect(page.getByText("Delivery acknowledged").first()).toBeVisible({ timeout: 20_000 })
  await signOut(page)
})

test("cutover-disabled dispatch stays blocked", async ({ page }) => {
  // Flag triggers refuse dual-write off while lot ledger exists. Replica is the
  // local-only way to present the fail-closed UI after this suite has dispatched.
  runLocalSql(
    `
    set session_replication_role = replica;
    update public.app_configuration set value = 'false'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
    `,
    "m3e2e disable cutover",
  )
  await signIn(page, "godown.m3e2e@example.com")
  await page.goto(`/dispatch/prepare/${fixture.orderId}`)
  await expect(page.getByRole("alert").filter({ hasText: /dual-write/i })).toBeVisible({
    timeout: 20_000,
  })
  await signOut(page)
  runLocalSql(
    `
    set session_replication_role = replica;
    update public.app_configuration set value = 'true'::jsonb
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    set session_replication_role = origin;
    `,
    "m3e2e restore cutover",
  )
})
