import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Building2 } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { notify } from "@/lib/utilities/notify"

/**
 * Physical godown records. Persistence still uses public.branches and the
 * create_branch / set_branch_active RPCs so existing RLS and assignments stay valid.
 */
type Godown = {
  id: string
  code: string
  name: string
  is_active: boolean
}

export function GodownsPage() {
  useDocumentTitle("Godowns")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [code, setCode] = useState("")
  const [name, setName] = useState("")
  const godowns = useQuery({
    queryKey: ["branches"],
    queryFn: async () => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase
        ?.from("branches")
        .select("id, code, name, is_active")
        .order("name")
      if (result?.error) throw new Error(toUserRpcMessage(result.error))
      return (result?.data ?? []) as Godown[]
    },
  })

  const save = useMutation({
    mutationFn: async () => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase?.rpc("create_branch", {
        branch_code: code,
        branch_name: name,
      })
      if (result?.error) throw new Error(toUserRpcMessage(result.error))
    },
    onSuccess: async () => {
      setCode("")
      setName("")
      notify.success("Godown created")
      await queryClient.invalidateQueries({ queryKey: ["branches"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: async (godown: Godown) => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase?.rpc("set_branch_active", {
        target_branch: godown.id,
        active: !godown.is_active,
      })
      if (result?.error) throw new Error(toUserRpcMessage(result.error))
    },
    onSuccess: async () => {
      notify.success("Godown status updated")
      await queryClient.invalidateQueries({ queryKey: ["branches"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  return (
    <section>
      <PageHeader
        title="Godowns"
        description="Physical warehouses. The five numbered branches in the business-process PDF are workflows and are not created here. Renaming a godown is not available yet; only create and active status are supported."
      />
      {can("branches.manage") ? (
        <form
          className="mb-4 grid gap-3 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80 sm:grid-cols-[1fr_1fr_auto]"
          onSubmit={(event) => {
            event.preventDefault()
            save.mutate()
          }}
        >
          <Input
            aria-label="Godown code"
            placeholder="Godown code"
            value={code}
            onChange={(event) => setCode(event.target.value)}
            required
          />
          <Input
            aria-label="Godown name"
            placeholder="Godown name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            required
          />
          <Button type="submit" disabled={save.isPending}>
            Create godown
          </Button>
        </form>
      ) : null}
      <div className="rounded-2xl bg-white ring-1 ring-slate-200/80">
        {godowns.isLoading ? (
          <LoadingBlock label="Loading godowns" />
        ) : godowns.isError ? (
          <EmptyState
            icon={Building2}
            title="Godowns could not be loaded"
            description={
              godowns.error instanceof Error
                ? godowns.error.message
                : "Try again."
            }
          />
        ) : (godowns.data ?? []).length === 0 ? (
          <EmptyState
            icon={Building2}
            title="No godowns"
            description="Create a godown when you know the real warehouse name."
          />
        ) : (
          <ul className="divide-y divide-slate-200/80">
            {(godowns.data ?? []).map((godown) => (
              <li
                key={godown.id}
                className="flex items-center justify-between gap-3 px-4 py-3"
              >
                <span>
                  <span className="block text-sm font-medium">
                    {godown.name}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {godown.code}
                  </span>
                </span>
                <span className="flex items-center gap-2">
                  <StatusBadge tone={godown.is_active ? "success" : "neutral"}>
                    {godown.is_active ? "Active" : "Inactive"}
                  </StatusBadge>
                  {can("branches.manage") ? (
                    <Button
                      variant="outline"
                      onClick={() => toggle.mutate(godown)}
                      disabled={toggle.isPending}
                    >
                      {godown.is_active ? "Deactivate" : "Activate"}
                    </Button>
                  ) : null}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  )
}
