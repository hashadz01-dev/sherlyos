import {
  isQuarantineRole,
  TARGET_ZONE_KEYS,
  type TargetZoneKey,
} from "@/lib/warehouse/capacity"

/** Presentation only. Godown-7 is not given different stock rules. */
export const RESERVE_GODOWN_CODE = "gd_7"

export type GodownClassification = "Normal" | "Reserve"

export function godownClassification(code: string): GodownClassification {
  return code.trim().toLowerCase() === RESERVE_GODOWN_CODE ? "Reserve" : "Normal"
}

export const TARGET_ZONES: {
  key: TargetZoneKey
  title: string
  classification: "Normal storage" | "Quarantine"
}[] = [
  { key: "A", title: "Zone A", classification: "Normal storage" },
  { key: "B", title: "Zone B", classification: "Normal storage" },
  { key: "C", title: "Zone C", classification: "Normal storage" },
  { key: "D", title: "Zone D", classification: "Normal storage" },
  { key: "E", title: "Zone E", classification: "Normal storage" },
  { key: "F", title: "Zone F", classification: "Quarantine" },
]

/**
 * Map a stored zone onto A–F only when the code and role agree.
 * Codes such as QRN or uat_z1 stay in the existing-zone list.
 */
export function matchTargetZone(zone: {
  code: string
  locationRole: string | null
}): TargetZoneKey | null {
  const compact = zone.code.trim().toUpperCase().replace(/[\s_-]+/g, "")
  const key = TARGET_ZONE_KEYS.find(
    (candidate) => compact === candidate || compact === `ZONE${candidate}`,
  )
  if (!key) return null
  const quarantine = isQuarantineRole(zone.locationRole)
  if (key === "F") return quarantine ? "F" : null
  return quarantine ? null : key
}

/**
 * A crate fills a numbered 1–4 position only inside an already matched A–F zone
 * and only when its code names that zone and slot, for example A-01.
 */
/** Preview routes never use a database id, so they cannot be posted as stock locations. */
export function plannedZonePath(godownId: string, zoneKey: string) {
  return `/godowns/${godownId}/zones/planned/${zoneKey}`
}

export function plannedZoneCratePath(
  godownId: string,
  zoneKey: string,
  slot: number,
) {
  return `/godowns/${godownId}/zones/planned/${zoneKey}/crates/${slot}`
}

export function zonePreviewCratePath(
  godownId: string,
  zoneId: string,
  slot: number,
) {
  return `/godowns/${godownId}/zones/${zoneId}/crates/preview/${slot}`
}

export function plannedCrateCode(zoneKey: string, slot: number) {
  return `${zoneKey}-${String(slot).padStart(2, "0")}`
}

export function matchTargetCrate(input: {
  zoneKey: TargetZoneKey | null
  crateCode: string
}): 1 | 2 | 3 | 4 | null {
  if (!input.zoneKey) return null
  const match = input.crateCode
    .trim()
    .toUpperCase()
    .match(new RegExp(`^ZONE${input.zoneKey}-0([1-4])$|^${input.zoneKey}-0([1-4])$`))
  const slot = Number(match?.[1] ?? match?.[2])
  if (slot === 1 || slot === 2 || slot === 3 || slot === 4) return slot
  return null
}
