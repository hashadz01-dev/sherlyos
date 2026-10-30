/**
 * M8.2C TEST ONLY Branch-1 UAT contract.
 * These values are synthetic labels for an isolated database. They are not
 * company prices, physical stock, supplier identities, or credit balances.
 * Do not import this module into production screens.
 */

/** Owner six-stage blueprint. Admin monitors and is not a seventh stage. */
export const M82C_OWNER_STAGES = [
  "salesperson_order_entry",
  "accounts_order_approval",
  "store_keeper_loading_preparation",
  "store_keeper_accounts_invoice_note",
  "accounts_billing_preview",
  "delivery_person_confirmation",
] as const

/**
 * Current implemented sequence. Invoice notes snapshot DISPATCH consume
 * quantity, not picked-but-undispatched cases.
 */
export const M82C_IMPLEMENTED_SEQUENCE = [
  "order_capture_submit",
  "accounts_verify_or_hold",
  "accounts_delivery_note",
  "godown_manager_dn_acknowledge",
  "godown_manager_allocate",
  "store_keeper_pick",
  "optional_short_shipment_accounts_approve",
  "godown_manager_confirm_dispatch",
  "godown_manager_assign_vehicle_driver",
  "godown_manager_prepare_invoice_note",
  "accounts_review_invoice_note",
  "delivery_person_pod",
] as const

export const M82C_LABEL = "TEST ONLY"

export const M82C_ISOLATION = {
  projectId: "sherlyos_m82c",
  apiPort: "57321",
  dbPort: "57322",
  appPort: "4373",
  container: "supabase_db_sherlyos_m82c",
  forbiddenOwnerSysid: "7699785797738577957",
  forbiddenM81cSysid: "7702023892197691429",
  forbiddenApiPorts: ["54321", "56321"],
} as const

export const M82C_USERS = {
  admin: "admin.m82c@example.test",
  accounts: "accounts.m82c@example.test",
  godownManager: "gm.m82c@example.test",
  salesperson: "sales.m82c@example.test",
  storeKeeper: "keeper.m82c@example.test",
  deliveryPerson: "driver.m82c@example.test",
} as const

export const M82C_SITE = {
  godownCode: "m82c_gd1",
  godownName: "TEST ONLY Godown-1",
  zoneCode: "m82c_z1",
  zoneName: "TEST ONLY Zone 1",
  crateACode: "m82c_c1",
  crateAName: "TEST ONLY Crate 1",
  crateBCode: "m82c_c2",
  crateBName: "TEST ONLY Crate 2",
} as const

export const M82C_SHOPS = {
  alphaName: "TEST ONLY Shop Alpha",
  betaName: "TEST ONLY Shop Beta",
  routeCode: "m82c_rt",
  routeName: "TEST ONLY Route M82C",
} as const

export const M82C_CATALOG = {
  supplierName: "TEST ONLY UAT Supplier",
  categoryName: "TEST ONLY Category",
  expirySku: "m82c-expiry",
  expiryName: "TEST ONLY Expiry SKU",
  stableSku: "m82c-stable",
  stableName: "TEST ONLY Stable SKU",
  spareSku: "m82c-spare",
  spareName: "TEST ONLY Spare SKU",
  billingUnit: "nos",
  billedUnitsPerCase: 10,
} as const

/** Synthetic INR amounts. Not company selling prices. */
export const M82C_SYNTHETIC_PRICES = {
  expiry: 10,
  stable: 25,
  spare: 40,
} as const

/** Synthetic opening cases. Not physical warehouse counts. */
export const M82C_SYNTHETIC_OPENING_CASES = {
  expiry: 20,
  stable: 20,
  spare: 20,
} as const

export const M82C_VEHICLE = {
  registration: "TEST-UAT-0001",
  displayName: "TEST ONLY Vehicle",
} as const

export const M82C_SCENARIO_A_CASES = 4
export const M82C_SCENARIO_B_ORDERED_CASES = 12
export const M82C_SCENARIO_B_LOADED_CASES = 11
export const M82C_SCENARIO_C_DELIVERED_CASES = 10
export const M82C_SCENARIO_C_RETURNED_CASES = 1
