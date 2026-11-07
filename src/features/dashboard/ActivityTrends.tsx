import { PeriodActivityPanel } from "@/features/dashboard/PeriodActivityPanel"

/**
 * Snapshot-mode period notice. Live period fetch stays behind
 * OPERATIONS_PERIOD_RPC_ENABLED — never imply a historical window drives KPIs.
 */
export function ActivityTrends() {
  return <PeriodActivityPanel />
}
