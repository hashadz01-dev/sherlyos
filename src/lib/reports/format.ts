/** Date inputs are UTC calendar days with a half-open end bound. */
export function utcDayStart(date: string) {
  if (!date) return null
  return `${date}T00:00:00Z`
}

export function utcDayEndExclusive(date: string) {
  if (!date) return null
  const next = new Date(`${date}T00:00:00Z`)
  next.setUTCDate(next.getUTCDate() + 1)
  return next.toISOString()
}

export function formatUtc(value: string | null | undefined) {
  if (!value) return "—"
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value))
}
