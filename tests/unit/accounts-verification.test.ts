import { describe, expect, it } from "vitest"
import { navigationItems } from "@/app/navigation"
import {
  ACCOUNTS_ROLE_PERMISSIONS,
  ADMIN_ONLY_NAV_PATHS,
  canSeeNavigationItem,
  isNavigationPathActive,
  visibleNavigationItems,
} from "@/lib/access/navigation-visibility"
import {
  describeOrderLoadFailure,
  describeVerificationBlock,
  filterOrderQueueRows,
  orderRecordPath,
  paginateRows,
  readableSiteLabel,
  shouldShowNewOrderAction,
  SUBMITTED_SCOPE_LABEL,
  VERIFICATION_DEFAULT_STATUS_FILTER,
  verificationActionLabel,
  verificationQueueEmptyCopy,
  verificationStatusLabel,
} from "@/lib/orders/verification"

function accountsCan(permission: string) {
  return (ACCOUNTS_ROLE_PERMISSIONS as readonly string[]).includes(permission)
}

describe("Accounts verification navigation", () => {
  it("shows Order verification and hides Admin-only paths", () => {
    const visible = visibleNavigationItems(navigationItems, accountsCan)
    const paths = visible.map((item) => item.to)
    expect(paths).toContain("/orders/verification")
    expect(paths).toContain("/orders")
    expect(paths).toContain("/deliveries")
    expect(paths).toContain("/invoices")
    for (const path of ADMIN_ONLY_NAV_PATHS) {
      expect(paths).not.toContain(path)
    }
    expect(paths).not.toContain("/picking")
    expect(paths).not.toContain("/dispatch")
    expect(paths).not.toContain("/inventory/opening")
    expect(accountsCan("accounts.godowns.all")).toBe(true)
    expect(accountsCan("branches.access_all")).toBe(false)
    expect(accountsCan("employees.read")).toBe(false)
    expect(accountsCan("employees.manage")).toBe(false)
    expect(accountsCan("picking.execute")).toBe(false)
    expect(accountsCan("dispatch.confirm")).toBe(false)
    expect(accountsCan("stock.opening.post")).toBe(false)
    expect(accountsCan("stock.adjustment.post")).toBe(false)
  })

  it("does not treat hidden navigation as a substitute for route permission", () => {
    expect(
      navigationItems.find((item) => item.to === "/employees")?.permission,
    ).toBe("employees.read")
    expect(accountsCan("employees.read")).toBe(false)
    expect(
      canSeeNavigationItem(
        navigationItems.find((item) => item.to === "/orders/verification")!,
        accountsCan,
      ),
    ).toBe(true)
  })

  it("keeps Orders inactive on the verification queue path", () => {
    expect(isNavigationPathActive("/orders", "/orders/verification")).toBe(false)
    expect(isNavigationPathActive("/orders/verification", "/orders/verification")).toBe(true)
    expect(isNavigationPathActive("/orders/verification", "/orders/verification/abc")).toBe(true)
    expect(isNavigationPathActive("/orders", "/orders/verification/abc")).toBe(false)
    expect(isNavigationPathActive("/orders", "/orders/abc")).toBe(true)
  })
})

describe("verification queue helpers", () => {
  const rows = [
    {
      id: "a",
      order_number: "SO-20261030-000025",
      shop_id: "shop-1",
      branch_id: "g1",
      source: "salesperson",
      status: "submitted",
      submitted_at: "2026-10-30T13:19:03+00:00",
      created_at: "2026-10-30T13:11:49+00:00",
    },
    {
      id: "b",
      order_number: "SO-HIDDEN",
      shop_id: "shop-2",
      branch_id: "g2",
      source: "accounts",
      status: "submitted",
      submitted_at: "2026-10-30T14:00:00+00:00",
      created_at: "2026-10-30T14:00:00+00:00",
    },
  ]

  it("shows an authorized submitted order and hides other shops on search", () => {
    const shopName = new Map([
      ["shop-1", "Haritha Thevara"],
      ["shop-2", "Other Shop"],
    ])
    const branchName = new Map([
      ["g1", "Godown-1"],
      ["g2", "Godown-2"],
    ])
    const found = filterOrderQueueRows(rows, {
      search: "Haritha",
      shopId: "all",
      branchId: "all",
      shopName,
      branchName,
    })
    expect(found.map((row) => row.order_number)).toEqual(["SO-20261030-000025"])
    const byNumber = filterOrderQueueRows(rows, {
      search: "SO-20261030-000025",
      shopId: "all",
      branchId: "all",
      shopName,
      branchName,
    })
    expect(byNumber).toHaveLength(1)
    const unauthorizedScope = filterOrderQueueRows(rows, {
      search: "",
      shopId: "all",
      branchId: "g1",
      shopName,
      branchName,
    })
    expect(unauthorizedScope.map((row) => row.id)).toEqual(["a"])
  })

  it("paginates the filtered queue", () => {
    const many = Array.from({ length: 25 }, (_, index) => ({
      ...rows[0]!,
      id: `id-${index}`,
      order_number: `SO-${index}`,
    }))
    const page1 = paginateRows(many, 1, 20)
    expect(page1.rows).toHaveLength(20)
    expect(page1.total).toBe(25)
    expect(paginateRows(many, 2, 20).rows).toHaveLength(5)
  })

  it("labels submitted orders as awaiting verification", () => {
    expect(verificationStatusLabel("submitted")).toBe("Submitted / Awaiting Verification")
    expect(verificationActionLabel("submitted")).toBe("Review to verify")
    expect(SUBMITTED_SCOPE_LABEL).toBe("Submitted")
  })

  it("defaults Order verification to every Accounts-visible status so verified orders stay listed", () => {
    expect(VERIFICATION_DEFAULT_STATUS_FILTER).toBe("all")
    expect(verificationQueueEmptyCopy("all").title).toBe("No orders in verification")
    expect(verificationQueueEmptyCopy("verified").title).toBe("No verified orders")
  })

  it("opens verification rows on the verification detail path", () => {
    expect(orderRecordPath("verification", "ord-1")).toBe("/orders/verification/ord-1")
    expect(orderRecordPath("capture", "ord-1")).toBe("/orders/ord-1")
  })

  it("shows New Order only on the capture module with orders.capture", () => {
    expect(shouldShowNewOrderAction({ mode: "capture", canCapture: true })).toBe(true)
    expect(shouldShowNewOrderAction({ mode: "capture", canCapture: false })).toBe(false)
    expect(shouldShowNewOrderAction({ mode: "verification", canCapture: true })).toBe(false)
  })

  it("never displays a raw godown UUID", () => {
    expect(readableSiteLabel("Godown-1", "Godown")).toBe("Godown-1")
    expect(readableSiteLabel("a5728a9c-2f50-49f0-9b80-e2c2f72667ec", "Godown")).toBe("Godown")
    expect(readableSiteLabel(undefined, "Godown")).toBe("Godown")
  })
})

describe("verification blocked reasons", () => {
  it("does not block Accounts verification for a missing godown assignment", () => {
    const block = describeVerificationBlock({
      orderFound: true,
      canVerify: true,
      assignedBranchCount: 0,
    })
    expect(block.kind).toBe("eligible")
    expect(block.message).not.toMatch(/Godown-1/i)
  })

  it("does not mark a stock-blocked order as approved", () => {
    const block = describeVerificationBlock({
      orderFound: true,
      canVerify: true,
      assignedBranchCount: 1,
      orderBranchId: "g1",
      assignedBranchIds: ["g1"],
      availability: {
        reserves_stock: false,
        picking_operational: false,
        cutover_blockers: ["Lot-aware picking requires dual-write to be enabled."],
        lines: [
          {
            product_id: "p1",
            requested_cases: 2,
            on_hand_cases: 0,
            eligible_cases: 0,
            shortfall_cases: 2,
            eligible: false,
            blockers: ["Lot-aware picking requires dual-write to be enabled."],
          },
        ],
      },
    })
    expect(block.kind).toBe("blocked_by_cutover")
    expect(block.label).toBe("Blocked by Stock")
    expect(block.message).not.toMatch(/verified|approved/i)
  })

  it("maps unauthorized get_order to an access diagnostic", () => {
    const none = describeOrderLoadFailure({
      errorMessage: "not authorized",
      canVerify: true,
      assignedBranchCount: 0,
    })
    expect(none.kind).toBe("not_authorized")
    expect(none.message).not.toMatch(/Godown-1/i)
    const otherSite = describeOrderLoadFailure({
      errorMessage: "You do not have permission to do that.",
      canVerify: true,
      assignedBranchCount: 2,
    })
    expect(otherSite.kind).toBe("not_authorized")
    expect(otherSite.message).not.toMatch(/SO-/)
  })
})
