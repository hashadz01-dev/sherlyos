/** localStorage key for the last time the operator pressed Check on App updates. */
export const APP_UPDATES_CHECKED_KEY = "sherlyos.settings.app-updates.checked-at"

/**
 * Format the last-checked stamp the way the settings card shows it.
 * Returns a stable fallback when nothing has been recorded yet.
 */
export function formatAppUpdateStamp(iso: string | null | undefined): string {
  if (!iso) return "Not checked yet"
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return "Not checked yet"
  return new Intl.DateTimeFormat("en-GB", {
    weekday: "long",
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date)
}

export function readAppUpdatesCheckedAt(): string | null {
  if (typeof localStorage === "undefined") return null
  return localStorage.getItem(APP_UPDATES_CHECKED_KEY)
}

export function recordAppUpdatesCheckedAt(iso = new Date().toISOString()): string {
  localStorage.setItem(APP_UPDATES_CHECKED_KEY, iso)
  return iso
}

/** Turn role codes such as godown_manager into a readable label. */
export function formatRoleLabel(code: string): string {
  return code
    .split("_")
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}

export function formatAssignedRoles(roles: string[]): string {
  if (roles.length === 0) return "No assigned role"
  return roles.map(formatRoleLabel).join(", ")
}
