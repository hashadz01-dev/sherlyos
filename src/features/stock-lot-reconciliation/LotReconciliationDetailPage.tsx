import { useMemo, useRef, useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import {
  addLotReconciliationFoundProduct,
  applyLegacyLotAttribution,
  approveLotReconciliation,
  cancelLotReconciliation,
  getLotAttributionReadiness,
  getLotReconciliation,
  lotReconciliationKeys,
  refreshLotReconciliationExpected,
  rejectLotReconciliation,
  reopenLotReconciliation,
  saveLotReconciliationCount,
  saveLotReconciliationLots,
  submitLotReconciliation,
  type LotReconciliationDetail,
  type LotReconciliationLine,
} from "@/lib/lot-reconciliation/api"
import {
  actorLabel,
  canSubmitFromSummary,
  countStateLabel,
  emptyLotDraft,
  eventLabel,
  formatTimestamp,
  isStaleVersionError,
  lineCountState,
  lineVariance,
  lotBreakdownState,
  lotDraftFromServer,
  lotEntryIssues,
  lotQuantitySum,
  lotReconciliationActions,
  lotStateLabel,
  lotsToRpc,
  newIdempotencyKey,
  reconciliationErrorMessage,
  statusTone,
  submitSummary,
  unknownIdentityDraft,
  type LotCondition,
  type LotEvidenceDraft,
} from "@/lib/lot-reconciliation/rules"
import { parseCaseCount } from "@/lib/verification/rules"
import { notify } from "@/lib/utilities/notify"

const refreshWarning =
  "Refreshing the expected stock snapshot will remove all existing counts and lot evidence for this session."

const cancelWarning =
  "Cancelling this session releases the reserved crate scope. Another reconciliation may then use these crates."

const applyWarning =
  "This splits eligible legacy-unattributed stock into verified physical lots. Aggregate carton quantities and historical ledger rows are not changed. Unknown identity stays unattributed. This cannot be undone from the application."

export function LotReconciliationDetailPage() {
  const { sessionId = "" } = useParams()
  const { can } = useAccess()
  const { session } = useAuth()
  const queryClient = useQueryClient()
  const locations = useStockLocations()
  const [stale, setStale] = useState(false)
  const [crateFilter, setCrateFilter] = useState("all")
  const detail = useQuery({
    queryKey: lotReconciliationKeys.detail(sessionId),
    enabled: Boolean(sessionId),
    queryFn: () => getLotReconciliation(sessionId),
  })
  useDocumentTitle(detail.data?.session_number ?? "Lot reconciliation")

  async function refresh(nextStale = false) {
    setStale(nextStale)
    await queryClient.invalidateQueries({ queryKey: lotReconciliationKeys.detail(sessionId) })
    await queryClient.invalidateQueries({ queryKey: lotReconciliationKeys.attribution(sessionId) })
    await queryClient.invalidateQueries({ queryKey: lotReconciliationKeys.list })
  }

  function onMutationError(error: unknown) {
    const message = reconciliationErrorMessage(error)
    notify.error(message)
    if (isStaleVersionError(error)) {
      void refresh(true)
    }
  }

  const header = detail.data
  const actions = header
    ? lotReconciliationActions({
        status: header.status,
        isSubmitter: header.submitted_by === session?.user.id,
        canPhysical: can("stock.lots.physical_reconcile"),
        canAdmin: can("stock.lots.legacy.reconcile"),
      })
    : null
  const godownName =
    locations.branches.data?.find((branch) => branch.id === header?.godown_id)?.name ?? header?.godown_id

  return (
    <section>
      <PageHeader
        title={header?.session_number ?? "Lot reconciliation"}
        description="Physical counts and lot evidence stay on this session. Approval does not change inventory or create lots."
        action={
          <Button variant="outline" asChild>
            <Link to="/stock-lot-reconciliation">Back</Link>
          </Button>
        }
      />
      {detail.isLoading ? <LoadingBlock label="Loading lot reconciliation" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {stale ? (
        <p role="alert" className="mb-4 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200">
          This session was changed by someone else. Review the latest counts before saving again. Your previous
          unsaved edit was not replayed.
        </p>
      ) : null}
      {header && actions ? (
        <div className="grid gap-6">
          <Summary header={header} godownName={godownName ?? header.godown_id} currentUserId={session?.user.id} />
          <CrateFilter crates={header.crates} value={crateFilter} onChange={setCrateFilter} />
          <Lines
            detail={header}
            crateFilter={crateFilter}
            actions={actions}
            onSaved={() => refresh(false)}
            onMutationError={onMutationError}
          />
          <FoundProduct
            detail={header}
            actions={actions}
            onSaved={() => refresh(false)}
            onMutationError={onMutationError}
          />
          <SubmitPanel
            detail={header}
            actions={actions}
            onSaved={() => refresh(false)}
            onMutationError={onMutationError}
          />
          <AdminReview
            detail={header}
            actions={actions}
            onSaved={() => refresh(false)}
            onMutationError={onMutationError}
          />
          <AttributionPanel
            detail={header}
            actions={actions}
            canAdmin={can("stock.lots.legacy.reconcile")}
            onSaved={() => refresh(false)}
            onMutationError={onMutationError}
          />
          <ReopenCancel
            detail={header}
            actions={actions}
            onSaved={() => refresh(false)}
            onMutationError={onMutationError}
          />
          <History detail={header} currentUserId={session?.user.id} />
        </div>
      ) : null}
    </section>
  )
}

function Summary({
  header,
  godownName,
  currentUserId,
}: {
  header: LotReconciliationDetail
  godownName: string
  currentUserId?: string
}) {
  const discrepancy = header.discrepancy
  return (
    <div className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200 md:grid-cols-2">
      <p>
        Status <StatusBadge tone={statusTone[header.status]}>{header.status}</StatusBadge>
      </p>
      <p>Godown {godownName}</p>
      <p>Crates {header.crates.map((crate) => crate.crate_code).join(", ") || "None"}</p>
      <p>Expected frozen {formatTimestamp(header.expected_frozen_at)}</p>
      <p>Created by {actorLabel(header.created_by, currentUserId)} at {formatTimestamp(header.created_at)}</p>
      <p>Updated {formatTimestamp(header.updated_at)}</p>
      <p>Submitted by {actorLabel(header.submitted_by, currentUserId)} at {formatTimestamp(header.submitted_at)}</p>
      <p>Reviewed by {actorLabel(header.reviewed_by, currentUserId)} at {formatTimestamp(header.reviewed_at)}</p>
      {header.notes ? <p className="md:col-span-2">Notes {header.notes}</p> : null}
      {header.rejection_reason ? (
        <p className="md:col-span-2 text-destructive">Rejection {header.rejection_reason}</p>
      ) : null}
      {header.review_notes ? <p className="md:col-span-2">Review notes {header.review_notes}</p> : null}
      {header.cancellation_reason ? (
        <p className="md:col-span-2">Cancellation {header.cancellation_reason}</p>
      ) : null}
      {header.applied_at ? (
        <p className="md:col-span-2">
          Attributed by {actorLabel(header.applied_by, currentUserId)} at {formatTimestamp(header.applied_at)}
        </p>
      ) : null}
      <p>Uncounted {discrepancy.uncounted_lines}</p>
      <p>Unmatched {discrepancy.unmatched_lines}</p>
      <p>Unexpected products {discrepancy.found_product_lines}</p>
      <p>Unknown-identity cases {discrepancy.unidentified_cases}</p>
      {discrepancy.unclassified_products > 0 ? (
        <p className="md:col-span-2 text-amber-900">
          {discrepancy.unclassified_products} unclassified products can be counted but cannot be approved until
          expiry policy is set.
        </p>
      ) : null}
      {header.status === "approved" ? (
        <p className="md:col-span-2 rounded-xl bg-emerald-50 px-3 py-2 text-emerald-950">
          This session is approved and locked. Physical counts cannot change. Admin attribution is a separate
          cutover step.
        </p>
      ) : null}
      {header.status === "applied" ? (
        <p className="md:col-span-2 rounded-xl bg-emerald-50 px-3 py-2 text-emerald-950">
          Legacy lots were attributed from this approved evidence. Aggregate stock was not changed.
        </p>
      ) : null}
    </div>
  )
}

function CrateFilter({
  crates,
  value,
  onChange,
}: {
  crates: LotReconciliationDetail["crates"]
  value: string
  onChange: (value: string) => void
}) {
  return (
    <label className="grid max-w-sm gap-2 text-sm font-medium">
      Crate
      <select
        aria-label="Crate filter"
        className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
        value={value}
        onChange={(event) => onChange(event.target.value)}
      >
        <option value="all">All selected crates</option>
        {crates.map((crate) => (
          <option key={crate.crate_id} value={crate.crate_id}>
            {crate.zone_code} · {crate.crate_code}
            {crate.crate_name ? ` · ${crate.crate_name}` : ""}
          </option>
        ))}
      </select>
    </label>
  )
}

function Lines({
  detail,
  crateFilter,
  actions,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  crateFilter: string
  actions: ReturnType<typeof lotReconciliationActions>
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const crates = crateFilter === "all" ? detail.crates : detail.crates.filter((crate) => crate.crate_id === crateFilter)
  return (
    <div className="grid gap-5">
      {crates.map((crate) => {
        const lines = detail.lines.filter((line) => line.crate_id === crate.crate_id)
        return (
          <section key={crate.crate_id} className="grid gap-3">
            <h2 className="text-base font-semibold">
              {crate.zone_code} · {crate.crate_code}
              {crate.crate_name ? ` · ${crate.crate_name}` : ""}
            </h2>
            {lines.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                No expected stock in this crate. Record an unexpected product if one is physically present.
              </p>
            ) : (
              lines.map((line) => (
                <LineCard
                  key={`${line.id}-${line.counted_at ?? "none"}-${line.lots.map((lot) => lot.id).join(",")}`}
                  detail={detail}
                  line={line}
                  crateLabel={`${crate.crate_code}`}
                  actions={actions}
                  onSaved={onSaved}
                  onMutationError={onMutationError}
                />
              ))
            )}
          </section>
        )
      })}
    </div>
  )
}

function LineCard({
  detail,
  line,
  crateLabel,
  actions,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  line: LotReconciliationLine
  crateLabel: string
  actions: ReturnType<typeof lotReconciliationActions>
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const [count, setCount] = useState(line.counted_quantity === null ? "" : String(line.counted_quantity))
  const [error, setError] = useState<string | null>(null)
  const countState = lineCountState(line.expected_quantity, line.counted_quantity)
  const lotState = lotBreakdownState(line.counted_quantity, line.lots)
  const variance = lineVariance(line.expected_quantity, line.counted_quantity)
  const saveCount = useMutation({
    mutationFn: async (cases: number) =>
      saveLotReconciliationCount({
        target_session: detail.id,
        expected_version: detail.version,
        target_crate: line.crate_id,
        target_product: line.product_id,
        counted_quantity: cases,
      }),
    onSuccess: async () => {
      setError(null)
      notify.success("Count saved.")
      await onSaved()
    },
    onError: (caught) => {
      setError(reconciliationErrorMessage(caught))
      onMutationError(caught)
    },
  })

  return (
    <article
      className={`grid gap-3 rounded-2xl p-4 text-sm ring-1 ${
        line.is_found_product
          ? "bg-amber-50 ring-amber-200"
          : countState === "matched"
            ? "bg-white ring-slate-200"
            : countState === "not_counted"
              ? "bg-white ring-slate-200"
              : "bg-white ring-amber-200"
      }`}
    >
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-medium">
          {line.sku} {line.product_name}
        </h3>
        <div className="flex flex-wrap gap-2">
          {line.is_found_product ? <StatusBadge tone="warning">Unexpected stock</StatusBadge> : null}
          <StatusBadge tone={countState === "matched" ? "success" : countState === "not_counted" ? "neutral" : "warning"}>
            {countStateLabel(countState)}
          </StatusBadge>
          <StatusBadge tone={lotState === "complete" ? "success" : lotState === "waiting" ? "neutral" : "warning"}>
            {lotStateLabel(lotState)}
          </StatusBadge>
        </div>
      </header>
      <div className="grid gap-1 sm:grid-cols-2">
        <p>Crate {crateLabel}</p>
        <p>Policy {line.expiry_policy ?? "unclassified"}</p>
        <p>Expected carton cases {line.expected_quantity}</p>
        <p>Counted carton cases {line.counted_quantity ?? "Not counted"}</p>
        <p>Difference {variance === null ? "Waiting" : variance}</p>
      </div>
      {line.is_found_product ? (
        <p>
          This product was physically found and is not in the expected snapshot. It is a discrepancy only and does
          not add stock, post an adjustment, or create a lot.
        </p>
      ) : null}
      {line.expiry_policy !== "expiry_controlled" && line.expiry_policy !== "non_expiring" ? (
        <p className="text-amber-900">Unclassified products can be counted. Approval is blocked until classification.</p>
      ) : null}
      {actions.saveCount ? (
        <div className="flex flex-wrap items-end gap-2">
          <label className="grid gap-1">
            Actual carton cases
            <Input
              aria-label={`Count ${line.sku}`}
              inputMode="numeric"
              value={count}
              onChange={(event) => setCount(event.target.value)}
            />
          </label>
          <Button
            type="button"
            disabled={saveCount.isPending}
            onClick={() => {
              const parsed = parseCaseCount(count)
              if (!parsed.ok) {
                setError(parsed.message)
                return
              }
              saveCount.mutate(parsed.cases)
            }}
          >
            {saveCount.isPending ? "Saving count" : "Save count"}
          </Button>
        </div>
      ) : null}
      <LotEditor
        detail={detail}
        line={line}
        canEdit={actions.saveLots}
        onSaved={onSaved}
        onMutationError={onMutationError}
      />
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
    </article>
  )
}

function LotEditor({
  detail,
  line,
  canEdit,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  line: LotReconciliationLine
  canEdit: boolean
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const [entries, setEntries] = useState<LotEvidenceDraft[]>(() =>
    line.lots.length > 0 ? line.lots.map(lotDraftFromServer) : [],
  )
  const [error, setError] = useState<string | null>(null)
  const counted = line.counted_quantity
  const sum = lotQuantitySum(lotsToRpc(entries).map((lot) => ({ quantity: lot.quantity })))
  const saveLots = useMutation({
    mutationFn: () =>
      saveLotReconciliationLots({
        target_session: detail.id,
        expected_version: detail.version,
        target_line: line.id,
        lots: lotsToRpc(entries),
      }),
    onSuccess: async () => {
      setError(null)
      notify.success("Lot evidence saved.")
      await onSaved()
    },
    onError: (caught) => {
      setError(reconciliationErrorMessage(caught))
      onMutationError(caught)
    },
  })

  if (counted === null) {
    return <p className="text-muted-foreground">Count this product before recording lot evidence.</p>
  }

  return (
    <div className="grid gap-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h4 className="font-medium">Physical lot evidence</h4>
        <p>
          Breakdown {sum} / {counted} carton cases
        </p>
      </div>
      {entries.map((entry, index) => (
        <LotFields
          key={`${line.id}-${index}`}
          entry={entry}
          policy={line.expiry_policy}
          canEdit={canEdit}
          sku={line.sku}
          index={index}
          onChange={(next) =>
            setEntries((current) => current.map((item, itemIndex) => (itemIndex === index ? next : item)))
          }
          onRemove={() => setEntries((current) => current.filter((_, itemIndex) => itemIndex !== index))}
        />
      ))}
      {canEdit ? (
        <div className="flex flex-wrap gap-2">
          <Button type="button" variant="outline" onClick={() => setEntries((current) => [...current, emptyLotDraft()])}>
            Add lot
          </Button>
          <Button
            type="button"
            variant="outline"
            onClick={() =>
              setEntries((current) => [...current, unknownIdentityDraft(counted > 0 ? String(counted) : "1")])
            }
          >
            Add unknown / legacy unattributed
          </Button>
          <Button
            type="button"
            disabled={saveLots.isPending}
            onClick={() => {
              if (counted === 0 && entries.length > 0) {
                setError("Zero-count lines cannot hold lot entries.")
                return
              }
              const issues = entries.flatMap((entry) => lotEntryIssues(entry, line.expiry_policy))
              if (counted > 0 && (entries.length === 0 || sum !== counted)) {
                issues.push("Lot carton quantities must equal the counted cases.")
              }
              if (issues.length > 0) {
                setError(issues[0] ?? "Lot evidence is invalid.")
                return
              }
              saveLots.mutate()
            }}
          >
            {saveLots.isPending ? "Saving lots" : "Save lots"}
          </Button>
        </div>
      ) : null}
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
    </div>
  )
}

function LotFields({
  entry,
  policy,
  canEdit,
  sku,
  index,
  onChange,
  onRemove,
}: {
  entry: LotEvidenceDraft
  policy: LotReconciliationLine["expiry_policy"]
  canEdit: boolean
  sku: string
  index: number
  onChange: (next: LotEvidenceDraft) => void
  onRemove: () => void
}) {
  const issues = lotEntryIssues(entry, policy)
  const unknown = entry.identity_unknown
  const hideExpiry = policy === "non_expiring" && !unknown
  return (
    <fieldset className="grid gap-3 rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200 md:grid-cols-2">
      <legend className="px-1 text-sm font-medium">
        {unknown ? "Unknown / Legacy unattributed" : `Lot ${index + 1}`}
      </legend>
      <label className="flex items-center gap-2 text-sm md:col-span-2">
        <input
          type="checkbox"
          aria-label={`Unknown identity ${sku} ${index + 1}`}
          checked={unknown}
          disabled={!canEdit}
          onChange={(event) =>
            onChange({
              ...entry,
              identity_unknown: event.target.checked,
              manufacturer_lot_code: event.target.checked ? "" : entry.manufacturer_lot_code,
              expiry_date: event.target.checked ? "" : entry.expiry_date,
              expiry_unknown: event.target.checked ? true : entry.expiry_unknown,
            })
          }
        />
        Identity unknown (do not invent a batch code)
      </label>
      <label className="grid gap-1 text-sm">
        Manufacturer lot
        <Input
          aria-label={`Manufacturer lot ${sku} ${index + 1}`}
          value={entry.manufacturer_lot_code}
          disabled={!canEdit || unknown}
          onChange={(event) => onChange({ ...entry, manufacturer_lot_code: event.target.value })}
        />
      </label>
      <label className="grid gap-1 text-sm">
        Carton quantity
        <Input
          aria-label={`Lot quantity ${sku} ${index + 1}`}
          inputMode="numeric"
          value={entry.quantity}
          disabled={!canEdit}
          onChange={(event) => onChange({ ...entry, quantity: event.target.value })}
        />
      </label>
      {hideExpiry ? (
        <p className="text-muted-foreground md:col-span-2">Non-expiring products do not carry expiry values.</p>
      ) : (
        <>
          <label className="grid gap-1 text-sm">
            Expiry date
            <Input
              type="date"
              aria-label={`Expiry ${sku} ${index + 1}`}
              value={entry.expiry_date}
              disabled={!canEdit || unknown || entry.expiry_unknown}
              onChange={(event) => onChange({ ...entry, expiry_date: event.target.value })}
            />
          </label>
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              aria-label={`Expiry unknown ${sku} ${index + 1}`}
              checked={entry.expiry_unknown}
              disabled={!canEdit || unknown}
              onChange={(event) =>
                onChange({
                  ...entry,
                  expiry_unknown: event.target.checked,
                  expiry_date: event.target.checked ? "" : entry.expiry_date,
                })
              }
            />
            Expiry unknown
          </label>
        </>
      )}
      <label className="grid gap-1 text-sm">
        Condition
        <select
          aria-label={`Condition ${sku} ${index + 1}`}
          className="h-10 rounded-lg border border-input bg-transparent px-2.5"
          value={entry.condition}
          disabled={!canEdit}
          onChange={(event) => onChange({ ...entry, condition: event.target.value as LotCondition })}
        >
          <option value="available">Available</option>
          <option value="quarantined">Quarantined</option>
          <option value="expired">Expired</option>
        </select>
      </label>
      {canEdit ? (
        <Button type="button" variant="outline" onClick={onRemove}>
          Remove lot
        </Button>
      ) : null}
      {issues.length > 0 ? (
        <ul className="text-destructive md:col-span-2">
          {issues.map((issue) => (
            <li key={issue}>{issue}</li>
          ))}
        </ul>
      ) : null}
    </fieldset>
  )
}

function FoundProduct({
  detail,
  actions,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  actions: ReturnType<typeof lotReconciliationActions>
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const locations = useStockLocations()
  const [crateId, setCrateId] = useState(detail.crates[0]?.crate_id ?? "")
  const [productId, setProductId] = useState("")
  const add = useMutation({
    mutationFn: () =>
      addLotReconciliationFoundProduct({
        target_session: detail.id,
        expected_version: detail.version,
        target_crate: crateId,
        target_product: productId,
      }),
    onSuccess: async () => {
      notify.success("Unexpected product recorded as a discrepancy.")
      setProductId("")
      await onSaved()
    },
    onError: onMutationError,
  })
  if (!actions.foundProduct) return null
  const products = (locations.products.data ?? []).filter((product) => product.is_active)
  return (
    <form
      className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200"
      onSubmit={(event) => {
        event.preventDefault()
        add.mutate()
      }}
    >
      <h2 className="font-medium">Unexpected physical product</h2>
      <p>
        Record a product that is physically present but absent from the expected snapshot. It remains a discrepancy
        until inventory is corrected through the existing adjustment path.
      </p>
      <div className="grid gap-3 md:grid-cols-2">
        <label className="grid gap-1">
          Crate
          <select
            aria-label="Unexpected product crate"
            className="h-10 rounded-lg border border-input bg-transparent px-2.5"
            value={crateId}
            onChange={(event) => setCrateId(event.target.value)}
          >
            {detail.crates.map((crate) => (
              <option key={crate.crate_id} value={crate.crate_id}>
                {crate.crate_code}
              </option>
            ))}
          </select>
        </label>
        <label className="grid gap-1">
          Product
          <select
            aria-label="Unexpected product"
            className="h-10 rounded-lg border border-input bg-transparent px-2.5"
            value={productId}
            onChange={(event) => setProductId(event.target.value)}
          >
            <option value="">Select a product</option>
            {products.map((product) => (
              <option key={product.id} value={product.id}>
                {product.sku} · {product.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      {add.error ? (
        <p role="alert" className="text-destructive">
          {reconciliationErrorMessage(add.error)}
        </p>
      ) : null}
      <Button type="submit" disabled={!crateId || !productId || add.isPending}>
        Record unexpected product
      </Button>
    </form>
  )
}

function SubmitPanel({
  detail,
  actions,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  actions: ReturnType<typeof lotReconciliationActions>
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const [refreshOpen, setRefreshOpen] = useState(false)
  const submitKey = useRef<string | null>(null)
  const summary = useMemo(() => submitSummary(detail.lines), [detail.lines])
  const ready = canSubmitFromSummary(summary)
  const refresh = useMutation({
    mutationFn: () =>
      refreshLotReconciliationExpected({
        target_session: detail.id,
        expected_version: detail.version,
      }),
    onSuccess: async () => {
      setRefreshOpen(false)
      notify.success("Expected stock refreshed. Counts and lot evidence were cleared.")
      await onSaved()
    },
    onError: onMutationError,
  })
  const submit = useMutation({
    mutationFn: () => {
      if (!submitKey.current) submitKey.current = newIdempotencyKey("lr-submit")
      return submitLotReconciliation({
        target_session: detail.id,
        expected_version: detail.version,
        idempotency_key: submitKey.current,
      })
    },
    onSuccess: async () => {
      submitKey.current = null
      notify.success("Reconciliation submitted.")
      await onSaved()
    },
    onError: (error) => {
      if (isStaleVersionError(error)) submitKey.current = null
      onMutationError(error)
    },
  })

  if (!actions.submit && !actions.refresh) return null

  return (
    <section className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <h2 className="font-medium">Submission</h2>
      <ul className="grid gap-1 sm:grid-cols-2">
        <li>Total lines {summary.totalLines}</li>
        <li>Counted lines {summary.countedLines}</li>
        <li>Missing counts {summary.missingCounts}</li>
        <li>Lot breakdown mismatches {summary.lotMismatches}</li>
        <li>Physical versus expected differences {summary.unmatchedLines}</li>
        <li>Unclassified products {summary.unclassifiedProducts}</li>
        <li>Unexpected products {summary.foundProductLines}</li>
      </ul>
      {summary.unmatchedLines > 0 || summary.foundProductLines > 0 ? (
        <p>
          Quantity differences and unexpected stock remain discrepancies. Submission is allowed when counts and lot
          totals are complete. Approval still requires a full-session quantity match.
        </p>
      ) : null}
      {actions.refresh ? (
        <Button type="button" variant="outline" onClick={() => setRefreshOpen(true)}>
          Refresh expected stock
        </Button>
      ) : null}
      {actions.submit ? (
        <Button type="button" disabled={!ready || submit.isPending} onClick={() => submit.mutate()}>
          {submit.isPending ? "Submitting" : "Submit counts"}
        </Button>
      ) : null}
      {submit.error ? (
        <p role="alert" className="text-destructive">
          {reconciliationErrorMessage(submit.error)}
        </p>
      ) : null}
      <AppModal
        open={refreshOpen}
        onOpenChange={setRefreshOpen}
        title="Refresh expected stock?"
        description={refreshWarning}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setRefreshOpen(false)}>
              Keep current snapshot
            </Button>
            <Button type="button" disabled={refresh.isPending} onClick={() => refresh.mutate()}>
              Refresh and clear counts
            </Button>
          </>
        }
      />
    </section>
  )
}

function AdminReview({
  detail,
  actions,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  actions: ReturnType<typeof lotReconciliationActions>
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const [reviewNotes, setReviewNotes] = useState("")
  const [rejectReason, setRejectReason] = useState("")
  const approveKey = useRef<string | null>(null)
  const rejectKey = useRef<string | null>(null)
  const approve = useMutation({
    mutationFn: () => {
      if (!approveKey.current) approveKey.current = newIdempotencyKey("lr-approve")
      return approveLotReconciliation({
        target_session: detail.id,
        expected_version: detail.version,
        review_notes: reviewNotes.trim() || null,
        idempotency_key: approveKey.current,
      })
    },
    onSuccess: async () => {
      approveKey.current = null
      notify.success("Reconciliation approved. Inventory was not changed.")
      await onSaved()
    },
    onError: (error) => {
      if (isStaleVersionError(error)) approveKey.current = null
      onMutationError(error)
    },
  })
  const reject = useMutation({
    mutationFn: () => {
      if (!rejectKey.current) rejectKey.current = newIdempotencyKey("lr-reject")
      return rejectLotReconciliation({
        target_session: detail.id,
        expected_version: detail.version,
        reject_reason: rejectReason,
        idempotency_key: rejectKey.current,
      })
    },
    onSuccess: async () => {
      rejectKey.current = null
      notify.success("Reconciliation rejected.")
      await onSaved()
    },
    onError: (error) => {
      if (isStaleVersionError(error)) rejectKey.current = null
      onMutationError(error)
    },
  })

  if (detail.status !== "submitted" && !actions.approve && !actions.reject) return null
  if (!actions.approve && !actions.reject && detail.status !== "submitted") return null

  return (
    <section className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <h2 className="font-medium">Admin review</h2>
      <p>
        Unmatched lines {detail.discrepancy.unmatched_lines}. Unclassified products{" "}
        {detail.discrepancy.unclassified_products}. Unexpected products {detail.discrepancy.found_product_lines}.
      </p>
      {detail.discrepancy.unmatched_lines > 0 ? (
        <p>Unresolved quantity discrepancies block approval. There is no override.</p>
      ) : null}
      {detail.submitted_by ? <p>Submitter {actorLabel(detail.submitted_by, undefined)}</p> : null}
      {actions.approve || actions.reject ? (
        <label className="grid gap-1">
          Review notes
          <textarea
            aria-label="Review notes"
            className="min-h-20 rounded-lg border border-input px-2.5 py-2"
            value={reviewNotes}
            onChange={(event) => setReviewNotes(event.target.value)}
          />
        </label>
      ) : null}
      {actions.reject ? (
        <label className="grid gap-1">
          Rejection reason
          <textarea
            aria-label="Rejection reason"
            className="min-h-20 rounded-lg border border-input px-2.5 py-2"
            value={rejectReason}
            onChange={(event) => setRejectReason(event.target.value)}
          />
        </label>
      ) : null}
      <div className="flex flex-wrap gap-2">
        {actions.approve ? (
          <Button type="button" disabled={approve.isPending} onClick={() => approve.mutate()}>
            {approve.isPending ? "Approving" : "Approve"}
          </Button>
        ) : detail.status === "submitted" ? (
          <p>Approval is unavailable for this user. The backend also blocks self-approval.</p>
        ) : null}
        {actions.reject ? (
          <Button
            type="button"
            variant="outline"
            disabled={reject.isPending || rejectReason.trim().length === 0}
            onClick={() => reject.mutate()}
          >
            {reject.isPending ? "Rejecting" : "Reject"}
          </Button>
        ) : null}
      </div>
      {approve.error ? (
        <p role="alert" className="text-destructive">
          {reconciliationErrorMessage(approve.error)}
        </p>
      ) : null}
      {reject.error ? (
        <p role="alert" className="text-destructive">
          {reconciliationErrorMessage(reject.error)}
        </p>
      ) : null}
    </section>
  )
}

function AttributionPanel({
  detail,
  actions,
  canAdmin,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  actions: ReturnType<typeof lotReconciliationActions>
  canAdmin: boolean
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const [confirmOpen, setConfirmOpen] = useState(false)
  const applyKey = useRef<string | null>(null)
  const showPanel =
    canAdmin && (detail.status === "approved" || detail.status === "applied")
  const readiness = useQuery({
    queryKey: lotReconciliationKeys.attribution(detail.id),
    enabled: showPanel && detail.status === "approved",
    queryFn: () => getLotAttributionReadiness(detail.id),
  })
  const apply = useMutation({
    mutationFn: () => {
      if (!applyKey.current) applyKey.current = newIdempotencyKey("lr-apply")
      return applyLegacyLotAttribution({
        target_session: detail.id,
        expected_version: detail.version,
        idempotency_key: applyKey.current,
      })
    },
    onSuccess: async () => {
      applyKey.current = null
      setConfirmOpen(false)
      notify.success("Legacy lots were attributed. Aggregate stock was not changed.")
      await onSaved()
    },
    onError: (error) => {
      if (isStaleVersionError(error)) applyKey.current = null
      onMutationError(error)
    },
  })

  if (!showPanel) return null

  const eligible = Boolean(actions.apply && readiness.data?.eligible)
  const blockers = readiness.data?.blockers ?? []

  return (
    <section className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <h2 className="font-medium">Legacy lot attribution</h2>
      {detail.status === "applied" ? (
        <>
          <p>This approved session has been applied. Physical evidence stays immutable.</p>
          {detail.attributions.length > 0 ? (
            <ul className="grid gap-1">
              {detail.attributions.map((row) => (
                <li key={`${row.crate_id}-${row.product_id}`}>
                  Attributed {row.attributed_quantity} · unknown {row.unknown_quantity} · remaining
                  unattributed {row.remaining_unattributed}
                </li>
              ))}
            </ul>
          ) : null}
        </>
      ) : (
        <>
          {readiness.isLoading ? <p>Checking attribution eligibility.</p> : null}
          {readiness.error ? (
            <p role="alert" className="text-destructive">
              {reconciliationErrorMessage(readiness.error)}
            </p>
          ) : null}
          {readiness.data ? (
            <>
              <p>
                Known physical lots {readiness.data.known_quantity}. Unknown / unattributed remainder{" "}
                {readiness.data.unknown_quantity}.
              </p>
              {eligible ? (
                <p>Attribution is eligible. Aggregate stock and historical ledger rows will not change.</p>
              ) : (
                <div>
                  <p>Attribution is not eligible yet.</p>
                  <ul>
                    {blockers.map((reason) => (
                      <li key={reason}>{reason}</li>
                    ))}
                  </ul>
                </div>
              )}
            </>
          ) : null}
          <Button
            type="button"
            disabled={!eligible || apply.isPending || readiness.isFetching}
            onClick={() => setConfirmOpen(true)}
          >
            Apply attribution
          </Button>
        </>
      )}
      {apply.error ? (
        <p role="alert" className="text-destructive">
          {reconciliationErrorMessage(apply.error)}
        </p>
      ) : null}
      <AppModal
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        title="Apply legacy lot attribution?"
        description={applyWarning}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setConfirmOpen(false)}>
              Keep approved session
            </Button>
            <Button type="button" disabled={apply.isPending || !eligible} onClick={() => apply.mutate()}>
              {apply.isPending ? "Applying" : "Apply attribution"}
            </Button>
          </>
        }
      />
    </section>
  )
}

function ReopenCancel({
  detail,
  actions,
  onSaved,
  onMutationError,
}: {
  detail: LotReconciliationDetail
  actions: ReturnType<typeof lotReconciliationActions>
  onSaved: () => Promise<void>
  onMutationError: (error: unknown) => void
}) {
  const [cancelOpen, setCancelOpen] = useState(false)
  const [cancelReason, setCancelReason] = useState("")
  const reopenKey = useRef<string | null>(null)
  const cancelKey = useRef<string | null>(null)
  const reopen = useMutation({
    mutationFn: () => {
      if (!reopenKey.current) reopenKey.current = newIdempotencyKey("lr-reopen")
      return reopenLotReconciliation({
        target_session: detail.id,
        expected_version: detail.version,
        idempotency_key: reopenKey.current,
      })
    },
    onSuccess: async () => {
      reopenKey.current = null
      notify.success("Session reopened to draft.")
      await onSaved()
    },
    onError: (error) => {
      if (isStaleVersionError(error)) reopenKey.current = null
      onMutationError(error)
    },
  })
  const cancel = useMutation({
    mutationFn: () => {
      if (!cancelKey.current) cancelKey.current = newIdempotencyKey("lr-cancel")
      return cancelLotReconciliation({
        target_session: detail.id,
        expected_version: detail.version,
        cancel_reason: cancelReason,
        idempotency_key: cancelKey.current,
      })
    },
    onSuccess: async () => {
      cancelKey.current = null
      setCancelOpen(false)
      notify.success("Session cancelled. Crate scope was released.")
      await onSaved()
    },
    onError: (error) => {
      if (isStaleVersionError(error)) cancelKey.current = null
      onMutationError(error)
    },
  })

  if (!actions.reopen && !actions.cancel) return null

  return (
    <section className="grid gap-3 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      {actions.reopen ? (
        <Button type="button" disabled={reopen.isPending} onClick={() => reopen.mutate()}>
          {reopen.isPending ? "Reopening" : "Reopen rejected session"}
        </Button>
      ) : null}
      {actions.cancel ? (
        <Button type="button" variant="outline" onClick={() => setCancelOpen(true)}>
          Cancel session
        </Button>
      ) : null}
      {reopen.error ? (
        <p role="alert" className="text-destructive">
          {reconciliationErrorMessage(reopen.error)}
        </p>
      ) : null}
      <AppModal
        open={cancelOpen}
        onOpenChange={setCancelOpen}
        title="Cancel lot reconciliation?"
        description={cancelWarning}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setCancelOpen(false)}>
              Keep session
            </Button>
            <Button
              type="button"
              disabled={cancel.isPending || cancelReason.trim().length === 0}
              onClick={() => cancel.mutate()}
            >
              Cancel session
            </Button>
          </>
        }
      >
        <label className="grid gap-1 text-sm">
          Cancellation reason
          <textarea
            aria-label="Cancellation reason"
            className="min-h-20 rounded-lg border border-input px-2.5 py-2"
            value={cancelReason}
            onChange={(event) => setCancelReason(event.target.value)}
          />
        </label>
      </AppModal>
    </section>
  )
}

function History({
  detail,
  currentUserId,
}: {
  detail: LotReconciliationDetail
  currentUserId?: string
}) {
  return (
    <section className="grid gap-2 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <h2 className="font-medium">Audit history</h2>
      {detail.events.length === 0 ? <p>No events yet.</p> : null}
      <ol className="grid gap-2">
        {detail.events.map((event) => (
          <li key={event.id}>
            <p>
              {eventLabel(event.event_type)} by {actorLabel(event.actor_id, currentUserId)} at{" "}
              {formatTimestamp(event.created_at)}
            </p>
            <p className="text-muted-foreground">
              {event.from_status ?? "none"} → {event.to_status ?? "none"} · version {event.session_version}
              {event.payload && Object.keys(event.payload).length > 0
                ? ` · ${JSON.stringify(event.payload)}`
                : ""}
            </p>
          </li>
        ))}
      </ol>
    </section>
  )
}
