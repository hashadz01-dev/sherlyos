import { useState } from "react"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { AppModal } from "@/components/shared/AppModal"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { FilterSelect } from "@/features/masters/MasterControls"
import {
  weekdayLabel,
  type SalesRouteRow,
  type ShopListRow,
  type ShopRouteMembership,
} from "@/lib/masters/shop-routes"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { shopSchema, type ShopValues } from "@/lib/validations/masters"

export type ShopAssignment = {
  id: string
  shop_id: string
  salesperson_id: string
  is_active: boolean
}

export type SalespersonOption = { id: string; name: string }

export async function loadSalespeople(): Promise<SalespersonOption[]> {
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

export function AssignForm({
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

export function ShopDialog({
  shop,
  routes,
  memberships,
  assignments,
  salespersonNames,
  canSave,
  canPersistRoute,
  pending,
  onClose,
  onSave,
}: {
  shop: ShopListRow | null
  routes: SalesRouteRow[]
  memberships: ShopRouteMembership[]
  assignments: ShopAssignment[]
  salespersonNames: Map<string, string>
  canSave: boolean
  canPersistRoute: boolean
  pending: boolean
  onClose: () => void
  onSave: (values: ShopValues) => void
}) {
  const shopMemberships = memberships.filter((row) => row.shop_id === shop?.id)
  const shopAssignments = assignments.filter((row) => row.shop_id === shop?.id)
  const form = useForm<ShopValues>({
    resolver: zodResolver(shopSchema),
    defaultValues: {
      name: shop?.name ?? "",
      phone: shop?.phone ?? "",
      address: shop?.address ?? "",
      routeId: shopMemberships[0]?.route_id ?? "",
    },
  })

  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={shop ? shop.name : "New shop"}
      description="A shop is not tied to a godown. Route is a sales-visit area, not a delivery vehicle run."
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
        <FilterSelect
          label="Sales route"
          value={form.watch("routeId") ?? ""}
          onChange={(value) => form.setValue("routeId", value)}
        >
          <option value="">{canPersistRoute ? "No route yet" : "Route assignment waits for schema approval"}</option>
          {canPersistRoute
            ? routes.map((route) => (
                <option key={route.id} value={route.id}>
                  {route.name} · {weekdayLabel(route.weekday)}
                </option>
              ))
            : null}
        </FilterSelect>
        {shop ? (
          <div className="grid gap-1 text-sm">
            <p className="font-medium">Visit sequence</p>
            {shopMemberships.length === 0 ? (
              <p className="text-muted-foreground">No route membership yet.</p>
            ) : (
              <ul className="grid gap-1 text-muted-foreground">
                {shopMemberships.map((row) => {
                  const route = routes.find((item) => item.id === row.route_id)
                  return (
                    <li key={`${row.route_id}-${row.visit_sequence}`}>
                      {route?.name ?? "Route"} · sequence {row.visit_sequence} · {weekdayLabel(route?.weekday)}
                    </li>
                  )
                })}
              </ul>
            )}
            <p className="mt-2 font-medium">Assignments</p>
            {shopAssignments.length === 0 ? (
              <p className="text-muted-foreground">None in your view.</p>
            ) : (
              <ul className="grid gap-1 text-muted-foreground">
                {shopAssignments.map((row) => (
                  <li key={row.id}>
                    {salespersonNames.get(row.salesperson_id) ?? "Salesperson"}
                    {row.is_active ? "" : " · revoked"}
                  </li>
                ))}
              </ul>
            )}
            <p className="text-muted-foreground">Status: {shop.is_active ? "Active" : "Inactive"}</p>
          </div>
        ) : null}
      </form>
    </AppModal>
  )
}
