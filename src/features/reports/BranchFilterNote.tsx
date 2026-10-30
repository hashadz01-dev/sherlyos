import { ReportSelect } from "@/features/reports/ReportControls"
import {
  partitionReportBranches,
  type ReportBranchOption,
} from "@/lib/branches/operational"

/** Approved policy: reporting includes inactive godowns; operations do not. */
export function BranchFilterNote() {
  return (
    <p className="text-sm text-muted-foreground">
      Authorized totals for “All authorized godowns” include inactive godown stock.
      Use Inactive / Historical to name those sites. Inactive godowns cannot be
      selected for new operational transactions and are not reactivated here.
    </p>
  )
}

export function ReportBranchSelect({
  value,
  onChange,
  branches,
}: {
  value: string
  onChange: (value: string) => void
  branches: ReportBranchOption[]
}) {
  const { active, inactive } = partitionReportBranches(branches)
  return (
    <ReportSelect label="Godown" value={value} onChange={onChange}>
      <option value="">All authorized godowns</option>
      <optgroup label="Active operational godowns">
        {active.map((branch) => (
          <option key={branch.id} value={branch.id}>
            {branch.code ? `${branch.name} (${branch.code})` : branch.name}
          </option>
        ))}
      </optgroup>
      {inactive.length > 0 ? (
        <optgroup label="Inactive / Historical">
          {inactive.map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.code ? `${branch.name} (${branch.code})` : branch.name} (inactive)
            </option>
          ))}
        </optgroup>
      ) : null}
    </ReportSelect>
  )
}
