/**
 * Polish verification: 1× caption opacity sample for one loop, and one
 * wall-clock 1× loop with dropped-frame counting.
 */
import { chromium } from "playwright"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const outDir = path.join(root, "drafts", "login-film-verify")
const baseURL = process.env.LOGIN_FILM_URL ?? "http://127.0.0.1:5173"
fs.mkdirSync(outDir, { recursive: true })

async function waitForFilm(page) {
  await page.goto(`${baseURL}/login`, { waitUntil: "domcontentloaded" })
  await page.addStyleTag({
    content: `
      section.bg-navy { display: block !important; position: relative !important; min-height: 100vh !important; }
      .grid.min-h-svh { grid-template-columns: minmax(0,0.92fr) minmax(0,1.08fr) !important; }
    `,
  })
  await page.waitForFunction(
    () =>
      Boolean(window.__loginFilm?.timeline) &&
      document.querySelectorAll("[data-hairline]").length >= 10,
    null,
    { timeout: 60_000 },
  )
}

const browser = await chromium.launch({ headless: true })
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
  reducedMotion: "no-preference",
})
const page = await context.newPage()
page.setDefaultTimeout(90_000)

const report = { at: new Date().toISOString(), caption1x: null, wallLoop1x: null, errors: [] }

try {
  await waitForFilm(page)

  console.log("[polish] caption 1x sample")
  report.caption1x = await page.evaluate(async () => {
    const film = window.__loginFilm
    const tl = film.timeline
    const caption = document.querySelector("[data-login-caption='live']")
    film.captionSwaps = []
    tl.timeScale(1)
    tl.pause(0)
    tl.totalTime(0)
    tl.play(0)

    const duration = tl.duration()
    let lastTextWhileVisible = ""
    let dualVisibleFrames = 0
    let frames = 0
    const wall0 = performance.now()
    // One full iteration at 1×, plus a little slack.
    while (performance.now() - wall0 < duration * 1000 + 4000) {
      const opacity = film.captionOpacity()
      const text = (caption.textContent || "").trim()
      if (opacity > 0.02) {
        if (lastTextWhileVisible && text && text !== lastTextWhileVisible) {
          dualVisibleFrames += 1
        }
        if (text) lastTextWhileVisible = text
      } else {
        lastTextWhileVisible = ""
      }
      frames += 1
      if (tl.totalTime() >= duration - 1 / 60) break
      await new Promise((r) => requestAnimationFrame(r))
    }
    tl.pause()
    return {
      dualVisibleFrames,
      frames,
      duration,
      wallMs: Math.round(performance.now() - wall0),
      swapsAtZero: film.captionSwaps.filter((s) => s.opacity === 0).length,
      swapCount: film.captionSwaps.length,
    }
  })

  // Wide-shot card slim check
  report.slimCard = await page.evaluate(() => {
    const film = window.__loginFilm
    film.seek("wide0")
    const card = document.querySelector("[data-slim]")
    const wrap = document.querySelector("[data-open]")
    const rect = card?.getBoundingClientRect()
    return {
      slim: card?.dataset.slim ?? null,
      open: wrap?.dataset.open ?? null,
      cardHeight: rect ? Math.round(rect.height) : null,
      paddingClass: card?.className ?? null,
    }
  })

  console.log("[polish] wall-clock 1x loop + dropped frames")
  report.wallLoop1x = await page.evaluate(async () => {
    const film = window.__loginFilm
    const tl = film.timeline
    tl.timeScale(1)
    tl.pause(0)
    tl.totalTime(0)
    tl.play(0)
    const duration = tl.duration()
    const expectedMs = duration * 1000
    let frames = 0
    let dropped = 0
    let last = performance.now()
    const wall0 = last
    const FRAME = 1000 / 60
    while (performance.now() - wall0 < expectedMs + 3000) {
      const now = performance.now()
      const dt = now - last
      // Count a drop when the gap is > 1.5 frames (browser jank / background).
      if (frames > 0 && dt > FRAME * 1.5) {
        dropped += Math.max(1, Math.round(dt / FRAME) - 1)
      }
      last = now
      frames += 1
      if (tl.totalTime() >= duration - 1 / 120) break
      await new Promise((r) => requestAnimationFrame(r))
    }
    tl.pause()
    return {
      duration,
      frames,
      dropped,
      wallMs: Math.round(performance.now() - wall0),
      expectedMs: Math.round(expectedMs),
      expectedFramesAt60: Math.round(duration * 60),
    }
  })
} catch (err) {
  report.errors.push(String(err && err.stack ? err.stack : err))
  console.error(err)
} finally {
  await browser.close()
}

const out = path.join(outDir, "polish-report.json")
fs.writeFileSync(out, JSON.stringify(report, null, 2))
console.log(JSON.stringify(report, null, 2))
console.log(`Wrote ${out}`)
