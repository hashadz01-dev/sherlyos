/** Shared copy for the unresolved inactive-godown reporting product decision. */
export function BranchFilterNote({
  operationalDropdown,
}: {
  operationalDropdown: boolean
}) {
  return (
    <p className="text-sm text-muted-foreground">
      {operationalDropdown
        ? "The branch dropdown lists active operational godowns only. Inactive godowns are not selectable and are not reactivated from this screen."
        : "Inactive godowns stay in the historical group so reporting can name them without turning them back on."}{" "}
      Authorized totals for “All authorized branches” still include stock at inactive godowns. That split is an unresolved product decision; this screen does not change those totals.
    </p>
  )
}
