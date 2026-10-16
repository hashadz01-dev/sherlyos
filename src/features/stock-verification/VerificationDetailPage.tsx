import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { notify } from "@/lib/utilities/notify"
import {
  addVerificationFoundProduct,
  closeStockVerification,
  getStockVerification,
  reportStockDiscrepancy,
  requestVerificationRecount,
  reviewVerificationDiscrepancy,
  reviewVerificationInactiveObject,
  saveVerificationCount,
  saveVerificationRecount,
  submitStockVerification,
  uploadVerificationPhoto,
  verificationPhotoPreview,
  type VerificationDetail,
  type VerificationLine,
} from "@/lib/verification/api"
import {
  canCloseVerification,
  countStatus,
  evidenceSatisfiesClosure,
  parseCaseCount,
  photoUploadTransition,
  recountRequired,
  sameIdSet,
  suggestedClosureResult,
  verificationActions,
  verificationErrorMessage,
  type ClosureResult,
  type PhotoUploadState,
  type VerificationStatus,
} from "@/lib/verification/rules"

const statusTone: Record<VerificationStatus, StatusTone> = {
  draft: "neutral",
  counting: "info",
  submitted: "info",
  recount: "warning",
  review: "warning",
  closed: "success",
}

const closeCopy =
  "Closing this verification permanently records the physical stock check and its discrepancies. Inventory balances will not change."

export function VerificationDetailPage() {
  const { verificationId = "" } = useParams()
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const detail = useQuery({
    queryKey: ["stock-verification", verificationId],
    enabled: Boolean(verificationId),
    queryFn: () => getStockVerification(verificationId),
  })
  useDocumentTitle(detail.data?.verification.verification_number ?? "Stock verification")

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: ["stock-verification", verificationId] })
    await queryClient.invalidateQueries({ queryKey: ["stock-verifications"] })
  }

  const actions = detail.data
    ? verificationActions({
        canVerify: can("stock.verify"),
        canCount: can("stock.count_assist"),
        canReport: can("stock.discrepancy.report"),
        status: detail.data.verification.status,
      })
    : null

  return (
    <section>
      <PageHeader
        title={detail.data?.verification.verification_number ?? "Stock verification"}
        description="Expected cases stay at the snapshot. Later ledger movement is shown separately and must be reconciled before closure."
        action={
          <Button variant="outline" asChild>
            <Link to="/stock-verification">Back</Link>
          </Button>
        }
      />
      {detail.isLoading ? <LoadingBlock label="Loading verification" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {detail.data && actions ? (
        <div className="grid gap-6">
          <Summary detail={detail.data} />
          <Lines detail={detail.data} actions={actions} onSaved={refresh} />
          <FoundProduct detail={detail.data} actions={actions} onSaved={refresh} />
          <Evidence detail={detail.data} actions={actions} onSaved={refresh} />
          <ClosurePanel detail={detail.data} actions={actions} onSaved={refresh} />
          <History detail={detail.data} />
        </div>
      ) : null}
    </section>
  )
}

function Summary({ detail }: { detail: VerificationDetail }) {
  const header = detail.verification
  const closure = detail.closure
  return (
    <div className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200 md:grid-cols-2">
      <p>
        Status <StatusBadge tone={statusTone[header.status]}>{header.status}</StatusBadge>
      </p>
      <p>Business date {header.business_date}</p>
      <p>Godown {header.godown_name}</p>
      <p>Started by {header.started_by_name ?? "Unknown"}</p>
      <p>
        Scope {detail.scopes.map((scope) => `${scope.zone_code}/${scope.crate_code}`).join(", ")}
      </p>
      <p>
        Progress {closure.lines_counted}/{closure.lines_total} counted
      </p>
      <p>Matched {closure.matched}</p>
      <p>
        Shortages {closure.shortages} · Overages {closure.overages}
      </p>
      <p>Movement-affected lines {closure.movement_affected}</p>
      <p>Verified photos {closure.verified_photos}</p>
      {header.closure_result ? <p>Result {header.closure_result.replaceAll("_", " ")}</p> : null}
      {header.closure_note ? <p>Closure note {header.closure_note}</p> : null}
      {header.correction_request_status === "requested" ? (
        <p>A correction is requested. Stock has not been adjusted.</p>
      ) : null}
    </div>
  )
}

function Lines({
  detail,
  actions,
  onSaved,
}: {
  detail: VerificationDetail
  actions: ReturnType<typeof verificationActions>
  onSaved: () => Promise<void>
}) {
  return (
    <div className="grid gap-4">
      {detail.unassigned_movements.length > 0 ? (
        <p className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 ring-1 ring-amber-200">
          Stock moved into a selected crate for a product that is not on this verification. Add that
          product before closure.
        </p>
      ) : null}
      {detail.lines.map((line) => (
        <LineCard key={line.id} line={line} actions={actions} onSaved={onSaved} />
      ))}
      {detail.lines.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No positive balances were in the selected crates. Add a physically found product if one is present.
        </p>
      ) : null}
    </div>
  )
}

function LineCard({
  line,
  actions,
  onSaved,
}: {
  line: VerificationLine
  actions: ReturnType<typeof verificationActions>
  onSaved: () => Promise<void>
}) {
  const [count, setCount] = useState("")
  const [recount, setRecount] = useState("")
  const [reason, setReason] = useState(line.discrepancy_reason ?? "")
  const [inactiveReason, setInactiveReason] = useState("")
  const [error, setError] = useState<string | null>(null)
  const variance = line.final_variance_cases
  const needsRecount = recountRequired(variance, line.recount_cases)
  const movementsPending =
    (line.movement_ids.length > 0 || (variance !== null && variance !== 0)) &&
    !sameIdSet(line.acknowledged_ledger_ids, line.movement_ids)
  const inactive =
    !line.product_active || !line.crate_active || !line.zone_active
  const run = useMutation({
    mutationFn: async (action: () => Promise<unknown>) => {
      setError(null)
      await action()
    },
    onSuccess: async () => {
      notify.success("Verification updated.")
      await onSaved()
    },
    onError: (caught) => setError(verificationErrorMessage(caught)),
  })

  return (
    <article className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="font-medium">
          {line.zone_code} · {line.crate_code} · {line.sku} {line.product_name}
        </h2>
        <StatusBadge tone={needsRecount ? "warning" : "neutral"}>
          {countStatus({
            countedCases: line.counted_cases,
            recountCases: line.recount_cases,
            recountRequested: line.recount_requested,
          })}
        </StatusBadge>
      </header>
      <div className="grid gap-1 sm:grid-cols-2">
        <p>Snapshot expected {line.expected_cases}</p>
        <p>Counted {line.counted_cases ?? "Not counted"}</p>
        <p>Recount {line.recount_cases ?? "No recount"}</p>
        <p>Ledger movement {line.ledger_movement_cases}</p>
        <p>Reconciled expected {line.reconciled_expected_cases ?? "Waiting for a count"}</p>
        <p>Final variance {variance ?? "Waiting for a count"}</p>
      </div>
      {line.first_counted_at ? (
        <p>
          First count by {line.first_counted_by_name ?? "Unknown"} at {line.first_counted_at}
        </p>
      ) : null}
      {line.recounted_at ? (
        <p>
          Recount by {line.recounted_by_name ?? "Unknown"} at {line.recounted_at}
        </p>
      ) : null}
      {line.movements.length > 0 ? (
        <ul className="grid gap-1">
          {line.movements.map((movement) => (
            <li key={movement.ledger_id}>
              {movement.transaction_type} {movement.reference_number}: {movement.quantity} cases
            </li>
          ))}
        </ul>
      ) : (
        <p>No ledger movement since the snapshot.</p>
      )}
      {inactive ? (
        <p className="text-amber-800">
          This crate, zone, or product became inactive. The snapshot and counts stay on the verification.
        </p>
      ) : null}
      {line.reviewed_at ? (
        <p>
          Reviewed by {line.reviewed_by_name ?? "Unknown"}
          {line.discrepancy_reason ? `: ${line.discrepancy_reason}` : ""}
        </p>
      ) : null}
      {line.inactive_reviewed_at ? (
        <p>
          Inactive review by {line.inactive_reviewed_by_name ?? "Unknown"}: {line.inactive_review_reason}
        </p>
      ) : null}
      {actions.canSaveCount && line.counted_cases === null ? (
        <div className="flex flex-wrap items-end gap-2">
          <label className="grid gap-1">
            Physical cases
            <Input
              aria-label={`Count ${line.sku}`}
              inputMode="numeric"
              value={count}
              onChange={(event) => setCount(event.target.value)}
            />
          </label>
          <Button
            type="button"
            onClick={() => {
              const parsed = parseCaseCount(count)
              if (!parsed.ok) {
                setError(parsed.message)
                return
              }
              run.mutate(() => saveVerificationCount(line.id, parsed.cases, line.line_version))
            }}
          >
            Save count
          </Button>
        </div>
      ) : null}
      {actions.canRequestRecount && line.counted_cases !== null && variance !== 0 ? (
        <Button type="button" variant="outline" onClick={() => run.mutate(() => requestVerificationRecount(line.id))}>
          Request recount
        </Button>
      ) : null}
      {actions.canSaveRecount && line.recount_requested ? (
        <div className="flex flex-wrap items-end gap-2">
          <label className="grid gap-1">
            Recount cases
            <Input
              aria-label={`Recount ${line.sku}`}
              inputMode="numeric"
              value={recount}
              onChange={(event) => setRecount(event.target.value)}
            />
          </label>
          <Button
            type="button"
            onClick={() => {
              const parsed = parseCaseCount(recount)
              if (!parsed.ok) {
                setError(parsed.message)
                return
              }
              run.mutate(() => saveVerificationRecount(line.id, parsed.cases, line.line_version))
            }}
          >
            Save recount
          </Button>
        </div>
      ) : null}
      {actions.canReport && variance !== null && (variance !== 0 || line.movement_ids.length > 0) ? (
        <div className="flex flex-wrap items-end gap-2">
          <label className="grid min-w-0 flex-1 gap-1">
            Discrepancy reason
            <Input aria-label={`Reason ${line.sku}`} value={reason} onChange={(event) => setReason(event.target.value)} />
          </label>
          <Button type="button" variant="outline" onClick={() => run.mutate(() => reportStockDiscrepancy(line.id, reason))}>
            Report discrepancy
          </Button>
        </div>
      ) : null}
      {actions.canReview && line.counted_cases !== null && !line.recount_requested && (needsRecount === false) && (variance !== 0 || movementsPending) ? (
        <Button
          type="button"
          onClick={() =>
            run.mutate(() => reviewVerificationDiscrepancy(line.id, reason, line.movement_ids))
          }
        >
          Review discrepancy
        </Button>
      ) : null}
      {actions.canReviewInactive && inactive && !line.inactive_reviewed_at ? (
        <div className="flex flex-wrap items-end gap-2">
          <label className="grid min-w-0 flex-1 gap-1">
            Inactive review reason
            <Input
              aria-label={`Inactive review ${line.sku}`}
              value={inactiveReason}
              onChange={(event) => setInactiveReason(event.target.value)}
            />
          </label>
          <Button
            type="button"
            variant="outline"
            onClick={() =>
              run.mutate(() => reviewVerificationInactiveObject("line", line.id, inactiveReason))
            }
          >
            Review inactive item
          </Button>
        </div>
      ) : null}
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
    </article>
  )
}

function FoundProduct({
  detail,
  actions,
  onSaved,
}: {
  detail: VerificationDetail
  actions: ReturnType<typeof verificationActions>
  onSaved: () => Promise<void>
}) {
  const [crateId, setCrateId] = useState(detail.scopes[0]?.crate_id ?? "")
  const [productId, setProductId] = useState("")
  const [error, setError] = useState<string | null>(null)
  const add = useMutation({
    mutationFn: () =>
      addVerificationFoundProduct({
        target_verification: detail.verification.id,
        target_crate: crateId,
        target_product: productId,
      }),
    onSuccess: async () => {
      setError(null)
      notify.success("Found product added with zero expected cases.")
      await onSaved()
    },
    onError: (caught) => setError(verificationErrorMessage(caught)),
  })
  if (!actions.canSaveCount || detail.verification.status === "closed") return null
  return (
    <form
      className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200"
      onSubmit={(event) => {
        event.preventDefault()
        add.mutate()
      }}
    >
      <h2 className="font-medium">Physically found product</h2>
      <div className="grid gap-3 md:grid-cols-2">
        <label className="grid gap-1">
          Crate
          <select
            aria-label="Found product crate"
            className="h-10 rounded-lg border border-input bg-transparent px-2.5"
            value={crateId}
            onChange={(event) => setCrateId(event.target.value)}
          >
            {detail.scopes.map((scope) => (
              <option key={scope.crate_id} value={scope.crate_id}>
                {scope.crate_code}
              </option>
            ))}
          </select>
        </label>
        <label className="grid gap-1">
          Product
          <select
            aria-label="Found product"
            className="h-10 rounded-lg border border-input bg-transparent px-2.5"
            value={productId}
            onChange={(event) => setProductId(event.target.value)}
          >
            <option value="">Select a product</option>
            {detail.products.map((product) => (
              <option key={product.id} value={product.id}>
                {product.sku} · {product.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
      <Button type="submit" disabled={!crateId || !productId || add.isPending}>
        Add product
      </Button>
    </form>
  )
}

function Evidence({
  detail,
  actions,
  onSaved,
}: {
  detail: VerificationDetail
  actions: ReturnType<typeof verificationActions>
  onSaved: () => Promise<void>
}) {
  const [note, setNote] = useState("")
  const [photo, setPhoto] = useState<PhotoUploadState>({ status: "idle", message: null })
  const [preview, setPreview] = useState<string | null>(null)
  const ready = evidenceSatisfiesClosure(
    detail.evidence.map((item) => ({ verifiedAt: item.verified_at })),
  )
  const upload = useMutation({
    mutationFn: (file: File) => uploadVerificationPhoto(detail.verification.id, file, note),
    onSuccess: async () => {
      setPhoto(photoUploadTransition(photo, { type: "finish" }))
      notify.success("Photo attached.")
      await onSaved()
    },
    onError: (caught) =>
      setPhoto(photoUploadTransition(photo, { type: "fail", message: verificationErrorMessage(caught) })),
  })

  return (
    <section className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <h2 className="font-medium">Photo evidence</h2>
      <p>{ready ? "A verified photo is attached." : "At least one verified photo is required before closure."}</p>
      {actions.canUpload ? (
        <div className="grid gap-2">
          <label className="grid gap-1">
            Note
            <Input aria-label="Photo note" value={note} onChange={(event) => setNote(event.target.value)} />
          </label>
          <input
            aria-label="Verification photo"
            type="file"
            accept="image/jpeg,image/png,image/webp"
            onChange={(event) => {
              const file = event.target.files?.[0]
              if (!file) return
              if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 10_485_760) {
                setPhoto(
                  photoUploadTransition(photo, {
                    type: "invalid",
                    message: "Choose a JPEG, PNG, or WebP image up to 10 MB.",
                  }),
                )
                return
              }
              setPhoto(photoUploadTransition(photo, { type: "start" }))
              upload.mutate(file)
            }}
          />
          {photo.status === "uploading" ? <p>Uploading photo</p> : null}
          {photo.message ? (
            <p role="alert" className="text-destructive">
              {photo.message}
            </p>
          ) : null}
        </div>
      ) : null}
      <ul className="grid gap-2">
        {detail.evidence.map((item) => (
          <li key={item.id} className="flex flex-wrap items-center justify-between gap-2">
            <span>
              {item.verified_at ? "Verified" : "Not finalized"} · {item.uploaded_by_name ?? "Unknown"} ·{" "}
              {item.uploaded_at}
              {item.note ? ` · ${item.note}` : ""}
            </span>
            {item.verified_at ? (
              <Button
                type="button"
                variant="outline"
                onClick={() =>
                  verificationPhotoPreview(item.id)
                    .then(setPreview)
                    .catch((caught: unknown) =>
                      setPhoto(
                        photoUploadTransition(photo, {
                          type: "fail",
                          message: verificationErrorMessage(caught),
                        }),
                      ),
                    )
                }
              >
                Preview
              </Button>
            ) : null}
          </li>
        ))}
      </ul>
      {preview ? <img alt="Verification evidence" className="max-h-64 rounded-lg" src={preview} /> : null}
    </section>
  )
}

function ClosurePanel({
  detail,
  actions,
  onSaved,
}: {
  detail: VerificationDetail
  actions: ReturnType<typeof verificationActions>
  onSaved: () => Promise<void>
}) {
  const [open, setOpen] = useState(false)
  const [note, setNote] = useState("")
  const [result, setResult] = useState<ClosureResult>(
    suggestedClosureResult(detail.closure.shortages + detail.closure.overages),
  )
  const [error, setError] = useState<string | null>(null)
  const allowed = canCloseVerification({
    canVerify: actions.canClose,
    status: detail.verification.status,
    blockers: detail.closure.blockers,
  })
  const close = useMutation({
    mutationFn: () => closeStockVerification(detail.verification.id, result, note),
    onSuccess: async () => {
      setOpen(false)
      notify.success("Verification closed. Inventory balances were not changed.")
      await onSaved()
    },
    onError: (caught) => setError(verificationErrorMessage(caught)),
  })
  const inactiveScopes = detail.scopes.filter(
    (scope) => (!scope.crate_active || !scope.zone_active) && !scope.inactive_reviewed_at,
  )

  return (
    <section className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <h2 className="font-medium">Closure</h2>
      {detail.verification.status === "counting" && actions.canSubmit ? (
        <SubmitButton id={detail.verification.id} onSaved={onSaved} />
      ) : null}
      {actions.canReviewInactive
        ? inactiveScopes.map((scope) => (
            <InactiveScope key={scope.id} scopeId={scope.id} label={scope.crate_code} onSaved={onSaved} />
          ))
        : null}
      {detail.closure.blockers.length > 0 && detail.verification.status !== "closed" ? (
        <ul>
          {detail.closure.blockers.map((blocker) => (
            <li key={blocker}>{blocker}</li>
          ))}
        </ul>
      ) : null}
      {actions.canClose ? (
        <Button type="button" disabled={!allowed} onClick={() => setOpen(true)}>
          Close verification
        </Button>
      ) : null}
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
      <AppModal
        open={open}
        onOpenChange={setOpen}
        title="Close verification"
        description={closeCopy}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Keep open
            </Button>
            <Button type="button" disabled={close.isPending || note.trim().length === 0} onClick={() => close.mutate()}>
              Close verification
            </Button>
          </>
        }
      >
        <div className="grid gap-3">
          <label className="grid gap-1 text-sm">
            Result
            <select
              aria-label="Closure result"
              className="h-10 rounded-lg border border-input bg-transparent px-2.5"
              value={result}
              onChange={(event) => setResult(event.target.value as ClosureResult)}
            >
              <option value="matched">Matched</option>
              <option value="variance_recorded">Variance recorded</option>
              <option value="correction_requested">Correction requested</option>
            </select>
          </label>
          <label className="grid gap-1 text-sm">
            Closure note
            <textarea
              aria-label="Closure note"
              className="min-h-24 rounded-lg border border-input px-2.5 py-2"
              value={note}
              onChange={(event) => setNote(event.target.value)}
            />
          </label>
        </div>
      </AppModal>
    </section>
  )
}

function SubmitButton({ id, onSaved }: { id: string; onSaved: () => Promise<void> }) {
  const [error, setError] = useState<string | null>(null)
  const submit = useMutation({
    mutationFn: () => submitStockVerification(id),
    onSuccess: async () => {
      notify.success("Verification submitted.")
      await onSaved()
    },
    onError: (caught) => setError(verificationErrorMessage(caught)),
  })
  return (
    <div className="grid gap-2">
      <Button type="button" onClick={() => submit.mutate()} disabled={submit.isPending}>
        Submit counts
      </Button>
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
    </div>
  )
}

function InactiveScope({
  scopeId,
  label,
  onSaved,
}: {
  scopeId: string
  label: string
  onSaved: () => Promise<void>
}) {
  const [reason, setReason] = useState("")
  const [error, setError] = useState<string | null>(null)
  const review = useMutation({
    mutationFn: () => reviewVerificationInactiveObject("scope", scopeId, reason),
    onSuccess: onSaved,
    onError: (caught) => setError(verificationErrorMessage(caught)),
  })
  return (
    <div className="grid gap-2">
      <p>{label} is inactive and needs a manager review.</p>
      <Input aria-label={`Review ${label}`} value={reason} onChange={(event) => setReason(event.target.value)} />
      <Button type="button" variant="outline" onClick={() => review.mutate()}>
        Review inactive crate
      </Button>
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
    </div>
  )
}

function History({ detail }: { detail: VerificationDetail }) {
  return (
    <section className="grid gap-2 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <h2 className="font-medium">History</h2>
      {detail.counts.map((count) => (
        <p key={count.id}>
          {count.count_kind} count {count.counted_cases} by {count.counted_by_name ?? "Unknown"} at{" "}
          {count.counted_at}
        </p>
      ))}
      {detail.history.map((event, index) => (
        <p key={`${event.action}-${event.occurred_at}-${index}`}>
          {event.action.replaceAll("_", " ")} by {event.actor_name ?? "Unknown"} at {event.occurred_at}
        </p>
      ))}
    </section>
  )
}
