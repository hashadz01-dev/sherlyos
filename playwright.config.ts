import { defineConfig, devices } from "@playwright/test"
import { assertLocalPlaywrightTarget } from "./tests/e2e/assert-local-target.ts"

assertLocalPlaywrightTarget()

export default defineConfig({
  testDir: "./tests/e2e",
  // Cutover flags and disposable lot fixtures are process-global. One worker
  // keeps M1-S2 reconciliation and M2 picking from overlapping flag flips.
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  use: {
    baseURL: "http://127.0.0.1:4173",
    trace: "on-first-retry",
  },
  webServer: {
    // --mode m1s2 loads gitignored .env.m1s2.local (127.0.0.1:54321).
    // .env and .env.local stay pointed at the development cloud.
    command: "npm run dev -- --mode m1s2 --host 127.0.0.1 --port 4173 --strictPort",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
})
