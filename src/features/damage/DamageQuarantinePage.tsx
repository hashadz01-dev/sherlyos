import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { DamageQuarantineTable } from "@/features/damage/components/DamageQuarantineTable"
import { DamageReadinessBanner } from "@/features/damage/components/DamageReadinessBanner"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import {
  formatCases,
  formatHoldKind,
  formatHoldStatus,
  formatDamageScenario,
} from "@/features/damage/utils/labels"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import {
  getDamageStockHoldReadyStatus,
  listDamageQuarantineInventory,
} from "@/lib/damage/api"
import {
  damageHoldKinds,
  damageHoldStatuses,
  damageScenarios,
} from "@/lib/damage/rules"

type QuarantineFilters = {
  godownId: string
  productSearch: string
  scenario: string
  holdKind: string
  holdStatus: string
  fromDate: string
  toDate: string
}

const emptyFilters: QuarantineFilters = {
  godownId: "all",
  productSearch: "",
  scenario: "all",
  holdKind: "all",
  holdStatus: "all",
  fromDate: "",
  toDate: "",
}

export function DamageQuarantinePage() {
  useDocumentTitle("Damage quarantine")
  const access = useDamageAccess()
  const locations = useStockLocations()
  const [filters, setFilters] = useState<QuarantineFilters>(emptyFilters)
  const [page, setPage] = useState(1)
  const pageSize = 25

  const ready = useQuery({
    queryKey: ["damage-ready-status"],
    queryFn: getDamageStockHoldReadyStatus,
    enabled: access.canViewQuarantine,
  })

  const list = useQuery({
    queryKey: ["damage-quarantine", page, pageSize, filters],
    queryFn: () =>
      listDamageQuarantineInventory({
        page,
        pageSize,
        targetGodown: filters.godownId === "all" ? null : filters.godownId,
        scenario: filters.scenario === "all" ? null : filters.scenario,
        holdKind: filters.holdKind === "all" ? null : filters.holdKind,
        holdStatus: filters.holdStatus === "all" ? null : filters.holdStatus,
        productSearch: filters.productSearch.trim() || null,
        fromDate: filters.fromDate || null,
        toDate: filters.toDate || null,
      }),
    enabled: access.canViewQuarantine,
  })

  const rows = list.data?.items ?? []
  const total = list.data?.total ?? 0
  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  function patch(partial: Partial<QuarantineFilters>) {
    setFilters((current) => ({ ...current, ...partial }))
    setPage(1)
  }

  return (
    <section className="min-w-0">
      <PageHeader
        title="Quarantine inventory"
        description="Authorized damage holds and quarantine crates. Logical holds are not physical stock."
        action={
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="outline">
              <Link to="/damage">Dashboard</Link>
            </Button>
            <Button asChild variant="outline">
              <Link to="/damage/reports">Reports</Link>
            </Button>
          </div>
        }
      />

      {ready.data ? (
        <div className="mb-4">
          <DamageReadinessBanner stockHoldReady={ready.data.stock_hold_ready} />
        </div>
      ) : null}

      <div className="mb-4 grid gap-3 md:grid-cols-3 xl:grid-cols-6">
        <label className="grid gap-2 text-sm font-medium">
          Godown
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.godownId}
            onChange={(event) => patch({ godownId: event.target.value })}
            aria-label="Godown"
          >
            <option value="all">All authorized godowns</option>
            {(locations.branches.data ?? []).map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
                {branch.is_active ? "" : " (inactive)"}
              </option>
            ))}
          </select>
        </label>
        <label className="grid gap-2 text-sm font-medium">
          Product
          <input
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.productSearch}
            onChange={(event) => patch({ productSearch: event.target.value })}
            aria-label="Product"
            placeholder="SKU or name"
          />
        </label>
        <label className="grid gap-2 text-sm font-medium">
          Scenario
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.scenario}
            onChange={(event) => patch({ scenario: event.target.value })}
            aria-label="Scenario"
          >
            <option value="all">All scenarios</option>
            {damageScenarios.map((scenario) => (
              <option key={scenario} value={scenario}>
                {formatDamageScenario(scenario)}
              </option>
            ))}
          </select>
        </label>
        <label className="grid gap-2 text-sm font-medium">
          Hold kind
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.holdKind}
            onChange={(event) => patch({ holdKind: event.target.value })}
            aria-label="Hold kind"
          >
            <option value="all">All hold kinds</option>
            {damageHoldKinds.map((kind) => (
              <option key={kind} value={kind}>
                {formatHoldKind(kind)}
              </option>
            ))}
          </select>
        </label>
        <label className="grid gap-2 text-sm font-medium">
          Status
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.holdStatus}
            onChange={(event) => patch({ holdStatus: event.target.value })}
            aria-label="Hold status"
          >
            <option value="all">All statuses</option>
            {damageHoldStatuses.map((status) => (
              <option key={status} value={status}>
                {formatHoldStatus(status)}
              </option>
            ))}
          </select>
        </label>
        <label className="grid gap-2 text-sm font-medium">
          From date
          <input
            type="date"
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.fromDate}
            onChange={(event) => patch({ fromDate: event.target.value })}
            aria-label="From date"
          />
        </label>
        <label className="grid gap-2 text-sm font-medium">
          To date
          <input
            type="date"
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.toDate}
            onChange={(event) => patch({ toDate: event.target.value })}
            aria-label="To date"
          />
        </label>
        <div className="flex flex-wrap items-end gap-2 md:col-span-3 xl:col-span-6">
          <Button
            type="button"
            variant="outline"
            onClick={() => {
              setFilters(emptyFilters)
              setPage(1)
            }}
          >
            Clear filters
          </Button>
          <Button
            type="button"
            variant="outline"
            onClick={() => void list.refetch()}
          >
            Refresh
          </Button>
        </div>
      </div>

      {list.isLoading ? (
        <LoadingBlock label="Loading quarantine inventory" />
      ) : null}
      {list.error ? (
        <p role="alert" className="text-sm text-destructive">
          {list.error.message}
        </p>
      ) : null}

      {/* Server totals cover the filter, not the visible page and not saleable stock. */}
      {list.data?.totals ? (
        <div className="mb-4 rounded-lg border border-border p-3">
          <p className="text-sm text-muted-foreground">
            Filter-wide hold counts. These are not this page&apos;s cartons and
            are not saleable stock. Written-off cases are excluded from current
            unavailable.
          </p>
          <dl className="mt-3 grid gap-2 text-sm sm:grid-cols-2 xl:grid-cols-3">
            <div>
              <dt className="text-muted-foreground">Matching hold rows</dt>
              <dd>{total}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Current unavailable</dt>
              <dd>{formatCases(list.data.totals.current_unavailable_cases)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Logical holds</dt>
              <dd>{formatCases(list.data.totals.logical_hold_cases)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Reservation converted</dt>
              <dd>
                {formatCases(list.data.totals.reservation_converted_cases)}
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Shop-return intake</dt>
              <dd>{formatCases(list.data.totals.shop_return_intake_cases)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Physically transferred</dt>
              <dd>
                {formatCases(list.data.totals.transferred_quarantine_cases)}
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">
                Written off (not current)
              </dt>
              <dd>{formatCases(list.data.totals.written_off_cases)}</dd>
            </div>
          </dl>
        </div>
      ) : null}

      {list.data ? <DamageQuarantineTable rows={rows} /> : null}

      {list.data && total > 0 ? (
        <div className="mt-4 flex items-center justify-between gap-3">
          <p className="text-sm text-muted-foreground">
            Page {page} of {totalPages} · {total} matching hold
            {total === 1 ? "" : "s"}
          </p>
          <div className="flex gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={page <= 1}
              onClick={() => setPage((current) => Math.max(1, current - 1))}
            >
              Previous
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={page >= totalPages}
              onClick={() => setPage((current) => current + 1)}
            >
              Next
            </Button>
          </div>
        </div>
      ) : null}
    </section>
  )
}
