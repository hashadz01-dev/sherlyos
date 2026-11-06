import { useEffect, useState } from "react"
import { Link } from "react-router"
import { cn } from "cn"

const logoSrc = "/branding/sherlys-logo.png"

export function BrandMark({
  compact = false,
  tone = "light",
  onNavigate,
}: {
  compact?: boolean
  tone?: "light" | "dark"
  /** Closes the mobile sheet after the logo is used as a home link. */
  onNavigate?: () => void
}) {
  const [logoReady, setLogoReady] = useState(false)

  useEffect(() => {
    const image = new Image()
    image.onload = () => setLogoReady(true)
    image.onerror = () => setLogoReady(false)
    image.src = logoSrc
  }, [])

  return (
    <Link
      to="/"
      onClick={onNavigate}
      className={cn(
        "flex min-w-0 items-center rounded-xl focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand",
        compact ? "gap-2.5" : "gap-3",
        tone === "light" && "focus-visible:outline-white",
      )}
    >
      {logoReady ? (
        <img
          src={logoSrc}
          alt="Sherly's"
          className={cn(
            "rounded-xl bg-white object-contain p-1.5",
            compact ? "h-10 w-16" : "h-14 w-24",
          )}
        />
      ) : null}
      <div className="min-w-0">
        <p
          className={cn(
            "font-semibold tracking-tight",
            compact ? "text-base" : "text-lg",
            tone === "light" ? "text-white" : "text-navy",
          )}
        >
          SherlysOS
        </p>
        {compact ? null : (
          <p
            className={cn(
              "text-xs",
              tone === "light" ? "text-white/60" : "text-muted-foreground",
            )}
          >
            Operations workspace
          </p>
        )}
      </div>
    </Link>
  )
}
