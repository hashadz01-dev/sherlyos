-- Delivery Person company-wide active-godown scope.
-- Same pattern as store_keeper.godowns.all: not Admin, not branches.access_all.
-- Action permissions stay the second check (deliveries.execute, assignment for
-- transit create, etc.). This only widens which active godowns the role may see
-- and use for already-authorized delivery / transit actions.

insert into public.permissions (code, description)
values (
  'delivery_person.godowns.all',
  'Work across every active godown for authorized Delivery Person actions. Does not grant damage.record, Admin, employee administration, or warehouse stock mutations.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'delivery_person.godowns.all'
where roles.code = 'delivery_person'
on conflict do nothing;

-- Admin-only access_all is unchanged. Company-wide roles see active godowns only.
create or replace function app_private.can_work_at_branch(target_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select app_private.has_permission('branches.access_all'))
    or (
      (
        (select app_private.has_permission('accounts.godowns.all'))
        or (select app_private.has_permission('godown_manager.godowns.all'))
        or (select app_private.has_permission('store_keeper.godowns.all'))
        or (select app_private.has_permission('delivery_person.godowns.all'))
      )
      and exists (
        select 1
        from public.branches
        where branches.id = target_branch
          and branches.is_active
      )
    )
    or exists (
      select 1
      from public.user_branch_assignments
      join public.branches on branches.id = user_branch_assignments.branch_id
      where user_branch_assignments.user_id = (select auth.uid())
        and user_branch_assignments.branch_id = target_branch
        and branches.is_active
    );
$$;

comment on function app_private.can_work_at_branch(uuid) is
  'Site scope only. Admin access_all includes inactive godowns. Accounts, Godown Manager, Store Keeper, and Delivery Person godowns.all are every active godown. Callers must still assert the action permission.';

-- Transit / consumed-delivery RPCs use this helper, not only can_work_at_branch.
create or replace function app_private.can_complete_consumed_delivery_at_branch(target_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.has_permission('branches.access_all')
    or (
      app_private.has_permission('delivery_person.godowns.all')
      and exists (
        select 1
        from public.branches
        where branches.id = target_branch
          and branches.is_active
      )
    )
    or exists (
      select 1
      from public.user_branch_assignments
      where user_branch_assignments.user_id = auth.uid()
        and user_branch_assignments.branch_id = target_branch
    );
$$;

comment on function app_private.can_complete_consumed_delivery_at_branch(uuid) is
  'Consumed-delivery site scope. Admin access_all, Delivery Person godowns.all on active godowns, or an explicit branch assignment. Action permissions remain separate.';

-- Catalog visibility for company-wide filters. Does not expose inactive godowns
-- and does not grant user_branch_assignments staff reads.
drop policy if exists branches_select_assigned_or_all on public.branches;

create policy branches_select_assigned_or_all
  on public.branches
  for select
  to authenticated
  using (
    (select app_private.has_permission('branches.access_all'))
    or (select app_private.has_permission('employees.read'))
    or (
      (
        (select app_private.has_permission('accounts.godowns.all'))
        or (select app_private.has_permission('godown_manager.godowns.all'))
        or (select app_private.has_permission('store_keeper.godowns.all'))
        or (select app_private.has_permission('delivery_person.godowns.all'))
      )
      and branches.is_active
    )
    or exists (
      select 1
      from public.user_branch_assignments
      where user_branch_assignments.user_id = (select auth.uid())
        and user_branch_assignments.branch_id = branches.id
    )
  );
