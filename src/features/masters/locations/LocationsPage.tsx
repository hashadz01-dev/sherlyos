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
import { useAccess } from "@/lib/access/use-access"
import { callRpc, loadRows } from "@/lib/masters/api"
import { notify } from "@/lib/utilities/notify"
import {
  crateSchema,
  emptyToNull,
  zoneSchema,
  type CrateValues,
  type ZoneValues,
} from "@/lib/validations/masters"

type Branch = { id: string; code: string; name: string; is_active: boolean }
type Zone = {
  id: string
  branch_id: string
  code: string
  name: string
  description: string | null
  is_active: boolean
}
type Crate = {
  id: string
  zone_id: string
  code: string
  name: string | null
  description: string | null
  is_active: boolean
}

export function LocationsPage() {
  useDocumentTitle("Godown locations")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [branchId, setBranchId] = useState("")
  const [zoneId, setZoneId] = useState("")
  const [zoneSearch, setZoneSearch] = useState("")
  const [crateSearch, setCrateSearch] = useState("")
  const [zoneStatus, setZoneStatus] = useState("all")
  const [crateStatus, setCrateStatus] = useState("all")
  const [editingZone, setEditingZone] = useState<Zone | "new" | null>(null)
  const [editingCrate, setEditingCrate] = useState<Crate | "new" | null>(null)
  const [statusZone, setStatusZone] = useState<Zone | null>(null)
  const [statusCrate, setStatusCrate] = useState<Crate | null>(null)
  const canManage = can("locations.manage")

  const branches = useQuery({
    queryKey: ["branches"],
    queryFn: () => loadRows<Branch>("branches", "id, code, name, is_active", "name"),
  })
  const selectedBranch = branchId || branches.data?.[0]?.id || ""
  const zones = useQuery({
    queryKey: ["zones", selectedBranch],
    enabled: Boolean(selectedBranch),
    queryFn: async () => {
      const rows = await loadRows<Zone>(
        "zones",
        "id, branch_id, code, name, description, is_active",
        "code",
      )
      return rows.filter((zone) => zone.branch_id === selectedBranch)
    },
  })
  const selectedZone = zones.data?.some((zone) => zone.id === zoneId)
    ? zoneId
    : (zones.data?.[0]?.id ?? "")
  const crates = useQuery({
    queryKey: ["crates", selectedZone],
    enabled: Boolean(selectedZone),
    queryFn: async () => {
      const rows = await loadRows<Crate>(
        "crates",
        "id, zone_id, code, name, description, is_active",
        "code",
      )
      return rows.filter((crate) => crate.zone_id === selectedZone)
    },
  })

  const saveZone = useMutation({
    mutationFn: async (values: ZoneValues) => {
      const description = emptyToNull(values.description)
      if (editingZone === "new") {
        await callRpc("create_zone", {
          target_branch: selectedBranch,
          zone_code: values.code,
          zone_name: values.name,
          zone_description: description,
        })
        return
      }
      if (!editingZone) return
      await callRpc("update_zone", {
        target_zone: editingZone.id,
        zone_code: values.code,
        zone_name: values.name,
        zone_description: description,
      })
    },
    onSuccess: async () => {
      setEditingZone(null)
      notify.success("Zone saved")
      await queryClient.invalidateQueries({ queryKey: ["zones"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggleZone = useMutation({
    mutationFn: (zone: Zone) =>
      callRpc("set_zone_active", { target_zone: zone.id, active: !zone.is_active }),
    onSuccess: async () => {
      setStatusZone(null)
      notify.success("Zone status updated")
      await queryClient.invalidateQueries({ queryKey: ["zones"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const saveCrate = useMutation({
    mutationFn: async (values: CrateValues) => {
      const description = emptyToNull(values.description)
      const name = emptyToNull(values.name)
      if (editingCrate === "new") {
        await callRpc("create_crate", {
          target_zone: selectedZone,
          crate_code: values.code,
          crate_name: name,
          crate_description: description,
        })
        return
      }
      if (!editingCrate) return
      await callRpc("update_crate", {
        target_crate: editingCrate.id,
        crate_code: values.code,
        crate_name: name,
        crate_description: description,
      })
    },
    onSuccess: async () => {
      setEditingCrate(null)
      notify.success("Crate saved")
      await queryClient.invalidateQueries({ queryKey: ["crates"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggleCrate = useMutation({
    mutationFn: (crate: Crate) =>
      callRpc("set_crate_active", { target_crate: crate.id, active: !crate.is_active }),
    onSuccess: async () => {
      setStatusCrate(null)
      notify.success("Crate status updated")
      await queryClient.invalidateQueries({ queryKey: ["crates"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const visibleZones = (zones.data ?? []).filter(
    (zone) =>
      matchesSearch(zoneSearch, [zone.code, zone.name, zone.description]) &&
      matchesStatus(zoneStatus, zone.is_active),
  )
  const visibleCrates = (crates.data ?? []).filter(
    (crate) =>
      matchesSearch(crateSearch, [crate.code, crate.name, crate.description]) &&
      matchesStatus(crateStatus, crate.is_active),
  )
  const branch = (branches.data ?? []).find((item) => item.id === selectedBranch)

  return (
    <section>
      <PageHeader
        title="Godown locations"
        description="Zones belong to a godown, and crates belong to a zone. This screen does not show stock. Godowns themselves are maintained under Godowns."
      />
      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <FilterSelect
          label="Godown"
          value={selectedBranch}
          onChange={(value) => {
            setBranchId(value)
            setZoneId("")
          }}
        >
          {(branches.data ?? []).length === 0 ? <option value="">No authorized godown</option> : null}
          {(branches.data ?? []).map((item) => (
            <option key={item.id} value={item.id}>
              {item.name} ({item.code})
            </option>
          ))}
        </FilterSelect>
        <p className="self-center text-sm text-muted-foreground">
          {branch
            ? `${branch.name} is ${branch.is_active ? "active" : "inactive"}. A zone cannot be moved to another godown.`
            : "No godown is available for this account."}
        </p>
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <div>
          <div className="mb-3 flex items-center justify-between gap-3">
            <h2 className="text-lg font-semibold">Zones</h2>
            {canManage && selectedBranch ? (
              <Button onClick={() => setEditingZone("new")}>New zone</Button>
            ) : null}
          </div>
          <div className="mb-3 grid gap-3 sm:grid-cols-2">
            <SearchField label="Search zones" value={zoneSearch} onChange={setZoneSearch} />
            <FilterSelect label="Zone status" value={zoneStatus} onChange={setZoneStatus}>
              <option value="all">All statuses</option>
              <option value="active">Active</option>
              <option value="inactive">Inactive</option>
            </FilterSelect>
          </div>
          <RecordCard
            loading={branches.isLoading || zones.isLoading}
            error={branches.error ?? zones.error}
            empty={visibleZones.length === 0}
            emptyTitle="No zones"
            emptyDescription="This godown has no matching zones."
          >
            <ul className="divide-y divide-slate-200/80">
              {visibleZones.map((zone) => (
                <li key={zone.id} className="flex items-center justify-between gap-2 px-4 py-3">
                  <button type="button" className="text-left" onClick={() => setZoneId(zone.id)}>
                    <span className="block text-sm font-medium">{zone.name}</span>
                    <span className="text-xs text-muted-foreground">{zone.code}</span>
                  </button>
                  <span className="flex items-center gap-2">
                    {zone.id === selectedZone ? <StatusBadge tone="info">Selected</StatusBadge> : null}
                    <StatusBadge tone={zone.is_active ? "success" : "neutral"}>
                      {zone.is_active ? "Active" : "Inactive"}
                    </StatusBadge>
                    {canManage ? (
                      <>
                        <Button variant="outline" onClick={() => setEditingZone(zone)}>Edit</Button>
                        <Button variant="outline" onClick={() => setStatusZone(zone)}>
                          {zone.is_active ? "Deactivate" : "Activate"}
                        </Button>
                      </>
                    ) : null}
                  </span>
                </li>
              ))}
            </ul>
          </RecordCard>
        </div>
        <div>
          <div className="mb-3 flex items-center justify-between gap-3">
            <h2 className="text-lg font-semibold">Crates</h2>
            {canManage && selectedZone ? (
              <Button onClick={() => setEditingCrate("new")}>New crate</Button>
            ) : null}
          </div>
          <div className="mb-3 grid gap-3 sm:grid-cols-2">
            <SearchField label="Search crates" value={crateSearch} onChange={setCrateSearch} />
            <FilterSelect label="Crate status" value={crateStatus} onChange={setCrateStatus}>
              <option value="all">All statuses</option>
              <option value="active">Active</option>
              <option value="inactive">Inactive</option>
            </FilterSelect>
          </div>
          <RecordCard
            loading={Boolean(selectedZone) && crates.isLoading}
            error={crates.error}
            empty={!selectedZone || visibleCrates.length === 0}
            emptyTitle="No crates"
            emptyDescription="Select a zone to see its crates."
          >
            <ul className="divide-y divide-slate-200/80">
              {visibleCrates.map((crate) => (
                <li key={crate.id} className="flex items-center justify-between gap-2 px-4 py-3">
                  <span>
                    <span className="block text-sm font-medium">{crate.name || crate.code}</span>
                    <span className="text-xs text-muted-foreground">{crate.code}</span>
                  </span>
                  <span className="flex items-center gap-2">
                    <StatusBadge tone={crate.is_active ? "success" : "neutral"}>
                      {crate.is_active ? "Active" : "Inactive"}
                    </StatusBadge>
                    {canManage ? (
                      <>
                        <Button variant="outline" onClick={() => setEditingCrate(crate)}>Edit</Button>
                        <Button variant="outline" onClick={() => setStatusCrate(crate)}>
                          {crate.is_active ? "Deactivate" : "Activate"}
                        </Button>
                      </>
                    ) : null}
                  </span>
                </li>
              ))}
            </ul>
          </RecordCard>
        </div>
      </div>
      {editingZone ? (
        <ZoneDialog
          key={editingZone === "new" ? "new" : editingZone.id}
          zone={editingZone === "new" ? null : editingZone}
          pending={saveZone.isPending}
          onClose={() => setEditingZone(null)}
          onSave={(values) => saveZone.mutate(values)}
        />
      ) : null}
      {editingCrate ? (
        <CrateDialog
          key={editingCrate === "new" ? "new" : editingCrate.id}
          crate={editingCrate === "new" ? null : editingCrate}
          pending={saveCrate.isPending}
          onClose={() => setEditingCrate(null)}
          onSave={(values) => saveCrate.mutate(values)}
        />
      ) : null}
      <ConfirmStatusDialog
        open={Boolean(statusZone)}
        name={statusZone?.name ?? "zone"}
        active={Boolean(statusZone?.is_active)}
        pending={toggleZone.isPending}
        onOpenChange={(open) => {
          if (!open) setStatusZone(null)
        }}
        onConfirm={() => {
          if (statusZone) toggleZone.mutate(statusZone)
        }}
      />
      <ConfirmStatusDialog
        open={Boolean(statusCrate)}
        name={statusCrate?.code ?? "crate"}
        active={Boolean(statusCrate?.is_active)}
        pending={toggleCrate.isPending}
        onOpenChange={(open) => {
          if (!open) setStatusCrate(null)
        }}
        onConfirm={() => {
          if (statusCrate) toggleCrate.mutate(statusCrate)
        }}
      />
    </section>
  )
}

function ZoneDialog({
  zone,
  pending,
  onClose,
  onSave,
}: {
  zone: Zone | null
  pending: boolean
  onClose: () => void
  onSave: (values: ZoneValues) => void
}) {
  const form = useForm<ZoneValues>({
    resolver: zodResolver(zoneSchema),
    defaultValues: {
      code: zone?.code ?? "",
      name: zone?.name ?? "",
      description: zone?.description ?? "",
    },
  })
  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={zone ? zone.name : "New zone"}
      description="The zone stays in the selected godown."
      footer={
        <>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button type="submit" form="zone-form" disabled={pending}>Save</Button>
        </>
      }
    >
      <form id="zone-form" className="grid gap-3" onSubmit={form.handleSubmit(onSave)}>
        <TextField label="Code" {...form.register("code")} error={form.formState.errors.code?.message} />
        <TextField label="Name" {...form.register("name")} error={form.formState.errors.name?.message} />
        <TextField label="Description" {...form.register("description")} error={form.formState.errors.description?.message} />
      </form>
    </AppModal>
  )
}

function CrateDialog({
  crate,
  pending,
  onClose,
  onSave,
}: {
  crate: Crate | null
  pending: boolean
  onClose: () => void
  onSave: (values: CrateValues) => void
}) {
  const form = useForm<CrateValues>({
    resolver: zodResolver(crateSchema),
    defaultValues: {
      code: crate?.code ?? "",
      name: crate?.name ?? "",
      description: crate?.description ?? "",
    },
  })
  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={crate ? crate.code : "New crate"}
      description="The crate stays in the selected zone. Name is optional."
      footer={
        <>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button type="submit" form="crate-form" disabled={pending}>Save</Button>
        </>
      }
    >
      <form id="crate-form" className="grid gap-3" onSubmit={form.handleSubmit(onSave)}>
        <TextField label="Code" {...form.register("code")} error={form.formState.errors.code?.message} />
        <TextField label="Name" {...form.register("name")} error={form.formState.errors.name?.message} />
        <TextField label="Description" {...form.register("description")} error={form.formState.errors.description?.message} />
      </form>
    </AppModal>
  )
}