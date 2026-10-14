import { Outlet, useLocation } from "react-router"
import { BrandMark } from "@/components/layout/BrandMark"
import { MobileNav } from "@/components/layout/MobileNav"
import { SidebarNav } from "@/components/layout/SidebarNav"
import { TopBar } from "@/components/layout/TopBar"

export function AppShell() {
  const { pathname } = useLocation()

  return (
    <div className="flex min-h-svh bg-background text-foreground">
      <aside className="sticky top-0 hidden h-svh w-64 shrink-0 flex-col bg-navy text-white md:flex">
        <div className="px-5 pt-6 pb-5">
          <BrandMark />
        </div>
        <SidebarNav />
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        <TopBar pathname={pathname} />
        <main className="flex-1 px-4 pt-6 pb-24 md:px-8 md:pb-10">
          <Outlet />
        </main>
      </div>
      <MobileNav />
    </div>
  )
}
