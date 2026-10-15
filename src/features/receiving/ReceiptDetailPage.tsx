import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useParams } from "react-router"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { ReceiptForm } from "@/features/receiving/ReceiptForm"
import type { ReceiptDraft } from "@/features/receiving/receipt-draft"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  cancelStockReceipt,
  getStockReceipt,
  holdStockReceipt,
  listReceivingOptions,
  releaseStockReceipt,
  submitStockReceipt,
  updateStockReceipt,
  verifyStockReceipt,
  type StockReceipt,
} from "@/lib/receiving/api"
import { receiptActions, receiptTotals, type ReceiptStatus } from "@/lib/receiving/rules"
import { notify } from "@/lib/utilities/notify"
import type { ReceiptFormValues } from "@/lib/validations/receiving"

const statusTone: Record<ReceiptStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  held: "warning",
  posted: "success",
  cancelled: "danger",
}

const auditLabel: Record<string, string> = {
  create_stock_receipt: "Created",
  update_stock_receipt: "Edited",
  submit_stock_receipt: "Submitted",
  hold_stock_receipt: "Held",
  release_stock_receipt: "Returned for correction",
  verify_stock_receipt: "Verified and posted",
  cancel_stock_receipt: "Cancelled",
}

export function ReceiptDetailPage() {
  const { receiptId = "" } = useParams()
  const receipt = useQuery({
    queryKey: ["stock-receipt", receiptId],
    queryFn: () => getStockReceipt(receiptId),
    enabled: receiptId.length > 0,
  })
  useDocumentTitle(receipt.data?.receipt_number ?? "Receipt")

  return (
    <section>
      {receipt.isLoading ? <LoadingBlock label="Loading receipt" /> : null}
      {receipt.error ? (
        <p role="alert" className="text-sm text-destructive">
          {receipt.error.message}
        </p>
      ) : null}
      {receipt.data ? <ReceiptDetail receipt={receipt.data} /> : null}
    </section>
  )
}

function ReceiptDetail({ receipt }: { receipt: StockReceipt }) {
  const { session } = useAuth()
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const actions = receiptActions({
    status: receipt.status,
    isCreator: session?.user.id === receipt.created_by,
    canExecute: can("receiving.execute"),
    canVerify: can("receiving.verify"),
  })
  const options = useQuery({
    queryKey: ["receiving-options"],
    queryFn: listReceivingOptions,
    enabled: actions.canEdit,
  })
  const [holdOpen, setHoldOpen] = useState(false)
  const [cancelOpen, setCancelOpen] = useState(false)
  const [verifyOpen, setVerifyOpen] = useState(false)
  const [reason, setReason] = useState("")
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const totals = receiptTotals(
    receipt.lines.map((line) => ({
      documentCases: line.document_cases,
      countedCases: line.counted_cases,
      damagedCases: line.damaged_cases,
    })),
  )

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: ["stock-receipt", receipt.id] })
    await queryClient.invalidateQueries({ queryKey: ["stock-receipts"] })
    await queryClient.invalidateQueries({ queryKey: ["stock-balances"] })
    await queryClient.invalidateQueries({ queryKey: ["stock-transactions"] })
  }

  const update = useMutation({
    mutationFn: (values: ReceiptFormValues) =>
      updateStockReceipt({
        target_receipt: receipt.id,
        target_godown: values.godownId,
        target_supplier: values.supplierId,
        supplier_document: values.documentReference,
        received_on: values.receivedDate,
        receipt_notes: values.notes || null,
        line_items: values.lines.map((line) => ({
          product_id: line.productId,
          destination_crate_id: line.crateId,
          document_cases: Number(line.documentCases),
          counted_cases: Number(line.countedCases),
          damaged_cases: Number(line.damagedCases),
        })),
      }),
    onSuccess: async () => {
      notify.success("Draft updated")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const submit = useMutation({
    mutationFn: () => submitStockReceipt(receipt.id),
    onSuccess: async () => {
      notify.success("Receipt submitted for verification")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const hold = useMutation({
    mutationFn: () => holdStockReceipt(receipt.id, reason),
    onSuccess: async () => {
      setHoldOpen(false)
      setReason("")
      notify.success("Receipt held")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const release = useMutation({
    mutationFn: () => releaseStockReceipt(receipt.id),
    onSuccess: async () => {
      notify.success("Receipt returned for correction")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const cancel = useMutation({
    mutationFn: () => cancelStockReceipt(receipt.id, reason),
    onSuccess: async () => {
      setCancelOpen(false)
      setReason("")
      notify.success("Receipt cancelled")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const verify = useMutation({
    mutationFn: () => verifyStockReceipt(receipt.id, idempotencyKey),
    onSuccess: async (posted) => {
      setVerifyOpen(false)
      const references = posted.transactions.map((row) => row.reference_number).join(", ")
      notify.success(
        references
          ? `${posted.receipt_number} posted as ${references}`
          : `${posted.receipt_number} verified with no stock movement`,
      )
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const initial: ReceiptDraft = {
    godownId: receipt.godown_id,
    supplierId: receipt.supplier_id,
    documentReference: receipt.document_reference,
    receivedDate: receipt.received_date,
    notes: receipt.notes ?? "",
    lines: receipt.lines.map((line) => ({
      key: line.id,
      productId: line.product_id,
      zoneId: line.zone_id,
      crateId: line.destination_crate_id,
      documentCases: String(line.document_cases),
      countedCases: String(line.counted_cases),
      damagedCases: String(line.damaged_cases),
    })),
  }

  return (
    <>
      <PageHeader
        title={receipt.receipt_number}
        description={`${receipt.supplier_name} · ${receipt.godown_name} · ${receipt.document_reference}`}
        action={<StatusBadge tone={statusTone[receipt.status]}>{receipt.status}</StatusBadge>}
      />
      <dl className="mb-6 grid gap-3 text-sm md:grid-cols-3">
        <Fact label="Received date" value={receipt.received_date} />
        <Fact label="Created by" value={receipt.creator_name ?? "Unknown"} />
        <Fact label="Verification" value={receipt.verified_at ? "Verified" : "Not verified"} />
      </dl>
      {receipt.hold_reason ? (
        <p className="mb-4 text-sm">Hold reason: {receipt.hold_reason}</p>
      ) : null}
      {receipt.cancellation_reason ? (
        <p className="mb-4 text-sm">Cancellation reason: {receipt.cancellation_reason}</p>
      ) : null}
      {actions.canEdit && options.isLoading ? <LoadingBlock label="Loading receipt editor" /> : null}
      {actions.canEdit && options.error ? (
        <p role="alert" className="text-sm text-destructive">
          {options.error.message}
        </p>
      ) : null}
      {actions.canEdit && options.data ? (
        <ReceiptForm
          key={receipt.updated_at}
          initial={initial}
          options={options.data}
          pending={update.isPending}
          submitLabel="Save draft"
          onSubmit={(values) => update.mutate(values)}
        />
      ) : (
        <ReceiptLines receipt={receipt} />
      )}
      <div className="mt-4 flex flex-wrap gap-2">
        {actions.canSubmit ? (
          <Button disabled={submit.isPending} onClick={() => submit.mutate()}>
            Submit for verification
          </Button>
        ) : null}
        {actions.canHold ? (
          <Button variant="outline" onClick={() => setHoldOpen(true)}>
            Hold
          </Button>
        ) : null}
        {actions.canRelease ? (
          <Button variant="outline" disabled={release.isPending} onClick={() => release.mutate()}>
            Return for correction
          </Button>
        ) : null}
        {actions.canVerify ? (
          <Button onClick={() => setVerifyOpen(true)}>Verify and post</Button>
        ) : null}
        {actions.canCancelOwn || actions.canCancelAsManager ? (
          <Button variant="destructive" onClick={() => setCancelOpen(true)}>
            Cancel receipt
          </Button>
        ) : null}
      </div>
      {receipt.transactions.length > 0 ? (
        <section className="mt-8">
          <h2 className="mb-3 text-sm font-semibold">Stock transactions</h2>
          <ul className="grid gap-2 text-sm">
            {receipt.transactions.map((row) => (
              <li key={row.id}>
                {row.reference_number} · {row.quantity} accepted cases
              </li>
            ))}
          </ul>
        </section>
      ) : null}
      <section className="mt-8">
        <h2 className="mb-3 text-sm font-semibold">History</h2>
        {receipt.audit.length === 0 ? (
          <p className="text-sm text-muted-foreground">No status history yet.</p>
        ) : (
          <ol className="grid gap-2 text-sm">
            {receipt.audit.map((entry) => (
              <li key={`${entry.action}-${entry.occurred_at}`}>
                {auditLabel[entry.action] ?? entry.action} · {entry.actor_name ?? "Unknown"} ·{" "}
                {new Date(entry.occurred_at).toLocaleString()}
              </li>
            ))}
          </ol>
        )}
      </section>
      <AppModal
        open={holdOpen}
        onOpenChange={setHoldOpen}
        title="Hold receipt"
        description="The original Store Keeper can correct this receipt after it is returned."
        footer={
          <>
            <Button variant="outline" onClick={() => setHoldOpen(false)}>
              Close
            </Button>
            <Button disabled={hold.isPending || reason.trim().length === 0} onClick={() => hold.mutate()}>
              Hold receipt
            </Button>
          </>
        }
      >
        <TextField label="Hold reason" value={reason} onChange={(event) => setReason(event.target.value)} />
      </AppModal>
      <AppModal
        open={cancelOpen}
        onOpenChange={setCancelOpen}
        title="Cancel receipt"
        description="A cancelled receipt cannot be reopened, and its supplier document cannot be used again."
        footer={
          <>
            <Button variant="outline" onClick={() => setCancelOpen(false)}>
              Close
            </Button>
            <Button
              variant="destructive"
              disabled={cancel.isPending || reason.trim().length === 0}
              onClick={() => cancel.mutate()}
            >
              Cancel receipt
            </Button>
          </>
        }
      >
        <TextField
          label="Cancellation reason"
          value={reason}
          onChange={(event) => setReason(event.target.value)}
        />
      </AppModal>
      <AppModal
        open={verifyOpen}
        onOpenChange={setVerifyOpen}
        title="Verify receipt"
        description="Verifying this receipt will permanently post the accepted carton cases to inventory. This action cannot be undone."
        footer={
          <>
            <Button variant="outline" onClick={() => setVerifyOpen(false)}>
              Close
            </Button>
            <Button disabled={verify.isPending} onClick={() => verify.mutate()}>
              Verify and post
            </Button>
          </>
        }
      >
        <dl className="grid grid-cols-2 gap-3 text-sm">
          <Fact label="Document cases" value={String(totals.documentCases)} />
          <Fact label="Counted cases" value={String(totals.countedCases)} />
          <Fact label="Damaged cases" value={String(totals.damagedCases)} />
          <Fact label="Accepted cases" value={String(totals.acceptedCases)} />
        </dl>
      </AppModal>
    </>
  )
}

function ReceiptLines({ receipt }: { receipt: StockReceipt }) {
  return (
    <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200">
      <table className="w-full min-w-[48rem] text-left text-sm">
        <thead className="text-xs tracking-wide text-muted-foreground uppercase">
          <tr>
            <th className="px-4 py-3 font-medium">Product</th>
            <th className="px-4 py-3 font-medium">Location</th>
            <th className="px-4 py-3 text-right font-medium">Document</th>
            <th className="px-4 py-3 text-right font-medium">Counted</th>
            <th className="px-4 py-3 text-right font-medium">Damaged</th>
            <th className="px-4 py-3 text-right font-medium">Accepted</th>
          </tr>
        </thead>
        <tbody>
          {receipt.lines.map((line) => (
            <tr key={line.id} className="border-t border-slate-100">
              <td className="px-4 py-3">
                {line.product_name}
                <span className="ml-2 text-muted-foreground">{line.product_sku}</span>
              </td>
              <td className="px-4 py-3">
                {line.zone_code} / {line.crate_code}
              </td>
              <td className="px-4 py-3 text-right">{line.document_cases}</td>
              <td className="px-4 py-3 text-right">{line.counted_cases}</td>
              <td className="px-4 py-3 text-right">{line.damaged_cases}</td>
              <td className="px-4 py-3 text-right">{line.accepted_cases}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Fact({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="font-medium">{value}</dd>
    </div>
  )
}
