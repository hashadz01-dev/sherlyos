import type { ReactNode } from "react"

/** Visual row for existing search and select controls. It does not own their state. */
export function FilterBar({
  label,
  children,
}: {
  label: string
  children: ReactNode
}) {
  return (
    <div
      role="search"
      aria-label={label}
      className="mb-4 flex flex-wrap items-end gap-3 rounded-2xl bg-white px-3 py-3 ring-1 ring-slate-200/80"
    >
      {children}
    </div>
  )
}
