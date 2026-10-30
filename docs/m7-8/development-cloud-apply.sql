-- M7.8 authorized development-cloud shared-fleet import. Not a schema migration.
-- Requires 20261030150000_shared_vehicle_fleet. Calls create_vehicle / set_vehicle_active
-- as Jeffin. Rolls back on flag or stock drift. Does not invent capacity or a home godown.
do $$
declare
  admin_id uuid := 'cdc087c0-0295-425d-8dbe-9a91030bf012';
  created_vehicle uuid;
  ledger_before bigint;
  balance_before bigint;
  lot_before bigint;
  price_before bigint;
  note_before bigint;
  dispatch_before bigint;
  assignment_before bigint;
  flag_before integer;
  note_text text := 'Shared fleet. Assigned to a godown only when a delivery run starts. Type not in Vehicle.docx; stored as other.';
begin
  select count(*) into ledger_before from public.stock_ledger;
  select count(*) into balance_before from public.stock_balances;
  select count(*) into lot_before from public.stock_lots;
  select count(*) into price_before from public.product_selling_prices;
  select count(*) into note_before from public.invoice_notes;
  select count(*) into dispatch_before
    from public.stock_dispatch_requests
    where stock_dispatch_requests.vehicle_id is not null;
  select count(*) into assignment_before from public.stock_dispatch_assignments;
  select count(*) into flag_before from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb;
  if flag_before is distinct from 0 then
    raise exception 'operational flags must remain false';
  end if;
  if not exists (select 1 from auth.users where id = admin_id and email = 'jeffinpappachan110@gmail.com') then
    raise exception 'Jeffin admin id mismatch';
  end if;
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43f948') then
    created_vehicle := public.create_vehicle(null, 'KL-43-F-948', 'other', 'Benz (B)', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43k3458') then
    created_vehicle := public.create_vehicle(null, 'KL-43-K-3458', 'other', 'Benz (S)', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43t5764') then
    created_vehicle := public.create_vehicle(null, 'KL-43-T-5764', 'other', 'New SML', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43n3241') then
    created_vehicle := public.create_vehicle(null, 'KL-43-N-3241', 'other', 'Mahindra', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43p0012') then
    created_vehicle := public.create_vehicle(null, 'KL-43-P-0012', 'other', 'Bada Dost (Malayalam Motors)', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43p7981') then
    created_vehicle := public.create_vehicle(null, 'KL-43-P-7981', 'other', 'Tata', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43q1561') then
    created_vehicle := public.create_vehicle(null, 'KL-43-Q-1561', 'other', 'Mahindra New', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43r1543') then
    created_vehicle := public.create_vehicle(null, 'KL-43-R-1543', 'other', 'SML', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43r5470') then
    created_vehicle := public.create_vehicle(null, 'KL-43-R-5470', 'other', 'Big Benz', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43s7528') then
    created_vehicle := public.create_vehicle(null, 'KL-43-S-7528', 'other', 'Veero', null, note_text);
  end if;
  if not exists (select 1 from public.vehicles where registration_normalized = 'kl43r6725') then
    created_vehicle := public.create_vehicle(
      null,
      'KL-43-R-6725',
      'other',
      'Bolero',
      null,
      'Source marked optional. Created inactive so it is in the master but not offered on a delivery run until the owner activates it.'
    );
    perform public.set_vehicle_active(created_vehicle, false);
  else
    select id into created_vehicle from public.vehicles where registration_normalized = 'kl43r6725';
    if (select is_active from public.vehicles where id = created_vehicle) then
      perform public.set_vehicle_active(created_vehicle, false);
    end if;
  end if;

  if (select count(*) from public.vehicles where registration_normalized in (
    'kl43f948','kl43k3458','kl43t5764','kl43n3241','kl43p0012','kl43p7981',
    'kl43q1561','kl43r1543','kl43r5470','kl43s7528','kl43r6725'
  )) is distinct from 11 then
    raise exception 'expected 11 Sherlys fleet plates after import';
  end if;
  if (select is_active from public.vehicles where registration_normalized = 'kl43r6725') then
    raise exception 'Bolero must remain inactive';
  end if;

  if (select count(*) from public.stock_ledger) is distinct from ledger_before
    or (select count(*) from public.stock_balances) is distinct from balance_before
    or (select count(*) from public.stock_lots) is distinct from lot_before
    or (select count(*) from public.product_selling_prices) is distinct from price_before
    or (select count(*) from public.invoice_notes) is distinct from note_before
    or (select count(*) from public.stock_dispatch_requests where stock_dispatch_requests.vehicle_id is not null) is distinct from dispatch_before
    or (select count(*) from public.stock_dispatch_assignments) is distinct from assignment_before
  then
    raise exception 'vehicle import changed stock or deliveries';
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
