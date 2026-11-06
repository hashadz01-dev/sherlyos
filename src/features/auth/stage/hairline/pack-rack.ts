// The kernel is untyped. This file is the drawing the look tool already checked.
// @ts-nocheck
import { HL } from "./kernel"
import { create, type FigureContext, type FigureOptions } from "./create"

/**
 * Godown rack: two posts, a top beam, a shelf of three open crates, a packing table.
 * The carton under the pointer slides forward and down onto the table. A dashed
 * footprint stays on the crate, so the slot is reserved rather than emptied.
 * The hanging tag carries the letter A as three strokes, the one letter allowed.
 * The slider is how far that carton travels.
 */
const {
  Cam,
  facing,
  fit,
  proj,
  rings,
  prism,
  put,
  solid,
  open,
  ringAt,
  poly,
  tdone,
  tset,
  tval,
  tween,
  disposer,
  mk,
  pointer,
  register,
} = HL

const XS = [-30, 0, 30]
const CW = 24,
  CD = 16,
  CH = 8,
  BW = 14,
  BD = 11,
  BH = 9
const SHELF = 16

function mount({ stage, svg, read }: FigureContext, travel: number) {
  const bag = disposer()
  const C = Cam(45, 0.5, 2.15)
  fit(
    C,
    [
      [-52, -22, 0],
      [64, 58, 0],
      [-52, -22, 54],
      [64, 58, SHELF + 4],
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

  slab(g, -46, -8, -38, 6, 0, 50, 1.1)
  slab(g, 46, -8, 54, 6, 0, 50, 1.1)
  slab(g, -46, -6, 54, 2, 46, 50, 1.2)
  slab(g, -42, -4, 50, 12, SHELF - 2.2, SHELF, 1.2)
  const crates = XS.map((x) =>
    slab(g, x, -1, x + CW, -1 + CD, SHELF, SHELF + CH, 1.4),
  )
  const ghosts = XS.map(() => mk("path", { class: "nf dash" }, g))
  slab(g, -18, 30, 48, 52, 0, 7, 1.8)
  const cartons = XS.map(() => ({ s: solid(g), y: tween(0), z: tween(0) }))
  const tag = slab(g, -44, 4, -34, 9, 28, 44, 0.7)
  const glyph = mk("path", { class: "nf" }, g)
  glyph.setAttribute(
    "d",
    (() => {
      const p = (dx, dz) => P(-39 + dx, 9, 30.5 + dz)
      return (
        open([p(0.4, 0), p(4.2, 10)]) +
        open([p(8, 0), p(4.2, 10)]) +
        open([p(2.1, 4), p(6.3, 4)])
      )
    })(),
  )

  function drawCarton(i, slide, drop) {
    const x = XS[i] + 5,
      y = 1 + slide,
      z = SHELF + 1.2 + drop
    const [ring, inner] = rings(x, y, x + BW, y + BD, 1.1, 0.45)
    put(cartons[i].s, prism(P, front, ring, inner, z, z + BH))
    const home = rings(x, 1, x + BW, 1 + BD, 1.1, 0.45)[0]
    ghosts[i].setAttribute("d", poly(ringAt(P, home, SHELF + CH + 0.2)))
  }

  const centers = XS.map((x) => P(x + CW / 2, 7, SHELF + CH + 1))
  function hit([sx, sy]) {
    let best = -1,
      bd = 56 * 56
    centers.forEach((c, i) => {
      const d = (sx - c[0]) ** 2 + (sy - c[1]) ** 2
      if (d < bd) {
        bd = d
        best = i
      }
    })
    return best
  }

  let prev = ""
  const B = register(stage, (_dt, now) => {
    const pose = cartons.map((c) => [tval(c.y, now), tval(c.z, now)])
    const key = pose.map((q) => q.map((n) => n.toFixed(2)).join(",")).join(";")
    const moving = cartons.some((c) => !tdone(c.y, now) || !tdone(c.z, now))
    if (key === prev) return moving
    prev = key
    pose.forEach(([slide, drop], i) => drawCarton(i, slide, drop))
    return moving
  })
  bag.add(B.unregister)

  let act = -1
  function setActive(a) {
    if (a === act) return
    const now = performance.now(),
      from = a >= 0 ? a : act
    act = a
    cartons.forEach((c, i) => {
      const dist = Math.abs(i - (from < 0 ? 0 : from))
      const chosen = a === i
      const near = a >= 0 && dist === 1
      tset(c.y, chosen ? travel : near ? travel * 0.1 : 0, now, dist * 42)
      tset(c.z, chosen ? -10 : 0, now, dist * 42 + (chosen ? 80 : 0))
      c.s.sil.classList.toggle("hi", a < 0 ? i === 1 : chosen)
    })
    const rest = a < 0
    tag.sil.classList.toggle("hi", rest)
    glyph.classList.toggle("hi", rest)
    crates.forEach((cr) => cr.sil.classList.remove("hi"))
    read.textContent = rest ? "rest" : "bay " + (a + 1)
    B.wake()
  }
  tag.sil.classList.add("hi")
  glyph.classList.add("hi")
  read.textContent = "rest"
  bag.add(
    pointer(stage, {
      move: (p) => setActive(hit(p)),
      leave: () => setActive(-1),
    }),
  )
  bag.add(() => svg.replaceChildren())
  return {
    set: (v) => {
      travel = v
    },
    destroy: bag.dispose,
  }
}

const spec = {
  name: "pack-rack",
  means:
    "A rack of crates: the carton under the pointer slides onto the table, and its slot stays outlined.",
  rules: [1, 2, 5, 6],
  range: [18, 30, 44],
  tour: [[160, 180], [224, 167], [290, 185], null],
  mount,
}

export function packRack(el: HTMLElement, options?: FigureOptions) {
  return create(spec, el, options)
}
