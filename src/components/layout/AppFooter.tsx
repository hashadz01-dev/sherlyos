import { Link } from "react-router"
import { EmailLink } from "@/components/shared/ContactLinks"
import { useAuth } from "@/hooks/use-auth"

/**
 * Workspace footer. Links stay inside the app so they cannot point at removed screens.
 * The year is read at render time so it does not go stale.
 */
export function AppFooter() {
  const { session } = useAuth()
  const email = session?.user.email
  const year = new Date().getFullYear()

  return (
    <footer className="mt-10 border-t border-slate-200/80 pt-4 text-sm text-muted-foreground print:hidden">
      <nav aria-label="Footer" className="flex flex-wrap gap-x-4 gap-y-2">
        <Link to="/" className="font-medium text-foreground hover:underline">
          Overview
        </Link>
        <Link to="/settings" className="font-medium text-foreground hover:underline">
          Settings
        </Link>
        <Link to="/terms" className="font-medium text-foreground hover:underline">
          Terms
        </Link>
        <Link to="/privacy" className="font-medium text-foreground hover:underline">
          Privacy
        </Link>
        {email ? <EmailLink value={email} /> : null}
      </nav>
      <p className="mt-3">© {year} Sherlys distributors & agents.</p>
    </footer>
  )
}
