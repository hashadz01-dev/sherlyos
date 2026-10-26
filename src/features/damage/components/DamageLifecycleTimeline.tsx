import { StatusBadge } from "@/components/shared/StatusBadge"
import {
  damageLifecycleStages,
  rejectedShopReturnStillQuarantined,
} from "@/features/damage/utils/lifecycle"
import { formatTimestamp } from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"

export function DamageLifecycleTimeline({
  report,
}: {
  report: DamageReportDetail
}) {
  const stages = damageLifecycleStages(report).filter(
    (stage) => stage.applicable,
  )
  const stillQuarantined = rejectedShopReturnStillQuarantined(report)

  return (
    <div className="grid gap-3">
      {stillQuarantined ? (
        <p
          role="status"
          className="rounded-xl bg-amber-50 px-3 py-2 text-sm text-amber-950 ring-1 ring-amber-200"
        >
          This shop-return was rejected. Quarantined stock remains unavailable
          until an authorized disposition posts.
        </p>
      ) : null}
      <ol className="grid gap-2">
        {stages.map((stage) => (
          <li
            key={stage.id}
            className="flex flex-wrap items-start justify-between gap-2 rounded-xl border border-border/70 bg-card px-3 py-2"
          >
            <div>
              <p className="font-medium">{stage.label}</p>
              <p className="text-xs text-muted-foreground">
                {stage.description}
              </p>
            </div>
            <div className="text-right">
              <StatusBadge tone={stage.complete ? "success" : "neutral"}>
                {stage.complete ? "Complete" : "Pending"}
              </StatusBadge>
              <p className="mt-1 text-xs text-muted-foreground">
                {stage.complete ? formatTimestamp(stage.at) : "—"}
              </p>
            </div>
          </li>
        ))}
      </ol>
    </div>
  )
}
