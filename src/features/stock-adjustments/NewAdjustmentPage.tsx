import { useMemo, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "react-router"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { createStockAdjustment, listAdjustmentCandidates } from "@/lib/adjustment/api"
import { reasonForQuantities } from "@/lib/adjustment/rules"

export function NewAdjustmentPage() {
  useDocumentTitle("New stock adjustment")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const candidates = useQuery({
    queryKey: ["adjustment-candidates"],
    queryFn: listAdjustmentCandidates,
  })
  const [verificationId, setVerificationId] = useState("")
  const [note, setNote] = useState("")
  const [selected, setSelected] = useState<string[]>([])
  const verification = candidates.data?.find((item) => item.verification_id === verificationId)
  const quantities = useMemo(
    () => (verification?.lines ?? []).filter((line) => selected.includes(line.line_id)).map((line) => line.variance_cases),
    [verification, selected],
  )
  const reason = reasonForQuantities(quantities)
  const create = useMutation({
    mutationFn: () => createStockAdjustment({
      verificationId,
      reasonCode: reason ?? "shortage",
      note,
      lineIds: selected,
      idempotencyKey: `adj-${crypto.randomUUID()}`,
    }),
    onSuccess: async (created) => {
      await queryClient.invalidateQueries({ queryKey: ["stock-adjustments"] })
      navigate(`/stock-adjustments/${created.id}`)
    },
  })

  return (
    <section className="min-w-0">
      <PageHeader title="New adjustment" description="Quantities come from the closed verification. A line cannot be posted for a different amount." />
      {candidates.error ? <p role="alert" className="text-sm text-destructive">{candidates.error.message}</p> : null}
      <form className="grid max-w-3xl gap-4" onSubmit={(event) => { event.preventDefault(); create.mutate() }}>
        <label className="grid gap-1 text-sm">
          Closed verification
          <select className="rounded-xl border bg-card px-3 py-2" value={verificationId} onChange={(event) => { setVerificationId(event.target.value); setSelected([]) }} required>
            <option value="">Select a verification</option>
            {(candidates.data ?? []).map((item) => (
              <option key={item.verification_id} value={item.verification_id}>
                {item.verification_number} · {item.godown_name}
              </option>
            ))}
          </select>
        </label>
        {verification ? (
          <fieldset className="grid gap-2">
            <legend className="text-sm">Discrepancy lines</legend>
            {verification.lines.map((line) => (
              <label key={line.line_id} className="rounded-2xl bg-card p-3 text-sm ring-1 ring-border">
                <span className="flex items-start gap-2">
                  <input
                    type="checkbox"
                    checked={selected.includes(line.line_id)}
                    onChange={(event) => setSelected((current) => event.target.checked ? [...current, line.line_id] : current.filter((id) => id !== line.line_id))}
                  />
                  <span>
                    <span className="font-medium">{line.sku}</span> in {line.crate_code}
                    <span className="mt-1 block text-muted-foreground">
                      Expected {line.expected_cases}, physical {line.physical_cases}, adjustment {line.variance_cases}
                    </span>
                  </span>
                </span>
              </label>
            ))}
            <p className="text-sm text-muted-foreground">Photo {verification.evidence_id} is the finalized verification evidence.</p>
          </fieldset>
        ) : null}
        <p className="text-sm">Reason code: {reason ?? "Select at least one line"}</p>
        <label className="grid gap-1 text-sm">
          Note
          <textarea className="min-h-24 rounded-xl border bg-card px-3 py-2" value={note} onChange={(event) => setNote(event.target.value)} required minLength={1} maxLength={500} />
        </label>
        {create.error ? <p role="alert" className="text-sm text-destructive">{create.error.message}</p> : null}
        <Button type="submit" disabled={create.isPending || !reason || note.trim() === ""}>Create draft</Button>
      </form>
    </section>
  )
}
