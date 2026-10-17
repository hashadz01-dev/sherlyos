# Access control

Phase 2A is finalized for review. `supabase/migrations/20261014150000_access_control.sql` has **not** been applied to the remote Supabase project. The React app still uses Supabase Auth only; it does not read roles or permissions yet. UI checks are never the security boundary.

## Confirmed business decisions

### Daily stock verification (Decision B)

The **Godown Manager** owns the full daily stock verification workflow from the BPM (DSV-01 through DSV-07):

- Select godown, zone, and crate scope.
- Enter physical counts and compare them to system balances.
- Investigate mismatches, recount, and record snapshots and photos when required.
- Record the final result and start an adjustment when one is needed.

The **Store Keeper** may assist with physical counting through `stock.count_assist` when assigned to the site. They do not receive `stock.verify` and do not own verification.

### Stock adjustments (Decision A)

Stock balances are **never** updated by direct table writes from the client. Posting happens only through a future controlled database function (Phase 2B or later).

| Permission                             | Purpose                                                         | Granted to     |
| -------------------------------------- | --------------------------------------------------------------- | -------------- |
| `stock.discrepancy.report`             | Report a mismatch and evidence without changing balances.       | Godown Manager |
| `stock.adjustment.request`             | Create an adjustment request with reason and reference.         | Godown Manager |
| `stock.adjustment.post`                | Post a **routine** authorized adjustment through the workflow.  | Godown Manager |
| `stock.adjustment.approve_exceptional` | Approve adjustments above configured thresholds before posting. | Admin          |

**Routine adjustments:** A Godown Manager with `stock.adjustment.post`, an active profile, and `app_private.can_work_at_branch` for the site may post when the request is approved and the delta is within thresholds.

**Exceptional adjustments:** When `app_configuration.stock.adjustment.exceptional_requires_admin` is `true` and any line's absolute carton quantity is greater than `stock.adjustment.exceptional_absolute_units`, an Admin with `stock.adjustment.approve_exceptional` must approve before posting. Phase 3.3 approves that threshold as **10**. A line of 10 is ordinary. A line of 11 is exceptional. The original access-control migration seeded 50 as a placeholder; the Phase 3.3 migration updates the configuration value and does not rewrite that earlier migration.

**Routine vs exceptional:** `stock.adjustment.post` (Godown Manager) and `stock.adjustment.approve_exceptional` (Admin) are separate permissions. Posting never substitutes for exceptional approval when the configured rules require it.

Phase 3.3 is implemented locally and is not deployed to development or production. Ordinary approval belongs to a different assigned Godown Manager. Admin ordinary approval is the fallback when no other eligible manager exists. Approval and posting are separate steps. A same-line receipt or transfer after verification close makes the adjustment stale and requires a new verification. Reversals are not implemented. A non-null `compensates_request_id` is rejected. Development Supabase was not changed by this phase.

### BPM terminology

"Branch 01" through "Branch 05" in the PDF are **workflows** (orders, damage, receiving, verification, refill). The `branches` table holds **operating sites** (for example a godown). No site rows are seeded.

## Six roles

| #   | Role            | Summary                                                                                                                |
| --- | --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| 1   | Admin           | Employee administration, sites, audit, module monitoring, refill approval, exceptional stock adjustment approval.      |
| 2   | Accounts        | Orders, billing documents, refill requests.                                                                            |
| 3   | Godown Manager  | Picking, delivery assignment, receiving verification, daily verification, stock adjustment workflow, damage at godown. |
| 4   | Salesperson     | Order capture and shop development.                                                                                    |
| 5   | Delivery Person | Shop delivery execution.                                                                                               |
| 6   | Store Keeper    | Receiving execution, loading assist, optional count assist, damage during receiving/loading.                           |

Roles are organization-wide. **Branch scope** comes from `user_branch_assignments`. Admin also has `branches.access_all`.

## Permission matrix

| Permission                           | Admin | Accounts | Godown Mgr | Sales | Delivery | Store Keeper |
| ------------------------------------ | ----- | -------- | ---------- | ----- | -------- | ------------ |
| employees.read                       | yes   |          |            |       |          |              |
| employees.manage                     | yes   |          |            |       |          |              |
| roles.assign                         | yes   |          |            |       |          |              |
| branches.manage                      | yes   |          |            |       |          |              |
| branches.access_all                  | yes   |          |            |       |          |              |
| assignments.manage                   | yes   |          |            |       |          |              |
| audit.read                           | yes   |          |            |       |          |              |
| operations.monitor                   | yes   |          |            |       |          |              |
| refill.approve                       | yes   |          |            |       |          |              |
| stock.adjustment.approve_exceptional | yes   |          |            |       |          |              |
| orders.capture                       |       | yes      |            | yes   |          |              |
| orders.verify                        |       | yes      |            |       |          |              |
| delivery_notes.issue                 |       | yes      |            |       |          |              |
| invoices.issue                       |       | yes      |            |       |          |              |
| refill.request                       |       | yes      |            |       |          |              |
| picking.execute                      |       |          | yes        |       |          |              |
| deliveries.assign                    |       |          | yes        |       |          |              |
| invoice_notes.prepare                |       |          | yes        |       |          |              |
| receiving.verify                     |       |          | yes        |       |          |              |
| stock.verify                         |       |          | yes        |       |          |              |
| stock.discrepancy.report             |       |          | yes        |       |          |              |
| stock.adjustment.request             |       |          | yes        |       |          |              |
| stock.adjustment.post                |       |          | yes        |       |          |              |
| damage.record                        |       |          | yes        |       |          | yes          |
| shops.develop                        |       |          |            | yes   |          |              |
| deliveries.execute                   |       |          |            |       | yes      |              |
| receiving.execute                    |       |          |            |       |          | yes          |
| loading.assist                       |       |          |            |       |          | yes          |
| stock.count_assist                   |       |          |            |       |          | yes          |

Operational permissions are a catalog only. Phase 4.1 adds order storage, capture/edit, submit, hold, verify (Rule A), and cancel through RPCs only. Clients still have select-only table grants. Phase 4.1D local QA and Phase 4.1E cloud JWT verification confirmed no unintended permission expansion on development.

## Phase 4.1A catalog grants

PHASE 4.1A–4.1D — LOCAL READY. PHASE 4.1E — DEVELOPMENT DEPLOYED AND VERIFIED on `ypkfondrkhkydkgovwup`. Production was not changed. Git commit/push checkpoint pending user approval.

1. Require `auth.uid()` with an active profile and `stock.adjustment.post`.
2. Call `app_private.can_work_at_branch(branch_id)` unless the actor has `branches.access_all`.
3. Require a non-empty reason, reference id (verification or adjustment request), and idempotency key to block duplicate submission.
4. Read current balance inside a transaction with `SELECT … FOR UPDATE` on the balance row.
5. Compare `abs(delta_units)` to `app_configuration` thresholds; if exceptional and not yet approved, reject.
6. Insert an **append-only** ledger movement (previous balance, delta, resulting balance, actor, timestamp). Do not update or delete prior movements.
7. Update the balance row once, in the same transaction, derived from the ledger sum or the locked row.
8. Write `audit_logs` via `app_private.write_audit`.
9. Reject callers with only the publishable key and no permission.

Direct `UPDATE` on future balance tables from the client remains forbidden by grants and RLS.

## Row level security summary

All listed tables use RLS **enabled** and **forced**. `anon` has no table access. `authenticated` has **select** only where a policy allows; there are no insert/update/delete policies on these tables for clients.

| Table                   | Select allowed when                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------------- |
| profiles                | Own row, or `employees.read`.                                                             |
| roles, permissions      | Any signed-in user (catalog).                                                             |
| role_permissions        | `employees.read`, or own role’s grants.                                                   |
| user_roles              | Own rows, or `employees.read`.                                                            |
| branches                | Assigned site, `branches.access_all`, or `employees.read`.                                |
| user_branch_assignments | Own rows, `employees.read`, or `branches.access_all`.                                     |
| app_configuration       | `stock.adjustment.post`, `stock.adjustment.approve_exceptional`, or `operations.monitor`. |
| audit_logs              | `audit.read` only.                                                                        |

Privileged changes use `SECURITY DEFINER` functions with explicit permission checks. Each rejects self-service on roles, active status, administered profiles, and branch assignments. `app_private.has_permission` and `app_private.can_work_at_branch` do not recurse through RLS on the tables they read.

### Expected access by role (read path)

| Role            | Typical visible data                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------ |
| Admin           | All profiles, roles, assignments, sites, configuration thresholds, audit log (with permissions above). |
| Accounts        | Own profile, role catalog, own role permissions, assigned sites only.                                  |
| Godown Manager  | Same as Accounts, plus configuration thresholds needed for adjustment rules.                           |
| Salesperson     | Own profile, catalog, assigned sites.                                                                  |
| Delivery Person | Same as Salesperson.                                                                                   |
| Store Keeper    | Same as Salesperson.                                                                                   |

Inactive profiles fail `has_permission` and lose privileged functions even if role rows remain.

`service_role` insert/update/delete on access-control tables is revoked. Audit log select is also revoked from `service_role`; auditors use an authenticated session with `audit.read`. The service-role key must not ship in frontend code.

## Privileged RPCs (Phase 2A)

| Function                                          | Who may call                       | Notes                                |
| ------------------------------------------------- | ---------------------------------- | ------------------------------------ |
| `assign_user_role` / `revoke_user_role`           | `roles.assign`                     | Cannot target self.                  |
| `set_employee_active` / `update_employee_profile` | `employees.manage`                 | Cannot target self.                  |
| `update_own_profile`                              | Self                               | Name only; not roles or active flag. |
| `create_branch` / `set_branch_active`             | `branches.manage`                  |                                      |
| `assign_user_branch` / `revoke_user_branch`       | `assignments.manage`               | Cannot target self.                  |
| `app_private.bootstrap_initial_admin`             | **service_role / SQL editor only** | Not granted to `authenticated`.      |

## Initial administrator bootstrap

1. Apply the migration to the development project (see below).
2. Create the person in Supabase Auth (dashboard or server-side Admin API). Confirm email. Trigger creates profile **without** any role.
3. In the Supabase SQL editor (database owner), run once:

```sql
select app_private.bootstrap_initial_admin(
  '<auth-user-id>'::uuid,
  'create-initial-administrator'
);
```

Fails safely if an Admin already exists, if the profile is missing, or if the confirmation phrase is wrong. No email or password belongs in source code. Further users are provisioned through Auth plus `assign_user_role` and branch assignment RPCs.

## Assumptions and open items

| Item                                                  | Status                                                                                    |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Godown Manager owns daily verification                | **Confirmed**                                                                             |
| Godown Manager posts routine adjustments via workflow | **Confirmed**                                                                             |
| Admin approves exceptional adjustments                | **Confirmed**                                                                             |
| Exceptional unit threshold                            | **Approved for Phase 3.3 as 10 carton cases per line.** Greater than 10 makes the whole request exceptional. |
| Value-based exceptional threshold (INR)               | **Deferred** until product valuation exists                                               |
| Delivery Person + BPM transit damage (DMG-05)         | **Unresolved** — `damage.record` is **not** granted; do not add without explicit approval |
| Telecalling / enquiry as order channels               | **Approved for Phase 4.1** as order source values, not roles.             |
| Auth email on profile                                 | Stays in Auth only                                                                        |

## Review and apply (remote)

1. Read this document and the full SQL in `supabase/migrations/20261014150000_access_control.sql`.
2. Confirm the permission matrix and proposed threshold defaults.
3. Link the project: `npx supabase link --project-ref ypkfondrkhkydkgovwup` (with access token in the environment, not in the repo).
4. Dry-run locally if you use local Supabase: `npx supabase db reset` on a **non-production** database only.
5. Apply to development: `npx supabase db push` or `migration up` per your process. **Do not edit the file after it has been applied**; add a new migration instead.
6. Run bootstrap SQL once, then assign roles and sites through RPCs.
7. Optionally verify policies in the dashboard SQL editor as an authenticated test user.

**Local validation (2026-10-14):** With Docker running, `npx supabase start`, `db reset --local`, `db lint --local`, and `db advisors --local` all succeeded against these migrations. Remote dev was not modified.

`supabase/seed.sql` stays empty.
