import type { ReactNode } from "react"
import { Link, useParams } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageActivityTimeline } from "@/features/damage/components/DamageActivityTimeline"
import { DamageCustodyPanel } from "@/features/damage/components/DamageCustodyPanel"
import { DamageEvidencePanel } from "@/features/damage/components/DamageEvidencePanel"
import { DamageEvidenceUploader } from "@/features/damage/components/DamageEvidenceUploader"
import { DamageHoldsPanel } from "@/features/damage/components/DamageHoldsPanel"
import { DamageLifecycleTimeline } from "@/features/damage/components/DamageLifecycleTimeline"
import { DamageExceptionalExecutionPanel } from "@/features/damage/components/DamageExceptionalExecutionPanel"
import { DamageExceptionalRequestPanel } from "@/features/damage/components/DamageExceptionalRequestPanel"
import { DamageExceptionalReviewPanel } from "@/features/damage/components/DamageExceptionalReviewPanel"
import { DamageOrdinaryWriteoffPanel } from "@/features/damage/components/DamageOrdinaryWriteoffPanel"
import { DamageVerificationHistory } from "@/features/damage/components/DamageVerificationHistory"
import { DamageVerificationPanel } from "@/features/damage/components/DamageVerificationPanel"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { useAuth } from "@/hooks/use-auth"
import { isEditableDamageStatus } from "@/lib/damage/rules"
import {
  damageStatusTone,
  formatCases,
  formatDamageScenario,
  formatDamageStatus,
  formatTimestamp,
} from "@/features/damage/utils/labels"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { getDamageReport } from "@/lib/damage/api"

function DetailSection({
  title,
  children,
}: {
  title: string
  children: ReactNode
}) {
  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <h2 className="mb-3 text-sm font-semibold">{title}</h2>
      {children}
    </section>
  )
}

export function DamageReportDetailPage() {
  const { reportId = "" } = useParams()
  const access = useDamageAccess()
  const { session } = useAuth()
  const userId = session?.user.id
  const detail = useQuery({
    queryKey: ["damage-report", reportId],
    queryFn: () => getDamageReport(reportId),
    enabled: reportId !== "" && access.canOpenDamage,
  })

  const report = detail.data
  useDocumentTitle(report ? report.report_number : "Damage report")

  return (
    <section className="min-w-0">
      <PageHeader
        title={report?.report_number ?? "Damage report"}
        description="Damage report detail. Custody and quarantine transfer use trusted backend RPCs."
        action={
          <div className="flex flex-wrap gap-2">
            {report &&
            access.canCreate &&
            report.reporter_user_id === userId &&
            isEditableDamageStatus(report.status) ? (
              <Button asChild>
                <Link to={`/damage/${report.id}/edit`}>Edit draft</Link>
              </Button>
            ) : null}
            {access.canViewVerification ? (
              <Button asChild variant="outline">
                <Link to="/damage/verification">Verification queue</Link>
              </Button>
            ) : null}
            {access.canViewExceptionalQueue ? (
              <Button asChild variant="outline">
                <Link to="/damage/exceptional">Exceptional approvals</Link>
              </Button>
            ) : null}
            {access.canViewQuarantine ? (
              <Button asChild variant="outline">
                <Link to="/damage/quarantine">Quarantine</Link>
              </Button>
            ) : null}
            <Button asChild variant="outline">
              <Link to="/damage/reports">Back to list</Link>
            </Button>
            <Button asChild variant="outline">
              <Link to="/damage">Dashboard</Link>
            </Button>
          </div>
        }
      />

      {detail.isLoading ? <LoadingBlock label="Loading damage report" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}

      {report ? (
        <div className="grid gap-4">
          <DetailSection title="Header">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <dl className="grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
                <div>
                  <dt className="text-muted-foreground">Scenario</dt>
                  <dd>{formatDamageScenario(report.scenario)}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Godown</dt>
                  <dd>{report.godown_name}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Reporter</dt>
                  <dd>{report.reporter_name ?? "—"}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Created</dt>
                  <dd>{formatTimestamp(report.created_at)}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Updated</dt>
                  <dd>{formatTimestamp(report.updated_at)}</dd>
                </div>
                {report.scenario === "shop_return" ? (
                  <div>
                    <dt className="text-muted-foreground">Shop</dt>
                    <dd>
                      {report.shop_name ?? report.shop_id?.slice(0, 8) ?? "—"}
                    </dd>
                  </div>
                ) : null}
              </dl>
              <StatusBadge tone={damageStatusTone[report.status]}>
                {formatDamageStatus(report.status)}
              </StatusBadge>
            </div>
            {report.notes ? (
              <p className="mt-3 text-sm">{report.notes}</p>
            ) : null}
          </DetailSection>

          <DetailSection title="Source documents">
            <dl className="grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
              {report.receipt_id ? (
                <div>
                  <dt className="text-muted-foreground">Receipt</dt>
                  <dd className="font-mono text-xs">{report.receipt_id}</dd>
                </div>
              ) : null}
              {report.picking_request_id ? (
                <div>
                  <dt className="text-muted-foreground">Packing request</dt>
                  <dd className="font-mono text-xs">
                    {report.picking_request_id}
                  </dd>
                </div>
              ) : null}
              {report.dispatch_id ? (
                <div>
                  <dt className="text-muted-foreground">Dispatch</dt>
                  <dd className="font-mono text-xs">{report.dispatch_id}</dd>
                </div>
              ) : null}
              {report.order_id ? (
                <div>
                  <dt className="text-muted-foreground">Order</dt>
                  <dd className="font-mono text-xs">{report.order_id}</dd>
                </div>
              ) : null}
              {report.shop_id ? (
                <div>
                  <dt className="text-muted-foreground">Shop</dt>
                  <dd className="font-mono text-xs">{report.shop_id}</dd>
                </div>
              ) : null}
              {!report.receipt_id &&
              !report.picking_request_id &&
              !report.dispatch_id &&
              !report.order_id &&
              !report.shop_id ? (
                <p className="text-sm text-muted-foreground">
                  No source document links on this report.
                </p>
              ) : null}
            </dl>
          </DetailSection>

          {report.scenario === "shop_return" ? (
            <DamageCustodyPanel
              report={report}
              onConfirmed={() => void detail.refetch()}
            />
          ) : null}

          {access.canViewVerification ? (
            <DamageVerificationPanel
              report={report}
              onChanged={() => void detail.refetch()}
            />
          ) : null}

          <DetailSection title="Lifecycle">
            <DamageLifecycleTimeline report={report} />
          </DetailSection>

          <DetailSection title="Damage lines">
            {report.lines.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                No lines recorded.
              </p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b text-left text-muted-foreground">
                      <th className="py-2 pr-3">Product</th>
                      <th className="py-2 pr-3">Cases</th>
                      <th className="py-2 pr-3">Crate</th>
                      <th className="py-2 pr-3">Lot</th>
                      <th className="py-2 pr-3">Reason</th>
                      <th className="py-2 pr-3">Receipt line</th>
                    </tr>
                  </thead>
                  <tbody>
                    {report.lines.map((line) => (
                      <tr key={line.id} className="border-b last:border-0">
                        <td className="py-2 pr-3">
                          {line.product_sku} · {line.product_name}
                        </td>
                        <td className="py-2 pr-3">
                          {formatCases(line.quantity_cases)}
                        </td>
                        <td className="py-2 pr-3">{line.crate_code ?? "—"}</td>
                        <td className="py-2 pr-3 font-mono text-xs">
                          {line.lot_id ? line.lot_id.slice(0, 8) : "—"}
                        </td>
                        <td className="py-2 pr-3">{line.damage_reason}</td>
                        <td className="py-2 pr-3 font-mono text-xs">
                          {line.receipt_line_id
                            ? line.receipt_line_id.slice(0, 8)
                            : "—"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </DetailSection>

          <DetailSection title="Stock isolation">
            <DamageHoldsPanel
              report={report}
              onTransferred={() => void detail.refetch()}
            />
          </DetailSection>

          {access.canViewVerification ? (
            <DamageOrdinaryWriteoffPanel
              report={report}
              onPosted={() => void detail.refetch()}
            />
          ) : null}

          <DamageExceptionalRequestPanel
            report={report}
            onChanged={() => void detail.refetch()}
          />
          <DamageExceptionalReviewPanel
            report={report}
            onChanged={() => void detail.refetch()}
          />
          <DamageExceptionalExecutionPanel
            report={report}
            onPosted={() => void detail.refetch()}
          />

          <DetailSection title="Evidence">
            {report.status === "submitted" &&
            (report.reporter_user_id === userId || access.canVerify) ? (
              <DamageEvidenceUploader
                report={report}
                onUploaded={() => void detail.refetch()}
              />
            ) : (
              <DamageEvidencePanel evidence={report.evidence} />
            )}
          </DetailSection>

          {access.canViewVerification ? (
            <DetailSection title="Verification history">
              <DamageVerificationHistory report={report} />
            </DetailSection>
          ) : null}

          <DetailSection title="Activity">
            <DamageActivityTimeline events={report.events} />
          </DetailSection>
        </div>
      ) : null}
    </section>
  )
}
