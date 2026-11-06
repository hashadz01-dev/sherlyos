import { LoaderCircle } from "lucide-react"
import { Skeleton } from "@/components/ui/skeleton"

export function LoadingScreen({
  label = "Checking your session",
}: {
  label?: string
}) {
  return (
    <div className="flex min-h-svh items-center justify-center bg-background px-6">
      <div className="flex items-center gap-3 text-sm font-medium text-muted-foreground">
        <LoaderCircle
          className="size-4 animate-spin text-brand"
          aria-hidden="true"
        />
        <span>{label}</span>
      </div>
    </div>
  )
}

/**
 * Page and list placeholder. The label names the wait. The bars reserve
 * the layout so content does not pop in from a single spinner.
 */
export function LoadingBlock({ label = "Loading" }: { label?: string }) {
  return (
    <div
      role="status"
      className="rounded-lg bg-card px-5 py-4 ring-1 ring-border"
    >
      <p className="flex items-center gap-3 text-sm text-muted-foreground">
        <LoaderCircle
          className="size-4 animate-spin text-brand"
          aria-hidden="true"
        />
        {label}
      </p>
      <div className="mt-4 space-y-3" aria-hidden="true">
        <Skeleton className="h-4 w-2/5" />
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-4/5" />
      </div>
    </div>
  )
}
