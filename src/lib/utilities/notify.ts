import { toast } from "sonner"

export const notify = {
  info(message: string) {
    toast.info(message)
  },
  success(message: string) {
    toast.success(message)
  },
  error(message: string) {
    toast.error(message)
  },
}
