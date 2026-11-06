import { Link, useParams } from "react-router"
import { Boxes } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { formatCases, formatPercent } from "@/lib/warehouse/capacity"
import { matchTargetZone, plannedCrateCode, zonePreviewCratePath } from "@/lib/warehouse/layout"
import { buildCrateBoard } from "@/lib/warehouse/model"
import {
  Metric,
  WarehouseBackLink,
  WarehouseBreadcrumbs,
  warehouseCardLinkClass,
} from "@/features/administration/godowns/components/WarehouseChrome"
import { useWarehouseSnapshot } from "@/features/administration/godowns/use-warehouse"

export function ZoneCratesPage() {
  useDocumentTitle("Zone crates")
  const { godownId = "", zoneId = "" } = useParams()
  const warehouse = useWarehouseSnapshot()
  const board = warehouse.ready ? buildCrateBoard(warehouse.ready, zoneId) : null
  const stockBlocked = Boolean(warehouse.balances.error || warehouse.lots.error)
  const stockReady = warehouse.balances.isSuccess && warehouse.lots.isSuccess

  return (
    <section>
      <WarehouseBreadcrumbs
        items={[
          { label: "Godowns", to: "/godowns" },
          {
            label: board?.godown?.name ?? "Godown",
            to: `/godowns/${godownId}/zones`,
          },
          { label: board?.zone?.name ?? "Zone" },
        ]}
      />
      <PageHeader
        title={board?.zone ? `${board.zone.name} crates` : "Zone crates"}
        description="Four crate positions are the planned layout. Only an unambiguous code such as A-01 fills a numbered position. Every other crate stays in the existing list."
        action={
          <WarehouseBackLink to={`/godowns/${godownId}/zones`} label="Back to zones" />
        }
      />
      {warehouse.structureLoading ? <LoadingBlock label="Loading crates" /> : null}
      {board && !board.zone ? (
        <EmptyState
          icon={Boxes}
          title="Zone not found"
          description="This zone is not visible, or it is not configured."
        />
      ) : null}
      {board?.zone ? (
        <>
          {board.extra.length > 0 ? (
            <section className="mb-8">
              <h2 className="mb-3 text-sm font-semibold">Crates in this zone</h2>
              <ul className="grid gap-3 md:grid-cols-2">
                {board.extra.map(({ crate, metrics }) => {
                  const quarantine =
                    board.quarantine ||
                    metrics.quarantineOnHand > 0 ||
                    crate.location_role === "quarantine"
                  return (
                    <li key={crate.id}>
                      <Link
                        to={`/godowns/${godownId}/zones/${zoneId}/crates/${crate.id}`}
                        className={`${warehouseCardLinkClass} ${quarantine ? "ring-orange-200 hover:ring-orange-300" : ""}`}
                        aria-label={`Open capacity for ${crate.code}`}
                      >
                        <div className="flex items-center justify-between gap-2">
                          <h3 className="font-medium">
                            {crate.code}
                            {crate.name ? ` · ${crate.name}` : ""}
                          </h3>
                          <StatusBadge tone={quarantine ? "warning" : "neutral"}>
                            {quarantine ? "Quarantine" : "Storage"}
                          </StatusBadge>
                        </div>
                        <p className="mt-1 text-xs text-muted-foreground">
                          {board.zone?.name} · {board.zone?.code}
                        </p>
                        <dl className="mt-3 grid grid-cols-2 gap-2">
                          <Metric
                            label="Current stock"
                            value={
                              !stockReady
                                ? stockBlocked
                                  ? "Unavailable"
                                  : "…"
                                : formatCases(metrics.onHand)
                            }
                          />
                          <Metric label="Capacity" value={formatCases(metrics.configuredCapacity)} />
                          <Metric
                            label="Occupied positions"
                            value={
                              stockReady
                                ? `${Math.min(50, metrics.onHand)}/50`
                                : "—"
                            }
                          />
                          <Metric
                            label="Free capacity"
                            value={stockReady ? formatCases(metrics.freePhysical) : "—"}
                          />
                          <Metric
                            label="Occupancy"
                            value={stockReady ? formatPercent(metrics.occupancy) : "—"}
                          />
                        </dl>
                        {stockReady && metrics.overCapacity > 0 ? (
                          <p className="mt-2 text-xs text-amber-800">
                            Over capacity by {formatCases(metrics.overCapacity)}. Stock was
                            not changed.
                          </p>
                        ) : null}
                        <p className="mt-3 text-sm font-medium">Open capacity</p>
                      </Link>
                    </li>
                  )
                })}
              </ul>
            </section>
          ) : null}
          <h2 className="mb-3 text-sm font-semibold">Planned crate positions</h2>
          <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            {board.positions.map((position) => {
              const destination = position.crate
                ? `/godowns/${godownId}/zones/${zoneId}/crates/${position.crate.id}`
                : zonePreviewCratePath(godownId, zoneId, position.slot)
              const zoneKey = board.zone
                ? matchTargetZone({
                    code: board.zone.code,
                    locationRole: board.zone.location_role,
                  })
                : null
              const plannedCode = zoneKey
                ? plannedCrateCode(zoneKey, position.slot)
                : `Planned ${String(position.slot).padStart(2, "0")}`
              return (
                <li key={position.slot}>
                  <Link
                    to={destination}
                    className={warehouseCardLinkClass}
                    aria-label={
                      position.crate
                        ? `Open capacity for ${position.crate.code}`
                        : `Preview crate ${String(position.slot).padStart(2, "0")}, not configured`
                    }
                  >
                    <div className="flex items-center justify-between">
                      <h2 className="font-medium">
                        Crate {String(position.slot).padStart(2, "0")}
                      </h2>
                      <StatusBadge tone={position.crate ? "success" : "neutral"}>
                        {position.crate ? "Configured" : "Not configured"}
                      </StatusBadge>
                    </div>
                    {position.crate && position.metrics ? (
                      <>
                        <p className="mt-2 text-sm">
                          {position.crate.code}
                          {position.crate.name ? ` · ${position.crate.name}` : ""}
                        </p>
                        <dl className="mt-2 grid gap-1">
                          <Metric label="Zone" value={board.zone?.code ?? "—"} />
                          <Metric label="Role" value={position.crate.location_role ?? "—"} />
                          <Metric
                            label="Current stock"
                            value={
                              !stockReady
                                ? stockBlocked
                                  ? "Unavailable"
                                  : "…"
                                : formatCases(position.metrics.onHand)
                            }
                          />
                          <Metric
                            label="Capacity"
                            value={formatCases(position.metrics.configuredCapacity)}
                          />
                          <Metric
                            label="Free capacity"
                            value={
                              stockReady ? formatCases(position.metrics.freePhysical) : "—"
                            }
                          />
                          <Metric
                            label="Occupancy"
                            value={stockReady ? formatPercent(position.metrics.occupancy) : "—"}
                          />
                        </dl>
                      </>
                    ) : (
                      <>
                        <p className="mt-2 text-sm">{plannedCode}</p>
                        <p className="mt-1 text-xs text-muted-foreground">Preview only</p>
                        <p className="mt-3 text-sm text-muted-foreground">
                          Capacity: 50 cases
                        </p>
                        <p className="text-sm text-muted-foreground">
                          Preview occupancy: 0/50
                        </p>
                      </>
                    )}
                    <p className="mt-3 text-sm font-medium">
                      {position.crate ? "Open capacity" : "Preview capacity"}
                    </p>
                  </Link>
                </li>
              )
            })}
          </ul>
          <Link
            to={`/godowns/${godownId}/zones`}
            className="mt-6 inline-block text-sm font-medium"
          >
            Back to zones
          </Link>
        </>
      ) : null}
    </section>
  )
}
