import { describe, expect, it } from "vitest"
import { toUserRpcMessage } from "@/lib/rpc/user-error"

describe("toUserRpcMessage", () => {
  it("maps permission and session failures without SQL", () => {
    expect(toUserRpcMessage({ code: "42501", message: "permission denied for function confirm_dispatch" })).toBe(
      "You do not have permission to do that.",
    )
    expect(toUserRpcMessage({ code: "PGRST303", message: "JWT expired" })).toBe(
      "Your session has ended. Sign in again.",
    )
    expect(toUserRpcMessage({ code: "PT409", message: "changed by someone else" })).toBe(
      "This record changed. Refresh and try again.",
    )
    expect(
      toUserRpcMessage({
        code: "PGRST202",
        message:
          "Could not find the function public.list_invoice_notes(p_branch_id, p_shop_id, p_status) in the schema cache",
      }),
    ).toBe(
      "This module is not available on the connected database yet.",
    )
  })

  it("keeps operational cutover wording and strips SQL leaks", () => {
    expect(
      toUserRpcMessage({
        message: "Lot-aware picking requires dual-write to be enabled.",
      }),
    ).toBe("Lot-aware picking requires dual-write to be enabled.")
    expect(
      toUserRpcMessage({
        message: "insert into public.stock_transactions failed",
      }),
    ).toBe("The request could not be completed. Try again or ask an administrator.")
  })
})
