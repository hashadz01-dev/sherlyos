import {
  activityNote,
  formatDamageEventAction,
  formatDamageStatus,
  formatTimestamp,
} from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"

export function DamageActivityTimeline({
  events,
}: {
  events: DamageReportDetail["events"]
}) {
  if (events.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No activity has been recorded yet.
      </p>
    )
  }

  return (
    <ol className="grid gap-3">
      {events.map((event, index) => {
        const note = activityNote(event.metadata)
        return (
          <li
            key={`${event.created_at}-${event.action}-${index}`}
            className="rounded-xl border border-border/70 bg-card px-3 py-2"
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <p className="font-medium">
                {formatDamageEventAction(event.action)}
              </p>
              <time
                className="text-xs text-muted-foreground"
                dateTime={event.created_at}
              >
                {formatTimestamp(event.created_at)}
              </time>
            </div>
            <p className="mt-1 text-sm text-muted-foreground">
              {event.actor_name ?? "System"}
              {event.previous_status || event.next_status
                ? ` · ${formatDamageStatus(event.previous_status ?? "—")} → ${formatDamageStatus(event.next_status)}`
                : null}
            </p>
            {note ? <p className="mt-1 text-sm">{note}</p> : null}
          </li>
        )
      })}
    </ol>
  )
}
