import type { ReactNode } from "react"
import { cn } from "cn"

/** Shared chrome for hand-built operational lists. Column content stays with the caller. */
export function RecordTable({
  children,
  className,
  caption,
}: {
  children: ReactNode
  className?: string
  caption?: string
}) {
  return (
    <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
      <table className={cn("w-full text-left text-sm", className)}>
        {caption ? <caption className="sr-only">{caption}</caption> : null}
        {children}
      </table>
    </div>
  )
}

export function RecordHeader({ children }: { children: ReactNode }) {
  return (
    <thead className="border-b border-slate-200 text-xs tracking-wide text-slate-500 uppercase">
      {children}
    </thead>
  )
}

export function RecordRow({ children }: { children: ReactNode }) {
  return <tr className="border-b border-slate-100 last:border-0 hover:bg-slate-50/80">{children}</tr>
}

export function RecordHeadCell({
  children,
  className,
}: {
  children: ReactNode
  className?: string
}) {
  return <th className={cn("px-4 py-3 font-medium", className)}>{children}</th>
}

export function RecordCell({
  children,
  className,
}: {
  children: ReactNode
  className?: string
}) {
  return <td className={cn("px-4 py-3 align-middle", className)}>{children}</td>
}
