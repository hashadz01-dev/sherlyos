import { useMemo, useState } from "react"
import { Link, useNavigate } from "react-router"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { activeOperationalBranches } from "@/lib/branches/operational"
import { createLotReconciliation, lotReconciliationKeys } from "@/lib/lot-reconciliation/api"
import {
  cratesBelongToGodown,
  createSessionIssues,
  newIdempotencyKey,
  reconciliationErrorMessage,
} from "@/lib/lot-reconciliation/rules"
import { notify } from "@/lib/utilities/notify"

export function NewLotReconciliationPage() {
  useDocumentTitle("New lot reconciliation")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const locations = useStockLocations()
  const [godownId, setGodownId] = useState("")
  const [crateIds, setCrateIds] = useState<string[]>([])
  const [notes, setNotes] = useState("")
  const [idempotencyKey, setIdempotencyKey] = useState(() => newIdempotencyKey("lr-create"))
  const branches = activeOperationalBranches(locations.branches.data)
  const zones = useMemo(
    () => (locations.zones.data ?? []).filter((zone) => zone.is_active && zone.branch_id === godownId),
    [locations.zones.data, godownId],
  )
  const crates = useMemo(
    () =>
      (locations.crates.data ?? []).filter(
        (crate) => crate.is_active && zones.some((zone) => zone.id === crate.zone_id),
      ),
    [locations.crates.data, zones],
  )
  const issues = createSessionIssues({ godownId, crateIds })
  const cratesValid = cratesBelongToGodown({
    crateIds,
    crates,
    zones,
    godownId,
  })
  const create = useMutation({
    mutationFn: () =>
      createLotReconciliation({
        target_godown: godownId,
        crate_ids: crateIds,
        idempotency_key: idempotencyKey,
        session_notes: notes.trim() || null,
      }),
    onSuccess: async (created) => {
      // Rotate only after a completed attempt so a retry keeps the original key.
      setIdempotencyKey(newIdempotencyKey("lr-create"))
      notify.success(`${created.session_number} created. Expected stock is frozen.`)
      await queryClient.invalidateQueries({ queryKey: lotReconciliationKeys.list })
      navigate(`/stock-lot-reconciliation/${created.id}`)
    },
  })
  const loading = locations.branches.isLoading || locations.zones.isLoading || locations.crates.isLoading
  const loadError = locations.branches.error || locations.zones.error || locations.crates.error

  function toggleCrate(crateId: string) {
    setCrateIds((current) =>
      current.includes(crateId) ? current.filter((id) => id !== crateId) : [...current, crateId],
    )
  }

  return (
    <section>
      <PageHeader
        title="New lot reconciliation"
        description="Select one authorized godown and the crates to count. The session number is assigned by the database."
        action={
          <Button variant="outline" asChild>
            <Link to="/stock-lot-reconciliation">Back</Link>
          </Button>
        }
      />
      {loading ? <LoadingBlock label="Loading godowns and crates" /> : null}
      {loadError ? (
        <p role="alert" className="text-sm text-destructive">
          {loadError.message}
        </p>
      ) : null}
      {!loading && !loadError ? (
        <form
          className="grid gap-5"
          onSubmit={(event) => {
            event.preventDefault()
            if (issues.length > 0 || !cratesValid || create.isPending) return
            create.mutate()
          }}
        >
          <label className="grid max-w-xl gap-2 text-sm font-medium">
            Godown
            <select
              aria-label="Godown"
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={godownId}
              onChange={(event) => {
                setGodownId(event.target.value)
                setCrateIds([])
              }}
            >
              <option value="">Select a godown</option>
              {branches.map((branch) => (
                <option key={branch.id} value={branch.id}>
                  {branch.name} ({branch.code})
                </option>
              ))}
            </select>
          </label>
          <fieldset className="grid gap-2">
            <legend className="text-sm font-medium">Crates</legend>
            <p className="text-sm text-muted-foreground">
              Select one or more crates in this godown. An overlapping active session will be rejected.
            </p>
            {godownId && crates.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => setCrateIds(crates.map((crate) => crate.id))}
                >
                  Select all crates
                </Button>
                <Button type="button" variant="outline" onClick={() => setCrateIds([])}>
                  Clear crates
                </Button>
              </div>
            ) : null}
            <div className="grid gap-2 sm:grid-cols-2">
              {crates.map((crate) => {
                const zone = zones.find((row) => row.id === crate.zone_id)
                return (
                  <label key={crate.id} className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={crateIds.includes(crate.id)}
                      onChange={() => toggleCrate(crate.id)}
                    />
                    {zone?.code} · {crate.code}
                    {crate.name ? ` · ${crate.name}` : ""}
                  </label>
                )
              })}
            </div>
            {godownId && crates.length === 0 ? (
              <p className="text-sm text-muted-foreground">No active crates in this godown.</p>
            ) : null}
          </fieldset>
          <label className="grid max-w-xl gap-2 text-sm font-medium">
            Notes
            <textarea
              aria-label="Session notes"
              className="min-h-24 rounded-lg border border-input px-2.5 py-2 text-sm font-normal"
              value={notes}
              onChange={(event) => setNotes(event.target.value)}
            />
          </label>
          {crateIds.length > 0 ? (
            <p className="text-sm">{crateIds.length} crates selected. The session reference will come from the server.</p>
          ) : null}
          {issues.map((issue) => (
            <p key={issue} role="alert" className="text-sm text-destructive">
              {issue}
            </p>
          ))}
          {!cratesValid && crateIds.length > 0 ? (
            <p role="alert" className="text-sm text-destructive">
              Every selected crate must belong to the chosen godown.
            </p>
          ) : null}
          {create.error ? (
            <p role="alert" className="text-sm text-destructive">
              {reconciliationErrorMessage(create.error)}
            </p>
          ) : null}
          <Button type="submit" disabled={issues.length > 0 || !cratesValid || create.isPending}>
            {create.isPending ? "Creating" : "Create session"}
          </Button>
        </form>
      ) : null}
    </section>
  )
}
