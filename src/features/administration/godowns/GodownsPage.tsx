import { useState } from "react"
import { Link } from "react-router"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { Building2, Warehouse } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { formatCases } from "@/lib/warehouse/capacity"
import { notify } from "@/lib/utilities/notify"
import { buildGodownCards } from "@/lib/warehouse/model"
import {
  CapacityProgress,
  Metric,
} from "@/features/administration/godowns/components/WarehouseChrome"
import { useWarehouseSnapshot } from "@/features/administration/godowns/use-warehouse"

/**
 * Physical godown records. Persistence still uses public.branches and the
 * create_branch / set_branch_active RPCs so existing RLS and assignments stay valid.
 */
export function GodownsPage() {
  useDocumentTitle("Godowns")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [code, setCode] = useState("")
  const [name, setName] = useState("")
  const warehouse = useWarehouseSnapshot()

  const save = useMutation({
    mutationFn: async () => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase?.rpc("create_branch", {
        branch_code: code,
        branch_name: name,
      })
      if (result?.error) throw new Error(toUserRpcMessage(result.error))
    },
    onSuccess: async () => {
      setCode("")
      setName("")
      notify.success("Godown created")
      await queryClient.invalidateQueries({ queryKey: ["branches"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const toggle = useMutation({
    mutationFn: async (godown: { id: string; is_active: boolean }) => {
      const supabase = getSupabaseBrowserClient()
      const result = await supabase?.rpc("set_branch_active", {
        target_branch: godown.id,
        active: !godown.is_active,
      })
      if (result?.error) throw new Error(toUserRpcMessage(result.error))
    },
    onSuccess: async () => {
      notify.success("Godown status updated")
      await queryClient.invalidateQueries({ queryKey: ["branches"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const cards = warehouse.ready ? buildGodownCards(warehouse.ready) : []
  const stockBlocked = Boolean(warehouse.balances.error || warehouse.lots.error)
  const stockReady = warehouse.balances.isSuccess && warehouse.lots.isSuccess

  return (
    <section>
      <PageHeader
        title="Godowns"
        description="Physical warehouses. Planned capacity is a visual target of 1,200 cases and is not enforced. Renaming a godown is not available."
      />
      {can("branches.manage") ? (
        <form
          className="mb-4 grid gap-3 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80 sm:grid-cols-[1fr_1fr_auto]"
          onSubmit={(event) => {
            event.preventDefault()
            save.mutate()
          }}
        >
          <Input
            aria-label="Godown code"
            placeholder="Godown code"
            value={code}
            onChange={(event) => setCode(event.target.value)}
            required
          />
          <Input
            aria-label="Godown name"
            placeholder="Godown name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            required
          />
          <Button type="submit" disabled={save.isPending}>
            Create godown
          </Button>
        </form>
      ) : null}
      {warehouse.structureLoading ? <LoadingBlock label="Loading godowns" /> : null}
      {warehouse.structureError ? (
        <EmptyState
          icon={Building2}
          title="Godowns could not be loaded"
          description={
            warehouse.structureError instanceof Error
              ? warehouse.structureError.message
              : "Try again."
          }
        />
      ) : null}
      {stockBlocked ? (
        <p role="alert" className="mb-3 text-sm text-destructive">
          Stock figures are unavailable for this account. Locations stay visible,
          but occupancy is not shown as zero.
        </p>
      ) : null}
      {!warehouse.structureLoading &&
      !warehouse.structureError &&
      (warehouse.godowns.data?.length ?? 0) === 0 ? (
        <EmptyState
          icon={Building2}
          title="No godowns"
          description="Create a godown when you know the real warehouse name."
        />
      ) : null}
      <ul className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {cards.map((card) => (
          <li
            key={card.id}
            className="relative cursor-pointer rounded-2xl bg-white p-4 ring-1 ring-slate-200 transition hover:bg-slate-50 hover:ring-slate-400"
          >
            <Link
              to={`/godowns/${card.id}/zones`}
              className="absolute inset-0 z-0 cursor-pointer rounded-2xl focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-slate-900"
              aria-label={`Open zones for ${card.name}`}
            />
            <div className="pointer-events-none flex items-start justify-between gap-3">
              <div className="min-w-0">
                <span className="flex items-center gap-2">
                  <Warehouse className="size-4 text-slate-500" aria-hidden="true" />
                  <span className="font-medium">{card.name}</span>
                </span>
                <span className="mt-1 block text-xs text-muted-foreground">
                  {card.code} · {card.classification}
                </span>
              </div>
              <StatusBadge tone={card.active ? "success" : "neutral"}>
                {card.active ? "Active" : "Inactive"}
              </StatusBadge>
            </div>
            {!card.active ? (
              <p className="pointer-events-none mt-2 text-xs text-muted-foreground">
                Inactive godowns stay visible, including historical stock. New
                operations remain restricted.
              </p>
            ) : null}
            <dl className="pointer-events-none mt-3 grid grid-cols-2 gap-2">
              <Metric label="Configured zones" value={String(card.zoneCount)} />
              <Metric label="Configured crates" value={String(card.crateCount)} />
              <Metric
                label="On hand"
                value={
                  stockBlocked || !stockReady
                    ? stockBlocked
                      ? "Unavailable"
                      : "…"
                    : formatCases(card.metrics.onHand)
                }
              />
              <Metric
                label="Quarantine"
                value={
                  stockBlocked || !stockReady
                    ? stockBlocked
                      ? "Unavailable"
                      : "…"
                    : formatCases(card.metrics.quarantineOnHand)
                }
              />
              <Metric
                label="Planned capacity"
                value={formatCases(card.metrics.plannedCapacity)}
              />
              <Metric
                label="Configured capacity"
                value={formatCases(card.metrics.configuredCapacity)}
              />
              <Metric
                label="Free physical capacity"
                value={
                  stockBlocked || !stockReady
                    ? stockBlocked
                      ? "Unavailable"
                      : "…"
                    : formatCases(card.metrics.freePhysical)
                }
              />
              <Metric
                label="Available to pick"
                value={
                  stockBlocked || !stockReady || card.metrics.availableToPick === null
                    ? stockBlocked || card.metrics.availableToPick === null
                      ? "Unavailable"
                      : "…"
                    : formatCases(card.metrics.availableToPick)
                }
              />
            </dl>
            <div className="pointer-events-none mt-3">
              <CapacityProgress
                ratio={stockReady && !stockBlocked ? card.metrics.occupancy : null}
                over={stockReady && !stockBlocked && card.metrics.overCapacity > 0}
              />
              {stockReady && !stockBlocked && card.metrics.overCapacity > 0 ? (
                <p className="mt-1 text-xs text-amber-800">
                  Over capacity by {formatCases(card.metrics.overCapacity)}. Stock
                  was not changed.
                </p>
              ) : null}
            </div>
            <div className="pointer-events-none mt-3 flex items-center justify-between gap-2">
              <span className="pointer-events-none text-sm font-medium">Open zones</span>
              {can("branches.manage") ? (
                <Button
                  className="pointer-events-auto relative z-10"
                  variant="outline"
                  size="sm"
                  onClick={() =>
                    toggle.mutate({ id: card.id, is_active: card.active })
                  }
                  disabled={toggle.isPending}
                >
                  {card.active ? "Deactivate" : "Activate"}
                </Button>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
      {!stockBlocked && cards.length > 0 && warehouse.ready && !warehouse.ready.reservationsVisible ? (
        <p className="mt-3 text-xs text-muted-foreground">
          Visible reservations could not be read, so available-to-pick is not shown.
        </p>
      ) : null}
    </section>
  )
}
