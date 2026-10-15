import { useState } from "react"
import { zodResolver } from "@hookform/resolvers/zod"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useForm } from "react-hook-form"
import { AppModal } from "@/components/shared/AppModal"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import {
  ConfirmStatusDialog,
  FilterSelect,
  SearchField,
} from "@/features/masters/MasterControls"
import { matchesSearch, matchesStatus } from "@/lib/masters/filters"
import { RecordCard } from "@/features/masters/products/ProductsPage"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import { callRpc, loadRows } from "@/lib/masters/api"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { notify } from "@/lib/utilities/notify"
import { emptyToNull, shopSchema, type ShopValues } from "@/lib/validations/masters"

type Shop = {
  id: string
  name: string
  phone: string | null
  address: string | null
  is_active: boolean
}

type Assignment = {
  id: string
  shop_id: string
  salesperson_id: string
  is_active: boolean
}

type SalespersonOption = { id: string; name: string }

export function ShopsPage() {
  useDocumentTitle("Shops")
  const { can } = useAccess()
  const { session } = useAuth()
  const userId = session?.user.id
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [statusFilter, setStatusFilter] = useState("all")
  const [editing, setEditing] = useState<Shop | "new" | null>(null)
  const [statusTarget, setStatusTarget] = useState<Shop | null>(null)
  const canAssign = can("shops.assign")

  const shops = useQuery({
    queryKey: ["shops"],
    queryFn: () =>
      loadRows<Shop>("shops", "id, name, phone, address, is_active", "name"),
  })
  const assignments = useQuery({
    queryKey: ["shop-assignments"],
    queryFn: () =>
      loadRows<Assignment>(
        "shop_salesperson_assignments",
        "id, shop_id, salesperson_id, is_active",
        "assigned_at",
      ),
  })
  const salespeople = useQuery({
    queryKey: ["salesperson-options"],
    enabled: canAssign,
    queryFn: loadSalespeople,
  })

  const save = useMutation({
    mutationFn: async (values: ShopValues) => {
      const args = {
        shop_name: values.name,
        shop_phone: emptyToNull(values.phone),
        shop_address: emptyToNull(values.address),
      }
      if (editing === "new") {
        await callRpc("create_shop", args)
        return
      }
      if (!editing) return
      await callRpc("update_shop", { target_shop: editing.id, ...args })
    },
    onSuccess: async () => {
      setEditing(null)
      notify.success("Shop saved")
      await queryClient.invalidateQueries({ queryKey: ["shops"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: (shop: Shop) =>
      callRpc("set_shop_active", { target_shop: shop.id, active: !shop.is_active }),
    onSuccess: async () => {
      setStatusTarget(null)
      notify.success("Shop status updated")
      await queryClient.invalidateQueries({ queryKey: ["shops"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const assign = useMutation({
    mutationFn: async ({ shopId, salespersonId }: { shopId: string; salespersonId: string }) => {
      await callRpc("assign_shop_salesperson", {
        target_shop: shopId,
        target_salesperson: salespersonId,
      })
    },
    onSuccess: async () => {
      notify.success("Salesperson assigned")
      await queryClient.invalidateQueries({ queryKey: ["shop-assignments"] })
      await queryClient.invalidateQueries({ queryKey: ["shops"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const revoke = useMutation({
    mutationFn: async ({ shopId, salespersonId }: { shopId: string; salespersonId: string }) => {
      await callRpc("revoke_shop_salesperson", {
        target_shop: shopId,
        target_salesperson: salespersonId,
      })
    },
    onSuccess: async () => {
      notify.success("Assignment revoked")
      await queryClient.invalidateQueries({ queryKey: ["shop-assignments"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const names = new Map((salespeople.data ?? []).map((person) => [person.id, person.name]))
  const visible = (shops.data ?? []).filter(
    (shop) =>
      matchesSearch(search, [shop.name, shop.phone, shop.address]) &&
      matchesStatus(statusFilter, shop.is_active),
  )

  function canEdit(shopId: string) {
    if (canAssign) return true
    return (assignments.data ?? []).some(
      (row) => row.shop_id === shopId && row.salesperson_id === userId && row.is_active,
    )
  }

  return (
    <section>
      <PageHeader
        title="Shops"
        description="You see shops you are allowed to open. Creating a shop, and assigning another salesperson, stay with an administrator until shop ownership is approved."
        action={
          canAssign ? <Button onClick={() => setEditing("new")}>New shop</Button> : null
        }
      />
      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <SearchField label="Search shops" value={search} onChange={setSearch} />
        <FilterSelect label="Status" value={statusFilter} onChange={setStatusFilter}>
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </FilterSelect>
      </div>
      <RecordCard
        loading={shops.isLoading || assignments.isLoading}
        error={shops.error ?? assignments.error}
        empty={visible.length === 0}
        emptyTitle="No shops"
        emptyDescription="No shops are in your scope."
      >
        <ul className="divide-y divide-slate-200/80">
          {visible.map((shop) => {
            const shopAssignments = (assignments.data ?? []).filter(
              (row) => row.shop_id === shop.id,
            )
            return (
              <li key={shop.id} className="grid gap-3 px-4 py-3">
                <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                  <button type="button" className="text-left" onClick={() => setEditing(shop)}>
                    <span className="block text-sm font-medium">{shop.name}</span>
                    <span className="text-xs text-muted-foreground">
                      {[shop.phone, shop.address].filter(Boolean).join(" · ") || "No contact details"}
                    </span>
                  </button>
                  <span className="flex items-center gap-2">
                    <StatusBadge tone={shop.is_active ? "success" : "neutral"}>
                      {shop.is_active ? "Active" : "Inactive"}
                    </StatusBadge>
                    {canEdit(shop.id) ? (
                      <Button variant="outline" onClick={() => setStatusTarget(shop)}>
                        {shop.is_active ? "Deactivate" : "Activate"}
                      </Button>
                    ) : null}
                  </span>
                </div>
                <div className="grid gap-2">
                  <p className="text-xs font-medium text-muted-foreground">Salesperson assignments</p>
                  {shopAssignments.length === 0 ? (
                    <p className="text-sm text-muted-foreground">No assignments in your view.</p>
                  ) : (
                    <ul className="grid gap-1">
                      {shopAssignments.map((row) => (
                        <li key={row.id} className="flex items-center justify-between gap-2 text-sm">
                          <span>
                            {names.get(row.salesperson_id) ?? (row.salesperson_id === userId ? "You" : "Salesperson")}
                            {row.is_active ? "" : " · revoked"}
                          </span>
                          {canAssign && row.is_active ? (
                            <Button
                              variant="outline"
                              onClick={() =>
                                revoke.mutate({
                                  shopId: shop.id,
                                  salespersonId: row.salesperson_id,
                                })
                              }
                            >
                              Revoke
                            </Button>
                          ) : null}
                        </li>
                      ))}
                    </ul>
                  )}
                  {canAssign && shop.is_active ? (
                    <AssignForm
                      people={salespeople.data ?? []}
                      pending={assign.isPending}
                      onAssign={(salespersonId) =>
                        assign.mutate({ shopId: shop.id, salespersonId })
                      }
                    />
                  ) : null}
                </div>
              </li>
            )
          })}
        </ul>
      </RecordCard>
      {editing ? (
        <ShopDialog
          key={editing === "new" ? "new" : editing.id}
          shop={editing === "new" ? null : editing}
          canSave={editing === "new" ? canAssign : canEdit(editing.id)}
          pending={save.isPending}
          onClose={() => setEditing(null)}
          onSave={(values) => save.mutate(values)}
        />
      ) : null}
      <ConfirmStatusDialog
        open={Boolean(statusTarget)}
        name={statusTarget?.name ?? "shop"}
        active={Boolean(statusTarget?.is_active)}
        pending={toggle.isPending}
        onOpenChange={(open) => {
          if (!open) setStatusTarget(null)
        }}
        onConfirm={() => {
          if (statusTarget) toggle.mutate(statusTarget)
        }}
      />
    </section>
  )
}

async function loadSalespeople(): Promise<SalespersonOption[]> {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) throw new Error("Supabase is not configured.")
  const result = await supabase
    .from("user_roles")
    .select("user_id, profiles(full_name, is_active), roles(code)")
  if (result.error) throw new Error(result.error.message)
  const rows = (result.data ?? []) as unknown as Array<{
    user_id: string
    profiles: { full_name: string; is_active: boolean } | { full_name: string; is_active: boolean }[] | null
    roles: { code: string } | { code: string }[] | null
  }>
  return rows.flatMap((row) => {
    const role = Array.isArray(row.roles) ? row.roles[0] : row.roles
    const profile = Array.isArray(row.profiles) ? row.profiles[0] : row.profiles
    if (role?.code !== "salesperson" || !profile?.is_active) return []
    return [{ id: row.user_id, name: profile.full_name || "Salesperson" }]
  })
}

function AssignForm({
  people,
  pending,
  onAssign,
}: {
  people: SalespersonOption[]
  pending: boolean
  onAssign: (salespersonId: string) => void
}) {
  const [assignee, setAssignee] = useState("")
  return (
    <form
      className="grid gap-2 sm:grid-cols-[1fr_auto]"
      onSubmit={(event) => {
        event.preventDefault()
        if (!assignee) return
        onAssign(assignee)
        setAssignee("")
      }}
    >
      <FilterSelect label="Salesperson" value={assignee} onChange={setAssignee}>
        <option value="">Choose a salesperson</option>
        {people.map((person) => (
          <option key={person.id} value={person.id}>
            {person.name}
          </option>
        ))}
      </FilterSelect>
      <Button type="submit" disabled={!assignee || pending}>
        Assign
      </Button>
    </form>
  )
}

function ShopDialog({
  shop,
  canSave,
  pending,
  onClose,
  onSave,
}: {
  shop: Shop | null
  canSave: boolean
  pending: boolean
  onClose: () => void
  onSave: (values: ShopValues) => void
}) {
  const form = useForm<ShopValues>({
    resolver: zodResolver(shopSchema),
    defaultValues: {
      name: shop?.name ?? "",
      phone: shop?.phone ?? "",
      address: shop?.address ?? "",
    },
  })

  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={shop ? shop.name : "New shop"}
      description="A shop is not tied to a godown. That relationship is still undecided."
      footer={
        canSave ? (
          <>
            <Button variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" form="shop-form" disabled={pending}>Save</Button>
          </>
        ) : (
          <Button variant="outline" onClick={onClose}>Close</Button>
        )
      }
    >
      <form id="shop-form" className="grid gap-3" onSubmit={form.handleSubmit(onSave)}>
        <TextField label="Shop name" {...form.register("name")} error={form.formState.errors.name?.message} disabled={!canSave} />
        <TextField label="Phone" {...form.register("phone")} error={form.formState.errors.phone?.message} disabled={!canSave} />
        <TextField label="Address" {...form.register("address")} error={form.formState.errors.address?.message} disabled={!canSave} />
      </form>
    </AppModal>
  )
}