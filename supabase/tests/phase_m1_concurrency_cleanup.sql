-- Removes the M1 race fixture and restores cutover flags off.
-- Replica first: attributed race ledger still exists until the deletes below.
set session_replication_role = replica;
update public.app_configuration
set value = 'false'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');

do $$
declare
  admin_id uuid;
  product uuid;
  lot_ids uuid[];
  txn_ids uuid[];
begin
  select id into admin_id from auth.users where email = 'admin.m1race@example.com';
  select id into product from public.products where sku = 'm1-race-exp';

  select coalesce(array_agg(id), '{}'::uuid[]) into lot_ids
  from public.stock_lots
  where product_id = product or manufacturer_lot_code = 'RACE-1';

  select coalesce(array_agg(id), '{}'::uuid[]) into txn_ids
  from public.stock_transactions
  where idempotency_key like 'm1-race%';

  if cardinality(txn_ids) > 0 then
    delete from public.stock_lot_aware_applications where transaction_id = any (txn_ids);
    delete from public.stock_ledger where transaction_id = any (txn_ids);
  end if;

  if cardinality(lot_ids) > 0 then
    delete from public.stock_lot_balances where lot_id = any (lot_ids);
    delete from public.stock_lots where id = any (lot_ids);
  end if;

  if cardinality(txn_ids) > 0 then
    delete from public.stock_transactions where id = any (txn_ids);
  end if;

  if product is not null then
    delete from public.stock_balances where product_id = product;
    delete from public.products where id = product;
  end if;

  delete from public.crates where code in ('cm1ra', 'cm1rb');
  delete from public.zones where code = 'zm1r';
  delete from public.branches where code = 'm1race';

  if admin_id is not null then
    delete from public.audit_logs where actor_id = admin_id;
    delete from public.user_branch_assignments where user_id = admin_id;
    delete from public.user_roles where user_id = admin_id;
    delete from public.profiles where id = admin_id;
    delete from auth.users where id = admin_id;
  end if;
end $$;

drop table if exists public.phase_m1_race_target cascade;

set session_replication_role = origin;

do $$
begin
  if exists (
    select 1 from public.app_configuration
    where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked')
      and value is distinct from 'false'::jsonb
  ) then
    raise exception 'cleanup left a cutover flag true';
  end if;
end $$;
