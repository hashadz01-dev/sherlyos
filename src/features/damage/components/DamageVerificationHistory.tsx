import {
  activityNote,
  formatDamageEventAction,
  formatTimestamp,
} from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"

const verificationActions = new Set([
  "submitted",
  "submit",
  "returned",
  "rejected",
  "custody_confirmed",
  "isolate",
  "isolated",
  "stock_isolated",
  "verified",
  "ordinary_writeoff",
  "quarantine_transferred",
  "holds_released",
  "exceptional_requested",
  "exceptional_approved",
  "exceptional_rejected",
  "exceptional_posted",
])

/** Persisted verification and write-off events only. No fabricated timestamps. */
export function DamageVerificationHistory({
  report,
}: {
  report: DamageReportDetail
}) {
  const rows = (report.events ?? []).filter((event) =>
    verificationActions.has(event.action),
  )
  if (rows.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No verification or write-off events are recorded yet.
      </p>
    )
  }
  return (
    <ol className="grid gap-2 text-sm">
      {rows.map((event, index) => (
        <li
          key={`${event.action}-${event.created_at}-${index}`}
          className="rounded-xl bg-muted/40 px-3 py-2"
        >
          <p className="font-medium">
            {formatDamageEventAction(event.action)} · {event.actor_name ?? "—"}
          </p>
          <p className="text-xs text-muted-foreground">
            {formatTimestamp(event.created_at)}
          </p>
          {activityNote(event.metadata) ? (
            <p className="text-muted-foreground">
              {activityNote(event.metadata)}
            </p>
          ) : null}
          {typeof event.metadata?.transaction_id === "string" ? (
            <p className="font-mono text-xs">
              Stock txn {event.metadata.transaction_id.slice(0, 8)}
            </p>
          ) : null}
        </li>
      ))}
    </ol>
  )
}
