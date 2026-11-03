import { createClient } from "@supabase/supabase-js"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const REPORT_ID = "f4793833-d1f7-41e1-9e9d-3934c51a2ab6"
const PASSWORD = "dmg03m-dev-only"

const env = {}
for (const line of readFileSync(resolve(".env.local"), "utf8").split(/\r?\n/)) {
  const m = line.match(/^([A-Z0-9_]+)=(.*)$/)
  if (m) env[m[1]] = m[2].replace(/^"|"$/g, "")
}

const gm = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY)
const auth = await gm.auth.signInWithPassword({
  email: "testgodownmanager@gmail.com",
  password: PASSWORD,
})
if (auth.error) throw auth.error

const detail = await gm.rpc("get_damage_report", { target_report: REPORT_ID })
if (detail.error) throw detail.error
console.log("status", detail.data?.status, "version", detail.data?.version)

const wo = await gm.rpc("post_ordinary_damage_writeoff", {
  target_report: REPORT_ID,
  expected_version: detail.data.version,
  idempotency_key: `dmg03m-wo-${REPORT_ID}`,
})
if (wo.error) {
  console.log("writeoff_error", wo.error.message)
  process.exit(1)
}
console.log("writeoff_ok", wo.data?.status, "version", wo.data?.version)
