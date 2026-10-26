-- Release M1-S3 concurrency fixtures. Local Docker only.
-- Deletes lot rows only when dual-write is off and ledger has no lot_id history.

do $$
begin
  if exists (
    select 1 from public.app_configuration
    where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
  ) then
    raise exception 'refusing lot cleanup while dual-write is enabled';
  end if;
  if exists (select 1 from public.stock_ledger where lot_id is not null) then
    raise exception 'refusing lot cleanup while lot-attributed ledger exists';
  end if;

  perform set_config('app.lot_reconciliation_write', 'on', true);
  perform app_private.begin_lot_balance_write('seed');

  delete from public.stock_lot_reconciliation_attributions;

  delete from public.stock_lot_attribution_baselines;
  delete from public.stock_lot_balances;
  delete from public.stock_legacy_lot_seeds;
  delete from public.stock_lots;

  perform app_private.end_lot_balance_write();

  update public.stock_lot_reconciliation_scope_crates sc
  set holds_scope = false
  from public.stock_lot_reconciliations s
  join public.branches b on b.id = s.godown_id
  where sc.session_id = s.id
    and b.code like 'm1s3c_%';

  update public.app_configuration
  set value = 'false'::jsonb
  where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
end;
$$;

set session_replication_role = replica;
delete from public.stock_balances
where product_id in (
  select id from public.products where sku like 'm1s3c%' or sku like 'm1s3qa%'
);
set session_replication_role = origin;
