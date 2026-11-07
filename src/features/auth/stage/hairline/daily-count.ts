// The kernel is untyped. This file is the drawing the look tool already checked.
// @ts-nocheck
import { HL } from "./kernel"
import { create, type FigureContext, type FigureOptions } from "./create"

/**
 * Daily count: clipboard + counter in front of a crate row. Tally ticks step
 * along the crates; a mismatch raises a flag, then a supervisor stamp. No
 * cracked carton — that belongs to damage-mark.
 */
const {
  Cam, facing, fit, proj, rings, prism, put, solid, open, tdone, tset, tval,
  tween, disposer, mk, pointer, register,
} = HL

const XS = [-40, -14, 12, 38]
const TOP = 20

function mount({ stage, svg, read }: FigureContext, tickH: number) {
  const bag = disposer()
  const C = Cam(45, 0.5, 2.15)
  fit(C, [[-70, -30, 0], [76, 60, 0], [-70, -30, 46], [76, 60, 46]], 200, 168)
  const P = proj(C), front = facing(C)
  const g = mk("g", {}, svg)
  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent)
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.75)
    put(s, prism(P, front, ring, inner, z0, z1))
    return s
  }
  // Low shelf + crates — not a tall damage bay.
  slab(g, -54, -6, 58, 16, TOP - 2, TOP, 1.2)
  const crates = XS.map((x) => slab(g, x, 0, x + 18, 14, TOP, TOP + 9, 1.2))
  const board = slab(g, -66, 26, -30, 56, 0, 2.2, 1.3)
  const clip = slab(g, -54, 24, -42, 30, 2.2, 5, 0.9)
  mk("path", { class: "nf lo" }, g).setAttribute(
    "d",
    [34, 40, 46].map((y) => {
      const a = P(-60, y, 2.4), b = P(-36, y, 2.4)
      return `M${a[0]} ${a[1]}L${b[0]} ${b[1]}`
    }).join(""),
  )
  const counter = slab(g, 22, 28, 64, 54, 0, 9, 1.4)
  const dial = solid(g)
  {
    const [ring, inner] = rings(34, 34, 52, 48, 2, 0.8)
    put(dial, prism(P, front, ring, inner, 9, 10.5))
  }

  const ticks = XS.map(() => ({
    s: solid(g),
    mark: mk("path", { class: "nf" }, g),
    z: tween(0),
  }))
  const flag = solid(g)
  const pennant = mk("path", { class: "nf" }, g)
  const stamp = solid(g)
  const stampZ = tween(TOP + 24)
  const flagZ = tween(0)

  function drawTick(i, rise) {
    const x = XS[i] + 9, y = 4, z = TOP + 9.4
    if (rise < 0.3) {
      ticks[i].s.sil.setAttribute("d", "")
      ticks[i].s.cr.setAttribute("d", "")
      ticks[i].mark.setAttribute("d", "")
      return
    }
    const [ring, inner] = rings(x - 4, y, x + 4, y + 8, 1, 0.45)
    put(ticks[i].s, prism(P, front, ring, inner, z, z + rise))
    ticks[i].mark.setAttribute(
      "d",
      open([
        P(x - 2.6, y + 3.6, z + rise),
        P(x - 0.4, y + 1.4, z + rise),
        P(x + 3.2, y + 5.8, z + rise),
      ]),
    )
  }
  function drawFlag(rise) {
    if (rise < 0.15) {
      flag.sil.setAttribute("d", "")
      flag.cr.setAttribute("d", "")
      pennant.setAttribute("d", "")
      return
    }
    const x = XS[2] + 14
    const [ring, inner] = rings(x, 4, x + 2.2, 7, 0.4, 0.2)
    put(flag, prism(P, front, ring, inner, TOP + 9, TOP + 9 + rise * 14))
    pennant.setAttribute(
      "d",
      open([
        P(x + 2.2, 5, TOP + 9 + rise * 12),
        P(x + 10, 6.5, TOP + 9 + rise * 10),
        P(x + 2.2, 8, TOP + 9 + rise * 8),
      ]),
    )
  }
  function drawStamp(z) {
    const x = XS[2] + 4
    const [ring, inner] = rings(x, 2, x + 12, 12, 1.4, 0.55)
    put(stamp, prism(P, front, ring, inner, z, z + 4))
  }

  const centers = XS.map((x) => P(x + 9, 7, TOP + 0.4))
  function hit([sx]) {
    let best = -1, bd = 56 * 56
    centers.forEach((c, i) => {
      const d = (sx - c[0]) ** 2
      if (d < bd) {
        bd = d
        best = i
      }
    })
    return best
  }

  let act = -1, prev = ""
  const B = register(stage, (_dt, now) => {
    const rises = ticks.map((tk) => tval(tk.z, now))
    const fz = tval(flagZ, now), sz = tval(stampZ, now)
    const key = [...rises, fz, sz].map((n) => n.toFixed(2)).join(";")
    const moving =
      ticks.some((tk) => !tdone(tk.z, now)) ||
      !tdone(flagZ, now) ||
      !tdone(stampZ, now)
    if (key === prev) return moving
    prev = key
    rises.forEach((rise, i) => drawTick(i, rise))
    drawFlag(fz)
    drawStamp(sz)
    return moving
  })
  bag.add(B.unregister)

  function setActive(a) {
    if (a === act) return
    const now = performance.now()
    act = a
    ticks.forEach((tk, i) => {
      const on = a >= 0 && i <= a
      tset(tk.z, on ? tickH * (i === a ? 1 : 0.55) : 0, now, i * 45)
      tk.s.sil.classList.toggle("hi", i === a)
      tk.mark.classList.toggle("hi", i === a)
      crates[i].sil.classList.toggle("hi", i === a)
    })
    tset(flagZ, a === 2 ? 1 : 0, now, a === 2 ? 90 : 0)
    tset(stampZ, a === 2 ? TOP + 10 : TOP + 24, now, a === 2 ? 180 : 40)
    flag.sil.classList.toggle("hi", a === 2)
    pennant.classList.toggle("hi", a === 2)
    stamp.sil.classList.toggle("hi", a === 2)
    board.sil.classList.toggle("hi", a < 0)
    clip.sil.classList.toggle("hi", a < 0)
    counter.sil.classList.toggle("hi", a >= 0 && a !== 2)
    dial.sil.classList.toggle("hi", a >= 0 && a !== 2)
    read.textContent = a < 0 ? "rest" : a === 2 ? "gap" : "crate " + (a + 1)
    B.wake()
  }

  board.sil.classList.add("hi")
  clip.sil.classList.add("hi")
  read.textContent = "rest"
  bag.add(pointer(stage, { move: (p) => setActive(hit(p)), leave: () => setActive(-1) }))
  bag.add(() => svg.replaceChildren())
  return { set: (v) => { tickH = v }, destroy: bag.dispose }
}

const spec = {
  name: "daily-count",
  means:
    "A crate rack with a clipboard: the pointer tallies each crate, and a mismatch raises a flag then takes a supervisor stamp.",
  rules: [1, 2, 4, 8],
  range: [5, 10, 16],
  tour: [[120, 200], [175, 188], [230, 195], null],
  mount,
}

export function dailyCount(el: HTMLElement, options?: FigureOptions) {
  return create(spec, el, options)
}
