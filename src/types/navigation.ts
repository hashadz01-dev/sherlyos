import type { LucideIcon } from "lucide-react"

export type NavGroup = "Operations" | "Stock" | "Workspace"

export type AppNavItem = {
  to: string
  label: string
  title: string
  description: string
  group: NavGroup
  icon: LucideIcon
  end?: boolean
}
