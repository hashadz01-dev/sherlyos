import {
  createColumnHelper,
  tableFeatures,
  type ColumnDef,
  type RowData,
} from "@tanstack/react-table"

export const appTableFeatures = tableFeatures({})

export type AppColumn<TData extends RowData> = ColumnDef<
  typeof appTableFeatures,
  TData
>

export function createAppColumnHelper<TData extends RowData>() {
  return createColumnHelper<typeof appTableFeatures, TData>()
}
