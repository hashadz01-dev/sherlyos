import { useEffect, useState, type SelectHTMLAttributes } from "react"
import { zodResolver } from "@hookform/resolvers/zod"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useForm } from "react-hook-form"
import { AppModal } from "@/components/shared/AppModal"
import { PageHeader } from "@/components/shared/PageHeader"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { InventoryLinks } from "@/features/inventory/InventoryLinks"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import {
  getStockLotCutoverState,
  listStockBalances,
  listStockLotBalances,
  postCrateTransfer,
} from "@/lib/inventory/api"
import { notify } from "@/lib/utilities/notify"
import {
  transferStockSchema,
  type TransferStockValues,
} from "@/lib/validations/inventory"

const emptyValues: TransferStockValues = {
  branchId: "",
  sourceZoneId: "",
  sourceCrateId: "",
  destinationZoneId: "",
  destinationCrateId: "",
  productId: "",
  quantity: "",
  notes: "",
  dualWriteEnabled: false,
  lotMoves: [],
}

export function TransfersPage() {
  useDocumentTitle("Stock transfers")
  const queryClient = useQueryClient()
  const locations = useStockLocations()
  const cutover = useQuery({
    queryKey: ["stock-lot-cutover"],
    queryFn: getStockLotCutoverState,
  })
  const balances = useQuery({
    queryKey: ["stock-balances"],
    queryFn: listStockBalances,
  })
  const [confirming, setConfirming] = useState<TransferStockValues | null>(null)
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID())
  const form = useForm<TransferStockValues>({
    resolver: zodResolver(transferStockSchema),
    defaultValues: emptyValues,
  })
  const branchId = form.watch("branchId")
  const sourceZoneId = form.watch("sourceZoneId")
  const sourceCrateId = form.watch("sourceCrateId")
  const destinationZoneId = form.watch("destinationZoneId")
  const productId = form.watch("productId")
  const lotMoves = form.watch("lotMoves")
  const dualWriteEnabled = cutover.data?.dual_write_enabled ?? false
  const zones = (locations.zones.data ?? []).filter(
    (zone) => zone.is_active && zone.branch_id === branchId,
  )
  const sourceCrates = (locations.crates.data ?? []).filter(
    (crate) => crate.is_active && crate.zone_id === sourceZoneId,
  )
  const destinationCrates = (locations.crates.data ?? []).filter(
    (crate) =>
      crate.is_active &&
      crate.zone_id === destinationZoneId &&
      crate.id !== sourceCrateId,
  )
  const products = (locations.products.data ?? []).filter((product) => product.is_active)
  const branches = (locations.branches.data ?? []).filter((branch) => branch.is_active)
  const sourceBalance =
    balances.data?.find(
      (row) => row.crate_id === sourceCrateId && row.product_id === productId,
    )?.quantity ?? 0
  const lotBalances = useQuery({
    queryKey: ["stock-lot-balances", branchId, sourceCrateId, productId],
    queryFn: () =>
      listStockLotBalances({
        filter_branch: branchId || null,
        filter_crate: sourceCrateId || null,
        filter_product: productId || null,
      }),
    enabled: dualWriteEnabled && Boolean(sourceCrateId && productId),
  })
  const availableLots = (lotBalances.data ?? []).filter((row) => row.quantity > 0)

  useEffect(() => {
    form.setValue("dualWriteEnabled", dualWriteEnabled)
  }, [dualWriteEnabled, form])

  useEffect(() => {
    form.setValue("lotMoves", [])
  }, [sourceCrateId, productId, form])

  const post = useMutation({
    mutationFn: (values: TransferStockValues) =>
      postCrateTransfer({
        target_product: values.productId,
        source_crate: values.sourceCrateId,
        destination_crate: values.destinationCrateId,
        carton_quantity: Number(values.quantity),
        idempotency_key: idempotencyKey,
        posting_notes: values.notes.trim() || null,
        lot_moves: dualWriteEnabled
          ? values.lotMoves.map((move) => ({
              lot_id: move.lotId,
              quantity: Number(move.quantity),
            }))
          : null,
      }),
    onSuccess: async (posted) => {
      setConfirming(null)
      form.reset({ ...emptyValues, dualWriteEnabled })
      setIdempotencyKey(crypto.randomUUID())
      notify.success(`Transfer posted as ${posted.reference_number}`)
      await queryClient.invalidateQueries({ queryKey: ["stock-balances"] })
      await queryClient.invalidateQueries({ queryKey: ["stock-transactions"] })
      await queryClient.invalidateQueries({ queryKey: ["stock-lot-balances"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  function setLotQuantity(lotId: string, quantity: string) {
    const next = lotMoves.filter((move) => move.lotId !== lotId)
    if (quantity.trim() !== "" && Number(quantity) > 0) {
      next.push({ lotId, quantity })
    }
    form.setValue("lotMoves", next, { shouldValidate: true })
  }

  return (
    <section>
      <PageHeader
        title="Stock transfers"
        description="Move whole carton cases between active crates in the same godown. A transfer across godowns is not available."
      />
      <InventoryLinks />
      <form
        className="grid max-w-xl gap-4"
        onSubmit={form.handleSubmit((values) => {
          if (Number(values.quantity) > sourceBalance) {
            form.setError("quantity", { message: "Quantity is higher than the source balance." })
            return
          }
          setConfirming(values)
        })}
      >
        <SelectField
          label="Godown"
          error={form.formState.errors.branchId?.message}
          {...form.register("branchId", {
            onChange: () => {
              form.setValue("sourceZoneId", "")
              form.setValue("sourceCrateId", "")
              form.setValue("destinationZoneId", "")
              form.setValue("destinationCrateId", "")
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
          label="Source zone"
          error={form.formState.errors.sourceZoneId?.message}
          {...form.register("sourceZoneId", {
            onChange: () => form.setValue("sourceCrateId", ""),
          })}
        >
          <option value="">Choose a zone</option>
          {zones.map((zone) => (
            <option key={zone.id} value={zone.id}>
              {zone.code} · {zone.name}
            </option>
          ))}
        </SelectField>
        <SelectField
          label="Source crate"
          error={form.formState.errors.sourceCrateId?.message}
          {...form.register("sourceCrateId")}
        >
          <option value="">Choose a crate</option>
          {sourceCrates.map((crate) => (
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
        <p className="text-sm text-muted-foreground">Source balance: {sourceBalance} carton cases</p>
        {dualWriteEnabled ? (
          <div className="grid gap-3 rounded-xl border border-input p-3">
            <p className="text-sm font-medium">Lot quantities (explicit selection, no FEFO)</p>
            {lotBalances.isLoading ? (
              <p className="text-sm text-muted-foreground">Loading lot balances…</p>
            ) : availableLots.length === 0 ? (
              <p className="text-sm text-muted-foreground">No lot balances at this source crate.</p>
            ) : (
              availableLots.map((lot) => {
                const current =
                  lotMoves.find((move) => move.lotId === lot.lot_id)?.quantity ?? ""
                return (
                  <div key={lot.lot_id} className="grid gap-1 text-sm">
                    <span>
                      {lot.manufacturer_lot_code ?? "No manufacturer code"} · qty {lot.quantity}
                      {lot.expiry_date ? ` · exp ${lot.expiry_date}` : ""}
                    </span>
                    <input
                      className="h-10 rounded-lg border border-input bg-transparent px-2.5"
                      inputMode="numeric"
                      placeholder="Move quantity"
                      value={current}
                      onChange={(event) => setLotQuantity(lot.lot_id, event.target.value)}
                    />
                  </div>
                )
              })
            )}
            {form.formState.errors.lotMoves?.message ? (
              <p role="alert" className="text-sm text-destructive">
                {form.formState.errors.lotMoves.message}
              </p>
            ) : null}
          </div>
        ) : null}
        <SelectField
          label="Destination zone"
          error={form.formState.errors.destinationZoneId?.message}
          {...form.register("destinationZoneId", {
            onChange: () => form.setValue("destinationCrateId", ""),
          })}
        >
          <option value="">Choose a zone</option>
          {zones.map((zone) => (
            <option key={zone.id} value={zone.id}>
              {zone.code} · {zone.name}
            </option>
          ))}
        </SelectField>
        <SelectField
          label="Destination crate"
          error={form.formState.errors.destinationCrateId?.message}
          {...form.register("destinationCrateId")}
        >
          <option value="">Choose a crate in this godown</option>
          {destinationCrates.map((crate) => (
            <option key={crate.id} value={crate.id}>
              {crate.code}
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
        <Button type="submit" className="h-10 w-fit" disabled={sourceBalance < 1}>
          Review transfer
        </Button>
      </form>
      <AppModal
        open={confirming !== null}
        onOpenChange={(open) => {
          if (!open) setConfirming(null)
        }}
        title="Post transfer?"
        description="This writes a source entry and a destination entry. The two quantities net to zero."
        footer={
          <>
            <Button variant="outline" onClick={() => setConfirming(null)}>
              Cancel
            </Button>
            <Button
              disabled={post.isPending || !confirming}
              onClick={() => confirming && post.mutate(confirming)}
            >
              Post transfer
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
