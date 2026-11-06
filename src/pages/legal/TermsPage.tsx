import { LegalDocument } from "@/pages/legal/LegalDocument"

export function TermsPage() {
  return (
    <LegalDocument
      title="Terms of use"
      description="Rules for staff who use the SherlysOS operations workspace. Last updated 6 November 2026."
    >
      <section>
        <h2 className="text-base font-semibold">Who may use this workspace</h2>
        <p className="mt-2">
          SherlysOS is an internal system for Sherlys distributors and agents.
          An administrator issues each account. Do not share a sign-in, and do
          not use an account that was not issued to you.
        </p>
      </section>
      <section>
        <h2 className="text-base font-semibold">Business records</h2>
        <p className="mt-2">
          Orders, stock, deliveries, damage reports, and related notes are
          business records of the operation. Enter them accurately. The
          workspace keeps an audit of privileged changes so later review can
          see who did what.
        </p>
      </section>
      <section>
        <h2 className="text-base font-semibold">Acceptable use</h2>
        <p className="mt-2">
          Use the workspace for Sherlys distribution work. Do not attempt to
          bypass permissions, copy data out for an unrelated purpose, or
          interfere with another person’s account.
        </p>
      </section>
      <section>
        <h2 className="text-base font-semibold">Ending access</h2>
        <p className="mt-2">
          An administrator can deactivate an account. Deactivation closes
          privileged screens. Records already stored for the operation stay
          in place.
        </p>
      </section>
    </LegalDocument>
  )
}
