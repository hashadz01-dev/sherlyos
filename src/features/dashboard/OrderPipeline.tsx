import { Fragment } from "react"
import { Link } from "react-router"
import { ChevronRight } from "lucide-react"
import { SUBMITTED_SCOPE_LABEL } from "@/lib/orders/verification"
import { DASHBOARD_DESTINATIONS } from "@/features/dashboard/metric-map"
import type { OperationsDashboard } from "@/lib/reports/api"

type Step = {
  label: string
  value: number | undefined
  to: string
  entity: string
}

/**
 * Compact connected pipeline. Stages may come from different entity tables;
 * tooltips name the underlying entity. Counts are never converted across strips.
 */
export function OrderPipeline({ data }: { data: OperationsDashboard }) {
  const steps: Step[] = []

  if (data.orders.visible) {
    steps.push(
      {
        label: "Draft",
        value: data.orders.draft,
        to: DASHBOARD_DESTINATIONS.orders,
        entity: "orders",
      },
      {
        label: SUBMITTED_SCOPE_LABEL,
        value: data.orders.submitted,
        to: DASHBOARD_DESTINATIONS.orderVerification,
        entity: "orders",
      },
      {
        label: "Held",
        value: data.orders.held,
        to: DASHBOARD_DESTINATIONS.orders,
        entity: "orders",
      },
      {
        label: "Verified",
        value: data.orders.verified,
        to: DASHBOARD_DESTINATIONS.orderVerification,
        entity: "orders",
      },
    )
  }

  if (data.picking.visible) {
    steps.push(
      {
        label: "Packing",
        value: data.picking.picking,
        to: DASHBOARD_DESTINATIONS.packing,
        entity: "stock_picking_requests",
      },
      {
        label: "Ready",
        value: data.picking.ready_for_dispatch,
        to: DASHBOARD_DESTINATIONS.dispatch,
        entity: "stock_picking_requests",
      },
      {
        label: "Blocked",
        value: data.picking.blocked,
        to: DASHBOARD_DESTINATIONS.packingExceptions,
        entity: "stock_picking_requests",
      },
    )
  }

  if (data.dispatch.visible) {
    steps.push(
      {
        label: "Preparing",
        value: data.dispatch.preparing,
        to: DASHBOARD_DESTINATIONS.dispatch,
        entity: "stock_dispatch_requests",
      },
      {
        label: "Dispatched",
        value: data.dispatch.dispatched,
        to: DASHBOARD_DESTINATIONS.dispatch,
        entity: "stock_dispatch_requests",
      },
      {
        label: "In transit",
        value: data.dispatch.in_transit,
        to: DASHBOARD_DESTINATIONS.deliveries,
        entity: "stock_dispatch_requests",
      },
      {
        label: "Delivered",
        value: data.dispatch.delivered,
        to: DASHBOARD_DESTINATIONS.deliveries,
        entity: "stock_dispatch_requests",
      },
      {
        label: "Exception",
        value: data.dispatch.exception,
        to: DASHBOARD_DESTINATIONS.dispatch,
        entity: "stock_dispatch_requests",
      },
    )
  } else if (data.deliveries.visible) {
    steps.push(
      {
        label: "Open runs",
        value: data.deliveries.assigned_open,
        to: DASHBOARD_DESTINATIONS.deliveries,
        entity: "assigned deliveries",
      },
      {
        label: "Delivered",
        value: data.deliveries.delivered,
        to: DASHBOARD_DESTINATIONS.deliveries,
        entity: "assigned deliveries",
      },
      {
        label: "Exception",
        value: data.deliveries.exception,
        to: DASHBOARD_DESTINATIONS.deliveries,
        entity: "assigned deliveries",
      },
    )
  }

  if (steps.length === 0) return null

  return (
    <section
      className="mb-4 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80"
      aria-labelledby="pipeline-heading"
    >
      <div className="mb-3 flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2
            id="pipeline-heading"
            className="text-sm font-semibold text-slate-900"
          >
            Order-to-delivery pipeline
          </h2>
          <p className="mt-0.5 text-xs text-muted-foreground">
            Status counts from orders, packing requests, and dispatches. These
            are different entities and are not conversion rates.
          </p>
        </div>
        {data.dispatch.visible &&
        data.dispatch.dispatched_cartons !== undefined ? (
          <p className="text-xs text-muted-foreground">
            Dispatched cartons (ledger):{" "}
            <span className="font-semibold tabular-nums text-slate-900">
              {data.dispatch.dispatched_cartons}
            </span>
          </p>
        ) : null}
      </div>

      <ol className="flex gap-1 overflow-x-auto pb-1">
        {steps.map((step, index) => (
          <Fragment key={`${step.entity}-${step.label}`}>
            {index > 0 ? (
              <li
                className="flex shrink-0 items-center text-slate-300"
                aria-hidden="true"
              >
                <ChevronRight className="size-4" />
              </li>
            ) : null}
            <li className="min-w-[5.5rem] flex-1">
              <Link
                to={step.to}
                title={`${step.label} · entity: ${step.entity}`}
                className="flex h-full flex-col rounded-xl bg-slate-50 px-2.5 py-2 ring-1 ring-slate-200/70 transition hover:bg-white hover:ring-slate-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
              >
                <span className="text-[10px] font-medium tracking-wide text-slate-500 uppercase">
                  {step.label}
                </span>
                {step.value === undefined ? (
                  <>
                    <span aria-hidden="true" className="mt-1 text-lg font-semibold">
                      —
                    </span>
                    <span className="sr-only">Not available</span>
                  </>
                ) : (
                  <span className="mt-1 text-lg font-semibold tabular-nums text-slate-950">
                    {step.value}
                  </span>
                )}
                <span className="mt-0.5 truncate text-[10px] text-slate-400">
                  {step.entity}
                </span>
              </Link>
            </li>
          </Fragment>
        ))}
      </ol>
    </section>
  )
}
