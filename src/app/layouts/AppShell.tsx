import { Suspense } from "react"
import { Outlet, useLocation } from "react-router"
import { findNavigationItem } from "@/app/navigation"
import { AppFooter } from "@/components/layout/AppFooter"
import { BrandMark } from "@/components/layout/BrandMark"
import { MobileNav } from "@/components/layout/MobileNav"
import { SidebarNav } from "@/components/layout/SidebarNav"
import { TopBar } from "@/components/layout/TopBar"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { useDocumentTitle } from "@/hooks/use-document-title"

export function AppShell() {
  const { pathname } = useLocation()

  return (
    // Fixed to the viewport so the document cannot grow under the workspace.
    // A viewport-height shell left in normal flow still let the page scroll
    // past the sidebar into empty space.
    <div className="app-shell fixed inset-0 flex overflow-hidden bg-background text-foreground">
      <aside className="hidden h-full min-h-0 w-64 shrink-0 flex-col border-r border-white/10 bg-navy text-white print:hidden md:flex">
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
        <main className="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-y-contain bg-background px-4 pt-6 pb-24 md:px-8 md:pb-10 print:overflow-visible print:bg-white print:px-0 print:pt-0 print:pb-0">
          <RouteDocumentMeta pathname={pathname} />
          <Suspense fallback={<LoadingBlock label="Loading page" />}>
            <div key={pathname} className="page-enter min-w-0 print:animate-none">
              <Outlet />
              <AppFooter />
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

/** Default title and description for the matched section. A page hook can replace both. */
function RouteDocumentMeta({ pathname }: { pathname: string }) {
  const item = findNavigationItem(pathname)
  useDocumentTitle(
    item?.title ?? "SherlysOS",
    item?.description ??
      "SherlysOS operations workspace for orders, stock, and delivery.",
  )
  return null
}
