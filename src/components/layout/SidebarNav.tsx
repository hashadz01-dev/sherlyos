import { NavLink } from "react-router"
import { cn } from "cn"
import { navigationGroups, navigationItems } from "@/app/navigation"

export function SidebarNav({ onNavigate }: { onNavigate?: () => void }) {
  return (
    <nav
      aria-label="Primary"
      className="flex flex-1 flex-col gap-6 overflow-y-auto px-3 pb-6"
    >
      {navigationGroups.map((group) => (
        <div key={group}>
          <p className="px-3 pb-2 text-[11px] font-semibold tracking-[0.16em] text-white/40 uppercase">
            {group}
          </p>
          <div className="flex flex-col gap-1">
            {navigationItems
              .filter((item) => item.group === group)
              .map((item) => {
                const Icon = item.icon
                return (
                  <NavLink
                    key={item.to}
                    to={item.to}
                    end={item.end}
                    onClick={onNavigate}
                    className={({ isActive }) =>
                      cn(
                        "flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium text-white/75 transition-colors hover:bg-white/8 hover:text-white focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white/70",
                        isActive &&
                          "bg-brand text-white shadow-sm hover:bg-brand",
                      )
                    }
                  >
                    <Icon className="size-4 shrink-0" aria-hidden="true" />
                    {item.label}
                  </NavLink>
                )
              })}
          </div>
        </div>
      ))}
    </nav>
  )
}
