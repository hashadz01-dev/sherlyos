import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { isValidDecisionReason } from "@/lib/damage/rules"

/** Shared return/reject reason capture. Backend still requires a trimmed reason. */
export function DamageDecisionReasonDialog({
  title,
  description,
  confirmLabel,
  ariaLabel,
  open,
  busy,
  reason,
  onReasonChange,
  onOpenChange,
  onConfirm,
}: {
  title: string
  description: string
  confirmLabel: string
  ariaLabel: string
  open: boolean
  busy: boolean
  reason: string
  onReasonChange: (value: string) => void
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  const valid = isValidDecisionReason(reason)
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title={title}
      description={description}
      footer={
        <>
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() => onOpenChange(false)}
          >
            Cancel
          </Button>
          <Button
            type="button"
            disabled={busy || !valid}
            onClick={onConfirm}
            aria-label={ariaLabel}
          >
            {busy ? "Saving…" : confirmLabel}
          </Button>
        </>
      }
    >
      <label className="grid gap-2 text-sm font-medium">
        Reason
        <textarea
          className="min-h-24 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
          value={reason}
          onChange={(event) => onReasonChange(event.target.value)}
          maxLength={500}
          aria-label="Decision reason"
        />
      </label>
      {!valid ? (
        <p className="mt-2 text-sm text-destructive">
          Enter a reason between 1 and 500 characters.
        </p>
      ) : null}
    </AppModal>
  )
}
