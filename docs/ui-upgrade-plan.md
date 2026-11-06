# SherlysOS UI upgrade plan

Skin and motion only. Business logic, RPCs, auth, permissions, routes, and data shapes stay as they are. Legal and operational warning text stays word for word.

## Stack already in the repo

| Piece | What we have |
|-------|----------------|
| React | 19.2 |
| Styling | Tailwind CSS 4 via `@tailwindcss/vite`, tokens in `src/index.css` (`@theme` + `:root`) |
| Components | shadcn-style primitives in `src/components/ui`, shared `PageHeader`, `StatusBadge`, `MetricCard`, `EmptyState`, `DataTable`, `AppModal` |
| Icons | `lucide-react` |
| Type | Plus Jakarta Sans (`@fontsource/plus-jakarta-sans`) |
| Motion today | `tw-animate-css` on dialogs only |

Tailwind does not need to be added. New colors, blur, and motion timings are CSS variables in `src/index.css`.

## Where styles are duplicated

Most screens rebuild the same white card (`rounded-2xl bg-white ring-1`) instead of `Card`. Status colors are split between `StatusBadge` tones and one-off Tailwind classes (`bg-amber-50`, `bg-emerald-50`). List pages share `DataTable` / `table.tsx`, but filter bars are local to each feature.

## Screen order

1. Tokens, shell, page header, badges, empty states, login atmosphere. **Started.**
2. Overview: bento, pipeline strip, real-value counters.
3. Orders, packing, dispatch, delivery, invoice notes, damage.
4. Stock, masters, administration, shops, godowns, audit timeline.
5. Login WebGL gallery only after a size check, lazy-loaded, with a static aurora fallback.

## Libraries not added yet

`motion`, GSAP, and a WebGL gallery are in the brief. They are not installed in this pass. Anything over about 50 KB gzipped needs a separate yes before it lands in the bundle. CSS transitions cover the shell enter, the active nav pill, and the dialog backdrop, and they turn off under `prefers-reduced-motion`.

## This pass

- Navy sidebar with a light top wash and a highlighted active item.
- Glass top bar and a faint aurora wash on the content canvas.
- Page titles slightly larger. Metric numbers use tabular figures. Values are still the real ones; they do not count up yet.
- Overview shows the same order counts again as a five-step strip (draft through awaiting packing). Hidden when orders are not authorized.
- Status palette tokens: green, blue, amber, red, and an orange quarantine tone.
- Empty-state icon tile. Login panel aurora. Dialog backdrop blur. Dialog text stays on an opaque surface.
