import { Label } from "@/components/ui/label"
import {
  damageScenarioDescriptions,
  formatDamageScenario,
} from "@/features/damage/utils/labels"
import { damageScenarios, type DamageScenario } from "@/lib/damage/rules"

export function DamageScenarioPicker({
  value,
  allowed,
  disabled,
  onChange,
}: {
  value: DamageScenario | ""
  allowed: DamageScenario[]
  disabled?: boolean
  onChange: (scenario: DamageScenario) => void
}) {
  return (
    <fieldset className="grid gap-3">
      <legend className="text-sm font-semibold">Scenario</legend>
      <div className="grid gap-2 md:grid-cols-2">
        {damageScenarios.map((scenario) => {
          const enabled = allowed.includes(scenario)
          return (
            <label
              key={scenario}
              className={`rounded-2xl p-3 ring-1 ${
                value === scenario ? "ring-foreground" : "ring-border"
              } ${enabled ? "bg-card" : "bg-muted/40 text-muted-foreground"}`}
            >
              <span className="flex items-start gap-2">
                <input
                  type="radio"
                  name="damage-scenario"
                  className="mt-1"
                  value={scenario}
                  checked={value === scenario}
                  disabled={disabled || !enabled}
                  onChange={() => onChange(scenario)}
                />
                <span>
                  <span className="block text-sm font-medium">
                    {formatDamageScenario(scenario)}
                  </span>
                  <span className="mt-1 block text-xs text-muted-foreground">
                    {damageScenarioDescriptions[scenario]}
                  </span>
                  {!enabled ? (
                    <span className="mt-1 block text-xs">
                      Not permitted for this account.
                    </span>
                  ) : null}
                </span>
              </span>
            </label>
          )
        })}
      </div>
      <Label className="sr-only" htmlFor="damage-scenario">
        Damage scenario
      </Label>
    </fieldset>
  )
}
