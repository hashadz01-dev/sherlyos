import { DamageDecisionReasonDialog } from "@/features/damage/components/DamageDecisionReasonDialog"

export function DamageExceptionalRejectionDialog({
  open,
  busy,
  reason,
  onReasonChange,
  onOpenChange,
  onConfirm,
}: {
  open: boolean
  busy: boolean
  reason: string
  onReasonChange: (value: string) => void
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  return (
    <DamageDecisionReasonDialog
      title="Reject exceptional disposition"
      description="Rejection does not post stock. Isolated quantity stays unavailable until a new authorized request."
      confirmLabel="Reject request"
      ariaLabel="Confirm exceptional rejection"
      open={open}
      busy={busy}
      reason={reason}
      onReasonChange={onReasonChange}
      onOpenChange={onOpenChange}
      onConfirm={onConfirm}
    />
  )
}
