import { useEffect } from "react"
import { isRouteErrorResponse, Link, useRouteError } from "react-router"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import {
  isStaleChunkError,
  reloadOnceForStaleChunk,
} from "@/lib/routing/stale-chunk"

function errorMessage(error: unknown) {
  if (isRouteErrorResponse(error)) {
    return error.statusText || `HTTP ${error.status}`
  }
  if (error instanceof Error) {
    return error.message
  }
  return "The screen could not be opened."
}

/**
 * Replaces React Router's default "Unexpected Application Error" overlay.
 * Stale hashed chunks after a Netlify publish get one automatic reload.
 */
export function RouteErrorPage() {
  const error = useRouteError()
  const stale = isStaleChunkError(error)
  useDocumentTitle(stale ? "Reload required" : "Something went wrong")

  useEffect(() => {
    if (stale) {
      reloadOnceForStaleChunk()
    }
  }, [stale])

  return (
    <main className="mx-auto max-w-xl px-6 py-16">
      <h1 className="text-xl font-semibold">
        {stale ? "This screen is out of date" : "Something went wrong"}
      </h1>
      <p className="mt-2 text-sm text-muted-foreground">
        {stale
          ? "A newer app bundle was published. Reload to load the current screens."
          : errorMessage(error)}
      </p>
      <div className="mt-6 flex flex-wrap gap-3">
        <Button type="button" onClick={() => window.location.reload()}>
          Reload
        </Button>
        <Button variant="outline" asChild>
          <Link to="/">Back to overview</Link>
        </Button>
      </div>
    </main>
  )
}
