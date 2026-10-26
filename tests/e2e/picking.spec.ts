import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m2e2e"
const RUN = Date.now().toString(36)
const PREFIX = `m2e2e_${RUN}`

test.describe.configure({ mode: "serial" })

const fixture = {
  orderAId: "",
  orderBId: "",
  orderANumber: "",
  keeperId: "",
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
      branch_id uuid;
      zone_id uuid;
      crate_id uuid;
      product_id uuid;
      shop_id uuid;
      order_a uuid;
      order_b uuid;
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
        ('admin.m2e2e@example.com'),
        ('accounts.m2e2e@example.com'),
        ('godown.m2e2e@example.com'),
        ('keeper.m2e2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m2e2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m2e2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m2e2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m2e2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M2E2E Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (accounts_id, 'M2E2E Accounts', true),
        (godown_id, 'M2E2E Godown', true),
        (keeper_id, 'M2E2E Keeper', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values (accounts_id, 'accounts'), (godown_id, 'godown_manager'), (keeper_id, 'store_keeper')) u(id, code)
      join public.roles r on r.code = u.code
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      execute 'set local role authenticated';

      -- M1-S2 QA openings stay aggregate-only. Dual-write cannot enable until
      -- every positive grain has matching lots. Seed leftover disposable SKUs
      -- through the real seed RPC; refuse any other unmatched stock.
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

      -- Flag DML is postgres-only; the cutover trigger still validates the pair.
      execute 'reset role';
      -- Replica: picking e2e is not proving the unmatched-grain enable trigger.
      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;
      execute 'set local role authenticated';

      branch_id := public.create_branch('${PREFIX}', 'M2E2E ${RUN}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}', 'M2E2E soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('M2E2E shop ${RUN}', null, null);

      perform public.post_opening_stock(
        product_id, crate_id, 6, '${PREFIX}-open', null, 'M2E2E-LOT', null, '2028-04-01'
      );

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', accounts_id, 'role', 'authenticated')::text,
        true
      );

      order_a := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 6)),
        '${PREFIX}-order-a'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_a, 1, '${PREFIX}-sub-a');
      perform public.verify_order(order_a, 2, '${PREFIX}-ver-a');

      order_b := (public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 2)),
        '${PREFIX}-order-b'
      ) -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_b, 1, '${PREFIX}-sub-b');
      perform public.verify_order(order_b, 2, '${PREFIX}-ver-b');
    end;
    $$;
    `,
    "m2e2e fixtures",
  )

  const parsed = lastLine(
    runLocalSql(
      `
      select
        (select id::text from public.orders where idempotency_key = '${PREFIX}-order-a') || '|' ||
        (select id::text from public.orders where idempotency_key = '${PREFIX}-order-b') || '|' ||
        (select order_number from public.orders where idempotency_key = '${PREFIX}-order-a') || '|' ||
        (select id::text from auth.users where email = 'keeper.m2e2e@example.com');
      `,
      "m2e2e ids",
    ),
  ).split("|")
  fixture.orderAId = parsed[0] ?? ""
  fixture.orderBId = parsed[1] ?? ""
  fixture.orderANumber = parsed[2] ?? ""
  fixture.keeperId = parsed[3] ?? ""
  if (!fixture.orderAId || !fixture.keeperId) {
    throw new Error(`m2e2e fixture parse failed: ${parsed.join("|")}`)
  }
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    update public.stock_reservations
    set status = 'released'
    where order_id in (
      select id from public.orders
      where idempotency_key in ('${PREFIX}-order-a', '${PREFIX}-order-b')
    );
    update public.stock_picking_requests
    set status = 'cancelled',
        cancelled_by = created_by,
        cancelled_at = coalesce(cancelled_at, clock_timestamp()),
        cancellation_reason = coalesce(cancellation_reason, 'm2e2e cleanup')
    where order_id in (
      select id from public.orders
      where idempotency_key in ('${PREFIX}-order-a', '${PREFIX}-order-b')
    )
      and status is distinct from 'cancelled'
      and status is distinct from 'ready_for_dispatch';
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
    "m2e2e cleanup",
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

test("unauthenticated visitors cannot open picking", async ({ page }) => {
  await page.goto("/picking")
  await expect(page).toHaveURL(/\/login$/)
})

test("store keeper cannot open allocation", async ({ page }) => {
  await signIn(page, "keeper.m2e2e@example.com")
  await page.goto(`/picking/allocate/${fixture.orderAId}`)
  await expect(page.getByRole("heading", { name: "You do not have access to this page" })).toBeVisible({
    timeout: 20_000,
  })
  await signOut(page)
})

test("godown manager allocates, store keeper picks, handoff is ready", async ({ page }) => {
  await signIn(page, "godown.m2e2e@example.com")
  await page.goto("/picking")
  await expect(page.getByRole("heading", { name: "Picking" })).toBeVisible()
  await page.getByLabel("Search picking").fill(fixture.orderANumber)
  await page.getByRole("link", { name: "Allocate" }).click()
  await expect(page.getByRole("heading", { name: new RegExp(`Allocate ${fixture.orderANumber}`) })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole("button", { name: "Confirm reservation" })).toBeEnabled()
  await page.getByRole("button", { name: "Confirm reservation" }).click()
  await expect(page.getByRole("heading", { name: /^PK-/ })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText("Reservation confirmed")).toBeVisible()

  await page.getByLabel("Assignee user id").fill(fixture.keeperId)
  await page.getByRole("button", { name: "Assign" }).click()
  await expect(page.getByText("Task assigned")).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Start picking" }).click()
  await expect(page.getByText("Picking started")).toBeVisible({ timeout: 20_000 })
  await signOut(page)

  await signIn(page, "keeper.m2e2e@example.com")
  await page.goto("/picking")
  await page.getByLabel("Picking status").selectOption("picking")
  await page.getByLabel("Search picking").fill(fixture.orderANumber)
  await page.getByRole("link", { name: "Open" }).click()
  await expect(page.getByRole("heading", { name: /^PK-/ })).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Confirm pick" }).click()
  await expect(page.getByText("Quantity confirmed")).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Complete picking" }).click()
  await expect(page.getByText("Picking completed")).toBeVisible({ timeout: 20_000 })
  await signOut(page)

  await signIn(page, "godown.m2e2e@example.com")
  await page.goto("/picking")
  await page.getByLabel("Picking status").selectOption("picked")
  await page.getByLabel("Search picking").fill(fixture.orderANumber)
  await page.getByRole("link", { name: "Open" }).click()
  await page.getByRole("button", { name: "Ready for dispatch" }).click()
  await expect(page.getByText("Ready for dispatch").first()).toBeVisible({ timeout: 20_000 })

  const ledger = lastLine(
    runLocalSql(
      `
      select concat_ws('|',
        (select count(*)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'DISPATCH' and p.sku = '${PREFIX}'),
        (select count(*)::text from public.stock_reservations r
          join public.products p on p.id = r.product_id
          where r.status = 'active' and p.sku = '${PREFIX}'),
        (select count(*)::text from public.stock_reservations r
          join public.products p on p.id = r.product_id
          where r.status = 'consumed' and p.sku = '${PREFIX}')
      );
      `,
      "m2e2e handoff ledger",
    ),
  )
  const [dispatchCount, activeCount, consumedCount] = ledger.split("|")
  expect(dispatchCount).toBe("0")
  expect(Number(activeCount)).toBeGreaterThan(0)
  expect(consumedCount).toBe("0")
})

test("insufficient leftover stock blocks a second allocation", async ({ page }) => {
  await signIn(page, "godown.m2e2e@example.com")
  await page.goto(`/picking/allocate/${fixture.orderBId}`)
  await expect(page.getByRole("heading", { name: /Allocate/ })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("listitem").filter({ hasText: "Insufficient eligible FEFO stock" })).toBeVisible()
  await expect(page.getByRole("button", { name: "Confirm reservation" })).toBeDisabled()
})

test("duplicate reservation is refused after the order is already allocated", async ({ page }) => {
  await signIn(page, "godown.m2e2e@example.com")
  await page.goto(`/picking/allocate/${fixture.orderAId}`)
  await expect(page.getByText(/already has an active picking request/)).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("button", { name: "Confirm reservation" })).toBeDisabled()
})
