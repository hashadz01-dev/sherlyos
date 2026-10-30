import { describe, expect, it } from "vitest"
import { invoiceNavPermissions, INVOICE_DRAFT_WATERMARK } from "@/lib/invoices/rules"
import { SHORT_SHIPMENT_OPERATIONAL, nextOrderPickingAction } from "@/lib/picking/rules"
import { PAYMENT_UNAVAILABLE_REASON } from "@/lib/shops/rules"
import {
  M82C_CATALOG,
  M82C_IMPLEMENTED_SEQUENCE,
  M82C_ISOLATION,
  M82C_LABEL,
  M82C_OWNER_STAGES,
  M82C_SCENARIO_B_LOADED_CASES,
  M82C_SCENARIO_B_ORDERED_CASES,
  M82C_SYNTHETIC_OPENING_CASES,
  M82C_SYNTHETIC_PRICES,
  M82C_USERS,
} from "@/lib/uat/m82c-manifest"

describe("M8.2C workflow alignment", () => {
  it("keeps the owner six-stage blueprint distinct from the implemented sequence", () => {
    expect(M82C_OWNER_STAGES).toHaveLength(6)
    expect(M82C_IMPLEMENTED_SEQUENCE.length).toBeGreaterThan(6)
    expect(M82C_IMPLEMENTED_SEQUENCE).toContain("accounts_delivery_note")
    expect(M82C_IMPLEMENTED_SEQUENCE).toContain("godown_manager_confirm_dispatch")
    expect(M82C_IMPLEMENTED_SEQUENCE.indexOf("godown_manager_prepare_invoice_note")).toBeGreaterThan(
      M82C_IMPLEMENTED_SEQUENCE.indexOf("godown_manager_confirm_dispatch"),
    )
  })

  it("requires an acknowledged delivery note before allocation", () => {
    expect(
      nextOrderPickingAction({
        orderStatus: "verified",
        dnStatus: null,
        pickingStatus: null,
        hasShortage: false,
        cutoverBlocked: false,
      }),
    ).toMatch(/delivery note/)
    expect(
      nextOrderPickingAction({
        orderStatus: "verified",
        dnStatus: "sent",
        pickingStatus: null,
        hasShortage: false,
        cutoverBlocked: false,
      }),
    ).toMatch(/acknowledgement/)
  })

  it("does not treat submitted orders as warehouse-ready", () => {
    expect(
      nextOrderPickingAction({
        orderStatus: "submitted",
        dnStatus: null,
        pickingStatus: null,
        hasShortage: false,
        cutoverBlocked: false,
      }),
    ).toMatch(/does not reserve/)
    expect(
      nextOrderPickingAction({
        orderStatus: "held",
        dnStatus: null,
        pickingStatus: null,
        hasShortage: false,
        cutoverBlocked: false,
      }),
    ).toMatch(/resubmit/)
  })

  it("keeps statutory invoice notes as drafts and short-shipment non-operational", () => {
    expect(INVOICE_DRAFT_WATERMARK).toMatch(/NOT A TAX INVOICE/)
    expect(invoiceNavPermissions).toContain("invoice_notes.prepare")
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
  })

  it("does not invent shop outstanding balances for Accounts credit review", () => {
    expect(PAYMENT_UNAVAILABLE_REASON).toMatch(/not implemented/i)
  })
})

describe("M8.2C TEST ONLY manifest", () => {
  it("labels every synthetic master as TEST ONLY", () => {
    expect(M82C_LABEL).toBe("TEST ONLY")
    expect(M82C_CATALOG.supplierName.startsWith(M82C_LABEL)).toBe(true)
    expect(M82C_CATALOG.expirySku.startsWith("m82c-")).toBe(true)
    expect(M82C_USERS.deliveryPerson).toMatch(/@example\.test$/)
  })

  it("keeps ordered quantity distinct from loaded quantity in scenario B", () => {
    expect(M82C_SCENARIO_B_ORDERED_CASES).toBe(12)
    expect(M82C_SCENARIO_B_LOADED_CASES).toBe(11)
    expect(M82C_SCENARIO_B_LOADED_CASES).toBeLessThan(M82C_SCENARIO_B_ORDERED_CASES)
  })

  it("uses synthetic prices and opening cases, not owner catalogue amounts", () => {
    expect(M82C_SYNTHETIC_PRICES.expiry).toBe(10)
    expect(M82C_SYNTHETIC_OPENING_CASES.stable).toBe(20)
    expect(M82C_ISOLATION.forbiddenApiPorts).toEqual(["54321", "56321"])
    expect(M82C_ISOLATION.apiPort).toBe("57321")
  })
})
