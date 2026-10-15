import { useState, type SelectHTMLAttributes } from "react"
import { zodResolver } from "@hookform/resolvers/zod"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useForm } from "react-hook-form"
import { AppModal } from "@/components/shared/AppModal"
import { PageHeader } from "@/components/shared/PageHeader"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { InventoryLinks } from "@/features/inventory/InventoryLinks"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { postOpeningStock } from "@/lib/inventory/api"
import { notify } from "@/lib/utilities/notify"
import {
  openingStockSchema,
  type OpeningStockValues,
} from "@/lib/validations/inventory"

const emptyValues: OpeningStockValues = {
  branchId: "",
  zoneId: "",
  crateId: "",
  productId: "",
  quantity: "",
  notes: "",
}

export function OpeningStockPage() {
  useDocumentTitle("Opening stock")
  const queryClient = useQueryClient()
  const locations = useStockLocations()
  const [confirming, setConfirming] = useState<OpeningStockValues | null>(null)
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID())
  const form = useForm<OpeningStockValues>({
    resolver: zodResolver(openingStockSchema),
    defaultValues: emptyValues,
  })
  const branchId = form.watch("branchId")
  const zoneId = form.watch("zoneId")
  const zones = (locations.zones.data ?? []).filter(
    (zone) => zone.is_active && zone.branch_id === branchId,
  )
  const crates = (locations.crates.data ?? []).filter(
    (crate) => crate.is_active && crate.zone_id === zoneId,
  )
  const products = (locations.products.data ?? []).filter((product) => product.is_active)
  const branches = (locations.branches.data ?? []).filter((branch) => branch.is_active)

  const post = useMutation({
    mutationFn: (values: OpeningStockValues) =>
      postOpeningStock({
        target_product: values.productId,
        target_crate: values.crateId,
        carton_quantity: Number(values.quantity),
        idempotency_key: idempotencyKey,
        posting_notes: values.notes.trim() || null,
      }),
    onSuccess: async (posted) => {
      setConfirming(null)
      form.reset(emptyValues)
      setIdempotencyKey(crypto.randomUUID())
      notify.success(`Opening stock posted as ${posted.reference_number}`)
      await queryClient.invalidateQueries({ queryKey: ["stock-balances"] })
      await queryClient.invalidateQueries({ queryKey: ["stock-transactions"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  return (
    <section>
      <PageHeader
        title="Opening stock"
        description="Post a one-time opening quantity into an active crate. A second opening for the same product and crate is rejected."
      />
      <InventoryLinks />
      <form
        className="grid max-w-xl gap-4"
        onSubmit={form.handleSubmit((values) => setConfirming(values))}
      >
        <SelectField
          label="Godown"
          error={form.formState.errors.branchId?.message}
          {...form.register("branchId", {
            onChange: () => {
              form.setValue("zoneId", "")
              form.setValue("crateId", "")
            },
          })}
        >
          <option value="">Choose a godown</option>
          {branches.map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.name}
            </option>
          ))}
        </SelectField>
        <SelectField
          label="Zone"
          error={form.formState.errors.zoneId?.message}
          {...form.register("zoneId", {
            onChange: () => form.setValue("crateId", ""),
          })}
        >
          <option value="">Choose a zone</option>
          {zones.map((zone) => (
            <option key={zone.id} value={zone.id}>
              {zone.code} · {zone.name}
            </option>
          ))}
        </SelectField>
        <SelectField label="Crate" error={form.formState.errors.crateId?.message} {...form.register("crateId")}>
          <option value="">Choose a crate</option>
          {crates.map((crate) => (
            <option key={crate.id} value={crate.id}>
              {crate.code}
            </option>
          ))}
        </SelectField>
        <SelectField
          label="Product"
          error={form.formState.errors.productId?.message}
          {...form.register("productId")}
        >
          <option value="">Choose a product</option>
          {products.map((product) => (
            <option key={product.id} value={product.id}>
              {product.name} ({product.sku})
            </option>
          ))}
        </SelectField>
        <TextField
          label="Carton cases"
          inputMode="numeric"
          error={form.formState.errors.quantity?.message}
          {...form.register("quantity")}
        />
        <TextField label="Notes" error={form.formState.errors.notes?.message} {...form.register("notes")} />
        <Button type="submit" className="h-10 w-fit">
          Review opening stock
        </Button>
      </form>
      <AppModal
        open={confirming !== null}
        onOpenChange={(open) => {
          if (!open) setConfirming(null)
        }}
        title="Post opening stock?"
        description="This writes one ledger entry and cannot be edited afterward."
        footer={
          <>
            <Button variant="outline" onClick={() => setConfirming(null)}>
              Cancel
            </Button>
            <Button
              disabled={post.isPending || !confirming}
              onClick={() => confirming && post.mutate(confirming)}
            >
              Post opening stock
            </Button>
          </>
        }
      />
    </section>
  )
}

function SelectField({
  label,
  error,
  children,
  ...props
}: SelectHTMLAttributes<HTMLSelectElement> & { label: string; error?: string }) {
  return (
    <label className="grid gap-2 text-sm font-medium">
      {label}
      <select
        className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
        {...props}
      >
        {children}
      </select>
      {error ? (
        <span role="alert" className="text-sm font-normal text-destructive">
          {error}
        </span>
      ) : null}
    </label>
  )
}
