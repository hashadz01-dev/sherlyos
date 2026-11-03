import { defineConfig, devices } from "@playwright/test"
import { assertLocalPlaywrightTarget } from "./tests/e2e/assert-local-target.ts"

/**
 * DMG-03C disposable local isolation UAT.
 * Isolated M8.2C Docker API on 57321. App on 5174. Never owner 54321 / cloud.
 */
process.env.SHERLYOS_ISOLATED = "1"
process.env.SHERLYOS_DMG03C = "1"
process.env.SHERLYOS_M82C = "1"
process.env.SHERLYOS_VITE_MODE = "dmg03c"
process.env.SHERLYOS_PSQL_CONTAINER = "supabase_db_sherlyos_m82c"

assertLocalPlaywrightTarget()

export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "**/dmg03c-isolation-uat.spec.ts",
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  use: {
    baseURL: "http://127.0.0.1:5174",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  webServer: {
    command:
      "npm run dev -- --mode dmg03c --host 127.0.0.1 --port 5174 --strictPort",
    url: "http://127.0.0.1:5174",
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
