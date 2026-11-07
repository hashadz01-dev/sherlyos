// The kernel is untyped. This file is the drawing the look tool already checked.
// @ts-nocheck
import { HL } from "./kernel"
import { create, type FigureContext, type FigureOptions } from "./create"

/**
 * Damage at a rack slot: a cracked carton, a count bead on the shelf lip, and
 * a manager stamp plate. The pointer brings the stamp down; only after it lands
 * does the bead drop away. The slider is how deep the stamp presses.
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

const SHELF = 16

function mount({ stage, svg, read }: FigureContext, press: number) {
  const bag = disposer()
  // Higher S fills more of the 400×320 frame (look warning was 17% rest cover).
  const C = Cam(45, 0.5, 2.55)
  fit(
    C,
    [
      [-44, -20, 0],
      [52, 44, 0],
      [-44, -20, 42],
      [52, 44, 42],
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

  slab(g, -40, -8, -32, 8, 0, 42, 1.1)
  slab(g, 36, -8, 44, 8, 0, 42, 1.1)
  slab(g, -40, -6, 44, 4, 38, 42, 1.2)
  slab(g, -34, -2, 38, 16, SHELF - 2, SHELF, 1.2)
  const slot = slab(g, -16, 0, 20, 14, SHELF, SHELF + 10, 1.3)
  const carton = solid(g)
  const crack = mk("path", { class: "nf" }, g)
  const bead = solid(g)
  const stamp = solid(g)
  const stampZ = tween(SHELF + 34)
  const beadDrop = tween(0)
  const crackOpen = tween(0.35)

  function drawCarton(openAmt) {
    const [ring, inner] = rings(-8, 2, 12, 12, 1.2, 0.5)
    put(carton, prism(P, front, ring, inner, SHELF + 1, SHELF + 11))
    const z = SHELF + 11.1
    crack.setAttribute(
      "d",
      open([
        P(-2, 4, z),
        P(1, 6 + openAmt * 2, z),
        P(4, 5, z),
        P(7, 8 + openAmt * 3, z),
      ]),
    )
  }

  function drawBead(drop) {
    if (drop > 0.85) {
      bead.sil.setAttribute("d", "")
      bead.cr.setAttribute("d", "")
      return
    }
    const z = SHELF + 10.4 - drop * 12
    const [ring, inner] = rings(22, 4, 28, 10, 2.2, 0.8)
    put(bead, prism(P, front, ring, inner, z, z + 4))
  }

  function drawStamp(z) {
    const [ring, inner] = rings(-4, 3, 8, 11, 1.3, 0.55)
    put(stamp, prism(P, front, ring, inner, z, z + press))
  }

  let armed = false
  let prev = ""
  const B = register(stage, (_dt, now) => {
    const sz = tval(stampZ, now)
    const drop = tval(beadDrop, now)
    const openAmt = tval(crackOpen, now)
    const key = [sz, drop, openAmt].map((n) => n.toFixed(2)).join(";")
    const moving =
      !tdone(stampZ, now) || !tdone(beadDrop, now) || !tdone(crackOpen, now)
    if (key === prev) return moving
    prev = key
    drawCarton(openAmt)
    drawBead(drop)
    drawStamp(sz)
    return moving
  })
  bag.add(B.unregister)

  function setArmed(on) {
    if (on === armed) return
    armed = on
    const now = performance.now()
    // Longer stamp travel + bead drop so the 240px answer moves more ink.
    tset(stampZ, on ? SHELF + 11 : SHELF + 34, now, 0)
    // Stock bead drops only after the stamp has settled on the carton.
    tset(beadDrop, on ? 1 : 0, now, on ? 220 : 40)
    tset(crackOpen, on ? 1 : 0.35, now, 60)
    stamp.sil.classList.toggle("hi", on)
    carton.sil.classList.toggle("hi", on)
    crack.classList.toggle("hi", on)
    bead.sil.classList.toggle("hi", !on)
    slot.sil.classList.toggle("hi", !on)
    read.textContent = on ? "hold" : "rest"
    B.wake()
  }

  slot.sil.classList.add("hi")
  bead.sil.classList.add("hi")
  read.textContent = "rest"
  drawCarton(0.35)
  drawBead(0)
  drawStamp(SHELF + 34)

  bag.add(
    pointer(stage, {
      move: () => setArmed(true),
      leave: () => setArmed(false),
    }),
  )
  bag.add(() => svg.replaceChildren())
  return {
    set: (v) => {
      press = v
    },
    destroy: bag.dispose,
  }
}

const spec = {
  name: "damage-mark",
  means:
    "A cracked carton in a rack slot: the manager stamp lands first, and only then does the shelf count bead fall away.",
  rules: [1, 4, 5, 8],
  range: [3.2, 5.5, 8],
  tour: [
    [200, 120],
    [190, 180],
    null,
  ],
  mount,
}

export function damageMark(el: HTMLElement, options?: FigureOptions) {
  return create(spec, el, options)
}
