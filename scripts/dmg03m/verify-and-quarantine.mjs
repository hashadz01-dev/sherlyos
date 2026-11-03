/**
 * DMG-03M: post-submit GM verify + quarantine + ordinary write-off on TEST stock.
 * Uses publishable key + test account passwords set for this development activation.
 */
import { createClient } from "@supabase/supabase-js"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const REPORT_ID = "f4793833-d1f7-41e1-9e9d-3934c51a2ab6"
const PASSWORD = "dmg03m-dev-only"

function loadEnv() {
  const env = {}
  for (const line of readFileSync(resolve(".env.local"), "utf8").split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/)
    if (m) env[m[1]] = m[2].replace(/^"|"$/g, "")
  }
  return env
}

async function clientFor(email) {
  const env = loadEnv()
  const client = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY)
  const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD })
  if (error) throw error
  return client
}

async function main() {
  const sk = await clientFor("teststorekeeper@gmail.com")
  const self = await sk.rpc("verify_damage_report", {
    target_report: REPORT_ID,
    expected_version: 2,
  })
  console.log(
    "self_verify:",
    self.error?.message ?? "UNEXPECTED_SUCCESS",
  )
  await sk.auth.signOut()

  const gm = await clientFor("testgodownmanager@gmail.com")
  const detail = await gm.rpc("get_damage_report", { target_report: REPORT_ID })
  if (detail.error) throw detail.error
  const version = detail.data?.version ?? 2
  console.log("status_before:", detail.data?.status, "version:", version)

  if (detail.data?.status === "submitted") {
    const ver = await gm.rpc("verify_damage_report", {
      target_report: REPORT_ID,
      expected_version: version,
    })
    if (ver.error) throw ver.error
    console.log("gm_verify:", ver.data?.status ?? "ok", "version:", ver.data?.version)
  }

  const after = await gm.rpc("get_damage_report", { target_report: REPORT_ID })
  const v2 = after.data?.version
  console.log("status_after_verify:", after.data?.status, "version:", v2)

  const q = await gm.rpc("transfer_verified_damage_to_quarantine", {
    target_report: REPORT_ID,
    expected_version: v2,
    idempotency_key: `dmg03m-q-${REPORT_ID}`,
  })
  if (q.error) {
    console.log("quarantine_error:", q.error.message)
  } else {
    console.log("quarantine:", q.data?.status ?? "ok", "version:", q.data?.version)
  }

  const afterQ = await gm.rpc("get_damage_report", { target_report: REPORT_ID })
  const v3 = afterQ.data?.version
  console.log("status_after_quarantine:", afterQ.data?.status, "version:", v3)

  // Ordinary write-off after quarantine (no notes arg — matches public RPC).
  const afterQ2 = await gm.rpc("get_damage_report", { target_report: REPORT_ID })
  const vWo = afterQ2.data?.version
  const wo = await gm.rpc("post_ordinary_damage_writeoff", {
    target_report: REPORT_ID,
    expected_version: vWo,
    idempotency_key: `dmg03m-wo-${REPORT_ID}`,
  })
  if (wo.error) {
    console.log("writeoff_error:", wo.error.message)
  } else {
    console.log("writeoff:", wo.data?.status ?? "ok", "version:", wo.data?.version)
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
