import { useMemo, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Users } from "lucide-react"
import { AppModal } from "@/components/shared/AppModal"
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

type Profile = {
  id: string
  full_name: string
  employee_code: string | null
  is_active: boolean
}

type Named = { id: string; code: string; name: string }

type Employee = Profile & {
  roles: Named[]
  branches: Named[]
}

function one<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null
  return Array.isArray(value) ? (value[0] ?? null) : value
}

async function loadEmployees(): Promise<{
  employees: Employee[]
  roles: Named[]
  branches: Named[]
}> {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }

  const [profiles, memberships, assignments, roles, branches] =
    await Promise.all([
      supabase
        .from("profiles")
        .select("id, full_name, employee_code, is_active"),
      supabase.from("user_roles").select("user_id, roles(id, code, name)"),
      supabase
        .from("user_branch_assignments")
        .select("user_id, branches(id, code, name)"),
      supabase.from("roles").select("id, code, name").order("name"),
      supabase
        .from("branches")
        .select("id, code, name, is_active")
        .order("name"),
    ])

  const failed = [profiles, memberships, assignments, roles, branches].find(
    (result) => result.error,
  )
  if (failed?.error) {
    throw new Error(failed.error.message)
  }

  const rolesByUser = new Map<string, Named[]>()
  for (const row of memberships.data ?? []) {
    const role = one((row as { roles: Named | Named[] | null }).roles)
    if (!role) continue
    const list = rolesByUser.get(row.user_id) ?? []
    list.push(role)
    rolesByUser.set(row.user_id, list)
  }

  const branchesByUser = new Map<string, Named[]>()
  for (const row of assignments.data ?? []) {
    const branch = one((row as { branches: Named | Named[] | null }).branches)
    if (!branch) continue
    const list = branchesByUser.get(row.user_id) ?? []
    list.push(branch)
    branchesByUser.set(row.user_id, list)
  }

  const employees = ((profiles.data ?? []) as Profile[]).map((profile) => ({
    ...profile,
    roles: rolesByUser.get(profile.id) ?? [],
    branches: branchesByUser.get(profile.id) ?? [],
  }))

  return {
    employees,
    roles: (roles.data ?? []) as Named[],
    branches: (
      (branches.data ?? []) as (Named & { is_active: boolean })[]
    ).filter((branch) => branch.is_active),
  }
}

export function EmployeesPage() {
  useDocumentTitle("Employees")
  const access = useAccess()
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState<"all" | "active" | "inactive">("all")
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [pending, setPending] = useState<string | null>(null)

  const directory = useQuery({
    queryKey: ["employees"],
    queryFn: loadEmployees,
  })

  const refresh = async () => {
    await queryClient.invalidateQueries({ queryKey: ["employees"] })
    await queryClient.invalidateQueries({ queryKey: ["access"] })
  }

  const run = useMutation({
    mutationFn: async (action: () => Promise<string | null>) => {
      const message = await action()
      if (message) {
        throw new Error(message)
      }
    },
    onSuccess: async () => {
      notify.success("Saved")
      setPending(null)
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const employees = directory.data?.employees ?? []
  const selected =
    employees.find((employee) => employee.id === selectedId) ?? null
  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase()
    return (directory.data?.employees ?? []).filter((employee) => {
      const matchesStatus =
        status === "all" ||
        (status === "active" ? employee.is_active : !employee.is_active)
      const haystack = [
        employee.full_name,
        employee.employee_code ?? "",
        ...employee.roles.map((role) => role.name),
        ...employee.branches.map((branch) => branch.name),
      ]
        .join(" ")
        .toLowerCase()
      return matchesStatus && (term.length === 0 || haystack.includes(term))
    })
  }, [directory.data?.employees, search, status])

  return (
    <section>
      <PageHeader
        title="Employees"
        description="Sign-in accounts are added from Users & role. This screen assigns roles and operating sites."
      />
      <div className="mb-4 flex flex-col gap-3 sm:flex-row">
        <Input
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search name, code, role, or site"
          aria-label="Search employees"
        />
        <select
          aria-label="Filter by status"
          className="h-8 rounded-lg border border-input bg-transparent px-2.5 text-sm"
          value={status}
          onChange={(event) =>
            setStatus(event.target.value as "all" | "active" | "inactive")
          }
        >
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </select>
      </div>
      <div className="rounded-2xl bg-white ring-1 ring-slate-200/80">
        {directory.isLoading ? (
          <LoadingBlock label="Loading employees" />
        ) : directory.isError ? (
          <EmptyState
            icon={Users}
            title="Employees could not be loaded"
            description={
              directory.error instanceof Error
                ? directory.error.message
                : "Try again."
            }
          />
        ) : filtered.length === 0 ? (
          <EmptyState
            icon={Users}
            title="No employees to show"
            description="Profiles appear after a person is created in Supabase Auth. This list does not include sample people."
          />
        ) : (
          <ul className="divide-y divide-slate-200/80">
            {filtered.map((employee) => (
              <li key={employee.id}>
                <button
                  type="button"
                  className="flex w-full items-center justify-between gap-4 px-4 py-3 text-left hover:bg-slate-50"
                  onClick={() => setSelectedId(employee.id)}
                >
                  <span>
                    <span className="block text-sm font-medium">
                      {employee.full_name || "Unnamed employee"}
                    </span>
                    <span className="block text-xs text-muted-foreground">
                      {employee.employee_code || "No employee code"} ·{" "}
                      {employee.roles.map((role) => role.name).join(", ") ||
                        "No role"}
                    </span>
                  </span>
                  <StatusBadge
                    tone={employee.is_active ? "success" : "neutral"}
                  >
                    {employee.is_active ? "Active" : "Inactive"}
                  </StatusBadge>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
      <AppModal
        open={selected !== null}
        onOpenChange={(open) => {
          if (!open) setSelectedId(null)
        }}
        title={selected?.full_name || "Employee"}
        description="Role and site changes go through the database functions from Phase 2A."
        footer={
          selected && access.can("employees.manage") ? (
            <Button
              variant="outline"
              disabled={run.isPending}
              onClick={() =>
                setPending(selected.is_active ? "deactivate" : "activate")
              }
            >
              {selected.is_active ? "Deactivate" : "Activate"}
            </Button>
          ) : null
        }
      >
        {selected ? (
          <div className="flex flex-col gap-4 text-sm">
            <p>
              Status: {selected.is_active ? "Active" : "Inactive"}. Sites:{" "}
              {selected.branches.map((branch) => branch.name).join(", ") ||
                "None"}
              .
            </p>
            {access.can("roles.assign") ? (
              <label className="flex flex-col gap-1">
                Assign role
                <select
                  aria-label="Assign role"
                  className="h-8 rounded-lg border border-input px-2"
                  defaultValue=""
                  onChange={(event) => {
                    const role = event.target.value
                    event.target.value = ""
                    if (!role) return
                    void run.mutate(async () => {
                      const supabase = getSupabaseBrowserClient()
                      const result = await supabase?.rpc("assign_user_role", {
                        target_user: selected.id,
                        role_code: role,
                      })
                      return result?.error?.message ?? null
                    })
                  }}
                >
                  <option value="">Choose a role</option>
                  {(directory.data?.roles ?? []).map((role) => (
                    <option key={role.id} value={role.code}>
                      {role.name}
                    </option>
                  ))}
                </select>
              </label>
            ) : null}
            {access.can("roles.assign")
              ? selected.roles.map((role) => (
                  <Button
                    key={role.id}
                    variant="outline"
                    onClick={() =>
                      void run.mutate(async () => {
                        const supabase = getSupabaseBrowserClient()
                        const result = await supabase?.rpc("revoke_user_role", {
                          target_user: selected.id,
                          role_code: role.code,
                        })
                        return result?.error?.message ?? null
                      })
                    }
                  >
                    Revoke {role.name}
                  </Button>
                ))
              : null}
            {access.can("assignments.manage") ? (
              <label className="flex flex-col gap-1">
                Assign operating site
                <select
                  aria-label="Assign operating site"
                  className="h-8 rounded-lg border border-input px-2"
                  defaultValue=""
                  onChange={(event) => {
                    const branchId = event.target.value
                    event.target.value = ""
                    if (!branchId) return
                    void run.mutate(async () => {
                      const supabase = getSupabaseBrowserClient()
                      const result = await supabase?.rpc("assign_user_branch", {
                        target_user: selected.id,
                        target_branch: branchId,
                      })
                      return result?.error?.message ?? null
                    })
                  }}
                >
                  <option value="">Choose a site</option>
                  {(directory.data?.branches ?? []).map((branch) => (
                    <option key={branch.id} value={branch.id}>
                      {branch.name}
                    </option>
                  ))}
                </select>
              </label>
            ) : null}
          </div>
        ) : null}
      </AppModal>
      <AppModal
        open={pending !== null && selected !== null}
        onOpenChange={(open) => {
          if (!open) setPending(null)
        }}
        title="Confirm status change"
        description="This changes whether the person can use privileged functions. It does not delete their account."
        footer={
          <>
            <Button variant="outline" onClick={() => setPending(null)}>
              Cancel
            </Button>
            <Button
              disabled={run.isPending}
              onClick={() => {
                if (!selected) return
                const active = pending === "activate"
                void run.mutate(async () => {
                  const supabase = getSupabaseBrowserClient()
                  const result = await supabase?.rpc("set_employee_active", {
                    target_user: selected.id,
                    active,
                  })
                  return result?.error?.message ?? null
                })
              }}
            >
              Confirm
            </Button>
          </>
        }
      />
    </section>
  )
}
