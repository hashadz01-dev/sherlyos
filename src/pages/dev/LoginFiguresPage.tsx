import type { CSSProperties, ComponentType } from "react"
import {
  DeliveryVan,
  DispatchBay,
  InvoiceNote,
  OrderDesk,
  PackRack,
  VerifyLedger,
} from "@/features/auth/stage/hairline/react"

/**
 * Review gallery for the six custom login figures. Dev only.
 * The live sign-in film still uses the stock Hairline figures.
 */
const PLATE = {
  "--hairline-plate": "#0e1c33",
  "--hairline-hi": "#e8eef6",
  "--hairline-edge": "#a9b8c9",
  "--hairline-mid": "#7b8da3",
  "--hairline-lo": "#415066",
} as CSSProperties

const FIGURES: {
  title: string
  label: string
  Figure: ComponentType<{ play?: boolean; theme?: "dark"; label?: string }>
}[] = [
  {
    title: "1 Order",
    label: "A tray of order slips on a counter",
    Figure: OrderDesk,
  },
  {
    title: "2 Verify",
    label: "An accounts ledger and a stamp press",
    Figure: VerifyLedger,
  },
  {
    title: "3 Pack",
    label: "A godown rack of crates tagged A",
    Figure: PackRack,
  },
  {
    title: "4 Dispatch",
    label: "A roller conveyor into a box truck",
    Figure: DispatchBay,
  },
  {
    title: "5 Invoice note",
    label: "A draft note beside a counting gate",
    Figure: InvoiceNote,
  },
  {
    title: "6 Deliver",
    label: "A box van on the road to a shop",
    Figure: DeliveryVan,
  },
]

export default function LoginFiguresPage() {
  return (
    <main className="min-h-screen bg-[#0e1c33] px-6 py-10 text-[#e8eef6]">
      <div className="mx-auto flex max-w-6xl flex-col gap-10">
        <header>
          <h1 className="text-2xl font-semibold">Login figures</h1>
          <p className="mt-2 max-w-2xl text-sm text-[#a9b8c9]">
            The six stations for the sign-in film, on the login navy, each
            playing. They are not wired into the live film yet.
          </p>
        </header>
        <div className="grid grid-cols-1 gap-12 lg:grid-cols-2">
          {FIGURES.map(({ title, label, Figure }) => (
            <figure key={title} className="flex flex-col gap-3">
              <figcaption className="text-sm font-medium tracking-wide">
                {title}
              </figcaption>
              <div style={PLATE} className="w-full">
                <Figure play theme="dark" label={label} />
              </div>
            </figure>
          ))}
        </div>
      </div>
    </main>
  )
}
