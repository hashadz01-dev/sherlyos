import type { LucideIcon } from "lucide-react"

export type NavGroup =
  | "Operations"
  | "Stock"
  | "Master data"
  | "Workspace"
  | "Administration"

export type AppNavItem = {
  to: string
  label: string
  title: string
  description: string
  group: NavGroup
  icon: LucideIcon
  end?: boolean
  /** Database permission required to show this item. Omitted items stay visible to every signed-in user. */
  permission?: string
  /** Show the item when the user has any one of these permissions. */
  anyPermissions?: string[]
}
