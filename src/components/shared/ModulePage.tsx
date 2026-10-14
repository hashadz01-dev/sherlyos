import { findNavigationItem } from "@/app/navigation"
import { EmptyState } from "@/components/shared/EmptyState"
import { PageHeader } from "@/components/shared/PageHeader"
import { useDocumentTitle } from "@/hooks/use-document-title"

export function ModulePage({ path }: { path: string }) {
  const item = findNavigationItem(path)
  const title = item?.title ?? "SherlysOS"
  useDocumentTitle(title)

  return (
    <section>
      <PageHeader title={title} description={item?.description} />
      <div className="rounded-2xl bg-white ring-1 ring-slate-200/80">
        <EmptyState
          icon={item?.icon}
          title={`${title} is not available yet`}
          description="This screen is registered for a later phase. It does not load operational records or change stock."
        />
      </div>
    </section>
  )
}
