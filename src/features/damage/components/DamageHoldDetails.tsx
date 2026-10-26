import {
  formatCases,
  formatHoldKind,
  formatHoldStatus,
} from "@/features/damage/utils/labels"
import type { DamageHoldRow } from "@/lib/damage/api"

export function DamageHoldDetails({ holds }: { holds: DamageHoldRow[] }) {
  if (holds.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No stock holds are recorded for this report. Inbound and transit
        scenarios may never create holds.
      </p>
    )
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b text-left text-muted-foreground">
            <th className="py-2 pr-3">Product</th>
            <th className="py-2 pr-3">Kind</th>
            <th className="py-2 pr-3">Status</th>
            <th className="py-2 pr-3">Crate</th>
            <th className="py-2 pr-3">Zone</th>
            <th className="py-2 pr-3">Lot</th>
            <th className="py-2 pr-3">Cases</th>
            <th className="py-2 pr-3">Reservation</th>
            <th className="py-2 pr-3">Stock txn</th>
          </tr>
        </thead>
        <tbody>
          {holds.map((hold) => (
            <tr key={hold.id} className="border-b last:border-0">
              <td className="py-2 pr-3">
                {hold.product_sku
                  ? `${hold.product_sku} · ${hold.product_name}`
                  : hold.product_id.slice(0, 8)}
              </td>
              <td className="py-2 pr-3">{formatHoldKind(hold.hold_kind)}</td>
              <td className="py-2 pr-3">{formatHoldStatus(hold.status)}</td>
              <td className="py-2 pr-3">
                {hold.crate_code ?? hold.crate_id.slice(0, 8)}
                {hold.location_role === "quarantine" ? " · quarantine" : ""}
              </td>
              <td className="py-2 pr-3">{hold.zone_code ?? "—"}</td>
              <td className="py-2 pr-3 font-mono text-xs">
                {hold.lot_id ? hold.lot_id.slice(0, 8) : "—"}
              </td>
              <td className="py-2 pr-3">{formatCases(hold.quantity_cases)}</td>
              <td className="py-2 pr-3 font-mono text-xs">
                {hold.source_reservation_id
                  ? hold.source_reservation_id.slice(0, 8)
                  : "—"}
              </td>
              <td className="py-2 pr-3 font-mono text-xs">
                {hold.posted_transaction_id
                  ? hold.posted_transaction_id.slice(0, 8)
                  : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
