import { describe, expect, it } from "vitest"
import {
  DASHBOARD_DESTINATIONS,
  DASHBOARD_QUICK_ACTIONS,
  queueSeverity,
} from "@/features/dashboard/metric-map"
import { buildAttentionItems } from "@/features/dashboard/AttentionQueue"
import { periodLabel } from "@/features/dashboard/use-dashboard-period"
import { availablePickDisplay, kpiNumber } from "@/features/dashboard/kpi-display"
import { OPERATIONS_PERIOD_RPC_ENABLED } from "@/lib/reports/api"
import type { OperationsDashboard } from "@/lib/reports/api"

const emptyDash = {
  timezone: "UTC",
  filter_branch: null,
  authorized_branches: [],
  cutover: { dual_write_enabled: false, aggregate_only_blocked: false },
  inventory: { visible: false },
  orders: { visible: false },
  picking: { visible: false },
  dispatch: { visible: false },
  deliveries: { visible: false },
  operations: { visible: false },
} satisfies OperationsDashboard

describe("dashboard metric map", () => {
  it("keeps quick actions on known path-only destinations", () => {
    for (const action of DASHBOARD_QUICK_ACTIONS) {
      expect(action.to.startsWith("/")).toBe(true)
      expect(action.to.includes("?")).toBe(false)
    }
    expect(DASHBOARD_DESTINATIONS.inventory).toBe("/inventory")
    expect(DASHBOARD_DESTINATIONS.damageVerification).toBe(
      "/damage/verification",
    )
  })

  it("maps severity from operational meaning", () => {
    expect(queueSeverity("exception")).toBe("danger")
    expect(queueSeverity("blocked")).toBe("warning")
    expect(queueSeverity("held")).toBe("warning")
    expect(queueSeverity("work")).toBe("info")
    expect(queueSeverity("policy")).toBe("warning")
  })

  it("omits zero attention queues and keeps exceptions", () => {
    const items = buildAttentionItems({
      ...emptyDash,
      orders: {
        visible: true,
        held: 2,
        awaiting_picking: 0,
        draft: 0,
        submitted: 0,
        verified: 0,
        cancelled: 0,
      },
      picking: {
        visible: true,
        blocked: 1,
        exception_rows: 0,
        allocated: 0,
        picking: 0,
        picked: 0,
        ready_for_dispatch: 0,
      },
    })
    expect(items.map((item) => item.id)).toEqual([
      "orders-held",
      "packing-blocked",
    ])
    expect(items.find((item) => item.id === "orders-held")?.severity).toBe(
      "warning",
    )
  })

  it("defaults reporting display to Current Snapshot while period RPC is off", () => {
    expect(OPERATIONS_PERIOD_RPC_ENABLED).toBe(false)
    expect(periodLabel({ preset: "snapshot", fromDate: "2026-01-01", toDate: "2026-01-01" })).toBe(
      "Current Snapshot",
    )
  })

  it("keeps zero numeric and unavailable distinct from unauthorized omission", () => {
    expect(kpiNumber(0, true)).toEqual({ value: 0, unavailable: false })
    expect(kpiNumber(undefined, true)).toEqual({ value: null, unavailable: true })
    expect(kpiNumber(5, false)).toEqual({ value: null, unavailable: true })
    expect(
      availablePickDisplay(
        {
          state: "not_applicable",
          reason: "lot_aware_allocation_inactive",
          value: null,
        },
        true,
      ).unavailable,
    ).toBe(true)
  })
})
