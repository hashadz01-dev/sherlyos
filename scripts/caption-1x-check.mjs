import { chromium } from "playwright"

const browser = await chromium.launch({ headless: true })
const page = await (
  await browser.newContext({
    viewport: { width: 1440, height: 900 },
    reducedMotion: "no-preference",
  })
).newPage()
await page.goto("http://127.0.0.1:5173/login", { waitUntil: "domcontentloaded" })
await page.addStyleTag({
  content:
    "section.bg-navy{display:block!important;min-height:100vh!important}",
})
await page.waitForFunction(() => window.__loginFilm?.timeline, null, {
  timeout: 60_000,
})
await page.waitForTimeout(1000)
const r = await page.evaluate(async () => {
  const film = window.__loginFilm
  const tl = film.timeline
  const caption = document.querySelector("[data-login-caption='live']")
  film.captionSwaps = []
  tl.timeScale(1)
  tl.pause(0)
  tl.totalTime(0)
  tl.play(0)
  const duration = tl.duration()
  let last = ""
  let dual = 0
  let frames = 0
  const t0 = performance.now()
  while (performance.now() - t0 < duration * 1000 + 2000) {
    const opacity = film.captionOpacity()
    const text = (caption.textContent || "").trim()
    if (opacity > 0.02) {
      if (last && text && text !== last) dual += 1
      if (text) last = text
    } else {
      last = ""
    }
    frames += 1
    if (tl.totalTime() >= duration - 1 / 60) break
    await new Promise((r) => requestAnimationFrame(r))
  }
  tl.pause()
  return {
    dualVisibleFrames: dual,
    frames,
    swapsAtZero: film.captionSwaps.filter((s) => s.opacity === 0).length,
    swapCount: film.captionSwaps.length,
    duration,
  }
})
console.log(JSON.stringify(r, null, 2))
await browser.close()
