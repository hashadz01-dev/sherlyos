import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { readSupabasePublicEnv } from "@/lib/supabase/env"

export function SettingsPage() {
  useDocumentTitle("Settings")
  const configured = readSupabasePublicEnv() !== null

  return (
    <section>
      <PageHeader
        title="Settings"
        description="Public configuration for this workspace. Account administration is not available yet."
      />
      <div className="rounded-2xl bg-white p-5 ring-1 ring-slate-200/80">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-sm font-semibold">Supabase</h2>
            <p className="mt-1 max-w-xl text-sm leading-6 text-muted-foreground">
              The browser reads only VITE_SUPABASE_URL and
              VITE_SUPABASE_PUBLISHABLE_KEY. Secret keys are not part of this
              application.
            </p>
          </div>
          <StatusBadge tone={configured ? "success" : "warning"}>
            {configured ? "Configured" : "Not configured"}
          </StatusBadge>
        </div>
      </div>
    </section>
  )
}
