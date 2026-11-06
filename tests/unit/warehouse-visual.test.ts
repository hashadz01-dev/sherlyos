import { describe, expect, it } from "vitest"
import {
  availableToPick,
  CASES_PER_CRATE,
  configuredCapacity,
  configuredCapacityFromCrates,
  overCapacityCases,
  PLANNED_GODOWN_CAPACITY,
  visualizeCaseSlots,
} from "@/lib/warehouse/capacity"
import { godownClassification, matchTargetCrate, matchTargetZone } from "@/lib/warehouse/layout"
import { buildCrateBoard, buildCrateDetail, buildGodownCards, buildZoneBoard } from "@/lib/warehouse/model"
import type { WarehouseSnapshot } from "@/lib/warehouse/model"

const godown = { id: "g1", code: "gd_1", name: "Godown-1", is_active: true }
const reserve = { id: "g7", code: "gd_7", name: "Godown-7", is_active: false }
const storageZone = {
  id: "z1",
  branch_id: "g1",
  code: "uat_z1",
  name: "UAT Zone 1",
  location_role: "storage",
  is_active: true,
}
const quarantineZone = {
  id: "zq",
  branch_id: "g1",
  code: "QRN",
  name: "Quarantine",
  location_role: "quarantine",
  is_active: true,
}
const storageCrate = {
  id: "c1",
  zone_id: "z1",
  code: "uat_c1",
  name: "UAT Crate 1",
  location_role: "storage",
  is_active: true,
}
const quarantineCrate = {
  id: "cq",
  zone_id: "zq",
  code: "QRN-01",
  name: "Quarantine crate",
  location_role: "quarantine",
  is_active: true,
}

function snapshot(partial: Partial<WarehouseSnapshot> = {}): WarehouseSnapshot {
  return {
    godowns: [godown, reserve],
    zones: [storageZone, quarantineZone],
    crates: [storageCrate, quarantineCrate],
    balances: [
      {
        godown_id: "g1",
        godown_code: "gd_1",
        godown_name: "Godown-1",
        zone_id: "z1",
        zone_code: "uat_z1",
        zone_name: "UAT Zone 1",
        crate_id: "c1",
        crate_code: "uat_c1",
        crate_name: "UAT Crate 1",
        product_id: "p1",
        product_sku: "AAA",
        product_name: "Alpha",
        quantity: 30,
      },
      {
        godown_id: "g1",
        godown_code: "gd_1",
        godown_name: "Godown-1",
        zone_id: "z1",
        zone_code: "uat_z1",
        zone_name: "UAT Zone 1",
        crate_id: "c1",
        crate_code: "uat_c1",
        crate_name: "UAT Crate 1",
        product_id: "p2",
        product_sku: "BBB",
        product_name: "Beta",
        quantity: 23,
      },
      {
        godown_id: "g1",
        godown_code: "gd_1",
        godown_name: "Godown-1",
        zone_id: "zq",
        zone_code: "QRN",
        zone_name: "Quarantine",
        crate_id: "cq",
        crate_code: "QRN-01",
        crate_name: "Quarantine crate",
        product_id: "pq",
        product_sku: "QSKU",
        product_name: "Quarantine product",
        quantity: 1,
      },
    ],
    lots: [
      {
        lot_id: "l1",
        product_id: "p1",
        product_sku: "AAA",
        product_name: "Alpha",
        expiry_policy: "non_expiring",
        lot_status: "available",
        lot_origin: "receipt",
        manufacturer_lot_code: "LOT-A",
        manufactured_on: null,
        expiry_date: null,
        received_on: null,
        godown_id: "g1",
        godown_code: "gd_1",
        crate_id: "c1",
        crate_code: "uat_c1",
        quantity: 30,
      },
      {
        lot_id: "l2",
        product_id: "p2",
        product_sku: "BBB",
        product_name: "Beta",
        expiry_policy: "non_expiring",
        lot_status: "available",
        lot_origin: "receipt",
        manufacturer_lot_code: "LOT-B",
        manufactured_on: null,
        expiry_date: "2027-01-01",
        received_on: null,
        godown_id: "g1",
        godown_code: "gd_1",
        crate_id: "c1",
        crate_code: "uat_c1",
        quantity: 23,
      },
    ],
    reservations: [
      {
        id: "r1",
        crate_id: "c1",
        product_id: "p1",
        lot_id: "l1",
        reserved_cases: 2,
        status: "active",
      },
    ],
    holds: [
      {
        id: "h1",
        crate_id: "cq",
        product_id: "pq",
        lot_id: null,
        quantity_cases: 1,
        hold_kind: "quarantine_intake",
        status: "active",
      },
    ],
    reservationsVisible: true,
    holdsVisible: true,
    ...partial,
  }
}

describe("warehouse capacity", () => {
  it("keeps planned godown capacity separate from configured crates", () => {
    expect(PLANNED_GODOWN_CAPACITY).toBe(1200)
    expect(configuredCapacity(2)).toBe(100)
    expect(configuredCapacity(0)).toBe(0)
    expect(overCapacityCases(53, CASES_PER_CRATE)).toBe(3)
    expect(configuredCapacityFromCrates([{ capacity_cases: 50 }, { capacity_cases: 50 }])).toBe(100)
    expect(configuredCapacityFromCrates([{}])).toBe(50)
  })

  it("maps real Zone A and crate A-01 without treating QRN as Zone F", () => {
    expect(matchTargetZone({ code: "A", locationRole: "storage" })).toBe("A")
    expect(matchTargetZone({ code: "F", locationRole: "quarantine" })).toBe("F")
    expect(matchTargetCrate({ zoneKey: "A", crateCode: "A-01" })).toBe(1)
    expect(matchTargetZone({ code: "QRN", locationRole: "quarantine" })).toBeNull()
  })

  it("does not subtract quarantine intake holds from saleable availability", () => {
    expect(
      availableToPick({
        saleableOnHand: 53,
        visibleReserved: 2,
        visibleSaleableHolds: 0,
      }),
    ).toBe(51)
  })

  it("classifies Godown-7 as reserve without matching current zone codes to A–F", () => {
    expect(godownClassification("gd_7")).toBe("Reserve")
    expect(godownClassification("gd_1")).toBe("Normal")
    expect(matchTargetZone({ code: "QRN", locationRole: "quarantine" })).toBeNull()
    expect(matchTargetZone({ code: "uat_z1", locationRole: "storage" })).toBeNull()
    expect(matchTargetZone({ code: "A", locationRole: "storage" })).toBe("A")
    expect(matchTargetZone({ code: "F", locationRole: "storage" })).toBeNull()
    expect(matchTargetCrate({ zoneKey: null, crateCode: "QRN-01" })).toBeNull()
    expect(matchTargetCrate({ zoneKey: "A", crateCode: "A-01" })).toBe(1)
  })

  it("fills the same slots on every render and warns when stock exceeds 50", () => {
    const first = visualizeCaseSlots({
      inactive: false,
      quarantine: false,
      onHand: 53,
      visibleReserved: 2,
      slices: [
        {
          sku: "BBB",
          productName: "Beta",
          lotId: "l2",
          lotCode: "LOT-B",
          expiryDate: null,
          quantity: 23,
        },
        {
          sku: "AAA",
          productName: "Alpha",
          lotId: "l1",
          lotCode: "LOT-A",
          expiryDate: null,
          quantity: 30,
        },
      ],
    })
    const second = visualizeCaseSlots({
      inactive: false,
      quarantine: false,
      onHand: 53,
      visibleReserved: 2,
      slices: [
        {
          sku: "AAA",
          productName: "Alpha",
          lotId: "l1",
          lotCode: "LOT-A",
          expiryDate: null,
          quantity: 30,
        },
        {
          sku: "BBB",
          productName: "Beta",
          lotId: "l2",
          lotCode: "LOT-B",
          expiryDate: null,
          quantity: 23,
        },
      ],
    })
    expect(first.overflow).toBe(3)
    expect(first.slots.filter((slot) => slot.status === "occupied")).toHaveLength(48)
    expect(first.slots.filter((slot) => slot.status === "reserved")).toHaveLength(2)
    expect(first.slots[0]?.slice?.sku).toBe("AAA")
    expect(first.slots.map((slot) => slot.status)).toEqual(
      second.slots.map((slot) => slot.status),
    )
  })

  it("does not invent a product when lot quantities do not match on-hand", () => {
    const visual = visualizeCaseSlots({
      inactive: false,
      quarantine: false,
      onHand: 4,
      visibleReserved: 0,
      slices: [
        {
          sku: "AAA",
          productName: "Alpha",
          lotId: "l1",
          lotCode: "LOT-A",
          expiryDate: null,
          quantity: 2,
        },
      ],
    })
    expect(visual.assigned).toBe(false)
    expect(visual.slots[0]?.slice).toBeNull()
    expect(visual.slots[0]?.status).toBe("occupied")
  })
})

describe("warehouse boards", () => {
  it("shows A–F as not configured and keeps QRN-01 outside Zone F", () => {
    const board = buildZoneBoard(snapshot(), "g1")
    expect(board.targets.every((zone) => zone.configured === false)).toBe(true)
    expect(board.quarantineLocations.map((zone) => zone.code)).toEqual(["QRN"])
    expect(board.existing.map((zone) => zone.code)).toEqual(["uat_z1", "QRN"])
    const crates = buildCrateBoard(snapshot(), "zq")
    expect(crates.positions.every((position) => position.crate === null)).toBe(true)
    expect(crates.extra.map((row) => row.crate.code)).toEqual(["QRN-01"])
  })

  it("separates saleable over-capacity stock from quarantine stock", () => {
    const cards = buildGodownCards(snapshot())
    const first = cards.find((card) => card.code === "gd_1")
    const seventh = cards.find((card) => card.code === "gd_7")
    expect(first?.metrics.onHand).toBe(54)
    expect(first?.metrics.saleableOnHand).toBe(53)
    expect(first?.metrics.quarantineOnHand).toBe(1)
    expect(first?.metrics.configuredCapacity).toBe(100)
    expect(first?.metrics.overCapacity).toBe(0)
    expect(first?.metrics.availableToPick).toBe(51)
    expect(seventh?.classification).toBe("Reserve")
    expect(seventh?.active).toBe(false)
    expect(seventh?.metrics.onHand).toBe(0)
    const detail = buildCrateDetail(snapshot(), "c1")
    expect(detail?.metrics.overCapacity).toBe(3)
    expect(detail?.visual.slots.filter((slot) => slot.slice?.sku === "AAA")).toHaveLength(30)
    expect(detail?.visual.slots.filter((slot) => slot.slice?.sku === "BBB")).toHaveLength(20)
    expect(detail?.products).toHaveLength(2)
  })

  it("marks an inactive crate unavailable instead of occupied", () => {
    const detail = buildCrateDetail(
      snapshot({
        crates: [{ ...storageCrate, is_active: false }],
      }),
      "c1",
    )
    expect(detail?.visual.slots.every((slot) => slot.status === "unavailable")).toBe(true)
  })
})
