import { useMemo, useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { FilterSelect, FilterToolbar, SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { hasCompanyWideGodownAccess, loadOwnAssignedBranchIds } from "@/lib/access/godown-scope"
import {
  listDeliveryNotes,
  listVerifiedOrdersWithoutDn,
  type DeliveryNoteStatus,
} from "@/lib/delivery-notes/api"
import {
  describeHandoverQueue,
  HANDOVER_QUEUE_TITLE,
  summarizeOrderLines,
} from "@/lib/delivery-notes/handover"
import { loadOrderBranches, loadOrderLineRows, loadOrderShops } from "@/lib/orders/api"
import { formatOrderTimestamp, readableSiteLabel } from "@/lib/orders/verification"
import { matchesSearch } from "@/lib/masters/filters"

const tone: Record<DeliveryNoteStatus, StatusTone> = {
  draft: "neutral",
  generated: "info",
  sent: "warning",
  acknowledged: "success",
  voided: "danger",
}

function formatStamp(value: string | null | undefined) {
  if (!value) return "—"
  return value.slice(0, 19).replace("T", " ")
}

export function DeliveriesPage() {
  useDocumentTitle("Delivery notes")
  const { can, roles } = useAccess()
  const canIssue = can("delivery_notes.issue")
  const companyWideGodownAccess = hasCompanyWideGodownAccess(can, roles)
  const canAcknowledge = can("delivery_notes.acknowledge")
  const isGodownInbox = canAcknowledge && !canIssue
  const [search, setSearch] = useState("")
  // Sent is only the acknowledgement queue. Acknowledged notes are the history,
  // so the inbox starts on every status the godown can already view.
  const [status, setStatus] = useState("all")
  const [shopId, setShopId] = useState("all")
  const [branchId, setBranchId] = useState("all")

  const notes = useQuery({
    queryKey: ["delivery-notes", status, shopId, branchId],
    queryFn: () =>
      listDeliveryNotes({
        status,
        shopId,
        branchId,
      }),
  })
  const queue = useQuery({
    queryKey: ["verified-orders-without-dn"],
    queryFn: listVerifiedOrdersWithoutDn,
    enabled: canIssue,
  })
  const assignments = useQuery({
    queryKey: ["own-branch-assignments"],
    queryFn: loadOwnAssignedBranchIds,
    enabled: canIssue && !companyWideGodownAccess,
  })
  const shops = useQuery({ queryKey: ["order-shops"], queryFn: loadOrderShops })
  const branches = useQuery({
    queryKey: ["order-branches"],
    queryFn: loadOrderBranches,
  })
  const queueIds = (queue.data ?? []).map((row) => row.id)
  const lineSummary = useQuery({
    queryKey: ["order-line-summary", queueIds.join(",")],
    queryFn: async () => summarizeOrderLines(await loadOrderLineRows(queueIds)),
    enabled: canIssue && queueIds.length > 0,
  })

  const shopName = useMemo(
    () => new Map((shops.data ?? []).map((shop) => [shop.id, shop.name])),
    [shops.data],
  )
  const branchName = useMemo(
    () => new Map((branches.data ?? []).map((branch) => [branch.id, branch.name])),
    [branches.data],
  )

  const rows = (notes.data ?? []).filter((row) =>
    matchesSearch(search, [
      row.delivery_note_number,
      row.order_number ?? "",
      shopName.get(row.shop_id) ?? "",
      branchName.get(row.branch_id) ?? "",
      row.status,
    ]),
  )
  const handover = describeHandoverQueue({
    canIssue,
    loading: queue.isLoading || assignments.isLoading,
    errorMessage: (queue.error ?? assignments.error)?.message ?? null,
    assignedBranchCount: assignments.data?.length ?? 0,
    queueLength: queue.data?.length ?? 0,
    companyWideGodownAccess,
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title={isGodownInbox ? "Delivery note inbox" : "Delivery notes"}
        description={
          isGodownInbox
            ? "Review delivery notes for your assigned godowns, including notes already acknowledged. Stock does not change here."
            : "Create draft delivery notes from verified orders, generate, send to godown, and void when required."
        }
        action={
          canIssue ? (
            <Button asChild>
              <Link to="/deliveries/new">New delivery note</Link>
            </Button>
          ) : null
        }
      />

      {notes.isLoading || shops.isLoading || branches.isLoading ? (
        <LoadingBlock label="Loading delivery notes" />
      ) : null}
      {notes.error || shops.error || branches.error ? (
        <p role="alert" className="text-sm text-destructive">
          {(notes.error ?? shops.error ?? branches.error)?.message}
        </p>
      ) : null}

      {canIssue ? (
        <div className="mb-8 grid gap-3">
          {/* Queue comes from list_verified_orders_without_dn, not list_orders. */}
          <h2 className="text-sm font-medium">{HANDOVER_QUEUE_TITLE}</h2>
          {handover.state === "loading" ? (
            <LoadingBlock label="Loading verified orders" />
          ) : null}
          {handover.state === "error" ? (
            <p role="alert" className="text-sm text-destructive">
              {handover.message}
            </p>
          ) : null}
          {handover.state === "unauthorized" ||
          handover.state === "no_site_assignment" ||
          handover.state === "empty" ? (
            <EmptyState title={handover.title} description={handover.message} />
          ) : null}
          {handover.state === "ready" ? (
            <ul className="grid gap-2">
              {(queue.data ?? []).map((order) => {
                const summary = lineSummary.data?.get(order.id)
                return (
                  <li
                    key={order.id}
                    className="flex flex-col gap-3 rounded-2xl bg-card p-4 ring-1 ring-border sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div className="min-w-0">
                      <p className="font-medium">{order.order_number}</p>
                      <dl className="mt-2 grid gap-1 text-sm text-muted-foreground sm:grid-cols-2">
                        <div>
                          <dt className="inline">Shop: </dt>
                          <dd className="inline">
                            {readableSiteLabel(shopName.get(order.shop_id), "Shop")}
                          </dd>
                        </div>
                        <div>
                          <dt className="inline">Godown: </dt>
                          <dd className="inline">
                            {readableSiteLabel(branchName.get(order.branch_id), "Godown")}
                          </dd>
                        </div>
                        <div>
                          <dt className="inline">Verified: </dt>
                          <dd className="inline">{formatOrderTimestamp(order.verified_at)}</dd>
                        </div>
                        <div>
                          <dt className="inline">Lines: </dt>
                          <dd className="inline">{summary?.lines ?? "—"}</dd>
                        </div>
                        <div>
                          <dt className="inline">Whole cases: </dt>
                          <dd className="inline">{summary?.cases ?? "—"}</dd>
                        </div>
                      </dl>
                    </div>
                    <Button asChild className="w-full sm:w-auto">
                      <Link to={`/deliveries/new?orderId=${order.id}`}>Create Delivery Note</Link>
                    </Button>
                  </li>
                )
              })}
            </ul>
          ) : null}
        </div>
      ) : null}

      {notes.data ? (
        <>
          <h2 className="mb-3 text-sm font-medium">Delivery notes already created</h2>
          <FilterToolbar>
            <SearchField label="Search delivery notes" value={search} onChange={setSearch} />
            <FilterSelect label="Status" value={status} onChange={setStatus}>
              <option value="all">All statuses</option>
              <option value="draft">Draft</option>
              <option value="generated">Generated</option>
              <option value="sent">Sent</option>
              <option value="acknowledged">Acknowledged</option>
              <option value="voided">Voided</option>
            </FilterSelect>
            <FilterSelect label="Shop" value={shopId} onChange={setShopId}>
              <option value="all">All shops</option>
              {(shops.data ?? []).map((shop) => (
                <option key={shop.id} value={shop.id}>
                  {shop.name}
                </option>
              ))}
            </FilterSelect>
            <FilterSelect label="Godown" value={branchId} onChange={setBranchId}>
              <option value="all">All godowns</option>
              {(branches.data ?? []).map((branch) => (
                <option key={branch.id} value={branch.id}>
                  {branch.name}
                </option>
              ))}
            </FilterSelect>
          </FilterToolbar>

          {rows.length === 0 ? (
            <EmptyState
              title={
                status === "sent" ? "No sent delivery notes" : "No delivery notes"
              }
              description={
                status === "sent"
                  ? "Sent notes for your assigned godowns will appear here for acknowledgement."
                  : status === "all"
                    ? isGodownInbox
                      ? "Sent and acknowledged notes for your assigned godowns appear here."
                      : "Draft and generated delivery notes for authorized godowns will appear here."
                    : "No delivery notes match this filter."
              }
            />
          ) : (
            <ul className="grid gap-3">
              {rows.map((row) => (
                <li key={row.id}>
                  <Link
                    to={`/deliveries/${row.id}`}
                    className="block rounded-2xl bg-card p-4 ring-1 ring-border transition hover:ring-foreground/20"
                  >
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="font-medium">{row.delivery_note_number}</p>
                      <StatusBadge tone={tone[row.status]}>{row.status}</StatusBadge>
                    </div>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {row.order_number ? `Order ${row.order_number} · ` : null}
                      {readableSiteLabel(shopName.get(row.shop_id), "Shop")} ·{" "}
                      {readableSiteLabel(branchName.get(row.branch_id), "Godown")}
                      {typeof row.total_cases === "number"
                        ? ` · ${row.total_cases} cases`
                        : null}
                    </p>
                    {row.sent_at ? (
                      <p className="mt-1 text-sm text-muted-foreground">
                        Sent {formatStamp(row.sent_at)}
                      </p>
                    ) : null}
                    {row.acknowledged_at ? (
                      <p className="mt-1 text-sm text-muted-foreground">
                        Acknowledged {formatStamp(row.acknowledged_at)}
                      </p>
                    ) : null}
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </>
      ) : null}
    </section>
  )
}
