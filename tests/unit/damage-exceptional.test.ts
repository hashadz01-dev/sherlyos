import { describe, expect, it } from "vitest"
import { formatDamageEventAction } from "@/features/damage/utils/labels"
import { damageLifecycleStages } from "@/features/damage/utils/lifecycle"
import {
  mapDamageMutationError,
  reportHasCompletedExceptionalDisposition,
} from "@/features/damage/utils/submit"
import type { DamageReportDetail } from "@/lib/damage/api"
import {
  canApproveExceptionalDisposition,
  canExecuteExceptionalDisposition,
  canRejectExceptionalDisposition,
  canRequestExceptionalDisposition,
  collectExceptionalExecuteBlockers,
  collectExceptionalRejectBlockers,
  collectExceptionalRequestBlockers,
  formatExceptionalStatus,
} from "@/lib/damage/rules"

const eligibleRequest = {
  status: "verified",
  scenario: "storage",
  canVerify: true,
  hasFinalizedEvidence: true,
  remainingHoldCases: 2,
  ordinaryPosted: false,
  exceptionalOpen: false,
  exceptionalPosted: false,
  godownActive: true,
}

describe("exceptional request eligibility", () => {
  it("allows GM request of verified storage with remaining holds", () => {
    expect(canRequestExceptionalDisposition(eligibleRequest)).toBe(true)
  })

  it("allows rejected shop-return with remaining quarantine", () => {
    expect(
      canRequestExceptionalDisposition({
        ...eligibleRequest,
        status: "rejected",
        scenario: "shop_return",
      }),
    ).toBe(true)
  })

  it("blocks inbound, ordinary posted, and open requests", () => {
    expect(
      collectExceptionalRequestBlockers({
        ...eligibleRequest,
        scenario: "refill_supply",
      }).some((row) => row.code === "scenario"),
    ).toBe(true)
    expect(
      collectExceptionalRequestBlockers({
        ...eligibleRequest,
        ordinaryPosted: true,
      }).some((row) => row.code === "posted"),
    ).toBe(true)
    expect(
      collectExceptionalRequestBlockers({
        ...eligibleRequest,
        exceptionalOpen: true,
      }).some((row) => row.code === "open"),
    ).toBe(true)
  })
})

describe("exceptional approval and execution", () => {
  it("keeps approval as an authorization event", () => {
    expect(
      canApproveExceptionalDisposition({
        canDispose: true,
        requestStatus: "requested",
      }),
    ).toBe(true)
    expect(
      canApproveExceptionalDisposition({
        canDispose: true,
        requestStatus: "approved",
      }),
    ).toBe(false)
    expect(
      canExecuteExceptionalDisposition({
        canVerify: true,
        requestStatus: "requested",
        remainingHoldCases: 2,
        godownActive: true,
      }),
    ).toBe(false)
  })

  it("allows GM execution only after approval", () => {
    expect(
      canExecuteExceptionalDisposition({
        canVerify: true,
        requestStatus: "approved",
        remainingHoldCases: 2,
        godownActive: true,
      }),
    ).toBe(true)
    expect(
      collectExceptionalExecuteBlockers({
        canVerify: false,
        requestStatus: "approved",
        remainingHoldCases: 2,
        godownActive: true,
      }).some((row) => row.code === "permission"),
    ).toBe(true)
  })

  it("labels approved as pending execution", () => {
    expect(formatExceptionalStatus("approved")).toMatch(/pending execution/i)
    expect(formatExceptionalStatus("posted")).toMatch(/ledger complete/i)
    expect(formatDamageEventAction("exceptional_posted")).toMatch(
      /ledger complete/i,
    )
    expect(formatDamageEventAction("ordinary_writeoff")).toMatch(
      /ordinary write-off posted/i,
    )
  })

  it("requires Admin damage.dispose for rejection and a requested status", () => {
    expect(
      canRejectExceptionalDisposition({
        canDispose: true,
        requestStatus: "requested",
      }),
    ).toBe(true)
    expect(
      collectExceptionalRejectBlockers({
        canDispose: false,
        requestStatus: "requested",
      }).some((row) => row.code === "permission"),
    ).toBe(true)
    expect(
      canRejectExceptionalDisposition({
        canDispose: true,
        requestStatus: "approved",
      }),
    ).toBe(false)
  })
})

describe("exceptional recovery and lifecycle", () => {
  it("maps ambiguous posting errors to refresh without retrying", () => {
    expect(
      mapDamageMutationError(new Error("Failed to fetch"), "exceptional-post"),
    ).toMatch(/refresh the report/i)
    expect(
      mapDamageMutationError(
        new Error("an ordinary write-off is already posted"),
        "exceptional-request",
      ),
    ).toMatch(/ordinary write-off/i)
  })

  it("identifies a completed exceptional posting from the payload", () => {
    expect(
      reportHasCompletedExceptionalDisposition({
        exceptional_requests: [{ id: "r1", kind: "destroy", status: "posted", version: 3 }],
        events: [{ action: "exceptional_posted" }],
      } as unknown as DamageReportDetail),
    ).toBe(true)
  })

  it("keeps requested, approved, and executed as distinct stages", () => {
    const stages = damageLifecycleStages({
      id: "r1",
      report_number: "DMG-1",
      scenario: "storage",
      godown_id: "g1",
      godown_name: "G",
      status: "verified",
      version: 3,
      reporter_name: "GM",
      created_at: "2026-10-26T10:00:00Z",
      receipt_id: null,
      picking_request_id: null,
      dispatch_id: null,
      order_id: null,
      shop_id: null,
      notes: null,
      verified_at: "2026-10-26T12:00:00Z",
      lines: [],
      holds: [
        {
          id: "h1",
          line_id: "l1",
          product_id: "p1",
          crate_id: "c1",
          lot_id: null,
          quantity_cases: 2,
          hold_kind: "on_hand_deduction",
          status: "written_off",
        },
      ],
      events: [
        {
          action: "exceptional_requested",
          actor_name: "GM",
          previous_status: "verified",
          next_status: "verified",
          created_at: "2026-10-26T13:00:00Z",
          metadata: {},
        },
        {
          action: "exceptional_approved",
          actor_name: "Admin",
          previous_status: "verified",
          next_status: "verified",
          created_at: "2026-10-26T13:05:00Z",
          metadata: {},
        },
        {
          action: "exceptional_posted",
          actor_name: "GM",
          previous_status: "verified",
          next_status: "verified",
          created_at: "2026-10-26T13:10:00Z",
          metadata: { transaction_id: "txn-1" },
        },
      ],
      evidence: [],
      exceptional_requests: [
        {
          id: "ex1",
          kind: "destroy",
          status: "posted",
          version: 3,
          requested_at: "2026-10-26T13:00:00Z",
          decided_at: "2026-10-26T13:05:00Z",
          posted_at: "2026-10-26T13:10:00Z",
        },
      ],
    } as DamageReportDetail)
    expect(stages.find((row) => row.id === "exceptional_requested")?.complete).toBe(
      true,
    )
    expect(stages.find((row) => row.id === "exceptional_approved")?.complete).toBe(
      true,
    )
    expect(stages.find((row) => row.id === "exceptional_posted")?.complete).toBe(
      true,
    )
    expect(
      stages.find((row) => row.id === "exceptional_approved")?.description,
    ).toMatch(/inventory has not been posted/i)
    expect(
      stages.find((row) => row.id === "exceptional_posted")?.description,
    ).toMatch(/not independently recorded/i)
    expect(
      stages.find((row) => row.id === "ordinary_writeoff")?.complete,
    ).toBe(false)
    expect(
      stages.find((row) => row.id === "ordinary_writeoff")?.applicable,
    ).toBe(false)
  })

  it("keeps ordinary write-off available after an exceptional rejection", () => {
    const stages = damageLifecycleStages({
      id: "r1",
      report_number: "DMG-1",
      scenario: "storage",
      godown_id: "g1",
      godown_name: "G",
      status: "verified",
      version: 4,
      reporter_name: "GM",
      created_at: "2026-10-26T10:00:00Z",
      receipt_id: null,
      picking_request_id: null,
      dispatch_id: null,
      order_id: null,
      shop_id: null,
      notes: null,
      verified_at: "2026-10-26T12:00:00Z",
      lines: [],
      holds: [
        {
          id: "h1",
          line_id: "l1",
          product_id: "p1",
          crate_id: "c1",
          lot_id: null,
          quantity_cases: 2,
          hold_kind: "on_hand_deduction",
          status: "active",
        },
      ],
      events: [
        {
          action: "exceptional_rejected",
          actor_name: "Admin",
          previous_status: "verified",
          next_status: "verified",
          created_at: "2026-10-26T13:00:00Z",
          metadata: {},
        },
      ],
      evidence: [],
      exceptional_requests: [
        {
          id: "ex1",
          kind: "destroy",
          status: "rejected",
          version: 2,
          requested_at: "2026-10-26T12:30:00Z",
          decided_at: "2026-10-26T13:00:00Z",
        },
      ],
    } as DamageReportDetail)
    expect(
      stages.find((row) => row.id === "ordinary_writeoff")?.applicable,
    ).toBe(true)
    expect(
      stages.find((row) => row.id === "ordinary_writeoff")?.complete,
    ).toBe(false)
  })
})
