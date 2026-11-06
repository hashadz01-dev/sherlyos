import { HL } from "./kernel"

/**
 * What a figure's mount receives. `read` is the corner name, the same
 * object the bench writes, so a figure can keep setting `read.textContent`.
 */
export type FigureContext = {
  stage: HTMLElement
  svg: SVGSVGElement
  read: { textContent: string }
}

export type FigureSpec = {
  name: string
  means: string
  range: readonly [number, number, number]
  tour: ReadonlyArray<readonly [number, number] | null>
  mount: (
    ctx: FigureContext,
    value: number,
  ) => { set: (value: number) => void; destroy: () => void }
}

/** The public options, the same set the package's figures take. */
export type FigureOptions = {
  intensity?: number
  theme?: "auto" | "light" | "dark"
  label?: string
  play?: boolean
  onRead?: (text: string) => void
}

export type FigureHandle = {
  update: (next?: Partial<FigureOptions>) => void
  destroy: () => void
}

const NS = "http://www.w3.org/2000/svg"
const mounted = new WeakMap<HTMLElement, () => void>()

/**
 * Intensity is 0 to 1. The figure hears its own number, read on `range`
 * as two straight lines that meet at 0.5, which is how the package does it.
 */
function parameter(
  range: readonly [number, number, number],
  value: number | undefined,
) {
  const [lo, mid, hi] = range
  const n = typeof value === "number" && Number.isFinite(value) ? value : 0.5
  const i = Math.min(1, Math.max(0, n))
  const v =
    i <= 0.5
      ? lo + (i / 0.5) * (mid - lo)
      : mid + ((i - 0.5) / 0.5) * (hi - mid)
  return Math.round(v * 1e3) / 1e3
}

/**
 * Mounts one figure on an element and returns the package's handle.
 * The package does not export this builder, so the six login figures share it.
 */
export function create(
  spec: FigureSpec,
  el: HTMLElement,
  options: FigureOptions = {},
): FigureHandle {
  if (!el || el.nodeType !== 1) {
    throw new TypeError(
      `hairline: ${spec.name}() takes an element as its first argument.`,
    )
  }
  mounted.get(el)?.()
  const opts: FigureOptions = { ...options }
  const doc = el.ownerDocument
  const root = el.getRootNode()
  HL.inject(root.nodeType === 9 || "host" in root ? root : doc)

  const owned = new Set<string>()
  const attr = (name: string, value: string | null) => {
    if (!owned.has(name) && el.hasAttribute(name)) return
    if (value === null) {
      el.removeAttribute(name)
      owned.delete(name)
    } else {
      el.setAttribute(name, value)
      owned.add(name)
    }
  }
  const dress = () => {
    attr(
      "data-hairline-theme",
      opts.theme === "light" || opts.theme === "dark" ? opts.theme : null,
    )
    attr(
      "aria-label",
      el.hasAttribute("aria-labelledby") ? null : (opts.label ?? spec.means),
    )
  }
  attr("data-hairline", spec.name)
  attr("role", "img")
  dress()

  const svg = doc.createElementNS(NS, "svg")
  svg.setAttribute("viewBox", "0 0 400 320")
  svg.setAttribute("aria-hidden", "true")
  el.appendChild(svg)

  let text: string | null = null
  let playing: { stop: () => void } | null = null
  const read = {
    get textContent() {
      return text ?? ""
    },
    set textContent(value: string) {
      const next = value ?? ""
      if (next === text) return
      text = next
      try {
        opts.onRead?.(next)
      } catch (err) {
        setTimeout(() => {
          throw err
        })
      }
    },
  }

  let value = parameter(spec.range, opts.intensity)
  playing = opts.play === true ? HL.tour(el, spec.tour) : null
  const engine = spec.mount({ stage: el, svg, read }, value)
  if (text === null) read.textContent = "rest"

  let dead = false
  const destroy = () => {
    if (dead) return
    dead = true
    if (mounted.get(el) === destroy) mounted.delete(el)
    playing?.stop()
    playing = null
    engine.destroy()
    svg.remove()
    for (const name of owned) el.removeAttribute(name)
    owned.clear()
  }
  mounted.set(el, destroy)

  return {
    update(next) {
      if (dead || !next) return
      for (const key of Object.keys(next) as (keyof FigureOptions)[]) {
        const given = next[key]
        if (given === undefined) delete opts[key]
        else Object.assign(opts, { [key]: given })
      }
      const v = parameter(spec.range, opts.intensity)
      if (v !== value) {
        value = v
        engine.set(v)
      }
      const play = opts.play === true
      if (play !== !!playing) {
        playing?.stop()
        playing = play ? HL.tour(el, spec.tour) : null
      }
      dress()
    },
    destroy,
  }
}
