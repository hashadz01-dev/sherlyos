import type { DamageDecisionBlocker } from "@/lib/damage/rules"

/** Persisted blockers only. Status alone is never treated as eligibility. */
export function DamageVerificationEligibility({
  blockers,
  emptyLabel,
}: {
  blockers: DamageDecisionBlocker[]
  emptyLabel: string
}) {
  if (blockers.length === 0) {
    return <p className="text-sm text-muted-foreground">{emptyLabel}</p>
  }
  return (
    <ul className="grid gap-1 text-sm text-destructive" role="list">
      {blockers.map((blocker) => (
        <li key={blocker.code}>{blocker.message}</li>
      ))}
    </ul>
  )
}
