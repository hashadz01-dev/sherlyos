import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"
import { EmptyState } from "@/components/shared/EmptyState"
import type { DashboardBranchStock } from "@/lib/reports/api"
import type { ReportBranchOption } from "@/lib/branches/operational"

type ChartRow = {
  branchId: string
  name: string
  short: string
  code: string
  cartons: number
  inactive: boolean
}

/**
 * Compact stock-by-godown chart. Zero-stock authorized godowns stay visible.
 * Bar click applies the dashboard godown filter (no invented query params).
 */
export function InventoryDistributionChart({
  rows,
  branches,
  selectedBranchId,
  onSelectBranch,
}: {
  rows: DashboardBranchStock[]
  branches: ReportBranchOption[]
  selectedBranchId?: string
  onSelectBranch?: (branchId: string) => void
}) {
  const data: ChartRow[] = rows.map((row) => {
    const listed = branches.find((branch) => branch.id === row.branch_id)
    const inactive = listed ? !listed.is_active : false
    return {
      branchId: row.branch_id,
      name: row.branch_name,
      short: row.branch_code || row.branch_name.slice(0, 8),
      code: row.branch_code,
      cartons: row.cartons,
      inactive,
    }
  })
  const hasInactive = data.some((row) => row.inactive)

  return (
    <section
      className="flex h-full min-h-0 flex-col rounded-2xl bg-white ring-1 ring-slate-200/80"
      aria-labelledby="stock-distribution-heading"
    >
      <div className="border-b border-slate-100 px-4 py-3">
        <h2
          id="stock-distribution-heading"
          className="text-sm font-semibold text-slate-900"
        >
          Stock Distribution
        </h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          On-hand carton cases by authorized godown · snapshot
        </p>
      </div>

      {data.length === 0 ? (
        <div className="flex flex-1 items-center px-2 py-6">
          <EmptyState
            title="No godown stock to chart"
            description="Authorized godowns appear here when inventory reporting is visible."
          />
        </div>
      ) : (
        <>
          <div className="min-h-[14rem] flex-1 px-2 pb-2 pt-3 sm:min-h-[16rem]">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart
                data={data}
                margin={{ top: 4, right: 8, left: -8, bottom: 0 }}
              >
                <CartesianGrid
                  strokeDasharray="3 3"
                  stroke="#e2e8f0"
                  vertical={false}
                />
                <XAxis
                  dataKey="short"
                  tick={{ fontSize: 11, fill: "#64748b" }}
                  tickLine={false}
                  axisLine={{ stroke: "#e2e8f0" }}
                  interval={0}
                />
                <YAxis
                  tick={{ fontSize: 11, fill: "#64748b" }}
                  tickLine={false}
                  axisLine={false}
                  allowDecimals={false}
                  width={36}
                />
                <Tooltip
                  formatter={(value) => [
                    typeof value === "number" ? value : String(value ?? ""),
                    "Cartons on hand",
                  ]}
                  labelFormatter={(_label, payload) => {
                    const row = payload?.[0]?.payload as ChartRow | undefined
                    if (!row) return ""
                    return row.inactive
                      ? `${row.name} (${row.code}) · Inactive / Historical`
                      : `${row.name} (${row.code})`
                  }}
                  contentStyle={{
                    borderRadius: 10,
                    border: "1px solid #e2e8f0",
                    fontSize: 12,
                  }}
                />
                <Bar
                  dataKey="cartons"
                  radius={[5, 5, 0, 0]}
                  maxBarSize={36}
                  cursor={onSelectBranch ? "pointer" : "default"}
                  onClick={(item) => {
                    const row = item?.payload as ChartRow | undefined
                    if (row?.branchId && onSelectBranch) {
                      onSelectBranch(row.branchId)
                    }
                  }}
                >
                  {data.map((row) => (
                    <Cell
                      key={row.branchId}
                      fill={
                        selectedBranchId && selectedBranchId === row.branchId
                          ? "#1e3a5f"
                          : "#2f6fe0"
                      }
                    />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
          <p className="border-t border-slate-100 px-4 py-2 text-[11px] text-slate-500">
            {onSelectBranch
              ? "Click a godown bar to filter this dashboard. "
              : null}
            {hasInactive
              ? "Inactive / Historical godowns remain listed when they still hold snapshot stock."
              : "Zero-stock authorized godowns stay visible."}
          </p>
        </>
      )}
    </section>
  )
}
