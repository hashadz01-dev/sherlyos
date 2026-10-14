import { useId, type ComponentProps } from "react"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"

type TextFieldProps = {
  label: string
  error?: string
} & ComponentProps<typeof Input>

export function TextField({ label, error, id, ...props }: TextFieldProps) {
  const generatedId = useId()
  const fieldId = id ?? generatedId
  const errorId = `${fieldId}-error`

  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor={fieldId}>{label}</Label>
      <Input
        id={fieldId}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? errorId : undefined}
        className="h-10"
        {...props}
      />
      {error ? (
        <p id={errorId} role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
    </div>
  )
}
