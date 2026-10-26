import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { fileURLToPath, URL } from "node:url"
import { loadEnv, type Plugin } from "vite"
import { defineConfig } from "vitest/config"
import { assertDevelopmentReleaseEnv } from "./src/lib/supabase/release-env.ts"

/** Fail Netlify/development production builds that are not the approved project. */
function sherlysReleaseEnvPlugin(): Plugin {
  return {
    name: "sherlys-release-env",
    config(_userConfig, { command, mode }) {
      if (command !== "build") return
      const loaded = loadEnv(mode, process.cwd(), "")
      assertDevelopmentReleaseEnv({
        url: loaded.VITE_SUPABASE_URL,
        publishableKey: loaded.VITE_SUPABASE_PUBLISHABLE_KEY,
        serviceRoleBrowserKey: loaded.VITE_SUPABASE_SERVICE_ROLE_KEY,
        netlify: Boolean(loaded.NETLIFY || process.env.NETLIFY),
        releaseTarget: loaded.SHERLYS_RELEASE_TARGET || process.env.SHERLYS_RELEASE_TARGET,
      })
    },
  }
}

export default defineConfig({
  plugins: [react(), tailwindcss(), sherlysReleaseEnvPlugin()],
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: "./tests/setup.ts",
    include: [
      "tests/unit/**/*.test.ts",
      "tests/unit/**/*.test.tsx",
      "tests/integration/**/*.test.tsx",
    ],
  },
})
