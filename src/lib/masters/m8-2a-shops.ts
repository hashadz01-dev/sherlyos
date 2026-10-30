/**
 * M8.2A shop-name invariants. Source lists are not in this file until the
 * four route screenshots are extracted. Matching never merges two areas by
 * name alone: PRIME in Thevara and PRIME in Kaloor stay distinct keys.
 */

export const SHOP_NAME_MAX = 160

export const EXPECTED_ROUTE_AREAS = [
  { sourceCollection: "SHEET_A", sourceDay: "monday", routeArea: "THEVARA", expectedCount: 42 },
  { sourceCollection: "SHEET_A", sourceDay: "tuesday", routeArea: "VYTTILA TOC H", expectedCount: 31 },
  { sourceCollection: "SHEET_A", sourceDay: "wednesday", routeArea: "NETTOOR, PANANGAD", expectedCount: 56 },
  { sourceCollection: "SHEET_A", sourceDay: "thursday", routeArea: "MANJUMMEL VENNALA", expectedCount: 38 },
  { sourceCollection: "SHEET_A", sourceDay: "friday", routeArea: "KARUKAPPALLY", expectedCount: 52 },
  { sourceCollection: "SHEET_A", sourceDay: "saturday", routeArea: "THRIPUNITHURA", expectedCount: 42 },
  { sourceCollection: "SHEET_B", sourceDay: "monday", routeArea: "PALARIVATTOM", expectedCount: 56 },
  { sourceCollection: "SHEET_B", sourceDay: "tuesday", routeArea: "KADAVANTHRA", expectedCount: 41 },
  { sourceCollection: "SHEET_B", sourceDay: "wednesday", routeArea: "KALOOR", expectedCount: 49 },
  { sourceCollection: "SHEET_B", sourceDay: "thursday", routeArea: "KALAMASSERY", expectedCount: 31 },
  { sourceCollection: "SHEET_B", sourceDay: "friday", routeArea: "KKD-1", expectedCount: 25 },
  { sourceCollection: "SHEET_B", sourceDay: "saturday", routeArea: "ERNAKULAM", expectedCount: 33 },
  { sourceCollection: "SHEET_B", sourceDay: "saturday", routeArea: "MARKET", expectedCount: 39 },
  { sourceCollection: "SHEET_C", sourceDay: null, routeArea: "CHULLIKKAL", expectedCount: 40 },
] as const

/** Sum of the 14 listed counts. The owner brief said 574; the listed counts add to 575. */
export const STATED_SOURCE_ENTRIES = 574

export const EXPECTED_SOURCE_ENTRIES = EXPECTED_ROUTE_AREAS.reduce(
  (sum, row) => sum + row.expectedCount,
  0,
)

/** Collapse runs of space only. Abbreviations such as K K D stay spaced. */
export function normalizeShopName(raw: string) {
  return String(raw ?? "")
    .replace(/\u00a0/g, " ")
    .trim()
    .replace(/[ \t]+/g, " ")
}

export function proposedShopKey(routeArea: string, originalShopName: string) {
  return `${normalizeShopName(routeArea).toLowerCase()}::${normalizeShopName(originalShopName).toLowerCase()}`
}

/**
 * A strong duplicate is the same proposed key already present as a shop.
 * Same name in a different route area is not a match.
 */
export function isAmbiguousGlobalNameMatch(
  candidateKey: string,
  existingKeys: Iterable<string>,
) {
  const [, name] = candidateKey.split("::")
  for (const existing of existingKeys) {
    const [area, existingName] = existing.split("::")
    if (existingName === name && `${area}::${existingName}` !== candidateKey) {
      return true
    }
  }
  return false
}
