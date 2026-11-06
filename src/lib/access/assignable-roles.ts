/**
 * Roles that stay in the catalog for existing checks, but are not offered
 * when an admin creates a user or assigns a role.
 * Damage Verifier and Statutory verifier are not operator roles on this screen.
 */
export const HIDDEN_ASSIGNABLE_ROLE_CODES = new Set([
  "damage_verifier",
  "statutory_verifier",
])

/** Drop hidden catalog roles before they reach a role picker. */
export function assignableRoleOptions<T extends { code: string }>(
  roles: readonly T[],
): T[] {
  return roles.filter((role) => !HIDDEN_ASSIGNABLE_ROLE_CODES.has(role.code))
}
