import { DamageEvidenceViewer } from "@/features/damage/components/DamageEvidenceViewer"
import type { DamageReportDetail } from "@/lib/damage/api"

export type SessionDamagePhoto = {
  id: string
  url: string
  name: string
  /** Server evidence id after a successful finalize. */
  evidenceId?: string
}

/**
 * Finalized photos use signed Storage previews. Session files (just chosen in
 * this browser) use a local object URL so the operator can view immediately.
 */
export function DamageEvidencePanel({
  evidence,
  sessionPhotos = [],
  onRemove,
  removingId,
}: {
  evidence: DamageReportDetail["evidence"]
  sessionPhotos?: SessionDamagePhoto[]
  onRemove?: (photo: {
    id: string
    evidenceId?: string
    src?: string
  }) => void | Promise<void>
  removingId?: string | null
}) {
  const finalized = evidence.filter((row) => row.finalized)
  const pending = evidence.filter((row) => !row.finalized)
  const photos =
    finalized.length > 0
      ? finalized.map((row, index) => ({
          id: row.id,
          evidenceId: row.id,
          // Stable alt for browser UAT and screen readers after trusted finalize.
          label:
            index === 0
              ? "Finalized damage evidence"
              : `Finalized damage evidence ${index + 1}`,
          caption: row.note ?? null,
        }))
      : sessionPhotos.map((row, index) => ({
          id: row.id,
          evidenceId: row.evidenceId,
          src: row.url,
          label: `Photo ${index + 1}`,
          caption: row.name,
        }))

  if (photos.length === 0) {
    return (
      <div className="grid gap-2">
        <p className="text-sm text-muted-foreground">
          No finalized evidence is available for this report.
        </p>
        {pending.length > 0 ? (
          <p role="status" className="text-sm text-destructive">
            {pending.length} unfinalized photo
            {pending.length === 1 ? "" : "s"} cannot be treated as verified
            evidence.
          </p>
        ) : null}
      </div>
    )
  }

  return (
    <div className="grid gap-2">
      <DamageEvidenceViewer
        photos={photos}
        onRemove={onRemove}
        removingId={removingId}
      />
      {pending.length > 0 ? (
        <p role="status" className="text-sm text-muted-foreground">
          {pending.length} earlier upload
          {pending.length === 1 ? "" : "s"} did not finalize and are not in
          this viewer.
        </p>
      ) : null}
    </div>
  )
}
