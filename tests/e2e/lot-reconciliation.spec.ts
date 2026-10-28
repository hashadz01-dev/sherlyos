import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"
import {
  cleanupDisposableTestStock,
  DISPOSABLE_SKU_PATTERNS,
} from "./disposable-stock"

const password = "local-only-m1s2qa"
const crateA1 = "m1s2qa_za · m1s2qa_ca1 · QA Crate A1"
const crateA2 = "m1s2qa_za · m1s2qa_ca2 · QA Crate A2"

test.describe.configure({ mode: "serial" })

/**
 * Release only disposable m1s2qa crate holds so a prior approved QA session
 * cannot block a new local run. Does not touch non-qa godowns.
 */
function releaseQaHolds() {
  const sql = `
    do $$
    begin
      perform set_config('app.lot_reconciliation_write', 'on', true);
      update public.stock_lot_reconciliation_scope_crates sc
      set holds_scope = false
      from public.stock_lot_reconciliations s
      join public.branches b on b.id = s.godown_id
      where sc.session_id = s.id
        and b.code like 'm1s2qa_%';
      update public.stock_lot_reconciliations s
      set
        status = 'cancelled',
        cancelled_by = coalesce(
          s.cancelled_by,
          (select id from auth.users where email = 'admin.m1s2qa@example.com')
        ),
        cancellation_reason = coalesce(s.cancellation_reason, 'm1s2qa e2e cleanup'),
        cancelled_at = coalesce(s.cancelled_at, clock_timestamp())
      from public.branches b
      where b.id = s.godown_id
        and b.code like 'm1s2qa_%'
        and s.status in ('draft', 'rejected', 'submitted', 'approved');
    end;
    $$;
  `
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
    ],
    { input: sql, encoding: "utf8" },
  )
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "m1s2qa hold cleanup failed")
  }
}

/**
 * After db reset the HTTP fixture is gone. Seed the same m1s2qa identities
 * the UI selectors expect so this file does not depend on a prior HTTP run.
 */
function ensureQaFixtures() {
  runLocalSql(
    `
    do $$
    declare
      admin_id uuid;
      admin2_id uuid;
      godown_id uuid;
      godown_b_id uuid;
      keeper_id uuid;
      branch_a uuid;
      branch_b uuid;
      zone_a uuid;
      zone_b uuid;
      crate_a1 uuid;
      crate_a2 uuid;
      crate_b uuid;
      soap uuid;
      oil uuid;
      found uuid;
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
        ('admin.m1s2qa@example.com'),
        ('admin2.m1s2qa@example.com'),
        ('godown.m1s2qa@example.com'),
        ('godownb.m1s2qa@example.com'),
        ('keeper.m1s2qa@example.com')
      ) u(email)
      where not exists (select 1 from auth.users e where e.email = u.email);

      update auth.users
      set
        encrypted_password = extensions.crypt('${password}', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        confirmation_token = coalesce(nullif(confirmation_token, ''), id::text || '-c'),
        recovery_token = coalesce(nullif(recovery_token, ''), id::text || '-r'),
        email_change_token_new = coalesce(nullif(email_change_token_new, ''), id::text || '-n'),
        email_change_token_current = coalesce(nullif(email_change_token_current, ''), id::text || '-e'),
        reauthentication_token = coalesce(nullif(reauthentication_token, ''), id::text || '-a'),
        email_change = coalesce(email_change, '')
      where email in (
        'admin.m1s2qa@example.com',
        'admin2.m1s2qa@example.com',
        'godown.m1s2qa@example.com',
        'godownb.m1s2qa@example.com',
        'keeper.m1s2qa@example.com'
      );

      select id into admin_id from auth.users where email = 'admin.m1s2qa@example.com';
      select id into admin2_id from auth.users where email = 'admin2.m1s2qa@example.com';
      select id into godown_id from auth.users where email = 'godown.m1s2qa@example.com';
      select id into godown_b_id from auth.users where email = 'godownb.m1s2qa@example.com';
      select id into keeper_id from auth.users where email = 'keeper.m1s2qa@example.com';

      begin
        perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
      exception
        when sqlstate '42501' then
          insert into public.profiles (id, full_name, is_active)
          values (admin_id, 'QA Admin', true)
          on conflict (id) do update set is_active = true;
          insert into public.user_roles (user_id, role_id, assigned_by)
          select admin_id, roles.id, admin_id from public.roles where code = 'admin'
          on conflict do nothing;
      end;

      insert into public.profiles (id, full_name, is_active)
      values
        (admin2_id, 'QA Admin 2', true),
        (godown_id, 'QA Godown', true),
        (godown_b_id, 'QA Godown B', true),
        (keeper_id, 'QA Keeper', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select u.id, r.id, admin_id
      from (values
        (admin2_id, 'admin'),
        (godown_id, 'godown_manager'),
        (godown_b_id, 'godown_manager'),
        (keeper_id, 'store_keeper')
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

      if not exists (select 1 from public.branches where code = 'm1s2qa_a') then
        branch_a := public.create_branch('m1s2qa_a', 'M1 S2 QA A');
      else
        select id into branch_a from public.branches where code = 'm1s2qa_a';
      end if;
      if not exists (select 1 from public.branches where code = 'm1s2qa_b') then
        branch_b := public.create_branch('m1s2qa_b', 'M1 S2 QA B');
      else
        select id into branch_b from public.branches where code = 'm1s2qa_b';
      end if;

      perform public.assign_user_branch(godown_id, branch_a);
      perform public.assign_user_branch(godown_b_id, branch_b);
      perform public.assign_user_branch(keeper_id, branch_a);

      if not exists (select 1 from public.zones where code = 'm1s2qa_za') then
        zone_a := public.create_zone(branch_a, 'm1s2qa_za', 'QA Zone A', null);
      else
        select id into zone_a from public.zones where code = 'm1s2qa_za';
      end if;
      if not exists (select 1 from public.zones where code = 'm1s2qa_zb') then
        zone_b := public.create_zone(branch_b, 'm1s2qa_zb', 'QA Zone B', null);
      else
        select id into zone_b from public.zones where code = 'm1s2qa_zb';
      end if;

      if not exists (select 1 from public.crates where code = 'm1s2qa_ca1') then
        crate_a1 := public.create_crate(zone_a, 'm1s2qa_ca1', 'QA Crate A1', null);
      else
        select id into crate_a1 from public.crates where code = 'm1s2qa_ca1';
      end if;
      if not exists (select 1 from public.crates where code = 'm1s2qa_ca2') then
        crate_a2 := public.create_crate(zone_a, 'm1s2qa_ca2', 'QA Crate A2', null);
      else
        select id into crate_a2 from public.crates where code = 'm1s2qa_ca2';
      end if;
      if not exists (select 1 from public.crates where code = 'm1s2qa_cb') then
        crate_b := public.create_crate(zone_b, 'm1s2qa_cb', 'QA Crate B', null);
      else
        select id into crate_b from public.crates where code = 'm1s2qa_cb';
      end if;

      if not exists (select 1 from public.products where sku = 'm1s2qa-soap') then
        soap := public.create_product('m1s2qa-soap', 'QA Soap', null, null);
      else
        select id into soap from public.products where sku = 'm1s2qa-soap';
      end if;
      if not exists (select 1 from public.products where sku = 'm1s2qa-oil') then
        oil := public.create_product('m1s2qa-oil', 'QA Oil', null, null);
      else
        select id into oil from public.products where sku = 'm1s2qa-oil';
      end if;
      if not exists (select 1 from public.products where sku = 'm1s2qa-found') then
        found := public.create_product('m1s2qa-found', 'QA Found', null, null);
      else
        select id into found from public.products where sku = 'm1s2qa-found';
      end if;

      perform public.set_product_expiry_policy(soap, 'expiry_controlled');
      perform public.set_product_expiry_policy(oil, 'non_expiring');
      perform public.set_product_expiry_policy(found, 'expiry_controlled');

      -- Restock each crate independently. Opening is unique per product+crate.
      -- Prior HTTP replica cleanup can leave the opening header with no ledger
      -- or balance; a new opening then fails. Restore those disposable rows.
      declare
        need record;
        current_qty integer;
        opening public.stock_transactions%rowtype;
      begin
        for need in
          select *
          from (
            values
              (soap, crate_a1, 6, 'm1s2qa-open-soap-'),
              (oil, crate_a1, 4, 'm1s2qa-open-oil-'),
              (soap, crate_a2, 3, 'm1s2qa-open-soap-2-'),
              (soap, crate_b, 2, 'm1s2qa-open-soap-b-')
          ) as lines(product_id, crate_id, qty, key_prefix)
        loop
          select coalesce(quantity, 0) into current_qty
          from public.stock_balances
          where crate_id = need.crate_id and product_id = need.product_id;
          current_qty := coalesce(current_qty, 0);
          if current_qty >= need.qty then
            continue;
          end if;

          select * into opening
          from public.stock_transactions
          where transaction_type = 'OPENING_STOCK'
            and product_id = need.product_id
            and destination_crate_id = need.crate_id
          order by posted_at
          limit 1;

          if opening.id is null then
            perform public.post_opening_stock(
              need.product_id,
              need.crate_id,
              need.qty,
              need.key_prefix || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
              null
            );
          else
            reset role;
            set session_replication_role = replica;
            if not exists (
              select 1 from public.stock_ledger where transaction_id = opening.id
            ) then
              insert into public.stock_ledger (
                transaction_id, product_id, crate_id, quantity, actor_id, posted_at
              )
              values (
                opening.id,
                opening.product_id,
                opening.destination_crate_id,
                opening.quantity,
                opening.actor_id,
                opening.posted_at
              );
            end if;
            insert into public.stock_balances (crate_id, product_id, quantity)
            values (need.crate_id, need.product_id, need.qty)
            on conflict (crate_id, product_id) do update
              set quantity = excluded.quantity;
            set session_replication_role = origin;
            perform set_config('request.jwt.claim.sub', admin_id::text, true);
            perform set_config(
              'request.jwt.claims',
              jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
              true
            );
            execute 'set local role authenticated';
          end if;
        end loop;
      end;
    end;
    $$;
    `,
    "m1s2qa e2e fixtures",
  )
}

test.beforeAll(() => {
  ensureQaFixtures()
})

test.beforeEach(() => {
  releaseQaHolds()
})

/**
 * Wipe disposable m1s2qa lots and balances after this file. Opening headers
 * stay; beforeAll restocks balances when quantity is short so HTTP/e2e can
 * rerun without unmatched grains leaking into later dual-write suites.
 */
test.afterAll(() => {
  runLocalSql(
    `
    set session_replication_role = replica;
    update public.stock_ledger
    set lot_id = null
    where product_id in (select id from public.products where sku like 'm1s2qa-%');
    delete from public.stock_lot_reconciliation_attributions
    where product_id in (select id from public.products where sku like 'm1s2qa-%');
    delete from public.stock_lot_attribution_baselines
    where lot_id in (
      select sl.id from public.stock_lots sl
      join public.products p on p.id = sl.product_id
      where p.sku like 'm1s2qa-%'
    );
    delete from public.stock_legacy_lot_seeds
    where product_id in (select id from public.products where sku like 'm1s2qa-%');
    delete from public.stock_lot_balances
    where lot_id in (
      select sl.id from public.stock_lots sl
      join public.products p on p.id = sl.product_id
      where p.sku like 'm1s2qa-%'
    );
    delete from public.stock_lots
    where product_id in (select id from public.products where sku like 'm1s2qa-%');
    delete from public.stock_balances
    where product_id in (select id from public.products where sku like 'm1s2qa-%');
    set session_replication_role = origin;
    `,
    "m1s2qa dual-write hygiene",
  )
})

function productArticle(page: Page, sku: string) {
  return page.locator("article").filter({
    has: page.getByRole("heading", { name: new RegExp(`^${sku}\\b`) }),
  })
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
    ],
    { input: sql, encoding: "utf8" },
  )
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || `${label} failed`)
  }
  return result.stdout
}

function wipeLocalLotsIfSafe() {
  runLocalSql(
    `
    do $$
    begin
      if exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ) then
        raise exception 'refusing lot wipe while dual-write is enabled';
      end if;
      if exists (select 1 from public.stock_ledger where lot_id is not null) then
        raise exception 'refusing lot wipe while lot-attributed ledger exists';
      end if;
      perform set_config('app.lot_reconciliation_write', 'on', true);
      perform set_config('app.picking_write', 'on', true);
      -- Return lots pin consumed reservations and original lots. Replica skips the
      -- append-only guard so a local wipe can proceed.
      execute 'set session_replication_role = replica';
      delete from public.stock_delivery_return_events;
      delete from public.stock_delivery_return_lots;
      execute 'set session_replication_role = origin';
      -- Local lot wipe cannot leave reservation FKs pointing at deleted lots.
      delete from public.stock_picking_exceptions;
      delete from public.stock_reservations;
      perform app_private.begin_lot_balance_write('seed');
      delete from public.stock_lot_reconciliation_attributions;
      delete from public.stock_lot_attribution_baselines;
      delete from public.stock_lot_balances;
      delete from public.stock_legacy_lot_seeds;
      delete from public.stock_lots;
      perform app_private.end_lot_balance_write();
      update public.app_configuration
      set value = 'false'::jsonb
      where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
    end;
    $$;
  `,
    "local lot wipe",
  )
}

function seedLegacyLotsAsAdmin() {
  runLocalSql(
    `
    begin;
    select set_config(
      'request.jwt.claims',
      (select json_build_object('sub', id, 'role', 'authenticated')::text
       from auth.users where email = 'admin.m1s2qa@example.com'),
      true
    );
    set local role authenticated;
    select public.seed_legacy_stock_lots();
    commit;
  `,
    "local legacy seed",
  )
}

function assertLocalSupabaseUrl(raw: string) {
  const url = new URL(raw)
  if (url.hostname !== "127.0.0.1" && url.hostname !== "localhost") {
    throw new Error(`refusing non-local API host ${url.hostname}`)
  }
  if (url.port && url.port !== "54321") {
    throw new Error(`refusing unexpected API port ${url.port}`)
  }
}

async function signIn(page: Page, email: string) {
  await page.goto("/login")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  const pending = page.waitForRequest((request) => {
    try {
      const url = new URL(request.url())
      return url.pathname.includes("/auth/v1") || url.pathname.includes("/rest/v1")
    } catch {
      return false
    }
  })
  await page.getByRole("button", { name: "Sign in" }).click()
  assertLocalSupabaseUrl((await pending).url())
  const loginAlert = page.getByRole("alert")
  await Promise.race([
    expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
      timeout: 20_000,
    }),
    loginAlert.waitFor({ state: "visible", timeout: 20_000 }).then(async () => {
      throw new Error(`sign-in failed for ${email}: ${await loginAlert.innerText()}`)
    }),
  ])
}

async function signOut(page: Page) {
  await page.getByRole("button", { name: "Account menu" }).click()
  await page.getByRole("menuitem", { name: "Sign out" }).click()
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible({ timeout: 20_000 })
}

async function createSession(page: Page, crateLabel: string) {
  await page.goto("/stock-lot-reconciliation/new")
  await expect(page.getByLabel("Godown").locator("option", { hasText: "M1 S2 QA A" })).toBeAttached({
    timeout: 20_000,
  })
  await page.getByLabel("Godown").selectOption({ label: "M1 S2 QA A (m1s2qa_a)" })
  await page.getByText(crateLabel, { exact: true }).click()
  await page.getByRole("button", { name: "Create session" }).click()
  await expect(page.getByRole("heading", { name: /^LR-/ })).toBeVisible({ timeout: 20_000 })
}

async function saveMatchedCount(page: Page, sku: string, quantity: number) {
  const card = productArticle(page, sku)
  await card.getByLabel(`Count ${sku}`).fill(String(quantity))
  await card.getByRole("button", { name: "Save count" }).click()
  await expect(card.getByText("Matched", { exact: true })).toBeVisible({ timeout: 15_000 })
}

async function saveKnownLot(
  page: Page,
  sku: string,
  code: string,
  quantity: number,
  expiry?: string,
) {
  const card = productArticle(page, sku)
  await card.getByRole("button", { name: "Add lot" }).click()
  await card.getByLabel(`Manufacturer lot ${sku} 1`).fill(code)
  await card.getByLabel(`Lot quantity ${sku} 1`).fill(String(quantity))
  if (expiry) {
    await card.getByLabel(`Expiry ${sku} 1`).fill(expiry)
  }
  await card.getByRole("button", { name: "Save lots" }).click()
  await expect(card.getByText("Lot evidence complete", { exact: true })).toBeVisible({
    timeout: 15_000,
  })
}

async function saveUnknownLot(page: Page, sku: string) {
  const card = productArticle(page, sku)
  await card.getByRole("button", { name: "Add unknown / legacy unattributed" }).click()
  await card.getByRole("button", { name: "Save lots" }).click()
  await expect(card.getByText("Lot evidence complete", { exact: true })).toBeVisible({
    timeout: 15_000,
  })
}

async function cancelOpenSession(page: Page, reason: string) {
  await page.getByRole("button", { name: "Cancel session" }).click()
  await page.getByLabel("Cancellation reason").fill(reason)
  await page.getByRole("dialog").getByRole("button", { name: "Cancel session" }).click()
  await expect(page.getByText("cancelled", { exact: true }).first()).toBeVisible({
    timeout: 20_000,
  })
}

test("store keeper cannot open lot reconciliation", async ({ page }) => {
  await signIn(page, "keeper.m1s2qa@example.com")
  await page.goto("/stock-lot-reconciliation")
  await expect(page.getByText("You do not have access to this page")).toBeVisible()
  await expect(
    page.getByRole("navigation", { name: "Primary" }).getByText("Lot reconciliation"),
  ).toHaveCount(0)
})

test("lot reconciliation create form fits a tablet width", async ({ page }) => {
  await page.setViewportSize({ width: 820, height: 1180 })
  await signIn(page, "admin.m1s2qa@example.com")
  await page.goto("/stock-lot-reconciliation/new")
  await expect(page.getByRole("heading", { name: "New lot reconciliation" })).toBeVisible()
  await expect(page.getByLabel("Godown")).toBeVisible()
  await expect(page.getByRole("button", { name: "Create session" })).toBeVisible()
})

test("stale version shows PT409 instead of replaying the edit", async ({ page, context }) => {
  test.setTimeout(120_000)
  await signIn(page, "admin.m1s2qa@example.com")
  await createSession(page, crateA2)
  const sessionUrl = page.url()
  await signOut(page)
  await signIn(page, "godown.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await expect(productArticle(page, "m1s2qa-soap")).toBeVisible({ timeout: 20_000 })

  const page2 = await context.newPage()
  await page2.goto(sessionUrl)
  await expect(productArticle(page2, "m1s2qa-soap")).toBeVisible({ timeout: 20_000 })

  await saveMatchedCount(page, "m1s2qa-soap", 3)
  await productArticle(page2, "m1s2qa-soap").getByLabel("Count m1s2qa-soap").fill("3")
  await productArticle(page2, "m1s2qa-soap").getByRole("button", { name: "Save count" }).click()
  await expect(
    page2.getByRole("alert").filter({
      hasText: "This session was changed by someone else. Review the latest counts before saving again.",
    }).first(),
  ).toBeVisible({ timeout: 20_000 })
  await page2.close()

  await signOut(page)
  await signIn(page, "admin.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await cancelOpenSession(page, "m1s2qa e2e pt409 cleanup")
})

test("refresh, unexpected stock, reject, and reopen stay on the session", async ({ page }) => {
  test.setTimeout(180_000)
  await signIn(page, "admin.m1s2qa@example.com")
  await createSession(page, crateA2)
  const sessionUrl = page.url()

  await signOut(page)
  await signIn(page, "godown.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await expect(productArticle(page, "m1s2qa-soap")).toBeVisible({ timeout: 20_000 })
  await saveMatchedCount(page, "m1s2qa-soap", 3)

  await page.getByRole("button", { name: "Refresh expected stock" }).click()
  await expect(page.getByRole("dialog")).toContainText("remove all existing counts")
  await page.getByRole("button", { name: "Refresh and clear counts" }).click()
  await expect(productArticle(page, "m1s2qa-soap").getByText("Not counted", { exact: true })).toBeVisible({
    timeout: 15_000,
  })

  await saveMatchedCount(page, "m1s2qa-soap", 3)
  await saveKnownLot(page, "m1s2qa-soap", "SOAP-A2", 3, "2028-01-01")
  await page.getByLabel("Unexpected product", { exact: true }).fill("m1s2qa-found")
  await page.getByRole("option", { name: "m1s2qa-found · QA Found" }).click()
  await page.getByRole("button", { name: "Record unexpected product" }).click()
  await expect(page.getByRole("heading", { name: "m1s2qa-found QA Found" })).toBeVisible({
    timeout: 15_000,
  })
  const found = productArticle(page, "m1s2qa-found")
  await found.getByLabel("Count m1s2qa-found").fill("1")
  await found.getByRole("button", { name: "Save count" }).click()
  await expect(found.getByText("Unexpected stock", { exact: true })).toBeVisible({ timeout: 15_000 })
  await saveUnknownLot(page, "m1s2qa-found")
  await page.getByRole("button", { name: "Submit counts" }).click()
  await expect(page.getByText("submitted", { exact: true }).first()).toBeVisible({ timeout: 20_000 })

  await signOut(page)
  await signIn(page, "admin2.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await expect(page.getByText("Unresolved quantity discrepancies block approval")).toBeVisible()
  await page.getByRole("button", { name: "Approve" }).click()
  await expect(page.getByText(/unresolved quantity discrepancies/i).last()).toBeVisible({
    timeout: 20_000,
  })
  await page.getByLabel("Rejection reason").fill("unexpected stock remains a discrepancy")
  await page.getByRole("button", { name: "Reject" }).click()
  await expect(page.getByText("rejected", { exact: true }).first()).toBeVisible({ timeout: 20_000 })

  await signOut(page)
  await signIn(page, "godown.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await page.getByRole("button", { name: "Reopen rejected session" }).click()
  await expect(page.getByText("draft", { exact: true }).first()).toBeVisible({ timeout: 20_000 })

  await signOut(page)
  await signIn(page, "admin.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await cancelOpenSession(page, "m1s2qa e2e reject-reopen cleanup")
})

test("admin and godown manager complete a matched physical reconciliation", async ({ page }) => {
  test.setTimeout(180_000)

  await signIn(page, "admin.m1s2qa@example.com")
  await page.getByRole("link", { name: "Lot reconciliation" }).click()
  await expect(page.getByRole("heading", { name: "Lot reconciliation" })).toBeVisible()
  await page.getByRole("link", { name: "New session" }).click()
  await createSession(page, crateA1)
  const sessionUrl = page.url()

  await signOut(page)
  await signIn(page, "godown.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await expect(page.getByRole("heading", { name: "m1s2qa-soap QA Soap" })).toBeVisible({
    timeout: 20_000,
  })

  await saveMatchedCount(page, "m1s2qa-soap", 6)
  await saveKnownLot(page, "m1s2qa-soap", "SOAP-UI", 6, "2028-01-01")
  await saveMatchedCount(page, "m1s2qa-oil", 4)
  await saveUnknownLot(page, "m1s2qa-oil")

  await page.getByRole("button", { name: "Submit counts" }).click()
  await expect(page.getByText("submitted", { exact: true }).first()).toBeVisible({ timeout: 20_000 })

  await signOut(page)
  await signIn(page, "admin2.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await page.getByRole("button", { name: "Approve" }).click()
  await expect(page.getByText("approved", { exact: true }).first()).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("heading", { name: "Audit history" })).toBeVisible()
  await expect(page.getByText(/Session created by/).first()).toBeVisible()
  await expect(page.getByText(/Submitted by/).first()).toBeVisible()
  await expect(page.getByText(/Approved by/).first()).toBeVisible()
  await expect(page.getByRole("button", { name: "Cancel session" })).toHaveCount(0)
})

test("admin applies approved attribution after local legacy seed", async ({ page }) => {
  test.setTimeout(180_000)
  wipeLocalLotsIfSafe()

  await signIn(page, "admin.m1s2qa@example.com")
  await createSession(page, crateA1)
  const sessionUrl = page.url()

  await signOut(page)
  await signIn(page, "godown.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await expect(page.getByRole("heading", { name: "m1s2qa-soap QA Soap" })).toBeVisible({
    timeout: 20_000,
  })
  await saveMatchedCount(page, "m1s2qa-soap", 6)
  await saveKnownLot(page, "m1s2qa-soap", "SOAP-UI", 6, "2028-01-01")
  await saveMatchedCount(page, "m1s2qa-oil", 4)
  await saveUnknownLot(page, "m1s2qa-oil")
  await page.getByRole("button", { name: "Submit counts" }).click()
  await expect(page.getByText("submitted", { exact: true }).first()).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("heading", { name: "Legacy lot attribution" })).toHaveCount(0)
  await expect(page.getByRole("button", { name: "Apply attribution" })).toHaveCount(0)

  await signOut(page)
  await signIn(page, "admin2.m1s2qa@example.com")
  await page.goto(sessionUrl)
  await page.getByRole("button", { name: "Approve" }).click()
  await expect(page.getByText("approved", { exact: true }).first()).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole("heading", { name: "Legacy lot attribution" })).toBeVisible()
  await expect(page.getByText(/Attribution is not eligible yet/)).toBeVisible()
  await expect(page.getByRole("button", { name: "Apply attribution" })).toBeDisabled()

  cleanupDisposableTestStock("lot-recon leftover disposable cleanup", {
    skuPatterns: DISPOSABLE_SKU_PATTERNS.filter(
      (pattern) => !pattern.startsWith("m1s2"),
    ),
  })
  seedLegacyLotsAsAdmin()
  await page.reload()
  await expect(page.getByText(/Attribution is eligible/)).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "Apply attribution" }).click()
  await expect(page.getByRole("dialog")).toContainText("cannot be undone from the application")
  try {
    await page.getByRole("dialog").getByRole("button", { name: "Apply attribution" }).click()
    await expect(page.getByText("applied", { exact: true }).first()).toBeVisible({ timeout: 20_000 })
    await expect(page.getByText(/from this approved evidence/).first()).toBeVisible()
    await expect(page.getByText(/Legacy lots attributed by/).first()).toBeVisible()
    await expect(page.getByRole("button", { name: "Apply attribution" })).toHaveCount(0)
  } finally {
    wipeLocalLotsIfSafe()
  }
})
