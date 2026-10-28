import { useMemo, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useAccess } from "@/lib/access/use-access"
import {
  approveDeliveryReturn,
  closeDeliveryReturnMissing,
  countDeliveryReturn,
  declareDeliveryReturnHandback,
  dispatchKeys,
  getDeliveryReturn,
  listDeliveryReturnStorageCrates,
  postDeliveryReturn,
  type DeliveryReturnLot,
} from "@/lib/dispatch/api"
import {
  cutoverBlocksDeliveryReturn,
  deliveryReturnEventLabel,
  deliveryReturnStatusLabel,
  deliveryReturnStatusTone,
  isStaleDispatchVersion,
  lotClassificationTotal,
} from "@/lib/dispatch/rules"

function nextKey(prefix: string) {
  return `${prefix}-${crypto.randomUUID()}`
}

function toQty(value: string) {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0
}

type LotDraft = {
  delivered_cases: string
  saleable_cases: string
  damaged_cases: string
  uncertain_cases: string
  missing_cases: string
  receiving_crate_id: string
}

function seedDraft(lots: DeliveryReturnLot[]): Record<string, LotDraft> {
  const next: Record<string, LotDraft> = {}
  for (const lot of lots) {
    next[lot.id] = {
      delivered_cases: String(lot.delivered_cases),
      saleable_cases: String(lot.saleable_cases),
      damaged_cases: String(lot.damaged_cases),
      uncertain_cases: String(lot.uncertain_cases),
      missing_cases: String(lot.missing_cases),
      receiving_crate_id: lot.receiving_crate_id ?? "",
    }
  }
  return next
}

function lotIsExpired(lot: DeliveryReturnLot) {
  if (!lot.expiry_date) return false
  return lot.expiry_date < new Date().toISOString().slice(0, 10)
}

export function DeliveryReturnPanel({ dispatchId }: { dispatchId: string }) {
  const queryClient = useQueryClient()
  const { can } = useAccess()
  const [actionError, setActionError] = useState<string | null>(null)
  const [handbackQty, setHandbackQty] = useState("")
  const [handbackNotes, setHandbackNotes] = useState("")
  const [draft, setDraft] = useState<Record<string, LotDraft>>({})

  const detail = useQuery({
    queryKey: dispatchKeys.deliveryReturn(dispatchId),
    queryFn: () => getDeliveryReturn(dispatchId),
    enabled: dispatchId !== "",
  })
  const returned = detail.data
  const crates = useQuery({
    queryKey: dispatchKeys.returnCrates(returned?.id ?? ""),
    queryFn: () => listDeliveryReturnStorageCrates(returned?.id ?? ""),
    enabled: Boolean(returned?.id) && can("deliveries.return_count"),
  })

  const seeded = useMemo(
    () => (returned ? seedDraft(returned.lots) : {}),
    [returned],
  )
  const lots = Object.keys(draft).length > 0 ? draft : seeded

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: dispatchKeys.detail(dispatchId) })
    await queryClient.invalidateQueries({
      queryKey: dispatchKeys.deliveryReturn(dispatchId),
    })
    await queryClient.invalidateQueries({ queryKey: ["dispatch-queue"] })
  }

  function onError(error: Error) {
    setActionError(
      isStaleDispatchVersion(error)
        ? "This return changed. Refresh and try again."
        : error.message,
    )
  }

  const handback = useMutation({
    mutationFn: () =>
      declareDeliveryReturnHandback({
        target_return: returned?.id ?? "",
        declared_returned_cases: toQty(handbackQty),
        handback_notes: handbackNotes.trim() === "" ? null : handbackNotes.trim(),
        expected_version: returned?.version ?? 1,
        idempotency_key: nextKey("dr-hb"),
      }),
    onSuccess: refresh,
    onError,
  })
  const count = useMutation({
    mutationFn: () =>
      countDeliveryReturn({
        target_return: returned?.id ?? "",
        lot_counts: (returned?.lots ?? []).map((lot) => {
          const row = lots[lot.id] ?? seedDraft([lot])[lot.id]
          return {
            id: lot.id,
            delivered_cases: toQty(row.delivered_cases),
            saleable_cases: toQty(row.saleable_cases),
            damaged_cases: toQty(row.damaged_cases),
            uncertain_cases: toQty(row.uncertain_cases),
            missing_cases: toQty(row.missing_cases),
            receiving_crate_id: row.receiving_crate_id || null,
          }
        }),
        expected_version: returned?.version ?? 1,
        idempotency_key: nextKey("dr-ct"),
      }),
    onSuccess: refresh,
    onError,
  })
  const approve = useMutation({
    mutationFn: () =>
      approveDeliveryReturn({
        target_return: returned?.id ?? "",
        expected_version: returned?.version ?? 1,
        idempotency_key: nextKey("dr-ap"),
      }),
    onSuccess: refresh,
    onError,
  })
  const post = useMutation({
    mutationFn: () =>
      postDeliveryReturn({
        target_return: returned?.id ?? "",
        expected_version: returned?.version ?? 1,
        idempotency_key: nextKey("dr-post"),
      }),
    onSuccess: refresh,
    onError,
  })
  const closeMissing = useMutation({
    mutationFn: () =>
      closeDeliveryReturnMissing({
        target_return: returned?.id ?? "",
        expected_version: returned?.version ?? 1,
        idempotency_key: nextKey("dr-miss"),
      }),
    onSuccess: refresh,
    onError,
  })

  if (detail.isLoading) {
    return <p className="text-sm text-slate-600">Loading return…</p>
  }
  if (detail.error) {
    return (
      <p role="alert" className="text-sm text-destructive">
        {detail.error.message}
      </p>
    )
  }
  if (!returned) return null

  const physical = returned.lots.reduce(
    (sum, lot) => sum + lot.saleable_cases + lot.damaged_cases + lot.uncertain_cases,
    0,
  )
  const missing = returned.lots.reduce((sum, lot) => sum + lot.missing_cases, 0)
  const cutoverBlock = cutoverBlocksDeliveryReturn(returned.cutover.dual_write_enabled)
  const stocked = Boolean(returned.posted_transaction_id)
  const canHandback =
    can("deliveries.return_handback") &&
    ["awaiting_handback", "handed_back"].includes(returned.status)
  const canCount =
    can("deliveries.return_count") && ["handed_back", "counted"].includes(returned.status)
  const canApprove = can("deliveries.return_approve") && returned.status === "counted"
  const canPost = can("deliveries.return_post") && returned.status === "approved"
  const canCloseMissing =
    can("deliveries.return_post") &&
    ["counted", "approved"].includes(returned.status) &&
    physical === 0 &&
    missing > 0 &&
    returned.unresolved_cases === 0
  const pending =
    handback.isPending ||
    count.isPending ||
    approve.isPending ||
    post.isPending ||
    closeMissing.isPending

  function setLot(id: string, field: keyof LotDraft, value: string) {
    setDraft((current) => {
      const base = current[id] ?? lots[id]
      return { ...current, [id]: { ...base, [field]: value } }
    })
  }

  return (
    <section>
      <h2 className="mb-2 text-base font-semibold">Failed-delivery return</h2>
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <StatusBadge tone={deliveryReturnStatusTone[returned.status] ?? "neutral"}>
          {deliveryReturnStatusLabel[returned.status] ?? returned.status}
        </StatusBadge>
        <span className="text-sm text-slate-600">{returned.return_number}</span>
      </div>
      <p className="mb-3 text-sm text-slate-600">
        {stocked
          ? `Stock credited on transaction ${returned.posted_transaction_id}. The original dispatch debit is unchanged.`
          : "Inventory is still deducted. Goods are not saleable until this return is posted to stock."}
      </p>
      <dl className="mb-4 grid gap-2 text-sm sm:grid-cols-2">
        <div>
          <dt className="text-slate-500">Driver handback</dt>
          <dd>{returned.declared_returned_cases} declared cases</dd>
        </div>
        <div>
          <dt className="text-slate-500">Unresolved</dt>
          <dd>{returned.unresolved_cases}</dd>
        </div>
        <div>
          <dt className="text-slate-500">Counted by</dt>
          <dd>{returned.counted_by_name ?? "—"}</dd>
        </div>
        <div>
          <dt className="text-slate-500">Missing cases</dt>
          <dd>{missing}</dd>
        </div>
      </dl>

      {actionError ? (
        <p role="alert" className="mb-3 text-sm text-destructive">
          {actionError}
        </p>
      ) : null}

      {canHandback ? (
        <form
          className="mb-4 grid gap-2 sm:grid-cols-[8rem_1fr_auto] sm:items-end"
          onSubmit={(event) => {
            event.preventDefault()
            handback.mutate()
          }}
        >
          <label className="grid gap-1 text-sm font-medium">
            Cases handed back
            <input
              className="h-10 rounded-lg border border-input px-2.5 text-sm font-normal"
              inputMode="numeric"
              value={handbackQty}
              onChange={(event) => setHandbackQty(event.target.value)}
              aria-label="Cases handed back"
            />
          </label>
          <label className="grid gap-1 text-sm font-medium">
            Notes (optional)
            <input
              className="h-10 rounded-lg border border-input px-2.5 text-sm font-normal"
              value={handbackNotes}
              onChange={(event) => setHandbackNotes(event.target.value)}
              maxLength={500}
              aria-label="Handback notes"
            />
          </label>
          <Button type="submit" disabled={pending}>
            {handback.isPending ? "Saving" : "Record handback"}
          </Button>
        </form>
      ) : null}

      <div className="mb-4 overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
        <table className="w-min min-w-full text-left text-sm">
          <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-3 font-medium">Original lot</th>
              <th className="px-3 py-3 font-medium">Dispatched</th>
              <th className="px-3 py-3 font-medium">Delivered</th>
              <th className="px-3 py-3 font-medium">Saleable</th>
              <th className="px-3 py-3 font-medium">Damaged</th>
              <th className="px-3 py-3 font-medium">Uncertain</th>
              <th className="px-3 py-3 font-medium">Missing</th>
              <th className="px-3 py-3 font-medium">Storage crate</th>
            </tr>
          </thead>
          <tbody>
            {returned.lots.map((lot) => {
              const row = lots[lot.id]
              const expired = lotIsExpired(lot)
              const classified = lotClassificationTotal({
                delivered_cases: toQty(row?.delivered_cases ?? "0"),
                saleable_cases: toQty(row?.saleable_cases ?? "0"),
                damaged_cases: toQty(row?.damaged_cases ?? "0"),
                uncertain_cases: toQty(row?.uncertain_cases ?? "0"),
                missing_cases: toQty(row?.missing_cases ?? "0"),
              })
              return (
                <tr key={lot.id} className="border-b border-slate-100 last:border-0 align-top">
                  <td className="px-3 py-3">
                    <div>
                      {lot.sku} · {lot.manufacturer_lot_code ?? lot.lot_id.slice(0, 8)}
                    </div>
                    <div className="text-xs text-slate-500">
                      Source {lot.source_crate_code}
                      {lot.expiry_date ? ` · exp ${lot.expiry_date}` : ""}
                      {expired ? " · expired — quarantine only" : ""}
                    </div>
                  </td>
                  <td className="px-3 py-3">{lot.dispatched_cases}</td>
                  {(
                    [
                      "delivered_cases",
                      "saleable_cases",
                      "damaged_cases",
                      "uncertain_cases",
                      "missing_cases",
                    ] as const
                  ).map((field) => (
                    <td key={field} className="px-3 py-3">
                      {canCount ? (
                        <input
                          className="h-9 w-16 rounded-lg border border-input px-2 text-sm"
                          inputMode="numeric"
                          value={row?.[field] ?? "0"}
                          onChange={(event) => setLot(lot.id, field, event.target.value)}
                          aria-label={`${field.replace(/_/g, " ")} for ${lot.sku}`}
                        />
                      ) : (
                        lot[field]
                      )}
                    </td>
                  ))}
                  <td className="px-3 py-3">
                    {canCount ? (
                      <select
                        className="h-9 min-w-40 rounded-lg border border-input bg-transparent px-2 text-sm"
                        value={row?.receiving_crate_id ?? ""}
                        onChange={(event) =>
                          setLot(lot.id, "receiving_crate_id", event.target.value)
                        }
                        aria-label={`Receiving crate for ${lot.sku}`}
                      >
                        <option value="">None</option>
                        {(crates.data ?? []).map((crate) => (
                          <option key={crate.id} value={crate.id}>
                            {crate.zone_code} / {crate.code}
                          </option>
                        ))}
                      </select>
                    ) : (
                      lot.receiving_crate_code ?? "—"
                    )}
                    {classified !== lot.dispatched_cases ? (
                      <div className="mt-1 text-xs text-destructive">
                        Must total {lot.dispatched_cases}
                      </div>
                    ) : null}
                    {toQty(row?.saleable_cases ?? "0") > 0 || lot.saleable_cases > 0 ? null : (
                      <div className="mt-1 text-xs text-slate-500">
                        Damaged or uncertain cases post to quarantine.
                      </div>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <div className="mb-4 flex flex-wrap gap-2">
        {canCount ? (
          <Button type="button" onClick={() => count.mutate()} disabled={pending}>
            {count.isPending ? "Saving" : "Save Store Keeper count"}
          </Button>
        ) : null}
        {canApprove ? (
          <Button type="button" onClick={() => approve.mutate()} disabled={pending}>
            {approve.isPending ? "Approving" : "Approve return"}
          </Button>
        ) : null}
        {canPost ? (
          <Button type="button" onClick={() => post.mutate()} disabled={pending || Boolean(cutoverBlock)}>
            {post.isPending ? "Posting" : "Post return to stock"}
          </Button>
        ) : null}
        {canCloseMissing ? (
          <Button
            type="button"
            variant="outline"
            onClick={() => closeMissing.mutate()}
            disabled={pending}
          >
            {closeMissing.isPending ? "Closing" : "Close as missing (no stock credit)"}
          </Button>
        ) : null}
      </div>

      {canApprove && returned.unresolved_cases > 0 ? (
        <p className="mb-2 text-sm text-slate-600">
          Approval is blocked until every dispatched lot is fully classified.
        </p>
      ) : null}
      {canPost && cutoverBlock ? (
        <p className="mb-2 text-sm text-slate-600">{cutoverBlock}</p>
      ) : null}
      {!canHandback &&
      !canCount &&
      !canApprove &&
      !canPost &&
      !canCloseMissing &&
      !stocked ? (
        <p className="mb-2 text-sm text-slate-600">
          You can view this return. Driver handback, Store Keeper count, and GM posting are
          separate permissions.
        </p>
      ) : null}

      <h3 className="mb-2 text-sm font-semibold">Return history</h3>
      <ol className="space-y-2 text-sm">
        {returned.events.map((event) => (
          <li key={event.id} className="rounded-lg bg-slate-50 px-3 py-2">
            <strong>{deliveryReturnEventLabel[event.event_type] ?? event.event_type}</strong>
            <span className="text-slate-500">
              {" "}
              · {new Date(event.created_at).toLocaleString()}
            </span>
          </li>
        ))}
      </ol>
    </section>
  )
}
