import { describe, expect, it } from "vitest"
import {
  ACCOUNTS_COMPANY_WIDE_GODOWN_PERMISSION,
  COMPANY_WIDE_GODOWN_ACCESS_LABEL,
  DELIVERY_PERSON_COMPANY_WIDE_GODOWN_PERMISSION,
  GODOWN_MANAGER_COMPANY_WIDE_GODOWN_PERMISSION,
  STORE_KEEPER_COMPANY_WIDE_GODOWN_PERMISSION,
  describeEmployeeGodownAccess,
  hasCompanyWideGodownAccess,
} from "@/lib/access/godown-scope"
import { ACCOUNTS_ROLE_PERMISSIONS } from "@/lib/access/navigation-visibility"

describe("Accounts company-wide godown access copy", () => {
  it("labels Accounts users as company-wide even with no assignment rows", () => {
    const view = describeEmployeeGodownAccess({
      roleCodes: ["accounts"],
      assignedBranchNames: [],
    })
    expect(view.companyWide).toBe(true)
    expect(view.accessLabel).toBe(COMPANY_WIDE_GODOWN_ACCESS_LABEL)
    expect(view.explicitAssignments).toEqual([])
  })

  it("labels Godown Manager as company-wide without inventing assignment rows", () => {
    const view = describeEmployeeGodownAccess({
      roleCodes: ["godown_manager"],
      assignedBranchNames: ["Godown-1"],
    })
    expect(view.companyWide).toBe(true)
    expect(view.accessLabel).toBe(COMPANY_WIDE_GODOWN_ACCESS_LABEL)
    expect(view.explicitAssignments).toEqual(["Godown-1"])
  })

  it("labels Store Keeper as company-wide without inventing assignment rows", () => {
    const view = describeEmployeeGodownAccess({
      roleCodes: ["store_keeper"],
      assignedBranchNames: ["Godown-1"],
    })
    expect(view.companyWide).toBe(true)
    expect(view.accessLabel).toBe(COMPANY_WIDE_GODOWN_ACCESS_LABEL)
    expect(view.explicitAssignments).toEqual(["Godown-1"])
  })

  it("labels Delivery Person as company-wide without inventing assignment rows", () => {
    const view = describeEmployeeGodownAccess({
      roleCodes: ["delivery_person"],
      assignedBranchNames: ["Godown-1"],
    })
    expect(view.companyWide).toBe(true)
    expect(view.accessLabel).toBe(COMPANY_WIDE_GODOWN_ACCESS_LABEL)
    expect(view.explicitAssignments).toEqual(["Godown-1"])
  })

  it("does not treat Admin access_all as an Accounts permission", () => {
    expect(ACCOUNTS_ROLE_PERMISSIONS).toContain(ACCOUNTS_COMPANY_WIDE_GODOWN_PERMISSION)
    expect(ACCOUNTS_ROLE_PERMISSIONS).not.toContain("branches.access_all")
    expect(hasCompanyWideGodownAccess((code) => code === "branches.access_all")).toBe(false)
    expect(
      hasCompanyWideGodownAccess((code) => code === ACCOUNTS_COMPANY_WIDE_GODOWN_PERMISSION),
    ).toBe(true)
  })

  it("treats Accounts, Godown Manager, Store Keeper, and Delivery Person as company-wide even before the permission catalog loads", () => {
    expect(hasCompanyWideGodownAccess(() => false, ["accounts"])).toBe(true)
    expect(hasCompanyWideGodownAccess(() => false, ["godown_manager"])).toBe(true)
    expect(hasCompanyWideGodownAccess(() => false, ["store_keeper"])).toBe(true)
    expect(hasCompanyWideGodownAccess(() => false, ["delivery_person"])).toBe(true)
    expect(
      hasCompanyWideGodownAccess(
        (code) => code === GODOWN_MANAGER_COMPANY_WIDE_GODOWN_PERMISSION,
      ),
    ).toBe(true)
    expect(
      hasCompanyWideGodownAccess(
        (code) => code === STORE_KEEPER_COMPANY_WIDE_GODOWN_PERMISSION,
      ),
    ).toBe(true)
    expect(
      hasCompanyWideGodownAccess(
        (code) => code === DELIVERY_PERSON_COMPANY_WIDE_GODOWN_PERMISSION,
      ),
    ).toBe(true)
  })
})
