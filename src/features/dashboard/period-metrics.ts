import type {
  DashboardPeriodMetric,
  OperationsDashboardPeriod,
} from "@/lib/reports/api"
import {
  zeroFillSeries,
  type PeriodWindow,
} from "@/features/dashboard/period-window"

/** Stable API keys → owner-approved display labels. */
export const PERIOD_METRIC_LABELS = {
  orders_created: "Orders created",
  picking_completed: "Packing handoffs",
  dispatches_consumed: "Dispatches confirmed",
  receipts_created: "Receipts created",
  damage_reports_created: "Damage reports created",
} as const

export type PeriodMetricKey = keyof typeof PERIOD_METRIC_LABELS

export type PreparedPeriodMetric = {
  key: PeriodMetricKey
  label: string
  visible: boolean
  total: number | null
  series: { day: string; count: number }[] | null
  state: "ready" | "unavailable" | "unauthorized"
}

/**
 * Prepare period metrics for charts. Unauthorized stay unavailable (not zero).
 * Zero-fill only when the metric is visible and the RPC returned successfully.
 */
export function preparePeriodMetrics(
  payload: OperationsDashboardPeriod | null | undefined,
  window: PeriodWindow,
): PreparedPeriodMetric[] {
  return (Object.keys(PERIOD_METRIC_LABELS) as PeriodMetricKey[]).map((key) => {
    const label = PERIOD_METRIC_LABELS[key]
    if (!payload) {
      return {
        key,
        label,
        visible: false,
        total: null,
        series: null,
        state: "unavailable" as const,
      }
    }
    const metric = payload[key] as DashboardPeriodMetric
    if (!metric?.visible) {
      return {
        key,
        label,
        visible: false,
        total: null,
        series: null,
        state: "unauthorized" as const,
      }
    }
    return {
      key,
      label: metric.label ?? label,
      visible: true,
      total: metric.total,
      series: zeroFillSeries(window, metric.series ?? []),
      state: "ready" as const,
    }
  })
}

/** Guards against inventing historical stock from snapshot fields. */
export const PERIOD_EXCLUDED_SNAPSHOT_FIELDS = [
  "total_cartons_on_hand",
  "active_reserved_cartons",
  "available_to_pick",
  "lot_attributed_cartons",
] as const
