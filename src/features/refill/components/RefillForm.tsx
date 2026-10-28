import { useState } from "react"
import { ProductSearchField } from "@/components/forms/ProductSearchField"
import { Button } from "@/components/ui/button"
import { activeOperationalBranches } from "@/lib/branches/operational"
import type { RefillLineInput, RefillOptions } from "@/lib/refill/api"
import { parseRequestedCases, validateRefillLines } from "@/lib/refill/rules"

export type RefillFormValues = {
  supplierId: string
  godownId: string
  notes: string
  lines: RefillLineInput[]
}

export function RefillForm({
  options,
  initial,
  submitLabel,
  pending,
  error,
  onSubmit,
}: {
  options: RefillOptions
  initial: RefillFormValues
  submitLabel: string
  pending: boolean
  error: string | null
  onSubmit: (values: RefillFormValues) => void
}) {
  const [supplierId, setSupplierId] = useState(initial.supplierId)
  const [godownId, setGodownId] = useState(initial.godownId)
  const [notes, setNotes] = useState(initial.notes)
  const [lines, setLines] = useState<RefillLineInput[]>(
    initial.lines.length > 0 ? initial.lines : [{ product_id: "", requested_cases: 1 }],
  )

  const godowns = activeOperationalBranches(options.godowns)
  const suppliers = options.suppliers.filter((row) => row.is_active)
  // Product rows come from search_products filtered by the selected supplier,
  // not the truncated options.products dump.
  void options.products
  const lineErrors = validateRefillLines(lines)
  const valid =
    supplierId !== "" &&
    godownId !== "" &&
    lineErrors.length === 0 &&
    lines.every((line) => line.product_id !== "")

  return (
    <form
      className="grid max-w-3xl gap-4"
      onSubmit={(event) => {
        event.preventDefault()
        if (!valid) return
        onSubmit({
          supplierId,
          godownId,
          notes: notes.trim(),
          lines: lines.map((line) => ({
            product_id: line.product_id,
            requested_cases: parseRequestedCases(line.requested_cases) ?? 0,
          })),
        })
      }}
    >
      <label className="grid gap-1 text-sm font-medium">
        Supplier
        <select
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={supplierId}
          onChange={(event) => {
            const next = event.target.value
            setSupplierId(next)
            setLines([{ product_id: "", requested_cases: 1 }])
          }}
          required
          aria-label="Supplier"
        >
          <option value="">Select a supplier</option>
          {suppliers.map((supplier) => (
            <option key={supplier.id} value={supplier.id}>
              {supplier.name}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-1 text-sm font-medium">
        Destination godown
        <select
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={godownId}
          onChange={(event) => setGodownId(event.target.value)}
          required
          aria-label="Destination godown"
        >
          <option value="">Select a godown</option>
          {godowns.map((godown) => (
            <option key={godown.id} value={godown.id}>
              {godown.code} · {godown.name}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-1 text-sm font-medium">
        Notes
        <textarea
          className="min-h-24 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
          value={notes}
          onChange={(event) => setNotes(event.target.value)}
          maxLength={500}
          aria-label="Request notes"
        />
      </label>
      <fieldset className="grid gap-3">
        <legend className="text-sm font-medium">Requested SKUs</legend>
        {lines.map((line, index) => (
          <div key={index} className="grid gap-2 sm:grid-cols-[1fr_8rem_auto]">
            <ProductSearchField
              label={`Product line ${index + 1}`}
              value={line.product_id}
              required
              supplierId={supplierId || null}
              disabled={supplierId === ""}
              onChange={(productId) => {
                setLines((current) =>
                  current.map((item, itemIndex) =>
                    itemIndex === index ? { ...item, product_id: productId } : item,
                  ),
                )
              }}
            />
            <label className="grid gap-1 text-sm">
              Cases
              <input
                type="number"
                min={1}
                max={1000000}
                step={1}
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={line.requested_cases}
                onChange={(event) => {
                  const parsed = Number(event.target.value)
                  setLines((current) =>
                    current.map((item, itemIndex) =>
                      itemIndex === index
                        ? {
                            ...item,
                            requested_cases: Number.isFinite(parsed) ? parsed : 0,
                          }
                        : item,
                    ),
                  )
                }}
                required
                aria-label={`Requested cases line ${index + 1}`}
              />
            </label>
            <div className="flex items-end">
              <Button
                type="button"
                variant="outline"
                disabled={lines.length === 1}
                onClick={() =>
                  setLines((current) =>
                    current.filter((_, itemIndex) => itemIndex !== index),
                  )
                }
              >
                Remove
              </Button>
            </div>
          </div>
        ))}
        <Button
          type="button"
          variant="outline"
          onClick={() =>
            setLines((current) => [...current, { product_id: "", requested_cases: 1 }])
          }
        >
          Add SKU
        </Button>
      </fieldset>
      {lineErrors.length > 0 ? (
        <ul className="list-disc pl-5 text-sm text-destructive">
          {lineErrors.map((message) => (
            <li key={message}>{message}</li>
          ))}
        </ul>
      ) : null}
      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
      <Button type="submit" disabled={pending || !valid}>
        {pending ? "Saving…" : submitLabel}
      </Button>
    </form>
  )
}
