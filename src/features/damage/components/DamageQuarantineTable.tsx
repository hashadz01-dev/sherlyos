import { Link } from "react-router"
import { EmptyState } from "@/components/shared/EmptyState"
import {
  formatCases,
  formatDamageScenario,
  formatHoldKind,
  formatHoldStatus,
  formatIsolationClass,
} from "@/features/damage/utils/labels"
import type { DamageQuarantineRow } from "@/lib/damage/api"

export function DamageQuarantineTable({
  rows,
}: {
  rows: DamageQuarantineRow[]
}) {
  if (rows.length === 0) {
    return (
      <EmptyState
        title="No quarantine inventory"
        description="No authorized holds match the current filters."
      />
    )
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b text-left text-muted-foreground">
            <th className="py-2 pr-3">Godown</th>
            <th className="py-2 pr-3">Zone</th>
            <th className="py-2 pr-3">Crate</th>
            <th className="py-2 pr-3">Product</th>
            <th className="py-2 pr-3">Cases</th>
            <th className="py-2 pr-3">Report</th>
            <th className="py-2 pr-3">Isolation</th>
            <th className="py-2 pr-3">Scenario</th>
            <th className="py-2 pr-3">Hold</th>
            <th className="py-2 pr-3">Stock txn</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.hold_id} className="border-b last:border-0">
              <td className="py-2 pr-3">
                {row.godown_name}
                {row.godown_active ? "" : " (inactive)"}
              </td>
              <td className="py-2 pr-3">{row.zone_code ?? "—"}</td>
              <td className="py-2 pr-3">{row.crate_code ?? "—"}</td>
              <td className="py-2 pr-3">
                {row.product_sku} · {row.product_name}
              </td>
              <td className="py-2 pr-3">{formatCases(row.quantity_cases)}</td>
              <td className="py-2 pr-3">
                <Link
                  className="font-medium underline-offset-2 hover:underline"
                  to={`/damage/${row.damage_report_id}`}
                >
                  {row.report_number}
                </Link>
              </td>
              <td className="py-2 pr-3">
                {formatIsolationClass(row.isolation_class)}
              </td>
              <td className="py-2 pr-3">
                {formatDamageScenario(row.scenario)}
              </td>
              <td className="py-2 pr-3">
                {formatHoldKind(row.hold_kind)} ·{" "}
                {formatHoldStatus(row.hold_status)}
              </td>
              <td className="py-2 pr-3 font-mono text-xs">
                {row.posted_transaction_id
                  ? row.posted_transaction_id.slice(0, 8)
                  : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
