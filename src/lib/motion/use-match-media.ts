import { useGSAP } from "@gsap/react"
import gsap from "gsap"

gsap.registerPlugin(useGSAP)

type MotionConditions = {
  reduceMotion?: boolean
}

/**
 * jsdom and a few old hosts have no matchMedia. Treat that as reduced
 * motion so counters and pills render their final state instead of throwing.
 */
function ensureMatchMedia() {
  if (typeof window === "undefined" || typeof window.matchMedia === "function") return
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

/**
 * Runs GSAP setup inside matchMedia so a reduced-motion preference
 * reverts the tween and applies the final state immediately.
 * `all` keeps the handler alive when reduced motion is off.
 */
export function useMatchMedia(
  effect: (reduced: boolean) => void,
  dependencies: unknown[],
) {
  useGSAP(
    () => {
      ensureMatchMedia()
      const media = gsap.matchMedia()
      media.add(
        {
          reduceMotion: "(prefers-reduced-motion: reduce)",
          all: "all",
        },
        (context) => {
          const conditions = context.conditions as MotionConditions | undefined
          effect(Boolean(conditions?.reduceMotion))
        },
      )
    },
    { dependencies, revertOnUpdate: true },
  )
}
