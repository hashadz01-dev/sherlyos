// The kernel is untyped. This file is the drawing the look tool already checked.
// @ts-nocheck
import { HL } from "./kernel"
import { create, type FigureContext, type FigureOptions } from "./create"

/**
 * Accounts: ledger book, filling credit gauge, checked draft sheet (outline
 * only), posting arm. No amounts, tax, GST, or software marks.
 */
const {
  Cam, clamp, facing, fit, proj, rings, prism, put, solid, ringAt, poly, open,
  unproj, spring, stepS, tdone, tset, tval, tween, disposer, mk, pointer, register,
} = HL

function mount({ stage, svg, read }: FigureContext, reach: number) {
  const bag = disposer()
  const C = Cam(45, 0.5, 2.45)
  fit(C, [[-66, -34, 0], [74, 46, 0], [-66, -34, 40], [74, 46, 40]], 200, 168)
  const P = proj(C), front = facing(C)
  const g = mk("g", {}, svg)
  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent)
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.75)
    put(s, prism(P, front, ring, inner, z0, z1))
    return s
  }
  slab(g, -58, -6, 64, 16, 0, 3, 1.4)
  // Ledger block — thick covers + spine, not a flat invoice sheet.
  const ledger = slab(g, -50, 0, -4, 26, 3, 13, 1.4)
  slab(g, -48, 2, -6, 24, 13, 14.2, 1)
  const spine = slab(g, -52, 0, -48, 26, 3, 13, 0.7)
  mk("path", { class: "nf lo" }, g).setAttribute(
    "d",
    [9, 15, 21].map((y) => {
      const a = P(-44, y, 14.4), b = P(-10, y, 14.4)
      return `M${a[0]} ${a[1]}L${b[0]} ${b[1]}`
    }).join(""),
  )
  const gauge = slab(g, 6, -2, 26, 12, 3, 5, 1)
  const segments = [0, 1, 2, 3, 4].map(() => solid(g))
  const fill = spring(0.1)
  // Draft: dashed outline only + check.
  const draft = slab(g, 32, -4, 60, 20, 3, 4.2, 1.1)
  mk("path", { class: "nf dash" }, g).setAttribute(
    "d",
    poly(ringAt(P, rings(36, 0, 56, 16, 1, 0.4)[0], 4.4)),
  )
  const check = mk("path", { class: "nf" }, g)
  const checkOn = tween(0)
  const arm = solid(g)
  const armZ = tween(24)

  function drawSegments(level) {
    segments.forEach((seg, i) => {
      if (level <= i * 0.18) {
        seg.sil.setAttribute("d", "")
        seg.cr.setAttribute("d", "")
        return
      }
      const z0 = 5.2 + i * 3.4
      const [ring, inner] = rings(9, 1, 23, 9, 1, 0.4)
      put(seg, prism(P, front, ring, inner, z0, z0 + 2.8))
      seg.sil.classList.toggle("hi", i === Math.min(4, Math.floor(level * 5)))
    })
  }
  function drawCheck(on) {
    check.setAttribute(
      "d",
      on < 0.2
        ? ""
        : open([P(40, 9, 4.5), P(44, 13, 4.5), P(52, 4, 4.5)]),
    )
    check.classList.toggle("hi", on > 0.5)
  }
  function drawArm(z) {
    const [ring, inner] = rings(-26, 6, -8, 18, 1.2, 0.5)
    put(arm, prism(P, front, ring, inner, z, z + 3.8))
  }

  let prev = ""
  const B = register(stage, (dt, now) => {
    const movingSpring = stepS(fill, dt)
    const az = tval(armZ, now), ck = tval(checkOn, now), level = fill.x
    const key = [level, az, ck].map((n) => n.toFixed(3)).join(";")
    const moving = movingSpring || !tdone(armZ, now) || !tdone(checkOn, now)
    if (key !== prev) {
      prev = key
      drawSegments(level)
      drawCheck(ck)
      drawArm(az)
    }
    return moving
  })
  bag.add(B.unregister)

  function aim([sx, sy]) {
    const [x] = unproj(C, sx, sy, 0)
    const t = clamp((x + 35) / 95, 0, 1)
    fill.t = t
    const now = performance.now()
    tset(checkOn, t > 0.4 ? 1 : 0, now, 80)
    tset(armZ, t > 0.72 ? 14.5 : 24, now, t > 0.72 ? 140 : 50)
    arm.sil.classList.toggle("hi", t > 0.72)
    ledger.sil.classList.toggle("hi", t > 0.72)
    spine.sil.classList.toggle("hi", t > 0.72)
    gauge.sil.classList.toggle("hi", t > 0.15 && t <= 0.72)
    draft.sil.classList.toggle("hi", t > 0.35 && t <= 0.72)
    read.textContent =
      t > 0.72 ? "post" : t > 0.4 ? "check" : t > 0.12 ? "credit" : "rest"
    B.wake()
  }
  function leave() {
    fill.t = 0
    const now = performance.now()
    tset(checkOn, 0, now, 40)
    tset(armZ, 24, now, 40)
    ;[arm, spine, gauge, draft].forEach((s) => s.sil.classList.remove("hi"))
    ledger.sil.classList.add("hi")
    read.textContent = "rest"
    B.wake()
  }

  ledger.sil.classList.add("hi")
  read.textContent = "rest"
  bag.add(pointer(stage, { move: aim, leave }))
  bag.add(() => svg.replaceChildren())
  return { set: (v) => { reach = v }, destroy: bag.dispose }
}

const spec = {
  name: "accounts-desk",
  means:
    "A ledger beside a draft note: the pointer fills a credit gauge, checks the sheet, then a posting arm presses the book.",
  rules: [1, 4, 5, 8],
  range: [18, 32, 48],
  tour: [[120, 160], [200, 150], [260, 210], null],
  mount,
}

export function accountsDesk(el: HTMLElement, options?: FigureOptions) {
  return create(spec, el, options)
}
