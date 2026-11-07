import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { ActivityTrends } from "@/features/dashboard/ActivityTrends"
import {
  AttentionQueue,
  buildAttentionItems,
} from "@/features/dashboard/AttentionQueue"
import { DashboardHeader } from "@/features/dashboard/DashboardHeader"
import { DashboardKpiGrid } from "@/features/dashboard/DashboardKpiGrid"
import { DashboardQuickActions } from "@/features/dashboard/DashboardQuickActions"
import { InventoryAvailability } from "@/features/dashboard/InventoryAvailability"
import { InventoryDistributionChart } from "@/features/dashboard/InventoryDistributionChart"
import { OperationsModuleGrid } from "@/features/dashboard/OperationsModuleGrid"
import { OrderPipeline } from "@/features/dashboard/OrderPipeline"
import { useReportBranchFilter } from "@/features/reports/use-report-branch-filter"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { getDamageDashboard } from "@/lib/damage/api"
import {
  canAny,
  dispatchReportPermissions,
  inventoryReportPermissions,
  operationsReportPermissions,
  orderReportPermissions,
} from "@/lib/reports/access"
import {
  getOperationsDashboard,
  reportKeys,
  type OperationsDashboard,
} from "@/lib/reports/api"

/**
 * Compact operations command centre.
 * Snapshot RPCs only — period reporting stays disabled until owner approval.
 */
export function DashboardPage() {
  useDocumentTitle(
    "Operations Dashboard",
    "Your warehouse operations at a glance.",
  )
  const access = useAccess()
  const { session } = useAuth()
  const { branchId, setBranchId, branches } = useReportBranchFilter()

  const canReport = canAny(access, operationsReportPermissions)
  const canDamage = access.can("damage.read")

  const dashboard = useQuery({
    queryKey: reportKeys.dashboard(session?.user.id, branchId),
    queryFn: () => getOperationsDashboard(branchId || null),
    enabled: canReport,
  })

  const damage = useQuery({
    queryKey: reportKeys.damageDashboard(session?.user.id, branchId),
    queryFn: () => getDamageDashboard(branchId || null),
    enabled: canDamage,
  })

  function refresh() {
    void dashboard.refetch()
    if (canDamage) void damage.refetch()
  }

  function clearFilters() {
    setBranchId("")
  }

  return (
    <section className="pb-2">
      <DashboardHeader
        email={session?.user.email}
        roles={access.roles}
        dataUpdatedAt={dashboard.dataUpdatedAt}
        refreshing={dashboard.isFetching || damage.isFetching}
        onRefresh={refresh}
        showFilters={canReport || canDamage}
        branchId={branchId}
        onBranch={setBranchId}
        branches={branches}
        onClear={clearFilters}
        cutoverOff={Boolean(
          dashboard.data && !dashboard.data.cutover.dual_write_enabled,
        )}
      />

      {!canReport ? (
        <p className="mb-4 text-sm text-muted-foreground">
          Signed in, but this account has no operational reporting permission.
        </p>
      ) : null}

      {canReport || canDamage ? <ActivityTrends /> : null}

      {canReport && dashboard.isLoading ? (
        <LoadingBlock label="Loading operations dashboard" />
      ) : null}

      {dashboard.error ? (
        <div className="mb-4 rounded-xl bg-red-50 px-4 py-3 text-sm text-red-900 ring-1 ring-red-200">
          <p role="alert">{dashboard.error.message}</p>
          <button
            type="button"
            className="mt-2 font-medium underline"
            onClick={() => void dashboard.refetch()}
          >
            Retry
          </button>
        </div>
      ) : null}

      {dashboard.data ? (
        <DashboardBody
          data={dashboard.data}
          branches={branches}
          branchId={branchId}
          onSelectBranch={setBranchId}
          damage={damage.data ?? null}
          damageError={damage.error?.message ?? null}
          onRetryDamage={() => void damage.refetch()}
          can={access.can}
        />
      ) : null}

      <DashboardQuickActions can={access.can} />

      {canReport ? (
        <p className="mt-3 text-xs text-muted-foreground">
          {canAny(access, inventoryReportPermissions) ? (
            <Link className="mr-3 underline" to="/reports/inventory">
              Inventory report
            </Link>
          ) : null}
          {canAny(access, orderReportPermissions) ? (
            <Link className="mr-3 underline" to="/reports/orders-picking">
              Orders and packing
            </Link>
          ) : null}
          {canAny(access, dispatchReportPermissions) ? (
            <Link className="underline" to="/reports/dispatch">
              Dispatch and delivery
            </Link>
          ) : null}
        </p>
      ) : null}
    </section>
  )
}

function DashboardBody({
  data,
  branches,
  branchId,
  onSelectBranch,
  damage,
  damageError,
  onRetryDamage,
  can,
}: {
  data: OperationsDashboard
  branches: { id: string; name: string; code?: string; is_active: boolean }[]
  branchId: string
  onSelectBranch: (branchId: string) => void
  damage: import("@/lib/damage/api").DamageDashboard | null
  damageError: string | null
  onRetryDamage: () => void
  can: (permission: string) => boolean
}) {
  const attention = buildAttentionItems(data, damage)
  const stockRows = data.inventory.visible
    ? (data.inventory.stock_by_godown ?? [])
    : []

  return (
    <>
      <DashboardKpiGrid data={data} />

      {damageError ? (
        <div className="mb-4 rounded-xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200">
          <p role="alert">Damage queues could not load: {damageError}</p>
          <button
            type="button"
            className="mt-2 font-medium underline"
            onClick={onRetryDamage}
          >
            Retry damage
          </button>
        </div>
      ) : null}

      {data.inventory.visible ? (
        <div className="mb-4 grid gap-3 xl:grid-cols-12 xl:items-stretch">
          <div className="xl:col-span-4">
            <AttentionQueue items={attention} />
          </div>
          <div className="xl:col-span-5">
            <InventoryDistributionChart
              rows={stockRows}
              branches={branches}
              selectedBranchId={branchId}
              onSelectBranch={onSelectBranch}
            />
          </div>
          <div className="xl:col-span-3">
            <InventoryAvailability
              inventory={data.inventory}
              cutoverOff={!data.cutover.dual_write_enabled}
            />
          </div>
        </div>
      ) : (
        <div className="mb-4">
          <AttentionQueue items={attention} />
        </div>
      )}

      <OrderPipeline data={data} />

      <OperationsModuleGrid
        data={data}
        damage={damage}
        canAdjust={
          can("stock.adjustment.request") ||
          can("stock.adjustment.post") ||
          can("operations.monitor")
        }
        canTransfer={can("stock.transfer.post")}
      />
    </>
  )
}
