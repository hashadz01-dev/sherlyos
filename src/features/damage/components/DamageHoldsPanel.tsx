import {
  damageHoldKindLabels,
  damageHoldStatusLabels,
  formatCases,
} from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import type { DamageHoldRow, DamageReportDetail } from "@/lib/damage/api"

export function DamageHoldsPanel({ report }: { report: DamageReportDetail }) {
  const breakdown = damageQuantityBreakdown(report)
  const holds = report.holds ?? []

  return (
    <div className="grid gap-4">
      <dl className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Reported</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.reportedCases)}
          </dd>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Logical hold</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.heldCases)}
          </dd>
          <p className="mt-1 text-xs text-muted-foreground">
            Not a physical quarantine move
          </p>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Quarantined</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.quarantinedCases)}
          </dd>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Written off</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.writtenOffCases)}
          </dd>
        </div>
      </dl>

      {holds.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No stock holds are recorded for this report. Inbound and transit
          scenarios may never create holds.
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-muted-foreground">
                <th className="py-2 pr-3">Kind</th>
                <th className="py-2 pr-3">Status</th>
                <th className="py-2 pr-3">Crate</th>
                <th className="py-2 pr-3">Role</th>
                <th className="py-2 pr-3">Cases</th>
                <th className="py-2 pr-3">Stock txn</th>
              </tr>
            </thead>
            <tbody>
              {holds.map((hold: DamageHoldRow) => (
                <tr key={hold.id} className="border-b last:border-0">
                  <td className="py-2 pr-3">
                    {damageHoldKindLabels[hold.hold_kind] ?? hold.hold_kind}
                  </td>
                  <td className="py-2 pr-3">
                    {damageHoldStatusLabels[hold.status] ?? hold.status}
                  </td>
                  <td className="py-2 pr-3">
                    {hold.crate_code ?? hold.crate_id.slice(0, 8)}
                  </td>
                  <td className="py-2 pr-3">{hold.location_role ?? "—"}</td>
                  <td className="py-2 pr-3">
                    {formatCases(hold.quantity_cases)}
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
      )}
    </div>
  )
}
