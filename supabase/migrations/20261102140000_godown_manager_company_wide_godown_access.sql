-- Godown Manager company-wide active-godown scope.
-- Same pattern as accounts.godowns.all: not Admin, not branches.access_all.
-- Action permissions stay the second check. Store Keeper stays assignment-scoped.
-- Godown Manager already holds warehouse actions; this only widens where they
-- may use those existing grants.

insert into public.permissions (code, description)
values (
  'godown_manager.godowns.all',
  'Work across every active godown for authorized Godown Manager actions. Does not grant Admin, employee administration, Accounts verification, or statutory invoice issuance.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'godown_manager.godowns.all'
where roles.code = 'godown_manager'
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
  'Site scope only. Admin access_all includes inactive godowns. Accounts and Godown Manager godowns.all are every active godown. Store Keeper still needs an assignment. Callers must still assert the action permission.';

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
