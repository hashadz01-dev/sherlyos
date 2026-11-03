import { createClient } from "@supabase/supabase-js"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const env = {}
for (const line of readFileSync(resolve(".env.local"), "utf8").split(/\r?\n/)) {
  const m = line.match(/^([A-Z0-9_]+)=(.*)$/)
  if (m) env[m[1]] = m[2].replace(/^"|"$/g, "")
}

const c = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY)
const auth = await c.auth.signInWithPassword({
  email: "teststorekeeper@gmail.com",
  password: "12345678",
})
if (auth.error) throw auth.error

const { data, error } = await c.rpc("list_damage_report_sources", {
  scenario: "loading",
  target_godown: "798bacf9-2212-43fc-9cbb-2fe1e7367a93",
  search_text: "PK-20261103-000002",
  page: 1,
  page_size: 20,
  catalog_search: null,
  catalog_page: 1,
})
if (error) throw error
const hit = (data.items || []).find((i) => i.label === "PK-20261103-000002")
console.log(JSON.stringify({ total_count: data.total_count, hit }, null, 2))
