import { Link, useParams } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { getDeliveryNotePrint } from "@/lib/delivery-notes/api"

function formatStamp(value: string | null | undefined) {
  if (!value) return "—"
  return value.slice(0, 19).replace("T", " ")
}

export function DeliveryNotePrintPage() {
  const { noteId = "" } = useParams()
  const print = useQuery({
    queryKey: ["delivery-note-print", noteId],
    queryFn: () => getDeliveryNotePrint(noteId),
    enabled: noteId !== "",
  })

  const note = print.data?.delivery_note
  useDocumentTitle(note ? `Print ${note.delivery_note_number}` : "Print delivery note")

  return (
    <section className="dn-print min-w-0 bg-background px-4 py-6 text-foreground sm:px-8">
      <div className="mb-6 flex flex-wrap gap-3 print:hidden">
        <Button asChild variant="outline">
          <Link to={`/deliveries/${noteId}`}>Back</Link>
        </Button>
        {print.data?.print_ready ? (
          <Button type="button" onClick={() => window.print()}>
            Print
          </Button>
        ) : null}
      </div>

      {print.isLoading ? <LoadingBlock label="Loading print data" /> : null}
      {print.error ? (
        <p role="alert" className="text-sm text-destructive">
          {print.error.message}
        </p>
      ) : null}

      {print.data && note ? (
        <article className="mx-auto max-w-3xl">
          {!print.data.print_ready ? (
            <div
              role="alert"
              className="mb-6 rounded-2xl bg-destructive/10 p-4 text-sm text-destructive print:hidden"
            >
              Official printing is blocked until company identity is configured. Set
              `company.legal_name` and `company.registered_address` in application
              configuration. No placeholder company name is used.
            </div>
          ) : null}

          <header className="mb-8 border-b border-border pb-6">
            <p className="text-xs tracking-[0.2em] text-muted-foreground uppercase">
              Delivery note
            </p>
            {print.data.print_ready ? (
              <>
                <h1 className="mt-2 text-2xl font-semibold">{print.data.company.legal_name}</h1>
                <p className="mt-2 whitespace-pre-wrap text-sm text-muted-foreground">
                  {print.data.company.registered_address}
                </p>
                {print.data.company.tax_id ? (
                  <p className="mt-1 text-sm">Tax ID: {print.data.company.tax_id}</p>
                ) : null}
              </>
            ) : (
              <h1 className="mt-2 text-2xl font-semibold text-muted-foreground">
                Company identity not configured
              </h1>
            )}
          </header>

          <dl className="mb-8 grid gap-3 sm:grid-cols-2">
            <div>
              <dt className="text-sm text-muted-foreground">Delivery note</dt>
              <dd className="font-medium">{note.delivery_note_number}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Generated</dt>
              <dd>{formatStamp(note.generated_at)}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Order</dt>
              <dd>{print.data.order.order_number}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Godown</dt>
              <dd>
                {print.data.godown.name} ({print.data.godown.code})
              </dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Shop</dt>
              <dd>{print.data.shop.name}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Shop phone</dt>
              <dd>{print.data.shop.phone ?? "—"}</dd>
            </div>
            <div className="sm:col-span-2">
              <dt className="text-sm text-muted-foreground">Shop address</dt>
              <dd>{print.data.shop.address ?? "—"}</dd>
            </div>
          </dl>

          <table className="mb-8 w-full border-collapse text-sm">
            <thead>
              <tr className="border-b border-border text-left">
                <th className="py-2 pr-3 font-medium">SKU</th>
                <th className="py-2 pr-3 font-medium">Product</th>
                <th className="py-2 text-right font-medium">Cases</th>
              </tr>
            </thead>
            <tbody>
              {print.data.lines.map((line) => (
                <tr key={line.id} className="border-b border-border/70">
                  <td className="py-2 pr-3 align-top">{line.sku}</td>
                  <td className="py-2 pr-3 align-top">{line.product_name}</td>
                  <td className="py-2 text-right align-top">{line.requested_cases}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td className="pt-3 font-medium" colSpan={2}>
                  Total cases
                </td>
                <td className="pt-3 text-right font-medium">{print.data.total_cases}</td>
              </tr>
            </tfoot>
          </table>

          <dl className="grid gap-3 text-sm sm:grid-cols-2">
            <div>
              <dt className="text-muted-foreground">Created by</dt>
              <dd>
                {print.data.created_by_name ?? "—"} · {formatStamp(note.created_at)}
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Generated by</dt>
              <dd>
                {print.data.generated_by_name ?? "—"} · {formatStamp(note.generated_at)}
              </dd>
            </div>
          </dl>
        </article>
      ) : null}
    </section>
  )
}
