import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import {
  ClipboardCheck,
  Package,
  ShieldAlert,
  TriangleAlert,
} from "lucide-react"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { MetricCard } from "@/components/shared/MetricCard"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { DamageQueueCard } from "@/features/damage/components/DamageQueueCard"
import { DamageReadinessBanner } from "@/features/damage/components/DamageReadinessBanner"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { getDamageDashboard } from "@/lib/damage/api"
import { useState } from "react"

export function DamagePage() {
  useDocumentTitle("Damage Management")
  const access = useDamageAccess()
  const locations = useStockLocations()
  const [godownId, setGodownId] = useState("all")
  const dashboard = useQuery({
    queryKey: ["damage-dashboard", godownId],
    queryFn: () => getDamageDashboard(godownId === "all" ? null : godownId),
    enabled: access.canOpenDamage,
  })

  const totals = dashboard.data?.totals
  const queues = dashboard.data?.queues

  return (
    <section className="min-w-0">
      <PageHeader
        title="Damage Management"
        description="Authorized damage reports, verification queues, and stock isolation status. Mutation workflows arrive in later phases."
        action={
          <Button asChild variant="outline">
            <Link to="/damage/reports">All reports</Link>
          </Button>
        }
      />

      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <label className="grid max-w-sm gap-2 text-sm font-medium">
          Godown filter
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={godownId}
            onChange={(event) => setGodownId(event.target.value)}
            aria-label="Godown filter"
          >
            <option value="all">All authorized godowns</option>
            {(locations.branches.data ?? []).map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </select>
        </label>
        {dashboard.data ? (
          <DamageReadinessBanner
            stockHoldReady={dashboard.data.stock_hold_ready}
          />
        ) : null}
      </div>

      {dashboard.isLoading ? (
        <LoadingBlock label="Loading damage dashboard" />
      ) : null}
      {dashboard.error ? (
        <p role="alert" className="text-sm text-destructive">
          {dashboard.error.message}
        </p>
      ) : null}

      {totals ? (
        <div className="mb-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <MetricCard
            label="Damage reports"
            icon={TriangleAlert}
            hint="Authorized report count"
            value={totals.reports}
          />
          <MetricCard
            label="Pending verification"
            icon={ClipboardCheck}
            hint="Submitted reports awaiting review"
            value={totals.pending_verification}
          />
          <MetricCard
            label="Verified reports"
            icon={ClipboardCheck}
            hint="Report count in verified status (not carton quantity)"
            value={totals.verified}
          />
          <MetricCard
            label="Active hold cases"
            icon={Package}
            hint="Carton cases under logical hold or quarantine intake"
            value={totals.active_hold_cases}
          />
          <MetricCard
            label="Quarantined cases"
            icon={Package}
            hint="Carton cases on quarantine crates or quarantine intake holds"
            value={totals.quarantined_cases}
          />
          <MetricCard
            label="Pending exceptional"
            icon={ShieldAlert}
            hint="Exceptional disposition requests still open"
            value={totals.pending_exceptional}
            unavailable={
              !access.showExceptionalQueues && totals.pending_exceptional === 0
            }
          />
        </div>
      ) : null}

      {queues ? (
        <div className="grid gap-4 lg:grid-cols-2">
          <DamageQueueCard
            title="Recently submitted"
            description="Newest submitted reports you are allowed to see."
            items={queues.recent_submitted}
          />
          {access.showVerificationQueues ? (
            <DamageQueueCard
              title="Awaiting verification"
              description="Oldest submitted reports first."
              items={queues.awaiting_verification}
            />
          ) : null}
          {access.showDispositionQueues ? (
            <DamageQueueCard
              title="Awaiting disposition"
              description="Verified reports that still have active or transferred holds."
              items={queues.awaiting_disposition}
            />
          ) : null}
          {access.showExceptionalQueues ? (
            <DamageQueueCard
              title="Exceptional approvals"
              description="Open return-to-supplier or destroy requests."
              items={queues.exceptional_pending}
            />
          ) : null}
          <DamageQueueCard
            title="Recently resolved"
            description="Verified, rejected, or cancelled reports without open holds."
            items={queues.recently_resolved}
          />
        </div>
      ) : null}
    </section>
  )
}
