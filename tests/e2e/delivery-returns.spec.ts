import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"
import { cleanupDisposableTestStock } from "./disposable-stock"

const password = "local-only-m74be2e"
const RUN = Date.now().toString(36)
const PREFIX = `m74b_${RUN}`

test.describe.configure({ mode: "serial" })

const fixture = {
  dispatchId: "",
  crateId: "",
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
  cleanupDisposableTestStock("m74b leftover disposable cleanup")
  const created = lastLine(
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
      vehicle_id uuid;
      order_id uuid;
      request_id uuid;
      header jsonb;
      res jsonb;
      i int;
      preview jsonb;
      prepared jsonb;
      confirmed jsonb;
      assigned jsonb;
      excepted jsonb;
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
        ('admin.m74be2e@example.com'),
        ('accounts.m74be2e@example.com'),
        ('godown.m74be2e@example.com'),
        ('keeper.m74be2e@example.com'),
        ('driver.m74be2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m74be2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m74be2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m74be2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m74be2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m74be2e@example.com';

      insert into public.profiles (id, full_name, is_active)
      values
        (admin_id, 'admin', true), (accounts_id, 'accounts', true),
        (godown_id, 'godown', true), (keeper_id, 'keeper', true), (driver_id, 'driver', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, roles.id, admin_id
      from (values
        (admin_id, 'admin'), (accounts_id, 'accounts'), (godown_id, 'godown_manager'),
        (keeper_id, 'store_keeper'), (driver_id, 'delivery_person')
      ) u(id, role_code)
      join public.roles on roles.code = u.role_code
      on conflict do nothing;

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      branch_id := public.create_branch('${PREFIX}', 'M74B E2E ${RUN}');
      perform public.assign_user_branch(accounts_id, branch_id);
      perform public.assign_user_branch(godown_id, branch_id);
      perform public.assign_user_branch(keeper_id, branch_id);
      perform public.assign_user_branch(driver_id, branch_id);
      zone_id := public.create_zone(branch_id, '${PREFIX}_z', 'Z', null);
      crate_id := public.create_crate(zone_id, '${PREFIX}_c', 'C', null);
      product_id := public.create_product('${PREFIX}', 'M74B E2E soap', null, null);
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      shop_id := public.create_shop('M74B E2E shop ${RUN}', null, null);

      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      vehicle_id := public.create_vehicle(branch_id, 'KL07${RUN}E', 'van', 'E2E return van', 8, null);

      execute 'reset role';
      set session_replication_role = replica;
      update public.app_configuration set value = 'true'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
      set session_replication_role = origin;
      execute 'set local role authenticated';

      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);
      perform public.post_opening_stock(product_id, crate_id, 4, '${PREFIX}-open', null, 'E2ELOT', null, '2028-06-01');

      perform set_config('request.jwt.claim.sub', accounts_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', accounts_id, 'role', 'authenticated')::text, true);
      header := public.create_order(
        shop_id, branch_id, 'accounts', null, null,
        jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 1)),
        '${PREFIX}-ord'
      );
      order_id := (header -> 'order' ->> 'id')::uuid;
      perform public.submit_order(order_id, 1, '${PREFIX}-sub');
      perform public.verify_order(order_id, 2, '${PREFIX}-ver');
      header := public.create_delivery_note(order_id, '${PREFIX}-dn');
      perform public.generate_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 1, '${PREFIX}-gen');
      perform public.send_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 2, '${PREFIX}-send');
      perform set_config('request.jwt.claim.sub', godown_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      perform public.acknowledge_delivery_note((header -> 'delivery_note' ->> 'id')::uuid, 3, '${PREFIX}-ack');
      header := public.reserve_order_allocation(order_id, 3, '${PREFIX}-res');
      request_id := (header ->> 'id')::uuid;
      header := public.assign_picking_request(request_id, keeper_id, 1, '${PREFIX}-asg');
      header := public.start_picking(request_id, 2, '${PREFIX}-start');
      perform set_config('request.jwt.claim.sub', keeper_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', keeper_id, 'role', 'authenticated')::text, true);
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
      perform set_config('request.jwt.claims', json_build_object('sub', godown_id, 'role', 'authenticated')::text, true);
      header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, '${PREFIX}-ho');
      preview := public.preview_dispatch(order_id);
      prepared := public.prepare_dispatch(order_id, (preview ->> 'picking_version')::integer, '${PREFIX}-prep');
      confirmed := public.confirm_dispatch((prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, '${PREFIX}-cfm');
      assigned := public.assign_dispatch_delivery(
        (confirmed ->> 'id')::uuid, driver_id, (confirmed ->> 'version')::integer, '${PREFIX}-asgd', vehicle_id
      );
      excepted := public.report_dispatch_delivery_exception(
        (assigned ->> 'id')::uuid, 'refused', (assigned ->> 'version')::integer, '${PREFIX}-exc'
      );
      perform set_config('sherlyos.dispatch', excepted ->> 'id', false);
      perform set_config('sherlyos.crate', crate_id::text, false);
    end $$;
    select concat_ws('|',
      current_setting('sherlyos.dispatch', true),
      (select crates.id::text from public.crates where crates.code = '${PREFIX}_c')
    );
    `,
      "m74b e2e fixture",
    ),
  )
  const [dispatchId, crateId] = created.split("|")
  fixture.dispatchId = dispatchId
  fixture.crateId = crateId
  if (!fixture.dispatchId) throw new Error(`fixture dispatch missing: ${created}`)
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    update public.app_configuration set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;
    `,
    "m74b restore flags",
  )
  cleanupDisposableTestStock("m74b e2e cleanup")
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

test("driver records handback, keeper counts, GM posts return to stock", async ({ page }) => {
  await signIn(page, "driver.m74be2e@example.com")
  await page.goto(`/dispatch/${fixture.dispatchId}`)
  await expect(page.getByRole("heading", { name: "Failed-delivery return" })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("Awaiting driver handback", { exact: true })).toBeVisible()
  await expect(page.getByText(/Inventory is still deducted/)).toBeVisible()
  await page.getByLabel("Cases handed back").fill("1")
  await page.getByRole("button", { name: "Record handback" }).click()
  await expect(page.getByText("Handed back — awaiting count", { exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await signOut(page)

  await signIn(page, "keeper.m74be2e@example.com")
  await page.goto(`/dispatch/${fixture.dispatchId}`)
  await expect(page.getByLabel(/saleable cases for/)).toBeVisible({ timeout: 20_000 })
  await page.getByLabel(/delivered cases for/).fill("0")
  await page.getByLabel(/saleable cases for/).fill("1")
  await page.getByLabel(/damaged cases for/).fill("0")
  await page.getByLabel(/uncertain cases for/).fill("0")
  await page.getByLabel(/missing cases for/).fill("0")
  await page.getByLabel(/Receiving crate for/).selectOption(fixture.crateId)
  await page.getByRole("button", { name: "Save Store Keeper count" }).click()
  await expect(page.getByText("Counted — awaiting approval", { exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await signOut(page)

  await signIn(page, "godown.m74be2e@example.com")
  await page.goto(`/dispatch/${fixture.dispatchId}`)
  await page.getByRole("button", { name: "Approve return" }).click()
  await expect(page.getByText("Approved — awaiting stock posting", { exact: true })).toBeVisible({
    timeout: 20_000,
  })
  await page.getByRole("button", { name: "Post return to stock" }).click()
  await expect(page.getByText("Returned to stock", { exact: true })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText(/Stock credited on transaction/)).toBeVisible()
  const posted = lastLine(
    runLocalSql(
      `
      select concat_ws('|',
        (select count(*)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'DELIVERY_RETURN' and p.sku = '${PREFIX}'),
        (select count(*)::text from public.stock_transactions st
          join public.products p on p.id = st.product_id
          where st.transaction_type = 'DISPATCH' and p.sku = '${PREFIX}')
      );
      `,
      "m74b e2e ledger",
    ),
  )
  expect(posted).toBe("1|1")
  await signOut(page)
})
