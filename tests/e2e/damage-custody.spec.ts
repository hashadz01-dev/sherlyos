import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m54ce2e"
const RUN = Date.now().toString(36)
const PREFIX = `m54c_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  godownName: `M54C Godown ${RUN}`,
  otherGodownName: `M54C Other ${RUN}`,
  inactiveGodownName: `M54C Inactive ${RUN}`,
  shopReturnId: "",
  shopReturnNumber: "",
  transferId: "",
  transferNumber: "",
  rejectedId: "",
  rejectedNumber: "",
  inactiveId: "",
  logicalHoldNumber: "",
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
      name: /operations overview|damage management|quarantine inventory/i,
    }),
  ).toBeVisible({ timeout: 20_000 })
}

test.beforeAll(() => {
  const created = runLocalSql(
    `
    set session_replication_role = replica;
    do $$
    declare
      admin_id uuid;
      godown_id uuid;
      keeper_id uuid;
      driver_id uuid;
      branch_id uuid;
      other_id uuid;
      dead_id uuid;
      zone_id uuid;
      crate_id uuid;
      qzone uuid;
      qcrate uuid;
      other_zone uuid;
      other_crate uuid;
      dead_zone uuid;
      dead_crate uuid;
      product_id uuid;
      shop_id uuid;
      sr_id uuid;
      xfer_id uuid;
      rej_id uuid;
      dead_report uuid;
      line_id uuid;
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
        ('admin.m54ce2e@example.com'),
        ('godown.m54ce2e@example.com'),
        ('keeper.m54ce2e@example.com'),
        ('driver.m54ce2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m54ce2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m54ce2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m54ce2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m54ce2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M54C Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (godown_id, 'M54C Godown', true),
        (keeper_id, 'M54C Keeper', true),
        (driver_id, 'M54C Driver', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select map.user_id, r.id, admin_id
      from (values
        (godown_id, 'godown_manager'),
        (keeper_id, 'store_keeper'),
        (driver_id, 'delivery_person')
      ) as map(user_id, role_code)
      join public.roles r on r.code = map.role_code
      on conflict do nothing;

      insert into public.branches (code, name, is_active)
      values
        ('${PREFIX}_gd', '${fixture.godownName}', true),
        ('${PREFIX}_ot', '${fixture.otherGodownName}', true),
        ('${PREFIX}_dd', '${fixture.inactiveGodownName}', false);

      select id into branch_id from public.branches where code = '${PREFIX}_gd';
      select id into other_id from public.branches where code = '${PREFIX}_ot';
      select id into dead_id from public.branches where code = '${PREFIX}_dd';

      insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
      select x.uid, branch_id, admin_id
      from (values (godown_id), (keeper_id), (driver_id), (admin_id)) as x(uid)
      on conflict do nothing;
      insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
      values (godown_id, dead_id, admin_id)
      on conflict do nothing;

      insert into public.zones (branch_id, code, name, is_active)
      values (branch_id, '${PREFIX}_z', 'M54C Zone', true)
      returning id into zone_id;
      insert into public.zones (branch_id, code, name, is_active, location_role)
      values (branch_id, '${PREFIX}_qrn', 'Quarantine', true, 'quarantine')
      returning id into qzone;
      insert into public.zones (branch_id, code, name, is_active)
      values (other_id, '${PREFIX}_zo', 'Other Zone', true)
      returning id into other_zone;
      insert into public.zones (branch_id, code, name, is_active)
      values (dead_id, '${PREFIX}_zd', 'Dead Zone', true)
      returning id into dead_zone;

      insert into public.crates (zone_id, code, name, is_active)
      values (zone_id, '${PREFIX}_c', 'M54C Crate', true)
      returning id into crate_id;
      insert into public.crates (zone_id, code, name, is_active, location_role)
      values (qzone, '${PREFIX}_qc', 'Quarantine crate', true, 'quarantine')
      returning id into qcrate;
      insert into public.crates (zone_id, code, name, is_active)
      values (other_zone, '${PREFIX}_co', 'Other Crate', true)
      returning id into other_crate;
      insert into public.crates (zone_id, code, name, is_active)
      values (dead_zone, '${PREFIX}_cd', 'Dead Crate', true)
      returning id into dead_crate;

      insert into public.products (sku, name, is_active)
      values ('${PREFIX}_sku', 'M54C Product', true)
      returning id into product_id;
      insert into public.shops (name, is_active)
      values ('M54C Shop ${RUN}', true)
      returning id into shop_id;
      insert into public.stock_balances (crate_id, product_id, quantity)
      values (crate_id, product_id, 6), (dead_crate, product_id, 2);

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes, shop_id
      ) values (
        '${PREFIX}-SR', 'shop_return', branch_id, 'draft', 1, godown_id,
        '${PREFIX}-sr-key', '${PREFIX}-sr-fp', 'custody e2e', shop_id
      ) returning id into sr_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      ) values (sr_id, product_id, crate_id, 2, 'expired');

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-XF', 'storage', branch_id, 'verified', 1, godown_id,
        godown_id, now(), '${PREFIX}-xf-key', '${PREFIX}-xf-fp', 'transfer e2e'
      ) returning id into xfer_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      ) values (xfer_id, product_id, crate_id, 2, 'crushed')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id,
        quantity_cases, hold_kind, status
      ) values (xfer_id, line_id, product_id, crate_id, 2, 'on_hand_deduction', 'active');

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes, shop_id
      ) values (
        '${PREFIX}-RJ', 'shop_return', branch_id, 'rejected', 2, godown_id,
        '${PREFIX}-rj-key', '${PREFIX}-rj-fp', 'rejected still quarantined', shop_id
      ) returning id into rej_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      ) values (rej_id, product_id, qcrate, 2, 'expired')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id,
        quantity_cases, hold_kind, status
      ) values (rej_id, line_id, product_id, qcrate, 2, 'quarantine_intake', 'active');

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-DD', 'storage', dead_id, 'verified', 1, godown_id,
        godown_id, now(), '${PREFIX}-dd-key', '${PREFIX}-dd-fp', 'inactive transfer'
      ) returning id into dead_report;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      ) values (dead_report, product_id, dead_crate, 1, 'crushed')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id,
        quantity_cases, hold_kind, status
      ) values (dead_report, line_id, product_id, dead_crate, 1, 'on_hand_deduction', 'active');

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-OT', 'storage', other_id, 'verified', 1, admin_id,
        admin_id, now(), '${PREFIX}-ot-key', '${PREFIX}-ot-fp', 'other godown'
      );
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      )
      select id, product_id, other_crate, 4, 'crushed'
      from public.damage_reports where report_number = '${PREFIX}-OT';
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id,
        quantity_cases, hold_kind, status
      )
      select damage_reports.id, damage_report_lines.id, damage_report_lines.product_id, other_crate,
        4, 'on_hand_deduction', 'active'
      from public.damage_reports
      join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
      where damage_reports.report_number = '${PREFIX}-OT';

    end $$;
    set session_replication_role = origin;

    select
      (select id::text from public.damage_reports where report_number = '${PREFIX}-SR') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-XF') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-RJ') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-DD');
    `,
    "m54c fixtures",
  )
  const ids = lastLine(created).split("|")
  fixture.shopReturnId = ids[0] ?? ""
  fixture.transferId = ids[1] ?? ""
  fixture.rejectedId = ids[2] ?? ""
  fixture.inactiveId = ids[3] ?? ""
  fixture.shopReturnNumber = `${PREFIX}-SR`
  fixture.transferNumber = `${PREFIX}-XF`
  fixture.rejectedNumber = `${PREFIX}-RJ`
  fixture.logicalHoldNumber = `${PREFIX}-XF`
})

test("authorized GM views and confirms shop-return custody", async ({
  page,
}) => {
  await login(page, "godown.m54ce2e@example.com")
  await page.goto(`/damage/${fixture.shopReturnId}`)
  await expect(
    page.getByRole("heading", { name: fixture.shopReturnNumber }),
  ).toBeVisible()
  await expect(page.getByText("Shop-return custody")).toBeVisible()
  await expect(page.getByText("Custody outstanding")).toBeVisible()
  await page.getByRole("button", { name: /confirm physical custody/i }).click()
  await expect(page.getByText(/does not submit the report/i)).toBeVisible()
  await page
    .getByRole("button", { name: /confirm physical custody now/i })
    .click()
  await expect(page.getByText("Custody confirmed").first()).toBeVisible()
  await page.reload()
  await expect(page.getByText("Custody confirmed").first()).toBeVisible()
  await expect(
    page.getByRole("button", { name: /confirm physical custody$/i }),
  ).toHaveCount(0)
})

test("store keeper cannot confirm custody", async ({ page }) => {
  await login(page, "keeper.m54ce2e@example.com")
  await page.goto(`/damage/${fixture.shopReturnId}`)
  await expect(page.getByText("Shop-return custody")).toBeVisible()
  await expect(
    page.getByRole("button", { name: /confirm physical custody/i }),
  ).toHaveCount(0)
})

test("delivery person cannot open quarantine inventory", async ({ page }) => {
  await login(page, "driver.m54ce2e@example.com")
  await page.goto("/damage/quarantine")
  await expect(
    page.getByText("You do not have access to this page"),
  ).toBeVisible({ timeout: 15_000 })
})

test("quarantine list respects godown scope and hold labels", async ({
  page,
}) => {
  await login(page, "godown.m54ce2e@example.com")
  await page.goto("/damage/quarantine")
  await expect(
    page.getByRole("heading", { name: /quarantine inventory/i }),
  ).toBeVisible()
  await expect(page.getByText(fixture.rejectedNumber)).toBeVisible()
  await expect(
    page.locator("td", { hasText: /shop-return quarantine intake/i }).first(),
  ).toBeVisible()
  await expect(
    page.locator("td", { hasText: /logical on-hand isolation/i }).first(),
  ).toBeVisible()
  await expect(page.getByText(`${PREFIX}-OT`)).toHaveCount(0)
})

test("verified transfer works and inactive godown transfer is denied", async ({
  page,
}) => {
  await login(page, "godown.m54ce2e@example.com")
  await page.goto(`/damage/${fixture.transferId}`)
  await page
    .getByRole("button", { name: /transfer verified damage to quarantine/i })
    .click()
  await page.getByRole("button", { name: /post quarantine transfer/i }).click()
  await expect(page.getByText("Quarantined").first()).toBeVisible()
  await expect(page.getByText(/physically segregated/i)).toBeVisible()

  await page.goto(`/damage/${fixture.inactiveId}`)
  await expect(page.getByRole("alert")).toBeVisible()
  await expect(page.getByRole("alert")).toContainText(
    /not authorized|permission|inactive/i,
  )
})

test("rejected shop-return remains quarantined and readiness stays false", async ({
  page,
}) => {
  await login(page, "godown.m54ce2e@example.com")
  await page.goto(`/damage/${fixture.rejectedId}`)
  await expect(
    page.getByText(/quarantined stock remains unavailable/i),
  ).toBeVisible()
  await page.goto("/damage")
  await expect(page.getByText("Damage stock isolation not ready")).toBeVisible()
  await page.goto("/damage/new")
  await page
    .locator("#damage-godown")
    .selectOption({ label: fixture.godownName })
  await page
    .locator('input[name="damage-scenario"][value="shop_return"]')
    .check()
  await expect(
    page.getByText(/submission stays blocked until isolation is ready/i),
  ).toBeVisible()
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    delete from public.damage_stock_holds
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.damage_report_events
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.stock_ledger
    where product_id in (select id from public.products where sku like '${PREFIX}_%');
    delete from public.stock_transactions
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.damage_report_lines
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.damage_reports where report_number like '${PREFIX}-%';
    delete from public.stock_balances
    where product_id in (select id from public.products where sku like '${PREFIX}_%')
       or crate_id in (select id from public.crates where code like '${PREFIX}_%');
    delete from public.crates where code like '${PREFIX}_%';
    delete from public.zones where code like '${PREFIX}_%';
    delete from public.user_branch_assignments
    where branch_id in (
      select id from public.branches where code like '${PREFIX}_%'
    );
    delete from public.branches where code like '${PREFIX}_%';
    delete from public.products where sku like '${PREFIX}_%';
    delete from public.shops where name like 'M54C Shop ${RUN}%';
    set session_replication_role = origin;
    `,
    "cleanup m5.4c fixtures",
  )
})
