export const adjustmentThreshold = 10

export const adjustmentStatuses = [
  "draft",
  "submitted",
  "returned",
  "approved",
  "rejected",
  "posted",
] as const

export type AdjustmentStatus = (typeof adjustmentStatuses)[number]

export function requestIsExceptional(quantities: number[]) {
  return quantities.some((quantity) => Math.abs(quantity) > adjustmentThreshold)
}

export function reasonForQuantities(quantities: number[]) {
  if (quantities.length === 0) return null
  if (quantities.every((quantity) => quantity < 0)) return "shortage"
  if (quantities.every((quantity) => quantity > 0)) return "surplus"
  return "mixed"
}

export function adjustmentActions(input: {
  status: AdjustmentStatus
  exceptional: boolean | null
  isRequester: boolean
  canRequest: boolean
  canPost: boolean
  canApproveExceptional: boolean
  otherManagerExists: boolean
}) {
  const canDecideOrdinary = input.canPost && !input.isRequester && input.otherManagerExists
  const canDecideFallback =
    input.canApproveExceptional && !input.isRequester && !input.otherManagerExists
  const canDecideExceptional = input.canApproveExceptional && !input.isRequester
  const canDecide = input.exceptional
    ? canDecideExceptional
    : canDecideOrdinary || canDecideFallback

  return {
    edit: input.canRequest && input.isRequester && (input.status === "draft" || input.status === "returned"),
    submit: input.canRequest && input.isRequester && (input.status === "draft" || input.status === "returned"),
    approve: canDecide && input.status === "submitted",
    return: canDecide && (input.status === "submitted" || input.status === "approved"),
    reject: canDecide && (input.status === "submitted" || input.status === "approved"),
    post: input.canPost && input.status === "approved",
  }
}
