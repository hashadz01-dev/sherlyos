import { Link, useParams } from "react-router"
import { MapPinned } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { formatCases, formatPercent } from "@/lib/warehouse/capacity"
import { plannedZonePath } from "@/lib/warehouse/layout"
import { buildZoneBoard } from "@/lib/warehouse/model"
import {
  CapacityProgress,
  Metric,
  WarehouseBackLink,
  WarehouseBreadcrumbs,
  warehouseCardLinkClass,
} from "@/features/administration/godowns/components/WarehouseChrome"
import { useWarehouseSnapshot } from "@/features/administration/godowns/use-warehouse"

export function GodownZonesPage() {
  useDocumentTitle("Godown zones")
  const { godownId = "" } = useParams()
  const warehouse = useWarehouseSnapshot()
  const board = warehouse.ready ? buildZoneBoard(warehouse.ready, godownId) : null
  const stockBlocked = Boolean(warehouse.balances.error || warehouse.lots.error)
  const stockReady = warehouse.balances.isSuccess && warehouse.lots.isSuccess

  return (
    <section>
      <WarehouseBreadcrumbs
        items={[
          { label: "Godowns", to: "/godowns" },
          { label: board?.godown?.name ?? "Godown" },
        ]}
      />
      <PageHeader
        title={board?.godown?.name ?? "Godown zones"}
        description="Zones A–E are the planned normal layout. Zone F is the planned quarantine layout. Locations that already exist under other codes stay listed separately."
        action={<WarehouseBackLink to="/godowns" label="Back to godowns" />}
      />
      {warehouse.structureLoading || warehouse.balances.isLoading ? (
        <LoadingBlock label="Loading zones" />
      ) : null}
      {warehouse.structureError ? (
        <p role="alert" className="text-sm text-destructive">
          {warehouse.structureError instanceof Error
            ? warehouse.structureError.message
            : "Zones could not be loaded."}
        </p>
      ) : null}
      {board && !board.godown ? (
        <EmptyState
          icon={MapPinned}
          title="Godown not found"
          description="This godown is not visible to the current account."
        />
      ) : null}
      {board?.godown ? (
        <div className="mb-4 flex flex-wrap gap-2">
          <StatusBadge tone={board.godown.classification === "Reserve" ? "info" : "neutral"}>
            {board.godown.classification}
          </StatusBadge>
          <StatusBadge tone={board.godown.is_active ? "success" : "neutral"}>
            {board.godown.is_active ? "Active" : "Inactive"}
          </StatusBadge>
          <span className="text-sm text-muted-foreground">{board.godown.code}</span>
        </div>
      ) : null}
      <ul className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {(board?.targets ?? []).map((zone) => {
          const destination =
            zone.configured && zone.id
              ? `/godowns/${godownId}/zones/${zone.id}/crates`
              : plannedZonePath(godownId, zone.key)
          return (
            <li key={zone.key}>
              <Link
                to={destination}
                className={`${warehouseCardLinkClass} ${zone.quarantine ? "ring-orange-200 hover:ring-orange-300" : ""}`}
                aria-label={
                  zone.configured
                    ? `Open crates for ${zone.title}`
                    : `Preview ${zone.title}, not configured`
                }
              >
                <div className="flex items-start justify-between gap-2">
                  <h2 className="font-medium">{zone.title}</h2>
                  <StatusBadge tone={zone.configured ? "success" : "neutral"}>
                    {zone.configured ? "Configured" : "Not configured"}
                  </StatusBadge>
                </div>
                <p className="mt-1 text-xs text-muted-foreground">{zone.classification}</p>
                {zone.configured && zone.metrics ? (
                  <>
                    <dl className="mt-3 grid grid-cols-2 gap-2">
                      <Metric label="Crates" value={String(zone.crateCount)} />
                      <Metric
                        label="On hand"
                        value={
                          !stockReady
                            ? stockBlocked
                              ? "Unavailable"
                              : "…"
                            : formatCases(zone.metrics.onHand)
                        }
                      />
                      <Metric
                        label="Planned capacity"
                        value={formatCases(zone.metrics.plannedCapacity)}
                      />
                      <Metric
                        label="Configured capacity"
                        value={formatCases(zone.metrics.configuredCapacity)}
                      />
                    </dl>
                    <div className="mt-3">
                      <CapacityProgress
                        ratio={stockReady ? zone.metrics.occupancy : null}
                        over={stockReady && zone.metrics.overCapacity > 0}
                      />
                      <p className="mt-1 text-xs text-muted-foreground">
                        Utilization {stockReady ? formatPercent(zone.metrics.occupancy) : "—"}
                        {" · "}
                        Free {stockReady ? formatCases(zone.metrics.freePhysical) : "—"}
                      </p>
                    </div>
                  </>
                ) : (
                  <p className="mt-3 text-sm text-muted-foreground">
                    Not configured. Open this card to preview four empty crates. No zone
                    record is created.
                  </p>
                )}
                <p className="mt-3 text-sm font-medium">
                  {zone.configured ? "Open crates" : "Preview layout"}
                </p>
              </Link>
            </li>
          )
        })}
      </ul>
      {board && board.existing.length > 0 ? (
        <section className="mt-8">
          <h2 className="mb-3 text-sm font-semibold">Existing / other zones</h2>
          <ul className="grid gap-3 md:grid-cols-2">
            {board.existing.map((zone) => (
              <li key={zone.id}>
                <Link
                  to={`/godowns/${godownId}/zones/${zone.id}/crates`}
                  className={`${warehouseCardLinkClass} ${zone.quarantine ? "ring-orange-200 hover:ring-orange-300" : ""}`}
                  aria-label={`Open crates for ${zone.name}`}
                >
                  <div className="flex items-center justify-between gap-2">
                    <h3 className="font-medium">
                      {zone.name} · {zone.code}
                    </h3>
                    {zone.quarantine ? (
                      <StatusBadge tone="warning">Quarantine</StatusBadge>
                    ) : (
                      <StatusBadge tone="neutral">Storage</StatusBadge>
                    )}
                  </div>
                  <p className="mt-2 text-sm text-muted-foreground">
                    {zone.crateCount} crates ·{" "}
                    {!stockReady ? "stock unavailable" : formatCases(zone.metrics.onHand)}
                  </p>
                  <p className="mt-2 text-sm font-medium">Open crates</p>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
      {board && board.quarantineLocations.length > 0 ? (
        <section className="mt-8">
          <h2 className="mb-2 text-sm font-semibold">Existing quarantine locations</h2>
          <p className="mb-3 text-sm text-muted-foreground">
            These locations stay where they are recorded. They are not moved into Zone F.
          </p>
          <ul className="grid gap-2">
            {board.quarantineLocations.map((zone) => (
              <li key={zone.id}>
                <Link
                  to={`/godowns/${godownId}/zones/${zone.id}/crates`}
                  className={`${warehouseCardLinkClass} ring-orange-200 hover:ring-orange-300`}
                  aria-label={`Open quarantine crates for ${zone.code}`}
                >
                  {zone.name} ({zone.code}) ·{" "}
                  {stockReady
                    ? formatCases(zone.metrics.quarantineOnHand)
                    : "stock unavailable"}
                  <span className="mt-1 block text-sm font-medium">Open crates</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
      <Link to="/godowns" className="mt-6 inline-block text-sm font-medium">
        Back to godowns
      </Link>
    </section>
  )
}
