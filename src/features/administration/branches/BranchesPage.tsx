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
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { notify } from "@/lib/utilities/notify"

type Branch = {
  id: string
  code: string
  name: string
  is_active: boolean
}

export function BranchesPage() {
  useDocumentTitle("Operating sites")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [code, setCode] = useState("")
  const [name, setName] = useState("")
  const branches = useQuery({
    queryKey: ["branches"],
    queryFn: async () => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase
        ?.from("branches")
        .select("id, code, name, is_active")
        .order("name")
      if (result?.error) throw new Error(result.error.message)
      return (result?.data ?? []) as Branch[]
    },
  })

  const save = useMutation({
    mutationFn: async () => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase?.rpc("create_branch", {
        branch_code: code,
        branch_name: name,
      })
      if (result?.error) throw new Error(result.error.message)
    },
    onSuccess: async () => {
      setCode("")
      setName("")
      notify.success("Operating site created")
      await queryClient.invalidateQueries({ queryKey: ["branches"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: async (branch: Branch) => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase?.rpc("set_branch_active", {
        target_branch: branch.id,
        active: !branch.is_active,
      })
      if (result?.error) throw new Error(result.error.message)
    },
    onSuccess: async () => {
      notify.success("Site status updated")
      await queryClient.invalidateQueries({ queryKey: ["branches"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  return (
    <section>
      <PageHeader
        title="Operating sites"
        description="These are physical sites such as a godown. The five numbered branches in the business-process PDF are workflows and are not created here. Renaming a site is not available yet; only create and active status are supported."
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
            aria-label="Site code"
            placeholder="Site code"
            value={code}
            onChange={(event) => setCode(event.target.value)}
            required
          />
          <Input
            aria-label="Site name"
            placeholder="Site name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            required
          />
          <Button type="submit" disabled={save.isPending}>
            Create site
          </Button>
        </form>
      ) : null}
      <div className="rounded-2xl bg-white ring-1 ring-slate-200/80">
        {branches.isLoading ? (
          <LoadingBlock label="Loading sites" />
        ) : branches.isError ? (
          <EmptyState
            icon={Building2}
            title="Sites could not be loaded"
            description={
              branches.error instanceof Error
                ? branches.error.message
                : "Try again."
            }
          />
        ) : (branches.data ?? []).length === 0 ? (
          <EmptyState
            icon={Building2}
            title="No operating sites"
            description="No sites are seeded. Create one when you know the real godown name."
          />
        ) : (
          <ul className="divide-y divide-slate-200/80">
            {(branches.data ?? []).map((branch) => (
              <li
                key={branch.id}
                className="flex items-center justify-between gap-3 px-4 py-3"
              >
                <span>
                  <span className="block text-sm font-medium">
                    {branch.name}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {branch.code}
                  </span>
                </span>
                <span className="flex items-center gap-2">
                  <StatusBadge tone={branch.is_active ? "success" : "neutral"}>
                    {branch.is_active ? "Active" : "Inactive"}
                  </StatusBadge>
                  {can("branches.manage") ? (
                    <Button
                      variant="outline"
                      onClick={() => toggle.mutate(branch)}
                      disabled={toggle.isPending}
                    >
                      {branch.is_active ? "Deactivate" : "Activate"}
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
