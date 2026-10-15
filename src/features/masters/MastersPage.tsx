import { Link } from "react-router"
import { PageHeader } from "@/components/shared/PageHeader"
import { LoadingScreen } from "@/components/shared/LoadingState"
import { navigationItems } from "@/app/navigation"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { AccessDeniedPage } from "@/pages/errors/AccessDeniedPage"

export function MastersPage() {
  useDocumentTitle("Master data")
  const { loading, can } = useAccess()
  const links = navigationItems.filter(
    (item) =>
      item.to.startsWith("/masters/") &&
      item.permission &&
      can(item.permission),
  )

  if (loading) return <LoadingScreen />
  if (links.length === 0) return <AccessDeniedPage />

  return (
    <section>
      <PageHeader
        title="Master data"
        description="Maintain the catalogs that later stock and order work will use. Nothing on these screens changes a stock balance."
      />
      <ul className="grid gap-3 sm:grid-cols-2">
        {links.map((item) => {
          const Icon = item.icon
          return (
            <li key={item.to}>
              <Link
                to={item.to}
                className="flex h-full gap-3 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80"
              >
                <Icon className="mt-0.5 size-4" aria-hidden="true" />
                <span>
                  <span className="block text-sm font-medium">{item.title}</span>
                  <span className="mt-1 block text-sm text-muted-foreground">
                    {item.description}
                  </span>
                </span>
              </Link>
            </li>
          )
        })}
      </ul>
    </section>
  )
}