import type { KpiValue } from "@/lib/reports/api"

/** A missing authorized field stays hidden. Do not paint it as zero. */
export function kpiNumber(value: number | undefined, visible: boolean) {
  if (!visible || value === undefined) {
    return { value: null as number | null, unavailable: true }
  }
  return { value, unavailable: false }
}

/** ATP is a lot-aware measure. Aggregate on-hand is not a substitute. */
export function availablePickDisplay(
  metric: KpiValue | undefined,
  visible: boolean,
) {
  if (!visible || !metric) {
    return {
      value: null as number | string | null,
      unavailable: true,
      hint: "Not authorized",
    }
  }
  if (metric.state === "not_applicable") {
    return {
      value: null as number | string | null,
      unavailable: true,
      hint: "Lot-aware allocation is inactive. Aggregate on-hand is not available-to-pick.",
    }
  }
  return {
    value: metric.value,
    unavailable: false,
    hint: "Lot-available carton cases",
  }
}
