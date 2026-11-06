import { useState, type ReactNode } from "react"
import { MoreHorizontal } from "lucide-react"
import { cn } from "cn"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { Skeleton } from "@/components/ui/skeleton"
import { formatPackAmount } from "@/lib/masters/pack-amount"

export type ProductLayout = "cards" | "list"

const LAYOUT_KEY = "sherlyos.products.layout"

export type ProductCardData = {
  id: string
  sku: string
  name: string
  is_active: boolean
  expiry_policy: "expiry_controlled" | "non_expiring" | null
  billing_unit?: string | null
  billed_units_per_case?: number | string | null
}

type TileTint = {
  wash: string
  ink: string
  edge: string
  hi: string
}

/**
 * Calm washes, not brand colours. The same category name always lands on
 * the same wash because the index is a hash, not the row order.
 */
const CATEGORY_TINTS: readonly TileTint[] = [
  { wash: "#e7eef6", ink: "#3d5168", edge: "#8aa0b8", hi: "#f7fafc" },
  { wash: "#e7f3ee", ink: "#3c5a4c", edge: "#7eaa96", hi: "#f6fbf8" },
  { wash: "#f3eee6", ink: "#5c5144", edge: "#b5a48e", hi: "#fbf8f3" },
  { wash: "#eceaf6", ink: "#4a4660", edge: "#9b96b5", hi: "#f8f7fb" },
  { wash: "#f6eee9", ink: "#5c463e", edge: "#c09a8e", hi: "#fbf7f5" },
  { wash: "#eef3e8", ink: "#46533c", edge: "#9aab86", hi: "#f7faf4" },
  { wash: "#e8f1f4", ink: "#3d5560", edge: "#86a8b4", hi: "#f5fafb" },
  { wash: "#f4efe8", ink: "#5a4b38", edge: "#c2ae90", hi: "#fbf8f4" },
]

/** Shared by every product that has no resolved category name. */
const NEUTRAL_TINT: TileTint = {
  wash: "#eef1f4",
  ink: "#415066",
  edge: "#a9b8c9",
  hi: "#f7f9fb",
}

/**
 * Remembers Cards vs List. Storage can throw in private mode, so a failed
 * read stays on Cards and a failed write still updates this visit.
 */
export function readProductLayout(): ProductLayout {
  try {
    return window.localStorage.getItem(LAYOUT_KEY) === "list" ? "list" : "cards"
  } catch {
    return "cards"
  }
}

export function writeProductLayout(layout: ProductLayout) {
  try {
    window.localStorage.setItem(LAYOUT_KEY, layout)
  } catch {
    // The in-memory toggle still applies for this visit.
  }
}

/**
 * A missing link uses the product dialog's empty option ("No category").
 * An id whose name has not arrived yet keeps the old row's placeholder
 * and does not pick a tint, so the wash does not change when the name loads.
 */
export function productRelationLabel(
  id: string | null,
  names: ReadonlyMap<string, string>,
  missing: string,
  unresolved: string,
) {
  if (!id) return { label: missing, tintName: null }
  const name = names.get(id)
  if (!name) return { label: unresolved, tintName: null }
  return { label: name, tintName: name }
}

/** FNV-1a. Stable across sessions for a given category name. */
export function categoryTint(categoryName: string | null): TileTint {
  const name = categoryName?.trim()
  if (!name) return NEUTRAL_TINT
  let hash = 2166136261
  for (let index = 0; index < name.length; index += 1) {
    hash ^= name.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return CATEGORY_TINTS[(hash >>> 0) % CATEGORY_TINTS.length]
}

/**
 * The products table has no photo column, and search_products does not
 * return one. If a later row includes an image field, the tile uses it
 * and falls back when the value is blank.
 */
export function readProductImage(product: ProductCardData): string | null {
  const extra = product as ProductCardData & {
    image_url?: unknown
    image?: unknown
    photo_url?: unknown
  }
  for (const value of [extra.image_url, extra.image, extra.photo_url]) {
    if (typeof value === "string" && value.trim()) return value.trim()
  }
  return null
}

export function ProductLayoutToggle({
  value,
  onChange,
}: {
  value: ProductLayout
  onChange: (value: ProductLayout) => void
}) {
  const options = [
    ["cards", "Cards"],
    ["list", "List"],
  ] as const

  return (
    <div
      role="group"
      aria-label="Product layout"
      className="inline-flex rounded-lg border border-border bg-card p-0.5"
    >
      {options.map(([option, label]) => {
        const selected = value === option
        return (
          <Button
            key={option}
            type="button"
            size="sm"
            variant={selected ? "secondary" : "ghost"}
            aria-pressed={selected}
            className={selected ? "font-semibold" : undefined}
            onClick={() => onChange(option)}
          >
            {label}
          </Button>
        )
      })}
    </div>
  )
}

const cardGridClass =
  "grid list-none grid-cols-[repeat(auto-fill,minmax(280px,1fr))] gap-5"

export function ProductCardGrid({ children }: { children: ReactNode }) {
  return <ul className={cn(cardGridClass, "p-0")}>{children}</ul>
}

export function ProductCardSkeletons() {
  return (
    <div role="status">
      <p className="sr-only">Loading records</p>
      <ul aria-hidden="true" className={cn(cardGridClass, "p-0")}>
        {Array.from({ length: 8 }, (_, index) => (
          <li key={index} className="min-w-0">
            <div className="overflow-hidden rounded-2xl border border-border bg-card shadow-sm">
              <Skeleton className="aspect-[16/10] w-full rounded-none motion-reduce:animate-none" />
              <div className="space-y-2 p-4">
                <Skeleton className="h-4 w-4/5 motion-reduce:animate-none" />
                <Skeleton className="h-3 w-3/5 motion-reduce:animate-none" />
                <Skeleton className="h-5 w-28 motion-reduce:animate-none" />
              </div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  )
}

/**
 * Stroke-only carton in the hairline plate language: light top, mid edge,
 * darker front. Decorative; the category label next to it names the tile.
 */
function CartonGlyph({ tint }: { tint: TileTint }) {
  return (
    <svg viewBox="0 0 88 72" className="h-14 w-16" aria-hidden="true">
      <polygon
        points="44,14 66,26 44,38 22,26"
        fill={tint.hi}
        stroke={tint.edge}
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <polygon
        points="22,26 44,38 44,58 22,46"
        fill="none"
        stroke={tint.ink}
        strokeWidth="1.4"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
      <polygon
        points="66,26 44,38 44,58 66,46"
        fill="none"
        stroke={tint.edge}
        strokeWidth="1.4"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
      <path
        d="M44 14 V38 M32 32 L44 38 L56 32"
        fill="none"
        stroke={tint.ink}
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function MetaChip({
  children,
  tone,
}: {
  children: ReactNode
  tone: "neutral" | "warning"
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        tone === "warning"
          ? "bg-[var(--status-warning-bg)] text-[var(--status-warning)]"
          : "bg-muted text-muted-foreground",
      )}
    >
      {children}
    </span>
  )
}

export function ProductCard({
  product,
  categoryLabel,
  supplierLabel,
  categoryTintName,
  canClassifyExpiry,
  canSetBilling,
  canManage,
  onEdit,
  onClassify,
  onBilling,
  onToggleStatus,
}: {
  product: ProductCardData
  categoryLabel: string
  supplierLabel: string
  categoryTintName: string | null
  canClassifyExpiry: boolean
  canSetBilling: boolean
  canManage: boolean
  onEdit: () => void
  onClassify: () => void
  onBilling: () => void
  onToggleStatus: () => void
}) {
  const [imageFailed, setImageFailed] = useState(false)
  const imageUrl = imageFailed ? null : readProductImage(product)
  const tint = categoryTint(categoryTintName)
  const titleId = `product-${product.id}-title`
  const packAmount = formatPackAmount(product.billed_units_per_case, product.billing_unit)
  const expiryLabel = product.expiry_policy ?? "unclassified"
  const showActions = canClassifyExpiry || canSetBilling || canManage
  const statusLabel = product.is_active ? "Active" : "Inactive"

  return (
    <article
      aria-labelledby={titleId}
      className={cn(
        "flex h-full flex-col overflow-hidden rounded-2xl border border-border bg-card shadow-sm",
        "transition-[transform,box-shadow] duration-[var(--motion-micro)] ease-[var(--ease-out)]",
        "hover:-translate-y-0.5 hover:shadow-md",
        "focus-within:-translate-y-0.5 focus-within:shadow-md",
        "motion-reduce:transition-none motion-reduce:hover:translate-y-0 motion-reduce:focus-within:translate-y-0",
      )}
    >
      <div
        className="relative aspect-[16/10] overflow-hidden"
        style={{ backgroundColor: tint.wash }}
      >
        {imageUrl ? (
          <img
            src={imageUrl}
            alt=""
            className="h-full w-full object-cover"
            onError={() => setImageFailed(true)}
          />
        ) : (
          <div className="flex h-full flex-col items-center justify-center gap-1.5 px-12">
            <CartonGlyph tint={tint} />
            <p
              className="line-clamp-2 text-center text-xs font-medium"
              style={{ color: tint.ink }}
            >
              {categoryLabel}
            </p>
          </div>
        )}
        <div className="absolute top-3 right-3">
          <StatusBadge tone={product.is_active ? "success" : "neutral"}>
            {statusLabel}
          </StatusBadge>
        </div>
      </div>
      <div className="flex flex-1 flex-col gap-2 px-4 pt-3.5 pb-3">
        <h3 id={titleId} className="text-sm leading-5 font-semibold text-foreground">
          <button
            type="button"
            className="line-clamp-2 w-full rounded-sm text-left outline-none focus-visible:ring-3 focus-visible:ring-ring/50"
            onClick={onEdit}
          >
            {product.name}
          </button>
        </h3>
        <p className="text-xs leading-5 text-muted-foreground">
          <span className="font-mono">{product.sku}</span>
          <span>{` · ${categoryLabel} · ${supplierLabel}`}</span>
        </p>
        <div className="mt-auto flex flex-wrap gap-1.5 pt-1">
          {packAmount ? <MetaChip tone="neutral">{packAmount}</MetaChip> : null}
          <MetaChip tone={product.expiry_policy ? "neutral" : "warning"}>{expiryLabel}</MetaChip>
        </div>
      </div>
      {showActions ? (
        <footer className="flex flex-wrap items-center gap-1.5 border-t border-border px-3 py-2.5">
          {canClassifyExpiry ? (
            <Button type="button" variant="secondary" size="xs" onClick={onClassify}>
              Classify expiry
            </Button>
          ) : null}
          {canSetBilling ? (
            <Button type="button" variant="secondary" size="xs" onClick={onBilling}>
              Billing units
            </Button>
          ) : null}
          {canManage ? (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button
                  type="button"
                  variant="outline"
                  size="icon-sm"
                  className="ml-auto"
                  aria-label={`More actions for ${product.name}`}
                >
                  <MoreHorizontal />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onSelect={onToggleStatus}>
                  {product.is_active ? "Deactivate" : "Activate"}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          ) : null}
        </footer>
      ) : null}
    </article>
  )
}
