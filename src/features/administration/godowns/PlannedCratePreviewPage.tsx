import { useState } from "react"
import { Link, useParams } from "react-router"
import { Boxes } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { CASES_PER_CRATE, visualizeCaseSlots } from "@/lib/warehouse/capacity"
import {
  plannedCrateCode,
  plannedZoneCratePath,
  plannedZonePath,
  TARGET_ZONES,
} from "@/lib/warehouse/layout"
import {
  godownZonesPath,
  locationSegment,
  matchLocation,
  zoneCratesPath,
} from "@/lib/warehouse/paths"
import { CaseCapacityGrid } from "@/features/administration/godowns/components/CaseCapacityGrid"
import { InventoryDetailsPanel } from "@/features/administration/godowns/components/InventoryDetailsPanel"
import {
  Metric,
  StockStatusLegend,
  WarehouseBackLink,
  WarehouseBreadcrumbs,
} from "@/features/administration/godowns/components/WarehouseChrome"
import { ReadableAddress } from "@/features/administration/godowns/ReadableAddress"
import { useWarehouseSnapshot } from "@/features/administration/godowns/use-warehouse"

const previewSlots = visualizeCaseSlots({
  inactive: false,
  quarantine: false,
  onHand: 0,
  visibleReserved: 0,
  slices: [],
})

/**
 * Empty 50-position picture for a crate that does not exist.
 * No stock query is addressed with this slot number.
 */
export function PlannedCratePreviewPage() {
  useDocumentTitle("Planned crate preview")
  const { godownId = "", zoneKey = "", zoneId = "", slot = "" } = useParams()
  const warehouse = useWarehouseSnapshot()
  const godowns = warehouse.ready?.godowns ?? []
  const godown = matchLocation(godowns, godownId)
  const godownKey = godown ? locationSegment(godown, godowns) : godownId
  const zonesHere = godown
    ? (warehouse.ready?.zones ?? []).filter((zone) => zone.branch_id === godown.id)
    : []
  const slotNumber = Number(slot)
  const validSlot = slotNumber === 1 || slotNumber === 2 || slotNumber === 3 || slotNumber === 4
  const target = zoneKey
    ? TARGET_ZONES.find((zone) => zone.key === zoneKey.toUpperCase())
    : null
  const existingZone = zoneId ? matchLocation(zonesHere, zoneId) : null
  const zonesPath = godown ? godownZonesPath(godown, godowns) : `/godowns/${godownId}/zones`
  const canonical =
    godown && validSlot && target
      ? plannedZoneCratePath(godownKey, target.key, slotNumber)
      : godown && existingZone && validSlot
        ? `${zoneCratesPath(godown, godowns, existingZone, zonesHere)}/preview/${slotNumber}`
        : null
  const [selected, setSelected] = useState<number | null>(null)
  const selectedSlot = previewSlots.slots.find((row) => row.position === selected) ?? null

  if (!validSlot || (zoneKey && !target) || (zoneId && warehouse.ready && !existingZone)) {
    return (
      <section>
        <EmptyState
          icon={Boxes}
          title="Planned crate not found"
          description="Preview crates are positions 01 to 04 on a planned or existing zone. They are not stock locations."
        />
      </section>
    )
  }

  const code = target
    ? plannedCrateCode(target.key, slotNumber)
    : `Position ${String(slotNumber).padStart(2, "0")}`
  const zoneLabel = target?.title ?? existingZone?.name ?? "Zone"
  const backToCrates = target
    ? plannedZonePath(godownKey, target.key)
    : godown && existingZone
      ? zoneCratesPath(godown, godowns, existingZone, zonesHere)
      : `/godowns/${godownId}/zones/${zoneId}/crates`

  return (
    <section>
      <ReadableAddress to={canonical} />
      <WarehouseBreadcrumbs
        items={[
          { label: "Godowns", to: "/godowns" },
          { label: godown?.name ?? "Godown", to: zonesPath },
          { label: zoneLabel, to: backToCrates },
          { label: `${code} preview` },
        ]}
      />
      <PageHeader
        title={`${code} preview`}
        description="Fifty empty positions show planned capacity. This crate is not configured and holds no stock."
        action={<WarehouseBackLink to={backToCrates} label="Back to crates" />}
      />
      <div className="mb-4 flex flex-wrap gap-2">
        <StatusBadge tone="neutral">Not configured</StatusBadge>
        <StatusBadge tone="info">Preview only</StatusBadge>
        {target?.key === "F" ? <StatusBadge tone="warning">Quarantine layout</StatusBadge> : null}
      </div>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200">
          <StockStatusLegend />
          <p className="my-3 text-sm text-muted-foreground">
            Preview occupancy: 0/50. Visualized allocation — not physically mapped.
          </p>
          <CaseCapacityGrid
            slots={previewSlots.slots}
            selected={selected}
            onSelect={setSelected}
          />
          <dl className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
            <Metric label="Capacity" value={`${CASES_PER_CRATE} cases`} />
            <Metric label="Occupied" value="0/50 cases" />
            <Metric label="Free" value="50 cases" />
            <Metric label="Occupancy" value="0%" />
          </dl>
          <Link to={backToCrates} className="mt-4 inline-block text-sm font-medium">
            Back to crates
          </Link>
        </div>
        <InventoryDetailsPanel
          slot={selectedSlot}
          crateCode={code}
          zoneName={zoneLabel}
          godownName={godown?.name ?? "Godown"}
          products={[]}
          lots={[]}
          quarantine={target?.key === "F"}
        />
      </div>
    </section>
  )
}
