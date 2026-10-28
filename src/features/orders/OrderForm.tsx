import { useState } from "react"
import { ProductSearchField } from "@/components/forms/ProductSearchField"
import { Button } from "@/components/ui/button"
import { activeOperationalBranches } from "@/lib/branches/operational"
import type { OrderCatalogBranch, OrderCatalogProduct, OrderCatalogShop, OrderLineInput, OrderSource } from "@/lib/orders/api"

export type OrderFormValues = {
  shopId: string
  branchId: string
  source: OrderSource
  sourceReference: string
  notes: string
  lines: OrderLineInput[]
}

const sources: { value: OrderSource; label: string }[] = [
  { value: "salesperson", label: "Salesperson" },
  { value: "accounts", label: "Accounts" },
  { value: "telecalling", label: "Telecalling" },
  { value: "enquiry", label: "Enquiry" },
]

export function OrderForm({
  shops,
  branches,
  products,
  initial,
  submitLabel,
  pending,
  error,
  onSubmit,
}: {
  shops: OrderCatalogShop[]
  branches: OrderCatalogBranch[]
  products: OrderCatalogProduct[]
  initial: OrderFormValues
  submitLabel: string
  pending: boolean
  error: string | null
  onSubmit: (values: OrderFormValues) => void
}) {
  const [shopId, setShopId] = useState(initial.shopId)
  const [branchId, setBranchId] = useState(initial.branchId)
  const [source, setSource] = useState<OrderSource>(initial.source)
  const [sourceReference, setSourceReference] = useState(initial.sourceReference)
  const [notes, setNotes] = useState(initial.notes)
  const [lines, setLines] = useState<OrderLineInput[]>(
    initial.lines.length > 0 ? initial.lines : [{ product_id: "", requested_cases: 1 }],
  )
  const activeShops = shops.filter((shop) => shop.is_active)
  const activeBranches = activeOperationalBranches(branches)
  // Catalog prop is retained so existing loaders keep compiling; the picker
  // searches server-side and no longer maps this array.
  void products
  const valid =
    shopId !== "" &&
    branchId !== "" &&
    lines.length > 0 &&
    lines.every((line) => line.product_id !== "" && line.requested_cases >= 1)

  return (
    <form
      className="grid max-w-3xl gap-4"
      onSubmit={(event) => {
        event.preventDefault()
        if (!valid) return
        onSubmit({ shopId, branchId, source, sourceReference, notes, lines })
      }}
    >
      <label className="grid gap-1 text-sm">
        Shop
        <select
          className="rounded-xl border bg-card px-3 py-2"
          value={shopId}
          onChange={(event) => setShopId(event.target.value)}
          required
        >
          <option value="">Select a shop</option>
          {activeShops.map((shop) => (
            <option key={shop.id} value={shop.id}>
              {shop.name}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-1 text-sm">
        Fulfilling godown
        <select
          className="rounded-xl border bg-card px-3 py-2"
          value={branchId}
          onChange={(event) => setBranchId(event.target.value)}
          required
        >
          <option value="">Select a godown</option>
          {activeBranches.map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.name}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-1 text-sm">
        Source
        <select
          className="rounded-xl border bg-card px-3 py-2"
          value={source}
          onChange={(event) => setSource(event.target.value as OrderSource)}
        >
          {sources.map((item) => (
            <option key={item.value} value={item.value}>
              {item.label}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-1 text-sm">
        Source reference
        <input
          className="rounded-xl border bg-card px-3 py-2"
          value={sourceReference}
          onChange={(event) => setSourceReference(event.target.value)}
          maxLength={80}
        />
      </label>
      <label className="grid gap-1 text-sm">
        Notes
        <textarea
          className="min-h-24 rounded-xl border bg-card px-3 py-2"
          value={notes}
          onChange={(event) => setNotes(event.target.value)}
          maxLength={500}
        />
      </label>
      <fieldset className="grid gap-3">
        <legend className="text-sm font-medium">Lines</legend>
        {lines.map((line, index) => (
          <div key={index} className="grid gap-2 sm:grid-cols-[1fr_8rem_auto]">
            <ProductSearchField
              label="Product"
              value={line.product_id}
              required
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
                className="rounded-xl border bg-card px-3 py-2"
                value={line.requested_cases}
                onChange={(event) => {
                  const requested = Number(event.target.value)
                  setLines((current) =>
                    current.map((item, itemIndex) =>
                      itemIndex === index
                        ? { ...item, requested_cases: Number.isFinite(requested) ? requested : 1 }
                        : item,
                    ),
                  )
                }}
                required
              />
            </label>
            <div className="flex items-end">
              <Button
                type="button"
                variant="outline"
                disabled={lines.length === 1}
                onClick={() => setLines((current) => current.filter((_, itemIndex) => itemIndex !== index))}
              >
                Remove
              </Button>
            </div>
          </div>
        ))}
        <Button
          type="button"
          variant="outline"
          onClick={() => setLines((current) => [...current, { product_id: "", requested_cases: 1 }])}
        >
          Add line
        </Button>
      </fieldset>
      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
      <Button type="submit" disabled={pending || !valid}>
        {submitLabel}
      </Button>
    </form>
  )
}
