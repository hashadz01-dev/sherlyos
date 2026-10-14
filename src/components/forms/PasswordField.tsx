import { useState, type ComponentProps } from "react"
import { Eye, EyeOff } from "lucide-react"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"

type PasswordFieldProps = Omit<ComponentProps<typeof TextField>, "type">

export function PasswordField(props: PasswordFieldProps) {
  const [visible, setVisible] = useState(false)

  return (
    <div className="relative">
      <TextField
        {...props}
        type={visible ? "text" : "password"}
        className="h-10 pr-10"
      />
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="absolute top-8 right-1.5"
        aria-label={visible ? "Hide entry" : "Show entry"}
        onClick={() => setVisible((current) => !current)}
      >
        {visible ? <EyeOff /> : <Eye />}
      </Button>
    </div>
  )
}
