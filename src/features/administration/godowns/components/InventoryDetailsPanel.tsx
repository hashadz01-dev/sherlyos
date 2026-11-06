import type { StockBalance, StockLotBalance } from "@/lib/inventory/api"
import type { VisualSlot } from "@/lib/warehouse/capacity"
import { formatCases } from "@/lib/warehouse/capacity"

export function InventoryDetailsPanel({
  slot,
  crateCode,
  zoneName,
  godownName,
  products,
  lots,
  quarantine,
}: {
  slot: VisualSlot | null
  crateCode: string
  zoneName: string
  godownName: string
  products: StockBalance[]
  lots: StockLotBalance[]
  quarantine: boolean
}) {
  if (!slot) {
    return (
      <aside className="rounded-2xl bg-white p-4 ring-1 ring-slate-200">
        <h2 className="text-sm font-semibold">Position details</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          Select a position. The grid is a visualized allocation, not a map of
          individual cases.
        </p>
      </aside>
    )
  }
  return (
    <aside className="rounded-2xl bg-white p-4 ring-1 ring-slate-200">
      <h2 className="text-sm font-semibold">Position {slot.label}</h2>
      <p className="mt-1 text-xs text-muted-foreground">
        Visualized allocation — not physically mapped. {godownName} · {zoneName} ·{" "}
        {crateCode}
        {quarantine ? " · quarantine location" : ""}
      </p>
      {slot.status === "available" ? (
        <p className="mt-3 text-sm">Empty capacity — no stock assigned.</p>
      ) : null}
      {slot.status === "quarantined" ? (
        <p className="mt-3 text-sm">
          Quarantined stock is not available for normal picking.
        </p>
      ) : null}
      {slot.status === "unavailable" ? (
        <p className="mt-3 text-sm">
          This crate is inactive, so its planned positions are unavailable.
        </p>
      ) : null}
      {slot.slice ? (
        <dl className="mt-3 grid gap-2 text-sm">
          <div>
            <dt className="text-xs text-muted-foreground">Product</dt>
            <dd>
              {slot.slice.productName} · {slot.slice.sku}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">Lot</dt>
            <dd>{slot.slice.lotCode ?? slot.slice.lotId ?? "Not lot-specific"}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">Quantity in this lot or line</dt>
            <dd>{formatCases(slot.slice.quantity)}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">Expiry</dt>
            <dd>{slot.slice.expiryDate ?? "—"}</dd>
          </div>
        </dl>
      ) : slot.status !== "available" && slot.status !== "unavailable" ? (
        <p className="mt-3 text-sm">
          On-hand quantity does not match a single lot breakdown, so this
          position is not assigned to a product.
        </p>
      ) : null}
      <h3 className="mt-4 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        Actual contents
      </h3>
      <ul className="mt-2 grid gap-2 text-sm">
        {products.length === 0 ? <li>No on-hand cases.</li> : null}
        {products.map((product) => (
          <li key={product.product_id}>
            {product.product_sku} · {product.product_name} ·{" "}
            {formatCases(product.quantity)}
          </li>
        ))}
      </ul>
      {lots.length > 0 ? (
        <ul className="mt-3 grid gap-1 text-xs text-muted-foreground">
          {lots.map((lot) => (
            <li key={lot.lot_id}>
              {lot.product_sku} lot {lot.manufacturer_lot_code ?? lot.lot_id} ·{" "}
              {formatCases(lot.quantity)} · {lot.lot_status}
              {lot.expiry_date ? ` · expiry ${lot.expiry_date}` : ""}
            </li>
          ))}
        </ul>
      ) : null}
    </aside>
  )
}
