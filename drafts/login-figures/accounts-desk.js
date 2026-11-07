/**
 * Accounts desk: ledger, credit gauge, draft note. Pointer fills the gauge,
 * checks the sheet, then a posting arm presses the book. No tax or currency.
 */
const {
  Cam, clamp, facing, fit, proj, rings, prism, put, solid, ringAt, poly, unproj,
  spring, stepS, tdone, tset, tval, tween, disposer, mk, pointer, register,
} = HL

const ROWS = [8, 16, 24, 32]

function mount({ stage, svg, read }, reach) {
  const bag = disposer()
  const C = Cam(45, 0.5, 2.0)
  fit(C, [[-78, -30, 0], [92, 54, 0], [-78, -30, 36], [92, 54, 36]], 200, 168)
  const P = proj(C), front = facing(C)
  const g = mk("g", {}, svg)
  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent)
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.75)
    put(s, prism(P, front, ring, inner, z0, z1))
    return s
  }
  const sheet = slab(g, -70, -6, -8, 42, 0, 1.6, 1.4)
  mk("path", { class: "nf dash" }, g).setAttribute(
    "d",
    poly(ringAt(P, rings(-64, 0, -14, 36, 1.2, 0.4)[0], 1.7)),
  )
  mk("path", { class: "nf lo" }, g).setAttribute(
    "d",
    ROWS.map((y) => {
      const a = P(-60, y, 1.75), b = P(-18, y, 1.75)
      return `M${a[0]} ${a[1]}L${b[0]} ${b[1]}`
    }).join(""),
  )
  const bars = ROWS.map(() => ({ s: solid(g), w: tween(0) }))
  const gaugeBase = slab(g, 4, -4, 48, 20, 0, 3, 1.2)
  const segments = [0, 1, 2, 3, 4].map(() => solid(g))
  const ledger = slab(g, 12, 26, 70, 50, 0, 5, 1.5)
  const arm = solid(g)
  const armZ = tween(28)
  const fill = spring(0.08)

  function drawBar(i, w) {
    const y = ROWS[i]
    if (w < 1) {
      bars[i].s.sil.setAttribute("d", "")
      bars[i].s.cr.setAttribute("d", "")
      return
    }
    const [ring, inner] = rings(-58, y - 2.2, -58 + w, y + 2.2, 0.8, 0.35)
    put(bars[i].s, prism(P, front, ring, inner, 1.8, 3.2))
  }
  function drawSegments(level) {
    segments.forEach((seg, i) => {
      if (level <= i * 0.18) {
        seg.sil.setAttribute("d", "")
        seg.cr.setAttribute("d", "")
        return
      }
      const x0 = 8 + i * 7.5
      const [ring, inner] = rings(x0, 2, x0 + 6, 14, 1, 0.4)
      put(seg, prism(P, front, ring, inner, 3.2, 3.2 + 4 + i * 1.2))
      seg.sil.classList.toggle("hi", i === Math.min(4, Math.floor(level * 5)))
    })
  }
  function drawArm(z) {
    const [ring, inner] = rings(30, 30, 52, 42, 1.2, 0.5)
    put(arm, prism(P, front, ring, inner, z, z + 4))
  }

  let prev = ""
  const B = register(stage, (dt, now) => {
    const movingSpring = stepS(fill, dt)
    const az = tval(armZ, now)
    const level = fill.x
    const key =
      level.toFixed(3) +
      ";" +
      az.toFixed(2) +
      ";" +
      bars.map((b) => tval(b.w, now).toFixed(1)).join(",")
    const moving =
      movingSpring || !tdone(armZ, now) || bars.some((b) => !tdone(b.w, now))
    if (key !== prev) {
      prev = key
      drawSegments(level)
      bars.forEach((b, i) => drawBar(i, tval(b.w, now)))
      drawArm(az)
    }
    return moving
  })
  bag.add(B.unregister)

  function aim([sx, sy]) {
    const [x] = unproj(C, sx, sy, 0)
    const t = clamp((x + 40) / 100, 0, 1)
    fill.t = t
    const now = performance.now()
    bars.forEach((b, i) => {
      tset(b.w, t > i * 0.2 ? 8 + t * reach * 0.35 : 0, now, i * 35)
      b.s.sil.classList.toggle("hi", t > i * 0.2 && t < (i + 1) * 0.28)
    })
    tset(armZ, t > 0.72 ? 6 : 28, now, t > 0.72 ? 120 : 40)
    arm.sil.classList.toggle("hi", t > 0.72)
    ledger.sil.classList.toggle("hi", t > 0.72)
    gaugeBase.sil.classList.toggle("hi", t > 0.2 && t <= 0.72)
    sheet.sil.classList.toggle("hi", t > 0.35 && t <= 0.72)
    read.textContent =
      t > 0.72 ? "post" : t > 0.35 ? "check" : t > 0.1 ? "credit" : "rest"
    B.wake()
  }
  function leave() {
    fill.t = 0.08
    const now = performance.now()
    bars.forEach((b, i) => tset(b.w, 0, now, i * 20))
    tset(armZ, 28, now, 40)
    arm.sil.classList.remove("hi")
    ledger.sil.classList.remove("hi")
    gaugeBase.sil.classList.remove("hi")
    sheet.sil.classList.add("hi")
    read.textContent = "rest"
    B.wake()
  }

  sheet.sil.classList.add("hi")
  read.textContent = "rest"
  bag.add(pointer(stage, { move: aim, leave }))
  bag.add(() => svg.replaceChildren())
  return { set: (v) => { reach = v }, destroy: bag.dispose }
}

hairline({
  name: "accounts-desk",
  means:
    "A ledger beside a draft note: the pointer fills a credit gauge, checks the sheet, then a posting arm presses the book.",
  rules: [1, 4, 5, 8],
  range: [18, 32, 48],
  tour: [[120, 160], [200, 150], [260, 210], null],
  mount,
})
