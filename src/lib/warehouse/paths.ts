/**
 * Warehouse addresses use the codes people already see (gd_1, A, A-01).
 * An id still resolves, then the address bar is replaced with the code path,
 * so an old link and a readable link open the same screen.
 */

export type CodedLocation = {
  id: string
  code: string
}

const RESERVED_SEGMENTS = new Set(["planned", "preview"])

/** A code that would break the route or collide with a sibling stays an id. */
export function locationSegment(record: CodedLocation, peers: CodedLocation[]) {
  const code = record.code.trim()
  const ambiguous =
    peers.filter((peer) => peer.code.trim().toLowerCase() === code.toLowerCase()).length > 1
  if (
    !code ||
    ambiguous ||
    RESERVED_SEGMENTS.has(code.toLowerCase()) ||
    /[/?#\\%]/.test(code)
  ) {
    return record.id
  }
  return encodeURIComponent(code)
}

export function matchLocation<T extends CodedLocation>(records: T[], segment: string) {
  let key = segment.trim()
  try {
    key = decodeURIComponent(key).trim()
  } catch {
    // A malformed escape is compared as typed.
  }
  const byId = records.find((row) => row.id === key)
  if (byId) return byId
  const matches = records.filter((row) => row.code.trim().toLowerCase() === key.toLowerCase())
  return matches.length === 1 ? matches[0] : null
}

export function godownZonesPath(godown: CodedLocation, godowns: CodedLocation[]) {
  return `/godowns/${locationSegment(godown, godowns)}/zones`
}

export function zoneCratesPath(
  godown: CodedLocation,
  godowns: CodedLocation[],
  zone: CodedLocation,
  zonesInGodown: CodedLocation[],
) {
  return `/godowns/${locationSegment(godown, godowns)}/zones/${locationSegment(zone, zonesInGodown)}/crates`
}

export function crateCapacityPath(
  godown: CodedLocation,
  godowns: CodedLocation[],
  zone: CodedLocation,
  zonesInGodown: CodedLocation[],
  crate: CodedLocation,
  cratesInZone: CodedLocation[],
) {
  return `${zoneCratesPath(godown, godowns, zone, zonesInGodown)}/${locationSegment(crate, cratesInZone)}`
}
