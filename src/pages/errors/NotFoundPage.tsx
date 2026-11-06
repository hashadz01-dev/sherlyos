import { Link } from "react-router"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"

export function NotFoundPage({ signedOut = false }: { signedOut?: boolean }) {
  useDocumentTitle(
    "Page not found",
    "That address is not part of SherlysOS.",
  )

  return (
    <section
      className={
        signedOut
          ? "mx-auto max-w-lg px-4 pt-16 pb-10"
          : "mx-auto max-w-lg"
      }
    >
      <p className="text-sm font-semibold tracking-wide text-brand">404</p>
      <PageHeader
        title="Page not found"
        description="That address is not part of SherlysOS. Use a page that exists, or sign in if this screen is private."
      />
      <div className="flex flex-wrap gap-3">
        <Button asChild>
          <Link to={signedOut ? "/login" : "/"}>
            {signedOut ? "Sign in" : "Back to overview"}
          </Link>
        </Button>
        {signedOut ? null : (
          <Button variant="outline" asChild>
            <Link to="/settings">Settings</Link>
          </Button>
        )}
      </div>
    </section>
  )
}
