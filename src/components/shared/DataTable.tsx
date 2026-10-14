import { useTable, type RowData } from "@tanstack/react-table"
import { EmptyState } from "@/components/shared/EmptyState"
import {
  appTableFeatures,
  type AppColumn,
} from "@/components/shared/table-columns"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"

export function DataTable<TData extends RowData>({
  columns,
  data,
  emptyTitle,
  emptyDescription,
}: {
  columns: AppColumn<TData>[]
  data: TData[]
  emptyTitle: string
  emptyDescription: string
}) {
  const table = useTable({
    features: appTableFeatures,
    columns,
    data,
  })
  const headerGroups = table.getHeaderGroups()
  const rows = table.getRowModel().rows
  const columnCount = headerGroups[0]?.headers.length ?? columns.length

  return (
    <Table>
      <TableHeader>
        {headerGroups.map((group) => (
          <TableRow key={group.id}>
            {group.headers.map((header) => (
              <TableHead key={header.id} className="text-slate-500">
                {header.isPlaceholder ? null : (
                  <table.FlexRender header={header} />
                )}
              </TableHead>
            ))}
          </TableRow>
        ))}
      </TableHeader>
      <TableBody>
        {rows.length === 0 ? (
          <TableRow>
            <TableCell colSpan={columnCount} className="p-0">
              <EmptyState title={emptyTitle} description={emptyDescription} />
            </TableCell>
          </TableRow>
        ) : (
          rows.map((row) => (
            <TableRow key={row.id}>
              {row.getAllCells().map((cell) => (
                <TableCell key={cell.id}>
                  <table.FlexRender cell={cell} />
                </TableCell>
              ))}
            </TableRow>
          ))
        )}
      </TableBody>
    </Table>
  )
}
