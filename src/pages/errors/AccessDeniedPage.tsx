import { ShieldOff } from "lucide-react"
import { Link } from "react-router"
import { EmptyState } from "@/components/shared/EmptyState"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"

export function AccessDeniedPage() {
  useDocumentTitle("Access denied")

  return (
    <section className="rounded-2xl bg-white ring-1 ring-slate-200/80">
      <EmptyState
        icon={ShieldOff}
        title="You do not have access to this page"
        description="Your account is signed in, but it does not have the permission this screen requires."
      />
      <div className="flex justify-center pb-8">
        <Button variant="outline" asChild>
          <Link to="/">Back to overview</Link>
        </Button>
      </div>
    </section>
  )
}
