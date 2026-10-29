/** Chrome reports several strings when a hashed Vite chunk 404s after a deploy. */
const STALE_CHUNK_MESSAGE =
  /Failed to fetch dynamically imported module|Importing a module script failed|error loading dynamically imported module|Unable to preload CSS/i

const RELOAD_FLAG = "sherlysos-chunk-reload"

export function isStaleChunkError(error: unknown) {
  const message =
    error instanceof Error
      ? error.message
      : typeof error === "object" && error && "message" in error
        ? String((error as { message: unknown }).message)
        : String(error)
  return STALE_CHUNK_MESSAGE.test(message)
}

/** One reload per tab so a still-missing file cannot loop. */
export function reloadOnceForStaleChunk() {
  if (typeof window === "undefined" || typeof sessionStorage === "undefined") {
    return false
  }
  if (sessionStorage.getItem(RELOAD_FLAG) === "1") {
    return false
  }
  sessionStorage.setItem(RELOAD_FLAG, "1")
  window.location.reload()
  return true
}
