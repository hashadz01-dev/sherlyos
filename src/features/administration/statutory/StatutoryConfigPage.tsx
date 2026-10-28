/**
 * M7.5C.1 statutory configuration workspace.
 * Records stay drafts until statutory.config.verify. Completeness cannot issue a tax invoice.
 */
import { useState, type ReactNode } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { PageHeader } from "@/components/shared/PageHeader"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { ProductSearchField } from "@/components/forms/ProductSearchField"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { assessInvoiceFinalizationReadiness } from "@/lib/invoices/api"
import { loadRows } from "@/lib/masters/api"
import {
  listProductHsnClassifications,
  listShopTaxIdentities,
  listStatutoryPolicies,
  listStatutorySellerIdentities,
  listTaxRateSchedules,
  statutoryKeys,
  submitProductHsnClassification,
  submitShopTaxIdentity,
  submitStatutoryPolicy,
  submitStatutorySellerIdentity,
  submitTaxRateSchedule,
  upsertProductHsnClassification,
  upsertShopTaxIdentity,
  upsertStatutoryPolicy,
  upsertStatutorySellerIdentity,
  upsertTaxRateSchedule,
  verifyProductHsnClassification,
  verifyShopTaxIdentity,
  verifyStatutoryPolicy,
  verifyStatutorySellerIdentity,
  verifyTaxRateSchedule,
} from "@/lib/statutory/api"
import {
  STATUTORY_ISSUANCE_BANNER,
  isVerifiedStatutoryStatus,
  shopRegistrationStatuses,
  statutoryPolicyKindLabel,
  statutoryPolicyKinds,
  statutoryStatusLabel,
} from "@/lib/statutory/rules"
import { notify } from "@/lib/utilities/notify"

type Shop = { id: string; name: string }

function statusTone(status: string) {
  if (status === "verified") return "success" as const
  if (status === "submitted") return "warning" as const
  if (status === "superseded" || status === "cancelled") return "danger" as const
  return "neutral" as const
}

export function StatutoryConfigPage() {
  useDocumentTitle("Statutory configuration")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const canPrepare = can("statutory.config.prepare")
  const canVerify = can("statutory.config.verify")

  const readiness = useQuery({
    queryKey: statutoryKeys.readiness,
    queryFn: () => assessInvoiceFinalizationReadiness(),
  })
  const sellers = useQuery({
    queryKey: statutoryKeys.sellers,
    queryFn: listStatutorySellerIdentities,
  })
  const shopTaxes = useQuery({
    queryKey: statutoryKeys.shops("all"),
    queryFn: () => listShopTaxIdentities(),
  })
  const hsnRows = useQuery({
    queryKey: statutoryKeys.hsn("all"),
    queryFn: () => listProductHsnClassifications(),
  })
  const rates = useQuery({
    queryKey: statutoryKeys.rates,
    queryFn: listTaxRateSchedules,
  })
  const policies = useQuery({
    queryKey: statutoryKeys.policies,
    queryFn: listStatutoryPolicies,
  })
  const shops = useQuery({
    queryKey: ["shops"],
    queryFn: () => loadRows<Shop>("shops", "id, name", "name"),
  })

  const [seller, setSeller] = useState({
    ownership_code: "",
    legal_name: "",
    registered_address: "",
    state_code: "",
    gstin: "",
    pan: "",
    signature_caption: "",
    effective_from: "",
  })
  const [shopForm, setShopForm] = useState({
    shop_id: "",
    billing_name: "",
    billing_address: "",
    registration_status: "unknown",
    gstin: "",
    effective_from: "",
  })
  const [hsnForm, setHsnForm] = useState({
    product_id: "",
    classification_kind: "hsn",
    hsn_sac_code: "",
    effective_from: "",
  })
  const [rateForm, setRateForm] = useState({
    schedule_code: "",
    treatment: "unspecified",
    cgst_rate: "",
    sgst_rate: "",
    igst_rate: "",
    effective_from: "",
  })
  const [policyKind, setPolicyKind] = useState<(typeof statutoryPolicyKinds)[number]>(
    "invoice_date",
  )
  const [policyPayload, setPolicyPayload] = useState('{"rule":"unspecified"}')
  const [policyFrom, setPolicyFrom] = useState("")

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: ["statutory-seller-identities"] })
    await queryClient.invalidateQueries({ queryKey: ["statutory-shop-tax"] })
    await queryClient.invalidateQueries({ queryKey: ["statutory-hsn"] })
    await queryClient.invalidateQueries({ queryKey: ["statutory-tax-schedules"] })
    await queryClient.invalidateQueries({ queryKey: ["statutory-policies"] })
    await queryClient.invalidateQueries({ queryKey: ["statutory-readiness"] })
  }

  const saveSeller = useMutation({
    mutationFn: () => {
      const current = (sellers.data ?? []).find(
        (row) =>
          row.ownership_code === seller.ownership_code &&
          (row.status === "draft" || row.status === "submitted"),
      )
      return upsertStatutorySellerIdentity({
        p_id: current?.id ?? null,
        p_ownership_code: seller.ownership_code,
        p_legal_name: seller.legal_name,
        p_registered_address: seller.registered_address,
        p_state_code: seller.state_code || null,
        p_gstin: seller.gstin || null,
        p_pan: seller.pan || null,
        p_signature_caption: seller.signature_caption || null,
        p_effective_from: seller.effective_from,
        p_expected_version: current?.version ?? 1,
      })
    },
    onSuccess: async () => {
      notify.success("Seller identity draft saved. This is not a tax invoice.")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const saveShop = useMutation({
    mutationFn: () => {
      const current = (shopTaxes.data ?? []).find(
        (row) =>
          row.shop_id === shopForm.shop_id &&
          (row.status === "draft" || row.status === "submitted"),
      )
      return upsertShopTaxIdentity({
        p_id: current?.id ?? null,
        p_shop_id: shopForm.shop_id,
        p_billing_name: shopForm.billing_name,
        p_billing_address: shopForm.billing_address,
        p_registration_status: shopForm.registration_status,
        p_gstin: shopForm.gstin || null,
        p_effective_from: shopForm.effective_from,
        p_expected_version: current?.version ?? 1,
      })
    },
    onSuccess: async () => {
      notify.success("Shop tax identity draft saved")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const saveHsn = useMutation({
    mutationFn: () => {
      const current = (hsnRows.data ?? []).find(
        (row) =>
          row.product_id === hsnForm.product_id &&
          (row.status === "draft" || row.status === "submitted"),
      )
      return upsertProductHsnClassification({
        p_id: current?.id ?? null,
        p_product_id: hsnForm.product_id,
        p_classification_kind: hsnForm.classification_kind,
        p_hsn_sac_code: hsnForm.hsn_sac_code,
        p_effective_from: hsnForm.effective_from,
        p_expected_version: current?.version ?? 1,
      })
    },
    onSuccess: async () => {
      notify.success("HSN draft saved. GST is not calculated.")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const saveRate = useMutation({
    mutationFn: () => {
      const current = (rates.data ?? []).find(
        (row) =>
          row.schedule_code === rateForm.schedule_code &&
          (row.status === "draft" || row.status === "submitted"),
      )
      return upsertTaxRateSchedule({
        p_id: current?.id ?? null,
        p_schedule_code: rateForm.schedule_code,
        p_treatment: rateForm.treatment,
        p_cgst_rate: rateForm.cgst_rate === "" ? null : Number(rateForm.cgst_rate),
        p_sgst_rate: rateForm.sgst_rate === "" ? null : Number(rateForm.sgst_rate),
        p_igst_rate: rateForm.igst_rate === "" ? null : Number(rateForm.igst_rate),
        p_effective_from: rateForm.effective_from,
        p_expected_version: current?.version ?? 1,
      })
    },
    onSuccess: async () => {
      notify.success("Tax schedule draft saved. Rates are not applied to invoices.")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const savePolicy = useMutation({
    mutationFn: () => {
      const current = (policies.data ?? []).find(
        (row) =>
          row.policy_kind === policyKind &&
          (row.status === "draft" || row.status === "submitted"),
      )
      return upsertStatutoryPolicy({
        p_id: current?.id ?? null,
        p_policy_kind: policyKind,
        p_payload: JSON.parse(policyPayload) as Record<string, unknown>,
        p_effective_from: policyFrom,
        p_expected_version: current?.version ?? 1,
      })
    },
    onSuccess: async () => {
      notify.success("Policy draft saved. Issuance stays disabled.")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })

  return (
    <section className="min-w-0 grid gap-6">
      <PageHeader
        title="Statutory configuration"
        description="Accountant-prepared GST identity, HSN, and policy records. These drafts cannot issue a tax invoice."
      />
      <p
        role="status"
        className="rounded-2xl bg-red-50 px-4 py-3 text-sm font-semibold tracking-wide text-red-800 ring-1 ring-red-200"
      >
        {STATUTORY_ISSUANCE_BANNER}
      </p>

      {readiness.isLoading ? <LoadingBlock label="Loading readiness" /> : null}
      {readiness.data ? (
        <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
          <h2 className="text-sm font-semibold">Statutory readiness</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            ready={String(readiness.data.ready)} · issuance blocked. Completing these
            records cannot enable finalization until M7.5C.2.
          </p>
          <ul className="mt-3 list-disc space-y-1 pl-5 text-sm">
            {(readiness.data.blockers ?? []).map((blocker) => (
              <li key={blocker.code}>{blocker.message}</li>
            ))}
          </ul>
        </div>
      ) : null}

      <ConfigSection title="Seller identity">
        {(sellers.data ?? []).map((row) => (
          <ConfigRow
            key={row.id}
            title={row.legal_name}
            detail={`${row.ownership_code} · GSTIN ${row.gstin ?? "none"}`}
            status={row.status}
            canPrepare={canPrepare && row.status === "draft"}
            canVerify={canVerify && row.status === "submitted"}
            onSubmit={() =>
              submitStatutorySellerIdentity(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
            onVerify={() =>
              verifyStatutorySellerIdentity(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
          />
        ))}
        {canPrepare ? (
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <Field label="Ownership code" value={seller.ownership_code} onChange={(v) => setSeller({ ...seller, ownership_code: v })} />
            <Field label="Legal name" value={seller.legal_name} onChange={(v) => setSeller({ ...seller, legal_name: v })} />
            <Field label="Registered address" value={seller.registered_address} onChange={(v) => setSeller({ ...seller, registered_address: v })} />
            <Field label="State code" value={seller.state_code} onChange={(v) => setSeller({ ...seller, state_code: v })} />
            <Field label="GSTIN" value={seller.gstin} onChange={(v) => setSeller({ ...seller, gstin: v })} />
            <Field label="PAN" value={seller.pan} onChange={(v) => setSeller({ ...seller, pan: v })} />
            <Field label="Signature caption" value={seller.signature_caption} onChange={(v) => setSeller({ ...seller, signature_caption: v })} />
            <Field label="Effective from" type="date" value={seller.effective_from} onChange={(v) => setSeller({ ...seller, effective_from: v })} />
            <Button type="button" onClick={() => saveSeller.mutate()} disabled={saveSeller.isPending}>
              Save seller draft
            </Button>
          </div>
        ) : null}
      </ConfigSection>

      <ConfigSection title="Customer tax details">
        {(shopTaxes.data ?? []).map((row) => (
          <ConfigRow
            key={row.id}
            title={row.billing_name}
            detail={`${row.shop_name ?? row.shop_id} · ${row.registration_status} · GSTIN ${row.gstin ?? "none"}`}
            status={row.status}
            canPrepare={canPrepare && row.status === "draft"}
            canVerify={canVerify && row.status === "submitted"}
            onSubmit={() =>
              submitShopTaxIdentity(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
            onVerify={() =>
              verifyShopTaxIdentity(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
          />
        ))}
        {canPrepare ? (
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <label className="grid gap-1 text-sm font-medium">
              Shop
              <select
                className="h-10 rounded-lg border border-input px-2.5 text-sm font-normal"
                value={shopForm.shop_id}
                onChange={(event) => setShopForm({ ...shopForm, shop_id: event.target.value })}
              >
                <option value="">Select shop</option>
                {(shops.data ?? []).map((shop) => (
                  <option key={shop.id} value={shop.id}>
                    {shop.name}
                  </option>
                ))}
              </select>
            </label>
            <Field label="Billing name" value={shopForm.billing_name} onChange={(v) => setShopForm({ ...shopForm, billing_name: v })} />
            <Field label="Billing address" value={shopForm.billing_address} onChange={(v) => setShopForm({ ...shopForm, billing_address: v })} />
            <label className="grid gap-1 text-sm font-medium">
              Registration
              <select
                className="h-10 rounded-lg border border-input px-2.5 text-sm font-normal"
                value={shopForm.registration_status}
                onChange={(event) =>
                  setShopForm({ ...shopForm, registration_status: event.target.value })
                }
              >
                {shopRegistrationStatuses.map((value) => (
                  <option key={value} value={value}>
                    {value}
                  </option>
                ))}
              </select>
            </label>
            <Field label="GSTIN (optional unless registered)" value={shopForm.gstin} onChange={(v) => setShopForm({ ...shopForm, gstin: v })} />
            <Field label="Effective from" type="date" value={shopForm.effective_from} onChange={(v) => setShopForm({ ...shopForm, effective_from: v })} />
            <Button type="button" onClick={() => saveShop.mutate()} disabled={saveShop.isPending}>
              Save shop tax draft
            </Button>
          </div>
        ) : null}
      </ConfigSection>

      <ConfigSection title="Product HSN and tax classification">
        {(hsnRows.data ?? []).map((row) => (
          <ConfigRow
            key={row.id}
            title={`${row.sku ?? row.product_id} · ${row.hsn_sac_code}`}
            detail={row.classification_kind}
            status={row.status}
            canPrepare={canPrepare && row.status === "draft"}
            canVerify={canVerify && row.status === "submitted"}
            onSubmit={() =>
              submitProductHsnClassification(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
            onVerify={() =>
              verifyProductHsnClassification(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
          />
        ))}
        {canPrepare ? (
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <ProductSearchField
              label="Product"
              value={hsnForm.product_id}
              onChange={(id) => setHsnForm({ ...hsnForm, product_id: id })}
            />
            <Field label="HSN/SAC code" value={hsnForm.hsn_sac_code} onChange={(v) => setHsnForm({ ...hsnForm, hsn_sac_code: v })} />
            <Field label="Effective from" type="date" value={hsnForm.effective_from} onChange={(v) => setHsnForm({ ...hsnForm, effective_from: v })} />
            <Button type="button" onClick={() => saveHsn.mutate()} disabled={saveHsn.isPending}>
              Save HSN draft
            </Button>
          </div>
        ) : null}
      </ConfigSection>

      <ConfigSection title="GST policy / tax schedules">
        <p className="text-sm text-muted-foreground">
          Empty rate fields stay unset. There is no default GST rate and no invoice calculation.
        </p>
        {(rates.data ?? []).map((row) => (
          <ConfigRow
            key={row.id}
            title={row.schedule_code}
            detail={`${row.treatment} · CGST ${row.cgst_rate ?? "unset"} / SGST ${row.sgst_rate ?? "unset"} / IGST ${row.igst_rate ?? "unset"}`}
            status={row.status}
            canPrepare={canPrepare && row.status === "draft"}
            canVerify={canVerify && row.status === "submitted"}
            onSubmit={() =>
              submitTaxRateSchedule(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
            onVerify={() =>
              verifyTaxRateSchedule(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
          />
        ))}
        {canPrepare ? (
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <Field label="Schedule code" value={rateForm.schedule_code} onChange={(v) => setRateForm({ ...rateForm, schedule_code: v })} />
            <label className="grid gap-1 text-sm font-medium">
              Treatment
              <select
                className="h-10 rounded-lg border border-input px-2.5 text-sm font-normal"
                value={rateForm.treatment}
                onChange={(event) => setRateForm({ ...rateForm, treatment: event.target.value })}
              >
                <option value="unspecified">Unspecified</option>
                <option value="intra_state">Intra-state</option>
                <option value="inter_state">Inter-state</option>
              </select>
            </label>
            <Field label="CGST % (optional)" value={rateForm.cgst_rate} onChange={(v) => setRateForm({ ...rateForm, cgst_rate: v })} />
            <Field label="SGST % (optional)" value={rateForm.sgst_rate} onChange={(v) => setRateForm({ ...rateForm, sgst_rate: v })} />
            <Field label="IGST % (optional)" value={rateForm.igst_rate} onChange={(v) => setRateForm({ ...rateForm, igst_rate: v })} />
            <Field label="Effective from" type="date" value={rateForm.effective_from} onChange={(v) => setRateForm({ ...rateForm, effective_from: v })} />
            <Button type="button" onClick={() => saveRate.mutate()} disabled={saveRate.isPending}>
              Save tax schedule draft
            </Button>
          </div>
        ) : null}
      </ConfigSection>

      <ConfigSection title="Invoice numbering, date, and remaining policies">
        {(policies.data ?? []).map((row) => (
          <ConfigRow
            key={row.id}
            title={statutoryPolicyKindLabel[row.policy_kind as keyof typeof statutoryPolicyKindLabel] ?? row.policy_kind}
            detail={JSON.stringify(row.payload)}
            status={row.status}
            canPrepare={canPrepare && row.status === "draft"}
            canVerify={canVerify && row.status === "submitted"}
            onSubmit={() =>
              submitStatutoryPolicy(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
            onVerify={() =>
              verifyStatutoryPolicy(row.id, row.version).then(refresh, (error: Error) =>
                notify.error(error.message),
              )
            }
          />
        ))}
        {canPrepare ? (
          <div className="mt-4 grid gap-3">
            <label className="grid gap-1 text-sm font-medium">
              Policy
              <select
                className="h-10 rounded-lg border border-input px-2.5 text-sm font-normal"
                value={policyKind}
                onChange={(event) =>
                  setPolicyKind(event.target.value as (typeof statutoryPolicyKinds)[number])
                }
              >
                {statutoryPolicyKinds.map((kind) => (
                  <option key={kind} value={kind}>
                    {statutoryPolicyKindLabel[kind]}
                  </option>
                ))}
              </select>
            </label>
            <label className="grid gap-1 text-sm font-medium">
              Payload JSON
              <textarea
                className="min-h-24 rounded-lg border border-input px-3 py-2 text-sm font-normal"
                value={policyPayload}
                onChange={(event) => setPolicyPayload(event.target.value)}
              />
            </label>
            <Field label="Effective from" type="date" value={policyFrom} onChange={setPolicyFrom} />
            <Button type="button" onClick={() => savePolicy.mutate()} disabled={savePolicy.isPending}>
              Save policy draft
            </Button>
          </div>
        ) : null}
      </ConfigSection>
    </section>
  )
}

function ConfigSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
      <h2 className="text-sm font-semibold">{title}</h2>
      <div className="mt-3">{children}</div>
    </section>
  )
}

function ConfigRow({
  title,
  detail,
  status,
  canPrepare,
  canVerify,
  onSubmit,
  onVerify,
}: {
  title: string
  detail: string
  status: string
  canPrepare: boolean
  canVerify: boolean
  onSubmit: () => void
  onVerify: () => void
}) {
  return (
    <div className="flex flex-col gap-2 border-b border-slate-100 py-3 sm:flex-row sm:items-center sm:justify-between">
      <span>
        <span className="block text-sm font-medium">{title}</span>
        <span className="text-xs text-muted-foreground">{detail}</span>
      </span>
      <span className="flex items-center gap-2">
        <StatusBadge tone={statusTone(status)}>
          {isVerifiedStatutoryStatus(status)
            ? statutoryStatusLabel.verified
            : (statutoryStatusLabel[status as keyof typeof statutoryStatusLabel] ?? status)}
        </StatusBadge>
        {canPrepare ? (
          <Button type="button" variant="outline" onClick={onSubmit}>
            Submit
          </Button>
        ) : null}
        {canVerify ? (
          <Button type="button" onClick={onVerify}>
            Verify
          </Button>
        ) : null}
      </span>
    </div>
  )
}

function Field({
  label,
  value,
  onChange,
  type = "text",
}: {
  label: string
  value: string
  onChange: (value: string) => void
  type?: string
}) {
  return (
    <label className="grid gap-1 text-sm font-medium">
      {label}
      <input
        type={type}
        className="h-10 rounded-lg border border-input px-3 text-sm font-normal"
        value={value}
        onChange={(event) => onChange(event.target.value)}
      />
    </label>
  )
}
