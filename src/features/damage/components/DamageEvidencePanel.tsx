import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { formatTimestamp } from "@/features/damage/utils/labels"
import { damagePhotoPreview, type DamageReportDetail } from "@/lib/damage/api"

function EvidencePreview({ evidenceId }: { evidenceId: string }) {
  const [expired, setExpired] = useState(false)
  const preview = useQuery({
    queryKey: ["damage-photo", evidenceId],
    queryFn: () => damagePhotoPreview(evidenceId),
    staleTime: 45_000,
    retry: 1,
  })

  if (preview.isLoading) {
    return <p className="text-sm text-muted-foreground">Loading evidence…</p>
  }
  if (preview.error || expired) {
    return (
      <div className="grid gap-2">
        <p role="alert" className="text-sm text-destructive">
          {expired ? "Signed preview expired." : preview.error?.message}
        </p>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => {
            setExpired(false)
            void preview.refetch()
          }}
        >
          Refresh preview
        </Button>
      </div>
    )
  }

  return (
    <img
      src={preview.data}
      alt="Finalized damage evidence"
      className="max-h-64 w-full rounded-xl object-contain ring-1 ring-border"
      onError={() => setExpired(true)}
    />
  )
}

export function DamageEvidencePanel({
  evidence,
}: {
  evidence: DamageReportDetail["evidence"]
}) {
  const finalized = evidence.filter((row) => row.finalized)

  if (finalized.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No finalized evidence is available for this report.
      </p>
    )
  }

  return (
    <ul className="grid gap-4 sm:grid-cols-2">
      {finalized.map((row) => (
        <li key={row.id} className="rounded-2xl bg-card p-3 ring-1 ring-border">
          <p className="mb-2 text-xs text-muted-foreground">
            Uploaded {formatTimestamp(row.uploaded_at)}
            {row.mime_type ? ` · ${row.mime_type}` : ""}
          </p>
          <EvidencePreview evidenceId={row.id} />
        </li>
      ))}
    </ul>
  )
}
