import { useState } from "react"
import { Button } from "@/components/ui/button"
import {
  downloadReportCsv,
  exportOperationsReport,
} from "@/lib/reports/api"

export function ExportButton({
  reportKind,
  filters,
}: {
  reportKind: string
  filters: Record<string, unknown>
}) {
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  async function onExport() {
    setBusy(true)
    setMessage(null)
    try {
      const exportFilters = Object.fromEntries(
        Object.entries(filters).filter(([key]) => key !== "page" && key !== "page_size"),
      )
      const payload = await exportOperationsReport({
        report_kind: reportKind,
        ...exportFilters,
      })
      downloadReportCsv(`${reportKind}-utc.csv`, payload.csv)
      setMessage(
        payload.truncated
          ? `Exported ${payload.row_count} of ${payload.total_count} authorized rows.`
          : `Exported ${payload.row_count} rows.`,
      )
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Export failed")
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex flex-col items-end gap-1">
      <Button type="button" variant="outline" disabled={busy} onClick={() => void onExport()}>
        {busy ? "Exporting" : "Export CSV"}
      </Button>
      {message ? (
        <p role="status" className="text-xs text-muted-foreground">
          {message}
        </p>
      ) : null}
    </div>
  )
}
