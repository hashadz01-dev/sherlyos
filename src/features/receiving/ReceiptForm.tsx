import { useState, type FormEvent, type SelectHTMLAttributes } from "react"
import { useQuery } from "@tanstack/react-query"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { formatCases, formatRefillReceivingLabel } from "@/features/refill/utils/labels"
import { getStockRefillReceivingReconciliation } from "@/lib/refill/api"
import type { ReceivingOptions } from "@/lib/receiving/api"
import { acceptedCases } from "@/lib/receiving/rules"
import { receiptFormSchema, type ReceiptFormValues } from "@/lib/validations/receiving"
import {
  emptyReceiptLine,
  type ReceiptDraft,
  type ReceiptLineDraft,
} from "@/features/receiving/receipt-draft"

export type { ReceiptDraft, ReceiptLineDraft }

export function ReceiptForm({
  initial,
  options,
  pending,
  submitLabel,
  onSubmit,
}: {
  initial: ReceiptDraft
  options: ReceivingOptions
  pending: boolean
  submitLabel: string
  onSubmit: (values: ReceiptFormValues) => void
}) {
  const [draft, setDraft] = useState(initial)
  const [errors, setErrors] = useState<string[]>([])
  const refillRequests = options.refill_requests ?? []
  const linked = Boolean(draft.refillRequestId)
  const reconciliation = useQuery({
    queryKey: ["refill-receiving", draft.refillRequestId],
    queryFn: () => getStockRefillReceivingReconciliation(draft.refillRequestId),
    enabled: draft.refillRequestId.length > 0,
  })
  const allowedProductIds = new Set(
    (reconciliation.data?.receiving.lines ?? []).map((line) => line.product_id),
  )
  // Keepers have stock.receive, not products.read, so this picker uses the
  // receiving-options RPC catalog rather than search_products.
  const products = linked
    ? options.products.filter((product) => allowedProductIds.has(product.id))
    : options.products
  const zones = options.zones.filter((zone) => zone.branch_id === draft.godownId)
  const zoneIds = new Set(zones.map((zone) => zone.id))
  const crates = options.crates.filter((crate) => zoneIds.has(crate.zone_id))

  function updateLine(key: string, patch: Partial<ReceiptLineDraft>) {
    setDraft((current) => ({
      ...current,
      lines: current.lines.map((line) => (line.key === key ? { ...line, ...patch } : line)),
    }))
  }

  function submit(event: FormEvent) {
    event.preventDefault()
    const parsed = receiptFormSchema.safeParse(draft)
    if (!parsed.success) {
      setErrors(parsed.error.issues.map((issue) => issue.message))
      return
    }
    // Linked receipts may only credit SKUs that remain on the refill request.
    if (linked && allowedProductIds.size > 0) {
      const extra = parsed.data.lines.filter((line) => !allowedProductIds.has(line.productId))
      if (extra.length > 0) {
        setErrors(["Linked receiving can only use products from the approved refill request."])
        return
      }
    }
    setErrors([])
    onSubmit(parsed.data)
  }

  return (
    <form className="grid gap-4" onSubmit={submit}>
      {refillRequests.length > 0 ? (
        <SelectField
          label="Approved refill request (optional)"
          value={draft.refillRequestId}
          aria-label="Approved refill request"
          onChange={(event) => {
            const nextId = event.target.value
            const next = refillRequests.find((row) => row.id === nextId)
            setDraft((current) => ({
              ...current,
              refillRequestId: nextId,
              godownId: next?.destination_godown_id ?? current.godownId,
              supplierId: next?.supplier_id ?? current.supplierId,
              lines: nextId ? [emptyReceiptLine()] : current.lines,
            }))
            if (!nextId) return
            void getStockRefillReceivingReconciliation(nextId).then((recon) => {
              setDraft((current) => {
                if (current.refillRequestId !== nextId) return current
                const snapshot = recon.receiving
                return {
                  ...current,
                  godownId: recon.destination_godown_id,
                  supplierId: recon.supplier_id,
                  lines:
                    snapshot.lines.length > 0
                      ? snapshot.lines.map((line) => ({
                          ...emptyReceiptLine(),
                          productId: line.product_id,
                          documentCases: String(line.outstanding_cases),
                        }))
                      : [emptyReceiptLine()],
                }
              })
            })
          }}
        >
          <option value="">Unlinked receiving</option>
          {refillRequests.map((request) => (
            <option key={request.id} value={request.id}>
              {request.request_number} · {request.supplier_name} · {request.godown_name}
            </option>
          ))}
        </SelectField>
      ) : null}
      {linked && reconciliation.data ? (
        <aside className="grid gap-2 rounded-2xl bg-slate-50 p-4 text-sm ring-1 ring-slate-200">
          <p className="font-medium">
            Remaining against {reconciliation.data.request_number}:{" "}
            {formatRefillReceivingLabel(reconciliation.data.receiving.summary.completion_label)}
          </p>
          <p className="text-muted-foreground">
            Outstanding is verified accepted against the request. Reserved includes
            drafts and unverified linked receipts. Damaged cases do not become accepted
            stock.
          </p>
          <ul className="grid gap-1">
            {reconciliation.data.receiving.lines.map((line) => (
              <li key={line.product_id}>
                {line.product_sku}: requested {formatCases(line.requested_cases)}, reserved{" "}
                {formatCases(line.reserved_cases ?? 0)}, verified{" "}
                {formatCases(line.accepted_cases)}, outstanding {formatCases(line.outstanding_cases)}
                {(line.draft_reserved_cases ?? 0) > 0
                  ? `, draft reserved ${formatCases(line.draft_reserved_cases)}`
                  : ""}
                {line.excess_cases > 0 ? `, excess ${formatCases(line.excess_cases)}` : ""}
              </li>
            ))}
          </ul>
        </aside>
      ) : null}
      <div className="grid gap-4 md:grid-cols-2">
        <SelectField
          label="Godown"
          value={draft.godownId}
          disabled={linked}
          onChange={(event) =>
            setDraft((current) => ({
              ...current,
              godownId: event.target.value,
              lines: current.lines.map((line) => ({ ...line, zoneId: "", crateId: "" })),
            }))
          }
        >
          <option value="">Choose a godown</option>
          {options.godowns.map((godown) => (
            <option key={godown.id} value={godown.id}>
              {godown.name}
            </option>
          ))}
        </SelectField>
        <SelectField
          label="Supplier"
          aria-label="Supplier"
          value={draft.supplierId}
          disabled={linked}
          onChange={(event) =>
            setDraft((current) => ({ ...current, supplierId: event.target.value }))
          }
        >
          <option value="">Choose a supplier</option>
          {options.suppliers.map((supplier) => (
            <option key={supplier.id} value={supplier.id}>
              {supplier.name}
            </option>
          ))}
        </SelectField>
        <TextField
          label="Supplier document reference"
          value={draft.documentReference}
          onChange={(event) =>
            setDraft((current) => ({ ...current, documentReference: event.target.value }))
          }
        />
        <TextField
          label="Received date"
          type="date"
          value={draft.receivedDate}
          onChange={(event) =>
            setDraft((current) => ({ ...current, receivedDate: event.target.value }))
          }
        />
      </div>
      <TextField
        label="Notes"
        value={draft.notes}
        onChange={(event) => setDraft((current) => ({ ...current, notes: event.target.value }))}
      />
      <div className="grid gap-3">
        {draft.lines.map((line, index) => {
          const lineCrates = crates.filter((crate) => crate.zone_id === line.zoneId)
          const counted = Number(line.countedCases)
          const damaged = Number(line.damagedCases)
          const accepted =
            Number.isInteger(counted) && Number.isInteger(damaged) && damaged <= counted
              ? String(acceptedCases(counted, damaged))
              : "—"
          return (
            <fieldset key={line.key} className="grid gap-3 rounded-2xl bg-white p-4 ring-1 ring-slate-200">
              <legend className="px-1 text-sm font-medium">Line {index + 1}</legend>
              <div className="grid gap-3 md:grid-cols-2">
                <SelectField
                  label="Product"
                  value={line.productId}
                  onChange={(event) => updateLine(line.key, { productId: event.target.value })}
                >
                  <option value="">Choose a product</option>
                  {products.map((product) => (
                    <option key={product.id} value={product.id}>
                      {product.name} ({product.sku})
                    </option>
                  ))}
                </SelectField>
                <SelectField
                  label="Zone"
                  value={line.zoneId}
                  onChange={(event) =>
                    updateLine(line.key, { zoneId: event.target.value, crateId: "" })
                  }
                >
                  <option value="">Choose a zone</option>
                  {zones.map((zone) => (
                    <option key={zone.id} value={zone.id}>
                      {zone.name}
                    </option>
                  ))}
                </SelectField>
                <SelectField
                  label="Destination crate"
                  value={line.crateId}
                  onChange={(event) => updateLine(line.key, { crateId: event.target.value })}
                >
                  <option value="">Choose a crate</option>
                  {lineCrates.map((crate) => (
                    <option key={crate.id} value={crate.id}>
                      {crate.code}
                    </option>
                  ))}
                </SelectField>
                <TextField
                  label="Document cases"
                  inputMode="numeric"
                  value={line.documentCases}
                  onChange={(event) => updateLine(line.key, { documentCases: event.target.value })}
                />
                <TextField
                  label="Counted cases"
                  inputMode="numeric"
                  value={line.countedCases}
                  onChange={(event) => updateLine(line.key, { countedCases: event.target.value })}
                />
                <TextField
                  label="Damaged cases"
                  inputMode="numeric"
                  value={line.damagedCases}
                  onChange={(event) => updateLine(line.key, { damagedCases: event.target.value })}
                />
                <p className="text-sm">
                  Accepted cases
                  <span className="mt-2 block h-10 rounded-lg bg-slate-50 px-2.5 py-2 font-medium">
                    {accepted}
                  </span>
                </p>
              </div>
              <Button
                type="button"
                variant="outline"
                onClick={() =>
                  setDraft((current) => ({
                    ...current,
                    lines: current.lines.filter((entry) => entry.key !== line.key),
                  }))
                }
              >
                Remove line
              </Button>
            </fieldset>
          )
        })}
      </div>
      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          variant="outline"
          onClick={() =>
            setDraft((current) => ({ ...current, lines: [...current.lines, emptyReceiptLine()] }))
          }
        >
          Add line
        </Button>
        <Button type="submit" disabled={pending}>
          {submitLabel}
        </Button>
      </div>
      {errors.length > 0 ? (
        <ul role="alert" className="grid gap-1 text-sm text-destructive">
          {errors.map((error) => (
            <li key={error}>{error}</li>
          ))}
        </ul>
      ) : null}
    </form>
  )
}

function SelectField({
  label,
  children,
  ...props
}: SelectHTMLAttributes<HTMLSelectElement> & { label: string }) {
  return (
    <label className="grid gap-2 text-sm font-medium">
      {label}
      <select
        className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
        {...props}
      >
        {children}
      </select>
    </label>
  )
}
