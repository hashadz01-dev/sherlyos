import { useGSAP } from "@gsap/react"
import {
  Basket,
  Hub,
  Laptop,
  Lockers,
  Stack,
} from "@lucasmarkes/hairline/react"
import gsap from "gsap"
import { useRef, useState, type CSSProperties, type ComponentType } from "react"

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

/**
 * One pass of the film: five stages, then a fade back to the first plate.
 * The extra 2s is `repeatDelay`, so a full cycle is about 24s.
 */
const STAGE_SECONDS = 4
const TRAVEL_SECONDS = 1.6
const FADE_SECONDS = 1.5
const LOOP_PAUSE_SECONDS = 2
const ACTIVE_INTENSITY = 0.4
const DISPATCH_INDEX = 3

const VIEW_W = 640
const VIEW_H = 640

/**
 * The carton rides the near corner of each plate. Plate centers sit up-left
 * of these docks so the cube stays on the connector instead of covering the figure.
 */
const DOCKS = [
  { x: 188, y: 520 },
  { x: 278, y: 430 },
  { x: 368, y: 340 },
  { x: 458, y: 250 },
  { x: 548, y: 160 },
] as const

const PLATE_SHIFT = { x: -64, y: -48 }

const STAGES: Array<{
  key: string
  Figure: ComponentType<{
    theme?: "dark"
    play?: boolean
    intensity?: number
    label?: string
    className?: string
  }>
  label: string
  caption: string
}> = [
  {
    key: "order",
    Figure: Laptop,
    label: "A laptop",
    caption: "Shop order captured.",
  },
  {
    key: "verify",
    Figure: Stack,
    label: "A stack of pages",
    caption: "Accounts verifies the order.",
  },
  {
    key: "pack",
    Figure: Basket,
    label: "A packing basket",
    caption: "Cartons reserved and packed. Stock is not deducted yet.",
  },
  {
    key: "dispatch",
    Figure: Lockers,
    label: "A bank of lockers",
    caption: "Dispatch confirmed. Stock leaves the godown once.",
  },
  {
    key: "deliver",
    Figure: Hub,
    label: "A hub linked to shops",
    caption: "Delivered to the shop.",
  },
]

const PLATE_COLOR = "#0e1c33"

const stageVars = {
  "--hairline-plate": PLATE_COLOR,
  "--hairline-hi": "#e8eef6",
  "--hairline-edge": "#a9b8c9",
  "--hairline-mid": "#7b8da3",
  "--hairline-lo": "#415066",
} as CSSProperties

const travelPath = DOCKS.map(
  (dock, index) => `${index === 0 ? "M" : "L"}${dock.x} ${dock.y}`,
).join(" ")

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
 * The connector SVG is stretched to the panel (`preserveAspectRatio: none`),
 * and MotionPathPlugin aligns in the path's own box, so the cube missed the
 * line. These are the same viewBox docks the plates use, in diagram pixels.
 */
function dockPoint(diagram: HTMLElement, dock: { x: number; y: number }) {
  const carton = 44
  return {
    x: (dock.x / VIEW_W) * diagram.clientWidth - carton / 2,
    y: (dock.y / VIEW_H) * diagram.clientHeight - carton / 2,
  }
}

/**
 * Pauses while the tab is hidden or the diagram has no box on screen.
 * Returns the detach function for the GSAP context revert.
 */
function watchPlayback(timeline: gsap.core.Timeline, node: HTMLElement) {
  const sync = () => {
    const box = node.getBoundingClientRect()
    const offscreen =
      box.width === 0 ||
      box.height === 0 ||
      box.bottom <= 0 ||
      box.top >= window.innerHeight
    if (document.visibilityState === "hidden" || offscreen) timeline.pause()
    else timeline.resume()
  }

  const onVisibility = () => sync()
  document.addEventListener("visibilitychange", onVisibility)

  let observer: IntersectionObserver | null = null
  if (typeof IntersectionObserver === "function") {
    observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry) return
        if (document.visibilityState === "hidden" || !entry.isIntersecting)
          timeline.pause()
        else timeline.resume()
      },
      { threshold: 0.05 },
    )
    observer.observe(node)
  }

  sync()
  return () => {
    document.removeEventListener("visibilitychange", onVisibility)
    observer?.disconnect()
  }
}

/**
 * Isometric login film. Hairline's React wrapper destroys each figure on
 * unmount; `useGSAP` reverts the timeline, the matchMedia setup, and the
 * visibility listeners in the same pass.
 */
export function LoginFlowStage() {
  const rootRef = useRef<HTMLDivElement>(null)
  const diagramRef = useRef<HTMLDivElement>(null)
  const pathRef = useRef<SVGPathElement>(null)
  const cartonRef = useRef<HTMLDivElement>(null)
  const plateNodes = useRef<Array<HTMLDivElement | null>>([])
  const captionNodes = useRef<Array<HTMLParagraphElement | null>>([])
  const [layoutKey, setLayoutKey] = useState(0)
  const [reduced, setReduced] = useState(prefersReducedMotion)
  const [active, setActive] = useState(0)

  useGSAP(
    () => {
      const diagram = diagramRef.current
      const carton = cartonRef.current
      if (!diagram || !carton) return

      const plates = plateNodes.current.filter(
        (node): node is HTMLDivElement => node !== null,
      )
      const captions = captionNodes.current.filter(
        (node): node is HTMLParagraphElement => node !== null,
      )
      const media = gsap.matchMedia()

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
            setActive(DISPATCH_INDEX)
            gsap.set(plates, { opacity: 1 })
            gsap.set(captions, { opacity: 1 })
            gsap.set(carton, {
              ...dockPoint(diagram, DOCKS[DISPATCH_INDEX]),
              opacity: 1,
            })
            return
          }

          setActive(0)
          gsap.set(carton, { ...dockPoint(diagram, DOCKS[0]), opacity: 1 })
          plates.forEach((plate, index) => {
            gsap.set(plate, { opacity: index === 0 ? 1 : 0.55 })
          })
          captions.forEach((caption, index) => {
            gsap.set(caption, { opacity: index === 0 ? 1 : 0 })
          })

          const timeline = gsap.timeline({
            paused: true,
            repeat: -1,
            repeatDelay: LOOP_PAUSE_SECONDS,
            defaults: { ease: "power1.inOut" },
          })

          STAGES.forEach((_, index) => {
            const at = index * STAGE_SECONDS
            timeline.call(() => setActive(index), undefined, at)
            plates.forEach((plate, plateIndex) => {
              timeline.to(
                plate,
                { opacity: plateIndex === index ? 1 : 0.55, duration: 0.45 },
                at,
              )
            })
            captions.forEach((caption, captionIndex) => {
              timeline.to(
                caption,
                { opacity: captionIndex === index ? 1 : 0, duration: 0.5 },
                at,
              )
            })
            if (index < STAGES.length - 1) {
              timeline.to(
                carton,
                {
                  ...dockPoint(diagram, DOCKS[index + 1]),
                  duration: TRAVEL_SECONDS,
                },
                at + STAGE_SECONDS - TRAVEL_SECONDS,
              )
            }
          })

          const resetAt = STAGES.length * STAGE_SECONDS
          const fadeOut = FADE_SECONDS * 0.4
          timeline.to(carton, { opacity: 0, duration: fadeOut }, resetAt)
          timeline.to(captions, { opacity: 0, duration: fadeOut }, resetAt)
          timeline.set(
            carton,
            dockPoint(diagram, DOCKS[0]),
            resetAt + fadeOut,
          )
          timeline.call(() => setActive(0), undefined, resetAt + fadeOut)
          timeline.to(
            carton,
            { opacity: 1, duration: FADE_SECONDS - fadeOut },
            resetAt + fadeOut,
          )
          timeline.to(
            captions[0],
            { opacity: 1, duration: FADE_SECONDS - fadeOut },
            resetAt + fadeOut,
          )
          plates.forEach((plate, index) => {
            timeline.to(
              plate,
              {
                opacity: index === 0 ? 1 : 0.55,
                duration: FADE_SECONDS - fadeOut,
              },
              resetAt + fadeOut,
            )
          })

          return watchPlayback(timeline, diagram)
        },
      )
    },
    { scope: rootRef, dependencies: [layoutKey], revertOnUpdate: true },
  )

  useGSAP(
    () => {
      const diagram = diagramRef.current
      if (!diagram || typeof ResizeObserver !== "function") return
      let timer = 0
      let ready = false
      const observer = new ResizeObserver(() => {
        // The first callback is the initial box. Rebuilding there restarts the film immediately.
        if (!ready) {
          ready = true
          return
        }
        window.clearTimeout(timer)
        timer = window.setTimeout(() => setLayoutKey((value) => value + 1), 200)
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
        className="relative min-h-0 flex-1"
        aria-hidden="true"
      >
        <svg
          className="absolute inset-0 h-full w-full"
          viewBox={`0 0 ${VIEW_W} ${VIEW_H}`}
          preserveAspectRatio="none"
        >
          <path
            ref={pathRef}
            d={travelPath}
            fill="none"
            stroke="var(--hairline-edge)"
            strokeWidth="1.25"
            strokeLinecap="round"
            strokeLinejoin="round"
            vectorEffect="non-scaling-stroke"
          />
        </svg>
        {STAGES.map((stage, index) => {
          const dock = DOCKS[index]
          const Figure = stage.Figure
          const live = !reduced && index === active
          return (
            <div
              key={stage.key}
              ref={(node) => {
                plateNodes.current[index] = node
              }}
              className={
                index === 0
                  ? "absolute w-[22%] -translate-x-1/2 -translate-y-1/2"
                  : "absolute w-[22%] -translate-x-1/2 -translate-y-1/2 opacity-[0.55]"
              }
              style={{
                left: `${((dock.x + PLATE_SHIFT.x) / VIEW_W) * 100}%`,
                top: `${((dock.y + PLATE_SHIFT.y) / VIEW_H) * 100}%`,
                zIndex: STAGES.length - index,
              }}
            >
              <Figure
                theme="dark"
                play={live}
                intensity={live ? ACTIVE_INTENSITY : 0}
                label={stage.label}
              />
            </div>
          )
        })}
        <div ref={cartonRef} className="absolute left-0 top-0 z-10">
          <CartonMark />
        </div>
      </div>
      <div className="relative z-10 mt-2 shrink-0" aria-hidden="true">
        <div className="rounded-2xl bg-[#16324f] px-5 py-4 ring-1 ring-white/25">
          {reduced ? (
            <ul className="space-y-1.5 text-sm leading-6 text-white">
              {STAGES.map((stage) => (
                <li key={stage.key}>{stage.caption}</li>
              ))}
            </ul>
          ) : null}
          {/* Captions stay mounted so a media-query change can fade them without a second render. */}
          <div className={reduced ? "hidden" : "relative"}>
            <p className="invisible text-sm leading-6">
              Cartons reserved and packed. Stock is not deducted yet.
            </p>
            {STAGES.map((stage, index) => (
              <p
                key={stage.key}
                ref={(node) => {
                  captionNodes.current[index] = node
                }}
                className={
                  index === 0
                    ? "absolute inset-x-0 top-0 text-sm leading-6 text-white"
                    : "absolute inset-x-0 top-0 text-sm leading-6 text-white opacity-0"
                }
              >
                {stage.caption}
              </p>
            ))}
          </div>
          <div className="mt-3 flex gap-1.5">
            {STAGES.map((stage, index) => (
              <span
                key={stage.key}
                className={
                  index === (reduced ? DISPATCH_INDEX : active)
                    ? "size-1.5 rounded-full bg-white"
                    : "size-1.5 rounded-full bg-white/55"
                }
              />
            ))}
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
