import { createContext } from "react"
import type { Session } from "@supabase/supabase-js"

export type SignInResult = {
  error: string | null
}

export type AuthContextValue = {
  configured: boolean
  loading: boolean
  session: Session | null
  signIn: (email: string, password: string) => Promise<SignInResult>
  signOut: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue | null>(null)
