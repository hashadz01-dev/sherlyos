import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { TriangleAlert } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listPickingExceptions, pickingKeys } from "@/lib/picking/api"

export function PickingExceptionsPage() {
  useDocumentTitle("Picking exceptions")
  const exceptions = useQuery({
    queryKey: pickingKeys.exceptions,
    queryFn: listPickingExceptions,
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title="Picking exceptions"
        description="Shortages, expired stock, unknown legacy lots, missing receipt chronology, and reservation conflicts."
        action={
          <Button asChild variant="outline">
            <Link to="/picking">Back to queue</Link>
          </Button>
        }
      />
      {exceptions.isLoading ? <LoadingBlock label="Loading exceptions" /> : null}
      {exceptions.error ? (
        <p role="alert" className="text-sm text-destructive">
          {exceptions.error.message}
        </p>
      ) : null}
      {exceptions.data && exceptions.data.length === 0 ? (
        <EmptyState
          icon={TriangleAlert}
          title="No picking exceptions"
          description="Shortage reports and allocation blockers appear here after warehouse work starts."
        />
      ) : null}
      {exceptions.data && exceptions.data.length > 0 ? (
        <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
          <table className="w-min min-w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-4 py-3 font-medium">When</th>
                <th className="px-4 py-3 font-medium">Order</th>
                <th className="px-4 py-3 font-medium">Type</th>
                <th className="px-4 py-3 font-medium">Message</th>
                <th className="px-4 py-3 font-medium">Qty</th>
              </tr>
            </thead>
            <tbody>
              {exceptions.data.map((row) => (
                <tr key={row.id} className="border-b border-slate-100 last:border-0">
                  <td className="px-4 py-3">{new Date(row.created_at).toLocaleString()}</td>
                  <td className="px-4 py-3">
                    {row.picking_request_id ? (
                      <Link className="underline" to={`/picking/${row.picking_request_id}`}>
                        {row.order_number ?? row.request_number}
                      </Link>
                    ) : (
                      (row.order_number ?? "—")
                    )}
                  </td>
                  <td className="px-4 py-3">{row.exception_type}</td>
                  <td className="px-4 py-3">{row.message}</td>
                  <td className="px-4 py-3">{row.quantity ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </section>
  )
}
