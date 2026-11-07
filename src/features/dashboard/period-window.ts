import type { DashboardPeriodSeriesPoint } from "@/lib/reports/api"

/** Maximum half-open reporting span enforced by the period RPC. */
export const PERIOD_MAX_DAYS = 93

export type PeriodPresetId = "today" | "7d" | "30d" | "custom"

export type PeriodWindow = {
  preset: PeriodPresetId
  /** Inclusive UTC calendar start YYYY-MM-DD */
  fromDate: string
  /** Inclusive UTC calendar end YYYY-MM-DD */
  toDate: string
  /** Inclusive bound for RPC */
  windowFrom: string
  /** Exclusive bound for RPC */
  windowTo: string
}

/** UTC calendar day YYYY-MM-DD. */
export function utcYmd(date: Date) {
  return date.toISOString().slice(0, 10)
}

export function todayUtc() {
  const d = new Date()
  d.setUTCHours(0, 0, 0, 0)
  return utcYmd(d)
}

function parseUtcYmd(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new Error("Date must be YYYY-MM-DD (UTC calendar day)")
  }
  const parsed = new Date(`${value}T00:00:00.000Z`)
  if (Number.isNaN(parsed.getTime()) || utcYmd(parsed) !== value) {
    throw new Error("Invalid UTC calendar day")
  }
  return parsed
}

/** Exclusive end instant: midnight after the inclusive calendar end day. */
export function exclusiveEndUtc(inclusiveToDate: string) {
  const start = parseUtcYmd(inclusiveToDate)
  start.setUTCDate(start.getUTCDate() + 1)
  return start.toISOString()
}

export function inclusiveStartUtc(fromDate: string) {
  return parseUtcYmd(fromDate).toISOString()
}

/** Calendar-day span for an inclusive from/to pair (today→today = 1). */
export function inclusiveDayCount(fromDate: string, toDate: string) {
  const from = parseUtcYmd(fromDate).getTime()
  const to = parseUtcYmd(toDate).getTime()
  if (to < from) {
    throw new Error("date range end must be after start")
  }
  return Math.floor((to - from) / 86_400_000) + 1
}

/**
 * Build a half-open UTC RPC window from calendar dates.
 * Rejects inverted ranges and spans longer than 93 days.
 */
export function buildPeriodWindow(args: {
  preset: PeriodPresetId
  fromDate: string
  toDate: string
}): PeriodWindow {
  const dayCount = inclusiveDayCount(args.fromDate, args.toDate)
  if (dayCount > PERIOD_MAX_DAYS) {
    throw new Error(`reporting window cannot exceed ${PERIOD_MAX_DAYS} days`)
  }
  return {
    preset: args.preset,
    fromDate: args.fromDate,
    toDate: args.toDate,
    windowFrom: inclusiveStartUtc(args.fromDate),
    windowTo: exclusiveEndUtc(args.toDate),
  }
}

export function periodWindowForPreset(
  preset: Exclude<PeriodPresetId, "custom">,
  today = todayUtc(),
): PeriodWindow {
  const end = parseUtcYmd(today)
  if (preset === "today") {
    return buildPeriodWindow({
      preset,
      fromDate: today,
      toDate: today,
    })
  }
  const start = new Date(end)
  start.setUTCDate(start.getUTCDate() - (preset === "7d" ? 6 : 29))
  return buildPeriodWindow({
    preset,
    fromDate: utcYmd(start),
    toDate: today,
  })
}

/**
 * Zero-fill sparse RPC series for an authorized metric only.
 * Never call for unauthorized / unavailable metrics.
 */
export function zeroFillSeries(
  window: Pick<PeriodWindow, "fromDate" | "toDate">,
  sparse: DashboardPeriodSeriesPoint[],
): DashboardPeriodSeriesPoint[] {
  const byDay = new Map(sparse.map((point) => [point.day, point.count]))
  const cursor = parseUtcYmd(window.fromDate)
  const end = parseUtcYmd(window.toDate)
  const filled: DashboardPeriodSeriesPoint[] = []
  while (cursor.getTime() <= end.getTime()) {
    const day = utcYmd(cursor)
    filled.push({ day, count: byDay.get(day) ?? 0 })
    cursor.setUTCDate(cursor.getUTCDate() + 1)
  }
  return filled
}
