import { RouterProvider } from "react-router"
import { router } from "@/app/router"
import { Providers } from "@/app/providers"

export function App() {
  return (
    <Providers>
      <RouterProvider router={router} />
    </Providers>
  )
}
