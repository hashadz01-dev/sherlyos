import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { formatTimestamp } from "@/features/damage/utils/labels"
import { damagePhotoPreview } from "@/lib/damage/api"

export type DamageViewablePhoto = {
  id: string
  label: string
  caption?: string | null
  uploadedAt?: string | null
  finalized?: boolean
  /** Local object URL. When set, the signed Storage preview is not fetched. */
  src?: string
  /** Finalized evidence id used to mint a short-lived signed URL. */
  evidenceId?: string
}

function useSignedPhoto(evidenceId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: ["damage-photo", evidenceId],
    queryFn: () => damagePhotoPreview(evidenceId!),
    enabled: enabled && Boolean(evidenceId),
    staleTime: 45_000,
    retry: 1,
  })
}

function PhotoImage({
  photo,
  alt,
  className,
  active,
}: {
  photo: DamageViewablePhoto
  alt: string
  className?: string
  /** Signed URLs are minted only after Preview, not for every row. */
  active: boolean
}) {
  const [expired, setExpired] = useState(false)
  const signed = useSignedPhoto(photo.evidenceId, active && !photo.src)
  const src = photo.src ?? (!expired ? signed.data : undefined)

  if (active && !photo.src && signed.isLoading) {
    return (
      <div
        className="min-h-16 w-full rounded-lg bg-muted"
        aria-busy="true"
        aria-label="Loading photo"
      />
    )
  }
  if (!src) {
    return (
      <div className="grid gap-2">
        <p role="alert" className="text-sm text-destructive">
          {expired
            ? "Signed preview expired."
            : (signed.error?.message ?? "Preview is not available.")}
        </p>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => {
            setExpired(false)
            void signed.refetch()
          }}
        >
          Refresh preview
        </Button>
      </div>
    )
  }

  return (
    <img
      src={src}
      alt={alt}
      className={className}
      onError={() => {
        if (!photo.src) setExpired(true)
      }}
    />
  )
}

/**
 * Same attach result as stock verification: a wrapping status line, Preview,
 * and the image under the list. Signed URLs stay in img src only.
 */
export function DamageEvidenceViewer({
  photos,
  onRemove,
  removingId,
}: {
  photos: DamageViewablePhoto[]
  /** Present on editable drafts so a wrong attach can be replaced. */
  onRemove?: (photo: DamageViewablePhoto) => void | Promise<void>
  removingId?: string | null
}) {
  const [previewId, setPreviewId] = useState<string | null>(null)
  if (photos.length === 0) return null

  const preview = photos.find((photo) => photo.id === previewId) ?? null

  return (
    <div className="grid min-w-0 gap-3">
      <ul className="grid min-w-0 gap-2">
        {photos.map((photo) => {
          const status = photo.finalized === false ? "Not finalized" : "Verified"
          const when = photo.uploadedAt ? formatTimestamp(photo.uploadedAt) : null
          const detail = [status, when, photo.caption || photo.label]
            .filter(Boolean)
            .join(" · ")
          return (
            <li
              key={photo.id}
              className="flex min-w-0 flex-wrap items-center justify-between gap-2"
            >
              <span className="min-w-0 break-words">{detail}</span>
              <span className="flex shrink-0 gap-2">
                <Button
                  type="button"
                  variant="outline"
                  onClick={() =>
                    setPreviewId((current) =>
                      current === photo.id ? null : photo.id,
                    )
                  }
                >
                  Preview
                </Button>
                {onRemove ? (
                  <Button
                    type="button"
                    variant="outline"
                    disabled={removingId === photo.id}
                    onClick={() => void onRemove(photo)}
                  >
                    {removingId === photo.id ? "Deleting…" : "Delete image"}
                  </Button>
                ) : null}
              </span>
            </li>
          )
        })}
      </ul>
      {preview ? (
        <PhotoImage
          photo={preview}
          alt={preview.label}
          active
          className="max-h-64 w-full rounded-lg object-contain"
        />
      ) : null}
    </div>
  )
}
