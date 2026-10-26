import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m54ee2e"
const RUN = Date.now().toString(36)
const PREFIX = `m54e_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  godownName: `M54E Godown ${RUN}`,
  destroyId: "",
  destroyNumber: "",
  supplierId: "",
  supplierNumber: "",
  shopReturnId: "",
  shopReturnNumber: "",
  writeoffId: "",
  writeoffNumber: "",
  staleId: "",
  staleNumber: "",
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
  if ((await page.getByLabel(/email/i).count()) === 0) {
    await page.getByRole("button", { name: "Account menu" }).click()
    await page.getByRole("menuitem", { name: "Sign out" }).click()
    await expect(page.getByLabel(/email/i)).toBeVisible({ timeout: 20_000 })
  }
  await page.getByLabel(/email/i).fill(email)
  await page.getByLabel(/password/i).fill(password)
  await page.getByRole("button", { name: /sign in/i }).click()
  await expect(
    page.getByRole("heading", {
      name: /operations overview|damage management|exceptional approvals/i,
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
      zone_id uuid;
      crate_id uuid;
      qzone_id uuid;
      qcrate_id uuid;
      product_id uuid;
      shop_id uuid;
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
        ('admin.m54ee2e@example.com'),
        ('godown.m54ee2e@example.com'),
        ('keeper.m54ee2e@example.com'),
        ('driver.m54ee2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m54ee2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m54ee2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m54ee2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m54ee2e@example.com';

      insert into public.profiles (id, full_name, is_active) values
        (admin_id, 'M54E Admin', true),
        (godown_id, 'M54E Godown', true),
        (keeper_id, 'M54E Keeper', true),
        (driver_id, 'M54E Driver', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select admin_id, roles.id, admin_id from public.roles where code = 'admin'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select godown_id, roles.id, admin_id from public.roles where code = 'godown_manager'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select keeper_id, roles.id, admin_id from public.roles where code = 'store_keeper'
      on conflict do nothing;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select driver_id, roles.id, admin_id from public.roles where code = 'delivery_person'
      on conflict do nothing;

      insert into public.branches (code, name, is_active)
      values ('${PREFIX}_gd', '${fixture.godownName}', true)
      returning id into branch_id;
      insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
      values
        (admin_id, branch_id, admin_id),
        (godown_id, branch_id, admin_id),
        (keeper_id, branch_id, admin_id),
        (driver_id, branch_id, admin_id)
      on conflict do nothing;
      insert into public.zones (branch_id, code, name, is_active)
      values (branch_id, '${PREFIX}_z', 'Z', true)
      returning id into zone_id;
      insert into public.crates (zone_id, code, name, is_active)
      values (zone_id, '${PREFIX}_c', 'C', true)
      returning id into crate_id;
      insert into public.zones (branch_id, code, name, is_active)
      values (branch_id, '${PREFIX}_q', 'Q', true)
      returning id into qzone_id;
      insert into public.crates (zone_id, code, name, is_active)
      values (qzone_id, '${PREFIX}_qc', 'QC', true)
      returning id into qcrate_id;
      insert into public.products (sku, name, is_active)
      values ('${PREFIX}_sku', 'M54E E2E Soap', true)
      returning id into product_id;
      insert into public.shops (name, is_active)
      values ('M54E E2E Shop ${RUN}', true)
      returning id into shop_id;
    end $$;
    set session_replication_role = origin;

    do $$
    declare
      admin_id uuid;
      crate_id uuid;
      qcrate_id uuid;
      product_id uuid;
    begin
      select id into admin_id from auth.users where email = 'admin.m54ee2e@example.com';
      select id into crate_id from public.crates where code = '${PREFIX}_c';
      select id into qcrate_id from public.crates where code = '${PREFIX}_qc';
      select id into product_id from public.products where sku = '${PREFIX}_sku';
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      perform public.post_opening_stock(
        product_id, crate_id, 30, '${PREFIX}-open', 'M54E E2E opening'
      );
      perform public.post_opening_stock(
        product_id, qcrate_id, 10, '${PREFIX}-open-q', 'M54E E2E quarantine opening'
      );
    end $$;
    set session_replication_role = replica;
    update public.zones set location_role = 'quarantine' where code = '${PREFIX}_q';
    update public.crates set location_role = 'quarantine' where code = '${PREFIX}_qc';
    set session_replication_role = origin;

    set session_replication_role = replica;
    do $$
    declare
      admin_id uuid;
      gm_user_id uuid;
      branch_id uuid;
      crate_id uuid;
      qcrate_id uuid;
      product_id uuid;
      shop_id uuid;
      des_id uuid;
      sup_id uuid;
      sr_id uuid;
      wo_id uuid;
      st_id uuid;
      line_id uuid;
      req_id uuid;
    begin
      select id into admin_id from auth.users where email = 'admin.m54ee2e@example.com';
      select id into gm_user_id from auth.users where email = 'godown.m54ee2e@example.com';
      select id into branch_id from public.branches where code = '${PREFIX}_gd';
      select id into crate_id from public.crates where code = '${PREFIX}_c';
      select id into qcrate_id from public.crates where code = '${PREFIX}_qc';
      select id into product_id from public.products where sku = '${PREFIX}_sku';
      select id into shop_id from public.shops where name = 'M54E E2E Shop ${RUN}';

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values
        ('${PREFIX}-DES', 'storage', branch_id, 'verified', 3, gm_user_id, gm_user_id, now(),
          '${PREFIX}-des-key', '${PREFIX}-des-fp', 'destroy me'),
        ('${PREFIX}-SUP', 'storage', branch_id, 'verified', 3, gm_user_id, gm_user_id, now(),
          '${PREFIX}-sup-key', '${PREFIX}-sup-fp', 'return me'),
        ('${PREFIX}-WO', 'storage', branch_id, 'verified', 3, gm_user_id, gm_user_id, now(),
          '${PREFIX}-wo-key', '${PREFIX}-wo-fp', 'ordinary'),
        ('${PREFIX}-ST', 'storage', branch_id, 'verified', 3, gm_user_id, gm_user_id, now(),
          '${PREFIX}-st-key', '${PREFIX}-st-fp', 'stale');
      select id into des_id from public.damage_reports where report_number = '${PREFIX}-DES';
      select id into sup_id from public.damage_reports where report_number = '${PREFIX}-SUP';
      select id into wo_id from public.damage_reports where report_number = '${PREFIX}-WO';
      select id into st_id from public.damage_reports where report_number = '${PREFIX}-ST';

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes, shop_id,
        rejected_at, rejected_by, rejection_reason
      ) values (
        '${PREFIX}-SR', 'shop_return', branch_id, 'rejected', 3, gm_user_id,
        '${PREFIX}-sr-key', '${PREFIX}-sr-fp', 'rejected shop return', shop_id,
        now(), gm_user_id, 'not accepted'
      ) returning id into sr_id;

      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      )
      select damage_reports.id, product_id,
        case when report_number = '${PREFIX}-SR' then qcrate_id else crate_id end,
        2, 'crushed'
      from public.damage_reports
      where report_number in (
        '${PREFIX}-DES', '${PREFIX}-SUP', '${PREFIX}-WO', '${PREFIX}-ST', '${PREFIX}-SR'
      );

      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id,
        quantity_cases, hold_kind, status
      )
      select damage_reports.id, damage_report_lines.id, damage_report_lines.product_id,
        damage_report_lines.crate_id,
        2,
        case when damage_reports.scenario = 'shop_return' then 'quarantine_intake' else 'on_hand_deduction' end,
        'active'
      from public.damage_reports
      join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
      where damage_reports.report_number in (
        '${PREFIX}-DES', '${PREFIX}-SUP', '${PREFIX}-WO', '${PREFIX}-ST', '${PREFIX}-SR'
      );

      insert into public.damage_evidence (
        damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
      )
      select damage_reports.id, damage_reports.id::text || '/' || gen_random_uuid()::text,
        gm_user_id, 'image/jpeg', 4, now()
      from public.damage_reports
      where report_number in (
        '${PREFIX}-DES', '${PREFIX}-SUP', '${PREFIX}-WO', '${PREFIX}-ST', '${PREFIX}-SR'
      );

      insert into public.damage_exceptional_requests (
        damage_report_id, disposition_kind, status, request_reason,
        requested_by, request_idempotency_key, decided_by, decided_at
      )
      values (
        st_id, 'destroy', 'approved', 'stale execute', gm_user_id, '${PREFIX}-st-req',
        admin_id, now()
      )
      returning id into req_id;
    end $$;
    set session_replication_role = origin;

    select id from public.damage_reports where report_number = '${PREFIX}-DES';
    select id from public.damage_reports where report_number = '${PREFIX}-SUP';
    select id from public.damage_reports where report_number = '${PREFIX}-SR';
    select id from public.damage_reports where report_number = '${PREFIX}-WO';
    select id from public.damage_reports where report_number = '${PREFIX}-ST';
    `,
    "seed m5.4e fixtures",
  )
  const ids = created
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) =>
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        line,
      ),
    )
  fixture.destroyId = ids.at(-5) ?? ""
  fixture.supplierId = ids.at(-4) ?? ""
  fixture.shopReturnId = ids.at(-3) ?? ""
  fixture.writeoffId = ids.at(-2) ?? ""
  fixture.staleId = ids.at(-1) ?? ""
  fixture.destroyNumber = `${PREFIX}-DES`
  fixture.supplierNumber = `${PREFIX}-SUP`
  fixture.shopReturnNumber = `${PREFIX}-SR`
  fixture.writeoffNumber = `${PREFIX}-WO`
  fixture.staleNumber = `${PREFIX}-ST`
  if (!fixture.destroyId || !fixture.staleId) {
    throw new Error(`m5.4e e2e seed missing ids ${created}`)
  }
})

test("GM requests destroy and cannot duplicate the open request", async ({
  page,
}) => {
  await login(page, "godown.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.destroyId}`)
  await expect(
    page.getByRole("heading", { name: "Exceptional disposition" }),
  ).toBeVisible()
  await page
    .getByRole("button", { name: /request exceptional disposition/i })
    .click()
  await page.getByLabel("Exceptional disposition kind").selectOption("destroy")
  await page.getByLabel("Exceptional request reason").fill("destroy crushed soap")
  await page.getByRole("button", { name: /confirm exceptional request/i }).click()
  await expect(page.getByText("Requested").first()).toBeVisible()
  await expect(
    page.getByRole("button", { name: /request exceptional disposition/i }),
  ).toBeDisabled()
})

test("Admin reviews the queue and approves destroy", async ({ page }) => {
  await login(page, "admin.m54ee2e@example.com")
  await page.goto("/damage/exceptional")
  await expect(
    page.getByRole("heading", { name: /exceptional approvals/i }),
  ).toBeVisible()
  await page.getByLabel("Search exceptional requests").fill(fixture.destroyNumber)
  await expect(
    page.getByRole("link", { name: fixture.destroyNumber }).first(),
  ).toBeVisible()
  await page.getByRole("link", { name: "Inspect" }).first().click()
  await expect(page.getByRole("heading", { name: "Admin review" })).toBeVisible()
  await page.getByRole("button", { name: /^approve$/i }).click()
  await page.getByRole("button", { name: /confirm exceptional approval/i }).click()
  await expect(
    page.getByText("Approved — pending execution").first(),
  ).toBeVisible()
})

test("authorized GM executes destroy", async ({ page }) => {
  await login(page, "godown.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.destroyId}`)
  await expect(
    page.getByRole("heading", { name: "Execute disposition" }),
  ).toBeVisible()
  await page.getByRole("button", { name: /execute destroy/i }).click()
  await expect(page.getByText(/ADJUSTMENT/)).toBeVisible()
  await page.getByRole("button", { name: /confirm exceptional execution/i }).click()
  await expect(page.getByText("Posted — ledger complete").first()).toBeVisible()
  await expect(page.getByText("Written off").first()).toBeVisible()
})

test("supplier-return request, approval, and execution", async ({ page }) => {
  await login(page, "godown.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.supplierId}`)
  await page
    .getByRole("button", { name: /request exceptional disposition/i })
    .click()
  await page
    .getByLabel("Exceptional disposition kind")
    .selectOption("return_supplier")
  await page.getByLabel("Exceptional request reason").fill("return crushed soap")
  await page.getByRole("button", { name: /confirm exceptional request/i }).click()
  await expect(page.getByText("Requested").first()).toBeVisible()

  await login(page, "admin.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.supplierId}`)
  await page.getByRole("button", { name: /^approve$/i }).click()
  await page.getByRole("button", { name: /confirm exceptional approval/i }).click()
  await expect(
    page.getByText("Approved — pending execution").first(),
  ).toBeVisible()

  await login(page, "godown.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.supplierId}`)
  await page.getByRole("button", { name: /execute return to supplier/i }).click()
  await page.getByRole("button", { name: /confirm exceptional execution/i }).click()
  await expect(page.getByText("Returned to supplier").first()).toBeVisible()
})

test("rejected shop-return quarantine can be destroyed", async ({ page }) => {
  await login(page, "godown.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.shopReturnId}`)
  await expect(
    page.getByText(/quarantined stock remains unavailable/i),
  ).toBeVisible()
  await page
    .getByRole("button", { name: /request exceptional disposition/i })
    .click()
  await page.getByLabel("Exceptional disposition kind").selectOption("destroy")
  await page
    .getByLabel("Exceptional request reason")
    .fill("destroy rejected return")
  await page.getByRole("button", { name: /confirm exceptional request/i }).click()

  await login(page, "admin.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.shopReturnId}`)
  await page.getByRole("button", { name: /^approve$/i }).click()
  await page.getByRole("button", { name: /confirm exceptional approval/i }).click()

  await login(page, "godown.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.shopReturnId}`)
  await page.getByRole("button", { name: /execute destroy/i }).click()
  await page.getByRole("button", { name: /confirm exceptional execution/i }).click()
  await expect(page.getByText("Posted — ledger complete").first()).toBeVisible()
})

test("stale-version execution recovers after refresh", async ({ page }) => {
  await login(page, "godown.m54ee2e@example.com")
  await page.goto(`/damage/${fixture.staleId}`)
  await page.getByRole("button", { name: /execute destroy/i }).click()
  runLocalSql(
    `
    set session_replication_role = replica;
    update public.damage_exceptional_requests
    set version = version + 1
    where request_idempotency_key = '${PREFIX}-st-req';
    set session_replication_role = origin;
    `,
    "bump stale request version",
  )
  await page.getByRole("button", { name: /confirm exceptional execution/i }).click()
  await expect(
    page.getByText(/this record changed|refresh/i).first(),
  ).toBeVisible()
  await page.reload()
  await page.getByRole("button", { name: /execute destroy/i }).click()
  await page.getByRole("button", { name: /confirm exceptional execution/i }).click()
  await expect(page.getByText("Posted — ledger complete").first()).toBeVisible()
})

test("store keeper cannot open the exceptional queue", async ({ page }) => {
  await login(page, "keeper.m54ee2e@example.com")
  await page.goto("/damage/exceptional")
  await expect(
    page.getByText("You do not have access to this page"),
  ).toBeVisible({ timeout: 15_000 })
  await page.goto(`/damage/${fixture.destroyId}`)
  await expect(
    page.getByRole("button", { name: /request exceptional disposition/i }),
  ).toHaveCount(0)
  await expect(
    page.getByRole("button", { name: /execute destroy/i }),
  ).toHaveCount(0)
})

test("delivery person cannot open the exceptional queue", async ({ page }) => {
  await login(page, "driver.m54ee2e@example.com")
  await page.goto("/damage/exceptional")
  await expect(
    page.getByText("You do not have access to this page"),
  ).toBeVisible({ timeout: 15_000 })
})

test("quarantine totals and ordinary write-off remain intact", async ({
  page,
}) => {
  await login(page, "godown.m54ee2e@example.com")
  await page.goto("/damage/quarantine")
  await expect(
    page.getByRole("heading", { name: /quarantine inventory/i }),
  ).toBeVisible()
  await page.goto(`/damage/${fixture.writeoffId}`)
  await expect(
    page.getByRole("heading", { name: "Ordinary write-off" }),
  ).toBeVisible()
  await page.getByRole("button", { name: /post ordinary write-off/i }).click()
  await page.getByRole("button", { name: /confirm ordinary write-off/i }).click()
  await expect(page.getByText("Written off").first()).toBeVisible()
  await page.goto("/damage")
  await expect(page.getByText("Damage stock isolation not ready")).toBeVisible()
  await expect(page.getByText("Ordinary write-off cases")).toBeVisible()
  await expect(page.getByText("Exceptional write-off cases")).toBeVisible()
  await expect(page.getByText("Returned to supplier")).toBeVisible()
  await page.goto("/damage/quarantine")
  await expect(
    page.getByText("Returned to supplier (not current)"),
  ).toBeVisible()
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    delete from public.damage_evidence
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.damage_stock_holds
    where damage_report_id in (
      select id from public.damage_reports where report_number like '${PREFIX}-%'
    );
    delete from public.damage_exceptional_requests
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
    where branch_id in (select id from public.branches where code like '${PREFIX}_%');
    delete from public.branches where code like '${PREFIX}_%';
    delete from public.products where sku like '${PREFIX}_%';
    delete from public.shops where name like 'M54E E2E Shop ${RUN}';
    set session_replication_role = origin;
    `,
    "cleanup m5.4e fixtures",
  )
})
