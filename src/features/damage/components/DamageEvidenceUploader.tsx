import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DamageEvidencePanel } from "@/features/damage/components/DamageEvidencePanel"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import type { DamageReportDetail } from "@/lib/damage/api"
import { uploadDamagePhoto } from "@/lib/damage/api"
import {
  damagePhotoMaxBytes,
  isSupportedDamagePhotoMime,
} from "@/lib/damage/rules"

export function DamageEvidenceUploader({
  report,
  disabled,
  onUploaded,
}: {
  report: DamageReportDetail | null
  disabled?: boolean
  onUploaded: () => Promise<void> | void
}) {
  const [note, setNote] = useState("")
  const [pending, setPending] = useState<"uploading" | "finalizing" | null>(
    null,
  )
  const [error, setError] = useState<string | null>(null)
  const [selectedName, setSelectedName] = useState<string | null>(null)
  const unfinalized = (report?.evidence ?? []).filter((row) => !row.finalized)

  async function onFile(file: File | undefined) {
    if (!file || !report) return
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
    setPending("uploading")
    try {
      await uploadDamagePhoto(report.id, file, note, (status) =>
        setPending(status),
      )
      setNote("")
      setSelectedName(null)
      await onUploaded()
    } catch (caught) {
      setError(mapDamageMutationError(caught, "upload"))
    } finally {
      setPending(null)
    }
  }

  return (
    <section className="grid gap-3">
      <h2 className="text-sm font-semibold">Photo evidence</h2>
      <p className="text-xs text-muted-foreground">
        Photos upload to a private bucket. Finalization happens only after the
        trusted server check. A completed browser upload is not proof of
        ownership.
      </p>
      {report ? (
        <>
          <Label className="grid gap-2 text-sm font-medium">
            Photo note
            <Input
              value={note}
              disabled={disabled || pending !== null}
              onChange={(event) => setNote(event.target.value)}
            />
          </Label>
          <Label className="grid gap-2 text-sm font-medium">
            Select photo
            <Input
              type="file"
              accept="image/jpeg,image/png,image/webp"
              disabled={disabled || pending !== null}
              onChange={(event) => void onFile(event.target.files?.[0])}
            />
          </Label>
          {pending ? (
            <p className="text-sm text-muted-foreground">
              {pending === "uploading"
                ? "Uploading to private storage…"
                : "Verifying and finalizing evidence…"}
            </p>
          ) : null}
          {selectedName && pending ? (
            <p className="text-xs text-muted-foreground">{selectedName}</p>
          ) : null}
          {error ? (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          ) : null}
          {unfinalized.length > 0 ? (
            <div className="rounded-xl bg-muted/40 px-3 py-2 text-sm">
              <p>
                {unfinalized.length} photo
                {unfinalized.length === 1 ? "" : "s"} awaiting server
                finalization. They cannot be previewed until verified.
              </p>
              <Button
                type="button"
                variant="outline"
                className="mt-2"
                onClick={() => void onUploaded()}
              >
                Refresh evidence
              </Button>
            </div>
          ) : null}
          <DamageEvidencePanel evidence={report.evidence} />
        </>
      ) : (
        <p className="text-sm text-muted-foreground">
          Save a draft before attaching photographic evidence.
        </p>
      )}
    </section>
  )
}
