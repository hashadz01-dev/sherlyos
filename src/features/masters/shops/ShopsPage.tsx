import { useMemo, useState } from "react"
import { Link } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import {
  ConfirmStatusDialog,
  FilterSelect,
  FilterToolbar,
  SearchField,
} from "@/features/masters/MasterControls"
import { RecordCard } from "@/features/masters/products/ProductsPage"
import {
  AssignForm,
  ShopDialog,
  loadSalespeople,
  type ShopAssignment,
} from "@/features/masters/shops/shop-form"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import { callRpc, loadRows, loadRowsIfPresent } from "@/lib/masters/api"
import {
  WEEKDAYS,
  catalogRoutesAsRows,
  groupShopsByRoute,
  nextVisitSequence,
  weekdayLabel,
  type SalesRouteRow,
  type ShopListRow,
  type ShopRouteMembership,
} from "@/lib/masters/shop-routes"
import { notify } from "@/lib/utilities/notify"
import { emptyToNull, type ShopValues } from "@/lib/validations/masters"

export function ShopsPage() {
  useDocumentTitle("Shops")
  const { can } = useAccess()
  const { session } = useAuth()
  const userId = session?.user.id
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [statusFilter, setStatusFilter] = useState("all")
  const [routeFilter, setRouteFilter] = useState("all")
  const [weekdayFilter, setWeekdayFilter] = useState("all")
  const [editing, setEditing] = useState<ShopListRow | "new" | null>(null)
  const [statusTarget, setStatusTarget] = useState<ShopListRow | null>(null)
  const canAssign = can("shops.assign")

  const shops = useQuery({
    queryKey: ["shops"],
    queryFn: () =>
      loadRows<ShopListRow>("shops", "id, name, phone, address, is_active", "name"),
  })
  const assignments = useQuery({
    queryKey: ["shop-assignments"],
    queryFn: () =>
      loadRows<ShopAssignment>(
        "shop_salesperson_assignments",
        "id, shop_id, salesperson_id, is_active",
        "assigned_at",
      ),
  })
  const persistedRoutes = useQuery({
    queryKey: ["sales-routes"],
    queryFn: () =>
      loadRowsIfPresent<SalesRouteRow>(
        "sales_routes",
        "id, code, name, weekday, sort_order, is_active",
        "sort_order",
      ),
  })
  const memberships = useQuery({
    queryKey: ["shop-route-memberships"],
    queryFn: () =>
      loadRowsIfPresent<ShopRouteMembership>(
        "shop_sales_route_memberships",
        "shop_id, route_id, visit_sequence",
        "visit_sequence",
      ),
  })
  const salespeople = useQuery({
    queryKey: ["salesperson-options"],
    enabled: canAssign,
    queryFn: loadSalespeople,
  })

  const persisted = persistedRoutes.data
  const routes = useMemo(
    () => (persisted && persisted.length > 0 ? persisted : catalogRoutesAsRows()),
    [persisted],
  )
  const canPersistRoute = Boolean(canAssign && persisted && persisted.length > 0)

  const save = useMutation({
    mutationFn: async (values: ShopValues) => {
      const args = {
        shop_name: values.name,
        shop_phone: emptyToNull(values.phone),
        shop_address: emptyToNull(values.address),
      }
      let shopId = editing === "new" || !editing ? "" : editing.id
      if (editing === "new") {
        shopId = await callRpc<string>("create_shop", args)
      } else if (editing) {
        await callRpc("update_shop", { target_shop: editing.id, ...args })
      }
      if (canPersistRoute && values.routeId) {
        const existing = (memberships.data ?? []).find(
          (row) => row.shop_id === shopId && row.route_id === values.routeId,
        )
        await callRpc("set_shop_sales_route", {
          target_shop: shopId,
          target_route: values.routeId,
          visit_sequence:
            existing?.visit_sequence ??
            nextVisitSequence(memberships.data ?? [], values.routeId),
        })
      }
    },
    onSuccess: async () => {
      setEditing(null)
      notify.success("Shop saved")
      await queryClient.invalidateQueries({ queryKey: ["shops"] })
      await queryClient.invalidateQueries({ queryKey: ["shop-route-memberships"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: (shop: ShopListRow) =>
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
  const groups = useMemo(
    () =>
      groupShopsByRoute({
        shops: shops.data ?? [],
        routes,
        memberships: memberships.data ?? [],
        search,
        status: statusFilter,
        routeId: routeFilter,
        weekday: weekdayFilter,
      }),
    [shops.data, routes, memberships.data, search, statusFilter, routeFilter, weekdayFilter],
  )
  const visibleCount = groups.reduce((sum, group) => sum + group.shopCount, 0)

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
        description="Central shop master grouped by geographic sales route. Creating a shop, assigning a route, and assigning another salesperson stay with an administrator."
        action={
          canAssign ? <Button onClick={() => setEditing("new")}>New shop</Button> : null
        }
      />
      <FilterToolbar>
        <SearchField label="Search shops" value={search} onChange={setSearch} />
        <FilterSelect label="Route" value={routeFilter} onChange={setRouteFilter}>
          <option value="all">All shops</option>
          {routes.map((route) => (
            <option key={route.id} value={route.id}>
              {route.name}
            </option>
          ))}
          <option value="unassigned">Unassigned route</option>
        </FilterSelect>
        <FilterSelect label="Weekday" value={weekdayFilter} onChange={setWeekdayFilter}>
          <option value="all">All weekdays</option>
          {WEEKDAYS.map((day) => (
            <option key={day} value={day}>
              {weekdayLabel(day)}
            </option>
          ))}
          <option value="unassigned">Unconfirmed</option>
        </FilterSelect>
        <FilterSelect label="Status" value={statusFilter} onChange={setStatusFilter}>
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </FilterSelect>
      </FilterToolbar>
      <RecordCard
        loading={shops.isLoading || assignments.isLoading}
        error={shops.error ?? assignments.error ?? persistedRoutes.error ?? memberships.error}
        empty={visibleCount === 0}
        emptyTitle="No shops"
        emptyDescription="No shops match these filters in your scope."
      >
        <div className="divide-y divide-slate-200/80">
          {groups.map((group) => (
            <section key={group.routeId} className="px-4 py-3">
              <header className="mb-2 flex flex-wrap items-baseline justify-between gap-2">
                <h2 className="text-sm font-semibold">
                  {group.routeName}
                  <span className="ml-2 text-xs font-normal text-muted-foreground">
                    {group.weekdayLabel}
                  </span>
                </h2>
                <p className="text-xs text-muted-foreground">
                  {group.shopCount} {group.shopCount === 1 ? "shop" : "shops"}
                </p>
              </header>
              <ul className="divide-y divide-slate-100">
                {group.shops.map((shop) => {
                  const shopAssignments = (assignments.data ?? []).filter(
                    (row) => row.shop_id === shop.id,
                  )
                  return (
                    <li key={`${group.routeId}-${shop.id}`} className="grid gap-3 py-3">
                      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                        <Link to={`/masters/shops/${shop.id}`} className="text-left">
                          <span className="block text-sm font-medium">
                            {shop.visitSequence != null ? `${shop.visitSequence}. ` : ""}
                            {shop.name}
                          </span>
                          <span className="text-xs text-muted-foreground">
                            {[shop.phone, shop.address].filter(Boolean).join(" · ") ||
                              "No contact details"}
                          </span>
                        </Link>
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
                        <p className="text-xs font-medium text-muted-foreground">
                          Salesperson assignments
                        </p>
                        {shopAssignments.length === 0 ? (
                          <p className="text-sm text-muted-foreground">No assignments in your view.</p>
                        ) : (
                          <ul className="grid gap-1">
                            {shopAssignments.map((row) => (
                              <li key={row.id} className="flex items-center justify-between gap-2 text-sm">
                                <span>
                                  {names.get(row.salesperson_id) ??
                                    (row.salesperson_id === userId ? "You" : "Salesperson")}
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
            </section>
          ))}
        </div>
      </RecordCard>
      {editing ? (
        <ShopDialog
          key={editing === "new" ? "new" : editing.id}
          shop={editing === "new" ? null : editing}
          routes={routes}
          memberships={memberships.data ?? []}
          assignments={assignments.data ?? []}
          salespersonNames={names}
          canSave={editing === "new" ? canAssign : canEdit(editing.id)}
          canPersistRoute={canPersistRoute}
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
