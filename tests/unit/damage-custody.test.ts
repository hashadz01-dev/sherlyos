import { describe, expect, it } from "vitest"
import {
  formatHoldKind,
  formatHoldStatus,
  formatIsolationClass,
  readinessMessage,
} from "@/features/damage/utils/labels"
import {
  damageLifecycleStages,
  rejectedShopReturnStillQuarantined,
} from "@/features/damage/utils/lifecycle"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import type { DamageReportDetail } from "@/lib/damage/api"
import {
  canConfirmShopReturnCustody,
  canTransferVerifiedDamage,
  damageQuarantinePermissions,
} from "@/lib/damage/rules"

function report(partial: Partial<DamageReportDetail> = {}): DamageReportDetail {
  return {
    id: "r1",
    report_number: "DMG-C1",
    scenario: "shop_return",
    godown_id: "g1",
    godown_name: "Main Godown",
    status: "draft",
    version: 1,
    reporter_name: "GM",
    created_at: "2026-10-26T10:00:00Z",
    receipt_id: null,
    picking_request_id: null,
    dispatch_id: null,
    order_id: null,
    shop_id: "s1",
    shop_name: "Corner Shop",
    notes: null,
    physical_custody_confirmed: false,
    lines: [
      {
        id: "l1",
        product_id: "p1",
        product_sku: "SKU-1",
        product_name: "Carton A",
        crate_id: "c1",
        crate_code: "CR-1",
        lot_id: null,
        quantity_cases: 2,
        damage_reason: "expired",
        notes: null,
        receipt_line_id: null,
      },
    ],
    holds: [],
    exceptional_requests: [],
    events: [
      {
        action: "create",
        actor_name: "GM",
        previous_status: null,
        next_status: "draft",
        created_at: "2026-10-26T10:00:00Z",
        metadata: {},
      },
    ],
    evidence: [],
    ...partial,
  }
}

describe("custody and transfer eligibility", () => {
  it("allows Godown Manager custody on editable shop-return drafts only", () => {
    expect(
      canConfirmShopReturnCustody({
        scenario: "shop_return",
        status: "draft",
        alreadyConfirmed: false,
        canRecord: true,
        canVerify: true,
      }),
    ).toBe(true)
    expect(
      canConfirmShopReturnCustody({
        scenario: "shop_return",
        status: "draft",
        alreadyConfirmed: true,
        canRecord: true,
        canVerify: true,
      }),
    ).toBe(false)
    expect(
      canConfirmShopReturnCustody({
        scenario: "shop_return",
        status: "submitted",
        alreadyConfirmed: false,
        canRecord: true,
        canVerify: true,
      }),
    ).toBe(false)
  })

  it("denies Store Keeper and Delivery Person custody confirmation", () => {
    expect(
      canConfirmShopReturnCustody({
        scenario: "shop_return",
        status: "draft",
        alreadyConfirmed: false,
        canRecord: true,
        canVerify: false,
      }),
    ).toBe(false)
    expect(
      canConfirmShopReturnCustody({
        scenario: "shop_return",
        status: "draft",
        alreadyConfirmed: false,
        canRecord: false,
        canVerify: false,
      }),
    ).toBe(false)
  })

  it("allows verified storage transfer only when on-hand holds remain", () => {
    expect(
      canTransferVerifiedDamage({
        scenario: "storage",
        status: "verified",
        canVerify: true,
        activeOnHandHolds: 1,
      }),
    ).toBe(true)
    expect(
      canTransferVerifiedDamage({
        scenario: "shop_return",
        status: "verified",
        canVerify: true,
        activeOnHandHolds: 1,
      }),
    ).toBe(false)
    expect(
      canTransferVerifiedDamage({
        scenario: "storage",
        status: "verified",
        canVerify: true,
        activeOnHandHolds: 0,
      }),
    ).toBe(false)
  })

  it("keeps quarantine inventory off the delivery-person permission set", () => {
    expect(damageQuarantinePermissions).not.toContain("deliveries.execute")
  })
})

describe("quarantine and hold labels", () => {
  it("labels hold kinds and statuses without calling a logical hold physical", () => {
    expect(formatHoldKind("on_hand_deduction")).toMatch(/on-hand hold/i)
    expect(formatHoldKind("reservation_conversion")).toMatch(/converted/i)
    expect(formatHoldKind("quarantine_intake")).toMatch(/shop-return/i)
    expect(formatHoldStatus("active")).toBe("Held")
    expect(formatHoldStatus("transferred")).toBe("Quarantined")
    expect(formatHoldStatus("written_off")).toBe("Written off")
    expect(formatIsolationClass("logical_hold")).toMatch(/logical/i)
    expect(formatIsolationClass("logical_hold")).not.toMatch(/physical/i)
    expect(formatIsolationClass("transferred_quarantine")).toMatch(
      /physically/i,
    )
  })

  it("keeps readiness copy free of the configuration key", () => {
    expect(readinessMessage(false)).not.toMatch(/damage\.stock_hold_ready/)
  })
})

describe("lifecycle mapping", () => {
  it("uses persisted custody and hold timestamps only", () => {
    const stages = damageLifecycleStages(
      report({
        physical_custody_confirmed: true,
        physical_custody_confirmed_at: "2026-10-26T11:00:00Z",
        physical_custody_confirmed_by_name: "GM",
        holds: [
          {
            id: "h1",
            line_id: "l1",
            product_id: "p1",
            crate_id: "q1",
            location_role: "quarantine",
            lot_id: null,
            quantity_cases: 2,
            hold_kind: "quarantine_intake",
            status: "active",
            created_at: "2026-10-26T12:00:00Z",
          },
        ],
        status: "rejected",
        events: [
          {
            action: "custody_confirmed",
            actor_name: "GM",
            previous_status: "draft",
            next_status: "draft",
            created_at: "2026-10-26T11:00:00Z",
            metadata: {},
          },
        ],
      }),
    )
    const custody = stages.find((row) => row.id === "custody_confirmed")
    const quarantined = stages.find((row) => row.id === "quarantined")
    expect(custody?.complete).toBe(true)
    expect(custody?.at).toBe("2026-10-26T11:00:00Z")
    expect(quarantined?.complete).toBe(true)
    expect(quarantined?.at).toBe("2026-10-26T12:00:00Z")
  })

  it("keeps rejected shop-return stock quarantined until disposition", () => {
    expect(
      rejectedShopReturnStillQuarantined(
        report({
          status: "rejected",
          holds: [
            {
              id: "h1",
              line_id: "l1",
              product_id: "p1",
              crate_id: "q1",
              location_role: "quarantine",
              lot_id: null,
              quantity_cases: 2,
              hold_kind: "quarantine_intake",
              status: "active",
            },
          ],
        }),
      ),
    ).toBe(true)
  })
})

describe("custody and transfer error mapping", () => {
  it("maps inactive godown and missing isolation without retrying", () => {
    expect(mapDamageMutationError("godown is inactive", "transfer")).toMatch(
      /inactive/i,
    )
    expect(
      mapDamageMutationError("no isolated damage quantity remains", "transfer"),
    ).toMatch(/refresh/i)
    expect(mapDamageMutationError("Failed to fetch", "transfer")).toMatch(
      /refresh the report/i,
    )
    expect(mapDamageMutationError("Failed to fetch", "custody")).toMatch(
      /refresh the report/i,
    )
  })
})
