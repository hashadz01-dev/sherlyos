import type { ReactNode } from "react"
import { cn } from "cn"

const toneClass = {
  neutral: "bg-slate-100 text-slate-700",
  info: "bg-blue-50 text-blue-700",
  success: "bg-emerald-50 text-emerald-700",
  warning: "bg-amber-50 text-amber-800",
  danger: "bg-red-50 text-red-700",
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
