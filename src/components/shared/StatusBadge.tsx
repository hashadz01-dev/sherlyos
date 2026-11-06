import type { ReactNode } from "react"
import { cn } from "cn"

/** Status colors come from the shared tokens in `src/index.css`. The label text is the caller's. */

const toneClass = {
  neutral: "bg-slate-100 text-slate-700",
  info: "bg-[var(--status-info-bg)] text-[var(--status-info)]",
  success: "bg-[var(--status-success-bg)] text-[var(--status-success)]",
  warning: "bg-[var(--status-warning-bg)] text-[var(--status-warning)]",
  danger: "bg-[var(--status-danger-bg)] text-[var(--status-danger)]",
  quarantine:
    "bg-[var(--status-quarantine-bg)] text-[var(--status-quarantine)]",
} as const

export type StatusTone = keyof typeof toneClass

export function StatusBadge({
  children,
  tone = "neutral",
}: {
  children: ReactNode
  tone?: StatusTone
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        toneClass[tone],
      )}
    >
      {children}
    </span>
  )
}
