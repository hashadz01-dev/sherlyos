import type { ReactNode } from "react"
import { cn } from "cn"
import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

/**
 * List-filter row. Search and selects share one baseline so an unlabeled
 * search box is not sitting higher than Status / Godown.
 */
export function FilterToolbar({ children }: { children: ReactNode }) {
  return <div className="mb-4 flex flex-wrap items-end gap-3">{children}</div>
}

function FilterField({
  label,
  className,
  children,
}: {
  label: string
  className?: string
  children: ReactNode
}) {
  return (
    <label className={cn("grid gap-1.5 text-sm font-medium", className)}>
      <span className="leading-none">{label}</span>
      {children}
    </label>
  )
}

export function SearchField({
  value,
  onChange,
  label,
}: {
  value: string
  onChange: (value: string) => void
  label: string
}) {
  return (
    <FilterField label={label} className="min-w-[16rem] max-w-xl flex-[1_1_16rem]">
      <Input
        aria-label={label}
        placeholder={label}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="h-10"
      />
    </FilterField>
  )
}

export function FilterSelect({
  label,
  value,
  onChange,
  children,
}: {
  label: string
  value: string
  onChange: (value: string) => void
  children: ReactNode
}) {
  return (
    <FilterField label={label} className="w-full min-w-[12rem] sm:w-56 sm:flex-none">
      <select
        aria-label={label}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="h-10 w-full rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
      >
        {children}
      </select>
    </FilterField>
  )
}

export function ConfirmStatusDialog({
  open,
  name,
  active,
  pending,
  onOpenChange,
  onConfirm,
}: {
  open: boolean
  name: string
  active: boolean
  pending: boolean
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title={active ? `Deactivate ${name}?` : `Activate ${name}?`}
      description={
        active
          ? "The record stays in history and can be activated again. This does not delete it."
          : "The record becomes available for new operational use."
      }
      footer={
        <>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={onConfirm} disabled={pending}>
            {active ? "Deactivate" : "Activate"}
          </Button>
        </>
      }
    />
  )
}