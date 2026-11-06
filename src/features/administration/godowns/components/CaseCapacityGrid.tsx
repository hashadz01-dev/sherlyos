import type { VisualSlot, VisualSlotStatus } from "@/lib/warehouse/capacity"

const statusClass: Record<VisualSlotStatus, string> = {
  occupied: "bg-emerald-600 text-white",
  available: "border border-slate-300 bg-white text-slate-700",
  reserved: "bg-sky-600 text-white",
  quarantined: "bg-orange-500 text-white",
  unavailable: "bg-slate-400 text-white",
}

const statusLabel: Record<VisualSlotStatus, string> = {
  occupied: "Occupied",
  available: "Empty",
  reserved: "Reserved",
  quarantined: "Quarantined",
  unavailable: "Unavailable",
}

export function CaseCapacityGrid({
  slots,
  selected,
  onSelect,
}: {
  slots: VisualSlot[]
  selected: number | null
  onSelect: (position: number) => void
}) {
  return (
    <div
      role="grid"
      aria-label="Visual case capacity, 5 rows of 10. Positions are not physically mapped cases."
      className="grid grid-cols-5 gap-1.5 sm:grid-cols-10"
    >
      {slots.map((slot) => {
        const selectedNow = selected === slot.position
        const label = [
          `Position ${slot.label}`,
          statusLabel[slot.status],
          slot.slice ? slot.slice.sku : "No single product assigned",
          "Visualized allocation, not physically mapped",
        ].join(", ")
        return (
          <button
            key={slot.position}
            type="button"
            role="gridcell"
            aria-pressed={selectedNow}
            aria-label={label}
            onClick={() => onSelect(slot.position)}
            className={`h-9 cursor-pointer rounded-md text-xs font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-slate-900 ${statusClass[slot.status]} ${selectedNow ? "ring-2 ring-slate-900 ring-offset-1" : ""}`}
          >
            {slot.label}
          </button>
        )
      })}
    </div>
  )
}
