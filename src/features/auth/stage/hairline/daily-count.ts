// The kernel is untyped. This file is the drawing the look tool already checked.
// @ts-nocheck
import { HL } from "./kernel"
import { create, type FigureContext, type FigureOptions } from "./create"

/**
 * Daily count: crate rack, clipboard, tally ticks. One crate raises a mismatch
 * flag, then a supervisor stamp. The slider is how tall a tick rises.
 */
const {
  Cam, facing, fit, proj, rings, prism, put, solid, open, tdone, tset, tval,
  tween, disposer, mk, pointer, register,
} = HL

const XS = [-36, -12, 12, 36]
const TOP = 18

function mount({ stage, svg, read }: FigureContext, tickH: number) {
  const bag = disposer()
  const C = Cam(45, 0.5, 2.05)
  fit(C, [[-60, -28, 0], [72, 58, 0], [-60, -28, 48], [72, 58, 48]], 200, 168)
  const P = proj(C), front = facing(C)
  const g = mk("g", {}, svg)
  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent)
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.75)
    put(s, prism(P, front, ring, inner, z0, z1))
    return s
  }
  slab(g, -48, -10, -40, 8, 0, 44, 1.1)
  slab(g, 48, -10, 56, 8, 0, 44, 1.1)
  slab(g, -48, -8, 56, 4, 40, 44, 1.2)
  slab(g, -44, -4, 52, 14, TOP - 2, TOP, 1.2)
  const crates = XS.map((x) => slab(g, x, 0, x + 20, 14, TOP, TOP + 10, 1.3))
  const board = slab(g, -58, 28, -28, 50, 0, 2, 1.2)
  slab(g, -54, 32, -32, 46, 2, 2.8, 0.6)
  const counter = slab(g, 24, 30, 58, 50, 0, 8, 1.4)
  const ticks = XS.map(() => ({
    s: solid(g),
    mark: mk("path", { class: "nf" }, g),
    z: tween(0),
  }))
  const flag = solid(g)
  const stamp = solid(g)
  const stampZ = tween(TOP + 22)
  const flagZ = tween(0)

  function drawTick(i, rise) {
    const x = XS[i] + 10, y = 5, z = TOP + 10.2
    if (rise < 0.3) {
      ticks[i].s.sil.setAttribute("d", "")
      ticks[i].s.cr.setAttribute("d", "")
      ticks[i].mark.setAttribute("d", "")
      return
    }
    const [ring, inner] = rings(x - 4, y, x + 4, y + 7, 1, 0.4)
    put(ticks[i].s, prism(P, front, ring, inner, z, z + rise))
    ticks[i].mark.setAttribute(
      "d",
      open([
        P(x - 2.4, y + 3.4, z + rise),
        P(x - 0.5, y + 1.6, z + rise),
        P(x + 2.8, y + 5.4, z + rise),
      ]),
    )
  }
  function drawFlag(rise) {
    if (rise < 0.2) {
      flag.sil.setAttribute("d", "")
      flag.cr.setAttribute("d", "")
      return
    }
    const x = XS[2] + 16
    const [ring, inner] = rings(x, 2, x + 3, 8, 0.6, 0.3)
    put(flag, prism(P, front, ring, inner, TOP + 10, TOP + 10 + rise * 8))
  }
  function drawStamp(z) {
    const x = XS[2] + 6
    const [ring, inner] = rings(x, 3, x + 10, 11, 1.2, 0.5)
    put(stamp, prism(P, front, ring, inner, z, z + 3.5))
  }

  const centers = XS.map((x) => P(x + 10, 8, TOP + 0.4))
  function hit([sx]) {
    let best = -1, bd = 52 * 52
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
      const dist = Math.abs(i - (a < 0 ? 1 : a))
      tset(tk.z, a < 0 ? 0 : i === a ? tickH : dist === 1 ? tickH * 0.25 : 0, now, dist * 40)
      tk.s.sil.classList.toggle("hi", i === a)
      tk.mark.classList.toggle("hi", i === a)
      crates[i].sil.classList.toggle("hi", i === a)
    })
    tset(flagZ, a === 2 ? 1 : 0, now, a === 2 ? 80 : 0)
    tset(stampZ, a === 2 ? TOP + 11.5 : TOP + 22, now, a === 2 ? 160 : 40)
    flag.sil.classList.toggle("hi", a === 2)
    stamp.sil.classList.toggle("hi", a === 2)
    board.sil.classList.toggle("hi", a < 0)
    counter.sil.classList.toggle("hi", a >= 0 && a !== 2)
    read.textContent = a < 0 ? "rest" : a === 2 ? "gap" : "crate " + (a + 1)
    B.wake()
  }

  board.sil.classList.add("hi")
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
  range: [1.2, 2.6, 4.2],
  tour: [[120, 200], [175, 188], [230, 195], null],
  mount,
}

export function dailyCount(el: HTMLElement, options?: FigureOptions) {
  return create(spec, el, options)
}
