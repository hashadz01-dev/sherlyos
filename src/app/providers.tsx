import { useState, type ReactNode } from "react"
import { QueryClientProvider } from "@tanstack/react-query"
import { Toaster } from "@/components/ui/sonner"
import { TooltipProvider } from "@/components/ui/tooltip"
import { AuthProvider } from "@/lib/auth/AuthProvider"
import { QueryCacheIsolation } from "@/lib/query/QueryCacheIsolation"
import { createScopedQueryClient } from "@/lib/query/session-scope"

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => createScopedQueryClient())

  return (
    <QueryClientProvider client={queryClient}>
      <TooltipProvider>
        <AuthProvider>
          <QueryCacheIsolation />
          {children}
          <Toaster />
        </AuthProvider>
      </TooltipProvider>
    </QueryClientProvider>
  )
}
