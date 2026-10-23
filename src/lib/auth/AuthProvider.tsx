import { useEffect, useMemo, useState, type ReactNode } from "react"
import type { Session } from "@supabase/supabase-js"
import { AuthContext, type SignInResult } from "@/lib/auth/auth-context"
import { setQueryScopeUserId } from "@/lib/query/session-scope"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

const unconfiguredMessage =
  "Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY, then restart the dev server."

export function AuthProvider({ children }: { children: ReactNode }) {
  const supabase = useMemo(() => getSupabaseBrowserClient(), [])
  const configured = supabase !== null
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(configured)
  // Hash query cache by identity before children render so a new user cannot
  // read the previous user's entries even before QueryCacheIsolation clears.
  setQueryScopeUserId(session?.user.id ?? null)

  useEffect(() => {
    if (!supabase) {
      return
    }

    let active = true

    void supabase.auth.getSession().then(({ data, error }) => {
      if (!active) {
        return
      }
      setSession(error ? null : data.session)
      setLoading(false)
    })

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession)
      setLoading(false)
    })

    return () => {
      active = false
      subscription.unsubscribe()
    }
  }, [supabase])

  async function signIn(
    email: string,
    password: string,
  ): Promise<SignInResult> {
    if (!supabase) {
      return { error: unconfiguredMessage }
    }

    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password,
    })

    if (error) {
      return { error: error.message }
    }

    setSession(data.session)
    return { error: null }
  }

  async function signOut() {
    if (supabase) {
      await supabase.auth.signOut()
    }
    setSession(null)
  }

  return (
    <AuthContext
      value={{
        configured,
        loading,
        session,
        signIn,
        signOut,
      }}
    >
      {children}
    </AuthContext>
  )
}
