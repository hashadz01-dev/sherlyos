import type { LucideIcon } from "lucide-react"
import { Inbox } from "lucide-react"

export function EmptyState({
  title,
  description,
  icon: Icon = Inbox,
}: {
  title: string
  description: string
  icon?: LucideIcon
}) {
  return (
    <div className="flex flex-col items-center px-6 py-10 text-center">
      <span className="flex size-11 items-center justify-center rounded-2xl bg-slate-100 text-slate-500">
        <Icon className="size-5" aria-hidden="true" />
      </span>
      <h2 className="mt-4 text-base font-semibold text-foreground">{title}</h2>
      <p className="mt-1 max-w-md text-sm leading-6 text-muted-foreground">
        {description}
      </p>
    </div>
  )
}
