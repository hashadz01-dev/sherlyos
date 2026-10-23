import { Link, useNavigate, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  pickingKeys,
  previewOrderAllocation,
  reserveOrderAllocation,
} from "@/lib/picking/api"
import { cutoverBlocksPicking, isStalePickingVersion } from "@/lib/picking/rules"

export function PickingAllocatePage() {
  const { orderId = "" } = useParams()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { can } = useAccess()
  const preview = useQuery({
    queryKey: pickingKeys.preview(orderId),
    queryFn: () => previewOrderAllocation(orderId),
    enabled: orderId !== "",
  })
  useDocumentTitle(preview.data ? `Allocate ${preview.data.order_number}` : "Allocate order")

  const reserve = useMutation({
    mutationFn: () => {
      if (!preview.data) throw new Error("Preview is not loaded.")
      return reserveOrderAllocation({
        target_order: preview.data.order_id,
        expected_order_version: preview.data.order_version,
        idempotency_key: `pk-reserve-${crypto.randomUUID()}`,
      })
    },
    onSuccess: async (detail) => {
      await queryClient.invalidateQueries({ queryKey: pickingKeys.queue("pending_allocation") })
      navigate(`/picking/${detail.id}`)
    },
  })

  const cutoverMessage = preview.data
    ? cutoverBlocksPicking(preview.data.cutover)
    : null
  const errorMessage =
    reserve.error && isStalePickingVersion(reserve.error)
      ? "This order changed. Reload the preview before reserving."
      : reserve.error?.message

  return (
    <section className="min-w-0">
      <PageHeader
        title={preview.data ? `Allocate ${preview.data.order_number}` : "Allocate order"}
        description="FEFO for expiry-controlled products, FIFO for non-expiring products. Confirming creates crate and lot reservations without changing the ledger."
        action={
          <Button asChild variant="outline">
            <Link to="/picking">Back to queue</Link>
          </Button>
        }
      />
      {preview.isLoading ? <LoadingBlock label="Loading allocation preview" /> : null}
      {preview.error ? (
        <p role="alert" className="text-sm text-destructive">
          {preview.error.message}
        </p>
      ) : null}
      {preview.data ? (
        <div className="space-y-4">
          {cutoverMessage ? (
            <p role="alert" className="rounded-xl bg-amber-50 px-4 py-3 text-sm text-amber-900">
              {cutoverMessage}
            </p>
          ) : null}
          {preview.data.blockers.length > 0 ? (
            <ul className="list-disc space-y-1 rounded-xl bg-slate-50 px-6 py-3 text-sm">
              {preview.data.blockers.map((blocker) => (
                <li key={blocker}>{blocker}</li>
              ))}
            </ul>
          ) : null}
          {preview.data.lines.map((line) => (
            <article key={line.order_line_id} className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
              <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                <h2 className="text-base font-semibold">
                  {line.sku} · {line.product_name}
                </h2>
                <StatusBadge tone={line.eligible ? "success" : "danger"}>
                  {line.allocated_cases}/{line.requested_cases} cases
                </StatusBadge>
              </div>
              {line.blockers.length > 0 ? (
                <p className="mb-2 text-sm text-destructive">{line.blockers.join(" ")}</p>
              ) : null}
              {line.slices.length === 0 ? (
                <p className="text-sm text-slate-600">No eligible crate or lot stock.</p>
              ) : (
                <table className="w-full text-left text-sm">
                  <thead className="text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="py-2 font-medium">Zone / crate</th>
                      <th className="py-2 font-medium">Lot</th>
                      <th className="py-2 font-medium">Expiry</th>
                      <th className="py-2 font-medium">Available</th>
                      <th className="py-2 font-medium">Reserve</th>
                    </tr>
                  </thead>
                  <tbody>
                    {line.slices.map((slice) => (
                      <tr key={`${slice.lot_id}-${slice.crate_id}`} className="border-t border-slate-100">
                        <td className="py-2">
                          {slice.zone_code} / {slice.crate_code}
                        </td>
                        <td className="py-2">{slice.manufacturer_lot_code ?? slice.lot_id.slice(0, 8)}</td>
                        <td className="py-2">{slice.expiry_date ?? "—"}</td>
                        <td className="py-2">{slice.available_cases}</td>
                        <td className="py-2">{slice.reserved_cases}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </article>
          ))}
          {errorMessage ? (
            <p role="alert" className="text-sm text-destructive">
              {errorMessage}
            </p>
          ) : null}
          {can("picking.allocate") ? (
            <Button
              type="button"
              disabled={!preview.data.eligible || reserve.isPending}
              onClick={() => reserve.mutate()}
            >
              {reserve.isPending ? "Reserving" : "Confirm reservation"}
            </Button>
          ) : null}
        </div>
      ) : null}
    </section>
  )
}
