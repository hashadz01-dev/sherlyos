/**
 * M8.2C isolated UAT constants. Must stay aligned with
 * src/lib/uat/m82c-manifest.ts. These scripts never target the development
 * cloud or the owner/m81c local stacks.
 */
export const PROJECT_ID = "sherlyos_m82c"
export const API_PORT = "57321"
export const DB_PORT = "57322"
export const SHADOW_PORT = "57320"
export const STUDIO_PORT = "57323"
export const INBUCKET_PORT = "57324"
export const ANALYTICS_PORT = "57327"
export const POOLER_PORT = "57329"
export const APP_PORT = "4373"
export const CONTAINER = "supabase_db_sherlyos_m82c"
export const OWNER_SYSID = "7699785797738577957"
export const M81C_SYSID = "7702023892197691429"
export const FORBIDDEN_API_PORTS = new Set(["54321", "56321"])
export const CLOUD_HOST_FRAGMENT = "supabase.co"
export const APPROVAL_ENV = "M82C_OWNER_APPROVED"
export const LOCAL_PASSWORD = "local-only-m82c"

export const USERS = {
  admin: { email: "admin.m82c@example.test", name: "TEST ONLY Admin", role: "admin" },
  accounts: { email: "accounts.m82c@example.test", name: "TEST ONLY Accounts", role: "accounts" },
  godown: { email: "gm.m82c@example.test", name: "TEST ONLY Godown Manager", role: "godown_manager" },
  sales: { email: "sales.m82c@example.test", name: "TEST ONLY Salesperson", role: "salesperson" },
  keeper: { email: "keeper.m82c@example.test", name: "TEST ONLY Store Keeper", role: "store_keeper" },
  driver: { email: "driver.m82c@example.test", name: "TEST ONLY Delivery Person", role: "delivery_person" },
}
