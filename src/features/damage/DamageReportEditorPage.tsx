/**
 * Create and edit drafts for the six blueprint damage scenarios.
 * Submit always goes through submit_damage_report. Isolation and custody
 * remain backend fail-closed gates; this page never posts stock.
 */
import { useCallback, useEffect, useState } from "react"
import { Link, useNavigate, useParams } from "react-router"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { DamageEvidenceUploader } from "@/features/damage/components/DamageEvidenceUploader"
import { DamageLineEditor } from "@/features/damage/components/DamageLineEditor"
import { DamageReadinessBanner } from "@/features/damage/components/DamageReadinessBanner"
import { DamageScenarioPicker } from "@/features/damage/components/DamageScenarioPicker"
import { DamageSourcePicker } from "@/features/damage/components/DamageSourcePicker"
import { DamageSubmitReview } from "@/features/damage/components/DamageSubmitReview"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import {
  clearCreateIdempotencyKey,
  createIdempotencyKey,
  emptySourceRefs,
  submitIdempotencyKey,
  toReportLineInputs,
  validateDraftLines,
  type DraftLine,
  type SourceRefs,
} from "@/features/damage/utils/draft"
import {
  damageStatusTone,
  formatDamageStatus,
} from "@/features/damage/utils/labels"
import {
  collectSubmitBlockers,
  mapDamageMutationError,
  scenarioSubmitHint,
} from "@/features/damage/utils/submit"
import { useStockLocations } from "@/features/inventory/location-options"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import {
  createDamageReport,
  getDamageReport,
  getDamageStockHoldReadyStatus,
  submitDamageReport,
  updateDamageReport,
  type DamageSourceCatalogs,
  type DamageSourceItem,
} from "@/lib/damage/api"
import { isEditableDamageStatus, type DamageScenario } from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

function sourceLabelOf(item: DamageSourceItem | null, refs: SourceRefs) {
  if (item?.label) return item.label
  if (refs.receiptId) return `Receipt ${refs.receiptId.slice(0, 8)}`
  if (refs.pickingRequestId)
    return `Picking ${refs.pickingRequestId.slice(0, 8)}`
  if (refs.dispatchId) return `Dispatch ${refs.dispatchId.slice(0, 8)}`
  if (refs.shopId) return `Shop ${refs.shopId.slice(0, 8)}`
  return ""
}

function DamageReportEditor({
  mode,
  reportId,
}: {
  mode: "create" | "edit"
  reportId?: string
}) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const access = useDamageAccess()
  const auth = useAuth()
  const locations = useStockLocations()
  const userId = auth.session?.user.id

  const [scenario, setScenario] = useState<DamageScenario | "">("")
  const [godownId, setGodownId] = useState("")
  const [source, setSource] = useState<DamageSourceItem | null>(null)
  const [catalogs, setCatalogs] = useState<DamageSourceCatalogs>({})
  const [refs, setRefs] = useState<SourceRefs>(emptySourceRefs())
  const [lines, setLines] = useState<DraftLine[]>([])
  const [notes, setNotes] = useState("")
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState<"save" | "submit" | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [savedId, setSavedId] = useState(reportId ?? "")
  const [ambiguousSubmit, setAmbiguousSubmit] = useState(false)

  const existing = useQuery({
    queryKey: ["damage-report", savedId],
    queryFn: () => getDamageReport(savedId),
    enabled: savedId !== "",
  })
  const readiness = useQuery({
    queryKey: ["damage-hold-ready"],
    queryFn: getDamageStockHoldReadyStatus,
    enabled: access.canOpenDamage,
  })

  const report = existing.data ?? null
  const stockHoldReady = readiness.data?.stock_hold_ready === true
  const editable =
    !report ||
    (isEditableDamageStatus(report.status) &&
      report.reporter_user_id === userId)

  useDocumentTitle(
    mode === "create"
      ? "New damage report"
      : report
        ? `Edit ${report.report_number}`
        : "Edit damage report",
  )

  useEffect(() => {
    if (!report || dirty) return
    setScenario(report.scenario)
    setGodownId(report.godown_id)
    setNotes(report.notes ?? "")
    setRefs({
      receiptId: report.receipt_id,
      pickingRequestId: report.picking_request_id,
      dispatchId: report.dispatch_id,
      orderId: report.order_id,
      shopId: report.shop_id,
    })
    setLines(
      report.lines.map((line) => ({
        key: line.id,
        product_id: line.product_id,
        product_sku: line.product_sku,
        product_name: line.product_name,
        quantity_cases: String(line.quantity_cases),
        damage_reason: line.damage_reason,
        crate_id: line.crate_id ?? "",
        crate_code: line.crate_code ?? "",
        lot_id: line.lot_id ?? "",
        notes: line.notes ?? "",
        receipt_line_id: line.receipt_line_id ?? "",
      })),
    )
  }, [report, dirty])

  useEffect(() => {
    if (!dirty) return
    const onLeave = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", onLeave)
    return () => window.removeEventListener("beforeunload", onLeave)
  }, [dirty])

  const markDirty = useCallback(() => {
    setDirty(true)
    setActionError(null)
  }, [])

  const onSelectSource = useCallback(
    (
      item: DamageSourceItem,
      nextCatalogs: DamageSourceCatalogs,
      nextRefs: SourceRefs,
    ) => {
      setCatalogs(nextCatalogs)
      setRefs(nextRefs)
      // Storage auto-selects the godown after catalogs load. Keep any lines
      // already entered for that same source so a late catalog refresh does
      // not wipe the draft form.
      setSource((previous) => {
        if (previous?.id !== item.id) {
          setLines([])
        }
        return item
      })
      markDirty()
    },
    [markDirty],
  )

  const lineErrors = scenario ? validateDraftLines(scenario, lines) : []
  const sourceSelected =
    scenario === "storage"
      ? Boolean(godownId)
      : Boolean(
          refs.receiptId ||
          refs.pickingRequestId ||
          refs.dispatchId ||
          refs.shopId,
        )
  const blockers = collectSubmitBlockers({
    scenario,
    stockHoldReady,
    linesValid: lineErrors.length === 0,
    sourceSelected,
    finalizedEvidence: (report?.evidence ?? []).filter((row) => row.finalized)
      .length,
    custodyConfirmed: report?.physical_custody_confirmed === true,
    status: report?.status,
  })

  async function refreshReport(id = savedId) {
    if (!id) return
    await queryClient.invalidateQueries({ queryKey: ["damage-report", id] })
    await existing.refetch()
  }

  async function saveDraft() {
    if (!scenario || !godownId) {
      setActionError("Select a scenario and godown.")
      return null
    }
    if (lineErrors.length > 0) {
      setActionError(lineErrors[0] ?? "Correct the damage lines.")
      return null
    }
    if (busy) return null
    setBusy("save")
    setActionError(null)
    try {
      const payload = {
        scenario,
        targetGodown: godownId,
        reportLines: toReportLineInputs(lines),
        notes: notes.trim() || null,
        receiptId: refs.receiptId,
        pickingRequestId: refs.pickingRequestId,
        dispatchId: refs.dispatchId,
        orderId: refs.orderId,
        shopId: refs.shopId,
      }
      const saved = report
        ? await updateDamageReport({
            targetReport: report.id,
            expectedVersion: report.version,
            reportLines: payload.reportLines,
            notes: payload.notes,
            receiptId: payload.receiptId,
            pickingRequestId: payload.pickingRequestId,
            dispatchId: payload.dispatchId,
            orderId: payload.orderId,
            shopId: payload.shopId,
          })
        : await createDamageReport({
            ...payload,
            idempotencyKey: createIdempotencyKey(userId),
          })
      clearCreateIdempotencyKey(userId)
      setSavedId(saved.id)
      setDirty(false)
      queryClient.setQueryData(["damage-report", saved.id], saved)
      notify.success(
        report
          ? `${saved.report_number} saved`
          : `Draft ${saved.report_number} created`,
      )
      if (mode === "create" && !reportId) {
        await navigate(`/damage/${saved.id}/edit`, { replace: true })
      }
      return saved
    } catch (caught) {
      setActionError(mapDamageMutationError(caught, "save"))
      return null
    } finally {
      setBusy(null)
    }
  }

  async function submitSaved() {
    const current = report ?? (await saveDraft())
    if (!current) return
    if (ambiguousSubmit) {
      await refreshReport(current.id)
      setAmbiguousSubmit(false)
      setActionError(
        "Report state refreshed. Confirm the status before submitting again.",
      )
      return
    }
    if (busy) return
    setBusy("submit")
    setActionError(null)
    try {
      const submitted = await submitDamageReport(
        current.id,
        current.version,
        submitIdempotencyKey(current.id),
      )
      setDirty(false)
      queryClient.setQueryData(["damage-report", submitted.id], submitted)
      notify.success(`${submitted.report_number} submitted`)
      await navigate(`/damage/${submitted.id}`)
    } catch (caught) {
      const message = mapDamageMutationError(caught, "submit")
      setActionError(message)
      if (/may have been received/i.test(message)) {
        setAmbiguousSubmit(true)
      }
    } finally {
      setBusy(null)
      setConfirmOpen(false)
    }
  }

  if (access.loading) {
    return <LoadingBlock label="Checking access" />
  }

  if (!access.canCreate) {
    return (
      <p role="alert" className="text-sm text-destructive">
        You do not have permission to create or edit damage reports.
      </p>
    )
  }

  if (mode === "edit" && existing.isLoading) {
    return <LoadingBlock label="Loading damage report" />
  }

  if (mode === "edit" && existing.error) {
    return (
      <p role="alert" className="text-sm text-destructive">
        {existing.error.message}
      </p>
    )
  }

  if (mode === "edit" && report && !editable) {
    return (
      <section className="grid gap-3">
        <p role="alert" className="text-sm text-destructive">
          This report cannot be edited. Only the reporter may change a draft or
          returned report.
        </p>
        <Button asChild variant="outline">
          <Link to={`/damage/${report.id}`}>Open report</Link>
        </Button>
      </section>
    )
  }

  return (
    <section className="min-w-0 grid gap-5">
      <PageHeader
        title={
          mode === "create"
            ? "New damage report"
            : report
              ? `Edit ${report.report_number}`
              : "Edit damage report"
        }
        description="Save a draft, attach private photo evidence, then submit through the trusted damage RPC. Stock is never posted from this screen."
        action={
          <div className="flex flex-wrap gap-2">
            {report ? (
              <StatusBadge tone={damageStatusTone[report.status]}>
                {formatDamageStatus(report.status)}
              </StatusBadge>
            ) : (
              <StatusBadge tone="neutral">Unsaved</StatusBadge>
            )}
            <Button asChild variant="outline">
              <Link to={report ? `/damage/${report.id}` : "/damage/reports"}>
                Cancel
              </Link>
            </Button>
          </div>
        }
      />

      {readiness.data ? (
        <DamageReadinessBanner stockHoldReady={stockHoldReady} />
      ) : null}
      {scenarioSubmitHint(scenario, stockHoldReady) ? (
        <p className="text-sm text-muted-foreground">
          {scenarioSubmitHint(scenario, stockHoldReady)}
        </p>
      ) : null}

      <Label
        className="grid max-w-sm gap-2 text-sm font-medium"
        htmlFor="damage-godown"
      >
        Godown
        <select
          id="damage-godown"
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={godownId}
          disabled={Boolean(report) || busy !== null}
          onChange={(event) => {
            setGodownId(event.target.value)
            setSource(null)
            setCatalogs({})
            setRefs(emptySourceRefs())
            setLines([])
            markDirty()
          }}
        >
          <option value="">Select godown</option>
          {(locations.branches.data ?? []).map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.name}
            </option>
          ))}
        </select>
      </Label>

      <DamageScenarioPicker
        value={scenario}
        allowed={access.availableScenarios}
        disabled={Boolean(report) || busy !== null}
        onChange={(next) => {
          setScenario(next)
          setSource(null)
          setCatalogs({})
          setRefs(emptySourceRefs())
          setLines([])
          markDirty()
        }}
      />

      {scenario && godownId ? (
        <DamageSourcePicker
          scenario={scenario}
          godownId={godownId}
          selectedId={source?.id ?? ""}
          disabled={busy !== null}
          onSelect={onSelectSource}
          onCatalogs={setCatalogs}
        />
      ) : null}

      {scenario ? (
        <DamageLineEditor
          scenario={scenario}
          source={source}
          catalogs={catalogs}
          lines={lines}
          disabled={busy !== null}
          onChange={(next) => {
            setLines(next)
            markDirty()
          }}
        />
      ) : null}

      {lineErrors.length > 0 ? (
        <ul className="grid gap-1 text-sm text-destructive">
          {lineErrors.map((error) => (
            <li key={error}>{error}</li>
          ))}
        </ul>
      ) : null}

      <Label className="grid gap-2 text-sm font-medium">
        Report notes
        <textarea
          className="min-h-20 rounded-xl border bg-transparent px-3 py-2 text-sm"
          maxLength={500}
          value={notes}
          disabled={busy !== null}
          onChange={(event) => {
            setNotes(event.target.value)
            markDirty()
          }}
        />
      </Label>

      <DamageEvidenceUploader
        report={report}
        disabled={busy !== null || !editable}
        onUploaded={() => refreshReport()}
      />

      <DamageSubmitReview
        scenario={scenario}
        sourceLabel={sourceLabelOf(source, refs)}
        lines={lines}
        notes={notes}
        evidenceCount={
          (report?.evidence ?? []).filter((row) => row.finalized).length
        }
        blockers={blockers}
      />

      {actionError ? (
        <p role="alert" className="text-sm text-destructive">
          {actionError}
        </p>
      ) : null}

      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          disabled={busy !== null}
          onClick={() => void saveDraft()}
        >
          {busy === "save" ? "Saving…" : "Save draft"}
        </Button>
        <Button
          type="button"
          variant="outline"
          disabled={busy !== null || blockers.length > 0}
          onClick={() => setConfirmOpen(true)}
        >
          Review and submit
        </Button>
      </div>

      <AppModal
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        title="Submit damage report"
        description="Submission calls the trusted backend RPC. Stock postings are not performed in the browser."
        footer={
          <>
            <Button
              type="button"
              variant="outline"
              onClick={() => setConfirmOpen(false)}
            >
              Back
            </Button>
            <Button
              type="button"
              disabled={busy !== null}
              onClick={() => void submitSaved()}
            >
              {busy === "submit" ? "Submitting…" : "Submit report"}
            </Button>
          </>
        }
      >
        <p className="text-sm">
          {sourceLabelOf(source, refs)} · {lines.length} line
          {lines.length === 1 ? "" : "s"}
        </p>
      </AppModal>
    </section>
  )
}

export function NewDamageReportPage() {
  return <DamageReportEditor mode="create" />
}

export function EditDamageReportPage() {
  const { reportId = "" } = useParams()
  return <DamageReportEditor mode="edit" reportId={reportId} />
}
