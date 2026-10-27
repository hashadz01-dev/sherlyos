import type { ReactNode } from "react"
import { SearchField } from "@/features/masters/MasterControls"
import { ReportDateField } from "@/features/reports/ReportControls"
import {
  formatRefillAcknowledgement,
  formatRefillCommunication,
  formatRefillDispatch,
  formatRefillReceivingLabel,
  formatRefillStatus,
} from "@/features/refill/utils/labels"
import type { RefillOptions } from "@/lib/refill/api"
import {
  refillAcknowledgementStatuses,
  refillCommunicationStatuses,
  refillDispatchStatuses,
  refillReceivingCompletionLabels,
  refillStatuses,
} from "@/lib/refill/rules"
import type { RefillQueueFilterState } from "@/features/refill/utils/queue-filters"

function FilterSelect({
  label,
  value,
  onChange,
  children,
}: {
  label: string
  value: string
  onChange: (value: string) => void
  children: ReactNode
}) {
  return (
    <label className="grid gap-2 text-sm font-medium">
      {label}
      <select
        className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
        value={value}
        onChange={(event) => onChange(event.target.value)}
        aria-label={label}
      >
        {children}
      </select>
    </label>
  )
}

/** Server-backed queue filters. Changing a filter resets pagination in the parent. */
export function RefillQueueFilters({
  value,
  options,
  onChange,
}: {
  value: RefillQueueFilterState
  options: RefillOptions | undefined
  onChange: (next: RefillQueueFilterState) => void
}) {
  function patch(partial: Partial<RefillQueueFilterState>) {
    onChange({ ...value, ...partial })
  }

  return (
    <div className="mb-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      <SearchField
        label="Search requests"
        value={value.search}
        onChange={(search) => patch({ search })}
      />
      <FilterSelect label="Approval status" value={value.status} onChange={(status) => patch({ status })}>
        <option value="all">All statuses</option>
        {refillStatuses.map((status) => (
          <option key={status} value={status}>
            {formatRefillStatus(status)}
          </option>
        ))}
      </FilterSelect>
      <FilterSelect
        label="Supplier"
        value={value.supplierId}
        onChange={(supplierId) => patch({ supplierId })}
      >
        <option value="all">All suppliers</option>
        {(options?.suppliers ?? []).map((supplier) => (
          <option key={supplier.id} value={supplier.id}>
            {supplier.name}
            {supplier.is_active ? "" : " (inactive)"}
          </option>
        ))}
      </FilterSelect>
      <FilterSelect label="Destination godown" value={value.godownId} onChange={(godownId) => patch({ godownId })}>
        <option value="all">All authorized godowns</option>
        <optgroup label="Active">
          {(options?.godowns ?? [])
            .filter((godown) => godown.is_active)
            .map((godown) => (
              <option key={godown.id} value={godown.id}>
                {godown.code} · {godown.name}
              </option>
            ))}
        </optgroup>
        {(options?.godowns ?? []).some((godown) => !godown.is_active) ? (
          <optgroup label="Inactive / Historical">
            {(options?.godowns ?? [])
              .filter((godown) => !godown.is_active)
              .map((godown) => (
                <option key={godown.id} value={godown.id}>
                  {godown.code} · {godown.name} (inactive)
                </option>
              ))}
          </optgroup>
        ) : null}
      </FilterSelect>
      <FilterSelect
        label="Supplier communication"
        value={value.communication}
        onChange={(communication) => patch({ communication })}
      >
        <option value="all">All communication</option>
        {refillCommunicationStatuses.map((status) => (
          <option key={status} value={status}>
            {formatRefillCommunication(status)}
          </option>
        ))}
      </FilterSelect>
      <FilterSelect
        label="Acknowledgement"
        value={value.acknowledgement}
        onChange={(acknowledgement) => patch({ acknowledgement })}
      >
        <option value="all">All acknowledgements</option>
        {refillAcknowledgementStatuses.map((status) => (
          <option key={status} value={status}>
            {formatRefillAcknowledgement(status)}
          </option>
        ))}
      </FilterSelect>
      <FilterSelect
        label="Dispatch status"
        value={value.dispatch}
        onChange={(dispatch) => patch({ dispatch })}
      >
        <option value="all">All dispatch</option>
        {refillDispatchStatuses.map((status) => (
          <option key={status} value={status}>
            {formatRefillDispatch(status)}
          </option>
        ))}
      </FilterSelect>
      <FilterSelect
        label="Receiving progress"
        value={value.receiving}
        onChange={(receiving) => patch({ receiving })}
      >
        <option value="all">All receiving</option>
        {refillReceivingCompletionLabels.map((label) => (
          <option key={label} value={label}>
            {formatRefillReceivingLabel(label)}
          </option>
        ))}
      </FilterSelect>
      <ReportDateField
        label="Created from"
        value={value.createdFrom}
        onChange={(createdFrom) => patch({ createdFrom })}
      />
      <ReportDateField
        label="Created to"
        value={value.createdTo}
        onChange={(createdTo) => patch({ createdTo })}
      />
    </div>
  )
}
