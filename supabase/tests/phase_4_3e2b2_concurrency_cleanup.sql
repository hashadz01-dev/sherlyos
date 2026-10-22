-- Cleanup for Phase 4.3E.2B.2 concurrency fixtures (local test only).

set session_replication_role = replica;

do $$
declare
  admin_id uuid;
  product uuid;
  lot_ids uuid[];
  txn_ids uuid[];
begin
  select id into admin_id
  from auth.users
  where email = 'admin.phase43e2b2race@example.com'
  limit 1;

  select id into product
  from public.products
  where sku = 'p43e2b2-race'
  limit 1;

  select coalesce(array_agg(id), '{}'::uuid[]) into lot_ids
  from public.stock_lots
  where product_id = product
     or manufacturer_lot_code in ('RACE-MAIN', 'RACE-DUP');

  select coalesce(array_agg(id), '{}'::uuid[]) into txn_ids
  from public.stock_transactions
  where reference_number like 'P43E2B2-RACE-%'
     or idempotency_key like 'p43e2b2-race%';

  if cardinality(txn_ids) > 0 then
    delete from public.stock_lot_aware_applications where transaction_id = any (txn_ids);
  end if;

  perform app_private.begin_lot_balance_write('helper');
  if cardinality(lot_ids) > 0 then
    delete from public.stock_lot_balances where lot_id = any (lot_ids);
  end if;
  perform app_private.end_lot_balance_write();

  if cardinality(txn_ids) > 0 then
    delete from public.stock_ledger where transaction_id = any (txn_ids);
    delete from public.stock_transactions where id = any (txn_ids);
  end if;

  if product is not null then
    delete from public.stock_balances where product_id = product;
  end if;

  if cardinality(lot_ids) > 0 then
    delete from public.stock_lots where id = any (lot_ids);
  end if;

  delete from public.crates where code in ('c43e2b2ra', 'c43e2b2rb');
  delete from public.zones where code = 'z43e2b2r';
  if product is not null then
    delete from public.products where id = product;
  end if;
  delete from public.branches where code = 'p43e2b2_race';

  if admin_id is not null then
    delete from public.user_branch_assignments where user_id = admin_id;
    delete from public.user_roles where user_id = admin_id;
    delete from public.profiles where id = admin_id;
    delete from auth.users where id = admin_id;
  end if;
end $$;

drop table if exists public.phase43e2b2_race_target cascade;

set session_replication_role = origin;
