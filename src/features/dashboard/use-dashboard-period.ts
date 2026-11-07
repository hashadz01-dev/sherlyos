/**
 * Period UI state for the operations dashboard.
 * Snapshot RPCs ignore these dates. Until get_operations_dashboard_period is
 * approved and OPERATIONS_PERIOD_RPC_ENABLED flips, the UI stays locked to
 * Current Snapshot.
 */

import { OPERATIONS_PERIOD_RPC_ENABLED } from "@/lib/reports/api"
import {
  periodWindowForPreset,
  todayUtc,
  type PeriodPresetId,
  type PeriodWindow,
} from "@/features/dashboard/period-window"

export type PeriodPreset = "snapshot" | PeriodPresetId

export type DashboardPeriod = {
  preset: PeriodPreset
  fromDate: string
  toDate: string
}

/**
 * Locked snapshot period. Historical presets stay disabled until Phase 3 deploy.
 * Window builders in period-window.ts are ready for staging once the flag flips.
 */
export function useDashboardPeriod() {
  const today = todayUtc()
  const period: DashboardPeriod = {
    preset: "snapshot",
    fromDate: today,
    toDate: today,
  }

  return {
    period,
    isDefault: true,
    periodReportingEnabled: OPERATIONS_PERIOD_RPC_ENABLED,
    /** Preview helper for tests / future unlock — does not drive snapshot KPIs. */
    previewWindow: (preset: Exclude<PeriodPresetId, "custom">): PeriodWindow =>
      periodWindowForPreset(preset, today),
    setPreset: (_preset: PeriodPreset) => {
      /* Period reporting disabled — no-op until approved deployment. */
    },
    setCustomFrom: (_value: string) => {
      /* Period reporting disabled — no-op until approved deployment. */
    },
    setCustomTo: (_value: string) => {
      /* Period reporting disabled — no-op until approved deployment. */
    },
    clearToDefault: () => {
      /* Snapshot is already the only mode. */
    },
  }
}

export function periodLabel(period: DashboardPeriod) {
  if (period.preset === "snapshot") return "Current Snapshot"
  if (period.preset === "today") return "Today (UTC)"
  if (period.preset === "7d") return "Last 7 days (UTC)"
  if (period.preset === "30d") return "Last 30 days (UTC)"
  return `${period.fromDate} → ${period.toDate} (UTC)`
}
