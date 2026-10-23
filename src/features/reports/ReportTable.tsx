import type { ReactNode } from "react"
import { EmptyState } from "@/components/shared/EmptyState"
import { ReportPager } from "@/features/reports/ReportControls"

export function ReportTable({
  columns,
  emptyTitle,
  emptyDescription,
  page,
  pageSize,
  total,
  onPage,
  children,
}: {
  columns: string[]
  emptyTitle: string
  emptyDescription: string
  page: number
  pageSize: number
  total: number
  onPage: (page: number) => void
  children: ReactNode
}) {
  const empty = total === 0

  return (
    <>
      {empty ? (
        <div className="overflow-hidden rounded-2xl bg-white ring-1 ring-slate-200">
          <EmptyState title={emptyTitle} description={emptyDescription} />
        </div>
      ) : (
        <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200">
          <table className="w-full min-w-[48rem] text-left text-sm">
            <thead className="text-xs tracking-wide text-muted-foreground uppercase">
              <tr>
                {columns.map((column) => (
                  <th key={column} className="px-4 py-3 font-medium">
                    {column}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>{children}</tbody>
          </table>
        </div>
      )}
      <ReportPager page={page} pageSize={pageSize} total={total} onPage={onPage} />
    </>
  )
}
