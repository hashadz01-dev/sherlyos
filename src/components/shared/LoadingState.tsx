import { LoaderCircle } from "lucide-react"

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

export function LoadingBlock({ label = "Loading" }: { label?: string }) {
  return (
    <div
      role="status"
      className="flex items-center gap-3 rounded-2xl bg-white px-5 py-4 text-sm text-muted-foreground ring-1 ring-slate-200"
    >
      <LoaderCircle
        className="size-4 animate-spin text-brand"
        aria-hidden="true"
      />
      {label}
    </div>
  )
}
