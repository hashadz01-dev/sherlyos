import { useState, type ReactNode } from "react"
import { zodResolver } from "@hookform/resolvers/zod"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useForm } from "react-hook-form"
import { Package } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { AppModal } from "@/components/shared/AppModal"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { callRpc, loadRows } from "@/lib/masters/api"
import { notify } from "@/lib/utilities/notify"
import {
  emptyToNull,
  productSchema,
  type ProductValues,
} from "@/lib/validations/masters"
import {
  ConfirmStatusDialog,
  FilterSelect,
  SearchField,
} from "@/features/masters/MasterControls"
import { matchesSearch, matchesStatus } from "@/lib/masters/filters"

type Product = {
  id: string
  sku: string
  name: string
  category_id: string | null
  supplier_id: string | null
  is_active: boolean
  expiry_policy: "expiry_controlled" | "non_expiring" | null
}

type Named = { id: string; name: string; is_active: boolean }

const emptyValues: ProductValues = {
  name: "",
  sku: "",
  categoryId: "",
  supplierId: "",
}

export function ProductsPage() {
  useDocumentTitle("Products")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [categoryFilter, setCategoryFilter] = useState("all")
  const [supplierFilter, setSupplierFilter] = useState("all")
  const [statusFilter, setStatusFilter] = useState("all")
  const [editing, setEditing] = useState<Product | "new" | null>(null)
  const [statusTarget, setStatusTarget] = useState<Product | null>(null)
  const [expiryTarget, setExpiryTarget] = useState<Product | null>(null)
  const [expiryPolicy, setExpiryPolicy] = useState<"expiry_controlled" | "non_expiring">(
    "expiry_controlled",
  )
  const canClassifyExpiry = can("products.expiry_policy.manage")

  const products = useQuery({
    queryKey: ["products"],
    queryFn: () =>
      loadRows<Product>(
        "products",
        "id, sku, name, category_id, supplier_id, is_active, expiry_policy",
        "name",
      ),
  })
  const categories = useQuery({
    queryKey: ["product-categories"],
    queryFn: () =>
      loadRows<Named>("product_categories", "id, name, is_active", "name"),
  })
  const suppliers = useQuery({
    queryKey: ["suppliers"],
    enabled: can("suppliers.read"),
    queryFn: () => loadRows<Named>("suppliers", "id, name, is_active", "name"),
  })

  const save = useMutation({
    mutationFn: async (values: ProductValues) => {
      const args = {
        product_sku: values.sku,
        product_name: values.name,
        next_supplier: emptyToNull(values.supplierId),
        next_category: emptyToNull(values.categoryId),
      }
      if (editing === "new") {
        await callRpc("create_product", args)
        return
      }
      if (!editing) return
      await callRpc("update_product", { target_product: editing.id, ...args })
    },
    onSuccess: async () => {
      setEditing(null)
      notify.success("Product saved")
      await queryClient.invalidateQueries({ queryKey: ["products"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: async (product: Product) => {
      await callRpc("set_product_active", {
        target_product: product.id,
        active: !product.is_active,
      })
    },
    onSuccess: async () => {
      setStatusTarget(null)
      notify.success("Product status updated")
      await queryClient.invalidateQueries({ queryKey: ["products"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const classify = useMutation({
    mutationFn: async () => {
      if (!expiryTarget) return
      await callRpc("set_product_expiry_policy", {
        target_product: expiryTarget.id,
        new_policy: expiryPolicy,
      })
    },
    onSuccess: async () => {
      setExpiryTarget(null)
      notify.success("Expiry policy updated")
      await queryClient.invalidateQueries({ queryKey: ["products"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const categoryName = new Map((categories.data ?? []).map((row) => [row.id, row.name]))
  const supplierName = new Map((suppliers.data ?? []).map((row) => [row.id, row.name]))
  const visible = (products.data ?? []).filter((product) => {
    return (
      matchesSearch(search, [product.name, product.sku]) &&
      matchesStatus(statusFilter, product.is_active) &&
      (categoryFilter === "all" || product.category_id === categoryFilter) &&
      (supplierFilter === "all" || product.supplier_id === supplierFilter)
    )
  })

  return (
    <section>
      <PageHeader
        title="Products"
        description="A product is the master record. Stock is counted later in whole carton cases, and this screen does not store a quantity."
        action={
          can("products.manage") ? (
            <Button onClick={() => setEditing("new")}>New product</Button>
          ) : null
        }
      />
      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <SearchField label="Search name or SKU" value={search} onChange={setSearch} />
        <FilterSelect label="Category" value={categoryFilter} onChange={setCategoryFilter}>
          <option value="all">All categories</option>
          {(categories.data ?? []).map((category) => (
            <option key={category.id} value={category.id}>
              {category.name}
            </option>
          ))}
        </FilterSelect>
        <FilterSelect label="Supplier" value={supplierFilter} onChange={setSupplierFilter}>
          <option value="all">All suppliers</option>
          {(suppliers.data ?? []).map((supplier) => (
            <option key={supplier.id} value={supplier.id}>
              {supplier.name}
            </option>
          ))}
        </FilterSelect>
        <FilterSelect label="Status" value={statusFilter} onChange={setStatusFilter}>
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </FilterSelect>
      </div>
      <RecordCard
        loading={products.isLoading}
        error={products.error}
        empty={visible.length === 0}
        emptyTitle="No products"
        emptyDescription="No products match this view."
      >
        <ul className="divide-y divide-slate-200/80">
          {visible.map((product) => (
            <li key={product.id} className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
              <button
                type="button"
                className="text-left"
                onClick={() => setEditing(product)}
              >
                <span className="block text-sm font-medium">{product.name}</span>
                <span className="text-xs text-muted-foreground">
                  {product.sku}
                  {product.category_id ? ` · ${categoryName.get(product.category_id) ?? "Category"}` : ""}
                  {product.supplier_id ? ` · ${supplierName.get(product.supplier_id) ?? "Supplier"}` : ""}
                  {` · ${product.expiry_policy ?? "unclassified"}`}
                </span>
              </button>
              <span className="flex items-center gap-2">
                <StatusBadge tone={product.is_active ? "success" : "neutral"}>
                  {product.is_active ? "Active" : "Inactive"}
                </StatusBadge>
                {canClassifyExpiry ? (
                  <Button
                    variant="outline"
                    onClick={() => {
                      setExpiryTarget(product)
                      setExpiryPolicy(product.expiry_policy ?? "expiry_controlled")
                    }}
                  >
                    Classify expiry
                  </Button>
                ) : null}
                {can("products.manage") ? (
                  <Button variant="outline" onClick={() => setStatusTarget(product)}>
                    {product.is_active ? "Deactivate" : "Activate"}
                  </Button>
                ) : null}
              </span>
            </li>
          ))}
        </ul>
      </RecordCard>
      {editing ? (
        <ProductDialog
          key={editing === "new" ? "new" : editing.id}
          product={editing === "new" ? null : editing}
          categories={categories.data ?? []}
          suppliers={suppliers.data ?? []}
          canChooseSupplier={can("suppliers.read")}
          canSave={can("products.manage")}
          pending={save.isPending}
          onClose={() => setEditing(null)}
          onSave={(values) => save.mutate(values)}
        />
      ) : null}
      <ConfirmStatusDialog
        open={Boolean(statusTarget)}
        name={statusTarget?.name ?? "product"}
        active={Boolean(statusTarget?.is_active)}
        pending={toggle.isPending}
        onOpenChange={(open) => {
          if (!open) setStatusTarget(null)
        }}
        onConfirm={() => {
          if (statusTarget) toggle.mutate(statusTarget)
        }}
      />
      <AppModal
        open={Boolean(expiryTarget)}
        onOpenChange={(open) => {
          if (!open) setExpiryTarget(null)
        }}
        title="Classify expiry policy"
        description="Admin-only. Godown Managers cannot classify. Policy cannot change after lots exist for the product."
        footer={
          <>
            <Button variant="outline" onClick={() => setExpiryTarget(null)}>
              Cancel
            </Button>
            <Button disabled={classify.isPending || !expiryTarget} onClick={() => classify.mutate()}>
              Save policy
            </Button>
          </>
        }
      >
        <label className="grid gap-2 text-sm font-medium">
          Expiry policy
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={expiryPolicy}
            onChange={(event) =>
              setExpiryPolicy(event.target.value as "expiry_controlled" | "non_expiring")
            }
          >
            <option value="expiry_controlled">Expiry controlled</option>
            <option value="non_expiring">Non-expiring</option>
          </select>
        </label>
      </AppModal>
    </section>
  )
}

function ProductDialog({
  product,
  categories,
  suppliers,
  canChooseSupplier,
  canSave,
  pending,
  onClose,
  onSave,
}: {
  product: Product | null
  categories: Named[]
  suppliers: Named[]
  canChooseSupplier: boolean
  canSave: boolean
  pending: boolean
  onClose: () => void
  onSave: (values: ProductValues) => void
}) {
  const form = useForm<ProductValues>({
    resolver: zodResolver(productSchema),
    defaultValues: product
      ? {
          name: product.name,
          sku: product.sku,
          categoryId: product.category_id ?? "",
          supplierId: product.supplier_id ?? "",
        }
      : emptyValues,
  })

  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={product ? product.name : "New product"}
      description="Category and supplier are optional. The inventory unit is one carton case."
      footer={
        canSave ? (
          <>
            <Button variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" form="product-form" disabled={pending}>
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
      <form
        id="product-form"
        className="grid gap-3"
        onSubmit={form.handleSubmit(onSave)}
      >
        <TextField label="Product name" {...form.register("name")} error={form.formState.errors.name?.message} disabled={!canSave} />
        <TextField label="SKU" {...form.register("sku")} error={form.formState.errors.sku?.message} disabled={!canSave} />
        <label className="grid gap-2 text-sm">
          Category
          <FilterSelect
            label="Category"
            value={form.watch("categoryId")}
            onChange={(value) => form.setValue("categoryId", value)}
          >
            <option value="">No category</option>
            {categories
              .filter((category) => category.is_active || category.id === product?.category_id)
              .map((category) => (
                <option key={category.id} value={category.id}>
                  {category.name}
                </option>
              ))}
          </FilterSelect>
        </label>
        {canChooseSupplier ? (
          <label className="grid gap-2 text-sm">
            Supplier
            <FilterSelect
              label="Supplier"
              value={form.watch("supplierId")}
              onChange={(value) => form.setValue("supplierId", value)}
            >
              <option value="">No supplier</option>
              {suppliers
                .filter((supplier) => supplier.is_active || supplier.id === product?.supplier_id)
                .map((supplier) => (
                  <option key={supplier.id} value={supplier.id}>
                    {supplier.name}
                  </option>
                ))}
            </FilterSelect>
          </label>
        ) : (
          <p className="text-sm text-muted-foreground">
            Supplier choices are hidden because this account cannot read suppliers. The product can be saved without one.
          </p>
        )}
      </form>
    </AppModal>
  )
}

export function RecordCard({
  loading,
  error,
  empty,
  emptyTitle,
  emptyDescription,
  children,
}: {
  loading: boolean
  error: unknown
  empty: boolean
  emptyTitle: string
  emptyDescription: string
  children: ReactNode
}) {
  return (
    <div className="rounded-2xl bg-white ring-1 ring-slate-200/80">
      {loading ? (
        <LoadingBlock label="Loading records" />
      ) : error ? (
        <EmptyState
          icon={Package}
          title="Records could not be loaded"
          description={error instanceof Error ? error.message : "Try again."}
        />
      ) : empty ? (
        <EmptyState icon={Package} title={emptyTitle} description={emptyDescription} />
      ) : (
        children
      )}
    </div>
  )
}