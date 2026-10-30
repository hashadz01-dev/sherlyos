-- Owner correction: GoodLife is a Nandini brand. Rename the placeholder supplier.
-- Does not create a second supplier, attach products, invent contacts, or flip flags.
do $$
declare
  admin_id uuid;
  target_supplier uuid;
  ledger_before bigint;
  balance_before bigint;
  lot_before bigint;
  price_before bigint;
  note_before bigint;
  flag_before integer;
  old_name text := 'GoodLife (pending invoicing confirmation)';
  new_name text := 'Nandini (pending invoicing confirmation)';
begin
  select count(*) into ledger_before from public.stock_ledger;
  select count(*) into balance_before from public.stock_balances;
  select count(*) into lot_before from public.stock_lots;
  select count(*) into price_before from public.product_selling_prices;
  select count(*) into note_before from public.invoice_notes;
  select count(*) into flag_before from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb;
  if flag_before is distinct from 0 then
    raise exception 'operational flags must remain false';
  end if;

  select id into admin_id
  from auth.users
  where email in ('jeffinpappachan110@gmail.com', 'admin.m1s2qa@example.com')
  order by case when email = 'jeffinpappachan110@gmail.com' then 0 else 1 end
  limit 1;
  if admin_id is null then
    raise exception 'admin user missing for supplier rename';
  end if;
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  select id into target_supplier
  from public.suppliers
  where lower(name) = lower(old_name)
  limit 1;

  if target_supplier is null then
    select id into target_supplier
    from public.suppliers
    where lower(name) = lower(new_name)
    limit 1;
    if target_supplier is null then
      raise exception 'neither GoodLife nor Nandini supplier row exists';
    end if;
  else
    perform public.update_supplier(target_supplier, new_name, null, null);
  end if;

  if exists (select 1 from public.suppliers where lower(name) = lower(old_name)) then
    raise exception 'GoodLife supplier name is still present';
  end if;
  if not exists (select 1 from public.suppliers where lower(name) = lower(new_name)) then
    raise exception 'Nandini supplier was not stored';
  end if;

  if (select count(*) from public.stock_ledger) is distinct from ledger_before
    or (select count(*) from public.stock_balances) is distinct from balance_before
    or (select count(*) from public.stock_lots) is distinct from lot_before
    or (select count(*) from public.product_selling_prices) is distinct from price_before
    or (select count(*) from public.invoice_notes) is distinct from note_before
  then
    raise exception 'supplier rename changed stock or prices';
  end if;
  if exists (
    select 1 from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  ) then
    raise exception 'operational flags changed';
  end if;
end $$;
