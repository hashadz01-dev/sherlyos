import { describe, expect, it } from "vitest"
import {
  PERIOD_EXCLUDED_SNAPSHOT_FIELDS,
  PERIOD_METRIC_LABELS,
  preparePeriodMetrics,
} from "@/features/dashboard/period-metrics"
import {
  PERIOD_MAX_DAYS,
  buildPeriodWindow,
  exclusiveEndUtc,
  inclusiveDayCount,
  inclusiveStartUtc,
  periodWindowForPreset,
  zeroFillSeries,
} from "@/features/dashboard/period-window"
import { OPERATIONS_PERIOD_RPC_ENABLED } from "@/lib/reports/api"
import type { OperationsDashboardPeriod } from "@/lib/reports/api"

describe("dashboard period window", () => {
  it("keeps the period RPC feature flag disabled until owner deployment", () => {
    expect(OPERATIONS_PERIOD_RPC_ENABLED).toBe(false)
  })

  it("builds today / 7d / 30d as half-open UTC windows", () => {
    const today = periodWindowForPreset("today", "2026-11-07")
    expect(today.windowFrom).toBe("2026-11-07T00:00:00.000Z")
    expect(today.windowTo).toBe("2026-11-08T00:00:00.000Z")
    expect(inclusiveDayCount(today.fromDate, today.toDate)).toBe(1)

    const week = periodWindowForPreset("7d", "2026-11-07")
    expect(week.fromDate).toBe("2026-11-01")
    expect(week.toDate).toBe("2026-11-07")
    expect(week.windowFrom).toBe(inclusiveStartUtc("2026-11-01"))
    expect(week.windowTo).toBe(exclusiveEndUtc("2026-11-07"))
    expect(inclusiveDayCount(week.fromDate, week.toDate)).toBe(7)

    const month = periodWindowForPreset("30d", "2026-11-07")
    expect(month.fromDate).toBe("2026-10-09")
    expect(inclusiveDayCount(month.fromDate, month.toDate)).toBe(30)
  })

  it("accepts a 93-day inclusive custom range and rejects 94 days", () => {
    const ok = buildPeriodWindow({
      preset: "custom",
      fromDate: "2026-01-01",
      toDate: "2026-04-03",
    })
    expect(inclusiveDayCount(ok.fromDate, ok.toDate)).toBe(PERIOD_MAX_DAYS)
    expect(ok.windowFrom).toBe("2026-01-01T00:00:00.000Z")
    expect(ok.windowTo).toBe("2026-04-04T00:00:00.000Z")

    expect(() =>
      buildPeriodWindow({
        preset: "custom",
        fromDate: "2026-01-01",
        toDate: "2026-04-04",
      }),
    ).toThrow(/93 days/i)
  })

  it("rejects inverted and invalid calendar dates", () => {
    expect(() =>
      buildPeriodWindow({
        preset: "custom",
        fromDate: "2026-11-08",
        toDate: "2026-11-07",
      }),
    ).toThrow(/after start/i)
    expect(() => exclusiveEndUtc("2026-13-40")).toThrow()
  })

  it("zero-fills sparse series only across the requested UTC calendar days", () => {
    const window = periodWindowForPreset("7d", "2026-11-07")
    const filled = zeroFillSeries(window, [
      { day: "2026-11-01", count: 2 },
      { day: "2026-11-07", count: 5 },
    ])
    expect(filled).toHaveLength(7)
    expect(filled[0]).toEqual({ day: "2026-11-01", count: 2 })
    expect(filled[1]).toEqual({ day: "2026-11-02", count: 0 })
    expect(filled[6]).toEqual({ day: "2026-11-07", count: 5 })
  })

  it("does not turn unauthorized period metrics into zeros", () => {
    const window = periodWindowForPreset("today", "2026-11-07")
    const payload = {
      timezone: "UTC",
      filter_branch: null,
      window_from: window.windowFrom,
      window_to: window.windowTo,
      scope_note: "Period event counts only.",
      orders_created: {
        visible: true,
        label: PERIOD_METRIC_LABELS.orders_created,
        total: 3,
        series: [{ day: "2026-11-07", count: 3 }],
      },
      picking_completed: {
        visible: false,
        label: PERIOD_METRIC_LABELS.picking_completed,
        total: 0,
        series: [],
      },
      dispatches_consumed: {
        visible: false,
        label: PERIOD_METRIC_LABELS.dispatches_consumed,
        total: 0,
        series: [],
      },
      receipts_created: {
        visible: false,
        label: PERIOD_METRIC_LABELS.receipts_created,
        total: 0,
        series: [],
      },
      damage_reports_created: {
        visible: false,
        label: PERIOD_METRIC_LABELS.damage_reports_created,
        total: 0,
        series: [],
      },
    } satisfies OperationsDashboardPeriod

    const prepared = preparePeriodMetrics(payload, window)
    const orders = prepared.find((row) => row.key === "orders_created")
    const packing = prepared.find((row) => row.key === "picking_completed")
    expect(orders?.state).toBe("ready")
    expect(orders?.series).toEqual([{ day: "2026-11-07", count: 3 }])
    expect(packing?.state).toBe("unauthorized")
    expect(packing?.total).toBeNull()
    expect(packing?.series).toBeNull()
  })

  it("uses approved historical labels and excludes snapshot stock fields", () => {
    expect(PERIOD_METRIC_LABELS.picking_completed).toBe("Packing handoffs")
    expect(PERIOD_METRIC_LABELS.dispatches_consumed).toBe("Dispatches confirmed")
    expect(PERIOD_EXCLUDED_SNAPSHOT_FIELDS).toEqual(
      expect.arrayContaining([
        "total_cartons_on_hand",
        "available_to_pick",
        "active_reserved_cartons",
      ]),
    )
  })

  it("documents packing and dispatch event columns for SQL contract tests", () => {
    // Staging SQL must filter/bucket these columns — never updated_at.
    expect({
      packingEvent: "handed_off_at",
      dispatchEvent: "dispatched_at",
      dispatchEligibility: "stock_consumed",
      countingUnit: "request rows",
    }).toMatchObject({
      packingEvent: "handed_off_at",
      dispatchEvent: "dispatched_at",
    })
  })
})
