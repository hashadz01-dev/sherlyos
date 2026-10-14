import { useQuery } from "@tanstack/react-query"
import { ShieldOff } from "lucide-react"
import { Navigate, Outlet } from "react-router"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingScreen } from "@/components/shared/LoadingState"
import { Button } from "@/components/ui/button"
import { useAuth } from "@/hooks/use-auth"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

export function RequireAuth() {
  const { loading, session, signOut } = useAuth()
  const userId = session?.user.id
  const profile = useQuery({
    queryKey: ["own-profile-active", userId],
    enabled: Boolean(userId),
    queryFn: async () => {
      const supabase = getSupabaseBrowserClient()
      if (!supabase || !userId) return null
      const result = await supabase
        .from("profiles")
        .select("is_active")
        .eq("id", userId)
        .maybeSingle()
      if (result.error) {
        throw new Error(result.error.message)
      }
      return result.data
    },
  })

  if (loading || (Boolean(userId) && profile.isLoading)) {
    return <LoadingScreen />
  }

  if (!session) {
    return <Navigate to="/login" replace />
  }

  if (profile.data?.is_active === false) {
    return (
      <main className="flex min-h-svh items-center justify-center bg-slate-100 p-6">
        <section className="w-full max-w-md rounded-2xl bg-white ring-1 ring-slate-200/80">
          <EmptyState
            icon={ShieldOff}
            title="This account is inactive"
            description="An administrator has turned off access for this sign-in. Privileged screens stay closed until the account is activated again."
          />
          <div className="flex justify-center pb-8">
            <Button variant="outline" onClick={() => void signOut()}>
              Sign out
            </Button>
          </div>
        </section>
      </main>
    )
  }

  return <Outlet />
}
