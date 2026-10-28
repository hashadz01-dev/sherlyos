/**
 * M7.5C.1 statutory configuration rules.
 * Configuration cannot enable tax-invoice issuance. Verification is a
 * separate permission that is not granted to existing Accounts users.
 */

export const STATUTORY_ISSUANCE_BANNER =
  "CONFIGURATION ONLY — TAX INVOICE ISSUANCE DISABLED"

export const statutoryNavPermissions = [
  "statutory.config.read",
  "statutory.config.prepare",
  "statutory.config.verify",
] as const

export const statutoryConfigStatuses = [
  "draft",
  "submitted",
  "verified",
  "superseded",
  "cancelled",
] as const

export type StatutoryConfigStatus = (typeof statutoryConfigStatuses)[number]

export const statutoryStatusLabel: Record<StatutoryConfigStatus, string> = {
  draft: "Draft",
  submitted: "Submitted",
  verified: "Verified",
  superseded: "Superseded",
  cancelled: "Cancelled",
}

export const statutoryPolicyKinds = [
  "invoice_date",
  "tax_inclusive_exclusive",
  "place_of_supply",
  "gst_component",
  "rounding",
  "credit_note_tax",
  "numbering",
] as const

export type StatutoryPolicyKind = (typeof statutoryPolicyKinds)[number]

export const statutoryPolicyKindLabel: Record<StatutoryPolicyKind, string> = {
  invoice_date: "Invoice date",
  tax_inclusive_exclusive: "Tax inclusive / exclusive",
  place_of_supply: "Place of supply",
  gst_component: "CGST / SGST / IGST selection",
  rounding: "Rounding",
  credit_note_tax: "Credit-note tax treatment",
  numbering: "Invoice numbering",
}

export const shopRegistrationStatuses = [
  "unknown",
  "unregistered",
  "gst_registered",
  "composition",
] as const

export function isVerifiedStatutoryStatus(status: string) {
  return status === "verified"
}
