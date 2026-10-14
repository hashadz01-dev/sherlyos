import { Link } from "react-router"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"

export function NotFoundPage() {
  useDocumentTitle("Page not found")

  return (
    <section>
      <PageHeader
        title="Page not found"
        description="That address is not part of SherlysOS."
      />
      <Button asChild>
        <Link to="/">Back to overview</Link>
      </Button>
    </section>
  )
}
