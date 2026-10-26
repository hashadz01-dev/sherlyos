import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import type { DraftLine } from "@/features/damage/utils/draft"
import type { DamageSourceCatalogs, DamageSourceItem } from "@/lib/damage/api"
import type { DamageScenario } from "@/lib/damage/rules"

function onHand(
  catalogs: DamageSourceCatalogs,
  crateId: string,
  productId: string,
) {
  return (
    catalogs.balances?.find(
      (row) => row.crate_id === crateId && row.product_id === productId,
    )?.on_hand_cases ?? 0
  )
}

export function DamageLineEditor({
  scenario,
  source,
  catalogs,
  lines,
  disabled,
  onChange,
}: {
  scenario: DamageScenario
  source: DamageSourceItem | null
  catalogs: DamageSourceCatalogs
  lines: DraftLine[]
  disabled?: boolean
  onChange: (lines: DraftLine[]) => void
}) {
  const inbound = scenario === "refill_supply" || scenario === "unloading"
  const reserved = scenario === "loading" || scenario === "transit"
  const storageLike = scenario === "storage" || scenario === "shop_return"
  const sourceLines = source?.lines ?? []

  function patch(index: number, partial: Partial<DraftLine>) {
    onChange(
      lines.map((line, current) =>
        current === index ? { ...line, ...partial } : line,
      ),
    )
  }

  function addFromSourceLine(
    sourceLine: NonNullable<DamageSourceItem["lines"]>[number],
  ) {
    onChange([
      ...lines,
      {
        key: crypto.randomUUID(),
        product_id: sourceLine.product_id,
        product_sku: sourceLine.product_sku,
        product_name: sourceLine.product_name,
        quantity_cases: String(
          sourceLine.remaining_cases ?? sourceLine.reserved_cases ?? 1,
        ),
        damage_reason: "",
        crate_id: sourceLine.crate_id ?? "",
        crate_code: sourceLine.crate_code ?? "",
        lot_id: sourceLine.lot_id ?? "",
        notes: "",
        receipt_line_id: sourceLine.receipt_line_id ?? "",
      },
    ])
  }

  return (
    <section className="grid gap-3">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold">Damage lines</h2>
        {storageLike ? (
          <Button
            type="button"
            variant="outline"
            disabled={disabled}
            onClick={() =>
              onChange([
                ...lines,
                {
                  key: crypto.randomUUID(),
                  product_id: "",
                  product_sku: "",
                  product_name: "",
                  quantity_cases: "1",
                  damage_reason: "",
                  crate_id: "",
                  crate_code: "",
                  lot_id: "",
                  notes: "",
                  receipt_line_id: "",
                },
              ])
            }
          >
            Add line
          </Button>
        ) : null}
      </div>

      {inbound || reserved ? (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-muted-foreground">
                <th className="py-2 pr-3">Product</th>
                <th className="py-2 pr-3">Crate</th>
                <th className="py-2 pr-3">Available</th>
                <th className="py-2 pr-3" />
              </tr>
            </thead>
            <tbody>
              {sourceLines.map((sourceLine) => (
                <tr
                  key={`${sourceLine.product_id}-${sourceLine.crate_id}-${sourceLine.receipt_line_id ?? ""}`}
                  className="border-b last:border-0"
                >
                  <td className="py-2 pr-3">
                    {sourceLine.product_sku} · {sourceLine.product_name}
                  </td>
                  <td className="py-2 pr-3">{sourceLine.crate_code ?? "—"}</td>
                  <td className="py-2 pr-3">
                    {sourceLine.remaining_cases ??
                      sourceLine.reserved_cases ??
                      0}{" "}
                    cases
                  </td>
                  <td className="py-2 pr-3">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={disabled}
                      onClick={() => addFromSourceLine(sourceLine)}
                    >
                      Add
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}

      {lines.length === 0 ? (
        <p className="text-sm text-muted-foreground">No damage lines yet.</p>
      ) : null}

      <ul className="grid gap-3">
        {lines.map((line, index) => (
          <li
            key={line.key}
            className="grid gap-3 rounded-2xl bg-card p-3 ring-1 ring-border md:grid-cols-2"
          >
            {storageLike ? (
              <>
                <Label className="grid gap-2 text-sm font-medium">
                  Product
                  <select
                    className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                    value={line.product_id}
                    disabled={disabled}
                    onChange={(event) => {
                      const product = catalogs.products?.find(
                        (row) => row.id === event.target.value,
                      )
                      patch(index, {
                        product_id: event.target.value,
                        product_sku: product?.sku ?? "",
                        product_name: product?.name ?? "",
                      })
                    }}
                  >
                    <option value="">Select product</option>
                    {(catalogs.products ?? []).map((product) => (
                      <option key={product.id} value={product.id}>
                        {product.sku} · {product.name}
                      </option>
                    ))}
                  </select>
                </Label>
                <Label className="grid gap-2 text-sm font-medium">
                  Crate{scenario === "shop_return" ? " (optional)" : ""}
                  <select
                    className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                    value={line.crate_id}
                    disabled={disabled}
                    onChange={(event) => {
                      const crate = catalogs.crates?.find(
                        (row) => row.id === event.target.value,
                      )
                      patch(index, {
                        crate_id: event.target.value,
                        crate_code: crate?.code ?? "",
                      })
                    }}
                  >
                    <option value="">Select crate</option>
                    {(catalogs.crates ?? []).map((crate) => (
                      <option key={crate.id} value={crate.id}>
                        {crate.code}
                        {crate.zone_code ? ` · ${crate.zone_code}` : ""}
                      </option>
                    ))}
                  </select>
                </Label>
                {scenario === "storage" && line.crate_id && line.product_id ? (
                  <p className="text-xs text-muted-foreground md:col-span-2">
                    On hand: {onHand(catalogs, line.crate_id, line.product_id)}{" "}
                    cases
                  </p>
                ) : null}
              </>
            ) : (
              <p className="text-sm md:col-span-2">
                {line.product_sku} · {line.product_name}
                {line.crate_code ? ` · ${line.crate_code}` : ""}
              </p>
            )}
            <Label className="grid gap-2 text-sm font-medium">
              Quantity (cases)
              <Input
                inputMode="numeric"
                value={line.quantity_cases}
                disabled={disabled}
                onChange={(event) =>
                  patch(index, { quantity_cases: event.target.value })
                }
              />
            </Label>
            <Label className="grid gap-2 text-sm font-medium">
              Damage reason
              <Input
                maxLength={80}
                value={line.damage_reason}
                disabled={disabled}
                onChange={(event) =>
                  patch(index, { damage_reason: event.target.value })
                }
              />
            </Label>
            <Label className="grid gap-2 text-sm font-medium md:col-span-2">
              Line notes
              <textarea
                className="min-h-16 rounded-xl border bg-transparent px-3 py-2 text-sm"
                maxLength={500}
                value={line.notes}
                disabled={disabled}
                onChange={(event) =>
                  patch(index, { notes: event.target.value })
                }
              />
            </Label>
            <div>
              <Button
                type="button"
                variant="outline"
                disabled={disabled}
                onClick={() =>
                  onChange(lines.filter((row) => row.key !== line.key))
                }
              >
                Remove
              </Button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  )
}
