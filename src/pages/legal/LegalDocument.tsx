import type { ReactNode } from "react"
import { Link } from "react-router"
import { BrandMark } from "@/components/layout/BrandMark"
import { useDocumentTitle } from "@/hooks/use-document-title"

/**
 * Public legal page. Stays outside the signed-in shell so the notice
 * can be read before an account is used.
 */
export function LegalDocument({
  title,
  description,
  children,
}: {
  title: string
  description: string
  children: ReactNode
}) {
  useDocumentTitle(title, description)

  return (
    <main className="min-h-svh bg-background px-4 py-10 text-foreground">
      <article className="mx-auto max-w-2xl">
        <BrandMark tone="dark" />
        <h1 className="mt-8 text-3xl font-semibold tracking-tight">{title}</h1>
        <p className="mt-3 text-sm leading-6 text-muted-foreground">{description}</p>
        <div className="mt-8 space-y-6 text-sm leading-6 text-foreground">{children}</div>
        <nav aria-label="Legal" className="mt-10 flex flex-wrap gap-x-4 gap-y-2 text-sm">
          <Link to="/login" className="font-medium underline">
            Sign in
          </Link>
          <Link to="/terms" className="font-medium underline">
            Terms
          </Link>
          <Link to="/privacy" className="font-medium underline">
            Privacy
          </Link>
        </nav>
      </article>
    </main>
  )
}
