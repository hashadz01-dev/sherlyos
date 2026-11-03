import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DamageVerificationPanel } from "@/features/damage/components/DamageVerificationPanel"
import type { DamageReportDetail } from "@/lib/damage/api"

vi.mock("@/features/damage/hooks/use-damage-access", () => ({
  useDamageAccess: () => ({
    canVerify: true,
    canMonitor: false,
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ session: { user: { id: "gm-1" } } }),
}))

vi.mock("@/lib/utilities/notify", () => ({
  notify: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}))

function report(partial: Partial<DamageReportDetail>): DamageReportDetail {
  return {
    id: "r1",
    report_number: "DMG-1",
    scenario: "refill_supply",
    godown_id: "g1",
    godown_name: "Godown-1",
    status: "submitted",
    version: 2,
    reporter_name: "Keeper",
    reporter_user_id: "keeper-1",
    created_at: "2026-11-03T05:00:00Z",
    receipt_id: null,
    picking_request_id: null,
    dispatch_id: null,
    order_id: null,
    shop_id: null,
    notes: null,
    evidence: [
      {
        id: "e1",
        finalized: true,
        mime_type: "image/png",
        uploaded_at: "2026-11-03T05:20:00Z",
      },
    ],
    lines: [
      {
        id: "l1",
        product_id: "p1",
        product_sku: "SKU",
        product_name: "Item",
        quantity_cases: 2,
        damage_reason: "broken",
        crate_id: null,
        crate_code: null,
        lot_id: null,
        notes: null,
        receipt_line_id: null,
      },
    ],
    holds: [],
    events: [],
    exceptional_requests: [],
    ...partial,
  } as DamageReportDetail
}

describe("DamageVerificationPanel", () => {
  it("shows decision actions only while the report is submitted", () => {
    render(
      <DamageVerificationPanel report={report({ status: "submitted" })} onChanged={() => undefined} />,
    )
    expect(screen.getByRole("button", { name: "Verify" })).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: "Return for correction" }),
    ).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Reject" })).toBeInTheDocument()
    expect(screen.getAllByText("Pending verification").length).toBeGreaterThan(0)
  })

  it("hides blockers and decision buttons after verification", () => {
    render(
      <DamageVerificationPanel
        report={report({
          status: "verified",
          verifier_name: "Test Godownmanager",
          verified_at: "2026-11-03T05:31:28Z",
        })}
        onChanged={() => undefined}
      />,
    )
    expect(screen.getByText("Verified")).toBeInTheDocument()
    expect(screen.getByText("Test Godownmanager")).toBeInTheDocument()
    expect(
      screen.queryByText(/Only submitted reports can be verified/i),
    ).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Verify" })).not.toBeInTheDocument()
    expect(
      screen.queryByRole("button", { name: "Return for correction" }),
    ).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Reject" })).not.toBeInTheDocument()
    expect(
      screen.getByText(/Verification is complete/i),
    ).toBeInTheDocument()
  })

  it("falls back to the verified event for report-keeping names", () => {
    render(
      <DamageVerificationPanel
        report={report({
          status: "verified",
          verifier_name: null,
          verified_at: null,
          events: [
            {
              action: "verified",
              actor_name: "Test Godownmanager",
              previous_status: "submitted",
              next_status: "verified",
              created_at: "2026-11-03T05:31:28Z",
              metadata: {},
            },
          ],
        })}
        onChanged={() => undefined}
      />,
    )
    expect(screen.getByText("Test Godownmanager")).toBeInTheDocument()
  })

  it("hides decision buttons after rejection", () => {
    render(
      <DamageVerificationPanel
        report={report({
          status: "rejected",
          rejection_reason: "Not damaged",
          rejected_by_name: "Test Godownmanager",
        })}
        onChanged={() => undefined}
      />,
    )
    expect(screen.getByText("Rejected")).toBeInTheDocument()
    expect(
      screen.queryByText(/Only submitted reports can be verified/i),
    ).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Verify" })).not.toBeInTheDocument()
    expect(
      screen.getByText(/This report was rejected/i),
    ).toBeInTheDocument()
  })
})
