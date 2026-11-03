/**
 * Site-assignment diagnostics and role-level company-wide godown copy.
 * Missing warehouse grants stay a data issue: the UI must not assign branches.
 */
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { toUserRpcMessage } from "@/lib/rpc/user-error"

/** Role-level company-wide scope. Not branches.access_all and not Admin. */
export const ACCOUNTS_COMPANY_WIDE_GODOWN_PERMISSION = "accounts.godowns.all"

export const GODOWN_MANAGER_COMPANY_WIDE_GODOWN_PERMISSION = "godown_manager.godowns.all"

export const STORE_KEEPER_COMPANY_WIDE_GODOWN_PERMISSION = "store_keeper.godowns.all"

export const DELIVERY_PERSON_COMPANY_WIDE_GODOWN_PERMISSION = "delivery_person.godowns.all"

export const COMPANY_WIDE_GODOWN_PERMISSIONS = [
  ACCOUNTS_COMPANY_WIDE_GODOWN_PERMISSION,
  GODOWN_MANAGER_COMPANY_WIDE_GODOWN_PERMISSION,
  STORE_KEEPER_COMPANY_WIDE_GODOWN_PERMISSION,
  DELIVERY_PERSON_COMPANY_WIDE_GODOWN_PERMISSION,
] as const

/** Role policy for company-wide active-godown scope (not Admin access_all). */
export const COMPANY_WIDE_GODOWN_ROLE_CODES = [
  "accounts",
  "godown_manager",
  "store_keeper",
  "delivery_person",
] as const

export const COMPANY_WIDE_GODOWN_ACCESS_LABEL = "All godowns — Company-wide"

/** Default UAT wording when Accounts has no user_branch_assignments. */
export const MISSING_GODOWN_ASSIGNMENT_MESSAGE =
  "You are not assigned to Godown-1. Contact an administrator to request access."

/**
 * Operator-facing copy for a missing site grant.
 * Pass the known godown name only when the caller is already authorized to see it.
 */
export function missingSiteAssignmentMessage(godownName?: string | null) {
  const name = godownName?.trim() || "Godown-1"
  return `You are not assigned to ${name}. Contact an administrator to request access.`
}

export function hasAssignedGodowns(branches: { id: string }[] | null | undefined) {
  return (branches?.length ?? 0) > 0
}

/**
 * Company-wide scope follows Accounts, Godown Manager, Store Keeper, and
 * Delivery Person role policy. The permission is the server source of truth;
 * the role code covers sessions whose catalog has not loaded the grant yet.
 * Action RPCs still assert separately (e.g. transit still needs assignment
 * on the dispatch for Delivery Person create).
 */
export function hasCompanyWideGodownAccess(
  can: (permission: string) => boolean,
  roles: readonly string[] = [],
) {
  return (
    COMPANY_WIDE_GODOWN_PERMISSIONS.some((permission) => can(permission)) ||
    roles.some((role) =>
      (COMPANY_WIDE_GODOWN_ROLE_CODES as readonly string[]).includes(role),
    )
  )
}

/**
 * Employee-detail copy. Company-wide access is role policy, not seven
 * assignment rows. Explicit assignments stay visible separately.
 */
export function describeEmployeeGodownAccess(input: {
  roleCodes: string[]
  assignedBranchNames: string[]
}) {
  const companyWide = input.roleCodes.some((role) =>
    (COMPANY_WIDE_GODOWN_ROLE_CODES as readonly string[]).includes(role),
  )
  return {
    companyWide,
    accessLabel: companyWide
      ? COMPANY_WIDE_GODOWN_ACCESS_LABEL
      : input.assignedBranchNames.length > 0
        ? input.assignedBranchNames.join(", ")
        : "None",
    explicitAssignments: input.assignedBranchNames,
  }
}

/**
 * Own godown grants. Used to distinguish a genuinely empty DN queue from
 * an unassigned Accounts session. Does not assign branches.
 */
export async function loadOwnAssignedBranchIds() {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }
  const session = await supabase.auth.getUser()
  const userId = session.data.user?.id
  if (!userId) return [] as string[]
  const result = await supabase
    .from("user_branch_assignments")
    .select("branch_id")
    .eq("user_id", userId)
  if (result.error) {
    throw new Error(toUserRpcMessage(result.error))
  }
  return (result.data ?? [])
    .map((row) => String(row.branch_id ?? ""))
    .filter((id) => id.length > 0)
}
