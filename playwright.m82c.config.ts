import { defineConfig, devices } from "@playwright/test"
import { assertLocalPlaywrightTarget } from "./tests/e2e/assert-local-target.ts"

/**
 * Isolated M8.2C Branch-1 UAT browser config.
 * Loads gitignored .env.m82c.local and refuses owner API port 54321 and
 * the M8.1C cutover API on 56321.
 */
process.env.SHERLYOS_ISOLATED = "1"
process.env.SHERLYOS_M82C = "1"
process.env.SHERLYOS_VITE_MODE = "m82c"
process.env.SHERLYOS_PSQL_CONTAINER = "supabase_db_sherlyos_m82c"

assertLocalPlaywrightTarget()

export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "**/m82c-isolated-uat.spec.ts",
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  use: {
    baseURL: "http://127.0.0.1:4373",
    trace: "on-first-retry",
  },
  webServer: {
    command: "npm run dev -- --mode m82c --host 127.0.0.1 --port 4373 --strictPort",
    url: "http://127.0.0.1:4373",
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
