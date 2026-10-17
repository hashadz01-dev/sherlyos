import { useMemo, useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  listDeliveryNotes,
  listVerifiedOrdersWithoutDn,
  type DeliveryNoteStatus,
} from "@/lib/delivery-notes/api"
import { loadOrderBranches, loadOrderShops } from "@/lib/orders/api"
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
  const { can } = useAccess()
  const canIssue = can("delivery_notes.issue")
  const canAcknowledge = can("delivery_notes.acknowledge")
  const isGodownInbox = canAcknowledge && !canIssue
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState(isGodownInbox ? "sent" : "all")
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
  const shops = useQuery({ queryKey: ["order-shops"], queryFn: loadOrderShops })
  const branches = useQuery({
    queryKey: ["order-branches"],
    queryFn: loadOrderBranches,
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

  return (
    <section className="min-w-0">
      <PageHeader
        title={isGodownInbox ? "Delivery note inbox" : "Delivery notes"}
        description={
          isGodownInbox
            ? "Review sent delivery notes for your assigned godowns and acknowledge receipt. Stock does not change here."
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
          <h2 className="text-sm font-medium">Verified orders without a delivery note</h2>
          {queue.isLoading ? <LoadingBlock label="Loading verified orders" /> : null}
          {queue.error ? (
            <p role="alert" className="text-sm text-destructive">
              {queue.error.message}
            </p>
          ) : null}
          {(queue.data ?? []).length === 0 && !queue.isLoading ? (
            <EmptyState
              title="No verified orders waiting"
              description="Orders appear here after Accounts verifies them and before a non-voided delivery note exists."
            />
          ) : null}
          <ul className="grid gap-2">
            {(queue.data ?? []).map((order) => (
              <li
                key={order.id}
                className="flex flex-col gap-3 rounded-2xl bg-card p-4 ring-1 ring-border sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="min-w-0">
                  <p className="font-medium">{order.order_number}</p>
                  <p className="text-sm text-muted-foreground">
                    {shopName.get(order.shop_id) ?? order.shop_id} ·{" "}
                    {branchName.get(order.branch_id) ?? order.branch_id}
                  </p>
                </div>
                <Button asChild className="w-full sm:w-auto">
                  <Link to={`/deliveries/new?orderId=${order.id}`}>Create draft</Link>
                </Button>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {notes.data ? (
        <>
          <div className="mb-4 grid gap-3 md:grid-cols-4">
            <SearchField label="Search delivery notes" value={search} onChange={setSearch} />
            <label className="grid gap-2 text-sm font-medium">
              Status
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                <option value="all">All statuses</option>
                <option value="draft">Draft</option>
                <option value="generated">Generated</option>
                <option value="sent">Sent</option>
                <option value="acknowledged">Acknowledged</option>
                <option value="voided">Voided</option>
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Shop
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={shopId}
                onChange={(event) => setShopId(event.target.value)}
              >
                <option value="all">All shops</option>
                {(shops.data ?? []).map((shop) => (
                  <option key={shop.id} value={shop.id}>
                    {shop.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Godown
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={branchId}
                onChange={(event) => setBranchId(event.target.value)}
              >
                <option value="all">All godowns</option>
                {(branches.data ?? []).map((branch) => (
                  <option key={branch.id} value={branch.id}>
                    {branch.name}
                  </option>
                ))}
              </select>
            </label>
          </div>

          {rows.length === 0 ? (
            <EmptyState
              title={isGodownInbox ? "No sent delivery notes" : "No delivery notes"}
              description={
                isGodownInbox
                  ? "Sent notes for your assigned godowns will appear here for acknowledgement."
                  : "Draft and generated delivery notes for authorized godowns will appear here."
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
                      {shopName.get(row.shop_id) ?? row.shop_id} ·{" "}
                      {branchName.get(row.branch_id) ?? row.branch_id}
                      {typeof row.total_cases === "number"
                        ? ` · ${row.total_cases} cases`
                        : null}
                    </p>
                    {row.sent_at ? (
                      <p className="mt-1 text-sm text-muted-foreground">
                        Sent {formatStamp(row.sent_at)}
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
