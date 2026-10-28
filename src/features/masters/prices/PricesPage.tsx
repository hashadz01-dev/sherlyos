import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { ProductSearchField } from "@/components/forms/ProductSearchField"
import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { FilterSelect } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { formatInr } from "@/lib/invoices/rules"
import { loadRows } from "@/lib/masters/api"
import {
  deactivateProductSellingPrice,
  listProductSellingPrices,
  pricingKeys,
  upsertProductSellingPrice,
} from "@/lib/pricing/api"
import { notify } from "@/lib/utilities/notify"

type Shop = { id: string; name: string; is_active: boolean }

export function PricesPage() {
  useDocumentTitle("Selling prices")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const canManage = can("products.price.manage")
  const [productId, setProductId] = useState("")
  const [shopFilter, setShopFilter] = useState("all")
  const [includeInactive, setIncludeInactive] = useState(false)
  const [editorOpen, setEditorOpen] = useState(false)
  const [unitAmount, setUnitAmount] = useState("")
  const [shopId, setShopId] = useState("")
  const [effectiveFrom, setEffectiveFrom] = useState("")
  const [effectiveTo, setEffectiveTo] = useState("")

  const shops = useQuery({
    queryKey: ["shops"],
    queryFn: () => loadRows<Shop>("shops", "id, name, is_active", "name"),
  })
  const prices = useQuery({
    queryKey: pricingKeys.list(productId, shopFilter, includeInactive),
    queryFn: () =>
      listProductSellingPrices({
        productId: productId || null,
        shopId: shopFilter === "all" ? null : shopFilter,
        includeInactive,
      }),
  })

  const save = useMutation({
    mutationFn: () => {
      const amount = Number(unitAmount)
      if (!productId) throw new Error("Choose a product.")
      if (!Number.isFinite(amount) || amount <= 0) {
        throw new Error("Enter a positive INR unit amount.")
      }
      if (!effectiveFrom) throw new Error("Enter an effective from date.")
      return upsertProductSellingPrice({
        productId,
        shopId: shopId || null,
        unitAmount: amount,
        effectiveFrom,
        effectiveTo: effectiveTo || null,
      })
    },
    onSuccess: async () => {
      notify.success("Selling price saved")
      setEditorOpen(false)
      setUnitAmount("")
      await queryClient.invalidateQueries({ queryKey: ["product-selling-prices"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const deactivate = useMutation({
    mutationFn: (priceId: string) => deactivateProductSellingPrice(priceId),
    onSuccess: async () => {
      notify.success("Selling price deactivated")
      await queryClient.invalidateQueries({ queryKey: ["product-selling-prices"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const rows = prices.data ?? []

  return (
    <section className="min-w-0">
      <PageHeader
        title="Selling prices"
        description="INR selling prices. Shop-specific rows override the default. Overlapping active windows are rejected. GST is not stored here."
        action={
          canManage ? (
            <Button type="button" onClick={() => setEditorOpen(true)} disabled={!productId}>
              Add price
            </Button>
          ) : null
        }
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <ProductSearchField
          label="Product"
          value={productId}
          onChange={(nextId) => setProductId(nextId)}
          activeOnly={!can("products.manage")}
        />
        <FilterSelect label="Shop" value={shopFilter} onChange={setShopFilter}>
          <option value="all">All shops / default</option>
          {(shops.data ?? []).map((shop) => (
            <option key={shop.id} value={shop.id}>
              {shop.name}
            </option>
          ))}
        </FilterSelect>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={includeInactive}
            onChange={(event) => setIncludeInactive(event.target.checked)}
          />
          Include inactive
        </label>
      </div>

      {prices.isLoading ? <LoadingBlock label="Loading selling prices" /> : null}
      {prices.error ? (
        <p role="alert" className="text-sm text-destructive">
          {prices.error.message}
        </p>
      ) : null}
      {!prices.isLoading && rows.length === 0 ? (
        <EmptyState
          title="No selling prices"
          description="Choose a product, then add a default INR price. Shop-specific prices are optional overrides."
        />
      ) : (
        <ul className="divide-y divide-slate-200/80 rounded-2xl bg-white ring-1 ring-slate-200/80">
          {rows.map((row) => (
            <li
              key={row.id}
              className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <span>
                <span className="block text-sm font-medium">
                  {row.sku} · {row.product_name}
                </span>
                <span className="text-xs text-muted-foreground">
                  {row.shop_name ?? "Default"} · {formatInr(row.unit_amount)} · {row.effective_from}
                  {row.effective_to ? ` to ${row.effective_to}` : " onward"}
                </span>
              </span>
              <span className="flex items-center gap-2">
                <StatusBadge tone={row.is_active ? "success" : "neutral"}>
                  {row.is_active ? "Active" : "Inactive"}
                </StatusBadge>
                {canManage && row.is_active ? (
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => deactivate.mutate(row.id)}
                    disabled={deactivate.isPending}
                  >
                    Deactivate
                  </Button>
                ) : null}
              </span>
            </li>
          ))}
        </ul>
      )}

      <AppModal
        open={editorOpen}
        onOpenChange={setEditorOpen}
        title="Add selling price"
        description="Amount is INR per billed unit, not per case. Leave shop blank for the default price."
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setEditorOpen(false)}>
              Cancel
            </Button>
            <Button type="button" onClick={() => save.mutate()} disabled={save.isPending}>
              {save.isPending ? "Saving" : "Save price"}
            </Button>
          </>
        }
      >
        <div className="grid gap-3">
          <label className="grid gap-1 text-sm font-medium">
            Shop (optional default)
            <select
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={shopId}
              onChange={(event) => setShopId(event.target.value)}
            >
              <option value="">Default for all shops</option>
              {(shops.data ?? []).map((shop) => (
                <option key={shop.id} value={shop.id}>
                  {shop.name}
                </option>
              ))}
            </select>
          </label>
          <label className="grid gap-1 text-sm font-medium">
            Unit amount (INR)
            <input
              className="h-10 rounded-lg border border-input px-3 text-sm"
              inputMode="decimal"
              value={unitAmount}
              onChange={(event) => setUnitAmount(event.target.value)}
            />
          </label>
          <label className="grid gap-1 text-sm font-medium">
            Effective from
            <input
              type="date"
              className="h-10 rounded-lg border border-input px-3 text-sm"
              value={effectiveFrom}
              onChange={(event) => setEffectiveFrom(event.target.value)}
            />
          </label>
          <label className="grid gap-1 text-sm font-medium">
            Effective to (optional)
            <input
              type="date"
              className="h-10 rounded-lg border border-input px-3 text-sm"
              value={effectiveTo}
              onChange={(event) => setEffectiveTo(event.target.value)}
            />
          </label>
        </div>
      </AppModal>
    </section>
  )
}
