import { Suspense } from "react"
import { Outlet, useLocation } from "react-router"
import { BrandMark } from "@/components/layout/BrandMark"
import { MobileNav } from "@/components/layout/MobileNav"
import { SidebarNav } from "@/components/layout/SidebarNav"
import { TopBar } from "@/components/layout/TopBar"
import { LoadingBlock } from "@/components/shared/LoadingState"

export function AppShell() {
  const { pathname } = useLocation()

  return (
    <div className="flex h-svh overflow-hidden bg-background text-foreground print:h-auto print:overflow-visible">
      <aside className="hidden h-svh w-64 shrink-0 flex-col border-r border-white/10 bg-navy text-white shadow-[inset_-1px_0_0_rgba(255,255,255,0.06)] print:hidden md:flex md:bg-[linear-gradient(180deg,rgba(255,255,255,0.06),transparent_22%),#0e1c33]">
        <div className="px-5 pt-6 pb-5">
          <BrandMark />
        </div>
        <SidebarNav />
      </aside>
      {/*
        Pin the account bar. Sticky on TopBar cannot work while the document
        itself scrolls, because the header's parent is only as tall as the bar.
      */}
      <div className="flex min-h-0 min-w-0 flex-1 flex-col">
        <div className="shrink-0 print:hidden">
          <TopBar pathname={pathname} />
        </div>
        <main className="min-h-0 flex-1 overflow-y-auto bg-[radial-gradient(ellipse_at_top_left,rgba(47,111,224,0.07),transparent_42%),radial-gradient(ellipse_at_top_right,rgba(34,211,238,0.05),transparent_34%)] px-4 pt-6 pb-24 md:px-8 md:pb-10 print:overflow-visible print:bg-white print:px-0 print:pt-0 print:pb-0">
          <Suspense fallback={<LoadingBlock label="Loading page" />}>
            <div key={pathname} className="page-enter print:animate-none">
              <Outlet />
            </div>
          </Suspense>
        </main>
      </div>
      <div className="print:hidden">
        <MobileNav />
      </div>
    </div>
  )
}
