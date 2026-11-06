import type { StockBalance, StockLotBalance } from "@/lib/inventory/api"
import {
  availableToPick,
  CASES_PER_CRATE,
  configuredCapacityFromCrates,
  freePhysicalCapacity,
  isQuarantineRole,
  occupancyRatio,
  overCapacityCases,
  PLANNED_GODOWN_CAPACITY,
  PLANNED_ZONE_CAPACITY,
  SALEABLE_HOLD_KINDS,
  TARGET_CRATES_PER_ZONE,
  visualizeCaseSlots,
  type CapacitySlice,
} from "@/lib/warehouse/capacity"
import {
  godownClassification,
  matchTargetCrate,
  matchTargetZone,
  TARGET_ZONES,
  type GodownClassification,
} from "@/lib/warehouse/layout"
import type {
  VisibleHold,
  VisibleReservation,
  WarehouseCrate,
  WarehouseZone,
} from "@/lib/warehouse/api"

export type GodownRecord = {
  id: string
  code: string
  name: string
  is_active: boolean
}

export type WarehouseSnapshot = {
  godowns: GodownRecord[]
  zones: WarehouseZone[]
  crates: WarehouseCrate[]
  balances: StockBalance[]
  lots: StockLotBalance[]
  reservations: VisibleReservation[]
  holds: VisibleHold[]
  reservationsVisible: boolean
  holdsVisible: boolean
}

function crateRole(crate: WarehouseCrate, zone: WarehouseZone | undefined) {
  if (isQuarantineRole(crate.location_role) || isQuarantineRole(zone?.location_role)) {
    return "quarantine" as const
  }
  return "storage" as const
}

function linesForCrates(
  snapshot: WarehouseSnapshot,
  crateIds: Set<string>,
) {
  return snapshot.balances.filter((row) => crateIds.has(row.crate_id) && row.quantity > 0)
}

function lotsForCrates(snapshot: WarehouseSnapshot, crateIds: Set<string>) {
  return snapshot.lots.filter((row) => crateIds.has(row.crate_id) && row.quantity > 0)
}

function reservedForCrates(snapshot: WarehouseSnapshot, crateIds: Set<string>) {
  return snapshot.reservations
    .filter((row) => crateIds.has(row.crate_id))
    .reduce((sum, row) => sum + Number(row.reserved_cases || 0), 0)
}

function saleableHoldsForCrates(snapshot: WarehouseSnapshot, crateIds: Set<string>) {
  return snapshot.holds
    .filter(
      (row) =>
        crateIds.has(row.crate_id) &&
        row.status === "active" &&
        (SALEABLE_HOLD_KINDS as readonly string[]).includes(row.hold_kind),
    )
    .reduce((sum, row) => sum + Number(row.quantity_cases || 0), 0)
}

export type LocationMetrics = {
  onHand: number
  saleableOnHand: number
  quarantineOnHand: number
  productCount: number
  lotCount: number
  visibleReserved: number | null
  visibleSaleableHolds: number | null
  availableToPick: number | null
  configuredCrates: number
  configuredCapacity: number
  plannedCapacity: number
  freePhysical: number | null
  overCapacity: number
  occupancy: number | null
}

export function metricsForCrates(
  snapshot: WarehouseSnapshot,
  crates: WarehouseCrate[],
  zonesById: Map<string, WarehouseZone>,
  plannedCapacity: number,
): LocationMetrics {
  const crateIds = new Set(crates.map((crate) => crate.id))
  const lines = linesForCrates(snapshot, crateIds)
  let saleableOnHand = 0
  let quarantineOnHand = 0
  for (const line of lines) {
    const crate = crates.find((row) => row.id === line.crate_id)
    const role = crate
      ? crateRole(crate, zonesById.get(crate.zone_id))
      : "storage"
    if (role === "quarantine") quarantineOnHand += line.quantity
    else saleableOnHand += line.quantity
  }
  const onHand = saleableOnHand + quarantineOnHand
  const products = new Set(lines.map((line) => line.product_id))
  const lots = lotsForCrates(snapshot, crateIds)
  const capacity = configuredCapacityFromCrates(crates)
  const visibleReserved = snapshot.reservationsVisible
    ? reservedForCrates(snapshot, crateIds)
    : null
  const visibleSaleableHolds = snapshot.holdsVisible
    ? saleableHoldsForCrates(snapshot, crateIds)
    : null
  return {
    onHand,
    saleableOnHand,
    quarantineOnHand,
    productCount: products.size,
    lotCount: new Set(lots.map((lot) => lot.lot_id)).size,
    visibleReserved,
    visibleSaleableHolds,
    availableToPick:
      visibleReserved === null || visibleSaleableHolds === null
        ? null
        : availableToPick({
            saleableOnHand,
            visibleReserved,
            visibleSaleableHolds,
          }),
    configuredCrates: crates.length,
    configuredCapacity: capacity,
    plannedCapacity,
    freePhysical: freePhysicalCapacity(onHand, capacity),
    overCapacity: overCapacityCases(onHand, capacity),
    occupancy: occupancyRatio(onHand, capacity),
  }
}

export type GodownCardModel = {
  id: string
  code: string
  name: string
  active: boolean
  classification: GodownClassification
  zoneCount: number
  crateCount: number
  metrics: LocationMetrics
}

export function buildGodownCards(snapshot: WarehouseSnapshot): GodownCardModel[] {
  const zonesById = new Map(snapshot.zones.map((zone) => [zone.id, zone]))
  return [...snapshot.godowns]
    .sort((left, right) => left.name.localeCompare(right.name))
    .map((godown) => {
      const zones = snapshot.zones.filter((zone) => zone.branch_id === godown.id)
      const zoneIds = new Set(zones.map((zone) => zone.id))
      const crates = snapshot.crates.filter((crate) => zoneIds.has(crate.zone_id))
      return {
        id: godown.id,
        code: godown.code,
        name: godown.name,
        active: godown.is_active,
        classification: godownClassification(godown.code),
        zoneCount: zones.length,
        crateCount: crates.length,
        metrics: metricsForCrates(
          snapshot,
          crates,
          zonesById,
          PLANNED_GODOWN_CAPACITY,
        ),
      }
    })
}

export type ZoneCardModel = {
  id: string | null
  key: string
  title: string
  classification: string
  configured: boolean
  quarantine: boolean
  crateCount: number
  metrics: LocationMetrics | null
}

export function buildZoneBoard(snapshot: WarehouseSnapshot, godownId: string) {
  const godown = snapshot.godowns.find((row) => row.id === godownId) ?? null
  const zones = snapshot.zones.filter((zone) => zone.branch_id === godownId)
  const zonesById = new Map(snapshot.zones.map((zone) => [zone.id, zone]))
  const matched = new Map<string, WarehouseZone>()
  const other: WarehouseZone[] = []
  for (const zone of zones) {
    const key = matchTargetZone({
      code: zone.code,
      locationRole: zone.location_role,
    })
    if (key && !matched.has(key)) matched.set(key, zone)
    else other.push(zone)
  }
  const targets: ZoneCardModel[] = TARGET_ZONES.map((target) => {
    const zone = matched.get(target.key)
    if (!zone) {
      return {
        id: null,
        key: target.key,
        title: target.title,
        classification: target.classification,
        configured: false,
        quarantine: target.key === "F",
        crateCount: 0,
        metrics: null,
      }
    }
    const crates = snapshot.crates.filter((crate) => crate.zone_id === zone.id)
    return {
      id: zone.id,
      key: target.key,
      title: `${target.title} · ${zone.name}`,
      classification: target.classification,
      configured: true,
      quarantine: target.key === "F",
      crateCount: crates.length,
      metrics: metricsForCrates(snapshot, crates, zonesById, PLANNED_ZONE_CAPACITY),
    }
  })
  const existing = other.map((zone) => {
    const crates = snapshot.crates.filter((crate) => crate.zone_id === zone.id)
    const quarantine =
      isQuarantineRole(zone.location_role) ||
      crates.some((crate) => isQuarantineRole(crate.location_role))
    return {
      id: zone.id,
      code: zone.code,
      name: zone.name,
      active: zone.is_active,
      quarantine,
      crateCount: crates.length,
      metrics: metricsForCrates(snapshot, crates, zonesById, PLANNED_ZONE_CAPACITY),
    }
  })
  const quarantineLocations = existing.filter((zone) => zone.quarantine)
  return {
    godown: godown
      ? {
          ...godown,
          classification: godownClassification(godown.code),
        }
      : null,
    targets,
    existing,
    quarantineLocations,
  }
}

export function buildCrateBoard(snapshot: WarehouseSnapshot, zoneId: string) {
  const zone = snapshot.zones.find((row) => row.id === zoneId) ?? null
  const godown = zone
    ? (snapshot.godowns.find((row) => row.id === zone.branch_id) ?? null)
    : null
  const zonesById = new Map(snapshot.zones.map((row) => [row.id, row]))
  const crates = snapshot.crates.filter((crate) => crate.zone_id === zoneId)
  const zoneKey = zone
    ? matchTargetZone({ code: zone.code, locationRole: zone.location_role })
    : null
  const bySlot = new Map<number, WarehouseCrate>()
  const extra: WarehouseCrate[] = []
  for (const crate of crates) {
    const slot = matchTargetCrate({ zoneKey, crateCode: crate.code })
    if (slot && !bySlot.has(slot)) bySlot.set(slot, crate)
    else extra.push(crate)
  }
  const positions = [1, 2, 3, 4].map((slot) => {
    const crate = bySlot.get(slot) ?? null
    return {
      slot,
      crate,
      metrics: crate
        ? metricsForCrates(snapshot, [crate], zonesById, CASES_PER_CRATE)
        : null,
    }
  })
  return {
    godown: godown
      ? { ...godown, classification: godownClassification(godown.code) }
      : null,
    zone,
    quarantine: zone ? isQuarantineRole(zone.location_role) : false,
    positions,
    extra: extra.map((crate) => ({
      crate,
      metrics: metricsForCrates(snapshot, [crate], zonesById, CASES_PER_CRATE),
    })),
    targetCount: TARGET_CRATES_PER_ZONE,
  }
}

export function buildCrateDetail(snapshot: WarehouseSnapshot, crateId: string) {
  const crate = snapshot.crates.find((row) => row.id === crateId) ?? null
  const zone = crate
    ? (snapshot.zones.find((row) => row.id === crate.zone_id) ?? null)
    : null
  const godown = zone
    ? (snapshot.godowns.find((row) => row.id === zone.branch_id) ?? null)
    : null
  if (!crate || !zone || !godown) return null
  const zonesById = new Map(snapshot.zones.map((row) => [row.id, row]))
  const quarantine = crateRole(crate, zone) === "quarantine"
  const metrics = metricsForCrates(snapshot, [crate], zonesById, CASES_PER_CRATE)
  const productLines = linesForCrates(snapshot, new Set([crate.id]))
  const lotLines = lotsForCrates(snapshot, new Set([crate.id]))
  const lotSlices: CapacitySlice[] = lotLines.map((lot) => ({
    sku: lot.product_sku,
    productName: lot.product_name,
    lotId: lot.lot_id,
    lotCode: lot.manufacturer_lot_code,
    expiryDate: lot.expiry_date,
    quantity: lot.quantity,
  }))
  const productSlices: CapacitySlice[] = productLines.map((line) => ({
    sku: line.product_sku,
    productName: line.product_name,
    lotId: null,
    lotCode: null,
    expiryDate: null,
    quantity: line.quantity,
  }))
  const slices = lotSlices.length > 0 ? lotSlices : productSlices
  const visual = visualizeCaseSlots({
    inactive: !crate.is_active,
    quarantine,
    onHand: metrics.onHand,
    visibleReserved: metrics.visibleReserved ?? 0,
    slices,
  })
  return {
    godown: { ...godown, classification: godownClassification(godown.code) },
    zone,
    crate,
    quarantine,
    metrics,
    products: productLines,
    lots: lotLines,
    visual,
  }
}
