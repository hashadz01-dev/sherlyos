import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import { damageScenarios, damageStatuses } from "@/lib/damage/rules"
import {
  formatDamageScenario,
  formatDamageStatus,
} from "@/features/damage/utils/labels"

export type DamageFilterState = {
  search: string
  status: string
  scenario: string
  godownId: string
  fromDate: string
  toDate: string
}

export function DamageReportFilters({
  value,
  onChange,
  godowns,
  onClear,
  onRefresh,
}: {
  value: DamageFilterState
  onChange: (next: DamageFilterState) => void
  godowns: { id: string; name: string }[]
  onClear: () => void
  onRefresh: () => void
}) {
  function patch(partial: Partial<DamageFilterState>) {
    onChange({ ...value, ...partial })
  }

  return (
    <div className="mb-4 grid gap-3 md:grid-cols-3 xl:grid-cols-6">
      <SearchField
        label="Search report number"
        value={value.search}
        onChange={(search) => patch({ search })}
      />
      <label className="grid gap-2 text-sm font-medium">
        Status
        <select
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={value.status}
          onChange={(event) => patch({ status: event.target.value })}
          aria-label="Status"
        >
          <option value="all">All statuses</option>
          {damageStatuses.map((status) => (
            <option key={status} value={status}>
              {formatDamageStatus(status)}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-2 text-sm font-medium">
        Scenario
        <select
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={value.scenario}
          onChange={(event) => patch({ scenario: event.target.value })}
          aria-label="Scenario"
        >
          <option value="all">All scenarios</option>
          {damageScenarios.map((scenario) => (
            <option key={scenario} value={scenario}>
              {formatDamageScenario(scenario)}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-2 text-sm font-medium">
        Godown
        <select
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={value.godownId}
          onChange={(event) => patch({ godownId: event.target.value })}
          aria-label="Godown"
        >
          <option value="all">All godowns</option>
          {godowns.map((godown) => (
            <option key={godown.id} value={godown.id}>
              {godown.name}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-2 text-sm font-medium">
        From date
        <input
          type="date"
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={value.fromDate}
          onChange={(event) => patch({ fromDate: event.target.value })}
          aria-label="From date"
        />
      </label>
      <label className="grid gap-2 text-sm font-medium">
        To date
        <input
          type="date"
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={value.toDate}
          onChange={(event) => patch({ toDate: event.target.value })}
          aria-label="To date"
        />
      </label>
      <div className="flex flex-wrap items-end gap-2 md:col-span-3 xl:col-span-6">
        <Button type="button" variant="outline" onClick={onClear}>
          Clear filters
        </Button>
        <Button type="button" variant="outline" onClick={onRefresh}>
          Refresh
        </Button>
      </div>
    </div>
  )
}
