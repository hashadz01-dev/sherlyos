import { useState, type ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { RefreshCcw, UserRound, type LucideIcon } from "lucide-react"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import {
  formatAppUpdateStamp,
  formatAssignedRoles,
  readAppUpdatesCheckedAt,
  recordAppUpdatesCheckedAt,
} from "@/features/administration/settings"

function SettingsCard({
  icon: Icon,
  title,
  children,
  action,
}: {
  icon: LucideIcon
  title: string
  children: ReactNode
  action?: ReactNode
}) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
      <div className="flex min-w-0 items-start gap-3">
        <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-slate-100 text-slate-600">
          <Icon className="size-4" aria-hidden />
        </div>
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">{title}</h2>
          <div className="mt-0.5 text-sm leading-5 text-muted-foreground">{children}</div>
        </div>
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  )
}

export function SettingsPage() {
  useDocumentTitle("Settings")
  const { session } = useAuth()
  const { roles, loading: rolesLoading } = useAccess()
  const [checkedAt, setCheckedAt] = useState<string | null>(() => readAppUpdatesCheckedAt())
  const userId = session?.user.id
  const profile = useQuery({
    queryKey: ["settings-profile", userId],
    enabled: Boolean(userId),
    queryFn: async () => {
      const supabase = getSupabaseBrowserClient()
      if (!supabase || !userId) return null
      const result = await supabase
        .from("profiles")
        .select("full_name, email")
        .eq("id", userId)
        .maybeSingle()
      if (result.error) {
        throw new Error(result.error.message)
      }
      return result.data
    },
  })

  // Prefer the profile display name; fall back to the signed-in email.
  const email = profile.data?.email ?? session?.user.email ?? null
  const displayName = profile.data?.full_name?.trim() || email || "Signed in"
  const roleLabel = rolesLoading ? "Loading role" : formatAssignedRoles(roles)

  function handleCheckUpdates() {
    setCheckedAt(recordAppUpdatesCheckedAt())
  }

  return (
    <section>
      <PageHeader
        title="Settings"
        description="Account details and app updates for this workspace."
      />
      <div className="grid max-w-md gap-3">
        <SettingsCard
          icon={RefreshCcw}
          title="App updates"
          action={
            <Button type="button" variant="outline" size="sm" onClick={handleCheckUpdates}>
              <RefreshCcw data-icon="inline-start" />
              Check
            </Button>
          }
        >
          <p>{formatAppUpdateStamp(checkedAt)}</p>
        </SettingsCard>
        <SettingsCard icon={UserRound} title="Profile">
          <p>Name: {displayName}</p>
          <p>Operations workspace</p>
          <p>Role: {roleLabel}</p>
        </SettingsCard>
      </div>
    </section>
  )
}
