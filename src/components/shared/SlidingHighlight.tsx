import { useRef, type ReactNode } from "react"
import gsap from "gsap"
import { cn } from "cn"
import { useMatchMedia } from "@/lib/motion/use-match-media"

/**
 * Decorative pill that follows `[data-active="true"]`.
 * Reduced motion sets the final box in the same frame instead of sliding.
 */
export function SlidingHighlight({
  children,
  className,
  highlightClassName,
  layoutKey,
}: {
  children: ReactNode
  className?: string
  highlightClassName?: string
  layoutKey: string
}) {
  const rootRef = useRef<HTMLDivElement>(null)
  const highlightRef = useRef<HTMLSpanElement>(null)

  useMatchMedia((reduced) => {
    const root = rootRef.current
    const highlight = highlightRef.current
    if (!root || !highlight) return

    const place = () => {
      const active = root.querySelector<HTMLElement>("[data-active='true']")
      if (!active) {
        gsap.set(highlight, { autoAlpha: 0 })
        return
      }
      const box = {
        x: active.offsetLeft,
        y: active.offsetTop,
        width: active.offsetWidth,
        height: active.offsetHeight,
        autoAlpha: 1,
      }
      if (reduced) {
        gsap.set(highlight, box)
        return
      }
      gsap.to(highlight, { ...box, duration: 0.28, ease: "power2.out", overwrite: "auto" })
    }

    place()
    if (typeof ResizeObserver !== "function") return
    const observer = new ResizeObserver(place)
    observer.observe(root)
    return () => observer.disconnect()
  }, [layoutKey])

  return (
    <div ref={rootRef} className={cn("relative", className)}>
      <span
        ref={highlightRef}
        aria-hidden="true"
        className={cn(
          "pointer-events-none absolute top-0 left-0 z-0 rounded-xl opacity-0",
          highlightClassName,
        )}
      />
      {children}
    </div>
  )
}
