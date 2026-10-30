import { useEffect, useMemo, useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  sourceRefsForScenario,
  type SourceRefs,
} from "@/features/damage/utils/draft"
import {
  listDamageReportSources,
  type DamageSourceCatalogs,
  type DamageSourceItem,
} from "@/lib/damage/api"
import type { DamageScenario } from "@/lib/damage/rules"

export function DamageSourcePicker({
  scenario,
  godownId,
  selectedId,
  disabled,
  onSelect,
  onCatalogs,
}: {
  scenario: DamageScenario
  godownId: string
  selectedId: string
  disabled?: boolean
  onSelect: (
    item: DamageSourceItem,
    catalogs: DamageSourceCatalogs,
    refs: SourceRefs,
  ) => void
  onCatalogs?: (catalogs: DamageSourceCatalogs) => void
}) {
  const [search, setSearch] = useState("")
  const [page, setPage] = useState(1)
  const [catalogSearch, setCatalogSearch] = useState("")
  const [catalogPage, setCatalogPage] = useState(1)
  const sources = useQuery({
    queryKey: [
      "damage-sources",
      scenario,
      godownId,
      search,
      page,
      catalogSearch,
      catalogPage,
    ],
    queryFn: () =>
      listDamageReportSources({
        scenario,
        targetGodown: godownId,
        search: search.trim() || null,
        page,
        pageSize: 20,
        catalogSearch: catalogSearch.trim() || null,
        catalogPage,
      }),
    enabled: Boolean(scenario && godownId),
  })

  const items = sources.data?.items ?? []
  const catalogs = sources.data?.catalogs ?? {}
  const total = sources.data?.total ?? 0
  const totalPages = Math.max(
    1,
    Math.ceil(total / (sources.data?.page_size ?? 20)),
  )

  useEffect(() => {
    if (sources.data?.catalogs) onCatalogs?.(sources.data.catalogs)
  }, [sources.data, onCatalogs])

  useEffect(() => {
    if (scenario !== "storage" || !sources.data?.items[0] || selectedId) return
    const item = sources.data.items[0]
    onSelect(
      item,
      sources.data.catalogs ?? {},
      sourceRefsForScenario("storage", item),
    )
  }, [scenario, sources.data, selectedId, onSelect])

  const helper = useMemo(() => {
    if (scenario === "refill_supply" || scenario === "unloading") {
      return "Posted receipts with remaining damaged cases at this godown."
    }
    if (scenario === "storage") {
      return "Authorized godown crates and products with on-hand carton cases."
    }
    if (scenario === "loading") {
      return "Eligible packing allocations that have not been consumed."
    }
    if (scenario === "transit") {
      return "Consumed dispatches you are authorized to report."
    }
    return "Active shops. Custody confirmation is a later workflow."
  }, [scenario])

  function applyItem(item: DamageSourceItem) {
    onSelect(item, catalogs, sourceRefsForScenario(scenario, item))
  }

  if (!godownId) {
    return (
      <p className="text-sm text-muted-foreground">
        Select a godown before choosing a source.
      </p>
    )
  }

  return (
    <section className="grid gap-3">
      <div>
        <h2 className="text-sm font-semibold">Source</h2>
        <p className="text-xs text-muted-foreground">{helper}</p>
      </div>
      {scenario !== "storage" ? (
        <Label className="grid gap-2 text-sm font-medium">
          Search sources
          <Input
            value={search}
            disabled={disabled}
            onChange={(event) => {
              setSearch(event.target.value)
              setPage(1)
            }}
          />
        </Label>
      ) : null}
      {sources.isLoading ? (
        <LoadingBlock label="Loading authorized sources" />
      ) : null}
      {sources.error ? (
        <p role="alert" className="text-sm text-destructive">
          {sources.error.message}
        </p>
      ) : null}
      {sources.data && items.length === 0 ? (
        <EmptyState
          title="No eligible sources"
          description="No authorized source documents match this scenario and godown."
        />
      ) : null}
      <ul className="grid gap-2">
        {items.map((item) => (
          <li key={item.id}>
            <button
              type="button"
              disabled={disabled}
              aria-label={`Select source ${item.label}`}
              onClick={() => applyItem(item)}
              className={`w-full rounded-2xl p-3 text-left ring-1 ${
                selectedId === item.id ? "ring-foreground" : "ring-border"
              }`}
            >
              <p className="text-sm font-medium">{item.label}</p>
              <p className="text-xs text-muted-foreground">
                {item.supplier_name ?? item.status ?? item.kind}
                {item.received_date ? ` · ${item.received_date}` : ""}
              </p>
            </button>
          </li>
        ))}
      </ul>
      {scenario === "shop_return" ? (
        <div className="grid gap-2">
          <Label className="grid gap-2 text-sm font-medium">
            Search products
            <Input
              value={catalogSearch}
              disabled={disabled}
              onChange={(event) => {
                setCatalogSearch(event.target.value)
                setCatalogPage(1)
              }}
            />
          </Label>
          <p className="text-xs text-muted-foreground">
            {(
              catalogs.products_total ??
              catalogs.products?.length ??
              0
            ).toLocaleString()}{" "}
            eligible products. Page {catalogs.products_page ?? catalogPage} of{" "}
            {Math.max(
              1,
              Math.ceil(
                (catalogs.products_total ?? 0) /
                  (sources.data?.page_size ?? 20),
              ),
            )}
            .
          </p>
          {(catalogs.products_total ?? 0) > (sources.data?.page_size ?? 20) ? (
            <div className="flex gap-2">
              <Button
                type="button"
                variant="outline"
                disabled={catalogPage <= 1 || disabled}
                onClick={() =>
                  setCatalogPage((current) => Math.max(1, current - 1))
                }
              >
                Previous products
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={
                  catalogPage >=
                    Math.max(
                      1,
                      Math.ceil(
                        (catalogs.products_total ?? 0) /
                          (sources.data?.page_size ?? 20),
                      ),
                    ) || disabled
                }
                onClick={() => setCatalogPage((current) => current + 1)}
              >
                Next products
              </Button>
            </div>
          ) : null}
        </div>
      ) : null}
      {total > 20 ? (
        <div className="flex items-center justify-between gap-2">
          <p className="text-xs text-muted-foreground">
            Page {page} of {totalPages}
          </p>
          <div className="flex gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={page <= 1 || disabled}
              onClick={() => setPage((current) => Math.max(1, current - 1))}
            >
              Previous
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={page >= totalPages || disabled}
              onClick={() => setPage((current) => current + 1)}
            >
              Next
            </Button>
          </div>
        </div>
      ) : null}
    </section>
  )
}
