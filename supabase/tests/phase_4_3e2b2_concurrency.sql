-- Shared setup for Phase 4.3E.2B.2 concurrency races. Not rolled back by design.
-- Cleaned by phase_4_3e2b2_concurrency_cleanup.sql
-- Note: lot_id ledger rows are created inside race sessions (not here) so deferred
-- integrity is not violated at setup commit.

drop table if exists public.phase43e2b2_race_target cascade;

create table public.phase43e2b2_race_target (
  name text primary key,
  value text not null
);

do $$
declare
  admin_id uuid := gen_random_uuid();
  branch uuid;
  zone uuid;
  crate_a uuid;
  crate_b uuid;
  product uuid;
  lot_main uuid;
  lot_dup uuid;
  txn_open uuid;
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  )
  values (
    '00000000-0000-0000-0000-000000000000', admin_id, 'authenticated', 'authenticated',
    'admin.phase43e2b2race@example.com',
    extensions.crypt('local-only', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"admin"}'::jsonb, now(), now()
  );

  begin
    perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values (admin_id, 'Phase 4.3E.2B.2 Race Admin', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select admin_id, roles.id, admin_id
      from public.roles
      where roles.code = 'admin'
      on conflict do nothing;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  set local role authenticated;

  branch := public.create_branch('p43e2b2_race', 'Phase 4.3E.2B.2 race');
  zone := public.create_zone(branch, 'z43e2b2r', 'Z43E2B2R', null);
  crate_a := public.create_crate(zone, 'c43e2b2ra', 'C43E2B2RA', null);
  crate_b := public.create_crate(zone, 'c43e2b2rb', 'C43E2B2RB', null);
  product := public.create_product('p43e2b2-race', 'Phase 4.3E.2B.2 race product', null, null);
  perform public.set_product_expiry_policy(product, 'expiry_controlled');

  reset role;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product, branch, 'RACE-MAIN', current_date + 60, clock_timestamp(),
    'available', 'receipt', admin_id
  ) returning id into lot_main;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product, branch, 'RACE-DUP', current_date + 60, clock_timestamp(),
    'available', 'receipt', admin_id
  ) returning id into lot_dup;

  -- Seed 5 units on crate_a for competing draw races
  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity
  ) values (
    'OPENING_STOCK', 'P43E2B2-RACE-OPEN', admin_id,
    'p43e2b2-race-open', 'fp-race-open', product, crate_a, 5
  ) returning id into txn_open;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values (txn_open, product, crate_a, 5, admin_id, clock_timestamp(), lot_main);

  perform app_private.apply_lot_aware_stock_deltas(
    txn_open,
    jsonb_build_array(jsonb_build_object(
      'product_id', product, 'lot_id', lot_main, 'crate_id', crate_a, 'quantity', 5
    ))
  );

  insert into public.phase43e2b2_race_target (name, value) values
    ('admin', admin_id::text),
    ('product', product::text),
    ('crate_a', crate_a::text),
    ('crate_b', crate_b::text),
    ('lot_main', lot_main::text),
    ('lot_dup', lot_dup::text);
end $$;
