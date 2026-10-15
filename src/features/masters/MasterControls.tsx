import type { ReactNode } from "react"
import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

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
    <Input
      aria-label={label}
      placeholder={label}
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className="h-10"
    />
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
    <select
      aria-label={label}
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className="h-10 w-full rounded-lg border border-input bg-transparent px-2.5 text-sm"
    >
      {children}
    </select>
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