import { useGSAP } from "@gsap/react"
import gsap from "gsap"
import { useRef, useState, type CSSProperties } from "react"
import {
  DeliveryVan,
  DispatchBay,
  InvoiceNote,
  OrderDesk,
  PackRack,
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

/** Wide, medium, and close framings. Close is 2.4 so a plate fills about 60% of the panel. */
const WIDE = 1
const MEDIUM = 1.35
const CLOSE = 2.4
const MARGIN = 0.06

const ESTABLISH = 3.5
const PUSH = 1.2
const HOLD = 3
const ARC = 1
const PULL_OUT = 1.8
const WIDE_HOLD = 3
const FADE = 1
const LOOP_PAUSE = 1.5

const WIDE_OPACITY = 0.7
const IDLE_OPACITY = 0.35
const PLAY_INTENSITY = 0.5
const CARTON = 44
const DOCK_GAP = 28

const PLATE_COLOR = "#0e1c33"

/**
 * One loop is about 42s: a wide shot, six stations, a pull-back, a reset, and a pause.
 * Station 5 is a draft note only. Nothing in this film is a tax invoice.
 */
const STAGES = [
  {
    key: "order",
    Figure: OrderDesk,
    tag: "1 Order",
    label: "An order desk",
    caption: "Shop order captured.",
  },
  {
    key: "verify",
    Figure: VerifyLedger,
    tag: "2 Verify",
    label: "An accounts ledger",
    caption: "Accounts verifies the order.",
  },
  {
    key: "pack",
    Figure: PackRack,
    tag: "3 Pack",
    label: "A packing rack",
    caption:
      "Cartons reserved from crates and packed. Stock is not deducted yet.",
  },
  {
    key: "dispatch",
    Figure: DispatchBay,
    tag: "4 Dispatch",
    label: "A dispatch bay",
    caption: "Dispatch confirmed. Stock leaves the godown once.",
  },
  {
    key: "invoice",
    Figure: InvoiceNote,
    tag: "5 Invoice note",
    label: "A draft invoice note",
    caption: "Draft invoice note prepared from the confirmed dispatch.",
  },
  {
    key: "deliver",
    Figure: DeliveryVan,
    tag: "6 Deliver",
    label: "A delivery van",
    caption: "Delivered to the shop with proof of delivery.",
  },
] as const

const LONGEST_CAPTION = STAGES[2].caption

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

/**
 * Six plates on a left-to-right zigzag. At scale 1 the route fits the panel
 * with a 6% margin. Plate width is 25% so the close scale of 2.4 fills ~60%.
 */
function buildLayout(width: number, height: number): PlateBox[] {
  const plateW = width * (0.6 / CLOSE)
  const plateH = plateW * 0.8
  const tag = 24
  const marginX = MARGIN * width
  const marginY = MARGIN * height
  let minX = marginX + plateW / 2
  let maxX = width - marginX - plateW / 2
  if (maxX < minX) {
    minX = width / 2
    maxX = width / 2
  }
  let minY = marginY + plateH / 2 + tag
  let maxY = height - marginY - plateH / 2
  if (maxY < minY) {
    const mid = height / 2
    minY = mid
    maxY = mid
  }
  const last = STAGES.length - 1
  const span = maxY - minY
  return STAGES.map((_, index) => {
    const x = minX + (index / last) * (maxX - minX)
    const low = index % 2 === 0
    const y = low ? maxY - span * 0.06 : minY + span * 0.06
    return { x, y, w: plateW, h: plateH }
  })
}

/** Where a ray from the plate centre hits the plate rectangle. */
function edgePoint(plate: PlateBox, toward: Point): Point {
  const dx = toward.x - plate.x
  const dy = toward.y - plate.y
  if (dx === 0 && dy === 0) return { x: plate.x, y: plate.y }
  const sx = dx === 0 ? Infinity : plate.w / 2 / Math.abs(dx)
  const sy = dy === 0 ? Infinity : plate.h / 2 / Math.abs(dy)
  const s = Math.min(sx, sy)
  return { x: plate.x + dx * s, y: plate.y + dy * s }
}

/** A point just outside the plate, so a connector meets the edge and misses the figure. */
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

/** The carton waits on the incoming edge. Plate 1 waits on the edge that leaves toward plate 2. */
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

function connectorPath(boxes: PlateBox[]) {
  const parts: string[] = []
  for (let index = 0; index < boxes.length - 1; index += 1) {
    const from = boxes[index]
    const to = boxes[index + 1]
    if (!from || !to) continue
    const start = outside(from, to)
    const end = outside(to, from)
    parts.push(
      `M${start.x.toFixed(1)} ${start.y.toFixed(1)} L${end.x.toFixed(1)} ${end.y.toFixed(1)}`,
    )
  }
  return parts.join(" ")
}

/**
 * x/y put `point` on the panel centre at this scale.
 * Origin is the world's top-left, so the wide shot is the identity transform.
 */
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

/** A midpoint offset sideways, so the pull-back bows instead of zooming on a straight line. */
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
 * The floor is a sibling of the world and only takes 60% of the camera move,
 * so the grid drifts behind the stations.
 * Transforms stay 2D (`force3D` is off) so a close-up is not promoted to a soft layer.
 */
function applyCamera(world: HTMLElement, floor: HTMLElement, cam: Cam) {
  world.style.transformOrigin = "0 0"
  floor.style.transformOrigin = "0 0"
  world.style.transform = `translate(${cam.x}px, ${cam.y}px) scale(${cam.scale})`
  const scale = 1 + (cam.scale - 1) * 0.6
  floor.style.transform = `translate(${cam.x * 0.6}px, ${cam.y * 0.6}px) scale(${scale})`
}

/**
 * jsdom and a few old hosts have no matchMedia. Treat that as reduced
 * motion so the stage renders one still frame instead of throwing.
 */
function prefersReducedMotion() {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function")
    return true
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches
}

/**
 * Pauses the master timeline, and reports it, while the tab is hidden or
 * the diagram has no box on screen. The focused figure reads that flag and
 * stops too, so only a visible station keeps playing.
 */
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

const FLOOR_DOTS = Array.from({ length: 22 }, (_, row) =>
  Array.from({ length: 30 }, (_, col) => ({
    x: col * 28 + (row % 2 ? 14 : 0),
    y: row * 14,
  })),
).flat()

/**
 * Isometric login film. One GSAP timeline moves the camera; Hairline's React
 * wrapper destroys each figure on unmount, and `useGSAP` reverts the timeline.
 */
export function LoginFlowStage() {
  const rootRef = useRef<HTMLDivElement>(null)
  const diagramRef = useRef<HTMLDivElement>(null)
  const worldRef = useRef<HTMLDivElement>(null)
  const floorRef = useRef<HTMLDivElement>(null)
  const cartonRef = useRef<HTMLDivElement>(null)
  const captionRef = useRef<HTMLParagraphElement>(null)
  const markerRef = useRef<HTMLSpanElement>(null)
  const plateNodes = useRef<Array<HTMLDivElement | null>>([])
  const [size, setSize] = useState({ w: 0, h: 0 })
  const [reduced, setReduced] = useState(prefersReducedMotion)
  const [focus, setFocus] = useState(-1)
  const [holding, setHolding] = useState(false)
  const [running, setRunning] = useState(true)
  const [line, setLine] = useState("")
  const [stepLabel, setStepLabel] = useState("")

  const ready = size.w > 10 && size.h > 10
  const boxes = ready ? buildLayout(size.w, size.h) : []

  useGSAP(
    () => {
      const diagram = diagramRef.current
      const world = worldRef.current
      const floor = floorRef.current
      const carton = cartonRef.current
      const caption = captionRef.current
      const marker = markerRef.current
      if (!diagram || !world || !floor || !carton || !caption || !marker) return
      if (!ready) return

      const plates = plateNodes.current.filter(
        (node): node is HTMLDivElement => node !== null,
      )
      if (plates.length !== STAGES.length) return

      const layout = buildLayout(size.w, size.h)
      const width = size.w
      const height = size.h
      const cam: Cam = { x: 0, y: 0, scale: WIDE }
      const write = () => applyCamera(world, floor, cam)
      const media = gsap.matchMedia()

      // Write the DOM in the same tick the fade-out ends, then let React catch up.
      // A shared element never shows the old line and the new line together.
      const showStep = (index: number) => {
        const stage = STAGES[index]
        const nextLine = stage ? stage.caption : ""
        const nextLabel = stage ? `${index + 1} / 6` : ""
        caption.textContent = nextLine
        marker.textContent = nextLabel
        setFocus(index)
        setLine(nextLine)
        setStepLabel(nextLabel)
      }

      const showWide = () => {
        caption.textContent = ""
        marker.textContent = ""
        setFocus(-1)
        setHolding(false)
        setLine("")
        setStepLabel("")
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
          const shop = layout.length - 1

          if (still) {
            setFocus(shop)
            setHolding(false)
            setRunning(false)
            cam.x = 0
            cam.y = 0
            cam.scale = WIDE
            write()
            gsap.set(plates, { opacity: 1 })
            gsap.set(carton, {
              ...placeCarton(arrival(layout, shop)),
              opacity: 1,
              force3D: false,
            })
            return
          }

          showWide()
          setRunning(true)
          write()
          gsap.set(plates, { opacity: WIDE_OPACITY })
          gsap.set([caption, marker], { opacity: 0 })
          gsap.set(carton, {
            ...placeCarton(arrival(layout, 0)),
            opacity: 1,
            force3D: false,
          })

          const timeline = gsap.timeline({
            paused: true,
            repeat: -1,
            repeatDelay: LOOP_PAUSE,
            defaults: { force3D: false },
          })

          timeline.set(cam, { x: 0, y: 0, scale: WIDE }, 0)
          timeline.call(write, undefined, 0)
          timeline.set(plates, { opacity: WIDE_OPACITY }, 0)
          timeline.set(
            carton,
            { ...placeCarton(arrival(layout, 0)), opacity: 1 },
            0,
          )
          timeline.call(showWide, undefined, 0)

          let cursor = ESTABLISH
          layout.forEach((plate, index) => {
            const close = frame(width, height, plate, CLOSE)
            const drifted = frame(
              width,
              height,
              {
                x: plate.x + plate.w * 0.03,
                y: plate.y - plate.h * 0.03,
              },
              CLOSE * 1.03,
            )
            const stationAt = cursor
            const holdAt = stationAt + PUSH
            const arcAt = holdAt + HOLD

            timeline.to(
              cam,
              {
                ...close,
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
            timeline.to(
              [caption, marker],
              { opacity: 0, duration: 0.2, ease: "power1.in" },
              stationAt,
            )
            timeline.call(
              () => {
                setHolding(false)
                showStep(index)
              },
              undefined,
              stationAt + 0.2,
            )
            timeline.to(
              [caption, marker],
              { opacity: 1, duration: 0.35, ease: "power1.out" },
              stationAt + 0.25,
            )
            timeline.call(() => setHolding(true), undefined, holdAt)
            timeline.to(
              cam,
              {
                ...drifted,
                duration: HOLD,
                ease: "power1.inOut",
                onUpdate: write,
              },
              holdAt,
            )

            const next = layout[index + 1]
            const medium = next
              ? frame(
                  width,
                  height,
                  { x: (plate.x + next.x) / 2, y: (plate.y + next.y) / 2 },
                  MEDIUM,
                )
              : frame(width, height, plate, MEDIUM)
            const bend = bow(drifted, medium)
            timeline.call(() => setHolding(false), undefined, arcAt)
            timeline.to(
              cam,
              {
                ...bend,
                duration: ARC / 2,
                ease: "power3.inOut",
                onUpdate: write,
              },
              arcAt,
            )
            timeline.to(
              cam,
              {
                ...medium,
                duration: ARC / 2,
                ease: "power3.inOut",
                onUpdate: write,
              },
              arcAt + ARC / 2,
            )
            if (next) {
              timeline.to(
                carton,
                {
                  ...placeCarton(arrival(layout, index + 1)),
                  duration: ARC,
                  ease: "power3.inOut",
                },
                arcAt,
              )
            }

            cursor = arcAt + ARC
          })

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
            cursor,
          )
          timeline.to(
            plates,
            { opacity: WIDE_OPACITY, duration: PULL_OUT, ease: "power3.inOut" },
            cursor,
          )
          timeline.to(
            [caption, marker],
            { opacity: 0, duration: 0.2, ease: "power1.in" },
            cursor,
          )
          timeline.call(showWide, undefined, cursor + 0.2)

          const fadeAt = cursor + PULL_OUT + WIDE_HOLD
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
            placeCarton(arrival(layout, 0)),
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

          return watchPlayback(timeline, diagram, setRunning)
        },
      )
    },
    { scope: rootRef, dependencies: [size.w, size.h], revertOnUpdate: true },
  )

  useGSAP(
    () => {
      const diagram = diagramRef.current
      if (!diagram || typeof ResizeObserver !== "function") return
      let timer = 0
      let seen = false
      const measure = () => {
        const width = diagram.clientWidth
        const height = diagram.clientHeight
        if (width < 10 || height < 10) return
        setSize((prev) =>
          prev.w === width && prev.h === height
            ? prev
            : { w: width, h: height },
        )
      }
      const observer = new ResizeObserver(() => {
        // The first box starts the film. Later changes wait so a drag does not rebuild every frame.
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

  return (
    <div
      ref={rootRef}
      className="pointer-events-none flex h-full min-h-0 flex-1 flex-col"
      style={stageVars}
    >
      <div
        ref={diagramRef}
        className="relative min-h-0 flex-1 overflow-hidden"
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
          <svg className="absolute inset-0 h-full w-full overflow-visible">
            <path
              d={connectorPath(boxes)}
              fill="none"
              stroke="var(--hairline-edge)"
              strokeWidth="1.25"
              strokeLinecap="round"
              strokeOpacity="0.55"
              vectorEffect="non-scaling-stroke"
            />
          </svg>
          {STAGES.map((stage, index) => {
            const box = boxes[index]
            const Figure = stage.Figure
            const live = !reduced && running && holding && index === focus
            return (
              <div
                key={stage.key}
                ref={(node) => {
                  plateNodes.current[index] = node
                }}
                className="absolute -translate-x-1/2 -translate-y-1/2 opacity-70"
                style={
                  box
                    ? {
                        left: box.x,
                        top: box.y,
                        width: box.w,
                        zIndex: index === focus ? 6 : 1,
                      }
                    : { left: "-100%", top: 0, width: 0 }
                }
              >
                <span className="absolute bottom-full left-1/2 mb-1.5 -translate-x-1/2 rounded-full bg-white/10 px-2.5 py-0.5 text-[11px] font-medium tracking-wide whitespace-nowrap text-white ring-1 ring-white/25">
                  {stage.tag}
                </span>
                {box ? (
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
      <div className="relative z-10 mt-2 shrink-0" aria-hidden="true">
        <div className="rounded-2xl bg-[#16324f] px-5 py-4 ring-1 ring-white/25">
          <ul
            className={
              reduced ? "space-y-1.5 text-sm leading-6 text-white" : "hidden"
            }
          >
            {STAGES.map((stage) => (
              <li key={stage.key}>{stage.caption}</li>
            ))}
          </ul>
          {/* One caption node. The old line fades out fully before the next line is written. */}
          <div className={reduced ? "hidden" : "relative"}>
            <p className="invisible text-sm leading-6">{LONGEST_CAPTION}</p>
            <p
              ref={captionRef}
              className="absolute inset-x-0 top-0 text-sm leading-6 text-white opacity-0"
            >
              {line}
            </p>
          </div>
          <div className="mt-3 flex items-center justify-between gap-3">
            <span
              ref={markerRef}
              className={
                reduced
                  ? "hidden"
                  : "inline-block min-h-4 min-w-10 text-xs tracking-wide text-white/80 tabular-nums opacity-0"
              }
            >
              {stepLabel}
            </span>
            <div className="flex gap-1.5">
              {STAGES.map((stage, index) => (
                <span
                  key={stage.key}
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

/** Stroke-only isometric cube. Colours come from the Hairline tokens on the stage. */
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
