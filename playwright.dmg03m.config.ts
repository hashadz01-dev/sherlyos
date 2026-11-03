import { defineConfig, devices } from "@playwright/test"

/**
 * DMG-03M cloud activation browser proof.
 * Targets existing Vite on 5173 → cloud ypkfondrkhkydkgovwup.
 * Does not start a disposable Docker API.
 */
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "**/dmg03m-cloud-activation.spec.ts",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 180_000,
  use: {
    baseURL: "http://127.0.0.1:5173",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
})
