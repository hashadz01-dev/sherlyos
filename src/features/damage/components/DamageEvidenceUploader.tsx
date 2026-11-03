import { useEffect, useRef, useState } from "react"
import { ImagePlus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
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
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [note, setNote] = useState("")
  const [pending, setPending] = useState<
    "saving" | "uploading" | "finalizing" | null
  >(null)
  const [error, setError] = useState<string | null>(null)
  const [selectedName, setSelectedName] = useState<string | null>(null)
  const [sessionPhotos, setSessionPhotos] = useState<SessionDamagePhoto[]>([])
  const sessionPhotosRef = useRef<SessionDamagePhoto[]>([])
  sessionPhotosRef.current = sessionPhotos
  const [removingId, setRemovingId] = useState<string | null>(null)
  const unfinalized = (report?.evidence ?? []).filter((row) => !row.finalized)
  const busy = disabled || pending !== null || removingId !== null

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
    setSelectedName(file.name)
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
        },
      ])
      setNote("")
      setSelectedName(null)
      if (fileInputRef.current) {
        fileInputRef.current.value = ""
      }
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
    <section className="grid gap-3 rounded-2xl bg-card p-4 ring-1 ring-border">
      <h2 className="text-sm font-semibold">Photo evidence</h2>
      <p className="text-sm text-muted-foreground">
        Attach a JPEG, PNG, or WebP photo of the damaged cartons (up to 10 MB).
        The file is stored privately and must verify on the server before this
        report can be submitted. If an earlier attempt did not finalize, choose
        the photo again.
      </p>
      <Label className="grid gap-2 text-sm font-medium">
        Photo note
        <Input
          value={note}
          disabled={busy}
          onChange={(event) => setNote(event.target.value)}
        />
      </Label>
      {/*
        Keep the native file control out of layout. Windows Chrome ignores
        sr-only clipping on input[type=file] and stretches this card.
      */}
      <div className="grid gap-1.5">
        <span className="text-sm font-medium">Select photo</span>
        <div
          className={`relative overflow-hidden rounded-xl border border-dashed border-border bg-muted/40 ${
            busy ? "opacity-60" : ""
          }`}
        >
          <input
            ref={fileInputRef}
            aria-label="Select photo"
            type="file"
            accept="image/jpeg,image/png,image/webp"
            disabled={busy}
            className="absolute inset-0 z-10 h-full w-full cursor-pointer opacity-0 disabled:cursor-not-allowed"
            onChange={(event) => {
              const file = event.target.files?.[0]
              event.target.value = ""
              void onFile(file)
            }}
          />
          <div className="pointer-events-none flex items-center gap-3 px-3 py-3">
            <ImagePlus
              className="size-5 shrink-0 text-muted-foreground"
              aria-hidden="true"
            />
            <div className="min-w-0">
              <p className="text-sm font-medium">Add damaged photo</p>
              <p className="text-xs text-muted-foreground">
                {selectedName && pending
                  ? selectedName
                  : "Take a photo or choose a JPEG, PNG, or WebP file"}
              </p>
            </div>
          </div>
        </div>
      </div>
      {pendingLabel ? (
        <p className="text-sm text-muted-foreground">{pendingLabel}</p>
      ) : null}
      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
      {!report ? (
        <p className="text-sm text-muted-foreground">
          Choosing a photo saves this report as a draft first, then uploads the
          evidence.
        </p>
      ) : null}
      {unfinalized.length > 0 ? (
        <div className="rounded-xl bg-muted/40 px-3 py-2 text-sm">
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
