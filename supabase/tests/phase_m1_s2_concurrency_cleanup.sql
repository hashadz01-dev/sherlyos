-- Release M1-S2.2 concurrency sessions. Local Docker only.

create or replace function public.m1s2c_cleanup()
returns void
language plpgsql
as $$
declare
  target uuid;
  sess record;
begin
  perform set_config('app.lot_reconciliation_write', 'on', true);

  for sess in
    select stock_lot_reconciliations.id, stock_lot_reconciliations.status, stock_lot_reconciliations.version
    from public.stock_lot_reconciliations
    join public.branches on branches.id = stock_lot_reconciliations.godown_id
    where branches.code = 'm1s2c_a'
  loop
    if sess.status in ('draft', 'rejected') then
      update public.stock_lot_reconciliation_scope_crates
      set holds_scope = false
      where session_id = sess.id;

      update public.stock_lot_reconciliations
      set
        status = 'cancelled',
        cancelled_by = coalesce(cancelled_by, (select id from public.m1s2c_actors where name = 'admin')),
        cancelled_at = coalesce(cancelled_at, clock_timestamp()),
        cancellation_reason = coalesce(cancellation_reason, 'concurrency cleanup'),
        version = sess.version + 1,
        updated_at = clock_timestamp()
      where id = sess.id
        and status in ('draft', 'rejected');
    elsif sess.status in ('submitted', 'approved') then
      -- Approved/submitted crates stay held by product rule; tests must not leave these
      -- behind. Force-release holds_scope only for local disposable fixtures.
      update public.stock_lot_reconciliation_scope_crates
      set holds_scope = false
      where session_id = sess.id;
    end if;
  end loop;
end;
$$;

select public.m1s2c_cleanup();
drop function if exists public.m1s2c_cleanup();

-- Disposable concurrency openings must not leak unmatched grains.
set session_replication_role = replica;
delete from public.stock_balances
where product_id in (select id from public.products where sku like 'm1s2c%');
set session_replication_role = origin;
