import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m54ae2e"
const RUN = Date.now().toString(36)
const PREFIX = `m54a_${RUN}`

test.describe.configure({ mode: "serial" })

const fixture = {
  reportId: "",
  reportNumber: "",
  transitReportId: "",
  transitReportNumber: "",
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

function lastLine(text: string) {
  return text.split(/\r?\n/).filter(Boolean).at(-1) ?? ""
}

async function login(page: Page, email: string) {
  await page.goto("/login")
  await page.getByLabel(/email/i).fill(email)
  await page.getByLabel(/password/i).fill(password)
  await page.getByRole("button", { name: /sign in/i }).click()
  await expect(
    page.getByRole("heading", {
      name: /operations overview|damage management/i,
    }),
  ).toBeVisible({
    timeout: 20_000,
  })
}

test.beforeAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
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
      picking_id uuid;
      dispatch_id uuid;
      report_id uuid;
      transit_id uuid;
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
        ('admin.m54ae2e@example.com'),
        ('accounts.m54ae2e@example.com'),
        ('godown.m54ae2e@example.com'),
        ('keeper.m54ae2e@example.com'),
        ('driver.m54ae2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m54ae2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m54ae2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m54ae2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m54ae2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m54ae2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M54A Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (accounts_id, 'M54A Accounts', true),
        (godown_id, 'M54A Godown', true),
        (keeper_id, 'M54A Keeper', true),
        (driver_id, 'M54A Driver', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select map.user_id, r.id, admin_id
      from (values
        (accounts_id, 'accounts'),
        (godown_id, 'godown_manager'),
        (keeper_id, 'store_keeper'),
        (driver_id, 'delivery_person')
      ) as map(user_id, role_code)
      join public.roles r on r.code = map.role_code
      on conflict do nothing;

      insert into public.branches (code, name, is_active)
      values ('${PREFIX}_gd', 'M54A Godown ${RUN}', true)
      on conflict (code) do update set name = excluded.name, is_active = true
      returning id into branch_id;
      if branch_id is null then
        select id into branch_id from public.branches where code = '${PREFIX}_gd';
      end if;

      insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
      select x.uid, branch_id, admin_id
      from (values (godown_id), (keeper_id), (driver_id), (admin_id)) as x(uid)
      on conflict do nothing;

      insert into public.zones (branch_id, code, name, is_active)
      values (branch_id, '${PREFIX}_z', 'M54A Zone', true)
      returning id into zone_id;

      insert into public.crates (zone_id, code, name, is_active)
      values (zone_id, '${PREFIX}_c', 'M54A Crate', true)
      returning id into crate_id;

      insert into public.products (sku, name, is_active)
      values ('${PREFIX}_sku', 'M54A Product', true)
      returning id into product_id;

      insert into public.shops (name, is_active)
      values ('M54A Shop ${RUN}', true)
      returning id into shop_id;

      -- Write guards are skipped for this session (session_replication_role=replica).

      insert into public.orders (
        order_number, shop_id, branch_id, status, source, version, created_by,
        idempotency_key, verified_by, verified_at, submitted_by, submitted_at
      )
      values (
        '${PREFIX}-ORD', shop_id, branch_id, 'verified', 'accounts', 1, accounts_id,
        '${PREFIX}-ord-key', accounts_id, now(), accounts_id, now()
      )
      returning id into order_id;

      insert into public.stock_picking_requests (
        request_number, order_id, branch_id, status, version, created_by, idempotency_key
      )
      values (
        '${PREFIX}-PK', order_id, branch_id, 'ready_for_dispatch', 1, godown_id, '${PREFIX}-pk-key'
      )
      returning id into picking_id;

      insert into public.stock_dispatch_requests (
        request_number, order_id, picking_request_id, branch_id, status, version,
        assigned_to, assigned_by, assigned_at, created_by, idempotency_key, request_fingerprint
      )
      values (
        '${PREFIX}-DSP', order_id, picking_id, branch_id, 'in_transit', 1,
        driver_id, godown_id, now(), godown_id, '${PREFIX}-dsp-key', '${PREFIX}-dsp-fp'
      )
      returning id into dispatch_id;

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes, submitted_at, submitted_by
      )
      values (
        '${PREFIX}-DMG', 'storage', branch_id, 'submitted', 1, keeper_id,
        '${PREFIX}-dmg-key', '${PREFIX}-dmg-fp', 'M54A storage fixture', now(), keeper_id
      )
      returning id into report_id;

      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason, sort_order
      )
      values (report_id, product_id, crate_id, 3, 'crushed corner', 1);

      insert into public.damage_report_events (
        damage_report_id, action, actor_id, previous_status, next_status, metadata
      )
      values (
        report_id, 'submit', keeper_id, 'draft', 'submitted', '{"note":"seeded for m5.4a"}'::jsonb
      );

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id, dispatch_id,
        idempotency_key, request_fingerprint, notes, submitted_at, submitted_by
      )
      values (
        '${PREFIX}-TRN', 'transit', branch_id, 'submitted', 1, driver_id, dispatch_id,
        '${PREFIX}-trn-key', '${PREFIX}-trn-fp', 'M54A transit fixture', now(), driver_id
      )
      returning id into transit_id;

      insert into public.damage_report_lines (
        damage_report_id, product_id, quantity_cases, damage_reason, sort_order
      )
      values (transit_id, product_id, 1, 'wet carton', 1);

      -- 26 dated rows so server-side date filters must paginate, not slice the current page.
      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes, submitted_at, submitted_by, created_at
      )
      select
        '${PREFIX}-P' || to_char(gs, 'FM00'),
        'storage',
        branch_id,
        'submitted',
        1,
        keeper_id,
        '${PREFIX}-p' || to_char(gs, 'FM00') || '-key',
        '${PREFIX}-p' || to_char(gs, 'FM00') || '-fp',
        'paged fixture',
        timestamptz '2026-09-01 12:00:00+00',
        keeper_id,
        timestamptz '2026-09-01 12:00:00+00' + (gs || ' minutes')::interval
      from generate_series(1, 26) as gs;
    end $$;
    set session_replication_role = origin;
    `,
    "seed m5.4a damage fixtures",
  )

  const ids = runLocalSql(
    `
    select damage_reports.id || '|' || damage_reports.report_number
    from public.damage_reports
    where damage_reports.report_number = '${PREFIX}-DMG';
    `,
    "load storage report",
  )
  const transit = runLocalSql(
    `
    select damage_reports.id || '|' || damage_reports.report_number
    from public.damage_reports
    where damage_reports.report_number = '${PREFIX}-TRN';
    `,
    "load transit report",
  )

  const storageParts = lastLine(ids).split("|")
  const transitParts = lastLine(transit).split("|")
  fixture.reportId = storageParts[0] ?? ""
  fixture.reportNumber = storageParts[1] ?? ""
  fixture.transitReportId = transitParts[0] ?? ""
  fixture.transitReportNumber = transitParts[1] ?? ""

  if (!fixture.reportId || !fixture.transitReportId) {
    throw new Error(`M5.4A fixture seed failed: ${ids} / ${transit}`)
  }
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    delete from public.damage_report_events
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.damage_report_lines
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.damage_reports where report_number like '${PREFIX}-%';
    delete from public.stock_dispatch_requests where request_number like '${PREFIX}-%';
    delete from public.stock_picking_requests where request_number like '${PREFIX}-%';
    delete from public.orders where order_number like '${PREFIX}-%';
    delete from public.crates where code like '${PREFIX}_%';
    delete from public.zones where code like '${PREFIX}_%';
    delete from public.user_branch_assignments
    where branch_id in (select id from public.branches where code = '${PREFIX}_gd');
    delete from public.branches where code = '${PREFIX}_gd';
    delete from public.products where sku = '${PREFIX}_sku';
    delete from public.shops where name like 'M54A Shop ${RUN}%';
    set session_replication_role = origin;
    `,
    "cleanup m5.4a fixtures",
  )
})

test("admin can open the damage dashboard and report list", async ({
  page,
}) => {
  await login(page, "admin.m54ae2e@example.com")
  await page.goto("/damage")
  await expect(
    page.getByRole("heading", { name: "Damage Management" }),
  ).toBeVisible()
  await expect(
    page.getByText(/Damage stock isolation not ready/i),
  ).toBeVisible()
  await page.getByRole("link", { name: "All reports" }).click()
  await expect(
    page.getByRole("heading", { name: "Damage reports" }),
  ).toBeVisible()
  await expect(page.getByText(fixture.reportNumber)).toBeVisible()
})

test("godown manager sees verification queues and report detail", async ({
  page,
}) => {
  await login(page, "godown.m54ae2e@example.com")
  await page.goto("/damage")
  await expect(page.getByText("Awaiting verification")).toBeVisible()
  await page.goto(`/damage/${fixture.reportId}`)
  await expect(page.getByText(fixture.reportNumber)).toBeVisible()
  await expect(page.getByText("Stock isolation")).toBeVisible()
  await expect(page.getByText("Activity")).toBeVisible()
  await expect(page.getByText(/crushed corner/i)).toBeVisible()
})

test("store keeper can open authorized reports", async ({ page }) => {
  await login(page, "keeper.m54ae2e@example.com")
  await page.goto("/damage/reports")
  const reportLink = page
    .getByRole("link", { name: fixture.reportNumber })
    .first()
  await expect(reportLink).toBeVisible()
  await reportLink.click()
  await expect(page.getByText("Damage lines")).toBeVisible()
})

test("assigned driver can see transit report but not general storage report", async ({
  page,
}) => {
  await login(page, "driver.m54ae2e@example.com")
  await page.goto("/damage/reports")
  await expect(
    page.getByRole("link", { name: fixture.transitReportNumber }).first(),
  ).toBeVisible()
  await expect(
    page.getByRole("link", { name: fixture.reportNumber }),
  ).toHaveCount(0)
  await page.goto(`/damage/${fixture.transitReportId}`)
  await expect(
    page.getByRole("heading", { name: fixture.transitReportNumber }),
  ).toBeVisible()
  await page.goto(`/damage/${fixture.reportId}`)
  await expect(page.getByRole("alert")).toBeVisible()
})

test("accounts is denied damage screens", async ({ page }) => {
  await login(page, "accounts.m54ae2e@example.com")
  await page.goto("/damage")
  await expect(
    page.getByText(/You do not have access to this page/i),
  ).toBeVisible()
})

test("report list filters by report number search", async ({ page }) => {
  await login(page, "godown.m54ae2e@example.com")
  await page.goto("/damage/reports")
  await page.getByLabel(/search report number/i).fill(fixture.reportNumber)
  await expect(
    page.getByRole("link", { name: fixture.reportNumber }).first(),
  ).toBeVisible()
  await page.getByLabel(/search report number/i).fill("NO-SUCH-REPORT")
  await expect(page.getByText("No damage reports")).toBeVisible({
    timeout: 15_000,
  })
})

test("report list date filters paginate from the server total", async ({
  page,
}) => {
  await login(page, "godown.m54ae2e@example.com")
  await page.goto("/damage/reports")
  await page.getByLabel("From date").fill("2026-09-01")
  await page.getByLabel("To date").fill("2026-09-01")
  await expect(page.getByText("Page 1 of 2 · 26 reports")).toBeVisible({
    timeout: 15_000,
  })
  await expect(page.getByRole("link", { name: `${PREFIX}-P01` })).toHaveCount(0)
  await page.getByRole("button", { name: "Next" }).click()
  await expect(page.getByText("Page 2 of 2 · 26 reports")).toBeVisible()
  await expect(page.getByRole("link", { name: `${PREFIX}-P01` })).toBeVisible()
})
