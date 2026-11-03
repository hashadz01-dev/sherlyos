import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { Eye, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { damagePhotoPreview } from "@/lib/damage/api"

export type DamageViewablePhoto = {
  id: string
  label: string
  caption?: string | null
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

function PhotoFrame({
  photo,
  alt,
  className,
  onActivate,
}: {
  photo: DamageViewablePhoto
  alt: string
  className?: string
  onActivate?: () => void
}) {
  const [expired, setExpired] = useState(false)
  const signed = useSignedPhoto(photo.evidenceId, !photo.src)
  const src = photo.src ?? (!expired ? signed.data : undefined)

  if (!photo.src && signed.isLoading) {
    return (
      <div
        className="min-h-12 w-full rounded-xl bg-muted"
        aria-busy="true"
        aria-label="Loading photo"
      />
    )
  }
  if (!src) {
    return (
      <div className="grid gap-2">
        <p role="alert" className="text-sm text-destructive">
          {expired ? "Signed preview expired." : signed.error?.message}
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

  const image = (
    <img
      src={src}
      alt={alt}
      className={className}
      onError={() => {
        if (!photo.src) setExpired(true)
      }}
    />
  )
  if (!onActivate) return image
  return (
    <button
      type="button"
      className="block w-full rounded-xl text-left"
      onClick={onActivate}
    >
      {image}
    </button>
  )
}

/**
 * Compact thumbnail + View (N) gallery, matching the receipt photo viewer.
 * Signed URLs stay in img src only and are not logged.
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
  const [open, setOpen] = useState(false)
  const [focused, setFocused] = useState<number | null>(null)
  if (photos.length === 0) return null

  const extra = photos.length - 1
  const focusedPhoto = focused !== null ? photos[focused] : null
  const canRemove = Boolean(onRemove)

  async function removePhoto(photo: DamageViewablePhoto) {
    if (!onRemove) return
    await onRemove(photo)
    setFocused(null)
    if (photos.length <= 1) setOpen(false)
  }

  return (
    <div className="flex flex-wrap items-center gap-3">
      <div className="relative size-14 shrink-0 overflow-hidden rounded-lg ring-1 ring-border">
        <PhotoFrame
          photo={photos[0]}
          alt={photos[0].label}
          className="size-full object-cover"
        />
        {extra > 0 ? (
          <span className="absolute top-1 right-1 rounded-full bg-emerald-500 px-1.5 text-[10px] font-semibold text-white">
            +{extra}
          </span>
        ) : null}
      </div>
      <Button
        type="button"
        variant="outline"
        onClick={() => {
          setFocused(null)
          setOpen(true)
        }}
      >
        <Eye />
        View ({photos.length})
      </Button>
      {canRemove && photos.length === 1 ? (
        <Button
          type="button"
          variant="outline"
          disabled={removingId === photos[0].id}
          onClick={() => void removePhoto(photos[0])}
        >
          <Trash2 />
          {removingId === photos[0].id ? "Deleting…" : "Delete image"}
        </Button>
      ) : null}

      <Dialog
        open={open}
        onOpenChange={(next) => {
          setOpen(next)
          if (!next) setFocused(null)
        }}
      >
        <DialogContent className="sm:max-w-4xl">
          <DialogHeader>
            <DialogTitle>
              {focusedPhoto
                ? "Photo view"
                : `Photos (${photos.length})`}
            </DialogTitle>
            <DialogDescription>
              {focusedPhoto
                ? focusedPhoto.caption || focusedPhoto.label
                : "Open a photo to view it larger."}
            </DialogDescription>
          </DialogHeader>
          {focusedPhoto ? (
            <div className="grid gap-3">
              <PhotoFrame
                photo={focusedPhoto}
                alt={focusedPhoto.label}
                className="max-h-[70vh] w-full rounded-xl object-contain"
              />
              <div className="flex flex-wrap gap-2">
                {photos.length > 1 ? (
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => setFocused(null)}
                  >
                    Back to photos
                  </Button>
                ) : null}
                {canRemove ? (
                  <Button
                    type="button"
                    variant="outline"
                    disabled={removingId === focusedPhoto.id}
                    onClick={() => void removePhoto(focusedPhoto)}
                  >
                    <Trash2 />
                    {removingId === focusedPhoto.id
                      ? "Deleting…"
                      : "Delete image"}
                  </Button>
                ) : null}
              </div>
            </div>
          ) : (
            <ul className="grid gap-4 sm:grid-cols-2">
              {photos.map((photo, index) => (
                <li key={photo.id} className="grid gap-2">
                  <PhotoFrame
                    photo={photo}
                    alt={photo.label}
                    className="max-h-80 w-full rounded-xl object-contain ring-1 ring-border"
                    onActivate={() => setFocused(index)}
                  />
                  <div className="flex flex-wrap items-center justify-center gap-2">
                    <p className="text-center text-sm text-muted-foreground">
                      {photo.label}
                      {photo.caption ? ` · ${photo.caption}` : ""}
                    </p>
                    {canRemove ? (
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        disabled={removingId === photo.id}
                        onClick={() => void removePhoto(photo)}
                      >
                        <Trash2 />
                        {removingId === photo.id ? "Deleting…" : "Delete"}
                      </Button>
                    ) : null}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </DialogContent>
      </Dialog>
    </div>
  )
}
