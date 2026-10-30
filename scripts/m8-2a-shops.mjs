/**
 * M8.2A shop and sales-route source.
 * Shop names come from the three owner screenshots. Tom/Liju/Arun are not mapped.
 */
export { SOURCE_ENTRIES, ROUTE_COUNTS } from "./m8-2a-extracted.mjs"

export const CATALOGUE_VERSION = "m8.2a"

export function normalizeShopName(raw) {
  return String(raw ?? "")
    .replace(/\u00a0/g, " ")
    .trim()
    .replace(/[ \t]+/g, " ")
}

export function proposedShopKey(routeArea, originalShopName) {
  return `${normalizeShopName(routeArea).toLowerCase()}::${normalizeShopName(originalShopName).toLowerCase()}`
}

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
]

export const SALES_ROUTES = EXPECTED_ROUTE_AREAS.map((row) => ({
  sourceCollection: row.sourceCollection,
  routeArea: row.routeArea,
  routeName: row.routeArea,
  sourceDay: row.sourceDay,
  expectedCount: row.expectedCount,
}))
