import type { CreditAdjustmentDetail } from "@/lib/invoices/api"
import { CREDIT_ADJUSTMENT_WATERMARK, formatInr } from "@/lib/invoices/rules"

function stamp(value: string | null | undefined) {
  if (!value) return "—"
  return value.replace("T", " ").slice(0, 19)
}

function dash(value: string | null | undefined) {
  const trimmed = value?.trim()
  return trimmed ? trimmed : "—"
}

export function CreditAdjustmentDocument({ row }: { row: CreditAdjustmentDetail }) {
  const taxReady = row.tax_preview_state === "tax_preview"

  return (
    <article className="credit-adjustment-print relative mx-auto max-w-[210mm] bg-white px-[12mm] py-[10mm] text-black">
      <div
        aria-hidden="true"
        className="credit-adjustment-watermark pointer-events-none absolute inset-0 flex items-center justify-center"
      >
        <p className="rotate-[-24deg] text-center text-2xl font-semibold tracking-widest text-red-500/25 uppercase">
          {row.watermark || CREDIT_ADJUSTMENT_WATERMARK}
        </p>
      </div>

      <header className="relative mb-4 border-b border-black/20 pb-3">
        <p className="text-[10px] tracking-[0.18em] text-neutral-600 uppercase">
          Internal financial adjustment
        </p>
        <h1 className="mt-1 text-xl font-semibold">{dash(row.shop_name)}</h1>
        <p className="mt-2 text-xs font-semibold text-red-800">
          {row.watermark || CREDIT_ADJUSTMENT_WATERMARK}
        </p>
        <p className="text-xs font-medium text-red-800">NO LEGAL CREDIT NOTE NUMBER</p>
      </header>

      <dl className="relative mb-4 grid grid-cols-2 gap-x-6 gap-y-2 text-xs">
        <div>
          <dt className="text-neutral-600">Adjustment</dt>
          <dd className="font-medium">{row.adjustment_number}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Reviewed invoice note</dt>
          <dd>{dash(row.invoice_note_number)}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Original dispatch</dt>
          <dd>{dash(row.dispatch_number)}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Verified return</dt>
          <dd>
            {dash(row.return_number)} · {dash(row.return_status)}
          </dd>
        </div>
        <div>
          <dt className="text-neutral-600">Tax preview</dt>
          <dd>{dash(row.tax_preview_state)}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Snapshot</dt>
          <dd>{stamp(row.generated_at ?? row.created_at)}</dd>
        </div>
      </dl>

      <table className="relative mb-4 w-full border-collapse text-xs">
        <thead>
          <tr className="border-b border-black/30 text-left">
            <th className="py-1 pr-2">Product</th>
            <th className="py-1 pr-2">Returned cases</th>
            <th className="py-1 pr-2">Billed qty</th>
            <th className="py-1 pr-2">Unit price</th>
            <th className="py-1 pr-2">Subtotal</th>
            <th className="py-1 pr-2">Tax</th>
            <th className="py-1">Total</th>
          </tr>
        </thead>
        <tbody>
          {row.lines.map((line) => (
            <tr key={line.id ?? line.line_no} className="border-b border-black/10 align-top">
              <td className="max-w-[48mm] py-1 pr-2">
                <span className="font-medium">{dash(line.product_name)}</span>
                <span className="mt-0.5 block text-[10px] text-neutral-600">
                  {dash(line.product_sku)} · {dash(line.billing_unit)} ×{" "}
                  {String(line.billed_units_per_case)}
                </span>
              </td>
              <td className="py-1 pr-2">{line.credited_cases}</td>
              <td className="py-1 pr-2">{String(line.billed_quantity)}</td>
              <td className="py-1 pr-2">{formatInr(line.unit_amount)}</td>
              <td className="py-1 pr-2">{formatInr(line.line_subtotal)}</td>
              <td className="py-1 pr-2">{formatInr(line.tax_amount)}</td>
              <td className="py-1">{formatInr(line.line_total)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <dl className="relative mb-4 grid grid-cols-2 gap-x-6 gap-y-1 text-xs">
        <div>
          <dt className="text-neutral-600">Returned cases</dt>
          <dd>{row.credited_cases}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Returned billed quantity</dt>
          <dd>{String(row.credited_quantity)}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Adjustment subtotal</dt>
          <dd>{formatInr(row.subtotal_amount)}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Preview CGST</dt>
          <dd>{taxReady ? formatInr(row.cgst_amount) : "blocked"}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Preview SGST</dt>
          <dd>{taxReady ? formatInr(row.sgst_amount) : "blocked"}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Preview IGST</dt>
          <dd>{taxReady ? formatInr(row.igst_amount) : "blocked"}</dd>
        </div>
        <div>
          <dt className="text-neutral-600">Preview adjustment total</dt>
          <dd className="font-semibold">{formatInr(row.adjustment_total)}</dd>
        </div>
      </dl>

      {(row.blockers ?? []).length > 0 ? (
        <section className="relative mb-3">
          <h2 className="text-xs font-semibold">Structured blockers</h2>
          <ul className="mt-1 list-disc space-y-1 pl-4 text-xs">
            {row.blockers.map((blocker) => (
              <li key={blocker.code}>{blocker.message}</li>
            ))}
          </ul>
        </section>
      ) : null}

      {!taxReady ? (
        <p role="status" className="relative text-xs font-medium text-amber-900">
          Tax components are not invented. Original tax-preview data is {row.tax_preview_state.replaceAll("_", " ")}.
        </p>
      ) : null}
    </article>
  )
}
