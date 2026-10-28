import { useEffect, useId, useState } from "react"
import { useQuery } from "@tanstack/react-query"
import {
  getProduct,
  productSearchLabel,
  searchProducts,
  type ProductSearchRow,
} from "@/lib/masters/product-search"

/**
 * Searchable product picker. Results come from search_products, not a 1,000-row dump.
 * Duplicate names stay distinct because options are keyed by id and labeled with SKU.
 */
export function ProductSearchField({
  label,
  value,
  onChange,
  required = false,
  activeOnly = true,
  supplierId = null,
  disabled = false,
  error,
}: {
  label: string
  value: string
  onChange: (productId: string, product: ProductSearchRow | null) => void
  required?: boolean
  activeOnly?: boolean
  supplierId?: string | null
  disabled?: boolean
  error?: string
}) {
  const listId = useId()
  const [typed, setTyped] = useState("")
  const [debounced, setDebounced] = useState("")
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const handle = window.setTimeout(() => setDebounced(typed.trim()), 200)
    return () => window.clearTimeout(handle)
  }, [typed])

  const selected = useQuery({
    queryKey: ["product-by-id", value],
    queryFn: () => getProduct(value),
    enabled: value !== "",
  })

  const matches = useQuery({
    queryKey: ["product-search", debounced, activeOnly, supplierId],
    queryFn: () =>
      searchProducts({
        query: debounced,
        activeOnly,
        supplierId,
      }),
    enabled: open && !disabled,
  })

  const selectedLabel = selected.data ? productSearchLabel(selected.data) : ""
  const display = open ? typed : selectedLabel
  const rows = matches.data ?? []

  return (
    <div className="grid gap-1">
      <label className="grid gap-1 text-sm">
        {label}
        <input
          role="combobox"
          aria-label={label}
          aria-expanded={open}
          aria-controls={listId}
          aria-autocomplete="list"
          autoComplete="off"
          disabled={disabled}
          required={required && value === ""}
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm"
          value={display}
          placeholder="Type a SKU or name"
          onFocus={() => {
            setTyped(selectedLabel)
            setOpen(true)
          }}
          onChange={(event) => {
            setTyped(event.target.value)
            setOpen(true)
            if (value) onChange("", null)
          }}
          onBlur={() => {
            window.setTimeout(() => setOpen(false), 150)
          }}
        />
      </label>
      {open ? (
        <ul
          id={listId}
          role="listbox"
          className="max-h-48 overflow-auto rounded-lg border border-input bg-card text-sm shadow-sm"
        >
          {matches.isLoading ? (
            <li className="px-2.5 py-2 text-muted-foreground">Searching catalog…</li>
          ) : rows.length === 0 ? (
            <li className="px-2.5 py-2 text-muted-foreground">No matching products</li>
          ) : (
            rows.map((row) => (
              <li key={row.id} role="option" aria-selected={row.id === value}>
                <button
                  type="button"
                  className="w-full px-2.5 py-2 text-left hover:bg-muted"
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => {
                    onChange(row.id, row)
                    setTyped(productSearchLabel(row))
                    setOpen(false)
                  }}
                >
                  {productSearchLabel(row)}
                </button>
              </li>
            ))
          )}
        </ul>
      ) : null}
      {error ? (
        <span role="alert" className="text-sm text-destructive">
          {error}
        </span>
      ) : null}
    </div>
  )
}
