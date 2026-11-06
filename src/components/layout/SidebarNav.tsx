import { NavLink, useLocation } from "react-router"
import { cn } from "cn"
import { navigationGroups, navigationItems } from "@/app/navigation"
import { SlidingHighlight } from "@/components/shared/SlidingHighlight"
import {
  canSeeNavigationItem,
  isNavigationPathActive,
} from "@/lib/access/navigation-visibility"
import { useAccess } from "@/lib/access/use-access"

export function SidebarNav({ onNavigate }: { onNavigate?: () => void }) {
  const { pathname } = useLocation()
  const { can, loading } = useAccess()
  const visible = navigationItems.filter((item) => {
    if (loading) {
      return !item.permission && !item.anyPermissions
    }
    return canSeeNavigationItem(item, can)
  })

  return (
    <nav
      aria-label="Primary"
      className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto px-3 pb-6"
    >
      {navigationGroups.map((group) => {
        const items = visible.filter((item) => item.group === group)
        if (items.length === 0) {
          return null
        }
        return (
          <div key={group}>
            <p className="px-3 pb-2 text-[11px] font-semibold tracking-[0.16em] text-white/40 uppercase">
              {group}
            </p>
            <SlidingHighlight
              layoutKey={`${pathname}:${items.map((item) => item.to).join("|")}`}
              className="flex flex-col gap-1"
              highlightClassName="bg-brand shadow-[inset_0_1px_0_rgba(255,255,255,0.35)]"
            >
              {items.map((item) => {
                const Icon = item.icon
                const active = isNavigationPathActive(item.to, pathname, item.end)
                return (
                  <NavLink
                    key={item.to}
                    to={item.to}
                    end={item.end}
                    onClick={onNavigate}
                    data-active={active ? "true" : "false"}
                    className={cn(
                      "relative z-10 flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium text-white/75 hover:bg-white/8 hover:text-white focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white/80",
                      active && "text-white hover:bg-transparent",
                    )}
                  >
                    <Icon className="size-4 shrink-0" aria-hidden="true" />
                    {item.label}
                  </NavLink>
                )
              })}
            </SlidingHighlight>
          </div>
        )
      })}
    </nav>
  )
}
