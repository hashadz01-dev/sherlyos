import { matchesSearch, matchesStatus } from "@/lib/masters/filters"

/**
 * Geographic sales-visit routes confirmed by the owner. These are not
 * salesperson collections and are not godown pick-face zones.
 */
export const SALES_ROUTE_CATALOG = [
  { code: "thevara", name: "Thevara", weekday: "monday", sourceSheet: "SHEET_A" },
  { code: "vyttila", name: "Vyttila", weekday: "tuesday", sourceSheet: "SHEET_A" },
  { code: "nettoor-panangad", name: "Nettoor / Panangad", weekday: "wednesday", sourceSheet: "SHEET_A" },
  { code: "manjummel-vennala", name: "Manjummel / Vennala", weekday: "thursday", sourceSheet: "SHEET_A" },
  { code: "karukappally", name: "Karukappally", weekday: "friday", sourceSheet: "SHEET_A" },
  { code: "thripunithura", name: "Thripunithura", weekday: "saturday", sourceSheet: "SHEET_A" },
  { code: "palarivattom", name: "Palarivattom", weekday: "monday", sourceSheet: "SHEET_B" },
  { code: "kadavanthra", name: "Kadavanthra", weekday: "tuesday", sourceSheet: "SHEET_B" },
  { code: "kaloor", name: "Kaloor", weekday: "wednesday", sourceSheet: "SHEET_B" },
  { code: "kalamassery", name: "Kalamassery", weekday: "thursday", sourceSheet: "SHEET_B" },
  { code: "kkd-1", name: "KKD-1", weekday: "friday", sourceSheet: "SHEET_B" },
  { code: "ernakulam", name: "Ernakulam", weekday: "saturday", sourceSheet: "SHEET_B" },
  { code: "market", name: "Market", weekday: "saturday", sourceSheet: "SHEET_B" },
  { code: "chullikkal", name: "Chullikkal", weekday: null, sourceSheet: "SHEET_C" },
] as const

export const WEEKDAYS = [
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
  "saturday",
] as const

export type SalesWeekday = (typeof WEEKDAYS)[number]

export type ShopListRow = {
  id: string
  name: string
  phone: string | null
  address: string | null
  is_active: boolean
}

export type SalesRouteRow = {
  id: string
  code: string
  name: string
  weekday: string | null
  sort_order: number
  is_active: boolean
}

export type ShopRouteMembership = {
  shop_id: string
  route_id: string
  visit_sequence: number
}

export type ShopRouteGroup = {
  routeId: string
  routeCode: string
  routeName: string
  weekday: string | null
  weekdayLabel: string
  shopCount: number
  shops: Array<ShopListRow & { visitSequence: number | null; memberships: ShopRouteMembership[] }>
}

/** Title-case a weekday, or mark Chullikkal until the owner confirms a day. */
export function weekdayLabel(day: string | null | undefined) {
  if (!day) return "Weekday unconfirmed"
  return day.charAt(0).toUpperCase() + day.slice(1)
}

export function catalogRoutesAsRows(): SalesRouteRow[] {
  return SALES_ROUTE_CATALOG.map((route, index) => ({
    id: route.code,
    code: route.code,
    name: route.name,
    weekday: route.weekday,
    sort_order: index + 1,
    is_active: true,
  }))
}

/**
 * Filter the authorized shop set, then group by geographic route. Shops with
 * no membership stay under Unassigned. Default route filter is all shops.
 */
export function groupShopsByRoute(args: {
  shops: ShopListRow[]
  routes: SalesRouteRow[]
  memberships: ShopRouteMembership[]
  search: string
  status: string
  routeId: string
  weekday: string
}): ShopRouteGroup[] {
  const membershipsByShop = new Map<string, ShopRouteMembership[]>()
  for (const row of args.memberships) {
    const list = membershipsByShop.get(row.shop_id) ?? []
    list.push(row)
    membershipsByShop.set(row.shop_id, list)
  }

  const visibleShops = args.shops.filter(
    (shop) =>
      matchesSearch(args.search, [shop.name, shop.phone, shop.address]) &&
      matchesStatus(args.status, shop.is_active),
  )

  const routeById = new Map(args.routes.map((route) => [route.id, route]))

  function shopOnWeekday(shopId: string) {
    if (args.weekday === "all" || args.weekday === "") return true
    const rows = membershipsByShop.get(shopId) ?? []
    if (args.weekday === "unassigned") {
      return rows.some((row) => routeById.get(row.route_id)?.weekday == null)
    }
    return rows.some((row) => routeById.get(row.route_id)?.weekday === args.weekday)
  }

  function shopOnRoute(shopId: string) {
    if (args.routeId === "all" || args.routeId === "") return true
    return (membershipsByShop.get(shopId) ?? []).some((row) => row.route_id === args.routeId)
  }

  const shops = visibleShops.filter((shop) => shopOnWeekday(shop.id) && shopOnRoute(shop.id))

  const groups: ShopRouteGroup[] = args.routes
    .slice()
    .sort((left, right) => left.sort_order - right.sort_order)
    .filter((route) => args.routeId === "all" || args.routeId === "" || route.id === args.routeId)
    .filter((route) => {
      if (args.weekday === "all" || args.weekday === "") return true
      if (args.weekday === "unassigned") return route.weekday == null
      return route.weekday === args.weekday
    })
    .map((route) => {
      const routeShops = shops
        .map((shop) => {
          const memberships = membershipsByShop.get(shop.id) ?? []
          const match = memberships.find((row) => row.route_id === route.id)
          return { shop, match, memberships }
        })
        .filter((row) => row.match)
        .sort((left, right) => {
          const sequence = (left.match?.visit_sequence ?? 0) - (right.match?.visit_sequence ?? 0)
          if (sequence !== 0) return sequence
          return left.shop.name.localeCompare(right.shop.name)
        })
        .map((row) => ({
          ...row.shop,
          visitSequence: row.match?.visit_sequence ?? null,
          memberships: row.memberships,
        }))
      return {
        routeId: route.id,
        routeCode: route.code,
        routeName: route.name,
        weekday: route.weekday,
        weekdayLabel: weekdayLabel(route.weekday),
        shopCount: routeShops.length,
        shops: routeShops,
      }
    })

  const showUnassigned =
    (args.routeId === "all" || args.routeId === "" || args.routeId === "unassigned") &&
    (args.weekday === "all" || args.weekday === "")

  if (showUnassigned) {
    const unassigned = shops
      .filter((shop) => (membershipsByShop.get(shop.id) ?? []).length === 0)
      .sort((left, right) => left.name.localeCompare(right.name))
      .map((shop) => ({ ...shop, visitSequence: null, memberships: [] as ShopRouteMembership[] }))
    if (unassigned.length > 0 || args.routeId === "unassigned") {
      groups.push({
        routeId: "unassigned",
        routeCode: "unassigned",
        routeName: "Unassigned route",
        weekday: null,
        weekdayLabel: "No visit day",
        shopCount: unassigned.length,
        shops: unassigned,
      })
    }
  }

  return args.routeId === "all" || args.routeId === ""
    ? groups.filter((group) => group.shopCount > 0 || group.routeId === "unassigned")
    : groups
}

export function nextVisitSequence(memberships: ShopRouteMembership[], routeId: string) {
  const used = memberships
    .filter((row) => row.route_id === routeId)
    .map((row) => row.visit_sequence)
  return (used.length === 0 ? 0 : Math.max(...used)) + 1
}
