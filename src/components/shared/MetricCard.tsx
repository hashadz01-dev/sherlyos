import { useRef } from "react"
import type { LucideIcon } from "lucide-react"
import gsap from "gsap"
import { useMatchMedia } from "@/lib/motion/use-match-media"

/**
 * Operational count. An unauthorized or missing value stays an em dash
 * and is never drawn as 0. Counting is decorative; the real value is in
 * the screen-reader text from the first paint. Pass `count={false}` for
 * document amounts so those figures do not tick.
 */
export function MetricCard({
  label,
  icon: Icon,
  hint,
  value,
  unavailable,
  count = true,
}: {
  label: string
  icon: LucideIcon
  hint: string
  value?: number | string | null
  unavailable?: boolean
  count?: boolean
}) {
  const showUnavailable = unavailable || value === null || value === undefined
  const visualRef = useRef<HTMLSpanElement>(null)
  const canCount = count && !showUnavailable && typeof value === "number"

  useMatchMedia((reduced) => {
    const node = visualRef.current
    if (!node || !canCount || typeof value !== "number") return
    const proxy = { n: reduced ? value : 0 }
    node.textContent = String(proxy.n)
    gsap.to(proxy, {
      n: value,
      duration: reduced ? 0 : 0.7,
      ease: "power2.out",
      snap: { n: 1 },
      onUpdate: () => {
        node.textContent = String(proxy.n)
      },
    })
  }, [canCount, value])

  return (
    <article className="rounded-2xl bg-white px-5 py-4 shadow-[0_1px_2px_rgba(15,23,42,0.04),0_12px_32px_-24px_rgba(14,28,51,0.45)] ring-1 ring-slate-200/80">
      <div className="flex items-start justify-between gap-3">
        <h2 className="text-sm font-medium text-slate-500">{label}</h2>
        <Icon className="size-4 text-slate-400" aria-hidden="true" />
      </div>
      <p className="mt-5 text-4xl font-semibold tracking-tight text-slate-950 tabular-nums">
        {showUnavailable ? (
          <>
            <span aria-hidden="true">—</span>
            <span className="sr-only">Not available</span>
          </>
        ) : (
          <>
            <span className="sr-only">{value}</span>
            <span ref={visualRef} aria-hidden="true">
              {value}
            </span>
          </>
        )}
      </p>
      <p className="mt-2 text-xs text-slate-500">{hint}</p>
    </article>
  )
}
