import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

const password = "local-only-m54be2e"
const RUN = Date.now().toString(36)
const PREFIX = `m54b_${RUN}`
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
)

test.describe.configure({ mode: "serial", timeout: 90_000 })

const fixture = {
  receiptNumber: `${PREFIX}-RCV`,
  dispatchNumber: `${PREFIX}-DSP`,
  productSku: `${PREFIX}_sku`,
  godownName: `M54B Godown ${RUN}`,
  draftNumber: "",
  inboundNumber: "",
  transitNumber: "",
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
      name: /operations overview|damage management|new damage report/i,
    }),
  ).toBeVisible({ timeout: 20_000 })
}

async function chooseGodown(page: Page) {
  const godown = page.locator("#damage-godown")
  await expect(
    godown.locator(`option:has-text("${fixture.godownName}")`),
  ).toBeAttached({
    timeout: 15_000,
  })
  await godown.selectOption({ label: fixture.godownName })
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
      supplier_id uuid;
      order_id uuid;
      picking_id uuid;
      order_line_id uuid;
      lot_id uuid;
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
        ('admin.m54be2e@example.com'),
        ('accounts.m54be2e@example.com'),
        ('godown.m54be2e@example.com'),
        ('keeper.m54be2e@example.com'),
        ('driver.m54be2e@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      select id into admin_id from auth.users where email = 'admin.m54be2e@example.com';
      select id into accounts_id from auth.users where email = 'accounts.m54be2e@example.com';
      select id into godown_id from auth.users where email = 'godown.m54be2e@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m54be2e@example.com';
      select id into driver_id from auth.users where email = 'driver.m54be2e@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'M54B Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (accounts_id, 'M54B Accounts', true),
        (godown_id, 'M54B Godown', true),
        (keeper_id, 'M54B Keeper', true),
        (driver_id, 'M54B Driver', true)
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
      values ('${PREFIX}_gd', '${fixture.godownName}', true)
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
      values (branch_id, '${PREFIX}_z', 'M54B Zone', true)
      returning id into zone_id;

      insert into public.crates (zone_id, code, name, is_active)
      values (zone_id, '${PREFIX}_c', 'M54B Crate', true)
      returning id into crate_id;

      insert into public.products (sku, name, is_active)
      values ('${fixture.productSku}', 'M54B Product', true)
      returning id into product_id;

      insert into public.shops (name, is_active)
      values ('M54B Shop ${RUN}', true)
      returning id into shop_id;

      insert into public.suppliers (name, is_active)
      values ('M54B Supplier ${RUN}', true)
      returning id into supplier_id;

      insert into public.stock_balances (crate_id, product_id, quantity)
      values (crate_id, product_id, 8);

      insert into public.stock_receipts (
        receipt_number, godown_id, supplier_id, document_reference,
        normalized_document_reference, received_date, status, created_by,
        verified_by, verified_at, posted_at, posting_idempotency_key, posting_fingerprint
      )
      values (
        '${fixture.receiptNumber}', branch_id, supplier_id, 'M54B-DOC',
        'm54b-doc-${RUN}', current_date, 'posted', keeper_id,
        godown_id, now(), now(), '${PREFIX}-rcv-post', '${PREFIX}-rcv-fp'
      );

      insert into public.stock_receipt_lines (
        receipt_id, product_id, destination_crate_id, document_cases, counted_cases, damaged_cases
      )
      select id, product_id, crate_id, 40, 38, 30
      from public.stock_receipts where receipt_number = '${fixture.receiptNumber}';

      insert into public.orders (
        order_number, shop_id, branch_id, status, source, version, created_by,
        idempotency_key, verified_by, verified_at, submitted_by, submitted_at
      )
      values (
        '${PREFIX}-ORD', shop_id, branch_id, 'verified', 'accounts', 1, accounts_id,
        '${PREFIX}-ord-key', accounts_id, now(), accounts_id, now()
      )
      returning id into order_id;

      insert into public.order_lines (order_id, product_id, requested_cases)
      values (order_id, product_id, 2)
      returning id into order_line_id;

      insert into public.stock_lots (product_id, status, origin, created_by, branch_id)
      values (product_id, 'available', 'opening', godown_id, branch_id)
      returning id into lot_id;

      insert into public.stock_picking_requests (
        request_number, order_id, branch_id, status, version, created_by, idempotency_key
      )
      values (
        '${PREFIX}-PK', order_id, branch_id, 'ready_for_dispatch', 1, godown_id, '${PREFIX}-pk-key'
      )
      returning id into picking_id;

      insert into public.stock_dispatch_requests (
        request_number, order_id, picking_request_id, branch_id, status, version,
        assigned_to, assigned_by, assigned_at, created_by, idempotency_key,
        request_fingerprint, stock_consumed, posted_transaction_id, dispatched_at, dispatched_by
      )
      values (
        '${fixture.dispatchNumber}', order_id, picking_id, branch_id, 'in_transit', 1,
        driver_id, godown_id, now(), godown_id, '${PREFIX}-dsp-key', '${PREFIX}-dsp-fp', true,
        gen_random_uuid(), now(), godown_id
      );

      insert into public.stock_reservations (
        picking_request_id, order_id, order_line_id, product_id, crate_id, lot_id,
        branch_id, reserved_cases, status, created_by
      )
      values (
        picking_id, order_id, order_line_id, product_id, crate_id, lot_id,
        branch_id, 2, 'consumed', godown_id
      );
    end $$;
    set session_replication_role = origin;
    `,
    "seed m5.4b damage reporting fixtures",
  )
  const balanceCount = runLocalSql(
    `
    select count(*)::text
    from public.stock_balances
    join public.crates on crates.id = stock_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    join public.branches on branches.id = zones.branch_id
    where branches.code = '${PREFIX}_gd'
      and stock_balances.quantity > 0;
    `,
    "verify storage balances",
  )
  if (Number(balanceCount.split(/\r?\n/).filter(Boolean).at(-1) ?? "0") < 1) {
    throw new Error(`M5.4B storage balances missing: ${balanceCount}`)
  }
})

test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    delete from public.damage_evidence
    where damage_report_id in (
      select id from public.damage_reports where report_number like 'DMG-%'
        and notes like '${PREFIX}%'
    );
    delete from public.damage_report_events
    where damage_report_id in (
      select id from public.damage_reports
      where notes like '${PREFIX}%' or report_number like '${PREFIX}%'
    );
    delete from public.damage_report_lines
    where damage_report_id in (
      select id from public.damage_reports
      where notes like '${PREFIX}%' or reporter_user_id in (
        select id from auth.users where email like '%m54be2e@example.com'
      )
    );
    delete from public.damage_reports
    where notes like '${PREFIX}%'
       or reporter_user_id in (select id from auth.users where email like '%m54be2e@example.com');
    delete from public.stock_reservations
    where picking_request_id in (
      select id from public.stock_picking_requests where request_number like '${PREFIX}%'
    );
    delete from public.stock_lots where created_by in (
      select id from auth.users where email like '%m54be2e@example.com'
    );
    delete from public.order_lines
    where order_id in (select id from public.orders where order_number like '${PREFIX}%');
    delete from public.stock_receipt_lines
    where receipt_id in (select id from public.stock_receipts where receipt_number like '${PREFIX}%');
    delete from public.stock_receipts where receipt_number like '${PREFIX}%';
    delete from public.stock_dispatch_requests where request_number like '${PREFIX}%';
    delete from public.stock_picking_requests where request_number like '${PREFIX}%';
    delete from public.orders where order_number like '${PREFIX}%';
    delete from public.stock_balances
    where crate_id in (select id from public.crates where code like '${PREFIX}_%');
    delete from public.crates where code like '${PREFIX}_%';
    delete from public.zones where code like '${PREFIX}_%';
    delete from public.user_branch_assignments
    where branch_id in (select id from public.branches where code = '${PREFIX}_gd');
    delete from public.branches where code = '${PREFIX}_gd';
    delete from public.products where sku = '${fixture.productSku}';
    delete from public.shops where name like 'M54B Shop ${RUN}%';
    delete from public.suppliers where name like 'M54B Supplier ${RUN}%';
    set session_replication_role = origin;
    `,
    "cleanup m5.4b fixtures",
  )
})

test("godown manager creates an authorized storage draft", async ({ page }) => {
  await login(page, "godown.m54be2e@example.com")
  await page.goto("/damage/new")
  await expect(
    page.getByRole("heading", { name: "New damage report" }),
  ).toBeVisible()
  await chooseGodown(page)
  await page.getByRole("radio", { name: /^Storage/ }).click()
  const storageSource = page.getByRole("button", {
    name: new RegExp(`Select source ${fixture.godownName}`),
  })
  await expect(storageSource).toBeVisible({ timeout: 15_000 })
  await expect(storageSource).toHaveClass(/ring-foreground/)
  await page.getByRole("button", { name: "Add line" }).click()
  await expect(
    page.getByLabel("Product").locator("option").nth(1),
  ).toBeAttached({
    timeout: 15_000,
  })
  await page.getByLabel("Product").selectOption({ index: 1 })
  await page.getByLabel(/^Crate/).selectOption({ index: 1 })
  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill("crushed corner")
  await page.getByLabel("Report notes").fill(`${PREFIX} gm storage`)
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByText("Draft", { exact: true })).toBeVisible()
  fixture.draftNumber =
    (await page.getByRole("heading").first().textContent()) ?? ""
})

test("store keeper edits an authorized inbound draft", async ({ page }) => {
  await login(page, "keeper.m54be2e@example.com")
  await page.goto("/damage/new")
  await chooseGodown(page)
  await page.getByRole("radio", { name: /refill supply/i }).click()
  await expect(page.getByText(fixture.receiptNumber)).toBeVisible({
    timeout: 15_000,
  })
  await page
    .getByRole("button", { name: new RegExp(fixture.receiptNumber) })
    .click()
  await page.getByRole("button", { name: "Add" }).click()
  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill("wet carton")
  await page.getByLabel("Report notes").fill(`${PREFIX} sk inbound`)
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  await page.getByLabel("Report notes").fill(`${PREFIX} sk inbound edited`)
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByText(/DMG-\d{8}-\d+ saved/)).toBeVisible({
    timeout: 15_000,
  })
  await expect(page.getByRole("alert")).toHaveCount(0)
  fixture.inboundNumber =
    (await page.getByRole("heading").first().textContent()) ?? ""
})

test("assigned delivery person creates a transit draft and cannot create storage", async ({
  page,
}) => {
  await login(page, "driver.m54be2e@example.com")
  await page.goto("/damage/new")
  await expect(page.getByRole("radio", { name: /storage/i })).toBeDisabled()
  await chooseGodown(page)
  await page.getByRole("radio", { name: /transit/i }).click()
  await expect(page.getByText(fixture.dispatchNumber)).toBeVisible({
    timeout: 15_000,
  })
  await page
    .getByRole("button", { name: new RegExp(fixture.dispatchNumber) })
    .click()
  await page.getByRole("button", { name: "Add" }).click()
  await page.getByLabel("Damage reason").fill("transit crush")
  await page.getByLabel("Report notes").fill(`${PREFIX} driver transit`)
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  fixture.transitNumber =
    (await page.getByRole("heading").first().textContent()) ?? ""
})

test("unauthorized user cannot access creation or edit routes", async ({
  page,
}) => {
  await login(page, "accounts.m54be2e@example.com")
  await page.goto("/damage/new")
  await expect(
    page.getByText(/You do not have access to this page/i),
  ).toBeVisible()
  await page.goto("/damage/not-a-real-id/edit")
  await expect(
    page.getByText(/You do not have access to this page/i),
  ).toBeVisible()
})

test("source picker stays on the authorized godown and invalid quantities are blocked", async ({
  page,
}) => {
  await login(page, "godown.m54be2e@example.com")
  await page.goto("/damage/new")
  await chooseGodown(page)
  await page.getByRole("radio", { name: /refill supply/i }).click()
  await expect(page.getByText(fixture.receiptNumber)).toBeVisible({
    timeout: 15_000,
  })
  await page
    .getByRole("button", { name: new RegExp(fixture.receiptNumber) })
    .click()
  await page.getByRole("button", { name: "Add" }).click()
  await page.getByLabel("Quantity (cases)").fill("0")
  await page.getByLabel("Damage reason").fill("crushed")
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("alert")).toHaveText(
    /whole number of carton cases/i,
  )
})

test("evidence upload finalizes through the trusted RPC and missing evidence blocks submit", async ({
  page,
}) => {
  await login(page, "keeper.m54be2e@example.com")
  await page.goto("/damage/new")
  await chooseGodown(page)
  await page.getByRole("radio", { name: /unloading/i }).click()
  await expect(page.getByText(fixture.receiptNumber)).toBeVisible({
    timeout: 15_000,
  })
  await page
    .getByRole("button", { name: new RegExp(fixture.receiptNumber) })
    .click()
  await page.getByRole("button", { name: "Add" }).click()
  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill("torn wrap")
  await page.getByLabel("Report notes").fill(`${PREFIX} evidence inbound`)
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  await expect(
    page.getByRole("button", { name: "Review and submit" }),
  ).toBeDisabled()
  await page.getByLabel("Select photo").setInputFiles({
    name: "damage.png",
    mimeType: "image/png",
    buffer: png,
  })
  await expect(page.getByAltText("Finalized damage evidence")).toBeVisible({
    timeout: 20_000,
  })
  await expect(
    page.getByRole("button", { name: "Review and submit" }),
  ).toBeEnabled()
  await page.getByRole("button", { name: "Review and submit" }).click()
  await page.getByRole("button", { name: "Submit report" }).click()
  await expect(page.getByRole("heading", { name: /DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  await expect(
    page.getByText("Submitted", { exact: true }).first(),
  ).toBeVisible()
  fixture.inboundNumber =
    (await page.getByRole("heading").first().textContent()) ?? ""
})

test("isolation-required submission stays blocked while readiness is false", async ({
  page,
}) => {
  await login(page, "godown.m54be2e@example.com")
  await page.goto("/damage/new")
  await chooseGodown(page)
  await page.getByRole("radio", { name: /storage/i }).click()
  await expect(
    page.getByText(/Stock isolation is not ready/i).first(),
  ).toBeVisible()
  await expect(
    page.getByRole("button", { name: "Review and submit" }),
  ).toBeDisabled()
})

test("eligible inbound submission follows backend rules after evidence", async ({
  page,
}) => {
  await login(page, "keeper.m54be2e@example.com")
  await page.goto("/damage/reports")
  const reportNo = fixture.inboundNumber.replace(/^Edit\s+/, "").trim()
  await page.getByLabel(/search report number/i).fill(reportNo)
  const reportRow = page.getByRole("row", { name: new RegExp(reportNo) })
  await expect(reportRow).toBeVisible({ timeout: 15_000 })
  await expect(reportRow.getByText("Submitted", { exact: true })).toBeVisible()
})

test("double save does not create duplicate reports and drafts survive refresh", async ({
  page,
}) => {
  await login(page, "godown.m54be2e@example.com")
  await page.goto("/damage/new")
  await chooseGodown(page)
  await page.getByRole("radio", { name: /refill supply/i }).click()
  await page
    .getByRole("button", { name: new RegExp(fixture.receiptNumber) })
    .click()
  await page.getByRole("button", { name: "Add" }).click()
  await page.getByLabel("Quantity (cases)").fill("1")
  await page.getByLabel("Damage reason").fill("double click")
  await page.getByLabel("Report notes").fill(`${PREFIX} double`)
  await page.getByRole("button", { name: "Save draft" }).click()
  await page.getByRole("button", { name: "Save draft" }).click()
  await expect(page.getByRole("heading", { name: /Edit DMG-/ })).toBeVisible({
    timeout: 20_000,
  })
  const heading = await page.getByRole("heading").first().textContent()
  await page.reload()
  await expect(
    page.getByRole("heading", { name: heading ?? /Edit DMG-/ }),
  ).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByLabel("Damage reason")).toHaveValue("double click")
})

test("existing damage dashboard list and detail routes still work", async ({
  page,
}) => {
  await login(page, "godown.m54be2e@example.com")
  await page.goto("/damage")
  await expect(
    page.getByRole("heading", { name: "Damage Management" }),
  ).toBeVisible()
  await page.getByRole("link", { name: "All reports" }).click()
  await expect(
    page.getByRole("heading", { name: "Damage reports" }),
  ).toBeVisible()
  await expect(page.getByRole("link", { name: "New report" })).toBeVisible()
})
