import { useMemo, useState, type FormEvent } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Plus, UserRound } from "lucide-react"
import { AppModal } from "@/components/shared/AppModal"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { emailInitial } from "@/lib/utilities/email-initial"
import { notify } from "@/lib/utilities/notify"

type Person = {
  id: string
  full_name: string
  email: string | null
  phone_number: string | null
  is_active: boolean
  roles: string[]
}

type RoleOption = { code: string; name: string }

type Draft = {
  fullName: string
  email: string
  phone: string
  roleCode: string
  password: string
  passwordConfirm: string
}

const emptyDraft: Draft = {
  fullName: "",
  email: "",
  phone: "",
  roleCode: "",
  password: "",
  passwordConfirm: "",
}

function one<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null
  return Array.isArray(value) ? (value[0] ?? null) : value
}

async function loadPeople(): Promise<{
  people: Person[]
  roles: RoleOption[]
}> {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }

  const [profiles, memberships, roles] = await Promise.all([
    supabase
      .from("profiles")
      .select("id, full_name, email, phone_number, is_active"),
    supabase.from("user_roles").select("user_id, roles(name)"),
    supabase.from("roles").select("code, name").order("name"),
  ])
  if (profiles.error) throw new Error(profiles.error.message)
  if (memberships.error) throw new Error(memberships.error.message)
  if (roles.error) throw new Error(roles.error.message)

  const rolesByUser = new Map<string, string[]>()
  for (const row of memberships.data ?? []) {
    const role = one(
      (row as { roles: { name: string } | { name: string }[] | null }).roles,
    )
    if (!role?.name) continue
    const list = rolesByUser.get(row.user_id) ?? []
    list.push(role.name)
    rolesByUser.set(row.user_id, list)
  }

  return {
    people: (profiles.data ?? []).map((profile) => ({
      id: profile.id,
      full_name: profile.full_name,
      email: profile.email,
      phone_number: profile.phone_number,
      is_active: profile.is_active,
      roles: rolesByUser.get(profile.id) ?? [],
    })),
    roles: (roles.data ?? []) as RoleOption[],
  }
}

async function readFunctionError(error: unknown) {
  if (error && typeof error === "object" && "context" in error) {
    const context = (error as { context?: { json?: () => Promise<unknown> } })
      .context
    if (context && typeof context.json === "function") {
      try {
        const body = (await context.json()) as { error?: unknown }
        if (typeof body.error === "string" && body.error.length > 0) {
          return body.error
        }
      } catch {
        return "The user could not be created."
      }
    }
  }
  return "The user could not be created."
}

export function UsersRolesPage() {
  useDocumentTitle("Users & role")
  const access = useAccess()
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [role, setRole] = useState("all")
  const [open, setOpen] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [pinned, setPinned] = useState<Person | null>(null)
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const directory = useQuery({ queryKey: ["users-roles"], queryFn: loadPeople })

  const assignedRoles = useMemo(() => {
    const names = new Set<string>()
    for (const person of directory.data?.people ?? []) {
      for (const assigned of person.roles) names.add(assigned)
    }
    return [...names].sort((left, right) => left.localeCompare(right))
  }, [directory.data?.people])

  const visible = useMemo(() => {
    const term = search.trim().toLowerCase()
    return (directory.data?.people ?? []).filter((person) => {
      const matchesRole = role === "all" || person.roles.includes(role)
      const haystack = [
        person.full_name,
        person.email ?? "",
        person.phone_number ?? "",
        ...person.roles,
      ]
        .join(" ")
        .toLowerCase()
      return matchesRole && (term.length === 0 || haystack.includes(term))
    })
  }, [directory.data?.people, role, search])

  const createUser = useMutation({
    mutationFn: async (next: Draft) => {
      const supabase = getSupabaseBrowserClient()
      if (!supabase) throw new Error("Supabase is not configured.")
      const result = await supabase.functions.invoke("create-employee", {
        body: next,
      })
      if (result.error) {
        throw new Error(await readFunctionError(result.error))
      }
      const payload = result.data as { error?: string } | null
      if (payload?.error) throw new Error(payload.error)
    },
    onSuccess: async () => {
      notify.success("User added.")
      setOpen(false)
      setDraft(emptyDraft)
      await queryClient.invalidateQueries({ queryKey: ["users-roles"] })
    },
    onError: (error) => {
      notify.error(
        error instanceof Error
          ? error.message
          : "The user could not be created.",
      )
    },
  })

  function updateDraft(field: keyof Draft, value: string) {
    setDraft((current) => ({ ...current, [field]: value }))
  }

  function submit(event: FormEvent) {
    event.preventDefault()
    if (draft.password !== draft.passwordConfirm) {
      notify.error("Password and re-typed password do not match.")
      return
    }
    createUser.mutate(draft)
  }

  return (
    <section>
      <PageHeader
        title="Users & role"
        description="People who can sign in to SherlysOS."
        action={
          access.can("employees.manage") ? (
            <Button
              onClick={() => {
                setDraft(emptyDraft)
                setOpen(true)
              }}
            >
              <Plus />
              New
            </Button>
          ) : null
        }
      />
      <div className="mb-4 flex flex-col gap-3 sm:flex-row">
        <Input
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search name or role"
          aria-label="Search users"
        />
        <select
          aria-label="Filter by role"
          className="h-8 rounded-lg border border-input bg-transparent px-2.5 text-sm"
          value={role}
          onChange={(event) => setRole(event.target.value)}
        >
          <option value="all">All roles</option>
          {assignedRoles.map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </select>
      </div>
      <div className="rounded-2xl bg-white ring-1 ring-slate-200/80">
        {directory.isLoading ? (
          <LoadingBlock label="Loading users" />
        ) : directory.isError ? (
          <EmptyState
            icon={UserRound}
            title="Users could not be loaded"
            description={
              directory.error instanceof Error
                ? directory.error.message
                : "Try again."
            }
          />
        ) : visible.length === 0 ? (
          <EmptyState
            icon={UserRound}
            title="No users to show"
            description="Add a person with New, or clear the search."
          />
        ) : (
          <ul className="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-3">
            {visible.map((person) => {
              const label = person.full_name.trim() || "Unnamed user"
              return (
                <li key={person.id}>
                  <button
                    type="button"
                    className="w-full rounded-2xl bg-slate-50 p-4 text-left ring-1 ring-slate-200/80 hover:bg-white"
                    onClick={() => {
                      setPinned(person)
                      setSelectedId(person.id)
                    }}
                  >
                    <div className="flex items-center gap-3">
                      <span className="flex size-10 items-center justify-center rounded-full bg-brand/10 text-sm font-semibold text-brand">
                        {emailInitial(label)}
                      </span>
                      <p className="truncate text-sm font-medium">{label}</p>
                    </div>
                    <div className="mt-3 flex flex-wrap gap-2">
                      <StatusBadge
                        tone={person.is_active ? "success" : "neutral"}
                      >
                        {person.is_active ? "Active" : "Inactive"}
                      </StatusBadge>
                      {person.roles.length === 0 ? (
                        <StatusBadge>No role</StatusBadge>
                      ) : (
                        person.roles.map((assigned) => (
                          <StatusBadge key={assigned} tone="info">
                            {assigned}
                          </StatusBadge>
                        ))
                      )}
                    </div>
                  </button>
                </li>
              )
            })}
          </ul>
        )}
      </div>
      <AppModal
        open={open}
        onOpenChange={(next) => {
          if (!createUser.isPending) setOpen(next)
        }}
        title="New user"
        description="The person can sign in with this email and password."
        footer={
          <>
            <Button
              type="button"
              variant="outline"
              disabled={createUser.isPending}
              onClick={() => setOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              form="create-user"
              disabled={createUser.isPending}
            >
              {createUser.isPending ? "Adding…" : "Add user"}
            </Button>
          </>
        }
      >
        <form
          id="create-user"
          className="flex flex-col gap-3"
          onSubmit={submit}
        >
          <Label className="flex flex-col items-stretch gap-1.5">
            Name
            <Input
              required
              maxLength={160}
              value={draft.fullName}
              onChange={(event) => updateDraft("fullName", event.target.value)}
              autoComplete="name"
            />
          </Label>
          <Label className="flex flex-col items-stretch gap-1.5">
            Email
            <Input
              required
              type="email"
              value={draft.email}
              onChange={(event) => updateDraft("email", event.target.value)}
              autoComplete="off"
            />
          </Label>
          <Label className="flex flex-col items-stretch gap-1.5">
            Phone number
            <Input
              required
              type="tel"
              value={draft.phone}
              onChange={(event) => updateDraft("phone", event.target.value)}
              autoComplete="tel"
              placeholder="+91 …"
            />
          </Label>
          <Label className="flex flex-col items-stretch gap-1.5">
            User role
            <select
              required
              aria-label="User role"
              className="h-8 rounded-lg border border-input bg-transparent px-2.5 text-sm"
              value={draft.roleCode}
              onChange={(event) => updateDraft("roleCode", event.target.value)}
            >
              <option value="">Select a role</option>
              {(directory.data?.roles ?? []).map((option) => (
                <option key={option.code} value={option.code}>
                  {option.name}
                </option>
              ))}
            </select>
          </Label>
          <Label className="flex flex-col items-stretch gap-1.5">
            Password
            <Input
              required
              type="password"
              minLength={8}
              maxLength={72}
              value={draft.password}
              onChange={(event) => updateDraft("password", event.target.value)}
              autoComplete="new-password"
            />
          </Label>
          <Label className="flex flex-col items-stretch gap-1.5">
            Re-type password
            <Input
              required
              type="password"
              minLength={8}
              maxLength={72}
              value={draft.passwordConfirm}
              onChange={(event) =>
                updateDraft("passwordConfirm", event.target.value)
              }
              autoComplete="new-password"
            />
          </Label>
        </form>
      </AppModal>
      <AppModal
        open={selectedId !== null}
        onOpenChange={(next) => {
          if (!next) setSelectedId(null)
        }}
        title={pinned?.full_name.trim() || "User"}
        description="Details for this person."
      >
        {pinned ? (
          <dl className="grid gap-3 text-sm">
            <div>
              <dt className="text-muted-foreground">Name</dt>
              <dd className="mt-0.5 font-medium">
                {pinned.full_name.trim() || "Unnamed user"}
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Email</dt>
              <dd className="mt-0.5 font-medium">
                {pinned.email || "Not recorded"}
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Phone number</dt>
              <dd className="mt-0.5 font-medium">
                {pinned.phone_number || "Not recorded"}
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">User role</dt>
              <dd className="mt-0.5 font-medium">
                {pinned.roles.join(", ") || "No role"}
              </dd>
            </div>
          </dl>
        ) : null}
      </AppModal>
    </section>
  )
}
