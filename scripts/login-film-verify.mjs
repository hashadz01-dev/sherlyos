/**
 * Login-film verification for ui/skin-and-motion.
 * Uses the running Vite host (default 127.0.0.1:5173). Writes screenshots and
 * a JSON report under drafts/login-film-verify/.
 */
import { chromium } from "playwright"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(__dirname, "..")
const outDir = path.join(root, "drafts", "login-film-verify")
const baseURL = process.env.LOGIN_FILM_URL ?? "http://127.0.0.1:5173"

fs.mkdirSync(outDir, { recursive: true })

const STAGES = [
  "order",
  "verify",
  "pack",
  "dispatch",
  "invoice",
  "deliver",
  "stock-in",
  "daily-count",
  "damage",
  "accounts",
]

function shotPath(name) {
  return path.join(outDir, `${name}.png`)
}

async function waitForFilm(page) {
  // Vite HMR keeps a websocket open, so networkidle never settles.
  await page.goto(`${baseURL}/login`, { waitUntil: "domcontentloaded" })
  // Film column is CSS-hidden below 900px; force it for narrow verification sizes.
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
    { timeout: 45_000 },
  )
}

async function seekLabel(page, label) {
  // GSAP seek suppresses callbacks by default; probe.seek(..., false) + write().
  await page.evaluate((name) => {
    const film = window.__loginFilm
    if (!film?.seek) throw new Error("no film seek")
    return film.seek(name)
  }, label)
  await page.waitForTimeout(80)
}

async function captureStationShots(page, sizeName, viewport) {
  await page.setViewportSize(viewport)
  await waitForFilm(page)
  await page.evaluate(() => {
    const film = window.__loginFilm
    film.timeline.pause()
    film.timeline.seek("wide0")
  })
  await page.waitForTimeout(120)
  await page.locator("section.bg-navy").screenshot({
    path: shotPath(`${sizeName}-wide`),
    type: "png",
  })

  for (let i = 0; i < STAGES.length; i += 1) {
    const key = STAGES[i]
    const label = `s${i + 1}`
    const hold = `s${i + 1}-hold`
    // Mid push-in: halfway through the push toward the station.
    await page.evaluate((name) => {
      const film = window.__loginFilm
      const t = film.timeline.labels[name]
      film.seek(t + 0.6)
    }, label)
    await page.waitForTimeout(60)
    await page.locator("section.bg-navy").screenshot({
      path: shotPath(`${sizeName}-mid-${String(i + 1).padStart(2, "0")}-${key}`),
      type: "png",
    })
    await seekLabel(page, hold)
    await page.locator("section.bg-navy").screenshot({
      path: shotPath(`${sizeName}-close-${String(i + 1).padStart(2, "0")}-${key}`),
      type: "png",
    })
  }
}

async function captureFigures(page) {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto(`${baseURL}/dev/login-figures`, { waitUntil: "domcontentloaded" })
  await page.waitForSelector("figure", { timeout: 20_000 })
  const figures = page.locator("figure")
  const count = await figures.count()
  for (let i = 0; i < count; i += 1) {
    const fig = figures.nth(i)
    const title = ((await fig.locator("figcaption").textContent()) || `fig-${i}`)
      .trim()
      .replace(/\s+/g, "-")
      .toLowerCase()
    await fig.scrollIntoViewIfNeeded()
    await page.waitForTimeout(40)
    await fig.screenshot({ path: shotPath(`figure-${title}`), type: "png" })
  }
  return count
}

async function firstLoopWithResize(page) {
  await page.setViewportSize({ width: 840, height: 660 })
  await waitForFilm(page)

  // Bridge: in-page sampler awaits this so the mid-loop resize is real.
  await page.exposeFunction("__loginFilmDoResize", async () => {
    await page.setViewportSize({ width: 860, height: 670 })
    return true
  })

  const live = await page.evaluate(async () => {
    const film = window.__loginFilm
    film.captionSwaps = []
    const tl = film.timeline
    // Infinite-repeat timelines: use totalTime, not time(), for wrap detection.
    tl.timeScale(8)
    tl.pause(0)
    tl.totalTime(0)
    tl.play(0)

    const duration = tl.duration()
    const events = []
    let resizedAt = null
    let postResizeTotalTime = null
    let lastIter = 0
    const wall0 = performance.now()
    const wallBudget = 25_000

    while (performance.now() - wall0 < wallBudget) {
      const totalTime = tl.totalTime()
      const t = tl.time()
      const iter = Math.floor(totalTime / Math.max(duration, 0.001))
      if (iter > lastIter) lastIter = iter
      const marker =
        [...document.querySelectorAll("span")]
          .map((s) => (s.textContent || "").trim())
          .find((s) => /^\d+ \/ 10$/.test(s)) || ""
      events.push({ t, totalTime, duration, marker, iter })
      if (resizedAt === null && t >= 18 && iter === 0) {
        resizedAt = t
        await window.__loginFilmDoResize()
        postResizeTotalTime = tl.totalTime()
        events.push({ event: "resize", at: t, postResizeTotalTime })
      }
      if (totalTime >= duration * 2 + 0.25) break
      await new Promise((r) => setTimeout(r, 20))
    }

    tl.pause()
    tl.timeScale(1)
    const labels = film.labels()
    const pushIns = Object.keys(labels)
      .filter((k) => /^s\d+$/.test(k))
      .sort((a, b) => labels[a] - labels[b])
      .map((k) => ({ label: k, t: labels[k] }))

    const markersLoop1 = []
    for (const e of events) {
      if (!e.marker || e.event || e.iter !== 0) continue
      if (
        !markersLoop1.length ||
        markersLoop1[markersLoop1.length - 1] !== e.marker
      ) {
        markersLoop1.push(e.marker)
      }
    }

    let restarts = 0
    for (let i = 1; i < events.length; i += 1) {
      const prev = events[i - 1]
      const cur = events[i]
      if (cur.event || prev.event) continue
      if (cur.totalTime + 0.4 < prev.totalTime) restarts += 1
    }

    return {
      pushIns,
      markersLoop1,
      restarts,
      resizedAt,
      postResizeTotalTime,
      loopsSeen: lastIter,
      duration,
      eventCount: events.length,
      wallMs: Math.round(performance.now() - wall0),
    }
  })

  return live
}

async function captionSync(page) {
  await page.setViewportSize({ width: 1440, height: 900 })
  await waitForFilm(page)
  const result = await page.evaluate(async () => {
    const film = window.__loginFilm
    film.captionSwaps = []
    const labels = film.labels()
    const stationLabels = Object.keys(labels)
      .filter((k) => /^s\d+$/.test(k))
      .sort((a, b) => labels[a] - labels[b])
    const caption = document.querySelector("[data-login-caption='live']")
    const FRAME = 1 / 60

    // Live play at 8×: sample opacity every frame for one loop.
    film.timeline.timeScale(8)
    film.timeline.pause(0)
    film.timeline.time(0)
    film.timeline.play(0)
    const frameSamples = []
    let lastTextWhileVisible = ""
    let dualVisibleFrames = 0
    const total = film.timeline.duration()
    const wallBudget = (total / 8) * 1000 + 800
    const t0 = performance.now()
    while (performance.now() - t0 < wallBudget) {
      const t = film.timeline.time()
      const opacity = Number(getComputedStyle(caption).opacity)
      const text = (caption.textContent || "").trim()
      if (opacity > 0.02) {
        if (lastTextWhileVisible && text && text !== lastTextWhileVisible) {
          dualVisibleFrames += 1
        }
        if (text) lastTextWhileVisible = text
      } else {
        lastTextWhileVisible = ""
      }
      frameSamples.push({ t, opacity, text })
      if (t >= total - FRAME) break
      await new Promise((r) => requestAnimationFrame(r))
    }
    film.timeline.pause()
    film.timeline.timeScale(1)

    // Per-label offset: seek scrub from each sN label until caption text is visible.
    const offsets = []
    let maxOffset = 0
    for (const name of stationLabels) {
      const labelT = labels[name]
      let firstVisible = null
      for (let dt = 0; dt <= 0.5; dt += FRAME) {
        film.seek(labelT + dt)
        const opacity = Number(gsapOpacity())
        const text = (caption.textContent || "").trim()
        if (firstVisible === null && opacity >= 0.05 && text) {
          firstVisible = dt
          break
        }
      }
      const offset = firstVisible ?? 99
      offsets.push({ label: name, labelT, visibleAt: labelT + offset, offset })
      maxOffset = Math.max(maxOffset, offset)
    }

    function gsapOpacity() {
      return film.captionOpacity()
    }

    return {
      maxOffset,
      offsets,
      dualVisibleFrames,
      frameSampleCount: frameSamples.length,
      swaps: film.captionSwaps.slice(0, 12),
    }
  })
  return result
}

async function closeFill(page) {
  const viewports = [
    { name: "1440x900", width: 1440, height: 900 },
    { name: "1100x800", width: 1100, height: 800 },
    { name: "900x700", width: 900, height: 700 },
  ]
  const report = []
  for (const vp of viewports) {
    await page.setViewportSize(vp)
    await waitForFilm(page)
    const rows = await page.evaluate((stageCount) => {
      const film = window.__loginFilm
      const out = []
      for (let i = 0; i < stageCount; i += 1) {
        film.seek(`s${i + 1}-hold`)
        const m = film.measureFill(i)
        out.push({
          index: i + 1,
          fillFromScale: m?.fillPct ?? null,
          fillFromScreen: m?.fillFromScreen ?? null,
          close: m?.close ?? null,
          scale: m?.scale ?? null,
          panelW: m?.panelW ?? null,
          figW: m?.svgScreenW ?? null,
        })
      }
      return out
    }, STAGES.length)
    report.push({ viewport: vp.name, rows })
  }
  return report
}

async function productionRouteCheck() {
  // Static check of the router source: DEV gate must wrap the figures route.
  const router = fs.readFileSync(path.join(root, "src/app/router.tsx"), "utf8")
  const gated =
    router.includes("import.meta.env.DEV") &&
    router.includes("/dev/login-figures")
  const distIndex = path.join(root, "dist/assets")
  let absentFromProd = null
  if (fs.existsSync(distIndex)) {
    const files = fs.readdirSync(distIndex)
    const hit = files.some((f) => {
      if (!f.endsWith(".js")) return false
      const body = fs.readFileSync(path.join(distIndex, f), "utf8")
      return body.includes("/dev/login-figures") || body.includes("LoginFiguresPage")
    })
    absentFromProd = !hit
  }
  return { gated, absentFromProd }
}

const report = {
  baseURL,
  at: new Date().toISOString(),
  screenshots: [],
  firstLoop: null,
  captionSync: null,
  closeFill: null,
  routes: null,
  errors: [],
}

function progress(msg) {
  console.log(`[verify] ${msg}`)
}

const browser = await chromium.launch({ headless: true })
const context = await browser.newContext({
  deviceScaleFactor: 2,
  viewport: { width: 1440, height: 900 },
})
const page = await context.newPage()
page.setDefaultTimeout(60_000)

try {
  progress("screenshots 1440x900")
  await captureStationShots(page, "1440x900", { width: 1440, height: 900 })
  progress("screenshots 840x660")
  await captureStationShots(page, "840x660", { width: 840, height: 660 })
  progress("figures")
  const figCount = await captureFigures(page)
  report.screenshots = {
    stationSets: ["1440x900", "840x660"],
    perStation: ["wide", "mid", "close"],
    figures: figCount,
    dir: outDir,
  }

  progress("first-loop + resize")
  report.firstLoop = await firstLoopWithResize(page)
  progress("caption sync")
  report.captionSync = await captionSync(page)
  progress("close fill")
  report.closeFill = await closeFill(page)
  progress("route check")
  report.routes = await productionRouteCheck()
} catch (err) {
  report.errors.push(String(err && err.stack ? err.stack : err))
  console.error(err)
} finally {
  await browser.close()
}

const reportPath = path.join(outDir, "report.json")
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2))
console.log(JSON.stringify(report, null, 2))
console.log(`\nWrote ${reportPath}`)
