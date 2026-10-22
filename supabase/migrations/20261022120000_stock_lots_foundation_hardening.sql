-- Phase 4.3D.1: local foundation hardening for stock lots / expiry policy.
-- Forward-only. Does not rewrite 20261020120000. Does not seed lots, post stock,
-- implement FEFO/FIFO, picking, or receiving. LOCAL-first; no cloud push here.
--
-- Hardens:
--   1) Admin-only products.expiry_policy.manage (products.manage unchanged)
--   2) stock_lots.branch_id + branch-scoped SELECT (incl. zero-balance / no-balance)
--   3) Corrected SQL comments (Admin vs Godown Manager)

-- ---------------------------------------------------------------------------
-- 1. Dedicated expiry-policy permission (Admin only)
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values (
  'products.expiry_policy.manage',
  'Classify products as expiry_controlled or non_expiring. Granted to Admin only; separate from products.manage.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'products.expiry_policy.manage'
where roles.code = 'admin'
on conflict do nothing;

create or replace function public.set_product_expiry_policy(
  target_product uuid,
  new_policy text
)
returns public.products
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.products%rowtype;
  cleaned text;
  lot_count integer;
begin
  perform app_private.assert_permission('products.expiry_policy.manage');

  cleaned := nullif(pg_catalog.btrim(coalesce(new_policy, '')), '');
  if cleaned is null or cleaned not in ('expiry_controlled', 'non_expiring') then
    raise exception 'expiry policy is invalid' using errcode = '23514';
  end if;

  select *
  into selected
  from public.products
  where products.id = target_product
  for update;

  if not found then
    raise exception 'product not found' using errcode = '42501';
  end if;

  -- Conservative: do not reinterpret existing lot inventory by changing policy.
  select count(*)::integer
  into lot_count
  from public.stock_lots
  where stock_lots.product_id = target_product;

  if lot_count > 0 and selected.expiry_policy is distinct from cleaned then
    raise exception 'expiry policy cannot change while stock lots exist for this product'
      using errcode = '23514';
  end if;

  if selected.expiry_policy is not distinct from cleaned then
    return selected;
  end if;

  update public.products
  set expiry_policy = cleaned
  where products.id = target_product
  returning * into selected;

  perform app_private.write_audit(
    auth.uid(),
    'set_product_expiry_policy',
    'products',
    target_product,
    pg_catalog.jsonb_build_object('expiry_policy', cleaned)
  );

  return selected;
end;
$$;

revoke all on function public.set_product_expiry_policy(uuid, text)
  from public, anon;
grant execute on function public.set_product_expiry_policy(uuid, text)
  to authenticated;

comment on function public.set_product_expiry_policy(uuid, text) is
  'Requires products.expiry_policy.manage (Admin only; Godown Manager keeps products.manage for catalog edits but cannot classify). Sets expiry_controlled or non_expiring. Idempotent when unchanged. Rejects policy changes once stock_lots exist for the product.';

comment on column public.products.expiry_policy is
  'Phase 4.3D/4.3D.1. NULL = unclassified. Only Admin (products.expiry_policy.manage) sets expiry_controlled or non_expiring via set_product_expiry_policy. Godown Manager products.manage does not grant classification. Unclassified products must not receive lot-aware intake or picking in later phases.';

-- ---------------------------------------------------------------------------
-- 2. Branch isolation for stock_lots (including lots with no balance rows)
-- ---------------------------------------------------------------------------

-- Empty after 4.3D; NOT NULL is safe. Future lot-creating RPCs must set branch_id
-- to the receiving/storage godown and keep lot×crate balances inside that hierarchy.
alter table public.stock_lots
  add column branch_id uuid not null references public.branches (id) on delete restrict;

create index stock_lots_branch_id_idx on public.stock_lots (branch_id);

comment on column public.stock_lots.branch_id is
  'Owning godown for the lot. Required for SELECT RLS via can_work_at_branch. Zero-quantity balances remain visible to authorized callers; lots with no balance rows are not globally readable.';

drop policy if exists stock_lots_select_authorized on public.stock_lots;

create policy stock_lots_select_authorized
  on public.stock_lots
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and (select app_private.has_permission('products.read'))
    and (select app_private.can_work_at_branch(stock_lots.branch_id))
  );

-- ---------------------------------------------------------------------------
-- 3. Concurrency / uniqueness notes for later lot-creating RPCs (not implemented)
-- ---------------------------------------------------------------------------

comment on table public.stock_lots is
  'Internal stock lot identity (Phase 4.3D/4.3D.1). branch_id scopes visibility. One row per inbound posting event in later phases — not merged solely by manufacturer lot code. Empty until 4.3E+ workflows. Expiry/received_on rules are enforced by later posting RPCs using products.expiry_policy. Future lot-creating RPCs must lock the product FOR UPDATE (same as set_product_expiry_policy) before insert so concurrent classification cannot race past the lots-exist guard. source_receipt_line_id uniqueness remains an unresolved product rule — do not invent a unique constraint until that decision is approved.';
