import { useGSAP } from "@gsap/react"
import gsap from "gsap"
import { useRef, useState, type CSSProperties } from "react"
import {
  AccountsDesk,
  DailyCount,
  DamageMark,
  DeliveryVan,
  DispatchBay,
  InvoiceNote,
  OrderDesk,
  PackRack,
  StockIn,
  VerifyLedger,
} from "@/features/auth/stage/hairline/react"

/**
 * jsdom has neither matchMedia nor IntersectionObserver. Hairline and GSAP
 * both call them while mounting, and an uncaught throw replaces the sign-in
 * route. Real browsers already have both, so this only fills the gap.
 */
function installLoginStageShims() {
  if (typeof window === "undefined") return
  if (typeof window.matchMedia !== "function") {
    window.matchMedia = (query: string): MediaQueryList => ({
      matches: query.includes("prefers-reduced-motion: reduce"),
      media: query,
      onchange: null,
      addListener: () => undefined,
      removeListener: () => undefined,
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
      dispatchEvent: () => false,
    })
  }
  if (typeof IntersectionObserver === "undefined") {
    class NoopObserver {
      observe() {}
      unobserve() {}
      disconnect() {}
      takeRecords() {
        return []
      }
      root = null
      rootMargin = ""
      thresholds: number[] = []
    }
    window.IntersectionObserver =
      NoopObserver as unknown as typeof IntersectionObserver
  }
}

installLoginStageShims()

const WIDE = 1
const MEDIUM = 1.35
const MARGIN = 0.06
/** Fallback close scale until each plate's figure box is measured. */
const CLOSE_FALLBACK = 2.4

const ESTABLISH = 3.5
const PUSH = 1.2
const HOLD = 3
const ARC = 1
const PULL_OUT = 1.8
const WIDE_HOLD = 2.5
const ACT_GAP = 2.5
const FADE = 1
const LOOP_PAUSE = 1.5
/** Old caption must be fully gone before the new line fades in. Keep under 0.1 s to the push-in label. */
const CAPTION_OUT = 0.08
const CAPTION_IN = 0.28
const WIDE_OPACITY = 0.7
const IDLE_OPACITY = 0.35
const PLAY_INTENSITY = 0.5
const CARTON = 44
const DOCK_GAP = 28
/** Target figure fill of the panel at close. */
const CLOSE_FILL = 0.6
/** Act 1 is the carton's journey. Act 2 plates are supporting operations. */
const CARTON_LAST = 5

const PLATE_COLOR = "#0e1c33"

/**
 * Act 1 (~40 s) follows one carton. Act 2 is four supporting stations after a
 * wide gap. Station 5 stays a draft note only — never a tax invoice.
 */
const STAGES = [
  {
    key: "order",
    Figure: OrderDesk,
    tag: "1 Order",
    label: "An order desk",
    caption: "Shop order captured.",
    act: 1 as const,
  },
  {
    key: "verify",
    Figure: VerifyLedger,
    tag: "2 Verify",
    label: "An accounts ledger",
    caption: "Accounts verifies the order.",
    act: 1 as const,
  },
  {
    key: "pack",
    Figure: PackRack,
    tag: "3 Pack",
    label: "A packing rack",
    caption:
      "Cartons reserved from crates and packed. Stock is not deducted yet.",
    act: 1 as const,
  },
  {
    key: "dispatch",
    Figure: DispatchBay,
    tag: "4 Dispatch",
    label: "A dispatch bay",
    caption: "Dispatch confirmed. Stock leaves the godown once.",
    act: 1 as const,
  },
  {
    key: "invoice",
    Figure: InvoiceNote,
    tag: "5 Invoice note",
    label: "A draft invoice note",
    caption: "Draft invoice note prepared from the confirmed dispatch.",
    act: 1 as const,
  },
  {
    key: "deliver",
    Figure: DeliveryVan,
    tag: "6 Deliver",
    label: "A delivery van",
    caption: "Delivered to the shop with proof of delivery.",
    act: 1 as const,
  },
  {
    key: "stock-in",
    Figure: StockIn,
    tag: "7 Stock in",
    label: "An inbound supplier bay",
    caption:
      "Inbound stock counted, damage set aside, cases allocated to crates.",
    act: 2 as const,
  },
  {
    key: "daily-count",
    Figure: DailyCount,
    tag: "8 Daily count",
    label: "A daily crate count",
    caption:
      "Every crate counted against the system. Differences need a reason and approval.",
    act: 2 as const,
  },
  {
    key: "damage",
    Figure: DamageMark,
    tag: "9 Damage",
    label: "A damaged carton on a rack",
    caption:
      "Damage recorded where it happened and verified before stock is deducted.",
    act: 2 as const,
  },
  {
    key: "accounts",
    Figure: AccountsDesk,
    tag: "10 Accounts",
    label: "An accounts desk",
    caption: "Accounts checks credit and billing before anything is posted.",
    act: 2 as const,
  },
] as const

const STAGE_COUNT = STAGES.length
const LONGEST_CAPTION = STAGES.reduce(
  (best, stage) => (stage.caption.length > best.length ? stage.caption : best),
  "",
)

const stageVars = {
  "--hairline-plate": PLATE_COLOR,
  "--hairline-hi": "#e8eef6",
  "--hairline-edge": "#a9b8c9",
  "--hairline-mid": "#7b8da3",
  "--hairline-lo": "#415066",
} as CSSProperties

type Point = { x: number; y: number }
type PlateBox = { x: number; y: number; w: number; h: number }
type Cam = { x: number; y: number; scale: number }
type LayoutState = {
  w: number
  h: number
  boxes: PlateBox[]
  close: number[]
}

/**
 * Ten plates: act 1 zigzags on the lower band, act 2 on the upper band.
 * Wide shot keeps a 6% margin. Plate width targets ~60% panel fill at close.
 * Bottom reserve keeps the route clear of the overlaid caption dock.
 */
function buildLayout(width: number, height: number): PlateBox[] {
  const plateW = Math.min(width * 0.2, width * (0.6 / CLOSE_FALLBACK))
  const plateH = plateW * 0.8
  const tag = 22
  const marginX = MARGIN * width
  const marginY = MARGIN * height
  const captionReserve = Math.min(150, Math.max(96, height * 0.18))
  let minX = marginX + plateW / 2
  let maxX = width - marginX - plateW / 2
  if (maxX < minX) {
    minX = width / 2
    maxX = width / 2
  }
  let minY = marginY + plateH / 2 + tag
  let maxY = height - marginY - plateH / 2 - captionReserve
  if (maxY < minY) {
    const mid = height / 2
    minY = mid
    maxY = mid
  }
  const midY = (minY + maxY) / 2
  const upper = midY - (maxY - minY) * 0.28
  const lower = midY + (maxY - minY) * 0.28

  return STAGES.map((stage, index) => {
    if (stage.act === 1) {
      const last = CARTON_LAST
      const x = minX + (index / last) * (maxX - minX)
      const low = index % 2 === 0
      const y = low ? lower + (maxY - lower) * 0.15 : lower - (lower - midY) * 0.2
      return { x, y, w: plateW, h: plateH }
    }
    const actIndex = index - (CARTON_LAST + 1)
    const actLast = STAGE_COUNT - CARTON_LAST - 2
    const x =
      minX +
      ((actIndex + 0.5) / (actLast + 1.5)) * (maxX - minX)
    const low = actIndex % 2 === 0
    const y = low ? upper + (midY - upper) * 0.1 : upper - (upper - minY) * 0.15
    return { x, y, w: plateW, h: plateH }
  })
}

function edgePoint(plate: PlateBox, toward: Point): Point {
  const dx = toward.x - plate.x
  const dy = toward.y - plate.y
  if (dx === 0 && dy === 0) return { x: plate.x, y: plate.y }
  const sx = dx === 0 ? Infinity : plate.w / 2 / Math.abs(dx)
  const sy = dy === 0 ? Infinity : plate.h / 2 / Math.abs(dy)
  const s = Math.min(sx, sy)
  return { x: plate.x + dx * s, y: plate.y + dy * s }
}

function outside(plate: PlateBox, toward: Point): Point {
  const edge = edgePoint(plate, toward)
  const dx = edge.x - plate.x
  const dy = edge.y - plate.y
  const len = Math.hypot(dx, dy) || 1
  return {
    x: edge.x + (dx / len) * DOCK_GAP,
    y: edge.y + (dy / len) * DOCK_GAP,
  }
}

function arrival(boxes: PlateBox[], index: number): Point {
  const plate = boxes[index]
  if (!plate) return { x: 0, y: 0 }
  if (index === 0) {
    const next = boxes[1]
    return next ? outside(plate, next) : { x: plate.x, y: plate.y }
  }
  const prev = boxes[index - 1]
  return prev ? outside(plate, prev) : { x: plate.x, y: plate.y }
}

/** Solid route for the carton's act 1. Dashed links for supporting act 2. */
function connectorPaths(boxes: PlateBox[]) {
  const solid: string[] = []
  const dashed: string[] = []
  for (let index = 0; index < boxes.length - 1; index += 1) {
    const from = boxes[index]
    const to = boxes[index + 1]
    if (!from || !to) continue
    const start = outside(from, to)
    const end = outside(to, from)
    const d = `M${start.x.toFixed(1)} ${start.y.toFixed(1)} L${end.x.toFixed(1)} ${end.y.toFixed(1)}`
    if (index < CARTON_LAST) solid.push(d)
    else dashed.push(d)
  }
  return { solid: solid.join(" "), dashed: dashed.join(" ") }
}

function frame(
  width: number,
  height: number,
  point: Point,
  scale: number,
): Cam {
  return {
    x: width / 2 - point.x * scale,
    y: height / 2 - point.y * scale,
    scale,
  }
}

function bow(from: Cam, to: Cam): Cam {
  return {
    x: (from.x + to.x) / 2 + (to.y - from.y) * 0.12,
    y: (from.y + to.y) / 2 - (to.x - from.x) * 0.12,
    scale: (from.scale + to.scale) / 2,
  }
}

function placeCarton(point: Point) {
  return { x: point.x - CARTON / 2, y: point.y - CARTON / 2 }
}

/**
 * Close scale so the focused figure fills ~60% of the panel width.
 * Prefer the laid-out plate width (world units at identity). Fall back to the
 * SVG box when the plate has not been sized yet.
 */
function measureCloseScales(
  plates: HTMLElement[],
  panelWidth: number,
  camScale: number,
): number[] {
  return plates.map((plate) => {
    const svg = plate.querySelector("svg")
    const plateW = plate.offsetWidth
    const box = (svg ?? plate).getBoundingClientRect()
    const measured =
      plateW > 8
        ? plateW
        : box.width / Math.max(camScale, 0.01)
    const worldW = Math.max(24, measured)
    return Math.min(3.4, Math.max(1.5, (CLOSE_FILL * panelWidth) / worldW))
  })
}

function applyCamera(
  world: HTMLElement,
  floor: HTMLElement,
  cam: Cam,
  tags: Array<HTMLElement | null>,
  focusIndex: number,
  connectors: Array<SVGPathElement | null>,
) {
  world.style.transformOrigin = "0 0"
  floor.style.transformOrigin = "0 0"
  world.style.transform = `translate(${cam.x}px, ${cam.y}px) scale(${cam.scale})`
  const floorScale = 1 + (cam.scale - 1) * 0.6
  floor.style.transform = `translate(${cam.x * 0.6}px, ${cam.y * 0.6}px) scale(${floorScale})`

  // Tags keep a constant screen size by counter-scaling the camera.
  const inv = 1 / Math.max(cam.scale, 0.01)
  const closeShot = cam.scale > MEDIUM + 0.05
  tags.forEach((tag, index) => {
    if (!tag) return
    tag.style.transform = `translateX(-50%) scale(${inv})`
    tag.style.transformOrigin = "50% 100%"
    if (closeShot) {
      tag.style.opacity = index === focusIndex ? "1" : "0"
    } else {
      tag.style.opacity = "1"
    }
  })

  const linkOpacity = closeShot ? 0 : 1
  connectors.forEach((path) => {
    if (path) path.style.opacity = String(linkOpacity)
  })
}

function prefersReducedMotion() {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function")
    return true
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches
}

function watchPlayback(
  timeline: gsap.core.Timeline,
  node: HTMLElement,
  onRunning: (running: boolean) => void,
) {
  let last: boolean | null = null
  const apply = (running: boolean) => {
    if (last !== running) {
      last = running
      onRunning(running)
    }
    if (running) timeline.resume()
    else timeline.pause()
  }

  const shown = () => {
    const box = node.getBoundingClientRect()
    const offscreen =
      box.width === 0 ||
      box.height === 0 ||
      box.bottom <= 0 ||
      box.top >= window.innerHeight
    return document.visibilityState !== "hidden" && !offscreen
  }

  const onVisibility = () => apply(shown())
  document.addEventListener("visibilitychange", onVisibility)

  let observer: IntersectionObserver | null = null
  if (typeof IntersectionObserver === "function") {
    observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry) return
        apply(
          document.visibilityState !== "hidden" &&
            entry.isIntersecting &&
            entry.intersectionRatio >= 0.05,
        )
      },
      { threshold: 0.05 },
    )
    observer.observe(node)
  }

  apply(shown())
  return () => {
    document.removeEventListener("visibilitychange", onVisibility)
    observer?.disconnect()
  }
}

function placePlates(
  plates: Array<HTMLDivElement | null>,
  boxes: PlateBox[],
) {
  plates.forEach((node, index) => {
    const box = boxes[index]
    if (!node || !box) return
    node.style.left = `${box.x}px`
    node.style.top = `${box.y}px`
    node.style.width = `${box.w}px`
  })
}

const FLOOR_DOTS = Array.from({ length: 22 }, (_, row) =>
  Array.from({ length: 30 }, (_, col) => ({
    x: col * 28 + (row % 2 ? 14 : 0),
    y: row * 14,
  })),
).flat()

/**
 * Isometric login film. The master timeline is built once. Resize only
 * recomputes layout targets and calls timeline.invalidate() — it must not
 * recreate the timeline (that truncated the first loop after Dispatch).
 */
export function LoginFlowStage() {
  const rootRef = useRef<HTMLDivElement>(null)
  const diagramRef = useRef<HTMLDivElement>(null)
  const worldRef = useRef<HTMLDivElement>(null)
  const floorRef = useRef<HTMLDivElement>(null)
  const cartonRef = useRef<HTMLDivElement>(null)
  const captionRef = useRef<HTMLParagraphElement>(null)
  const captionWrapRef = useRef<HTMLDivElement>(null)
  const markerRef = useRef<HTMLSpanElement>(null)
  const solidLinkRef = useRef<SVGPathElement>(null)
  const dashedLinkRef = useRef<SVGPathElement>(null)
  const plateNodes = useRef<Array<HTMLDivElement | null>>([])
  const tagNodes = useRef<Array<HTMLSpanElement | null>>([])
  const dotNodes = useRef<Array<HTMLSpanElement | null>>([])
  const layoutRef = useRef<LayoutState | null>(null)
  const timelineRef = useRef<gsap.core.Timeline | null>(null)
  const focusRef = useRef(-1)
  const camRef = useRef<Cam>({ x: 0, y: 0, scale: WIDE })

  const [ready, setReady] = useState(false)
  const [reduced, setReduced] = useState(prefersReducedMotion)
  const [focus, setFocus] = useState(-1)
  const [holding, setHolding] = useState(false)
  const [running, setRunning] = useState(true)
  const [paths, setPaths] = useState({ solid: "", dashed: "" })

  useGSAP(
    () => {
      const diagram = diagramRef.current
      if (!diagram || typeof ResizeObserver !== "function") return

      const syncLayout = (width: number, height: number, rebuildClose: boolean) => {
        const boxes = buildLayout(width, height)
        const plates = plateNodes.current.filter(
          (node): node is HTMLDivElement => node !== null,
        )
        placePlates(plateNodes.current, boxes)
        const close =
          rebuildClose && plates.length === STAGE_COUNT
            ? measureCloseScales(plates, width, camRef.current.scale)
            : (layoutRef.current?.close ??
              Array.from({ length: STAGE_COUNT }, () => CLOSE_FALLBACK))
        layoutRef.current = { w: width, h: height, boxes, close }
        const nextPaths = connectorPaths(boxes)
        setPaths(nextPaths)
        if (solidLinkRef.current) solidLinkRef.current.setAttribute("d", nextPaths.solid)
        if (dashedLinkRef.current)
          dashedLinkRef.current.setAttribute("d", nextPaths.dashed)
        // Functional tweens re-read layoutRef on the next tick after invalidate.
        timelineRef.current?.invalidate()
      }

      let timer = 0
      let seen = false
      const measure = () => {
        const width = diagram.clientWidth
        const height = diagram.clientHeight
        if (width < 10 || height < 10) return
        const first = !layoutRef.current
        syncLayout(width, height, first || !timelineRef.current)
        if (first) setReady(true)
      }

      const observer = new ResizeObserver(() => {
        // First box starts the film. Later changes only invalidate targets.
        if (!seen) {
          seen = true
          measure()
          return
        }
        window.clearTimeout(timer)
        timer = window.setTimeout(measure, 200)
      })
      observer.observe(diagram)
      return () => {
        window.clearTimeout(timer)
        observer.disconnect()
      }
    },
    { scope: diagramRef },
  )

  useGSAP(
    () => {
      const diagram = diagramRef.current
      const world = worldRef.current
      const floor = floorRef.current
      const carton = cartonRef.current
      const caption = captionRef.current
      const captionWrap = captionWrapRef.current
      const marker = markerRef.current
      if (!diagram || !world || !floor || !carton || !caption || !marker) return
      if (!ready || !layoutRef.current) return

      const plates = plateNodes.current.filter(
        (node): node is HTMLDivElement => node !== null,
      )
      if (plates.length !== STAGE_COUNT) return

      // Re-measure close scales now that every figure SVG is in the tree.
      const { w: width, boxes } = layoutRef.current
      layoutRef.current.close = measureCloseScales(plates, width, 1)
      placePlates(plateNodes.current, boxes)
      setPaths(connectorPaths(boxes))

      const cam = camRef.current
      const write = () =>
        applyCamera(
          world,
          floor,
          cam,
          tagNodes.current,
          focusRef.current,
          [solidLinkRef.current, dashedLinkRef.current],
        )

      const media = gsap.matchMedia()

      const setCaptionOpen = (open: boolean) => {
        if (!captionWrap) return
        captionWrap.style.gridTemplateRows = open ? "1fr" : "0fr"
        captionWrap.dataset.open = open ? "1" : "0"
      }

      const showStep = (index: number) => {
        const stage = STAGES[index]
        const nextLine = stage ? stage.caption : ""
        const nextLabel = stage ? `${index + 1} / ${STAGE_COUNT}` : ""
        // Text swaps only while opacity is 0, so old and new never share a frame.
        caption.textContent = nextLine
        marker.textContent = nextLabel
        focusRef.current = index
        setFocus(index)
        setCaptionOpen(Boolean(nextLine))
        dotNodes.current.forEach((dot, i) => {
          if (!dot) return
          dot.classList.toggle("bg-white", i === index)
          dot.classList.toggle("bg-white/55", i !== index)
        })
        if (import.meta.env.DEV) {
          const probe = (
            window as Window & {
              __loginFilm?: { captionSwaps: Array<Record<string, unknown>> }
            }
          ).__loginFilm
          probe?.captionSwaps.push({
            index,
            label: `s${index + 1}`,
            at: performance.now(),
            text: nextLine,
            opacity: Number(gsap.getProperty(caption, "opacity")),
          })
        }
      }

      const showWide = () => {
        caption.textContent = ""
        marker.textContent = ""
        focusRef.current = -1
        setFocus(-1)
        setHolding(false)
        setCaptionOpen(false)
        dotNodes.current.forEach((dot) => {
          if (!dot) return
          dot.classList.remove("bg-white")
          dot.classList.add("bg-white/55")
        })
      }

      media.add(
        {
          reduceMotion: "(prefers-reduced-motion: reduce)",
          all: "all",
        },
        (context) => {
          const still = Boolean(
            (context.conditions as { reduceMotion?: boolean } | undefined)
              ?.reduceMotion,
          )
          setReduced(still)

          if (still) {
            setFocus(-1)
            setHolding(false)
            setRunning(false)
            cam.x = 0
            cam.y = 0
            cam.scale = WIDE
            write()
            gsap.set(plates, { opacity: 1 })
            gsap.set(carton, { opacity: 0 })
            setCaptionOpen(false)
            return
          }

          showWide()
          setRunning(true)
          write()
          gsap.set(plates, { opacity: WIDE_OPACITY })
          gsap.set([caption, marker], { opacity: 0 })
          gsap.set(carton, {
            ...placeCarton(arrival(layoutRef.current!.boxes, 0)),
            opacity: 1,
          })

          // Build once. Resize path calls invalidate() instead of recreating.
          // Do not put force3D on timeline defaults — GSAP 3.15 rejects it on
          // plain-object camera tweens and skips the property with a warning.
          const timeline = gsap.timeline({
            paused: true,
            repeat: -1,
            repeatDelay: LOOP_PAUSE,
          })
          timelineRef.current = timeline

          if (import.meta.env.DEV) {
            const started = performance.now()
            ;(
              window as Window & {
                __loginFilm?: Record<string, unknown>
              }
            ).__loginFilm = {
              started,
              timeline,
              labels: () => ({ ...timeline.labels }),
              time: () => timeline.time(),
              totalDuration: () => timeline.totalDuration(),
              captionSwaps: [] as Array<Record<string, unknown>>,
              captionOpacity: () => Number(gsap.getProperty(caption, "opacity")),
              captionText: () => caption.textContent ?? "",
              closeScales: () => layoutRef.current?.close ?? [],
              /** Seek with suppressEvents=false so onUpdate write() paints the camera. */
              seek: (labelOrTime: string | number) => {
                timeline.pause()
                timeline.seek(labelOrTime, false)
                write()
                return {
                  time: timeline.time(),
                  scale: cam.scale,
                  x: cam.x,
                  y: cam.y,
                }
              },
              measureFill: (index: number) => {
                const plate = plates[index]
                const L = layoutRef.current
                if (!plate || !L) return null
                const close = L.close[index] ?? CLOSE_FALLBACK
                const svg = plate.querySelector("svg")
                const worldW = plate.offsetWidth || 1
                const panel = diagram.getBoundingClientRect().width
                const figW = svg?.getBoundingClientRect().width ?? 0
                return {
                  index,
                  close,
                  plateWorldW: worldW,
                  fillPct: (worldW * close) / L.w,
                  fillFromScreen: panel > 0 ? figW / panel : null,
                  svgScreenW: figW || null,
                  panelW: panel || L.w,
                  scale: cam.scale,
                }
              },
            }
          }

          const layout = () => layoutRef.current!

          timeline.set(cam, { x: 0, y: 0, scale: WIDE }, 0)
          timeline.call(write, undefined, 0)
          timeline.set(plates, { opacity: WIDE_OPACITY }, 0)
          timeline.set(
            carton,
            {
              x: () => placeCarton(arrival(layout().boxes, 0)).x,
              y: () => placeCarton(arrival(layout().boxes, 0)).y,
              opacity: 1,
            },
            0,
          )
          timeline.call(showWide, undefined, 0)
          timeline.addLabel("wide0", 0)

          let cursor = ESTABLISH

          const pushStation = (index: number) => {
            const stationAt = cursor
            const holdAt = stationAt + PUSH
            const arcAt = holdAt + HOLD
            const label = `s${index + 1}`
            timeline.addLabel(label, stationAt)

            timeline.to(
              cam,
              {
                x: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  return frame(L.w, L.h, plate, L.close[index] ?? CLOSE_FALLBACK)
                    .x
                },
                y: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  return frame(L.w, L.h, plate, L.close[index] ?? CLOSE_FALLBACK)
                    .y
                },
                scale: () => layout().close[index] ?? CLOSE_FALLBACK,
                duration: PUSH,
                ease: "power3.inOut",
                onUpdate: write,
              },
              stationAt,
            )
            plates.forEach((node, plateIndex) => {
              timeline.to(
                node,
                {
                  opacity: plateIndex === index ? 1 : IDLE_OPACITY,
                  duration: PUSH,
                  ease: "power3.inOut",
                },
                stationAt,
              )
            })
            // Caption changes at the push-in. Old line fully out before new in.
            timeline.to(
              [caption, marker],
              { opacity: 0, duration: CAPTION_OUT, ease: "power1.in" },
              stationAt,
            )
            timeline.call(
              () => {
                setHolding(false)
                showStep(index)
              },
              undefined,
              stationAt + CAPTION_OUT,
            )
            timeline.to(
              [caption, marker],
              { opacity: 1, duration: CAPTION_IN, ease: "power1.out" },
              stationAt + CAPTION_OUT,
            )
            timeline.call(() => setHolding(true), undefined, holdAt)
            timeline.addLabel(`${label}-hold`, holdAt)
            timeline.to(
              cam,
              {
                x: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  const close = L.close[index] ?? CLOSE_FALLBACK
                  return frame(
                    L.w,
                    L.h,
                    {
                      x: plate.x + plate.w * 0.03,
                      y: plate.y - plate.h * 0.03,
                    },
                    close * 1.03,
                  ).x
                },
                y: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  const close = L.close[index] ?? CLOSE_FALLBACK
                  return frame(
                    L.w,
                    L.h,
                    {
                      x: plate.x + plate.w * 0.03,
                      y: plate.y - plate.h * 0.03,
                    },
                    close * 1.03,
                  ).y
                },
                scale: () => (layout().close[index] ?? CLOSE_FALLBACK) * 1.03,
                duration: HOLD,
                ease: "power1.inOut",
                onUpdate: write,
              },
              holdAt,
            )

            timeline.call(() => setHolding(false), undefined, arcAt)
            timeline.to(
              cam,
              {
                x: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  const next = L.boxes[index + 1]
                  const close = L.close[index] ?? CLOSE_FALLBACK
                  const drifted = frame(
                    L.w,
                    L.h,
                    {
                      x: plate.x + plate.w * 0.03,
                      y: plate.y - plate.h * 0.03,
                    },
                    close * 1.03,
                  )
                  const medium = next
                    ? frame(
                        L.w,
                        L.h,
                        {
                          x: (plate.x + next.x) / 2,
                          y: (plate.y + next.y) / 2,
                        },
                        MEDIUM,
                      )
                    : frame(L.w, L.h, plate, MEDIUM)
                  return bow(drifted, medium).x
                },
                y: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  const next = L.boxes[index + 1]
                  const close = L.close[index] ?? CLOSE_FALLBACK
                  const drifted = frame(
                    L.w,
                    L.h,
                    {
                      x: plate.x + plate.w * 0.03,
                      y: plate.y - plate.h * 0.03,
                    },
                    close * 1.03,
                  )
                  const medium = next
                    ? frame(
                        L.w,
                        L.h,
                        {
                          x: (plate.x + next.x) / 2,
                          y: (plate.y + next.y) / 2,
                        },
                        MEDIUM,
                      )
                    : frame(L.w, L.h, plate, MEDIUM)
                  return bow(drifted, medium).y
                },
                scale: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  const next = L.boxes[index + 1]
                  const close = L.close[index] ?? CLOSE_FALLBACK
                  const drifted = frame(
                    L.w,
                    L.h,
                    {
                      x: plate.x + plate.w * 0.03,
                      y: plate.y - plate.h * 0.03,
                    },
                    close * 1.03,
                  )
                  const medium = next
                    ? frame(
                        L.w,
                        L.h,
                        {
                          x: (plate.x + next.x) / 2,
                          y: (plate.y + next.y) / 2,
                        },
                        MEDIUM,
                      )
                    : frame(L.w, L.h, plate, MEDIUM)
                  return bow(drifted, medium).scale
                },
                duration: ARC / 2,
                ease: "power3.inOut",
                onUpdate: write,
              },
              arcAt,
            )
            timeline.to(
              cam,
              {
                x: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  const next = L.boxes[index + 1]
                  return next
                    ? frame(
                        L.w,
                        L.h,
                        {
                          x: (plate.x + next.x) / 2,
                          y: (plate.y + next.y) / 2,
                        },
                        MEDIUM,
                      ).x
                    : frame(L.w, L.h, plate, MEDIUM).x
                },
                y: () => {
                  const L = layout()
                  const plate = L.boxes[index]!
                  const next = L.boxes[index + 1]
                  return next
                    ? frame(
                        L.w,
                        L.h,
                        {
                          x: (plate.x + next.x) / 2,
                          y: (plate.y + next.y) / 2,
                        },
                        MEDIUM,
                      ).y
                    : frame(L.w, L.h, plate, MEDIUM).y
                },
                scale: MEDIUM,
                duration: ARC / 2,
                ease: "power3.inOut",
                onUpdate: write,
              },
              arcAt + ARC / 2,
            )

            // Carton hand-off only on the act 1 route.
            if (index < CARTON_LAST) {
              timeline.to(
                carton,
                {
                  x: () =>
                    placeCarton(arrival(layout().boxes, index + 1)).x,
                  y: () =>
                    placeCarton(arrival(layout().boxes, index + 1)).y,
                  duration: ARC,
                  ease: "power3.inOut",
                },
                arcAt,
              )
            }

            cursor = arcAt + ARC
          }

          // Act 1: carton journey.
          for (let index = 0; index <= CARTON_LAST; index += 1) {
            pushStation(index)
          }

          // Wide between acts.
          const midWide = cursor
          timeline.addLabel("act-gap", midWide)
          timeline.to(
            cam,
            {
              x: 0,
              y: 0,
              scale: WIDE,
              duration: PULL_OUT,
              ease: "power3.inOut",
              onUpdate: write,
            },
            midWide,
          )
          timeline.to(
            plates,
            { opacity: WIDE_OPACITY, duration: PULL_OUT, ease: "power3.inOut" },
            midWide,
          )
          timeline.to(
            [caption, marker],
            { opacity: 0, duration: CAPTION_OUT, ease: "power1.in" },
            midWide,
          )
          timeline.call(showWide, undefined, midWide + CAPTION_OUT)
          timeline.to(
            carton,
            { opacity: 0.35, duration: 0.4, ease: "power1.out" },
            midWide + 0.3,
          )
          cursor = midWide + PULL_OUT + ACT_GAP

          // Act 2: supporting operations (no carton hand-off).
          for (let index = CARTON_LAST + 1; index < STAGE_COUNT; index += 1) {
            pushStation(index)
          }

          const pullAt = cursor
          timeline.addLabel("pull-end", pullAt)
          timeline.to(
            cam,
            {
              x: 0,
              y: 0,
              scale: WIDE,
              duration: PULL_OUT,
              ease: "power3.inOut",
              onUpdate: write,
            },
            pullAt,
          )
          timeline.to(
            plates,
            { opacity: WIDE_OPACITY, duration: PULL_OUT, ease: "power3.inOut" },
            pullAt,
          )
          timeline.to(
            [caption, marker],
            { opacity: 0, duration: CAPTION_OUT, ease: "power1.in" },
            pullAt,
          )
          timeline.call(showWide, undefined, pullAt + CAPTION_OUT)

          const fadeAt = pullAt + PULL_OUT + WIDE_HOLD
          timeline.addLabel("fade", fadeAt)
          timeline.to(
            [carton, ...plates],
            { opacity: 0, duration: FADE * 0.45, ease: "power1.in" },
            fadeAt,
          )
          timeline.call(
            () => {
              cam.x = 0
              cam.y = 0
              cam.scale = WIDE
              write()
              showWide()
            },
            undefined,
            fadeAt + FADE * 0.5,
          )
          timeline.set(
            carton,
            {
              x: () => placeCarton(arrival(layout().boxes, 0)).x,
              y: () => placeCarton(arrival(layout().boxes, 0)).y,
            },
            fadeAt + FADE * 0.5,
          )
          timeline.to(
            carton,
            { opacity: 1, duration: FADE * 0.5, ease: "power1.out" },
            fadeAt + FADE * 0.5,
          )
          timeline.to(
            plates,
            { opacity: WIDE_OPACITY, duration: FADE * 0.5, ease: "power1.out" },
            fadeAt + FADE * 0.5,
          )

          const stopWatch = watchPlayback(timeline, diagram, setRunning)
          return () => {
            stopWatch()
            timelineRef.current = null
          }
        },
      )
    },
    // Ready flips once. Do not list size — that recreated the timeline mid-loop.
    { scope: rootRef, dependencies: [ready], revertOnUpdate: true },
  )

  return (
    <div
      ref={rootRef}
      className="pointer-events-none relative h-full min-h-0 w-full"
      style={stageVars}
    >
      {/* Diagram fills the panel; caption docks over the lower edge. */}
      <div
        ref={diagramRef}
        className="absolute inset-0 overflow-hidden"
        aria-hidden="true"
      >
        <div
          ref={floorRef}
          className="absolute top-[-30%] left-[-30%] h-[160%] w-[160%]"
        >
          <svg viewBox="0 0 860 320" className="h-full w-full">
            <g fill="var(--hairline-lo)">
              {FLOOR_DOTS.map((dot) => (
                <circle
                  key={`${dot.x}-${dot.y}`}
                  cx={dot.x}
                  cy={dot.y}
                  r="1.15"
                  opacity="0.5"
                />
              ))}
            </g>
          </svg>
        </div>
        <div ref={worldRef} className="absolute inset-0">
          {/* Connectors sit under the plates so they never cross a figure. */}
          <svg className="absolute inset-0 z-0 h-full w-full overflow-visible">
            <path
              ref={solidLinkRef}
              d={paths.solid}
              fill="none"
              stroke="var(--hairline-edge)"
              strokeWidth="1.25"
              strokeLinecap="round"
              strokeOpacity="0.55"
              vectorEffect="non-scaling-stroke"
            />
            <path
              ref={dashedLinkRef}
              d={paths.dashed}
              fill="none"
              stroke="var(--hairline-edge)"
              strokeWidth="1"
              strokeLinecap="round"
              strokeDasharray="4 5"
              strokeOpacity="0.4"
              vectorEffect="non-scaling-stroke"
            />
          </svg>
          {STAGES.map((stage, index) => {
            const Figure = stage.Figure
            const live = !reduced && running && holding && index === focus
            return (
              <div
                key={stage.key}
                ref={(node) => {
                  plateNodes.current[index] = node
                }}
                className="absolute z-[1] -translate-x-1/2 -translate-y-1/2 opacity-70"
                style={{
                  left: "-100%",
                  top: 0,
                  width: 0,
                  zIndex: index === focus ? 6 : 1,
                }}
              >
                <span
                  ref={(node) => {
                    tagNodes.current[index] = node
                  }}
                  className="absolute bottom-full left-1/2 mb-1.5 -translate-x-1/2 rounded-full bg-white/10 px-2.5 py-0.5 text-[11px] font-medium tracking-wide whitespace-nowrap text-white ring-1 ring-white/25"
                >
                  {stage.tag}
                </span>
                {ready ? (
                  <Figure
                    theme="dark"
                    play={live}
                    intensity={PLAY_INTENSITY}
                    label={stage.label}
                  />
                ) : null}
              </div>
            )
          })}
          <div ref={cartonRef} className="absolute top-0 left-0 z-20">
            <CartonMark />
          </div>
        </div>
      </div>
      <div
        className="absolute inset-x-0 bottom-0 z-10 px-8 pb-8 pt-16"
        aria-hidden="true"
      >
        <div className="rounded-2xl bg-[#16324f]/92 px-5 py-4 ring-1 ring-white/25 backdrop-blur-sm">
          <ul
            className={
              reduced ? "space-y-1.5 text-sm leading-6 text-white" : "hidden"
            }
          >
            {STAGES.map((stage) => (
              <li key={stage.key}>
                <span className="font-medium">{stage.tag}</span>
                {" — "}
                {stage.caption}
              </li>
            ))}
          </ul>
          {/* Collapse the text area in wide shots so dots are not under a blank box. */}
          <div
            ref={captionWrapRef}
            className={
              reduced
                ? "hidden"
                : "grid transition-[grid-template-rows] duration-200 ease-out"
            }
            style={{ gridTemplateRows: "0fr" }}
            data-open="0"
          >
            <div className="relative min-h-0 overflow-hidden">
              <p
                className="invisible text-sm leading-6"
                aria-hidden="true"
              >
                {LONGEST_CAPTION}
              </p>
              <p
                ref={captionRef}
                className="absolute inset-x-0 top-0 text-sm leading-6 text-white opacity-0"
                data-login-caption="live"
              />
            </div>
          </div>
          <div className="mt-3 flex items-center justify-between gap-3">
            <span
              ref={markerRef}
              className={
                reduced
                  ? "hidden"
                  : "inline-block min-h-4 min-w-12 text-xs tracking-wide text-white/80 tabular-nums opacity-0"
              }
            />
            <div className="flex gap-1.5">
              {STAGES.map((stage, index) => (
                <span
                  key={stage.key}
                  ref={(node) => {
                    dotNodes.current[index] = node
                  }}
                  className={
                    index === focus
                      ? "size-1.5 rounded-full bg-white"
                      : "size-1.5 rounded-full bg-white/55"
                  }
                />
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

function CartonMark() {
  return (
    <svg viewBox="0 0 48 52" className="h-11 w-11 overflow-visible">
      <polygon
        points="24,4 44,15 24,26 4,15"
        fill="none"
        stroke="var(--hairline-hi)"
        strokeWidth="1.25"
        strokeLinejoin="round"
      />
      <polygon
        points="4,15 24,26 24,46 4,35"
        fill="none"
        stroke="var(--hairline-edge)"
        strokeWidth="1.25"
        strokeLinejoin="round"
      />
      <polygon
        points="44,15 24,26 24,46 44,35"
        fill="none"
        stroke="var(--hairline-mid)"
        strokeWidth="1.25"
        strokeLinejoin="round"
      />
    </svg>
  )
}
