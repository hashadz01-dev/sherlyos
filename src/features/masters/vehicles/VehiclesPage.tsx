import { useState } from "react"
import { zodResolver } from "@hookform/resolvers/zod"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useForm } from "react-hook-form"
import { AppModal } from "@/components/shared/AppModal"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { RecordCard } from "@/features/masters/products/ProductsPage"
import {
  ConfirmStatusDialog,
  FilterSelect,
  SearchField,
} from "@/features/masters/MasterControls"
import { matchesSearch, matchesStatus } from "@/lib/masters/filters"
import { vehicleTypeLabel } from "@/lib/dispatch/rules"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { callRpc, loadRows } from "@/lib/masters/api"
import { notify } from "@/lib/utilities/notify"
import {
  emptyToNull,
  vehicleSchema,
  vehicleTypes,
  type VehicleValues,
} from "@/lib/validations/masters"

type Vehicle = {
  id: string
  branch_id: string | null
  registration_number: string
  vehicle_type: string
  display_name: string
  capacity_cases: number | null
  notes: string | null
  is_active: boolean
}

export function VehiclesPage() {
  useDocumentTitle("Vehicles")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [statusFilter, setStatusFilter] = useState("all")
  const [editing, setEditing] = useState<Vehicle | "new" | null>(null)
  const [statusTarget, setStatusTarget] = useState<Vehicle | null>(null)
  const canManage = can("vehicles.manage")

  const vehicles = useQuery({
    queryKey: ["vehicles"],
    queryFn: () =>
      loadRows<Vehicle>(
        "vehicles",
        "id, branch_id, registration_number, vehicle_type, display_name, capacity_cases, notes, is_active",
        "display_name",
      ),
  })

  const save = useMutation({
    mutationFn: async (values: VehicleValues) => {
      const notes = emptyToNull(values.notes)
      const capacity = emptyToNull(values.capacityCases)
      const args = {
        registration_number: values.registrationNumber,
        vehicle_type: values.vehicleType,
        display_name: values.displayName,
        capacity_cases: capacity ? Number(capacity) : null,
        operational_notes: notes,
      }
      if (editing === "new") {
        // Shared fleet: godown is chosen later on the delivery run.
        await callRpc("create_vehicle", {
          target_branch: null,
          ...args,
        })
        return
      }
      if (!editing) return
      await callRpc("update_vehicle", {
        target_vehicle: editing.id,
        ...args,
      })
    },
    onSuccess: async () => {
      setEditing(null)
      notify.success("Vehicle saved")
      await queryClient.invalidateQueries({ queryKey: ["vehicles"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: (vehicle: Vehicle) =>
      callRpc("set_vehicle_active", {
        target_vehicle: vehicle.id,
        active: !vehicle.is_active,
      }),
    onSuccess: async () => {
      setStatusTarget(null)
      notify.success("Vehicle status updated")
      await queryClient.invalidateQueries({ queryKey: ["vehicles"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const visible = (vehicles.data ?? []).filter(
    (vehicle) =>
      matchesSearch(search, [
        vehicle.display_name,
        vehicle.registration_number,
        vehicleTypeLabel[vehicle.vehicle_type] ?? vehicle.vehicle_type,
      ]) && matchesStatus(statusFilter, vehicle.is_active),
  )

  return (
    <section>
      <PageHeader
        title="Vehicles"
        description="Shared delivery fleet. Assign an available vehicle when a shop delivery starts. Deactivating a vehicle keeps historical deliveries readable and does not restore stock."
        action={
          canManage ? (
            <Button onClick={() => setEditing("new")}>New vehicle</Button>
          ) : null
        }
      />
      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <SearchField label="Search vehicles" value={search} onChange={setSearch} />
        <FilterSelect label="Status" value={statusFilter} onChange={setStatusFilter}>
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </FilterSelect>
      </div>
      <RecordCard
        loading={vehicles.isLoading}
        error={vehicles.error}
        empty={visible.length === 0}
        emptyTitle="No vehicles"
        emptyDescription="No vehicles match this view."
      >
        <ul className="divide-y divide-slate-200/80">
          {visible.map((vehicle) => (
            <li
              key={vehicle.id}
              className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <button type="button" className="text-left" onClick={() => setEditing(vehicle)}>
                <span className="block text-sm font-medium">{vehicle.display_name}</span>
                <span className="text-xs text-muted-foreground">
                  {vehicle.registration_number}
                  {` · ${vehicleTypeLabel[vehicle.vehicle_type] ?? vehicle.vehicle_type}`}
                  {vehicle.capacity_cases
                    ? ` · ${vehicle.capacity_cases} cases (informational)`
                    : ""}
                </span>
              </button>
              <span className="flex items-center gap-2">
                <StatusBadge tone={vehicle.is_active ? "success" : "neutral"}>
                  {vehicle.is_active ? "Active" : "Inactive"}
                </StatusBadge>
                {canManage ? (
                  <Button variant="outline" onClick={() => setStatusTarget(vehicle)}>
                    {vehicle.is_active ? "Deactivate" : "Activate"}
                  </Button>
                ) : null}
              </span>
            </li>
          ))}
        </ul>
      </RecordCard>
      {editing ? (
        <VehicleDialog
          key={editing === "new" ? "new" : editing.id}
          vehicle={editing === "new" ? null : editing}
          canSave={canManage}
          pending={save.isPending}
          onClose={() => setEditing(null)}
          onSave={(values) => save.mutate(values)}
        />
      ) : null}
      <ConfirmStatusDialog
        open={Boolean(statusTarget)}
        name={statusTarget?.display_name ?? "vehicle"}
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

function VehicleDialog({
  vehicle,
  canSave,
  pending,
  onClose,
  onSave,
}: {
  vehicle: Vehicle | null
  canSave: boolean
  pending: boolean
  onClose: () => void
  onSave: (values: VehicleValues) => void
}) {
  const form = useForm<VehicleValues>({
    resolver: zodResolver(vehicleSchema),
    defaultValues: {
      registrationNumber: vehicle?.registration_number ?? "",
      vehicleType: (vehicle?.vehicle_type as VehicleValues["vehicleType"]) ?? "other",
      displayName: vehicle?.display_name ?? "",
      capacityCases: vehicle?.capacity_cases ? String(vehicle.capacity_cases) : "",
      notes: vehicle?.notes ?? "",
    },
  })

  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={vehicle ? vehicle.display_name : "New vehicle"}
      footer={
        canSave ? (
          <>
            <Button variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" form="vehicle-form" disabled={pending}>
              Save
            </Button>
          </>
        ) : (
          <Button variant="outline" onClick={onClose}>
            Close
          </Button>
        )
      }
    >
      <form id="vehicle-form" className="grid gap-3" onSubmit={form.handleSubmit(onSave)}>
        <TextField
          label="Registration number"
          {...form.register("registrationNumber")}
          error={form.formState.errors.registrationNumber?.message}
          disabled={!canSave}
        />
        <label className="grid gap-1 text-sm font-medium">
          Vehicle type
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            disabled={!canSave}
            aria-label="Vehicle type"
            {...form.register("vehicleType")}
          >
            {vehicleTypes.map((type) => (
              <option key={type} value={type}>
                {vehicleTypeLabel[type]}
              </option>
            ))}
          </select>
        </label>
        <TextField
          label="Display name"
          {...form.register("displayName")}
          error={form.formState.errors.displayName?.message}
          disabled={!canSave}
        />
        <TextField
          label="Capacity in cases (optional, not enforced)"
          {...form.register("capacityCases")}
          error={form.formState.errors.capacityCases?.message}
          disabled={!canSave}
        />
        <TextField
          label="Notes"
          {...form.register("notes")}
          error={form.formState.errors.notes?.message}
          disabled={!canSave}
        />
      </form>
    </AppModal>
  )
}
