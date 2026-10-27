import { Link } from "react-router"
import { StatusBadge } from "@/components/shared/StatusBadge"
import {
  formatCases,
  formatRefillReceivingLabel,
  formatTimestamp,
} from "@/features/refill/utils/labels"
import { canCreateLinkedRefillReceipt } from "@/lib/refill/rules"
import type { RefillRequestDetail } from "@/lib/refill/api"

/**
 * REF-07 read-only reconciliation. Stock still posts only through Branch 03 verify.
 */
export function RefillReceivingPanel({
  request,
  canExecuteReceiving,
  canViewReceiving,
}: {
  request: RefillRequestDetail
  canExecuteReceiving: boolean
  canViewReceiving: boolean
}) {
  const snapshot = request.receiving
  if (!snapshot) return null
  const show =
    request.status === "approved" || (snapshot.receipts?.length ?? 0) > 0
  if (!show) return null

  const summary = snapshot.summary
  const canOpenReceiving = canCreateLinkedRefillReceipt({
    canExecuteReceiving,
    requestStatus: request.status,
    godownActive: request.godown_active,
  })

  return (
    <section className="grid gap-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold">Receiving & reconciliation</h2>
          <p className="text-sm text-muted-foreground">
            Posted accepted cases come from verified Branch 03 receipts only. Linking
            a receipt does not add inventory.
          </p>
        </div>
        <StatusBadge
          tone={
            summary.completion_label === "excess_requires_review"
              ? "danger"
              : summary.completion_label === "fully_received"
                ? "success"
                : summary.completion_label === "partially_received" ||
                    summary.completion_label === "pending_verification"
                  ? "warning"
                  : "neutral"
          }
        >
          {formatRefillReceivingLabel(summary.completion_label)}
        </StatusBadge>
      </div>
      <dl className="grid gap-3 rounded-2xl bg-card p-4 text-sm ring-1 ring-border sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">Requested cases</dt>
          <dd>{formatCases(summary.requested_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Verified accepted cases</dt>
          <dd>{formatCases(summary.accepted_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Damaged cases (posted receipts)</dt>
          <dd>{formatCases(summary.damaged_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Pending receipt cases</dt>
          <dd>{formatCases(summary.pending_receipt_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Outstanding cases</dt>
          <dd>{formatCases(summary.outstanding_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Excess cases</dt>
          <dd>{formatCases(summary.excess_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Supplier</dt>
          <dd>{request.supplier_name}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Destination godown</dt>
          <dd>
            {request.godown_code} · {request.godown_name}
            {request.godown_active ? "" : " (inactive)"}
          </dd>
        </div>
      </dl>
      <p className="text-sm text-muted-foreground">
        {canOpenReceiving
          ? "Create the next physical receipt from Stock receiving and select this request."
          : "Accounts cannot post receiving. A Store Keeper counts the delivery; a Godown Manager verifies it."}
      </p>
      {canOpenReceiving ? (
        <div>
          <Link
            className="text-sm font-medium underline-offset-4 hover:underline"
            to="/receiving/new"
          >
            Open stock receiving
          </Link>
        </div>
      ) : null}
      <div className="overflow-x-auto rounded-2xl bg-card ring-1 ring-border">
        <table className="w-full min-w-[40rem] text-left text-sm">
          <thead>
            <tr className="border-b border-border text-muted-foreground">
              <th className="px-4 py-3 font-medium">SKU</th>
              <th className="px-4 py-3 font-medium">Requested</th>
              <th className="px-4 py-3 font-medium">Accepted</th>
              <th className="px-4 py-3 font-medium">Outstanding</th>
              <th className="px-4 py-3 font-medium">Excess</th>
              <th className="px-4 py-3 font-medium">Damaged</th>
              <th className="px-4 py-3 font-medium">Pending</th>
            </tr>
          </thead>
          <tbody>
            {snapshot.lines.map((line) => (
              <tr key={line.product_id} className="border-b border-border last:border-0">
                <td className="px-4 py-3">
                  {line.product_sku}
                  <span className="ml-2 text-muted-foreground">{line.product_name}</span>
                </td>
                <td className="px-4 py-3">{formatCases(line.requested_cases)}</td>
                <td className="px-4 py-3">{formatCases(line.accepted_cases)}</td>
                <td className="px-4 py-3">{formatCases(line.outstanding_cases)}</td>
                <td className="px-4 py-3">{formatCases(line.excess_cases)}</td>
                <td className="px-4 py-3">{formatCases(line.damaged_cases)}</td>
                <td className="px-4 py-3">{formatCases(line.pending_receipt_cases)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div>
        <h3 className="mb-2 text-sm font-semibold">Linked receipts</h3>
        {snapshot.receipts.length === 0 ? (
          <p className="text-sm text-muted-foreground">No linked receipts yet.</p>
        ) : (
          <ul className="grid gap-2 text-sm">
            {snapshot.receipts.map((receipt) => (
              <li
                key={receipt.id}
                className="rounded-xl bg-card px-4 py-3 ring-1 ring-border"
              >
                <p className="font-medium">
                  {canViewReceiving ? (
                    <Link
                      className="underline-offset-4 hover:underline"
                      to={`/receiving/${receipt.id}`}
                    >
                      {receipt.receipt_number}
                    </Link>
                  ) : (
                    receipt.receipt_number
                  )}
                  <span className="ml-2 text-muted-foreground">{receipt.status}</span>
                </p>
                <p className="text-muted-foreground">
                  {receipt.document_reference} · accepted {formatCases(receipt.accepted_cases)}{" "}
                  · damaged {formatCases(receipt.damaged_cases)} · verified{" "}
                  {formatTimestamp(receipt.verified_at)}
                </p>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  )
}
