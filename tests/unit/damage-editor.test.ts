import { describe, expect, it } from "vitest"
import {
  clearCreateIdempotencyKey,
  createIdempotencyKey,
  lineGrain,
  parseCartonQuantity,
  sourceRefsForScenario,
  submitIdempotencyKey,
  validateDraftLines,
  type DraftLine,
} from "@/features/damage/utils/draft"
import {
  collectSubmitBlockers,
  mapDamageMutationError,
  scenarioSubmitHint,
} from "@/features/damage/utils/submit"
import {
  canOpenDamageCreate,
  isSupportedDamagePhotoMime,
  scenariosAvailableForPermissions,
} from "@/lib/damage/rules"

function line(partial: Partial<DraftLine> = {}): DraftLine {
  return {
    key: "k1",
    product_id: "p1",
    product_sku: "SKU",
    product_name: "Item",
    quantity_cases: "2",
    damage_reason: "crushed",
    crate_id: "c1",
    crate_code: "C1",
    lot_id: "",
    notes: "",
    receipt_line_id: "",
    ...partial,
  }
}

describe("damage scenario availability", () => {
  it("gives Godown Manager all six scenarios", () => {
    const can = (permission: string) =>
      [
        "damage.record",
        "damage.verify",
        "receiving.execute",
        "loading.assist",
      ].includes(permission)
    expect(scenariosAvailableForPermissions(can)).toEqual([
      "refill_supply",
      "unloading",
      "storage",
      "loading",
      "transit",
      "shop_return",
    ])
  })

  it("limits Store Keeper to inbound and loading", () => {
    const can = (permission: string) =>
      ["damage.record", "receiving.execute", "loading.assist"].includes(
        permission,
      )
    expect(scenariosAvailableForPermissions(can)).toEqual([
      "refill_supply",
      "unloading",
      "loading",
      "transit",
    ])
  })

  it("limits Delivery Person to transit and denies general create for admin monitors", () => {
    const driver = (permission: string) => permission === "deliveries.execute"
    expect(scenariosAvailableForPermissions(driver)).toEqual(["transit"])
    expect(canOpenDamageCreate(driver)).toBe(true)
    const admin = (permission: string) =>
      permission === "operations.monitor" || permission === "damage.read"
    expect(scenariosAvailableForPermissions(admin)).toEqual([])
    expect(canOpenDamageCreate(admin)).toBe(false)
  })
})

describe("damage source mapping", () => {
  const catalog = {
    id: "dispatch-1",
    receipt_id: "receipt-1",
    picking_request_id: "picking-1",
    dispatch_id: "dispatch-1",
    order_id: "order-1",
    shop_id: "shop-1",
  }

  it("posts only the document id each scenario may keep", () => {
    expect(sourceRefsForScenario("refill_supply", catalog)).toEqual({
      receiptId: "receipt-1",
      pickingRequestId: null,
      dispatchId: null,
      orderId: null,
      shopId: null,
    })
    expect(sourceRefsForScenario("transit", catalog)).toEqual({
      receiptId: null,
      pickingRequestId: null,
      dispatchId: "dispatch-1",
      orderId: null,
      shopId: null,
    })
    expect(sourceRefsForScenario("loading", catalog)).toEqual({
      receiptId: null,
      pickingRequestId: "picking-1",
      dispatchId: "dispatch-1",
      orderId: null,
      shopId: null,
    })
    expect(sourceRefsForScenario("storage", catalog)).toEqual({
      receiptId: null,
      pickingRequestId: null,
      dispatchId: null,
      orderId: null,
      shopId: null,
    })
    expect(sourceRefsForScenario("shop_return", catalog)).toEqual({
      receiptId: null,
      pickingRequestId: null,
      dispatchId: null,
      orderId: "order-1",
      shopId: "shop-1",
    })
  })
})

describe("damage idempotency keys", () => {
  it("reuses a durable create key across refresh-like reads", () => {
    clearCreateIdempotencyKey("user-a")
    const first = createIdempotencyKey("user-a")
    const second = createIdempotencyKey("user-a")
    expect(second).toBe(first)
    expect(createIdempotencyKey("user-b")).not.toBe(first)
    clearCreateIdempotencyKey("user-a")
    expect(createIdempotencyKey("user-a")).not.toBe(first)
  })

  it("reuses a submit key per report", () => {
    const first = submitIdempotencyKey("report-1")
    expect(submitIdempotencyKey("report-1")).toBe(first)
    expect(submitIdempotencyKey("report-2")).not.toBe(first)
  })
})

describe("damage draft line validation", () => {
  it("requires positive integer carton quantities", () => {
    expect(parseCartonQuantity("0")).toBeNull()
    expect(parseCartonQuantity("1.5")).toBeNull()
    expect(parseCartonQuantity("-2")).toBeNull()
    expect(parseCartonQuantity("3")).toBe(3)
  })

  it("requires inbound receipt lines and storage crates", () => {
    expect(
      validateDraftLines("refill_supply", [line({ receipt_line_id: "" })]),
    ).toEqual(expect.arrayContaining([expect.stringMatching(/receipt line/i)]))
    expect(validateDraftLines("storage", [line({ crate_id: "" })])).toEqual(
      expect.arrayContaining([expect.stringMatching(/crate/i)]),
    )
  })

  it("blocks duplicate grains", () => {
    const errors = validateDraftLines("storage", [
      line({ key: "a" }),
      line({ key: "b" }),
    ])
    expect(errors.join(" ")).toMatch(/duplicate/i)
    expect(lineGrain(line())).toBe("p1|c1||")
  })
})

describe("damage submission readiness", () => {
  it("blocks isolation scenarios while readiness is false", () => {
    const blockers = collectSubmitBlockers({
      scenario: "storage",
      stockHoldReady: false,
      linesValid: true,
      sourceSelected: true,
      finalizedEvidence: 1,
      custodyConfirmed: true,
    })
    expect(blockers.some((row) => row.code === "isolation")).toBe(true)
    expect(scenarioSubmitHint("storage", false)).toMatch(/blocked/i)
  })

  it("allows inbound and transit submit messaging without holds", () => {
    const blockers = collectSubmitBlockers({
      scenario: "refill_supply",
      stockHoldReady: false,
      linesValid: true,
      sourceSelected: true,
      finalizedEvidence: 1,
      custodyConfirmed: false,
    })
    expect(blockers.some((row) => row.code === "isolation")).toBe(false)
    expect(scenarioSubmitHint("transit", false)).toMatch(/may submit/i)
  })

  it("blocks shop-return until custody workflow exists", () => {
    const blockers = collectSubmitBlockers({
      scenario: "shop_return",
      stockHoldReady: true,
      linesValid: true,
      sourceSelected: true,
      finalizedEvidence: 1,
      custodyConfirmed: false,
    })
    expect(blockers.some((row) => row.code === "custody")).toBe(true)
  })

  it("blocks missing evidence and invalid lines", () => {
    const blockers = collectSubmitBlockers({
      scenario: "transit",
      stockHoldReady: false,
      linesValid: false,
      sourceSelected: true,
      finalizedEvidence: 0,
      custodyConfirmed: false,
    })
    expect(blockers.map((row) => row.code)).toEqual(
      expect.arrayContaining(["lines", "evidence"]),
    )
  })
})

describe("damage mutation error mapping", () => {
  it("maps isolation, custody, stale, session, and ambiguous network outcomes", () => {
    expect(
      mapDamageMutationError("damage stock isolation is not ready"),
    ).toMatch(/isolation is not ready/i)
    expect(
      mapDamageMutationError(
        "shop-return damage requires confirmed physical custody",
      ),
    ).toMatch(/custody/i)
    expect(
      mapDamageMutationError("This record changed. Refresh and try again."),
    ).toMatch(/changed/i)
    expect(
      mapDamageMutationError("Your session has ended. Sign in again."),
    ).toMatch(/session/i)
    expect(mapDamageMutationError("Failed to fetch", "submit")).toMatch(
      /refresh the report/i,
    )
    expect(mapDamageMutationError("", "submit")).toMatch(/refresh the report/i)
  })

  it("never treats a browser upload as finalized", () => {
    expect(isSupportedDamagePhotoMime("image/jpeg")).toBe(true)
    expect(isSupportedDamagePhotoMime("image/jpg")).toBe(true)
    expect(isSupportedDamagePhotoMime("application/pdf")).toBe(false)
    expect(
      mapDamageMutationError("photo content could not be verified", "finalize"),
    ).toMatch(/did not finalize/i)
  })
})
