-- M7.6 full-ERP readiness. Rolls back.
-- Does not flip flags, issue statutory documents, or mutate owner history.

begin;

do $$
declare
  admin_id uuid;
  branch_id uuid;
  zone_id uuid;
  crate_id uuid;
  product_id uuid;
  target_crate uuid;
  target_product uuid;
  opening jsonb;
  dashboard jsonb;
  ledger_n bigint;
  balance_n integer;
  lot_mismatch integer;
  unclassified_stock integer;
  posted_returns integer;
  posted_without_lots integer;
  notes_with_tax integer;
  overlap_count integer;
  unique_return boolean;
begin
  if exists (
    select 1 from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    )
      and value = 'true'::jsonb
  ) then
    raise exception 'operational stock flags must remain false';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'product_selling_prices_active_window_excl' and contype = 'x'
  ) then
    raise exception 'selling-price GiST exclusion is missing';
  end if;

  select count(*) into overlap_count
  from public.product_selling_prices a
  join public.product_selling_prices b
    on a.product_id = b.product_id
   and a.id < b.id
   and a.is_active and b.is_active
   and a.shop_id is not distinct from b.shop_id
   and daterange(a.effective_from, coalesce(a.effective_to, 'infinity'::date), '[]')
     && daterange(b.effective_from, coalesce(b.effective_to, 'infinity'::date), '[]');
  if overlap_count is distinct from 0 then
    raise exception 'active selling-price overlaps must be 0: %', overlap_count;
  end if;

  if to_regprocedure('public.finalize_invoice_note(uuid, integer)') is not null
    or to_regprocedure('public.issue_tax_invoice(uuid, integer)') is not null
    or to_regprocedure('public.allocate_statutory_invoice_number(text)') is not null
    or to_regprocedure('public.create_invoice_credit_note(uuid)') is not null
    or to_regprocedure('public.issue_gst_credit_note(uuid, integer)') is not null
    or to_regprocedure('public.allocate_credit_note_number(uuid)') is not null
  then
    raise exception 'statutory issuance RPC must not exist';
  end if;

  if exists (select 1 from public.invoice_financial_years where legal_allocation_enabled)
    or exists (select 1 from public.invoice_number_series where legal_allocation_enabled)
    or exists (select 1 from public.invoice_credit_note_number_series where legal_allocation_enabled)
  then
    raise exception 'legal numbering must stay disabled';
  end if;

  if exists (
    select 1 from pg_class cls
    join pg_namespace nsp on nsp.oid = cls.relnamespace
    where nsp.nspname = 'public'
      and cls.relname in (
        'stock_ledger', 'stock_balances', 'invoice_notes', 'invoice_credit_adjustments',
        'stock_delivery_returns', 'damage_reports'
      )
      and (not cls.relrowsecurity or not cls.relforcerowsecurity)
  ) then
    raise exception 'core operational tables must keep FORCE RLS';
  end if;

  select exists (
    select 1 from pg_constraint
    where conrelid = 'public.stock_delivery_returns'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) ilike '%dispatch_id%'
  ) into unique_return;
  if not unique_return then
    raise exception 'one-return-wave UNIQUE on dispatch_id is missing';
  end if;

  -- Cutover assessment (read-only). Dual-write is off, so aggregate-only grains
  -- without lots are expected. Lot grains that exist must not exceed aggregate.
  select count(*) into lot_mismatch
  from (
    select b.crate_id, b.product_id, sum(b.quantity) as agg
    from public.stock_balances b group by 1,2
  ) a
  full join (
    select l.crate_id, sl.product_id, sum(l.quantity) as lot_qty
    from public.stock_lot_balances l
    join public.stock_lots sl on sl.id = l.lot_id
    group by 1,2
  ) x on x.crate_id = a.crate_id and x.product_id = a.product_id
  where coalesce(x.lot_qty, 0) > 0
    and coalesce(a.agg, 0) is distinct from coalesce(x.lot_qty, 0);
  if lot_mismatch is distinct from 0 then
    raise exception 'lot grains must not disagree with aggregate: %', lot_mismatch;
  end if;

  select count(distinct b.product_id) into unclassified_stock
  from public.stock_balances b
  join public.products p on p.id = b.product_id
  where coalesce(p.expiry_policy, 'unclassified') = 'unclassified'
    and b.quantity > 0;
  -- Dual-write-off aggregate stock may exist on unclassified SKUs (test residue or
  -- owner catalog). Recorded for cutover; not auto-classified or deleted.
  raise notice 'cutover unclassified products with stock: %', unclassified_stock;

  select count(*) into posted_returns
  from public.stock_delivery_returns where status = 'posted';
  select count(*) into posted_without_lots
  from public.stock_delivery_returns r
  where r.status = 'posted'
    and not exists (select 1 from public.stock_delivery_return_lots l where l.return_id = r.id);
  if posted_returns > 0 and posted_without_lots is distinct from posted_returns then
    raise exception 'posted returns without lots drifted: posted % without_lots %',
      posted_returns, posted_without_lots;
  end if;

  select count(*) into notes_with_tax from public.invoice_notes where tax_amount <> 0;
  if notes_with_tax is distinct from 0 then
    raise exception 'invoice-note tax_amount must stay 0';
  end if;

  select id into admin_id from auth.users where email = 'admin.m1s2qa@example.com';
  if admin_id is null then
    raise exception 'admin.m1s2qa is required';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  -- Isolated aggregate-only opening (dual-write remains false). Independent ledger oracle.
  branch_id := public.create_branch('m76sql_' || substr(gen_random_uuid()::text, 1, 8), 'M76 SQL');
  zone_id := public.create_zone(branch_id, 'm76z', 'Z', null);
  target_crate := public.create_crate(zone_id, 'm76c', 'C', null);
  target_product := public.create_product(
    'm76-' || substr(gen_random_uuid()::text, 1, 8),
    'M76 readiness soap',
    null,
    null
  );
  opening := public.post_opening_stock(
    target_product, target_crate, 5, 'm76-open-' || target_product::text, null
  );

  select coalesce(sum(stock_ledger.quantity), 0) into ledger_n
  from public.stock_ledger
  where stock_ledger.product_id = target_product and stock_ledger.crate_id = target_crate;
  select coalesce(stock_balances.quantity, 0) into balance_n
  from public.stock_balances
  where stock_balances.product_id = target_product and stock_balances.crate_id = target_crate;
  if ledger_n is distinct from 5 or balance_n is distinct from 5 then
    raise exception 'isolated opening must write 5 ledger and 5 balance: ledger % balance %',
      ledger_n, balance_n;
  end if;

  dashboard := public.get_operations_dashboard(branch_id);
  if coalesce((dashboard -> 'cutover' ->> 'dual_write_enabled')::boolean, true) then
    raise exception 'dashboard must report dual-write off';
  end if;
  if dashboard -> 'inventory' -> 'available_to_pick' ->> 'state' is distinct from 'not_applicable' then
    raise exception 'ATP must stay not_applicable while dual-write is off: %',
      dashboard -> 'inventory' -> 'available_to_pick';
  end if;
  if (dashboard -> 'inventory' ->> 'total_cartons_on_hand')::integer is distinct from 5 then
    raise exception 'dashboard on-hand must match isolated opening: %',
      dashboard -> 'inventory' ->> 'total_cartons_on_hand';
  end if;

  if (public.assess_invoice_finalization_readiness(null) ->> 'ready')::boolean
    or (public.assess_invoice_finalization_readiness(null) ->> 'legal_issuance_blocked')::boolean is distinct from true
  then
    raise exception 'invoice issuance must stay blocked';
  end if;
end;
$$;

rollback;
