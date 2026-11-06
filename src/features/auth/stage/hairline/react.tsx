import {
  forwardRef,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  type CSSProperties,
  type HTMLAttributes,
} from "react"
import type { FigureHandle, FigureOptions } from "./create"
import { deliveryVan } from "./delivery-van"
import { dispatchBay } from "./dispatch-bay"
import { invoiceNote } from "./invoice-note"
import { orderDesk } from "./order-desk"
import { packRack } from "./pack-rack"
import { verifyLedger } from "./verify-ledger"

const useIsoLayoutEffect =
  typeof window === "undefined" ? useEffect : useLayoutEffect

type Mount = (el: HTMLElement, options?: FigureOptions) => FigureHandle

type FigureProps = Omit<HTMLAttributes<HTMLDivElement>, "onChange"> &
  FigureOptions & {
    style?: CSSProperties
  }

/**
 * The package's React wrapper: the ref is the div, the figure is created
 * after layout, and update/destroy follow the option changes.
 */
function make(name: string, mount: Mount) {
  const Component = forwardRef<HTMLDivElement, FigureProps>(
    function Hairline(props, ref) {
      const { intensity, theme, label, onRead, play, style, ...attrs } = props
      const named = label ?? attrs["aria-label"]
      const el = useRef<HTMLDivElement | null>(null)
      const figure = useRef<FigureHandle | null>(null)
      const read = useRef(onRead)
      const set = useCallback(
        (node: HTMLDivElement | null) => {
          el.current = node
          if (typeof ref === "function") ref(node)
          else if (ref) (ref as { current: HTMLDivElement | null }).current = node
        },
        [ref],
      )
      useIsoLayoutEffect(() => {
        read.current = onRead
      })
      useIsoLayoutEffect(() => {
        const node = el.current
        if (!node) return
        const f = mount(node, {
          intensity,
          theme,
          label: typeof named === "string" ? named : undefined,
          play,
          onRead: (text) => read.current?.(text),
        })
        figure.current = f
        return () => {
          f.destroy()
          figure.current = null
        }
        // Mount once. Later option changes go through update, as the package does.
        // eslint-disable-next-line react-hooks/exhaustive-deps
      }, [])
      useIsoLayoutEffect(() => {
        figure.current?.update({
          intensity,
          theme,
          label: typeof named === "string" ? named : undefined,
          play,
        })
      }, [intensity, theme, named, play])
      return (
        <div {...attrs} ref={set} style={{ aspectRatio: "5 / 4", ...style }} />
      )
    },
  )
  Component.displayName = name
  return Component
}

export const OrderDesk = make("OrderDesk", orderDesk)
export const VerifyLedger = make("VerifyLedger", verifyLedger)
export const PackRack = make("PackRack", packRack)
export const DispatchBay = make("DispatchBay", dispatchBay)
export const InvoiceNote = make("InvoiceNote", invoiceNote)
export const DeliveryVan = make("DeliveryVan", deliveryVan)
