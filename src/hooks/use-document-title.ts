import { useLayoutEffect } from "react"

const DESCRIPTION_SELECTOR = 'meta[name="description"]'

/**
 * Sets the browser title and, when a description is given, the meta description.
 * Pages call this so each screen has its own title instead of the static index.html value.
 */
export function useDocumentTitle(title: string, description?: string) {
  useLayoutEffect(() => {
    document.title = `${title} · SherlysOS`
    if (!description) return

    const meta = document.querySelector(DESCRIPTION_SELECTOR)
    if (!meta) return

    const previous = meta.getAttribute("content")
    meta.setAttribute("content", description)
    return () => {
      if (previous) meta.setAttribute("content", previous)
    }
  }, [title, description])
}
