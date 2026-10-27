import { Link } from "react-router"
import { StatusBadge } from "@/components/shared/StatusBadge"
import {
  formatCases,
  formatLinkedReceiptStatus,
  formatRefillReceivingLabel,
  formatTimestamp,
  receiptStatusTone,
} from "@/features/refill/utils/labels"
import { canCreateLinkedRefillReceipt } from "@/lib/refill/rules"
import type { RefillRequestDetail } from "@/lib/refill/api"

/**
 * REF-07 read-only reconciliation. Stock still posts only through Branch 03 verify.
 * Reserved cases include drafts; they are not accepted inventory.
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
  const draftReceipts = snapshot.receipts.filter((receipt) => receipt.status === "draft")

  return (
    <section className="grid gap-4" id="refill-receiving" aria-labelledby="refill-receiving-heading">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 id="refill-receiving-heading" className="text-base font-semibold">
            Receiving & reconciliation
          </h2>
          <p className="text-sm text-muted-foreground">
            Posted accepted cases come from verified Branch 03 receipts only. Linking
            a receipt does not add inventory. This request stays approved until an
            owner-approved completion policy exists.
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
      <dl className="grid gap-3 rounded-2xl bg-card p-4 text-sm ring-1 ring-border sm:grid-cols-2 lg:grid-cols-4">
        <div>
          <dt className="text-muted-foreground">Requested cases</dt>
          <dd>{formatCases(summary.requested_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Reserved on linked receipts</dt>
          <dd>{formatCases(summary.reserved_cases ?? 0)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Reserved on drafts</dt>
          <dd>{formatCases(summary.draft_reserved_cases ?? 0)}</dd>
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
        {summary.excess_cases > 0 ? (
          <div>
            <dt className="text-muted-foreground">Historical excess</dt>
            <dd>{formatCases(summary.excess_cases)}</dd>
          </div>
        ) : null}
      </dl>
      {(summary.draft_reserved_cases ?? 0) > 0 ? (
        <aside
          role="status"
          className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200"
        >
          Draft receipts still reserve requested quantity until they are completed or
          cancelled. Reserved cases are not accepted stock. Accounts cannot cancel
          Store Keeper receipts.
        </aside>
      ) : null}
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
        <table className="w-full min-w-[48rem] text-left text-sm">
          <thead>
            <tr className="border-b border-border text-muted-foreground">
              <th className="px-4 py-3 font-medium">SKU</th>
              <th className="px-4 py-3 font-medium">Requested</th>
              <th className="px-4 py-3 font-medium">Reserved</th>
              <th className="px-4 py-3 font-medium">Draft reserved</th>
              <th className="px-4 py-3 font-medium">Verified accepted</th>
              <th className="px-4 py-3 font-medium">Outstanding</th>
              {snapshot.lines.some((line) => line.excess_cases > 0) ? (
                <th className="px-4 py-3 font-medium">Excess</th>
              ) : null}
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
                <td className="px-4 py-3">{formatCases(line.reserved_cases ?? 0)}</td>
                <td className="px-4 py-3">{formatCases(line.draft_reserved_cases ?? 0)}</td>
                <td className="px-4 py-3">{formatCases(line.accepted_cases)}</td>
                <td className="px-4 py-3">{formatCases(line.outstanding_cases)}</td>
                {snapshot.lines.some((item) => item.excess_cases > 0) ? (
                  <td className="px-4 py-3">{formatCases(line.excess_cases)}</td>
                ) : null}
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
                  <span className="ml-2">
                    <StatusBadge tone={receiptStatusTone[receipt.status] ?? "neutral"}>
                      {formatLinkedReceiptStatus(receipt.status)}
                    </StatusBadge>
                  </span>
                </p>
                <p className="mt-1 text-muted-foreground">
                  {receipt.document_reference} · counted {formatCases(receipt.counted_cases)} ·
                  accepted {formatCases(receipt.accepted_cases)} · damaged{" "}
                  {formatCases(receipt.damaged_cases)} · verified{" "}
                  {formatTimestamp(receipt.verified_at)}
                </p>
                {receipt.status === "draft" && canViewReceiving ? (
                  <p className="mt-1">
                    <Link
                      className="font-medium underline-offset-4 hover:underline"
                      to={`/receiving/${receipt.id}`}
                    >
                      Open draft to complete or cancel
                    </Link>
                  </p>
                ) : null}
              </li>
            ))}
          </ul>
        )}
        {draftReceipts.length > 0 && !canViewReceiving ? (
          <p className="mt-2 text-sm text-muted-foreground">
            Ask a Store Keeper to complete or cancel the draft receipt. Accounts cannot
            cancel receiving documents.
          </p>
        ) : null}
      </div>
    </section>
  )
}
