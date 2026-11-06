import { LegalDocument } from "@/pages/legal/LegalDocument"

export function PrivacyPage() {
  return (
    <LegalDocument
      title="Privacy notice"
      description="What SherlysOS stores about staff and shop operations, and who can see it. Last updated 6 November 2026."
    >
      <section>
        <h2 className="text-base font-semibold">What this notice covers</h2>
        <p className="mt-2">
          This notice covers the SherlysOS workspace used by staff at Sherlys
          distributors and agents.
        </p>
      </section>
      <section>
        <h2 className="text-base font-semibold">Information in the workspace</h2>
        <p className="mt-2">
          The workspace stores the email and profile on your account, the
          role an administrator assigns, and the operational records you and
          your colleagues enter. Those records include shops, orders, stock,
          deliveries, invoices notes, and damage reports, including contact
          details a shop has given the business.
        </p>
      </section>
      <section>
        <h2 className="text-base font-semibold">Who can see it</h2>
        <p className="mt-2">
          Each screen checks the permissions on your account. A colleague
          sees a record only when their role includes that permission.
          Sign-in is handled by the Supabase project this workspace is
          configured to use. SherlysOS does not sell this information.
        </p>
      </section>
      <section>
        <h2 className="text-base font-semibold">How long it is kept</h2>
        <p className="mt-2">
          Operational records stay for as long as the business needs them
          for fulfilment, stock control, and later review. Deactivating an
          account does not delete those records.
        </p>
      </section>
      <section>
        <h2 className="text-base font-semibold">Questions</h2>
        <p className="mt-2">
          Ask the administrator who issued your SherlysOS account. That
          person can correct a profile or explain a record you are allowed
          to see.
        </p>
      </section>
    </LegalDocument>
  )
}