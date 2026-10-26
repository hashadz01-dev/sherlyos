/** Operational writes may only target currently active godowns. */
export function activeOperationalBranches<T extends { is_active: boolean }>(rows: T[] | undefined) {
  return (rows ?? []).filter((row) => row.is_active)
}

export type ReportBranchOption = {
  id: string
  name: string
  code?: string
  is_active: boolean
}

/** Reporting may name inactive godowns; operational selectors must not. */
export function partitionReportBranches(branches: ReportBranchOption[]) {
  return {
    active: branches.filter((branch) => branch.is_active),
    inactive: branches.filter((branch) => !branch.is_active),
  }
}
