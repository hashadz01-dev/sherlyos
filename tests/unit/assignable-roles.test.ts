import { describe, expect, it } from "vitest"
import { assignableRoleOptions } from "@/lib/access/assignable-roles"

describe("assignable role options", () => {
  it("hides Damage Verifier and Statutory verifier from role pickers", () => {
    const options = assignableRoleOptions([
      { code: "accounts", name: "Accounts" },
      { code: "admin", name: "Admin" },
      { code: "damage_verifier", name: "Damage Verifier" },
      { code: "delivery_person", name: "Delivery Person" },
      { code: "godown_manager", name: "Godown Manager" },
      { code: "salesperson", name: "Salesperson" },
      { code: "statutory_verifier", name: "Statutory verifier" },
      { code: "store_keeper", name: "Store Keeper" },
    ])

    expect(options.map((role) => role.name)).toEqual([
      "Accounts",
      "Admin",
      "Delivery Person",
      "Godown Manager",
      "Salesperson",
      "Store Keeper",
    ])
  })
})
