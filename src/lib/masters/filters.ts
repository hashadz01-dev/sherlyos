export function matchesSearch(query: string, values: Array<string | null | undefined>) {
  const needle = query.trim().toLowerCase()
  if (!needle) return true
  return values.some((value) => value?.toLowerCase().includes(needle))
}

export function matchesStatus(filter: string, isActive: boolean) {
  if (filter === "active") return isActive
  if (filter === "inactive") return !isActive
  return true
}