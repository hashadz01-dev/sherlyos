import { spawnSync } from "node:child_process"
import { expect, test, type Page } from "@playwright/test"

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
        and s.status in ('draft', 'rejected', 'submitted');
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

test.beforeEach(() => {
  releaseQaHolds()
})

function productArticle(page: Page, sku: string) {
  return page.locator("article").filter({
    has: page.getByRole("heading", { name: new RegExp(`^${sku}\\b`) }),
  })
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
  await expect(page.getByRole("heading", { name: "Operations Overview" })).toBeVisible({
    timeout: 20_000,
  })
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
    }),
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
  await page.getByLabel("Unexpected product", { exact: true }).selectOption({
    label: "m1s2qa-found · QA Found",
  })
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
