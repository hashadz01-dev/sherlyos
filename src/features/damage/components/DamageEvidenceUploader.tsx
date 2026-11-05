import { useEffect, useRef, useState } from "react"
import { PhotoAttachFields } from "@/components/shared/PhotoAttachFields"
import { Button } from "@/components/ui/button"
import {
  DamageEvidencePanel,
  type SessionDamagePhoto,
} from "@/features/damage/components/DamageEvidencePanel"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import type { DamageReportDetail } from "@/lib/damage/api"
import { discardDamagePhoto, uploadDamagePhoto } from "@/lib/damage/api"
import {
  damagePhotoMaxBytes,
  isSupportedDamagePhotoMime,
} from "@/lib/damage/rules"

/**
 * Private-bucket photo attach for drafts and returned reports.
 * Bytes still go through create_damage_photo_upload + finalize RPC. Choosing a
 * file on an unsaved /damage/new form persists the draft first so the picker
 * is available before Save draft.
 */
export function DamageEvidenceUploader({
  report,
  disabled,
  onUploaded,
  ensureDraft,
}: {
  report: DamageReportDetail | null
  disabled?: boolean
  onUploaded: (reportId?: string) => Promise<void> | void
  /** Persist an unsaved form so create_damage_photo_upload has a report id. */
  ensureDraft?: () => Promise<DamageReportDetail | null>
}) {
  const [note, setNote] = useState("")
  const [pending, setPending] = useState<
    "saving" | "uploading" | "finalizing" | null
  >(null)
  const [error, setError] = useState<string | null>(null)
  const [sessionPhotos, setSessionPhotos] = useState<SessionDamagePhoto[]>([])
  const sessionPhotosRef = useRef<SessionDamagePhoto[]>([])
  const [removingId, setRemovingId] = useState<string | null>(null)
  const unfinalized = (report?.evidence ?? []).filter((row) => !row.finalized)
  const finalized = (report?.evidence ?? []).filter((row) => row.finalized)
  const verifiedCount = Math.max(finalized.length, sessionPhotos.length)
  const busy = disabled || pending !== null || removingId !== null

  useEffect(() => {
    sessionPhotosRef.current = sessionPhotos
  }, [sessionPhotos])

  useEffect(() => {
    return () => {
      for (const photo of sessionPhotosRef.current) {
        URL.revokeObjectURL(photo.url)
      }
    }
  }, [])

  async function onFile(file: File | undefined) {
    if (!file) return
    setError(null)
    if (!isSupportedDamagePhotoMime(file.type)) {
      setError("Use a JPEG, PNG, or WebP photo.")
      return
    }
    if (file.size > damagePhotoMaxBytes) {
      setError("Photo must be 10 MB or smaller.")
      return
    }
    try {
      let target = report
      if (!target) {
        if (!ensureDraft) {
          setError("Please save the damage report before attaching evidence.")
          return
        }
        setPending("saving")
        target = await ensureDraft()
        if (!target) {
          setError("Please save the damage report before attaching evidence.")
          return
        }
      }
      setPending("uploading")
      const evidenceId = await uploadDamagePhoto(
        target.id,
        file,
        note,
        (status) => setPending(status),
      )
      // Session preview is only for a verified upload. Unfinalized Storage
      // objects must not look like evidence before the RPC returns.
      const localUrl = URL.createObjectURL(file)
      setSessionPhotos((current) => [
        ...current,
        {
          id: evidenceId,
          evidenceId,
          url: localUrl,
          name: file.name,
          note: note.trim() || null,
        },
      ])
      setNote("")
      await onUploaded(target.id)
    } catch (caught) {
      setError(mapDamageMutationError(caught, "upload"))
    } finally {
      setPending(null)
    }
  }

  async function removePhoto(photo: {
    id: string
    evidenceId?: string
    src?: string
  }) {
    setError(null)
    setRemovingId(photo.id)
    try {
      const evidenceId = photo.evidenceId ?? photo.id
      // Prefer the trusted discard RPC when the catalog row exists.
      if (report || photo.evidenceId) {
        await discardDamagePhoto(evidenceId)
      }
      setSessionPhotos((current) => {
        const next = current.filter(
          (row) => row.id !== photo.id && row.evidenceId !== evidenceId,
        )
        const removed = current.find(
          (row) => row.id === photo.id || row.evidenceId === evidenceId,
        )
        if (removed) URL.revokeObjectURL(removed.url)
        return next
      })
      await onUploaded(report?.id)
    } catch (caught) {
      setError(mapDamageMutationError(caught, "upload"))
    } finally {
      setRemovingId(null)
    }
  }

  const pendingLabel =
    pending === "saving"
      ? "Saving the draft so this photo can be attached…"
      : pending === "uploading"
        ? "Uploading to private storage…"
        : pending === "finalizing"
          ? "Verifying and finalizing evidence…"
          : null

  return (
    <section className="grid min-w-0 gap-3 rounded-2xl bg-card p-4 text-sm ring-1 ring-border">
      <h2 className="font-medium">Photo evidence</h2>
      <p>
        {verifiedCount > 0
          ? "A verified photo is attached."
          : "At least one verified photo is required before this report can be submitted."}
      </p>
      <PhotoAttachFields
        note={note}
        onNoteChange={setNote}
        fileAriaLabel="Select photo"
        accept="image/jpeg,image/png,image/webp"
        disabled={busy}
        onFile={(file) => void onFile(file)}
      />
      <p className="text-muted-foreground">
        JPEG, PNG, or WebP up to 10 MB. The file is stored privately and must
        verify on the server before submit.
      </p>
      {pendingLabel ? (
        <p className="text-muted-foreground">{pendingLabel}</p>
      ) : null}
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
      {!report ? (
        <p className="text-muted-foreground">
          Choosing a photo saves this report as a draft first, then uploads the
          evidence.
        </p>
      ) : null}
      {unfinalized.length > 0 ? (
        <div className="rounded-xl bg-muted/40 px-3 py-2">
          <p>
            {unfinalized.length} earlier photo
            {unfinalized.length === 1 ? "" : "s"} did not finish verification
            and cannot be previewed. A new JPEG, PNG, or WebP attach is enough
            once it appears as finalized below.
          </p>
          <Button
            type="button"
            variant="outline"
            className="mt-2"
            onClick={() => void onUploaded(report?.id)}
          >
            Refresh evidence
          </Button>
        </div>
      ) : null}
      {report || sessionPhotos.length > 0 ? (
        <DamageEvidencePanel
          evidence={report?.evidence ?? []}
          sessionPhotos={sessionPhotos}
          onRemove={disabled ? undefined : (photo) => removePhoto(photo)}
          removingId={removingId}
        />
      ) : null}
    </section>
  )
}
