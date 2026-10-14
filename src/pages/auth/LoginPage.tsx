import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Navigate } from "react-router"
import { BrandMark } from "@/components/layout/BrandMark"
import { PasswordField } from "@/components/forms/PasswordField"
import { TextField } from "@/components/forms/TextField"
import { Button } from "@/components/ui/button"
import { LoadingScreen } from "@/components/shared/LoadingState"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { loginSchema, type LoginValues } from "@/lib/validations/login"

export function LoginPage() {
  const { configured, loading, session, signIn } = useAuth()
  const {
    register,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<LoginValues>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: "", password: "" },
  })

  useDocumentTitle("Sign in")

  if (loading) {
    return <LoadingScreen />
  }

  if (session) {
    return <Navigate to="/" replace />
  }

  async function onSubmit(values: LoginValues) {
    const result = await signIn(values.email, values.password)
    if (result.error) {
      setError("root", { message: result.error })
    }
  }

  return (
    <div className="grid min-h-svh bg-background lg:grid-cols-[minmax(0,0.92fr)_minmax(0,1.08fr)]">
      <section className="hidden flex-col justify-between bg-navy px-12 py-12 text-white lg:flex">
        <BrandMark />
        <div className="max-w-md">
          <h1 className="text-4xl font-semibold tracking-tight">
            Operations, kept in one workspace.
          </h1>
          <p className="mt-4 text-base leading-7 text-white/70">
            Orders, deliveries, receiving, verification, and refill will be
            added in later phases. Sign-in uses your Supabase account.
          </p>
        </div>
        <p className="text-sm text-white/50">Sherlys distribution operations</p>
      </section>
      <section className="flex items-center justify-center px-4 py-10">
        <div className="w-full max-w-md">
          <div className="mb-8 lg:hidden">
            <BrandMark tone="dark" />
          </div>
          <h2 className="text-2xl font-semibold tracking-tight">Sign in</h2>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">
            Use the email and password issued for your SherlysOS account.
          </p>
          {configured ? null : (
            <p
              role="status"
              className="mt-5 rounded-xl bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-900 ring-1 ring-amber-200"
            >
              Supabase is not configured. Add VITE_SUPABASE_URL and
              VITE_SUPABASE_PUBLISHABLE_KEY to .env.local, then restart the dev
              server. Sign-in will not create a session until then.
            </p>
          )}
          <form
            className="mt-6 flex flex-col gap-4"
            onSubmit={(event) => void handleSubmit(onSubmit)(event)}
            noValidate
          >
            <TextField
              label="Email"
              type="email"
              autoComplete="email"
              error={errors.email?.message}
              {...register("email")}
            />
            <PasswordField
              label="Password"
              autoComplete="current-password"
              error={errors.password?.message}
              {...register("password")}
            />
            {errors.root?.message ? (
              <p role="alert" className="text-sm text-destructive">
                {errors.root.message}
              </p>
            ) : null}
            <Button
              type="submit"
              size="lg"
              className="mt-2 h-10 w-full"
              disabled={isSubmitting}
            >
              {isSubmitting ? "Signing in" : "Sign in"}
            </Button>
          </form>
          <p className="mt-6 text-sm text-muted-foreground">
            Accounts are issued by an administrator.
          </p>
        </div>
      </section>
    </div>
  )
}
