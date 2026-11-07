// The kernel is untyped. This file is the drawing the look tool already checked.
// @ts-nocheck
import { HL } from "./kernel"
import { create, type FigureContext, type FigureOptions } from "./create"

/**
 * Inbound bay: a supplier lorry at a dock, a counting table, a damaged corner
 * tray, and a short rack of crates. The pointer sweeps along the belt: cartons
 * roll onto the table, a few peel to the tray, and the rest slide into crates.
 * The slider is how far one sweep carries the line.
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
  poly,
  circ,
  unproj,
  spring,
  stepS,
  disposer,
  mk,
  pointer,
  register,
} = HL

const BED = 6

function mount({ stage, svg, read }: FigureContext, sweep: number) {
  const bag = disposer()
  const C = Cam(45, 0.5, 1.92)
  fit(
    C,
    [
      [-90, -40, 0],
      [100, 56, 0],
      [-90, -40, 42],
      [100, 56, 42],
    ],
    200,
    170,
  )
  const P = proj(C),
    front = facing(C)
  const g = mk("g", {}, svg)

  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent)
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.7)
    put(s, prism(P, front, ring, inner, z0, z1))
    return s
  }

  // Dock apron and rollers.
  slab(g, -8, -8, 70, 22, BED, BED + 2.8, 1.2)
  for (let i = 0; i < 6; i++) {
    const x = 4 + i * 10
    slab(g, x, -2, x + 6, 16, BED + 2.8, BED + 5.6, 2.8)
  }
  // Counting table.
  const table = slab(g, 18, 24, 58, 48, 0, 9, 1.4)
  // Damaged corner tray.
  const tray = slab(g, 62, 28, 86, 46, 0, 5, 1.1)
  // Crate rack at the far side.
  slab(g, -18, 30, -6, 50, 0, 28, 1)
  slab(g, 2, 30, 14, 50, 0, 28, 1)
  slab(g, -18, 32, 14, 48, 26, 30, 1)
  const crates = [-14, -2].map((x) =>
    slab(g, x, 34, x + 10, 46, 12, 22, 1.2),
  )

  // Lorry body backed to the bay (open rear toward the rollers).
  const lorry = slab(g, -82, -28, -20, 24, BED + 4, 34, 2)
  const opening = mk("path", { class: "nf lo" }, g)
  opening.setAttribute(
    "d",
    poly([
      P(-20, -10, BED + 8),
      P(-20, 14, BED + 8),
      P(-20, 14, 30),
      P(-20, -10, 30),
    ]),
  )
  ;[-68, -40].forEach((x) => {
    const w = mk("path", { class: "sil" }, g)
    w.setAttribute(
      "d",
      poly(circ(6, 16).map((q) => P(x + q.u, 26, 6 + q.v))),
    )
  })

  const homes = [64, 48, 32, 16]
  const cartons = homes.map(() => solid(g))
  const belt = spring(0.12)
  let prev = -1
  let lit = -1
  let hot = false

  function drawCarton(i, t) {
    const along = homes[i] - t * sweep
    // Last carton peels toward the damaged tray once past the table.
    const peel = i === 0 && along < 28 ? clamp((28 - along) / 18, 0, 1) : 0
    const x = along + peel * 22
    const y = -1 + peel * 30
    const z = BED + 5.6 + peel * 2
    const [ring, inner] = rings(x, y, x + 11, y + 10, 1.1, 0.45)
    put(cartons[i], prism(P, front, ring, inner, z, z + 9))
  }

  const B = register(stage, (dt) => {
    const moving = stepS(belt, dt)
    const q = Math.round(belt.x * 40)
    if (q !== prev) {
      prev = q
      homes.forEach((_, i) => drawCarton(i, belt.x))
      const on = homes.findIndex((h) => h - belt.x * sweep > 20)
      const idx = on < 0 ? 0 : on
      if (hot && idx !== lit) {
        lit = idx
        cartons.forEach((c, i) => c.sil.classList.toggle("hi", i === idx))
        table.sil.classList.toggle("hi", idx > 0)
        tray.sil.classList.toggle("hi", idx === 0 && belt.x > 0.45)
        crates.forEach((c) => c.sil.classList.remove("hi"))
        if (belt.x > 0.72) crates[idx % crates.length].sil.classList.add("hi")
      }
    }
    return moving
  })
  bag.add(B.unregister)
  lorry.sil.classList.add("hi")

  function aim([sx, sy]) {
    const [x] = unproj(C, sx, sy, BED)
    hot = true
    belt.t = clamp((70 - x) / 90, 0, 1)
    read.textContent = "bay " + (1 + Math.round(belt.t * 3))
    B.wake()
  }
  function leave() {
    hot = false
    belt.t = 0.14
    read.textContent = "rest"
    lorry.sil.classList.add("hi")
    table.sil.classList.remove("hi")
    tray.sil.classList.remove("hi")
    cartons.forEach((c) => c.sil.classList.remove("hi"))
    crates.forEach((c) => c.sil.classList.remove("hi"))
    lit = -1
    B.wake()
  }
  read.textContent = "rest"
  bag.add(pointer(stage, { move: aim, leave }))
  bag.add(() => svg.replaceChildren())
  return {
    set: (v) => {
      sweep = v
    },
    destroy: bag.dispose,
  }
}

const spec = {
  name: "stock-in",
  means:
    "An inbound lorry at a bay: the pointer rolls cartons onto a counting table, peels a few to a damage tray, and slides the rest into crates.",
  rules: [1, 3, 4, 8],
  range: [18, 36, 54],
  tour: [
    [260, 150],
    [210, 170],
    [160, 200],
    null,
  ],
  mount,
}

export function stockIn(el: HTMLElement, options?: FigureOptions) {
  return create(spec, el, options)
}
