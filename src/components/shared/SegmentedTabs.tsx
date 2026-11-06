import { NavLink, useLocation } from "react-router"
import { cn } from "cn"
import { SlidingHighlight } from "@/components/shared/SlidingHighlight"

export type SegmentedTab = {
  to: string
  label: string
  end?: boolean
}

/** Same rule NavLink uses, so the pill and the white label stay on one tab. */
function isSegmentActive(pathname: string, tab: SegmentedTab) {
  if (tab.end) return pathname === tab.to
  return pathname === tab.to || pathname.startsWith(`${tab.to}/`)
}

/**
 * Route tabs with one sliding indicator. `end` is forwarded so a parent
 * route does not stay active on its children.
 */
export function SegmentedTabs({
  label,
  items,
}: {
  label: string
  items: SegmentedTab[]
}) {
  const { pathname } = useLocation()

  return (
    <nav aria-label={label} className="mb-6">
      <SlidingHighlight
        layoutKey={`${pathname}:${items.map((item) => item.to).join("|")}`}
        className="inline-flex max-w-full flex-wrap gap-1 rounded-2xl bg-white p-1 ring-1 ring-slate-200/80"
        highlightClassName="bg-brand shadow-[inset_0_1px_0_rgba(255,255,255,0.35)]"
      >
        {items.map((item) => {
          const active = isSegmentActive(pathname, item)
          return (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              data-active={active ? "true" : "false"}
              className={cn(
                "relative z-10 rounded-xl px-3 py-1.5 text-sm font-medium text-slate-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand",
                active && "text-white",
              )}
            >
              {item.label}
            </NavLink>
          )
        })}
      </SlidingHighlight>
    </nav>
  )
}
