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
import { formatPackAmount } from "@/lib/masters/pack-amount"
import { RecordCard } from "@/features/masters/products/ProductsPage"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { callRpc, loadRows } from "@/lib/masters/api"
import { searchProducts } from "@/lib/masters/product-search"
import { notify } from "@/lib/utilities/notify"
import {
  emptyToNull,
  supplierSchema,
  type SupplierValues,
} from "@/lib/validations/masters"

type Supplier = {
  id: string
  name: string
  phone: string | null
  email: string | null
  is_active: boolean
}

export function SuppliersPage() {
  useDocumentTitle("Suppliers")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [statusFilter, setStatusFilter] = useState("all")
  const [editing, setEditing] = useState<Supplier | "new" | null>(null)
  const [statusTarget, setStatusTarget] = useState<Supplier | null>(null)
  const suppliers = useQuery({
    queryKey: ["suppliers"],
    queryFn: () =>
      loadRows<Supplier>("suppliers", "id, name, phone, email, is_active", "name"),
  })

  const save = useMutation({
    mutationFn: async (values: SupplierValues) => {
      const args = {
        supplier_name: values.name,
        supplier_phone: emptyToNull(values.phone),
        supplier_email: emptyToNull(values.email),
      }
      if (editing === "new") {
        await callRpc("create_supplier", args)
        return
      }
      if (!editing) return
      await callRpc("update_supplier", { target_supplier: editing.id, ...args })
    },
    onSuccess: async () => {
      setEditing(null)
      notify.success("Supplier saved")
      await queryClient.invalidateQueries({ queryKey: ["suppliers"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: (supplier: Supplier) =>
      callRpc("set_supplier_active", {
        target_supplier: supplier.id,
        active: !supplier.is_active,
      }),
    onSuccess: async () => {
      setStatusTarget(null)
      notify.success("Supplier status updated")
      await queryClient.invalidateQueries({ queryKey: ["suppliers"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const visible = (suppliers.data ?? []).filter(
    (supplier) =>
      matchesSearch(search, [supplier.name, supplier.phone, supplier.email]) &&
      matchesStatus(statusFilter, supplier.is_active),
  )

  return (
    <section>
      <PageHeader
        title="Suppliers"
        description="Each product can name one supplier. Phone and email are optional. Tax and payment details are not collected here."
        action={
          can("suppliers.manage") ? (
            <Button onClick={() => setEditing("new")}>New supplier</Button>
          ) : null
        }
      />
      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <SearchField label="Search suppliers" value={search} onChange={setSearch} />
        <FilterSelect label="Status" value={statusFilter} onChange={setStatusFilter}>
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </FilterSelect>
      </div>
      <RecordCard
        loading={suppliers.isLoading}
        error={suppliers.error}
        empty={visible.length === 0}
        emptyTitle="No suppliers"
        emptyDescription="No suppliers match this view."
      >
        <ul className="divide-y divide-slate-200/80">
          {visible.map((supplier) => (
            <li key={supplier.id} className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
              <button type="button" className="text-left" onClick={() => setEditing(supplier)}>
                <span className="block text-sm font-medium">{supplier.name}</span>
                <span className="text-xs text-muted-foreground">
                  {[supplier.phone, supplier.email].filter(Boolean).join(" · ") || "No contact details"}
                </span>
              </button>
              <span className="flex items-center gap-2">
                <StatusBadge tone={supplier.is_active ? "success" : "neutral"}>
                  {supplier.is_active ? "Active" : "Inactive"}
                </StatusBadge>
                {can("suppliers.manage") ? (
                  <Button variant="outline" onClick={() => setStatusTarget(supplier)}>
                    {supplier.is_active ? "Deactivate" : "Activate"}
                  </Button>
                ) : null}
              </span>
            </li>
          ))}
        </ul>
      </RecordCard>
      {editing ? (
        <SupplierDialog
          key={editing === "new" ? "new" : editing.id}
          supplier={editing === "new" ? null : editing}
          canSave={can("suppliers.manage")}
          canReadProducts={can("products.read")}
          pending={save.isPending}
          onClose={() => setEditing(null)}
          onSave={(values) => save.mutate(values)}
        />
      ) : null}
      <ConfirmStatusDialog
        open={Boolean(statusTarget)}
        name={statusTarget?.name ?? "supplier"}
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

function SupplierDialog({
  supplier,
  canSave,
  canReadProducts,
  pending,
  onClose,
  onSave,
}: {
  supplier: Supplier | null
  canSave: boolean
  canReadProducts: boolean
  pending: boolean
  onClose: () => void
  onSave: (values: SupplierValues) => void
}) {
  const form = useForm<SupplierValues>({
    resolver: zodResolver(supplierSchema),
    defaultValues: {
      name: supplier?.name ?? "",
      phone: supplier?.phone ?? "",
      email: supplier?.email ?? "",
    },
  })
  const linkedProducts = useQuery({
    queryKey: ["supplier-products", supplier?.id],
    enabled: Boolean(supplier?.id) && canReadProducts,
    queryFn: () =>
      searchProducts({
        query: "",
        supplierId: supplier?.id,
        activeOnly: false,
        limit: 200,
      }),
  })

  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={supplier ? supplier.name : "New supplier"}
      footer={
        canSave ? (
          <>
            <Button variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" form="supplier-form" disabled={pending}>Save</Button>
          </>
        ) : (
          <Button variant="outline" onClick={onClose}>Close</Button>
        )
      }
    >
      <form id="supplier-form" className="grid gap-3" onSubmit={form.handleSubmit(onSave)}>
        <TextField label="Name" {...form.register("name")} error={form.formState.errors.name?.message} disabled={!canSave} />
        <TextField label="Phone" {...form.register("phone")} error={form.formState.errors.phone?.message} disabled={!canSave} />
        <TextField label="Email" {...form.register("email")} error={form.formState.errors.email?.message} disabled={!canSave} />
      </form>
      {supplier && canReadProducts ? (
        <div className="mt-4 border-t border-slate-200/80 pt-3">
          <p className="text-sm font-medium">Products</p>
          {linkedProducts.isLoading ? (
            <p className="mt-2 text-xs text-muted-foreground">Loading products</p>
          ) : (linkedProducts.data ?? []).length === 0 ? (
            <p className="mt-2 text-xs text-muted-foreground">
              No products are linked to this supplier yet.
            </p>
          ) : (
            <ul className="mt-2 max-h-56 space-y-1 overflow-auto text-sm">
              {(linkedProducts.data ?? []).map((product) => {
                const packAmount = formatPackAmount(
                  product.billed_units_per_case,
                  product.billing_unit,
                )
                return (
                  <li key={product.id}>
                    <span className="font-medium">{product.name}</span>
                    <span className="block text-xs text-muted-foreground">
                      {product.sku}
                      {packAmount ? ` · ${packAmount}` : ""}
                    </span>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      ) : null}
    </AppModal>
  )
}