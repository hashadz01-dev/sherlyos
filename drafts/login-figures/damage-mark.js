// The kernel is untyped. This file is the drawing the look tool already checked.
/**
 * Damage: one cracked carton in a single rack slot. The manager stamp lands,
 * then the shelf count bead falls away. Distinct from daily-count — no
 * clipboard, no crate row, no tally ticks.
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
  tdone,
  tset,
  tval,
  tween,
  disposer,
  mk,
  pointer,
  register,
} = HL

const SHELF = 14

function mount({ stage, svg, read }, press) {
  const bag = disposer()
  const C = Cam(45, 0.5, 2.85)
  fit(
    C,
    [
      [-40, -22, 0],
      [48, 40, 0],
      [-40, -22, 44],
      [48, 40, 44],
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

  // Single bay: posts + one shelf slot — not a multi-crate count rack.
  slab(g, -34, -10, -26, 6, 0, 40, 1.1)
  slab(g, 28, -10, 36, 6, 0, 40, 1.1)
  slab(g, -34, -8, 36, 2, 36, 40, 1.2)
  slab(g, -28, -4, 30, 14, SHELF - 2, SHELF, 1.2)
  const slot = slab(g, -14, 0, 16, 12, SHELF, SHELF + 9, 1.2)

  const carton = solid(g)
  const crack = mk("path", { class: "nf" }, g)
  const crack2 = mk("path", { class: "nf" }, g)
  const bead = solid(g)
  const stamp = solid(g)
  const stampZ = tween(SHELF + 32)
  const beadDrop = tween(0)
  const crackOpen = tween(0.4)

  function drawCarton(openAmt) {
    // Larger carton face so the crack is the hero mark.
    const [ring, inner] = rings(-10, 1, 14, 13, 1.3, 0.55)
    put(carton, prism(P, front, ring, inner, SHELF + 1, SHELF + 12))
    const z = SHELF + 12.2
    // Two zig-zag strokes — readable as a crack even at rest.
    crack.setAttribute(
      "d",
      open([
        P(-6, 3, z),
        P(-2, 5 + openAmt * 2.5, z),
        P(2, 4, z),
        P(6, 8 + openAmt * 3.5, z),
        P(10, 7, z),
      ]),
    )
    crack2.setAttribute(
      "d",
      open([
        P(-4, 8, z),
        P(0, 9 + openAmt * 1.5, z),
        P(5, 11 + openAmt * 2, z),
      ]),
    )
  }

  function drawBead(drop) {
    if (drop > 0.85) {
      bead.sil.setAttribute("d", "")
      bead.cr.setAttribute("d", "")
      return
    }
    const z = SHELF + 10 - drop * 14
    const [ring, inner] = rings(20, 3, 28, 11, 2.4, 0.9)
    put(bead, prism(P, front, ring, inner, z, z + 5))
  }

  function drawStamp(z) {
    // Manager plate: wider and thicker so it reads before the bead drops.
    const [ring, inner] = rings(-6, 2, 10, 12, 1.5, 0.6)
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
    tset(stampZ, on ? SHELF + 12 : SHELF + 32, now, 0)
    // Count bead falls only after the stamp has settled.
    tset(beadDrop, on ? 1 : 0, now, on ? 240 : 40)
    tset(crackOpen, on ? 1 : 0.4, now, 70)
    stamp.sil.classList.toggle("hi", on)
    carton.sil.classList.toggle("hi", on)
    crack.classList.toggle("hi", on)
    crack2.classList.toggle("hi", on)
    bead.sil.classList.toggle("hi", !on)
    slot.sil.classList.toggle("hi", !on)
    read.textContent = on ? "hold" : "rest"
    B.wake()
  }

  slot.sil.classList.add("hi")
  bead.sil.classList.add("hi")
  read.textContent = "rest"
  drawCarton(0.4)
  drawBead(0)
  drawStamp(SHELF + 32)

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

hairline({
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
})

