import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "react-router"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { ReceiptForm } from "@/features/receiving/ReceiptForm"
import { emptyReceiptLine, type ReceiptDraft } from "@/features/receiving/receipt-draft"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { createStockReceipt, listReceivingOptions } from "@/lib/receiving/api"
import { notify } from "@/lib/utilities/notify"
import type { ReceiptFormValues } from "@/lib/validations/receiving"

function today() {
  return new Date().toISOString().slice(0, 10)
}

export function ReceiptEditorPage() {
  useDocumentTitle("New receipt")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const options = useQuery({
    queryKey: ["receiving-options"],
    queryFn: listReceivingOptions,
  })
  const create = useMutation({
    mutationFn: (values: ReceiptFormValues) =>
      createStockReceipt({
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
    onSuccess: async (receipt) => {
      notify.success(`Draft ${receipt.receipt_number} saved`)
      await queryClient.invalidateQueries({ queryKey: ["stock-receipts"] })
      await navigate(`/receiving/${receipt.id}`)
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const initial: ReceiptDraft = {
    godownId: "",
    supplierId: "",
    documentReference: "",
    receivedDate: today(),
    notes: "",
    lines: [emptyReceiptLine()],
  }

  return (
    <section>
      <PageHeader
        title="New receipt"
        description="Save a draft for the godown you work at. Submitting it asks a Godown Manager to verify accepted cases. Saving does not add stock."
      />
      {options.isLoading ? <LoadingBlock label="Loading receiving options" /> : null}
      {options.error ? (
        <p role="alert" className="text-sm text-destructive">
          {options.error.message}
        </p>
      ) : null}
      {options.data ? (
        <ReceiptForm
          initial={initial}
          options={options.data}
          pending={create.isPending}
          submitLabel="Save draft"
          onSubmit={(values) => create.mutate(values)}
        />
      ) : null}
    </section>
  )
}
