// The kernel is untyped. This file is the drawing the look tool already checked.
// @ts-nocheck
import { HL } from "./kernel"
import { create, type FigureContext, type FigureOptions } from "./create"

/**
 * A draft note: a sheet with a dashed border, beside a counting gate.
 * Cartons pass the gate and the sheet's rows fill one by one. No words,
 * so it cannot be read as a tax invoice. The slider is how long a filled row grows.
 */
const {
  Cam,
  clamp,
  facing,
  fit,
  proj,
  rings,
  prism,
  put,
  solid,
  ringAt,
  poly,
  unproj,
  spring,
  stepS,
  tdone,
  tset,
  tval,
  tween,
  disposer,
  mk,
  pointer,
  register,
} = HL

const ROWS = [6, 14, 22, 30]
const GATE = 18

function mount({ stage, svg, read }: FigureContext, span: number) {
  const bag = disposer()
  const C = Cam(45, 0.5, 2.05)
  fit(
    C,
    [
      [-78, -28, 0],
      [88, 52, 0],
      [-78, -28, 36],
      [88, 52, 36],
    ],
    200,
    168,
  )
  const P = proj(C),
    front = facing(C)
  const g = mk("g", {}, svg)

  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent)
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.75)
    put(s, prism(P, front, ring, inner, z0, z1))
    return s
  }

  const sheet = slab(g, -70, -8, -6, 44, 0, 1.6, 1.4)
  const dash = mk("path", { class: "nf dash" }, g)
  dash.setAttribute(
    "d",
    poly(ringAt(P, rings(-64, -2, -12, 38, 1.2, 0.4)[0], 1.7)),
  )
  const rules = mk("path", { class: "nf lo" }, g)
  rules.setAttribute(
    "d",
    ROWS.map((y) => {
      const a = P(-60, y, 1.75),
        b = P(-16, y, 1.75)
      return `M${a[0]} ${a[1]}L${b[0]} ${b[1]}`
    }).join(""),
  )
  const bars = ROWS.map(() => ({ s: solid(g), w: tween(0) }))

  const homes = [32, 48, 64, 80]
  const cartons = homes.map(() => solid(g))
  slab(g, GATE - 2, 6, GATE + 2, 28, 0, 24, 0.8)
  slab(g, GATE + 14, 6, GATE + 18, 28, 0, 24, 0.8)
  slab(g, GATE - 3, 8, GATE + 19, 14, 20, 24.5, 0.8)
  const pass = spring(0.12)

  function drawBar(i, w) {
    const y = ROWS[i]
    if (w < 1) {
      bars[i].s.sil.setAttribute("d", "")
      bars[i].s.cr.setAttribute("d", "")
      return
    }
    const [ring, inner] = rings(-58, y - 2.1, -58 + w, y + 2.1, 0.6, 0.3)
    put(bars[i].s, prism(P, front, ring, inner, 1.8, 3.4))
  }
  function drawCarton(i, along) {
    const x = homes[i] - along
    const [ring, inner] = rings(x, 12, x + 9, 22, 1, 0.4)
    put(cartons[i], prism(P, front, ring, inner, 0, 8))
  }

  let prev = "",
    filled = -1
  const B = register(stage, (dt, now) => {
    const moving = stepS(pass, dt) || bars.some((b) => !tdone(b.w, now))
    const key = [pass.x, ...bars.map((b) => tval(b.w, now))]
      .map((n) => n.toFixed(2))
      .join(";")
    if (key === prev) return moving
    prev = key
    const along = pass.x * (homes[3] - GATE + 10)
    homes.forEach((_, i) => drawCarton(i, along))
    const n = homes.filter((_, i) => homes[i] - along < GATE).length
    if (n !== filled) {
      filled = n
      bars.forEach((b, i) =>
        tset(b.w, i < n ? span : 0, now, Math.abs(i - Math.max(n - 1, 0)) * 36),
      )
      bars.forEach((b, i) =>
        b.s.sil.classList.toggle("hi", n > 0 && i === n - 1),
      )
      dash.classList.toggle("hi", n === 0)
      sheet.sil.classList.toggle("hi", n === 0)
    }
    bars.forEach((b, i) => drawBar(i, tval(b.w, now)))
    return moving
  })
  bag.add(B.unregister)
  sheet.sil.classList.add("hi")
  dash.classList.add("hi")

  function aim([sx, sy]) {
    const [x] = unproj(C, sx, sy, 4)
    pass.t = clamp((108 - x) / 100, 0, 1)
    const n = 1 + Math.round(pass.t * 3)
    read.textContent = "row " + n
    B.wake()
  }
  function leave() {
    pass.t = 0.15
    read.textContent = "rest"
    B.wake()
  }
  read.textContent = "rest"
  bag.add(pointer(stage, { move: aim, leave }))
  bag.add(() => svg.replaceChildren())
  return {
    set: (v) => {
      span = v
    },
    destroy: bag.dispose,
  }
}

const spec = {
  name: "invoice-note",
  means:
    "A dashed draft sheet beside a counting gate: each carton that passes fills the next row.",
  rules: [1, 3, 6, 8],
  range: [16, 30, 46],
  tour: [[250, 210], [199, 191], [140, 175], null],
  mount,
}

export function invoiceNote(el: HTMLElement, options?: FigureOptions) {
  return create(spec, el, options)
}
