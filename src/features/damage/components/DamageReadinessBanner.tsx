import { readinessMessage } from "@/features/damage/utils/labels"

export function DamageReadinessBanner({
  stockHoldReady,
}: {
  stockHoldReady: boolean
}) {
  return (
    <aside
      role="status"
      className={
        stockHoldReady
          ? "rounded-2xl bg-emerald-50 px-4 py-3 text-sm text-emerald-900 ring-1 ring-emerald-200"
          : "rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200"
      }
    >
      <p className="font-medium">
        {stockHoldReady
          ? "Damage stock isolation ready"
          : "Damage stock isolation not ready"}
      </p>
      <p className="mt-1 text-sm opacity-90">
        {readinessMessage(stockHoldReady)}
      </p>
    </aside>
  )
}
