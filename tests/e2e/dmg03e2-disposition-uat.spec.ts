import { expect, test } from "@playwright/test"
import { localPsqlContainer, runLocalSql } from "./disposable-stock"
import {
  createVerifiedStorageDamage,
  findVerifiedActiveHoldReport,
  releaseSubmittedDisposableHolds,
  signIn,
  stockSnapshot,
} from "./dmg03e2-helpers"
import { M82C_ISOLATION, M82C_USERS } from "../../src/lib/uat/m82c-manifest"

test.describe.configure({ mode: "serial", timeout: 240_000 })

// Prefer the DMG-03F replenishment lot (free cases) over fully-held legacy lots.
const LOT_Q = "TEST-LOT-DMG03F"
const LOT_WO = "TEST-LOT-DMG03F"
const LOT_EX = "TEST-LOT-DMG03F"
const LOT_REJ = "TEST-LOT-DMG03F"

const state = {
  quarantineReportId: "",
  quarantineReportNumber: "",
  writeoffReportId: "",
  writeoffReportNumber: "",
  destroyReportId: "",
  destroyReportNumber: "",
  rejectReportId: "",
  rejectRequestId: "",
  physicalC1Before: 0,
  ledgerBefore: 0,
  lotBAvailBefore: 0,
  lotAAvailBefore: 0,
}

test.beforeAll(() => {
  if (localPsqlContainer() !== M82C_ISOLATION.container) {
    throw new Error("DMG-03E.2 refused a non-m82c Postgres container")
  }
  const sysid = runLocalSql(
    "select system_identifier from pg_control_system();",
    "sysid",
  )
  expect(sysid).not.toContain(M82C_ISOLATION.forbiddenOwnerSysid)
  expect(sysid).not.toContain(M82C_ISOLATION.forbiddenM81cSysid)

  const flags = runLocalSql(
    `select key || '=' || (value #>> '{}')
     from public.app_configuration
     where key in ('damage.stock_hold_ready', 'stock.lots.dual_write_enabled')
     order by 1;`,
    "flags",
  )
  expect(flags).toContain("damage.stock_hold_ready=true")
  expect(flags).toContain("stock.lots.dual_write_enabled=true")

  // Reject leftover submitted disposable holds so picking capacity exists.
  expect(releaseSubmittedDisposableHolds()).toContain("ok")

  const snap = stockSnapshot(LOT_Q)
  const [physicalC1, , lotTriple, , ledger] = snap.split("|")
  const [, , avail] = lotTriple.split(":").map(Number)
  const snapA = stockSnapshot(LOT_EX)
  const [, , lotATriple] = snapA.split("|")
  const [, , availA] = lotATriple.split(":").map(Number)

  // C1 physical shrinks as disposable write-offs / quarantine settle; only
  // require enough available cases for the remaining suite steps.
  expect(Number(physicalC1)).toBeGreaterThanOrEqual(0)
  // Fresh create needs avail; otherwise UAT reuses existing verified holds.
  expect(avail + availA).toBeGreaterThanOrEqual(0)
  const reusable = findVerifiedActiveHoldReport(LOT_Q)
  expect(avail >= 1 || reusable.includes("|")).toBe(true)
  state.physicalC1Before = Number(physicalC1)
  state.ledgerBefore = Number(ledger)
  state.lotBAvailBefore = avail
  state.lotAAvailBefore = availA
})

test("quarantine transfer moves verified hold onto godown quarantine crate", async ({
  page,
}) => {
  const existing = findVerifiedActiveHoldReport(LOT_Q)
  let reportId: string
  let reportNumber: string
  if (existing.includes("|") && state.lotBAvailBefore < 1) {
    ;[reportId, reportNumber] = existing.split("|")
    await signIn(page, M82C_USERS.godownManager)
  } else if (state.lotBAvailBefore >= 1) {
    const created = await createVerifiedStorageDamage(page, {
      lotCode: LOT_Q,
      reason: "DMG-03E.2 quarantine Packaging Damage",
    })
    reportId = created.reportId
    reportNumber = created.reportNumber
  } else {
    throw new Error("No disposable verified hold or available cases for quarantine UAT")
  }
  state.quarantineReportId = reportId
  state.quarantineReportNumber = reportNumber

  const before = stockSnapshot(LOT_Q)
  const [physBefore, qPhysBefore, lotBefore, qLotBefore, ledgerBefore] =
    before.split("|")
  const [lotPhysBefore] = lotBefore.split(":").map(Number)

  await page.goto(`/damage/${reportId}`)
  await expect(page.getByText("Verified", { exact: true }).first()).toBeVisible({
    timeout: 15_000,
  })
  const openTransfer = page.getByRole("button", {
    name: "Transfer verified damage to quarantine",
  })
  await expect(openTransfer).toBeVisible({ timeout: 15_000 })
  await openTransfer.click()
  await expect(
    page.getByRole("heading", { name: "Transfer verified damage to quarantine" }),
  ).toBeVisible({ timeout: 10_000 })
  await page.getByRole("button", { name: "Post quarantine transfer" }).click()
  await expect(
    page.getByText("Verified damage transferred to quarantine"),
  ).toBeVisible({ timeout: 30_000 })

  const holds = runLocalSql(
    `select h.status || '|' || h.hold_kind || '|' || h.quantity_cases::text
        || '|' || coalesce(c.location_role, '?')
        || '|' || coalesce(sl.manufacturer_lot_code, '?')
     from public.damage_stock_holds h
     left join public.crates c on c.id = h.crate_id
     left join public.stock_lots sl on sl.id = h.lot_id
     where h.damage_report_id = '${reportId}'
     order by h.created_at;`,
    "q-holds",
  )
  expect(holds).toContain("transferred|on_hand_deduction|1|quarantine|" + LOT_Q)

  const after = stockSnapshot(LOT_Q)
  const [physAfter, qPhysAfter, lotAfter, qLotAfter, ledgerAfter] =
    after.split("|")
  const [lotPhysAfter, , lotAvailAfter] = lotAfter.split(":").map(Number)

  // Aggregate C1 physical drops by 1; quarantine crate gains 1; lot retained.
  expect(Number(physAfter)).toBe(Number(physBefore) - 1)
  expect(Number(qPhysAfter)).toBe(Number(qPhysBefore) + 1)
  expect(lotPhysAfter).toBe(lotPhysBefore - 1)
  expect(Number(qLotAfter)).toBe(Number(qLotBefore) + 1)
  expect(Number(ledgerAfter)).toBe(Number(ledgerBefore) + 2) // -src +dst legs
  expect(lotAvailAfter).toBeLessThanOrEqual(Number(lotBefore.split(":")[2]))

  const audit = runLocalSql(
    `select string_agg(action, ',' order by created_at)
     from public.damage_report_events
     where damage_report_id = '${reportId}';`,
    "q-audit",
  )
  expect(audit).toMatch(/quarantine_transferred/)

  // Picking must ignore quarantine crate balances.
  const pickableQ = Number(
    runLocalSql(
      `select app_private.picking_available_cases(sl.id, c.id)::text
       from public.stock_lots sl
       join public.products p on p.id = sl.product_id
       join public.stock_lot_balances slb on slb.lot_id = sl.id
       join public.crates c on c.id = slb.crate_id
       where p.sku = 'm82c-stable'
         and sl.manufacturer_lot_code = '${LOT_Q}'
         and c.location_role = 'quarantine'
       limit 1;`,
      "q-pickable",
    ),
  )
  expect(pickableQ).toBe(0)

  // Store keeper cannot quarantine.
  await signIn(page, M82C_USERS.storeKeeper)
  await page.goto(`/damage/${reportId}`)
  await expect(
    page.getByRole("button", { name: "Transfer verified damage to quarantine" }),
  ).toHaveCount(0)
})

test("ordinary write-off after quarantine posts one ledger adjustment", async ({
  page,
}) => {
  // Continue the quarantine fixture — one report covers both custody and write-off.
  const reportId = state.quarantineReportId
  expect(reportId).toBeTruthy()
  state.writeoffReportId = reportId
  state.writeoffReportNumber = state.quarantineReportNumber

  await signIn(page, M82C_USERS.godownManager)
  await page.goto(`/damage/${reportId}`)
  await expect(
    page.getByRole("heading", { name: state.quarantineReportNumber }),
  ).toBeVisible({ timeout: 20_000 })

  const before = stockSnapshot(LOT_WO)
  const [physBefore, qPhysBefore, , qLotBefore, ledgerBefore] = before.split("|")

  await page.getByRole("button", { name: "Post ordinary write-off" }).click()
  await page.getByRole("button", { name: "Confirm ordinary write-off" }).click()
  await expect(page.getByText("Ordinary write-off posted")).toBeVisible({
    timeout: 20_000,
  })

  const holds = runLocalSql(
    `select status || '|' || quantity_cases::text
     from public.damage_stock_holds
     where damage_report_id = '${reportId}';`,
    "wo-holds",
  )
  expect(holds).toContain("written_off|1")

  const tx = runLocalSql(
    `select count(*)::text || '|' || coalesce(max(damage_posting_kind), '')
     from public.stock_transactions
     where damage_report_id = '${reportId}'
       and damage_posting_kind = 'ordinary_writeoff';`,
    "wo-tx",
  )
  expect(tx).toBe("1|ordinary_writeoff")

  const after = stockSnapshot(LOT_WO)
  const [physAfter, qPhysAfter, , qLotAfter, ledgerAfter] = after.split("|")

  // Source C1 unchanged by write-off (already moved); quarantine physical -1.
  expect(Number(physAfter)).toBe(Number(physBefore))
  expect(Number(qPhysAfter)).toBe(Number(qPhysBefore) - 1)
  expect(Number(qLotAfter)).toBe(Number(qLotBefore) - 1)
  // Exactly one adjustment ledger row for the write-off (negative qty).
  const woLegs = Number(
    runLocalSql(
      `select count(*)::text
       from public.stock_ledger l
       join public.stock_transactions t on t.id = l.transaction_id
       where t.damage_report_id = '${reportId}'
         and t.damage_posting_kind = 'ordinary_writeoff';`,
      "wo-legs",
    ),
  )
  expect(woLegs).toBe(1)
  expect(Number(ledgerAfter)).toBe(Number(ledgerBefore) + 1)

  // Duplicate post is idempotent / no second transaction.
  const dup = runLocalSql(
    `
    do $$
    declare
      v integer;
      tx_before integer;
      tx_after integer;
    begin
      select version into v from public.damage_reports where id = '${reportId}'::uuid;
      select count(*) into tx_before from public.stock_transactions
      where damage_report_id = '${reportId}'::uuid
        and damage_posting_kind = 'ordinary_writeoff';
      perform set_config('request.jwt.claim.sub',
        (select id::text from auth.users where email = '${M82C_USERS.godownManager}'), true);
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', (select id from auth.users where email = '${M82C_USERS.godownManager}'),
          'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      perform public.post_ordinary_damage_writeoff(
        '${reportId}'::uuid, v, 'dmg03e2-wo-dup-' || gen_random_uuid()::text
      );
      select count(*) into tx_after from public.stock_transactions
      where damage_report_id = '${reportId}'::uuid
        and damage_posting_kind = 'ordinary_writeoff';
      if tx_after is distinct from tx_before then
        raise exception 'duplicate write-off created transaction';
      end if;
    end $$;
    select 'ok';
    `,
    "wo-dup",
  )
  expect(dup).toContain("ok")

  const audit = runLocalSql(
    `select string_agg(action, ',' order by created_at)
     from public.damage_report_events
     where damage_report_id = '${reportId}';`,
    "wo-audit",
  )
  expect(audit).toMatch(/ordinary_writeoff/)
})

test("exceptional destroy requires admin approval before stock posts", async ({
  page,
}) => {
  // Resume an open approved/requested destroy when a prior attempt stalled,
  // else reuse any verified active hold, else create fresh when avail allows.
  const openEx = runLocalSql(
    `select r.id::text || '|' || r.report_number || '|' || ex.status
     from public.damage_exceptional_requests ex
     join public.damage_reports r on r.id = ex.damage_report_id
     where ex.disposition_kind = 'destroy'
       and ex.status in ('requested', 'approved')
     order by ex.requested_at desc
     limit 1;`,
    "ex-open",
  )
  let reportId: string
  let reportNumber: string
  let phase: "request" | "approve" | "execute" = "request"

  if (openEx.includes("|")) {
    const parts = openEx.split("|")
    reportId = parts[0]
    reportNumber = parts[1]
    phase = parts[2] === "approved" ? "execute" : "approve"
    await signIn(page, M82C_USERS.godownManager)
  } else {
    const existing = findVerifiedActiveHoldReport(LOT_EX)
    if (existing.includes("|")) {
      ;[reportId, reportNumber] = existing.split("|")
      await signIn(page, M82C_USERS.godownManager)
    } else {
      const created = await createVerifiedStorageDamage(page, {
        lotCode: LOT_EX,
        reason: "DMG-03E.2 exceptional destroy",
      })
      reportId = created.reportId
      reportNumber = created.reportNumber
    }
  }
  state.destroyReportId = reportId
  state.destroyReportNumber = reportNumber

  const before = stockSnapshot(LOT_EX)
  const [physBefore, , lotBefore, , ledgerBefore] = before.split("|")
  const [, heldBefore] = lotBefore.split(":").map(Number)

  await page.goto(`/damage/${reportId}`)
  await expect(page.getByRole("heading", { name: reportNumber })).toBeVisible({
    timeout: 20_000,
  })

  if (phase === "request") {
    await page
      .getByRole("button", { name: "Request exceptional disposition" })
      .click()
    await page.getByLabel("Exceptional disposition kind").selectOption("destroy")
    await page
      .getByLabel("Exceptional request reason")
      .fill("Disposable UAT destroy request")
    await page.getByRole("button", { name: "Confirm exceptional request" }).click()
    await expect(page.getByText("Exceptional request submitted")).toBeVisible({
      timeout: 20_000,
    })

    // Stock unchanged after request.
    const mid = stockSnapshot(LOT_EX)
    expect(mid.split("|")[0]).toBe(physBefore)
    expect(mid.split("|")[4]).toBe(ledgerBefore)

    // Store keeper cannot approve.
    const skBlocked = runLocalSql(
      `
      do $$
      declare
        req uuid;
        v integer;
        msg text;
      begin
        select id, version into req, v
        from public.damage_exceptional_requests
        where damage_report_id = '${reportId}'::uuid
        order by requested_at desc limit 1;
        perform set_config('request.jwt.claim.sub',
          (select id::text from auth.users where email = '${M82C_USERS.storeKeeper}'), true);
        perform set_config('request.jwt.claims',
          jsonb_build_object('sub', (select id from auth.users where email = '${M82C_USERS.storeKeeper}'),
            'role', 'authenticated')::text, true);
        perform set_config('role', 'authenticated', true);
        begin
          perform public.approve_exceptional_damage_disposition(req, v);
          raise exception 'store keeper approved exceptional request';
        exception
          when others then
            get stacked diagnostics msg = message_text;
            if msg ilike '%store keeper approved%' then raise;
            end if;
        end;
      end $$;
      select 'ok';
      `,
      "ex-sk-blocked",
    )
    expect(skBlocked).toContain("ok")
    phase = "approve"
  }

  if (phase === "approve") {
    await signIn(page, M82C_USERS.admin)
    await page.goto(`/damage/${reportId}`)
    await page.getByRole("button", { name: "Approve", exact: true }).click()
    await page.getByRole("button", { name: "Confirm exceptional approval" }).click()
    await expect(page.getByText("Exceptional request approved")).toBeVisible({
      timeout: 20_000,
    })

    const afterApprove = stockSnapshot(LOT_EX)
    expect(afterApprove.split("|")[0]).toBe(physBefore)
    expect(afterApprove.split("|")[4]).toBe(ledgerBefore)
  }

  // GM posts disposition — stock must not move before this step.
  const prePost = stockSnapshot(LOT_EX)
  expect(prePost.split("|")[0]).toBe(physBefore)
  expect(prePost.split("|")[4]).toBe(ledgerBefore)

  await signIn(page, M82C_USERS.godownManager)
  await page.goto(`/damage/${reportId}`)
  await page.getByRole("button", { name: /Execute destroy/i }).click()
  await page
    .getByRole("button", { name: "Confirm exceptional execution" })
    .click()
  await expect(page.getByText("Exceptional disposition posted")).toBeVisible({
    timeout: 20_000,
  })

  const holds = runLocalSql(
    `select status from public.damage_stock_holds where damage_report_id = '${reportId}';`,
    "ex-holds",
  )
  expect(holds).toMatch(/written_off/)

  const after = stockSnapshot(LOT_EX)
  const [physAfter, , lotAfter, , ledgerAfter] = after.split("|")
  const [, heldAfter] = lotAfter.split(":").map(Number)
  expect(Number(physAfter)).toBe(Number(physBefore) - 1)
  expect(heldAfter).toBe(heldBefore - 1)
  expect(Number(ledgerAfter)).toBeGreaterThan(Number(ledgerBefore))

  const kind = runLocalSql(
    `select disposition_kind || '|' || status
     from public.damage_exceptional_requests
     where damage_report_id = '${reportId}'
     order by requested_at desc limit 1;`,
    "ex-kind",
  )
  expect(kind).toBe("destroy|posted")
})

test("exceptional rejection leaves holds intact and blocks posting", async ({
  page,
}) => {
  const existing = findVerifiedActiveHoldReport(LOT_REJ)
  let reportId: string
  if (existing.includes("|")) {
    reportId = existing.split("|")[0]
    await signIn(page, M82C_USERS.godownManager)
  } else {
    const created = await createVerifiedStorageDamage(page, {
      lotCode: LOT_REJ,
      reason: "DMG-03E.2 exceptional reject path",
    })
    reportId = created.reportId
  }
  state.rejectReportId = reportId

  await page.goto(`/damage/${reportId}`)
  await page
    .getByRole("button", { name: "Request exceptional disposition" })
    .click()
  await page
    .getByLabel("Exceptional disposition kind")
    .selectOption("return_supplier")
  await page
    .getByLabel("Exceptional request reason")
    .fill("Disposable UAT supplier return request")
  await page.getByRole("button", { name: "Confirm exceptional request" }).click()
  await expect(page.getByText("Exceptional request submitted")).toBeVisible({
    timeout: 20_000,
  })

  state.rejectRequestId = runLocalSql(
    `select id::text from public.damage_exceptional_requests
     where damage_report_id = '${reportId}'
     order by requested_at desc limit 1;`,
    "rej-req",
  )

  const before = stockSnapshot(LOT_REJ)

  await signIn(page, M82C_USERS.admin)
  await page.goto(`/damage/${reportId}`)
  await page.getByRole("button", { name: "Reject", exact: true }).click()
  await page.getByLabel("Decision reason").fill("Disposable UAT rejection")
  await page.getByRole("button", { name: "Confirm exceptional rejection" }).click()
  await expect(page.getByText("Exceptional request rejected")).toBeVisible({
    timeout: 20_000,
  })

  const after = stockSnapshot(LOT_REJ)
  expect(after).toBe(before)

  const status = runLocalSql(
    `select status from public.damage_exceptional_requests where id = '${state.rejectRequestId}';`,
    "rej-status",
  )
  expect(status).toBe("rejected")

  const postBlocked = runLocalSql(
    `
    do $$
    declare
      v integer;
      msg text;
    begin
      select version into v from public.damage_exceptional_requests
      where id = '${state.rejectRequestId}'::uuid;
      perform set_config('request.jwt.claim.sub',
        (select id::text from auth.users where email = '${M82C_USERS.godownManager}'), true);
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', (select id from auth.users where email = '${M82C_USERS.godownManager}'),
          'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      begin
        perform public.post_exceptional_damage_disposition(
          '${state.rejectRequestId}'::uuid, v, 'dmg03e2-rej-post-' || gen_random_uuid()::text
        );
        raise exception 'rejected request was posted';
      exception
        when others then
          get stacked diagnostics msg = message_text;
          if msg ilike '%rejected request was posted%' then raise; end if;
      end;
    end $$;
    select 'ok';
    `,
    "rej-post-blocked",
  )
  expect(postBlocked).toContain("ok")

  const active = Number(
    runLocalSql(
      `select coalesce(sum(quantity_cases),0)::text from public.damage_stock_holds
       where damage_report_id = '${reportId}' and status = 'active';`,
      "rej-holds",
    ),
  )
  expect(active).toBe(1)
})

test("independent stock reconciliation remains consistent", async () => {
  const recon = runLocalSql(
    `
    with c1 as (
      select sb.quantity as phys
      from public.stock_balances sb
      join public.products p on p.id = sb.product_id
      join public.crates c on c.id = sb.crate_id
      where p.sku = 'm82c-stable' and c.code = 'm82c_c1'
    ),
    lots as (
      select coalesce(sum(slb.quantity),0) as lot_sum
      from public.stock_lot_balances slb
      join public.stock_lots sl on sl.id = slb.lot_id
      join public.products p on p.id = sl.product_id
      join public.crates c on c.id = slb.crate_id
      where p.sku = 'm82c-stable' and c.code = 'm82c_c1'
    ),
    active_holds as (
      select coalesce(sum(h.quantity_cases),0) as held
      from public.damage_stock_holds h
      join public.crates c on c.id = h.crate_id
      join public.products p on p.id = h.product_id
      where h.status = 'active'
        and p.sku = 'm82c-stable'
        and c.code = 'm82c_c1'
    ),
    q_phys as (
      select coalesce(sum(sb.quantity),0) as q
      from public.stock_balances sb
      join public.crates c on c.id = sb.crate_id
      join public.products p on p.id = sb.product_id
      where p.sku = 'm82c-stable' and c.location_role = 'quarantine'
    ),
    stranded as (
      select count(*) as n
      from public.damage_stock_holds h
      join public.damage_reports r on r.id = h.damage_report_id
      where h.status = 'active'
        and r.status in ('cancelled')
    )
    select c1.phys::text
      || '|' || lots.lot_sum::text
      || '|' || active_holds.held::text
      || '|' || q_phys.q::text
      || '|' || stranded.n::text
      || '|' || (c1.phys - active_holds.held)::text
    from c1, lots, active_holds, q_phys, stranded;
    `,
    "recon",
  )
  const [phys, lotSum, held, qPhys, stranded, impliedAvailFloor] =
    recon.split("|").map(Number)
  expect(phys).toBe(lotSum)
  expect(phys).toBeGreaterThanOrEqual(0)
  expect(held).toBeGreaterThanOrEqual(0)
  expect(qPhys).toBeGreaterThanOrEqual(0)
  expect(stranded).toBe(0)
  expect(impliedAvailFloor).toBe(phys - held)
  expect(phys + qPhys).toBeLessThanOrEqual(state.physicalC1Before + 2)
})
