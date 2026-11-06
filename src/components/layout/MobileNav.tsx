import { Menu, type LucideIcon } from "lucide-react"
import { NavLink } from "react-router"
import { cn } from "cn"
import { navigationItems } from "@/app/navigation"
import { BrandMark } from "@/components/layout/BrandMark"
import { SidebarNav } from "@/components/layout/SidebarNav"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet"
import { canSeeNavigationItem } from "@/lib/access/navigation-visibility"
import { useAccess } from "@/lib/access/use-access"
import { useUiStore } from "@/stores/ui-store"

const shortcutPaths = ["/", "/orders", "/deliveries"]

export function MobileNav() {
  const mobileNavOpen = useUiStore((state) => state.mobileNavOpen)
  const setMobileNavOpen = useUiStore((state) => state.setMobileNavOpen)
  const { can, loading } = useAccess()
  const shortcuts = shortcutPaths.flatMap((path) => {
    const item = navigationItems.find((entry) => entry.to === path)
    if (!item) return []
    // Hide shortcuts the signed-in role cannot open. Overview has no permission.
    if (loading) return item.permission || item.anyPermissions ? [] : [item]
    return canSeeNavigationItem(item, can) ? [item] : []
  })

  return (
    <>
      <Sheet open={mobileNavOpen} onOpenChange={setMobileNavOpen}>
        <SheetContent
          side="left"
          className="w-[min(100%,20rem)] border-none bg-navy p-0 text-white [&_[data-slot=sheet-close]]:text-white [&_[data-slot=sheet-close]]:hover:bg-white/10"
        >
          <SheetHeader className="px-5 pt-6 pr-12">
            <SheetTitle className="sr-only">Navigation</SheetTitle>
            <SheetDescription className="sr-only">
              SherlysOS sections
            </SheetDescription>
            <BrandMark compact onNavigate={() => setMobileNavOpen(false)} />
          </SheetHeader>
          <SidebarNav onNavigate={() => setMobileNavOpen(false)} />
        </SheetContent>
      </Sheet>
      <nav
        aria-label="Mobile"
        className="fixed inset-x-0 bottom-0 z-30 border-t border-slate-200 bg-white pb-[env(safe-area-inset-bottom)] md:hidden"
      >
        <div
          className="grid"
          style={{ gridTemplateColumns: `repeat(${shortcuts.length + 1}, minmax(0, 1fr))` }}
        >
          {shortcuts.map((item) => (
            <MobileLink
              key={item.to}
              to={item.to}
              label={item.label}
              icon={item.icon}
              end={item.end}
            />
          ))}
          <button
            type="button"
            className="flex min-w-0 flex-col items-center gap-1 px-2 py-2.5 text-center text-[11px] font-medium text-slate-500"
            onClick={() => setMobileNavOpen(true)}
          >
            <Menu className="size-4 shrink-0" aria-hidden="true" />
            <span className="w-full truncate">Menu</span>
          </button>
        </div>
      </nav>
    </>
  )
}

function MobileLink({
  to,
  label,
  icon: Icon,
  end,
}: {
  to: string
  label: string
  icon: LucideIcon
  end?: boolean
}) {
  return (
    <NavLink
      to={to}
      end={end}
      className={({ isActive }) =>
        cn(
          "flex min-w-0 flex-col items-center gap-1 px-2 py-2.5 text-center text-[11px] font-medium text-slate-500",
          isActive && "text-brand",
        )
      }
    >
      <Icon className="size-4 shrink-0" aria-hidden="true" />
      <span className="w-full truncate">{label}</span>
    </NavLink>
  )
}
