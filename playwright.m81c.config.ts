import { defineConfig, devices } from "@playwright/test"
import { assertLocalPlaywrightTarget } from "./tests/e2e/assert-local-target.ts"

/**
 * Isolated M8.1C browser config. Loads gitignored .env.m81c.local and
 * refuses the owner API on 54321. Do not use the default playwright.config.ts
 * for this milestone — that file still targets the owner local stack.
 */
process.env.SHERLYOS_ISOLATED = "1"
process.env.SHERLYOS_VITE_MODE = "m81c"
process.env.SHERLYOS_PSQL_CONTAINER = "supabase_db_sherlyos_m81c"

assertLocalPlaywrightTarget()

export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "**/m81c-isolated-cutover.spec.ts",
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  use: {
    baseURL: "http://127.0.0.1:4273",
    trace: "on-first-retry",
  },
  webServer: {
    command: "npm run dev -- --mode m81c --host 127.0.0.1 --port 4273 --strictPort",
    url: "http://127.0.0.1:4273",
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
