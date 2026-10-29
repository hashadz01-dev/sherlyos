import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m54de2e"
const RUN = Date.now().toString(36)
const PREFIX = `m54d_${RUN}`

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  godownName: `M54D Godown ${RUN}`,
  inboundId: "",
  inboundNumber: "",
  noEvidenceId: "",
  noEvidenceNumber: "",
  selfId: "",
  selfNumber: "",
  returnId: "",
  returnNumber: "",
  rejectId: "",
  rejectNumber: "",
  writeoffId: "",
  writeoffNumber: "",
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
      name: /operations overview|damage management|damage verification/i,
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
      product_id uuid;
      inbound uuid;
      noev uuid;
      self_id uuid;
      ret_id uuid;
      rej_id uuid;
      wo_id uuid;
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
        ('admin.m54de2e@example.com'),
        ('godown.m54de2e@example.com'),
        ('keeper.m54de2e@example.com'),
        ('driver.m54de2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m54de2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m54de2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m54de2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m54de2e@example.com';

      insert into public.profiles (id, full_name, is_active) values
        (admin_id, 'M54D Admin', true),
        (godown_id, 'M54D Godown', true),
        (keeper_id, 'M54D Keeper', true),
        (driver_id, 'M54D Driver', true)
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
      insert into public.products (sku, name, is_active)
      values ('${PREFIX}_sku', 'M54D E2E Soap', true)
      returning id into product_id;
    end $$;
    set session_replication_role = origin;

    do $$
    declare
      admin_id uuid;
      crate_id uuid;
      product_id uuid;
    begin
      select id into admin_id from auth.users where email = 'admin.m54de2e@example.com';
      select id into crate_id from public.crates where code = '${PREFIX}_c';
      select id into product_id from public.products where sku = '${PREFIX}_sku';
      perform set_config('request.jwt.claim.sub', admin_id::text, true);
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
        true
      );
      -- Classify before opening stock so dual-write left on by another spec cannot fail closed.
      perform public.set_product_expiry_policy(product_id, 'expiry_controlled');
      if app_private.stock_lots_dual_write_enabled() then
        perform public.post_opening_stock(
          product_id, crate_id, 20, '${PREFIX}-open', 'M54D E2E opening',
          '${PREFIX}-LOT', null, '2028-06-01'
        );
      else
        perform public.post_opening_stock(
          product_id, crate_id, 20, '${PREFIX}-open', 'M54D E2E opening'
        );
      end if;
    end $$;

    set session_replication_role = replica;
    do $$
    declare
      admin_id uuid;
      godown_id uuid;
      keeper_id uuid;
      branch_id uuid;
      crate_id uuid;
      product_id uuid;
      inbound uuid;
      noev uuid;
      self_id uuid;
      ret_id uuid;
      rej_id uuid;
      wo_id uuid;
      line_id uuid;
    begin
      select id into admin_id from auth.users where email = 'admin.m54de2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m54de2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m54de2e@example.com';
      select id into branch_id from public.branches where code = '${PREFIX}_gd';
      select id into crate_id from public.crates where code = '${PREFIX}_c';
      select id into product_id from public.products where sku = '${PREFIX}_sku';

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-IN', 'refill_supply', branch_id, 'submitted', 2, keeper_id,
        '${PREFIX}-in-key', '${PREFIX}-in-fp', 'verify me'
      ) returning id into inbound;
      insert into public.damage_report_lines (damage_report_id, product_id, quantity_cases, damage_reason)
      values (inbound, product_id, 2, 'crushed');
      insert into public.damage_evidence (
        damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
      ) values (inbound, inbound::text || '/' || gen_random_uuid()::text, keeper_id, 'image/jpeg', 4, now());

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-NE', 'refill_supply', branch_id, 'submitted', 2, keeper_id,
        '${PREFIX}-ne-key', '${PREFIX}-ne-fp', 'no evidence'
      ) returning id into noev;
      insert into public.damage_report_lines (damage_report_id, product_id, quantity_cases, damage_reason)
      values (noev, product_id, 1, 'wet');

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-SF', 'refill_supply', branch_id, 'submitted', 2, godown_id,
        '${PREFIX}-sf-key', '${PREFIX}-sf-fp', 'self verify'
      ) returning id into self_id;
      insert into public.damage_report_lines (damage_report_id, product_id, quantity_cases, damage_reason)
      values (self_id, product_id, 1, 'wet');
      insert into public.damage_evidence (
        damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
      ) values (self_id, self_id::text || '/' || gen_random_uuid()::text, godown_id, 'image/jpeg', 4, now());

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-RT', 'refill_supply', branch_id, 'submitted', 2, keeper_id,
        '${PREFIX}-rt-key', '${PREFIX}-rt-fp', 'return me'
      ) returning id into ret_id;
      insert into public.damage_report_lines (damage_report_id, product_id, quantity_cases, damage_reason)
      values (ret_id, product_id, 1, 'wet');
      insert into public.damage_evidence (
        damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
      ) values (ret_id, ret_id::text || '/' || gen_random_uuid()::text, keeper_id, 'image/jpeg', 4, now());

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-RJ', 'refill_supply', branch_id, 'submitted', 2, keeper_id,
        '${PREFIX}-rj-key', '${PREFIX}-rj-fp', 'reject me'
      ) returning id into rej_id;
      insert into public.damage_report_lines (damage_report_id, product_id, quantity_cases, damage_reason)
      values (rej_id, product_id, 1, 'wet');
      insert into public.damage_evidence (
        damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
      ) values (rej_id, rej_id::text || '/' || gen_random_uuid()::text, keeper_id, 'image/jpeg', 4, now());

      insert into public.damage_reports (
        report_number, scenario, godown_id, status, version, reporter_user_id,
        verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
      ) values (
        '${PREFIX}-WO', 'storage', branch_id, 'verified', 3, keeper_id,
        godown_id, now(), '${PREFIX}-wo-key', '${PREFIX}-wo-fp', 'write off'
      ) returning id into wo_id;
      insert into public.damage_report_lines (
        damage_report_id, product_id, crate_id, quantity_cases, damage_reason
      ) values (wo_id, product_id, crate_id, 2, 'crushed')
      returning id into line_id;
      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id,
        quantity_cases, hold_kind, status
      ) values (wo_id, line_id, product_id, crate_id, 2, 'on_hand_deduction', 'active');
      insert into public.damage_evidence (
        damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
      ) values (wo_id, wo_id::text || '/' || gen_random_uuid()::text, keeper_id, 'image/jpeg', 4, now());
    end $$;
    set session_replication_role = origin;

    select
      (select id::text from public.damage_reports where report_number = '${PREFIX}-IN') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-NE') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-SF') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-RT') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-RJ') || '|' ||
      (select id::text from public.damage_reports where report_number = '${PREFIX}-WO');
    `,
    "m54d fixtures",
  )
  const ids = lastLine(created).split("|")
  fixture.inboundId = ids[0] ?? ""
  fixture.noEvidenceId = ids[1] ?? ""
  fixture.selfId = ids[2] ?? ""
  fixture.returnId = ids[3] ?? ""
  fixture.rejectId = ids[4] ?? ""
  fixture.writeoffId = ids[5] ?? ""
  fixture.inboundNumber = `${PREFIX}-IN`
  fixture.noEvidenceNumber = `${PREFIX}-NE`
  fixture.selfNumber = `${PREFIX}-SF`
  fixture.returnNumber = `${PREFIX}-RT`
  fixture.rejectNumber = `${PREFIX}-RJ`
  fixture.writeoffNumber = `${PREFIX}-WO`
})

test("GM opens verification queue and inspects a report", async ({ page }) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto("/damage/verification")
  await expect(
    page.getByRole("heading", { name: /damage verification/i }),
  ).toBeVisible()
  await expect(page.getByText("Damage stock isolation not ready")).toBeVisible()
  await expect(
    page.getByRole("link", { name: fixture.inboundNumber }),
  ).toBeVisible()
  await page.getByRole("link", { name: fixture.inboundNumber }).click()
  await expect(
    page.getByRole("heading", { name: "Godown verification" }),
  ).toBeVisible()
})

test("missing evidence blocks verification", async ({ page }) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto(`/damage/${fixture.noEvidenceId}`)
  await expect(
    page.getByText("Finalized photographic evidence is required.").first(),
  ).toBeVisible()
  await expect(page.getByRole("button", { name: /^verify$/i })).toBeDisabled()
})

test("reporter cannot self-verify", async ({ page }) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto(`/damage/${fixture.selfId}`)
  await expect(
    page.getByText("The reporter cannot verify this damage report.").first(),
  ).toBeVisible()
  await expect(page.getByRole("button", { name: /^verify$/i })).toBeDisabled()
})

test("authorized verification succeeds", async ({ page }) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto(`/damage/${fixture.inboundId}`)
  await page.getByRole("button", { name: /^verify$/i }).click()
  await expect(
    page.getByRole("button", { name: /confirm damage verification/i }),
  ).toBeVisible()
  await page
    .getByRole("button", { name: /confirm damage verification/i })
    .click()
  await expect(page.getByText("Verified").first()).toBeVisible()
  await page.reload()
  await expect(page.getByText("Verified").first()).toBeVisible()
})

test("return workflow", async ({ page }) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto(`/damage/${fixture.returnId}`)
  await page.getByRole("button", { name: /return for correction/i }).click()
  await page.getByLabel("Decision reason").fill("need clearer photos")
  await page
    .getByRole("button", { name: /confirm return for correction/i })
    .click()
  await expect(page.getByText(/returned/i).first()).toBeVisible()
})

test("rejection workflow", async ({ page }) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto(`/damage/${fixture.rejectId}`)
  await page.getByRole("button", { name: /^reject$/i }).click()
  await page.getByLabel("Decision reason").fill("not accepted")
  await page.getByRole("button", { name: /confirm damage rejection/i }).click()
  await expect(page.getByText(/rejected/i).first()).toBeVisible()
})

test("ordinary write-off confirmation and double-submit protection", async ({
  page,
}) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto(`/damage/${fixture.writeoffId}`)
  await expect(
    page.getByRole("heading", { name: "Ordinary write-off" }),
  ).toBeVisible()
  await page.getByRole("button", { name: /post ordinary write-off/i }).click()
  await expect(page.getByText(/ADJUSTMENT/)).toBeVisible()
  const confirm = page.getByRole("button", {
    name: /confirm ordinary write-off/i,
  })
  await confirm.click()
  await expect(page.getByText("Written off").first()).toBeVisible()
  await page.reload()
  await expect(page.getByText("Written off").first()).toBeVisible()
  await expect(
    page.getByRole("button", { name: /post ordinary write-off/i }),
  ).toBeDisabled()
  await expect(page.getByText("Ordinary write-off posted").first()).toBeVisible()
})

test("store keeper cannot open the verification queue", async ({ page }) => {
  await login(page, "keeper.m54de2e@example.com")
  await page.goto("/damage/verification")
  await expect(
    page.getByText("You do not have access to this page"),
  ).toBeVisible({ timeout: 15_000 })
  await page.goto(`/damage/${fixture.writeoffId}`)
  await expect(page.getByRole("button", { name: /^verify$/i })).toHaveCount(0)
  await expect(
    page.getByRole("button", { name: /post ordinary write-off/i }),
  ).toHaveCount(0)
})

test("delivery person cannot open the verification queue", async ({ page }) => {
  await login(page, "driver.m54de2e@example.com")
  await page.goto("/damage/verification")
  await expect(
    page.getByText("You do not have access to this page"),
  ).toBeVisible({ timeout: 15_000 })
})

test("readiness stays false and existing damage screens still load", async ({
  page,
}) => {
  await login(page, "godown.m54de2e@example.com")
  await page.goto("/damage")
  await expect(page.getByText("Damage stock isolation not ready")).toBeVisible()
  await page.goto("/damage/reports")
  await expect(
    page.getByRole("heading", { name: /damage reports/i }),
  ).toBeVisible()
  await page.goto("/damage/quarantine")
  await expect(
    page.getByRole("heading", { name: /quarantine inventory/i }),
  ).toBeVisible()
  await page.goto("/damage/new")
  await expect(
    page.getByRole("heading", { name: /new damage report/i }),
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
    set session_replication_role = origin;
    `,
    "cleanup m5.4d fixtures",
  )
})
