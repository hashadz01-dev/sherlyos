import { Link } from "react-router"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  inboundQuantityMessage,
  parseCartonQuantity,
  type DraftLine,
} from "@/features/damage/utils/draft"
import { inboundReceiptAvailability } from "@/features/damage/utils/quantities"
import type {
  DamageSourceCatalogs,
  DamageSourceItem,
  DamageStorageLotOption,
} from "@/lib/damage/api"
import { clientDamageClassifications } from "@/features/damage/utils/labels"
import type { DamageScenario } from "@/lib/damage/rules"

export type ClaimingDamageReport = {
  id: string
  report_number: string
  status: string
}

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

/** Eligible lots for the selected storage crate + product (dual-write catalogs). */
function lotsForGrain(
  catalogs: DamageSourceCatalogs,
  crateId: string,
  productId: string,
): DamageStorageLotOption[] {
  if (!crateId || !productId) return []
  return (catalogs.lots ?? []).filter(
    (lot) => lot.crate_id === crateId && lot.product_id === productId,
  )
}

function formatLotLabel(lot: DamageStorageLotOption) {
  const code = lot.manufacturer_lot_code?.trim() || lot.lot_id.slice(0, 8)
  const expiry = lot.expiry_date ? ` · exp ${lot.expiry_date}` : ""
  return `${code}${expiry} · avail ${lot.available_cases}`
}

export function DamageLineEditor({
  scenario,
  source,
  catalogs,
  lines,
  disabled,
  onChange,
  savedOwnByReceiptLine = {},
  claimingReports = [],
}: {
  scenario: DamageScenario
  source: DamageSourceItem | null
  catalogs: DamageSourceCatalogs
  lines: DraftLine[]
  disabled?: boolean
  onChange: (lines: DraftLine[]) => void
  /** Saved quantity on this draft, keyed by receipt line. */
  savedOwnByReceiptLine?: Record<string, number>
  claimingReports?: ClaimingDamageReport[]
}) {
  const inbound = scenario === "refill_supply" || scenario === "unloading"
  const reserved = scenario === "loading" || scenario === "transit"
  const storageLike = scenario === "storage" || scenario === "shop_return"
  const requireStorageLot =
    scenario === "storage" && catalogs.dual_write_enabled === true
  const sourceLines = source?.lines ?? []

  function patch(index: number, partial: Partial<DraftLine>) {
    onChange(
      lines.map((line, current) =>
        current === index ? { ...line, ...partial } : line,
      ),
    )
  }

  function availabilityFor(
    sourceLine: NonNullable<DamageSourceItem["lines"]>[number],
  ) {
    const receiptLineId = sourceLine.receipt_line_id ?? ""
    return inboundReceiptAvailability({
      damagedCases: sourceLine.damaged_cases ?? 0,
      alreadyReported: sourceLine.already_reported ?? 0,
      ownQuantity: savedOwnByReceiptLine[receiptLineId] ?? 0,
    })
  }

  function addFromSourceLine(
    sourceLine: NonNullable<DamageSourceItem["lines"]>[number],
  ) {
    const receiptLineId = sourceLine.receipt_line_id ?? ""
    if (
      receiptLineId &&
      lines.some((line) => line.receipt_line_id === receiptLineId)
    ) {
      return
    }
    const available = inbound
      ? availabilityFor(sourceLine).remaining
      : (sourceLine.remaining_cases ?? sourceLine.reserved_cases ?? 1)
    if (available < 1) return
    onChange([
      ...lines,
      {
        key: crypto.randomUUID(),
        product_id: sourceLine.product_id,
        product_sku: sourceLine.product_sku,
        product_name: sourceLine.product_name,
        quantity_cases: String(available),
        damage_reason: "",
        crate_id: sourceLine.crate_id ?? "",
        crate_code: sourceLine.crate_code ?? "",
        lot_id: sourceLine.lot_id ?? "",
        notes: "",
        receipt_line_id: receiptLineId,
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
                    {inbound
                      ? availabilityFor(sourceLine).remaining
                      : (sourceLine.remaining_cases ??
                        sourceLine.reserved_cases ??
                        0)}{" "}
                    cases
                  </td>
                  <td className="py-2 pr-3">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={
                        disabled ||
                        (inbound && availabilityFor(sourceLine).remaining < 1) ||
                        Boolean(
                          sourceLine.receipt_line_id &&
                            lines.some(
                              (line) =>
                                line.receipt_line_id ===
                                sourceLine.receipt_line_id,
                            ),
                        )
                      }
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

      {inbound && sourceLines.length > 0
        ? sourceLines.map((sourceLine) => {
            const available = availabilityFor(sourceLine)
            const qtyError = inboundQuantityMessage(
              parseCartonQuantity(
                lines.find(
                  (line) => line.receipt_line_id === sourceLine.receipt_line_id,
                )?.quantity_cases ?? "0",
              ) ?? 0,
              {
                damagedCases: available.damagedCases,
                remaining: available.remaining,
                claimingNumbers: claimingReports.map((row) => row.report_number),
              },
            )
            return (
              <div
                key={sourceLine.receipt_line_id ?? sourceLine.product_id}
                className="grid gap-1 rounded-xl bg-muted/40 px-3 py-2 text-sm"
              >
                <p>
                  Receipt damaged: {available.damagedCases} cases
                </p>
                <p>
                  Already claimed/reserved: {available.claimedByOthers} cases
                </p>
                {available.ownQuantity > 0 ? (
                  <p>This draft: {available.ownQuantity} cases</p>
                ) : null}
                <p>Available to report: {available.remaining} cases</p>
                {claimingReports.length > 0 ? (
                  <p>
                    These damaged cases are already linked to damage report{" "}
                    {claimingReports.map((row, index) => (
                      <span key={row.id}>
                        {index > 0 ? ", " : null}
                        <Link
                          className="underline-offset-4 hover:underline"
                          to={`/damage/${row.id}/edit`}
                        >
                          {row.report_number}
                        </Link>
                      </span>
                    ))}
                    .
                  </p>
                ) : null}
                {qtyError ? (
                  <p role="alert" className="text-destructive">
                    {qtyError}
                  </p>
                ) : null}
              </div>
            )
          })
        : null}

      {lines.length === 0 ? (
        <p className="text-sm text-muted-foreground">No damage lines yet.</p>
      ) : null}

      {/* One shared list so each line can suggest client Excel classifications. */}
      <datalist id="client-damage-classifications">
        {clientDamageClassifications.map((classification) => (
          <option key={classification} value={classification} />
        ))}
      </datalist>
      <ul className="grid gap-3">
        {lines.map((line, index) => {
          const eligibleLots = lotsForGrain(
            catalogs,
            line.crate_id,
            line.product_id,
          )
          const selectedLot = eligibleLots.find(
            (lot) => lot.lot_id === line.lot_id,
          )
          return (
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
                      // Product change invalidates lot selection for this grain.
                      patch(index, {
                        product_id: event.target.value,
                        product_sku: product?.sku ?? "",
                        product_name: product?.name ?? "",
                        lot_id: "",
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
                      // Crate change invalidates lot selection for this grain.
                      patch(index, {
                        crate_id: event.target.value,
                        crate_code: crate?.code ?? "",
                        lot_id: "",
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
                {scenario === "storage" && requireStorageLot ? (
                  <Label className="grid gap-2 text-sm font-medium md:col-span-2">
                    Stock lot
                    <select
                      aria-label="Stock lot"
                      className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                      value={line.lot_id}
                      disabled={
                        disabled || !line.product_id || !line.crate_id
                      }
                      onChange={(event) =>
                        patch(index, { lot_id: event.target.value })
                      }
                    >
                      <option value="">
                        {!line.product_id || !line.crate_id
                          ? "Select product and crate first"
                          : eligibleLots.length === 0
                            ? "No eligible lots at this crate"
                            : "Select damaged lot"}
                      </option>
                      {eligibleLots.map((lot) => (
                        <option key={lot.lot_id} value={lot.lot_id}>
                          {formatLotLabel(lot)}
                        </option>
                      ))}
                    </select>
                  </Label>
                ) : null}
                {scenario === "storage" && line.crate_id && line.product_id ? (
                  <div className="grid gap-1 text-xs text-muted-foreground md:col-span-2">
                    <p>
                      Crate on hand:{" "}
                      {onHand(catalogs, line.crate_id, line.product_id)} cases
                    </p>
                    {requireStorageLot && !line.product_id ? null : null}
                    {requireStorageLot &&
                    line.product_id &&
                    line.crate_id &&
                    eligibleLots.length === 0 ? (
                      <p role="status">
                        No lot balances with available cases for this product in
                        this crate. Reserved or held stock cannot be damaged
                        through storage isolation.
                      </p>
                    ) : null}
                    {selectedLot ? (
                      <p role="status">
                        Lot physical {selectedLot.on_hand_cases} · reserved{" "}
                        {selectedLot.reserved_cases} · held{" "}
                        {selectedLot.held_cases} · available{" "}
                        {selectedLot.available_cases}
                        {selectedLot.expiry_date
                          ? ` · expiry ${selectedLot.expiry_date}`
                          : ""}
                      </p>
                    ) : null}
                  </div>
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
                list="client-damage-classifications"
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
          )
        })}
      </ul>
    </section>
  )
}
