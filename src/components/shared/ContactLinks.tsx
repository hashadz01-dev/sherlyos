/**
 * Turn a stored phone or email into a real link.
 * Empty values stay plain text so lists do not show a dead link.
 */

function telHref(value: string) {
  const dialable = value.replace(/[^\d+]/g, "")
  return dialable ? `tel:${dialable}` : null
}

export function PhoneLink({
  value,
  empty = "No contact details",
}: {
  value?: string | null
  empty?: string
}) {
  const trimmed = value?.trim() ?? ""
  const href = trimmed ? telHref(trimmed) : null
  if (!href) return <>{empty}</>
  return (
    <a href={href} className="underline-offset-4 hover:underline">
      {trimmed}
    </a>
  )
}

export function EmailLink({
  value,
  empty = "Not recorded",
}: {
  value?: string | null
  empty?: string
}) {
  const trimmed = value?.trim() ?? ""
  if (!trimmed.includes("@")) return <>{trimmed || empty}</>
  return (
    <a href={`mailto:${trimmed}`} className="break-all underline-offset-4 hover:underline">
      {trimmed}
    </a>
  )
}
