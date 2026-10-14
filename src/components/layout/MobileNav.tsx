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
import { useUiStore } from "@/stores/ui-store"

const shortcutPaths = ["/", "/orders", "/deliveries"]

export function MobileNav() {
  const mobileNavOpen = useUiStore((state) => state.mobileNavOpen)
  const setMobileNavOpen = useUiStore((state) => state.setMobileNavOpen)
  const shortcuts = shortcutPaths.flatMap((path) => {
    const item = navigationItems.find((entry) => entry.to === path)
    return item ? [item] : []
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
            <BrandMark compact />
          </SheetHeader>
          <SidebarNav onNavigate={() => setMobileNavOpen(false)} />
        </SheetContent>
      </Sheet>
      <nav
        aria-label="Mobile"
        className="fixed inset-x-0 bottom-0 z-30 border-t border-slate-200 bg-white pb-[env(safe-area-inset-bottom)] md:hidden"
      >
        <div className="grid grid-cols-4">
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
            className="flex flex-col items-center gap-1 px-2 py-2.5 text-[11px] font-medium text-slate-500"
            onClick={() => setMobileNavOpen(true)}
          >
            <Menu className="size-4" aria-hidden="true" />
            Menu
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
          "flex flex-col items-center gap-1 px-2 py-2.5 text-[11px] font-medium text-slate-500",
          isActive && "text-brand",
        )
      }
    >
      <Icon className="size-4" aria-hidden="true" />
      {label}
    </NavLink>
  )
}
