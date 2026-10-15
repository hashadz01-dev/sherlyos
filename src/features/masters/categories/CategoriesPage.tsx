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
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { callRpc, loadRows } from "@/lib/masters/api"
import { notify } from "@/lib/utilities/notify"
import {
  categorySchema,
  emptyToNull,
  type CategoryValues,
} from "@/lib/validations/masters"

type Category = {
  id: string
  name: string
  description: string | null
  is_active: boolean
}

export function CategoriesPage() {
  useDocumentTitle("Categories")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [search, setSearch] = useState("")
  const [statusFilter, setStatusFilter] = useState("all")
  const [editing, setEditing] = useState<Category | "new" | null>(null)
  const [statusTarget, setStatusTarget] = useState<Category | null>(null)
  const categories = useQuery({
    queryKey: ["product-categories"],
    queryFn: () =>
      loadRows<Category>(
        "product_categories",
        "id, name, description, is_active",
        "name",
      ),
  })

  const save = useMutation({
    mutationFn: async (values: CategoryValues) => {
      const description = emptyToNull(values.description)
      if (editing === "new") {
        await callRpc("create_product_category", {
          category_name: values.name,
          category_description: description,
        })
        return
      }
      if (!editing) return
      await callRpc("update_product_category", {
        target_category: editing.id,
        category_name: values.name,
        category_description: description,
      })
    },
    onSuccess: async () => {
      setEditing(null)
      notify.success("Category saved")
      await queryClient.invalidateQueries({ queryKey: ["product-categories"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: (category: Category) =>
      callRpc("set_product_category_active", {
        target_category: category.id,
        active: !category.is_active,
      }),
    onSuccess: async () => {
      setStatusTarget(null)
      notify.success("Category status updated")
      await queryClient.invalidateQueries({ queryKey: ["product-categories"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const visible = (categories.data ?? []).filter(
    (category) =>
      matchesSearch(search, [category.name, category.description]) &&
      matchesStatus(statusFilter, category.is_active),
  )

  return (
    <section>
      <PageHeader
        title="Categories"
        description="Categories group products. A product does not have to use one, and categories do not form a hierarchy."
        action={
          can("products.manage") ? (
            <Button onClick={() => setEditing("new")}>New category</Button>
          ) : null
        }
      />
      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <SearchField label="Search categories" value={search} onChange={setSearch} />
        <FilterSelect label="Status" value={statusFilter} onChange={setStatusFilter}>
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </FilterSelect>
      </div>
      <RecordCard
        loading={categories.isLoading}
        error={categories.error}
        empty={visible.length === 0}
        emptyTitle="No categories"
        emptyDescription="No categories match this view."
      >
        <ul className="divide-y divide-slate-200/80">
          {visible.map((category) => (
            <li key={category.id} className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
              <button type="button" className="text-left" onClick={() => setEditing(category)}>
                <span className="block text-sm font-medium">{category.name}</span>
                {category.description ? (
                  <span className="text-xs text-muted-foreground">{category.description}</span>
                ) : null}
              </button>
              <span className="flex items-center gap-2">
                <StatusBadge tone={category.is_active ? "success" : "neutral"}>
                  {category.is_active ? "Active" : "Inactive"}
                </StatusBadge>
                {can("products.manage") ? (
                  <Button variant="outline" onClick={() => setStatusTarget(category)}>
                    {category.is_active ? "Deactivate" : "Activate"}
                  </Button>
                ) : null}
              </span>
            </li>
          ))}
        </ul>
      </RecordCard>
      {editing ? (
        <CategoryDialog
          key={editing === "new" ? "new" : editing.id}
          category={editing === "new" ? null : editing}
          canSave={can("products.manage")}
          pending={save.isPending}
          onClose={() => setEditing(null)}
          onSave={(values) => save.mutate(values)}
        />
      ) : null}
      <ConfirmStatusDialog
        open={Boolean(statusTarget)}
        name={statusTarget?.name ?? "category"}
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

function CategoryDialog({
  category,
  canSave,
  pending,
  onClose,
  onSave,
}: {
  category: Category | null
  canSave: boolean
  pending: boolean
  onClose: () => void
  onSave: (values: CategoryValues) => void
}) {
  const form = useForm<CategoryValues>({
    resolver: zodResolver(categorySchema),
    defaultValues: {
      name: category?.name ?? "",
      description: category?.description ?? "",
    },
  })

  return (
    <AppModal
      open
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      title={category ? category.name : "New category"}
      footer={
        canSave ? (
          <>
            <Button variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" form="category-form" disabled={pending}>Save</Button>
          </>
        ) : (
          <Button variant="outline" onClick={onClose}>Close</Button>
        )
      }
    >
      <form id="category-form" className="grid gap-3" onSubmit={form.handleSubmit(onSave)}>
        <TextField label="Name" {...form.register("name")} error={form.formState.errors.name?.message} disabled={!canSave} />
        <TextField label="Description" {...form.register("description")} error={form.formState.errors.description?.message} disabled={!canSave} />
      </form>
    </AppModal>
  )
}