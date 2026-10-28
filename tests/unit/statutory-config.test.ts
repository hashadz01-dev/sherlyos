import { describe, expect, it } from "vitest"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"
import {
  STATUTORY_ISSUANCE_BANNER,
  isVerifiedStatutoryStatus,
  statutoryNavPermissions,
  statutoryPolicyKindLabel,
  statutoryStatusLabel,
} from "@/lib/statutory/rules"

describe("statutory configuration presentation", () => {
  it("keeps the issuance-disabled banner exact", () => {
    expect(STATUTORY_ISSUANCE_BANNER).toBe(
      "CONFIGURATION ONLY — TAX INVOICE ISSUANCE DISABLED",
    )
  })

  it("does not treat draft configuration as legally verified", () => {
    expect(isVerifiedStatutoryStatus("draft")).toBe(false)
    expect(isVerifiedStatutoryStatus("submitted")).toBe(false)
    expect(isVerifiedStatutoryStatus("verified")).toBe(true)
    expect(statutoryStatusLabel.draft).toBe("Draft")
  })

  it("keeps numbering as an unapproved policy kind, not an issuer", () => {
    expect(statutoryPolicyKindLabel.numbering).toBe("Invoice numbering")
    expect(statutoryNavPermissions).toContain("statutory.config.read")
    expect(statutoryNavPermissions).not.toContain("invoices.issue")
  })

  it("does not treat short-shipment as operational", () => {
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
  })
})
