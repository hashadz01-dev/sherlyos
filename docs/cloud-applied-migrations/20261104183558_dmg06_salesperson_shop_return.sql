-- Archived copy of an already-applied development-cloud migration statement.
-- Do not move this file into supabase/migrations and do not apply it again.

-- DMG-06 salesperson shop-return workflow (local-first).
-- Salesperson may create/submit shop_return only for assigned shops.
-- Submit does not post inventory. GM confirms custody on submitted reports.
-- Independent verify posts quarantine intake exactly once.
-- Does not flip operational flags. Does not alter historical stock postings.

-- ---------------------------------------------------------------------------
-- 1. Permission: shop-return create without warehouse damage.record
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values (
  'damage.shop_return.record',
  'Create, edit own drafts, submit, and view authorized shop-return (DMG-06) damage reports. Does not grant warehouse scenarios, custody confirmation, verification, or disposition.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'damage.shop_return.record'
where roles.code = 'salesperson'
on conflict do nothing;
