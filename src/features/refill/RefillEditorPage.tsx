import { useEffect, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useNavigate, useParams } from "react-router"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { RefillForm, type RefillFormValues } from "@/features/refill/components/RefillForm"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import {
  createStockRefillRequest,
  getStockRefillRequest,
  listStockRefillOptions,
  updateStockRefillRequest,
} from "@/lib/refill/api"
import {
  canEditRefillRequest,
  refillCreateIdempotencyKey,
} from "@/lib/refill/rules"

const CREATE_KEY = "sherlyos.refill.createIdempotency"

function notesOrNull(notes: string) {
  const cleaned = notes.trim()
  return cleaned.length > 0 ? cleaned : null
}

export function NewRefillRequestPage() {
  useDocumentTitle("New refill request")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { can } = useAccess()
  const [idempotencyKey] = useState(() => {
    const stored = sessionStorage.getItem(CREATE_KEY)
    const key = refillCreateIdempotencyKey(stored)
    sessionStorage.setItem(CREATE_KEY, key)
    return key
  })
  const options = useQuery({
    queryKey: ["refill-options"],
    queryFn: listStockRefillOptions,
    enabled: can("refill.request"),
  })
  const create = useMutation({
    mutationFn: (values: RefillFormValues) =>
      createStockRefillRequest({
        supplierId: values.supplierId,
        godownId: values.godownId,
        lines: values.lines,
        notes: notesOrNull(values.notes),
        idempotencyKey,
      }),
    retry: false,
    onSuccess: async (created) => {
      sessionStorage.removeItem(CREATE_KEY)
      await queryClient.invalidateQueries({ queryKey: ["refill-requests"] })
      navigate(`/refill/${created.id}`)
    },
  })

  if (!can("refill.request")) {
    return (
      <p role="alert" className="text-sm text-destructive">
        You do not have permission to create refill requests.
      </p>
    )
  }

  return (
    <section className="min-w-0">
      <PageHeader
        title="New refill request"
        description="Prepare a brand-specific supplier replenishment. Saving a draft does not change stock. If the save is interrupted, stay on this page and try again — do not open a second new-request tab."
      />
      {options.isLoading ? <LoadingBlock label="Loading catalog" /> : null}
      {options.error ? (
        <p role="alert" className="text-sm text-destructive">
          {options.error.message}
        </p>
      ) : null}
      {options.data ? (
        <RefillForm
          options={options.data}
          initial={{
            supplierId: "",
            godownId: "",
            notes: "",
            lines: [{ product_id: "", requested_cases: 1 }],
          }}
          submitLabel="Save draft"
          pending={create.isPending}
          error={create.error?.message ?? null}
          onSubmit={(values) => create.mutate(values)}
        />
      ) : null}
    </section>
  )
}

export function EditRefillRequestPage() {
  const { requestId = "" } = useParams()
  useDocumentTitle("Edit refill request")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { session } = useAuth()
  const { can } = useAccess()
  const detail = useQuery({
    queryKey: ["refill-request", requestId],
    queryFn: () => getStockRefillRequest(requestId),
    enabled: requestId.length > 0,
  })
  const options = useQuery({
    queryKey: ["refill-options"],
    queryFn: listStockRefillOptions,
  })
  const save = useMutation({
    retry: false,
    mutationFn: (values: RefillFormValues) => {
      if (!detail.data) {
        throw new Error("Request is not loaded.")
      }
      return updateStockRefillRequest({
        requestId: detail.data.id,
        expectedVersion: detail.data.version,
        supplierId: values.supplierId,
        godownId: values.godownId,
        lines: values.lines,
        notes: notesOrNull(values.notes),
      })
    },
    onSuccess: async (updated) => {
      await queryClient.invalidateQueries({ queryKey: ["refill-requests"] })
      await queryClient.invalidateQueries({ queryKey: ["refill-request", requestId] })
      navigate(`/refill/${updated.id}`)
    },
  })

  const request = detail.data
  const allowed =
    request &&
    canEditRefillRequest({
      status: request.status,
      createdBy: request.created_by,
      viewerId: session?.user.id ?? null,
      canRequest: can("refill.request"),
    })

  useEffect(() => {
    if (detail.data && !allowed) {
      navigate(`/refill/${requestId}`, { replace: true })
    }
  }, [allowed, detail.data, navigate, requestId])

  return (
    <section className="min-w-0">
      <PageHeader
        title={request ? `Edit ${request.request_number}` : "Edit refill request"}
        description="Held requests can be revised and resubmitted. Stock is not changed."
        action={
          <ButtonLinkFallback requestId={requestId} />
        }
      />
      {detail.isLoading || options.isLoading ? (
        <LoadingBlock label="Loading request" />
      ) : null}
      {detail.error || options.error ? (
        <p role="alert" className="text-sm text-destructive">
          {(detail.error ?? options.error)?.message}
        </p>
      ) : null}
      {request && options.data && allowed ? (
        <RefillForm
          key={`${request.id}-${request.version}`}
          options={options.data}
          initial={{
            supplierId: request.supplier_id,
            godownId: request.destination_godown_id,
            notes: request.notes ?? "",
            lines: request.lines.map((line) => ({
              product_id: line.product_id,
              requested_cases: line.requested_cases,
            })),
          }}
          submitLabel="Save changes"
          pending={save.isPending}
          error={save.error?.message ?? null}
          onSubmit={(values) => save.mutate(values)}
        />
      ) : null}
    </section>
  )
}

function ButtonLinkFallback({ requestId }: { requestId: string }) {
  return (
    <Link
      className="inline-flex h-10 items-center rounded-lg border border-input px-4 text-sm"
      to={`/refill/${requestId}`}
    >
      Back to request
    </Link>
  )
}
