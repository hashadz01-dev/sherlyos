import type { InvoiceNoteDetail } from "@/lib/invoices/api"
import {
  INVOICE_PREVIEW_WATERMARK,
  TAX_PREVIEW_WATERMARK,
  formatInr,
  isDriverHandoverCopy,
} from "@/lib/invoices/rules"

function stamp(value: string | null | undefined) {
  if (!value) return "—"
  return value.replace("T", " ").slice(0, 19)
}

function dash(value: string | null | undefined) {
  const trimmed = value?.trim()
  return trimmed ? trimmed : "—"
}

export function InvoiceHandoverDocument({ note }: { note: InvoiceNoteDetail }) {
  const driver = isDriverHandoverCopy(note.copy ?? "driver")
  const taxReady = note.financial_preview_state === "tax_preview"

  return (
    <article className="invoice-handover-print relative mx-auto max-w-[210mm] bg-white px-[12mm] py-[10mm] text-black">
      <div
        aria-hidden="true"
        className="invoice-handover-watermark pointer-events-none absolute inset-0 flex items-center justify-center"
      >
        <p className="rotate-[-24deg] text-center text-2xl font-semibold tracking-widest text-red-500/25 uppercase">
          {note.watermark || INVOICE_PREVIEW_WATERMARK}
        </p>
      </div>

      <header className="invoice-handover-header relative mb-4 border-b border-black/20 pb-3">
        <p className="text-[10px] tracking-[0.18em] text-neutral-600 uppercase">
          {note.copy_label}
        </p>
        <h1 className="mt-1 text-xl font-semibold">
          {driver
            ? dash(note.shop.name)
            : note.seller_identity?.available
              ? dash(note.seller_identity.legal_name)
              : "Verified seller identity unavailable"}
        </h1>
        <p className="mt-1 whitespace-pre-wrap text-xs text-neutral-700">
          {driver
            ? dash(note.shop.address)
            : note.seller_identity?.available
              ? dash(note.seller_identity.registered_address)
              : dash(note.seller_identity?.reason)}
        </p>
        {!driver && note.seller_identity?.available && note.seller_identity.gstin ? (
          <p className="mt-1 text-xs">GSTIN {note.seller_identity.gstin}</p>
        ) : null}
        <p className="mt-2 text-xs font-semibold text-red-800">
          {note.watermark || INVOICE_PREVIEW_WATERMARK}
        </p>
        <p className="text-xs font-medium text-red-800">
          {note.legal_seal_caption ?? "NO LEGAL SEAL — DRAFT PREVIEW ONLY"}
        </p>
        <p className="text-xs text-neutral-600">
          Legal invoice number: not allocated
        </p>
      </header>

      <dl className="relative mb-4 grid grid-cols-2 gap-x-6 gap-y-2 text-xs">
        <div>
          <dt className="text-neutral-600">Draft note</dt>
          <dd className="font-medium">{note.note_number}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Dispatch</dt>
          <dd>{dash(note.dispatch_number)}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Date of dispatch</dt>
          <dd>{dash(note.as_of_date ?? note.dispatch_confirmed_at?.slice(0, 10))}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">{driver ? "Delivery location" : "Shop"}</dt>
          <dd>{driver ? dash(note.shop.address) : dash(note.shop.name)}</dd>
        </div>
        {note.godown ? (
          <div>
            <dt className="text-neutral-600">Godown</dt>
            <dd>
              {note.godown.name} ({note.godown.code})
            </dd>
          </div>
        ) : null}
        {!driver ? (
          <div>
            <dt className="text-neutral-600">Financial review status</dt>
            <dd className="capitalize">{note.status}</dd>
          </div>
        ) : null}
        <div className="col-span-2">
          <dt className="text-neutral-600">Document generated</dt>
          <dd>{stamp(note.generated_at)}</dd>
        </div>
      </dl>

      {!driver ? (
        <section className="relative mb-4 text-xs">
          <h2 className="font-semibold">Customer</h2>
          {note.customer_identity?.available ? (
            <>
              <p>{dash(note.customer_identity.billing_name)}</p>
              <p className="whitespace-pre-wrap">{dash(note.customer_identity.billing_address)}</p>
              {note.customer_identity.gstin ? <p>GSTIN {note.customer_identity.gstin}</p> : null}
            </>
          ) : (
            <p className="text-amber-900">
              {dash(note.customer_identity?.reason)} Shop name on the note: {dash(note.shop.name)}.
            </p>
          )}
        </section>
      ) : null}

      <table className="relative mb-4 w-full border-collapse text-left text-xs">
        <thead>
          <tr className="border-b border-black/30">
            <th className="py-1.5 pr-2 font-medium">Product</th>
            {driver ? <th className="py-1.5 pr-2 font-medium">SKU</th> : <th className="py-1.5 pr-2 font-medium">HSN</th>}
            <th className="py-1.5 pr-2 font-medium">Cases</th>
            <th className="py-1.5 pr-2 font-medium">Billing units</th>
            {!driver ? (
              <>
                <th className="py-1.5 pr-2 font-medium">Unit price</th>
                <th className="py-1.5 pr-2 font-medium">Line amount</th>
                <th className="py-1.5 pr-2 font-medium">Taxable (preview)</th>
                <th className="py-1.5 pr-2 font-medium">Tax (preview)</th>
              </>
            ) : null}
          </tr>
        </thead>
        <tbody>
          {note.lines.map((line) => {
            const previewLine = note.tax_preview?.lines?.find(
              (row) => row.invoice_note_line_id === line.id,
            )
            return (
              <tr key={line.id} className="border-b border-black/10 align-top">
                <td className="max-w-[28mm] py-1.5 pr-2 break-words">{line.product_name}</td>
                <td className="py-1.5 pr-2">{driver ? line.product_sku : dash(line.hsn_sac_code)}</td>
                <td className="py-1.5 pr-2">{line.shipped_cases}</td>
                <td className="py-1.5 pr-2">
                  {String(line.billed_quantity)} {line.billing_unit}
                </td>
                {!driver ? (
                  <>
                    <td className="py-1.5 pr-2">{formatInr(line.unit_amount)}</td>
                    <td className="py-1.5 pr-2">{formatInr(line.line_amount)}</td>
                    <td className="py-1.5 pr-2">
                      {taxReady ? formatInr(previewLine?.taxable_value) : "—"}
                    </td>
                    <td className="py-1.5 pr-2">
                      {taxReady ? formatInr(previewLine?.tax_amount) : "—"}
                    </td>
                  </>
                ) : null}
              </tr>
            )
          })}
        </tbody>
      </table>

      {driver ? (
        <section className="relative mt-8 grid gap-8 text-xs sm:grid-cols-2">
          <p className="sm:col-span-2 text-neutral-700">
            {note.handover_acknowledgement?.note}
          </p>
          <div>
            <div className="h-12 border-b border-black/40" />
            <p className="mt-1">
              {note.handover_acknowledgement?.driver_signature_label}
            </p>
          </div>
          <div>
            <div className="h-12 border-b border-black/40" />
            <p className="mt-1">
              {note.handover_acknowledgement?.receiver_signature_label}
            </p>
          </div>
        </section>
      ) : (
        <section className="relative space-y-2 text-xs">
          <p className="font-semibold text-red-800">
            {note.tax_preview_watermark ?? TAX_PREVIEW_WATERMARK}
          </p>
          {note.financial_preview_state === "tax_stale" ? (
            <p role="status" className="text-amber-900">
              Tax preview is stale. Do not treat these figures as current. Totals are not invented.
            </p>
          ) : null}
          {note.financial_preview_state === "tax_unavailable" ? (
            <p role="status" className="text-amber-900">
              Tax preview unavailable. CGST/SGST/IGST are not displayed.
            </p>
          ) : null}
          {taxReady ? (
            <dl className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              <div>
                <dt className="text-neutral-600">Taxable (preview)</dt>
                <dd>{formatInr(note.tax_preview?.taxable_value)}</dd>
              </div>
              <div>
                <dt className="text-neutral-600">CGST (preview)</dt>
                <dd>{formatInr(note.tax_preview?.cgst_amount)}</dd>
              </div>
              <div>
                <dt className="text-neutral-600">SGST (preview)</dt>
                <dd>{formatInr(note.tax_preview?.sgst_amount)}</dd>
              </div>
              <div>
                <dt className="text-neutral-600">IGST (preview)</dt>
                <dd>{formatInr(note.tax_preview?.igst_amount)}</dd>
              </div>
              <div>
                <dt className="text-neutral-600">Tax (preview)</dt>
                <dd>{formatInr(note.tax_preview?.tax_amount)}</dd>
              </div>
              <div>
                <dt className="text-neutral-600">Preview total</dt>
                <dd>{formatInr(note.tax_preview?.invoice_total)}</dd>
              </div>
            </dl>
          ) : null}
          <p>Reviewed line snapshot total {formatInr(note.grand_total)}. Note tax_amount stays 0.</p>
          <p>
            Source snapshot {note.source?.invoice_note_id ?? note.id} v
            {note.source?.invoice_note_version ?? note.version}. Generated {stamp(note.generated_at)}.
          </p>
        </section>
      )}
    </article>
  )
}
