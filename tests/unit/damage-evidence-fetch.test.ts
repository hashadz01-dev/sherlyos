import { describe, expect, it } from "vitest"
import dropFollowlocationSql from "../../supabase/migrations/20261103100000_damage_evidence_drop_followlocation.sql?raw"
import cloudAllowlistSql from "../../supabase/migrations/20261102180000_damage_evidence_cloud_storage_fetch.sql?raw"

/**
 * pgsql-http on Supabase rejects CURLOPT_FOLLOWLOCATION at runtime.
 * Finalize must GET private Storage bytes without that curl option.
 */
describe("damage storage byte fetch migration", () => {
  it("drops CURLOPT_FOLLOWLOCATION while keeping timeout and cloud host", () => {
    expect(dropFollowlocationSql).not.toMatch(
      /http_set_curlopt\('CURLOPT_FOLLOWLOCATION'/,
    )
    expect(dropFollowlocationSql).toMatch(
      /http_set_curlopt\('CURLOPT_TIMEOUT_MS'/,
    )
    expect(dropFollowlocationSql).toContain(
      "https://ypkfondrkhkydkgovwup.supabase.co",
    )
    expect(dropFollowlocationSql).toContain("stock-damage-evidence")
    expect(dropFollowlocationSql).toMatch(
      /revoke all on function app_private\.damage_storage_object_bytes/,
    )
  })

  it("keeps the cloud allowlist migration free of FOLLOWLOCATION", () => {
    expect(cloudAllowlistSql).not.toMatch(
      /http_set_curlopt\('CURLOPT_FOLLOWLOCATION'/,
    )
    expect(cloudAllowlistSql).toContain(
      "https://ypkfondrkhkydkgovwup.supabase.co",
    )
  })
})
