import { Link, useParams } from "react-router"
import { MapPinned } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { CASES_PER_CRATE, TARGET_CRATES_PER_ZONE } from "@/lib/warehouse/capacity"
import {
  plannedCrateCode,
  plannedZoneCratePath,
  plannedZonePath,
  TARGET_ZONES,
} from "@/lib/warehouse/layout"
import { godownZonesPath, locationSegment, matchLocation } from "@/lib/warehouse/paths"
import {
  WarehouseBackLink,
  WarehouseBreadcrumbs,
  warehouseCardLinkClass,
} from "@/features/administration/godowns/components/WarehouseChrome"
import { ReadableAddress } from "@/features/administration/godowns/ReadableAddress"
import { useWarehouseSnapshot } from "@/features/administration/godowns/use-warehouse"

/**
 * Read-only picture of a zone that has no database row.
 * The route key is A–F, never a branch, zone, or crate id.
 */
export function PlannedZonePreviewPage() {
  useDocumentTitle("Planned zone preview")
  const { godownId = "", zoneKey = "" } = useParams()
  const warehouse = useWarehouseSnapshot()
  const godowns = warehouse.ready?.godowns ?? []
  const godown = matchLocation(godowns, godownId)
  const godownKey = godown ? locationSegment(godown, godowns) : godownId
  const target = TARGET_ZONES.find((zone) => zone.key === zoneKey.toUpperCase())
  const zonesPath = godown ? godownZonesPath(godown, godowns) : `/godowns/${godownId}/zones`
  const canonical = godown && target ? plannedZonePath(godownKey, target.key) : null
  const slots = Array.from({ length: TARGET_CRATES_PER_ZONE }, (_, index) => index + 1)

  if (!target) {
    return (
      <section>
        <EmptyState
          icon={MapPinned}
          title="Planned zone not found"
          description="Planned zones are A through F. This address is not one of them."
        />
      </section>
    )
  }

  return (
    <section>
      <ReadableAddress to={canonical} />
      <WarehouseBreadcrumbs
        items={[
          { label: "Godowns", to: "/godowns" },
          { label: godown?.name ?? "Godown", to: zonesPath },
          { label: `${target.title} preview` },
        ]}
      />
      <PageHeader
        title={`${target.title} preview`}
        description="This zone is not configured. The four crates below are a layout preview and are not operational storage."
        action={
          <WarehouseBackLink to={zonesPath} label="Back to zones" />
        }
      />
      <div className="mb-4 flex flex-wrap gap-2">
        <StatusBadge tone="neutral">Not configured</StatusBadge>
        <StatusBadge tone="info">Preview only</StatusBadge>
        <StatusBadge tone={target.key === "F" ? "warning" : "neutral"}>
          {target.classification}
        </StatusBadge>
      </div>
      <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {slots.map((slot) => {
          const code = plannedCrateCode(target.key, slot)
          return (
            <li key={slot}>
              <Link
                to={plannedZoneCratePath(godownKey, target.key, slot)}
                className={`${warehouseCardLinkClass} ${target.key === "F" ? "ring-orange-200 hover:ring-orange-300" : ""}`}
                aria-label={`Preview ${code}, not configured`}
              >
                <div className="flex items-center justify-between gap-2">
                  <h2 className="font-medium">Crate {String(slot).padStart(2, "0")}</h2>
                  <StatusBadge tone="neutral">Not configured</StatusBadge>
                </div>
                <p className="mt-2 text-sm">{code}</p>
                <p className="mt-1 text-xs text-muted-foreground">Preview only</p>
                <p className="mt-3 text-sm text-muted-foreground">
                  Capacity: {CASES_PER_CRATE} cases
                </p>
                <p className="text-sm text-muted-foreground">Preview occupancy: 0/50</p>
              </Link>
            </li>
          )
        })}
      </ul>
      <Link
        to={zonesPath}
        className="mt-4 inline-block text-sm font-medium"
      >
        Back to zones
      </Link>
    </section>
  )
}
