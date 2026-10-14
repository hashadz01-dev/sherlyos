import { useEffect, useState } from "react"
import { cn } from "cn"

const logoSrc = "/branding/sherlys-logo.png"

export function BrandMark({
  compact = false,
  tone = "light",
}: {
  compact?: boolean
  tone?: "light" | "dark"
}) {
  const [logoReady, setLogoReady] = useState(false)

  useEffect(() => {
    const image = new Image()
    image.onload = () => setLogoReady(true)
    image.onerror = () => setLogoReady(false)
    image.src = logoSrc
  }, [])

  return (
    <div className={cn("flex items-center gap-3", compact && "gap-2.5")}>
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
    </div>
  )
}
