import { useState } from "react"
import { Link, useParams } from "react-router"
import { Boxes } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { formatCases, formatPercent } from "@/lib/warehouse/capacity"
import { buildCrateDetail } from "@/lib/warehouse/model"
import { CaseCapacityGrid } from "@/features/administration/godowns/components/CaseCapacityGrid"
import { InventoryDetailsPanel } from "@/features/administration/godowns/components/InventoryDetailsPanel"
import {
  Metric,
  StockStatusLegend,
  WarehouseBackLink,
  WarehouseBreadcrumbs,
} from "@/features/administration/godowns/components/WarehouseChrome"
import { useWarehouseSnapshot } from "@/features/administration/godowns/use-warehouse"

export function CrateCapacityPage() {
  useDocumentTitle("Crate capacity")
  const { godownId = "", zoneId = "", crateId = "" } = useParams()
  const warehouse = useWarehouseSnapshot()
  const stockReady = warehouse.balances.isSuccess && warehouse.lots.isSuccess
  const detail =
    warehouse.ready && stockReady ? buildCrateDetail(warehouse.ready, crateId) : null
  const stockBlocked = Boolean(warehouse.balances.error || warehouse.lots.error)
  const [selected, setSelected] = useState<number | null>(1)
  const slot =
    detail?.visual.slots.find((row) => row.position === selected) ?? null

  return (
    <section>
      <WarehouseBreadcrumbs
        items={[
          { label: "Godowns", to: "/godowns" },
          {
            label: detail?.godown.name ?? "Godown",
            to: `/godowns/${godownId}/zones`,
          },
          {
            label: detail?.zone.name ?? "Zone",
            to: `/godowns/${godownId}/zones/${zoneId}/crates`,
          },
          { label: detail?.crate.code ?? "Crate" },
        ]}
      />
      <PageHeader
        title={detail ? `${detail.crate.code} capacity` : "Crate capacity"}
        description="Fifty positions show planned case capacity. They do not identify a uniquely tracked physical case, and selecting one does not move stock."
        action={
          <WarehouseBackLink
            to={`/godowns/${godownId}/zones/${zoneId}/crates`}
            label="Back to crates"
          />
        }
      />
      {warehouse.structureLoading || warehouse.balances.isLoading || warehouse.lots.isLoading ? (
        <LoadingBlock label="Loading capacity" />
      ) : null}
      {stockBlocked ? (
        <p role="alert" className="mb-3 text-sm text-destructive">
          Stock figures are unavailable, so the capacity grid is not shown.
        </p>
      ) : null}
      {warehouse.ready && stockReady && !detail ? (
        <EmptyState
          icon={Boxes}
          title="Crate not found"
          description="This crate is not configured or is not visible."
        />
      ) : null}
      {detail ? (
        <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
          <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200">
            <StockStatusLegend />
            <p className="my-3 text-sm text-muted-foreground">
              Visualized allocation — not physically mapped.
              {detail.quarantine
                ? " Quarantined stock is not available for normal picking."
                : ""}
            </p>
            {detail.visual.overflow > 0 ? (
              <p role="status" className="mb-3 text-sm text-amber-800">
                Over capacity. Capacity is 50 cases, occupied is{" "}
                {formatCases(detail.metrics.onHand)}, overflow is{" "}
                {formatCases(detail.visual.overflow)}, and free capacity is{" "}
                {formatCases(detail.metrics.freePhysical)}. The grid shows 50 positions.
                The extra cases stay in the contents list. Stock was not changed.
              </p>
            ) : null}
            <CaseCapacityGrid
              slots={detail.visual.slots}
              selected={selected}
              onSelect={setSelected}
            />
            <dl className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
              <Metric
                label="Capacity"
                value={formatCases(detail.metrics.configuredCapacity)}
              />
              <Metric
                label="Occupied"
                value={`${detail.metrics.onHand.toLocaleString("en-IN")}/${detail.metrics.configuredCapacity} cases`}
              />
              <Metric label="Overflow" value={formatCases(detail.visual.overflow)} />
              <Metric label="Free" value={formatCases(detail.metrics.freePhysical)} />
              <Metric
                label="Occupancy"
                value={formatPercent(detail.metrics.occupancy)}
              />
              <Metric label="Products" value={String(detail.metrics.productCount)} />
              <Metric label="Lots" value={String(detail.metrics.lotCount)} />
              <Metric
                label="Visible reserved"
                value={
                  detail.metrics.visibleReserved === null
                    ? "Unavailable"
                    : formatCases(detail.metrics.visibleReserved)
                }
              />
              <Metric
                label="Available to pick"
                value={
                  detail.metrics.availableToPick === null
                    ? "Unavailable"
                    : formatCases(detail.metrics.availableToPick)
                }
              />
            </dl>
            <Link
              to={`/godowns/${godownId}/zones/${zoneId}/crates`}
              className="mt-4 inline-block text-sm font-medium"
            >
              Back to crates
            </Link>
          </div>
          <InventoryDetailsPanel
            slot={slot}
            crateCode={detail.crate.code}
            zoneName={detail.zone.name}
            godownName={detail.godown.name}
            products={detail.products}
            lots={detail.lots}
            quarantine={detail.quarantine}
          />
        </div>
      ) : null}
    </section>
  )
}
