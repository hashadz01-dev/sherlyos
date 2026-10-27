import { useState } from "react"
import { Link, useNavigate, useParams } from "react-router"
import { useMutation, useQuery } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  confirmDispatch,
  dispatchKeys,
  prepareDispatch,
  previewDispatch,
} from "@/lib/dispatch/api"
import { cutoverBlocksDispatch, isStaleDispatchVersion } from "@/lib/dispatch/rules"

function nextKey(prefix: string) {
  return `${prefix}-${crypto.randomUUID()}`
}

export function DispatchPreparePage() {
  const { orderId = "" } = useParams()
  const navigate = useNavigate()
  const { can } = useAccess()
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const preview = useQuery({
    queryKey: dispatchKeys.preview(orderId),
    queryFn: () => previewDispatch(orderId),
    enabled: orderId !== "",
  })
  const data = preview.data
  useDocumentTitle(data ? `Dispatch ${data.order_number}` : "Dispatch")

  const cutoverMessage = data
    ? cutoverBlocksDispatch(data.cutover)
    : null
  const canConfirm = can("dispatch.confirm") && data?.eligible === true

  const [prepareKey] = useState(() => nextKey("ds-prep"))
  const [confirmKey] = useState(() => nextKey("ds-cfm"))

  const confirm = useMutation({
    mutationFn: async () => {
      if (!data?.picking_request_id || data.picking_version == null) {
        throw new Error("Picking handoff is missing.")
      }
      const prepared = data.dispatch_id
        ? await confirmDispatch({
            target_dispatch: data.dispatch_id,
            expected_version: data.dispatch_version ?? 1,
            idempotency_key: confirmKey,
          })
        : await prepareDispatch({
            target_order: orderId,
            expected_picking_version: data.picking_version,
            idempotency_key: prepareKey,
          }).then((document) =>
            confirmDispatch({
              target_dispatch: document.id,
              expected_version: document.version,
              idempotency_key: confirmKey,
            }),
          )
      return prepared
    },
    onSuccess: (document) => {
      navigate(`/dispatch/${document.id}`, { replace: true })
    },
    onError: (error: Error) => {
      setActionError(
        isStaleDispatchVersion(error)
          ? "This dispatch changed. Refresh and try again."
          : error.message,
      )
      setConfirmOpen(false)
    },
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title={data ? `Dispatch ${data.order_number}` : "Dispatch"}
        description="Confirm the reserved carton cases. Inventory is deducted only after this step succeeds."
      />
      {preview.isLoading ? <LoadingBlock label="Loading dispatch preview" /> : null}
      {preview.error ? (
        <p role="alert" className="text-sm text-destructive">
          {preview.error.message}
        </p>
      ) : null}
      {data ? (
        <div className="grid gap-4">
          {cutoverMessage ? (
            <p role="alert" className="text-sm text-destructive">
              {cutoverMessage}
            </p>
          ) : null}
          {data.blockers.filter((blocker) => blocker !== cutoverMessage).length > 0 ? (
            <ul className="list-disc space-y-1 pl-5 text-sm text-destructive">
              {data.blockers
                .filter((blocker) => blocker !== cutoverMessage)
                .map((blocker, index) => (
                  <li key={`${index}-${blocker}`}>{blocker}</li>
                ))}
            </ul>
          ) : null}
          <dl className="grid gap-2 text-sm sm:grid-cols-2">
            <div>
              <dt className="text-slate-500">Picking</dt>
              <dd>{data.picking_request_number ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-slate-500">Delivery note</dt>
              <dd>{data.delivery_note_number ?? "None (paperwork is optional)"}</dd>
            </div>
            <div>
              <dt className="text-slate-500">Shipment document</dt>
              <dd>
                {data.shipment_number
                  ? `${data.shipment_number} · ${data.shipment_status ?? "draft"} · rev ${data.shipment_revision ?? 1}`
                  : "Full shipment (no short-shipment document)"}
              </dd>
            </div>
            <div>
              <dt className="text-slate-500">Carton cases to dispatch</dt>
              <dd>{data.total_cases}</dd>
            </div>
            <div>
              <dt className="text-slate-500">Stock consumed</dt>
              <dd>{data.stock_consumed ? "Yes" : "No"}</dd>
            </div>
          </dl>
          <ReservationTable rows={data.reservations} />
          {actionError ? (
            <p role="alert" className="text-sm text-destructive">
              {actionError}
            </p>
          ) : null}
          <div className="flex flex-wrap gap-2">
            {canConfirm ? (
              <Button type="button" onClick={() => setConfirmOpen(true)}>
                Confirm dispatch
              </Button>
            ) : null}
            {data.picking_request_id ? (
              <Button asChild variant="outline">
                <Link to={`/picking/${data.picking_request_id}`}>Open picking</Link>
              </Button>
            ) : null}
          </div>
        </div>
      ) : null}

      <AppModal
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        title="Confirm dispatch"
        description="This deducts the approved shipped carton cases from inventory exactly once. Retrying a timeout is safe."
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setConfirmOpen(false)}>
              Cancel
            </Button>
            <Button
              type="button"
              onClick={() => confirm.mutate()}
              disabled={confirm.isPending}
            >
              {confirm.isPending ? "Confirming" : `Dispatch ${data?.total_cases ?? 0} cases`}
            </Button>
          </>
        }
      />
    </section>
  )
}

function ReservationTable({
  rows,
}: {
  rows: {
    id: string
    sku: string
    product_name: string
    zone_code: string
    crate_code: string
    manufacturer_lot_code: string | null
    expiry_date: string | null
    reserved_cases: number
    picked_cases: number
  }[]
}) {
  if (rows.length === 0) {
    return <p className="text-sm text-slate-600">No reserved carton cases.</p>
  }
  return (
    <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
      <table className="w-min min-w-full text-left text-sm">
        <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th className="px-4 py-3 font-medium">Product</th>
            <th className="px-4 py-3 font-medium">Location</th>
            <th className="px-4 py-3 font-medium">Lot</th>
            <th className="px-4 py-3 font-medium">Reserved</th>
            <th className="px-4 py-3 font-medium">Picked</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.id} className="border-b border-slate-100 last:border-0">
              <td className="px-4 py-3">
                {row.sku} · {row.product_name}
              </td>
              <td className="px-4 py-3">
                {row.zone_code} / {row.crate_code}
              </td>
              <td className="px-4 py-3">
                {row.manufacturer_lot_code ?? "—"}
                {row.expiry_date ? ` · ${row.expiry_date}` : ""}
              </td>
              <td className="px-4 py-3">{row.reserved_cases}</td>
              <td className="px-4 py-3">{row.picked_cases}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
