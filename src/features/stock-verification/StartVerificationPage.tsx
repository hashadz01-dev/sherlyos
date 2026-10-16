import { useMemo, useState } from "react"
import { Link, useNavigate } from "react-router"
import { useMutation, useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { notify } from "@/lib/utilities/notify"
import {
  listVerificationOptions,
  previewVerificationScope,
  startStockVerification,
} from "@/lib/verification/api"
import {
  scopeSelectionReady,
  startVerificationIssues,
  verificationErrorMessage,
} from "@/lib/verification/rules"

export function StartVerificationPage() {
  useDocumentTitle("Start stock verification")
  const navigate = useNavigate()
  const [godownId, setGodownId] = useState("")
  const [businessDate, setBusinessDate] = useState(() => {
    const now = new Date()
    const month = String(now.getMonth() + 1).padStart(2, "0")
    const day = String(now.getDate()).padStart(2, "0")
    return `${now.getFullYear()}-${month}-${day}`
  })
  const [zoneIds, setZoneIds] = useState<string[]>([])
  const [crateIds, setCrateIds] = useState<string[]>([])
  const options = useQuery({
    queryKey: ["verification-options"],
    queryFn: listVerificationOptions,
  })
  const zones = useMemo(
    () => (options.data?.zones ?? []).filter((zone) => zone.branch_id === godownId),
    [options.data, godownId],
  )
  const crates = useMemo(
    () =>
      (options.data?.crates ?? []).filter((crate) =>
        zones.some((zone) => zone.id === crate.zone_id && zoneIds.includes(zone.id)),
      ),
    [options.data, zones, zoneIds],
  )
  const ready = scopeSelectionReady({
    zoneIds,
    crateIds,
    crates: options.data?.crates ?? [],
  })
  const preview = useQuery({
    queryKey: ["verification-preview", godownId, zoneIds, crateIds],
    enabled: Boolean(godownId) && ready,
    queryFn: () =>
      previewVerificationScope({
        target_godown: godownId,
        zone_ids: zoneIds,
        crate_ids: crateIds,
      }),
  })
  const start = useMutation({
    mutationFn: () =>
      startStockVerification({
        target_godown: godownId,
        verification_date: businessDate,
        zone_ids: zoneIds,
        crate_ids: crateIds,
      }),
    onSuccess: (id) => {
      notify.success("Verification started. Expected stock is frozen.")
      navigate(`/stock-verification/${id}`)
    },
  })
  const issues = startVerificationIssues({ godownId, businessDate, zoneIds, crateIds })

  function toggle(list: string[], id: string, setList: (next: string[]) => void) {
    setList(list.includes(id) ? list.filter((item) => item !== id) : [...list, id])
  }

  return (
    <section>
      <PageHeader
        title="Start verification"
        description="Choose one assigned godown, its zones, and the crates to count. Starting freezes expected stock from the ledger."
        action={
          <Button variant="outline" asChild>
            <Link to="/stock-verification">Back</Link>
          </Button>
        }
      />
      {options.isLoading ? <LoadingBlock label="Loading godowns" /> : null}
      {options.error ? (
        <p role="alert" className="text-sm text-destructive">
          {options.error.message}
        </p>
      ) : null}
      {options.data ? (
        <form
          className="grid gap-5"
          onSubmit={(event) => {
            event.preventDefault()
            if (issues.length > 0 || !ready) return
            start.mutate()
          }}
        >
          <div className="grid gap-3 md:grid-cols-2">
            <label className="grid gap-2 text-sm font-medium">
              Godown
              <select
                aria-label="Godown"
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={godownId}
                onChange={(event) => {
                  setGodownId(event.target.value)
                  setZoneIds([])
                  setCrateIds([])
                }}
              >
                <option value="">Select a godown</option>
                {options.data.godowns.map((godown) => (
                  <option key={godown.id} value={godown.id}>
                    {godown.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Business date
              <input
                type="date"
                aria-label="Business date"
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={businessDate}
                onChange={(event) => setBusinessDate(event.target.value)}
              />
            </label>
          </div>
          <fieldset className="grid gap-2">
            <legend className="text-sm font-medium">Zones</legend>
            <div className="grid gap-2 sm:grid-cols-2">
              {zones.map((zone) => (
                <label key={zone.id} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={zoneIds.includes(zone.id)}
                    onChange={() => {
                      const next = zoneIds.includes(zone.id)
                        ? zoneIds.filter((id) => id !== zone.id)
                        : [...zoneIds, zone.id]
                      setZoneIds(next)
                      setCrateIds(
                        crateIds.filter((crateId) =>
                          (options.data?.crates ?? []).some(
                            (crate) => crate.id === crateId && next.includes(crate.zone_id),
                          ),
                        ),
                      )
                    }}
                  />
                  {zone.code} · {zone.name}
                </label>
              ))}
            </div>
          </fieldset>
          <fieldset className="grid gap-2">
            <legend className="text-sm font-medium">Crates</legend>
            <div className="grid gap-2 sm:grid-cols-2">
              {crates.map((crate) => (
                <label key={crate.id} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={crateIds.includes(crate.id)}
                    onChange={() => toggle(crateIds, crate.id, setCrateIds)}
                  />
                  {crate.code}
                  {crate.name ? ` · ${crate.name}` : ""}
                </label>
              ))}
            </div>
          </fieldset>
          {preview.data ? (
            <div className="rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
              <p>{preview.data.crate_count} crates selected</p>
              <p>{preview.data.product_count} products with stock</p>
              <p>{preview.data.expected_cases} expected cases</p>
            </div>
          ) : null}
          {preview.error ? (
            <p role="alert" className="text-sm text-destructive">
              {preview.error.message}
            </p>
          ) : null}
          {start.error ? (
            <p role="alert" className="text-sm text-destructive">
              {verificationErrorMessage(start.error)}
            </p>
          ) : null}
          <Button type="submit" disabled={issues.length > 0 || !ready || start.isPending}>
            {start.isPending ? "Starting" : "Start and freeze snapshot"}
          </Button>
        </form>
      ) : null}
    </section>
  )
}
