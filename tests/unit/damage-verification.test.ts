import { describe, expect, it } from "vitest"
import { damageLifecycleStages } from "@/features/damage/utils/lifecycle"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import type { DamageReportDetail } from "@/lib/damage/api"
import { reportHasCompletedOrdinaryWriteoff } from "@/features/damage/utils/submit"
import {
  canPostOrdinaryDamageWriteoff,
  canRejectDamageReport,
  canReturnDamageReport,
  canVerifyDamageReport,
  collectOrdinaryWriteoffBlockers,
  collectVerificationBlockers,
  formatVerificationQueueState,
  isValidDecisionReason,
  verificationQueueState,
} from "@/lib/damage/rules"

const eligibleVerify = {
  status: "submitted",
  scenario: "refill_supply",
  canVerify: true,
  isReporter: false,
  hasFinalizedEvidence: true,
  reportedCases: 2,
  isolatedCases: 0,
  godownActive: true,
}

describe("verification eligibility", () => {
  it("allows GM verification of submitted inbound with finalized evidence", () => {
    expect(canVerifyDamageReport(eligibleVerify)).toBe(true)
    expect(collectVerificationBlockers(eligibleVerify)).toHaveLength(0)
  })

  it("blocks self-verification even when other facts are ready", () => {
    const blockers = collectVerificationBlockers({
      ...eligibleVerify,
      isReporter: true,
    })
    expect(blockers.some((row) => row.code === "self")).toBe(true)
    expect(canVerifyDamageReport({ ...eligibleVerify, isReporter: true })).toBe(
      false,
    )
  })

  it("blocks missing evidence and incomplete isolation", () => {
    expect(
      collectVerificationBlockers({
        ...eligibleVerify,
        hasFinalizedEvidence: false,
      }).some((row) => row.code === "evidence"),
    ).toBe(true)
    expect(
      collectVerificationBlockers({
        ...eligibleVerify,
        scenario: "storage",
        isolatedCases: 0,
        reportedCases: 2,
      }).some((row) => row.code === "isolation"),
    ).toBe(true)
  })

  it("blocks inactive godown, mismatched holds, and unsubmitted custody", () => {
    expect(
      collectVerificationBlockers({
        ...eligibleVerify,
        godownActive: false,
      }).some((row) => row.code === "godown"),
    ).toBe(true)
    expect(
      collectVerificationBlockers({
        ...eligibleVerify,
        scenario: "storage",
        isolatedCases: 1,
        reportedCases: 2,
      }).some((row) => row.code === "quantity"),
    ).toBe(true)
    expect(
      collectVerificationBlockers({
        ...eligibleVerify,
        status: "draft",
        scenario: "shop_return",
      }).some((row) => row.code === "status"),
    ).toBe(true)
  })
})

describe("return and reject eligibility", () => {
  it("forbids returning submitted shop-return", () => {
    expect(
      canReturnDamageReport({
        status: "submitted",
        scenario: "shop_return",
        canVerify: true,
        godownActive: true,
      }),
    ).toBe(false)
  })

  it("allows return of submitted inbound", () => {
    expect(
      canReturnDamageReport({
        status: "submitted",
        scenario: "refill_supply",
        canVerify: true,
        godownActive: true,
      }),
    ).toBe(true)
  })

  it("blocks reporter rejection and requires a reason", () => {
    expect(
      canRejectDamageReport({
        status: "submitted",
        canVerify: true,
        isReporter: true,
        godownActive: true,
      }),
    ).toBe(false)
    expect(isValidDecisionReason("")).toBe(false)
    expect(isValidDecisionReason("needs more photos")).toBe(true)
  })
})

describe("ordinary write-off eligibility", () => {
  const ready = {
    status: "verified",
    scenario: "storage",
    canVerify: true,
    hasFinalizedEvidence: true,
    remainingHoldCases: 2,
    exceptionalOpen: false,
    alreadyWrittenOff: false,
    godownActive: true,
  }

  it("allows verified storage with remaining holds", () => {
    expect(canPostOrdinaryDamageWriteoff(ready)).toBe(true)
  })

  it("blocks inbound and already posted write-offs", () => {
    expect(
      collectOrdinaryWriteoffBlockers({
        ...ready,
        scenario: "refill_supply",
      }).some((row) => row.code === "scenario"),
    ).toBe(true)
    expect(
      collectOrdinaryWriteoffBlockers({
        ...ready,
        remainingHoldCases: 0,
        alreadyWrittenOff: true,
      }).some((row) => row.code === "posted"),
    ).toBe(true)
  })
})

describe("verification queue labels and error mapping", () => {
  it("distinguishes blocked evidence from eligible submitted rows", () => {
    expect(
      formatVerificationQueueState(
        verificationQueueState({
          status: "submitted",
          scenario: "refill_supply",
          hasFinalizedEvidence: false,
        }),
      ),
    ).toMatch(/missing evidence/i)
    expect(
      formatVerificationQueueState(
        verificationQueueState({
          status: "submitted",
          scenario: "refill_supply",
          hasFinalizedEvidence: true,
        }),
      ),
    ).toMatch(/eligible/i)
  })

  it("keeps verification and ordinary write-off as separate lifecycle stages", () => {
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
      lines: [
        {
          id: "l1",
          product_id: "p1",
          product_sku: "SKU",
          product_name: "Soap",
          crate_id: "c1",
          crate_code: "C1",
          lot_id: null,
          quantity_cases: 2,
          damage_reason: "crushed",
          notes: null,
          receipt_line_id: null,
        },
      ],
      holds: [
        {
          id: "h1",
          line_id: "l1",
          product_id: "p1",
          crate_id: "c1",
          quantity_cases: 2,
          hold_kind: "on_hand_deduction",
          status: "written_off",
        },
      ],
      events: [
        {
          action: "verified",
          actor_name: "Verifier",
          previous_status: "submitted",
          next_status: "verified",
          created_at: "2026-10-26T12:00:00Z",
          metadata: {},
        },
        {
          action: "ordinary_writeoff",
          actor_name: "Verifier",
          previous_status: "verified",
          next_status: "verified",
          created_at: "2026-10-26T13:00:00Z",
          metadata: { transaction_id: "txn-1" },
        },
      ],
      evidence: [
        {
          id: "e1",
          finalized: true,
          mime_type: "image/jpeg",
          uploaded_at: "2026-10-26T11:00:00Z",
        },
      ],
    } as DamageReportDetail)
    const verified = stages.find((row) => row.id === "verified")
    const writeoff = stages.find((row) => row.id === "ordinary_writeoff")
    expect(verified?.complete).toBe(true)
    expect(verified?.at).toBe("2026-10-26T12:00:00Z")
    expect(writeoff?.complete).toBe(true)
    expect(writeoff?.at).toBe("2026-10-26T13:00:00Z")
  })

  it("maps self-verify and write-off errors without retrying", () => {
    expect(
      mapDamageMutationError(
        new Error("the reporter cannot verify this damage report"),
        "verify",
      ),
    ).toMatch(/reporter cannot verify/i)
    expect(
      mapDamageMutationError(new Error("Failed to fetch"), "writeoff"),
    ).toMatch(/refresh the report/i)
    expect(
      mapDamageMutationError(
        new Error("changed by someone else"),
        "writeoff",
      ),
    ).toMatch(/refresh/i)
  })

  it("identifies a completed ordinary write-off from the report payload", () => {
    expect(
      reportHasCompletedOrdinaryWriteoff({
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
        events: [{ action: "ordinary_writeoff" }],
      } as unknown as DamageReportDetail),
    ).toBe(true)
    expect(
      reportHasCompletedOrdinaryWriteoff({
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
        events: [],
      } as unknown as DamageReportDetail),
    ).toBe(false)
    expect(
      reportHasCompletedOrdinaryWriteoff({
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
        events: [{ action: "exceptional_posted" }],
      } as unknown as DamageReportDetail),
    ).toBe(false)
  })
})
