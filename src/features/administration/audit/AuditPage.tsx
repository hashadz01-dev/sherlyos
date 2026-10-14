import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { ScrollText } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Input } from "@/components/ui/input"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

type AuditRow = {
  id: string
  occurred_at: string
  actor_id: string | null
  action: string
  entity_table: string
  entity_id: string | null
  metadata: Record<string, unknown>
}

export function AuditPage() {
  useDocumentTitle("Audit history")
  const [action, setAction] = useState("")
  const logs = useQuery({
    queryKey: ["audit-logs"],
    queryFn: async () => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase
        ?.from("audit_logs")
        .select(
          "id, occurred_at, actor_id, action, entity_table, entity_id, metadata",
        )
        .order("occurred_at", { ascending: false })
        .limit(200)
      if (result?.error) throw new Error(result.error.message)
      return (result?.data ?? []) as AuditRow[]
    },
  })

  const term = action.trim().toLowerCase()
  const rows = (logs.data ?? []).filter(
    (row) => term.length === 0 || row.action.toLowerCase().includes(term),
  )

  return (
    <section>
      <PageHeader
        title="Audit history"
        description="Append-only security events. Ordinary users cannot read or change these rows."
      />
      <Input
        className="mb-4 max-w-sm"
        aria-label="Filter by action"
        placeholder="Filter by action"
        value={action}
        onChange={(event) => setAction(event.target.value)}
      />
      <div className="rounded-2xl bg-white ring-1 ring-slate-200/80">
        {logs.isLoading ? (
          <LoadingBlock label="Loading audit history" />
        ) : logs.isError ? (
          <EmptyState
            icon={ScrollText}
            title="Audit history could not be loaded"
            description={
              logs.error instanceof Error ? logs.error.message : "Try again."
            }
          />
        ) : rows.length === 0 ? (
          <EmptyState
            icon={ScrollText}
            title="No audit events"
            description="Events appear after privileged changes such as role assignment."
          />
        ) : (
          <ul className="divide-y divide-slate-200/80">
            {rows.map((row) => (
              <li key={row.id} className="px-4 py-3 text-sm">
                <p className="font-medium">{row.action}</p>
                <p className="text-xs text-muted-foreground">
                  {new Date(row.occurred_at).toLocaleString()} ·{" "}
                  {row.entity_table}
                  {row.entity_id ? ` · ${row.entity_id}` : ""}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {JSON.stringify(row.metadata)}
                </p>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  )
}
