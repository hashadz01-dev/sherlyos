import { DamageVerificationEligibility } from "@/features/damage/components/DamageVerificationEligibility"
import type { DamageDecisionBlocker } from "@/lib/damage/rules"

/** Alias for exceptional eligibility. Same persisted-blocker contract. */
export function DamageDispositionEligibility({
  blockers,
  emptyLabel,
}: {
  blockers: DamageDecisionBlocker[]
  emptyLabel: string
}) {
  return (
    <DamageVerificationEligibility
      blockers={blockers}
      emptyLabel={emptyLabel}
    />
  )
}
