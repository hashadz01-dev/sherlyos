import {
  formatCases,
  formatDamageScenario,
} from "@/features/damage/utils/labels"
import type { DraftLine } from "@/features/damage/utils/draft"
import { totalDraftCases } from "@/features/damage/utils/draft"
import type { SubmitBlocker } from "@/features/damage/utils/submit"
import type { DamageScenario } from "@/lib/damage/rules"

export function DamageSubmitReview({
  scenario,
  sourceLabel,
  lines,
  notes,
  evidenceCount,
  blockers,
}: {
  scenario: DamageScenario | ""
  sourceLabel: string
  lines: DraftLine[]
  notes: string
  evidenceCount: number
  blockers: SubmitBlocker[]
}) {
  return (
    <section className="grid gap-3 rounded-2xl bg-card p-4 ring-1 ring-border">
      <h2 className="text-sm font-semibold">Review before submit</h2>
      <dl className="grid gap-2 text-sm sm:grid-cols-2">
        <div>
          <dt className="text-muted-foreground">Scenario</dt>
          <dd>{scenario ? formatDamageScenario(scenario) : "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Source</dt>
          <dd>{sourceLabel || "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Lines</dt>
          <dd>{lines.length}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Total cases</dt>
          <dd>{formatCases(totalDraftCases(lines))}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Finalized evidence</dt>
          <dd>{evidenceCount}</dd>
        </div>
      </dl>
      {notes ? <p className="text-sm">{notes}</p> : null}
      <ul className="grid gap-1 text-sm">
        {lines.map((line) => (
          <li key={line.key}>
            {line.product_sku || "Product"} · {line.quantity_cases} cases
            {line.damage_reason ? ` · ${line.damage_reason}` : ""}
          </li>
        ))}
      </ul>
      {blockers.length > 0 ? (
        <ul className="grid gap-1 text-sm text-destructive" role="list">
          {blockers.map((blocker) => (
            <li key={`${blocker.code}-${blocker.message}`}>
              {blocker.message}
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-muted-foreground">
          Ready to submit through the trusted damage report RPC.
        </p>
      )}
    </section>
  )
}
