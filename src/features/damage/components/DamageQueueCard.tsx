import { Link } from "react-router"
import { EmptyState } from "@/components/shared/EmptyState"
import { StatusBadge } from "@/components/shared/StatusBadge"
import {
  damageStatusTone,
  formatDamageScenario,
  formatDamageStatus,
  formatDate,
} from "@/features/damage/utils/labels"
import type { DamageQueueItem } from "@/lib/damage/api"
import {
  formatExceptionalStatus,
  type DamageStatus,
} from "@/lib/damage/rules"

export function DamageQueueCard({
  title,
  description,
  items,
  href,
}: {
  title: string
  description: string
  items: DamageQueueItem[]
  href?: string
}) {
  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <header className="mb-3">
        <h2 className="text-sm font-semibold">
          {href ? (
            <Link className="underline-offset-2 hover:underline" to={href}>
              {title}
            </Link>
          ) : (
            title
          )}
        </h2>
        <p className="text-xs text-muted-foreground">{description}</p>
      </header>
      {items.length === 0 ? (
        <EmptyState
          title="No items"
          description="Nothing is waiting in this queue."
        />
      ) : (
        <ul className="grid gap-2">
          {items.map((item) => (
            <li key={`${item.id}-${item.exceptional_status ?? item.status}`}>
              <Link
                to={`/damage/${item.id}`}
                className="flex items-start justify-between gap-3 rounded-xl px-3 py-2 hover:bg-muted/60"
              >
                <div className="min-w-0">
                  <p className="truncate font-medium">{item.report_number}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {formatDamageScenario(item.scenario)} · {item.godown_name}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {formatDate(item.created_at)}
                  </p>
                </div>
                <StatusBadge
                  tone={
                    damageStatusTone[item.status as DamageStatus] ?? "neutral"
                  }
                >
                  {item.exceptional_status
                    ? formatExceptionalStatus(item.exceptional_status)
                    : formatDamageStatus(item.status)}
                </StatusBadge>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
