import { describe, expect, it } from "vitest"
import {
  canIssueDeliveryNoteForOrder,
  describeDeliveryNoteFormBlock,
  describeHandoverQueue,
  isActiveDeliveryNote,
  mergeHandoverOrderOptions,
  summarizeOrderLines,
} from "@/lib/delivery-notes/handover"

const verified = {
  id: "ord-1",
  order_number: "SO-20261030-000025",
  shop_id: "shop-1",
  branch_id: "g1",
  status: "verified",
  verified_at: "2026-11-02T06:48:26+00:00",
  created_at: "2026-10-30T13:11:49+00:00",
}

describe("delivery-note handover queue copy", () => {
  it("does not treat an unassigned Accounts session as an empty queue", () => {
    const view = describeHandoverQueue({
      canIssue: true,
      loading: false,
      assignedBranchCount: 0,
      queueLength: 0,
    })
    expect(view.state).toBe("no_site_assignment")
    expect(view.title).toBe("No godown assignment")
    expect(view.message).toMatch(/not assigned to a godown/i)
  })

  it("keeps empty, error, and unauthorized distinct from missing assignment", () => {
    expect(
      describeHandoverQueue({
        canIssue: false,
        loading: false,
        assignedBranchCount: 0,
        queueLength: 0,
      }).state,
    ).toBe("unauthorized")
    expect(
      describeHandoverQueue({
        canIssue: true,
        loading: false,
        errorMessage: "not authorized",
        assignedBranchCount: 1,
        queueLength: 0,
      }).state,
    ).toBe("error")
    expect(
      describeHandoverQueue({
        canIssue: true,
        loading: false,
        assignedBranchCount: 1,
        queueLength: 0,
      }).state,
    ).toBe("empty")
    expect(
      describeHandoverQueue({
        canIssue: true,
        loading: true,
        assignedBranchCount: 0,
        queueLength: 0,
      }).state,
    ).toBe("loading")
    expect(
      describeHandoverQueue({
        canIssue: true,
        loading: false,
        assignedBranchCount: 0,
        queueLength: 2,
      }).state,
    ).toBe("ready")
    expect(
      describeHandoverQueue({
        canIssue: true,
        loading: false,
        assignedBranchCount: 0,
        queueLength: 0,
        companyWideGodownAccess: true,
      }).state,
    ).toBe("empty")
  })
})

describe("delivery-note eligibility", () => {
  it("allows a verified order listed in the authorized queue", () => {
    expect(
      canIssueDeliveryNoteForOrder({
        canIssue: true,
        orderStatus: "verified",
        hasActiveDeliveryNote: false,
        orderBranchId: "g1",
        assignedBranchIds: [],
        listedInHandoverQueue: true,
      }),
    ).toBe(true)
  })

  it("allows Accounts company-wide godown access without a personal assignment", () => {
    expect(
      canIssueDeliveryNoteForOrder({
        canIssue: true,
        orderStatus: "verified",
        hasActiveDeliveryNote: false,
        orderBranchId: "g1",
        assignedBranchIds: [],
        listedInHandoverQueue: false,
        companyWideGodownAccess: true,
      }),
    ).toBe(true)
  })

  it("rejects submitted, held, cancelled, duplicate, and unauthorized godowns", () => {
    const base = {
      canIssue: true,
      hasActiveDeliveryNote: false,
      orderBranchId: "g1",
      assignedBranchIds: ["g1"],
      listedInHandoverQueue: false,
    }
    expect(canIssueDeliveryNoteForOrder({ ...base, orderStatus: "submitted" })).toBe(false)
    expect(canIssueDeliveryNoteForOrder({ ...base, orderStatus: "held" })).toBe(false)
    expect(canIssueDeliveryNoteForOrder({ ...base, orderStatus: "cancelled" })).toBe(false)
    expect(
      canIssueDeliveryNoteForOrder({
        ...base,
        orderStatus: "verified",
        hasActiveDeliveryNote: true,
      }),
    ).toBe(false)
    expect(
      canIssueDeliveryNoteForOrder({
        ...base,
        orderStatus: "verified",
        assignedBranchIds: ["g2"],
      }),
    ).toBe(false)
  })

  it("treats voided notes as inactive", () => {
    const note = {
      id: "dn-1",
      delivery_note_number: "DN-1",
      status: "voided",
      version: 2,
      acknowledged_at: null,
      acknowledged_by: null,
    }
    expect(isActiveDeliveryNote(note)).toBe(false)
    expect(isActiveDeliveryNote({ ...note, status: "draft", version: 1 })).toBe(true)
  })
})

describe("new delivery note selector", () => {
  it("merges a deep-linked order into the dropdown when the queue omitted it", () => {
    const options = mergeHandoverOrderOptions([], verified)
    expect(options[0]?.id).toBe("ord-1")
    expect(options[0]?.order_number).toBe("SO-20261030-000025")
  })

  it("does not duplicate an order already in the queue", () => {
    const options = mergeHandoverOrderOptions([verified], verified)
    expect(options).toHaveLength(1)
  })

  it("explains invalid, unauthorized, and existing-note cases without implying create is allowed", () => {
    expect(
      describeDeliveryNoteFormBlock({
        canIssue: true,
        orderId: "missing",
        orderFound: false,
        loadError: "This order is not available.",
        assignedBranchCount: 1,
        listedInHandoverQueue: false,
        hasActiveDeliveryNote: false,
        canCreate: false,
      }),
    ).toBe("This order is not available.")
    expect(
      describeDeliveryNoteFormBlock({
        canIssue: true,
        orderId: "ord-1",
        orderFound: true,
        orderStatus: "verified",
        assignedBranchCount: 0,
        listedInHandoverQueue: false,
        hasActiveDeliveryNote: false,
        canCreate: false,
      }),
    ).toMatch(/not assigned to a godown/i)
    expect(
      describeDeliveryNoteFormBlock({
        canIssue: true,
        orderId: "ord-1",
        orderFound: true,
        orderStatus: "verified",
        assignedBranchCount: 1,
        listedInHandoverQueue: false,
        hasActiveDeliveryNote: true,
        activeNoteNumber: "DN-1",
        canCreate: false,
      }),
    ).toMatch(/already has an active delivery note \(DN-1\)/i)
    expect(
      describeDeliveryNoteFormBlock({
        canIssue: true,
        orderId: "ord-1",
        orderFound: true,
        loading: true,
        assignedBranchCount: 0,
        listedInHandoverQueue: false,
        hasActiveDeliveryNote: false,
        canCreate: false,
      }),
    ).toBeNull()
  })

  it("summarizes whole-case lines for the waiting queue", () => {
    const totals = summarizeOrderLines([
      { order_id: "ord-1", requested_cases: 2 },
      { order_id: "ord-1", requested_cases: 1 },
      { order_id: "ord-2", requested_cases: 4 },
    ])
    expect(totals.get("ord-1")).toEqual({ cases: 3, lines: 2 })
    expect(totals.get("ord-2")).toEqual({ cases: 4, lines: 1 })
  })
})
