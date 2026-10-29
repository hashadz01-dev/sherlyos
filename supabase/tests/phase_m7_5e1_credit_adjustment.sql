-- M7.5E.1 verified-return credit-adjustment preview.
-- Rolls back. Does not issue GST credit notes, write stock, or flip flags.

begin;

do $$
declare
  admin_id uuid;
  closer_id uuid;
  godown_id uuid;
  note public.invoice_notes;
  note_line public.invoice_note_lines;
  unverified public.invoice_notes;
  over_note public.invoice_notes;
  over_line public.invoice_note_lines;
  ret_id uuid;
  unverified_id uuid;
  over_return_id uuid;
  adj jsonb;
  replay jsonb;
  expected_qty numeric(14, 4);
  expected_subtotal numeric(14, 2);
  ledger_before bigint;
  ledger_after bigint;
  readiness jsonb;
begin
  if exists (
    select 1
    from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    )
      and value = 'true'::jsonb
  ) then
    raise exception 'operational stock flags must remain false';
  end if;

  if to_regprocedure('public.finalize_invoice_note(uuid, integer)') is not null
    or to_regprocedure('public.issue_tax_invoice(uuid, integer)') is not null
    or to_regprocedure('public.allocate_statutory_invoice_number(text)') is not null
    or to_regprocedure('public.create_invoice_credit_note(uuid)') is not null
    or to_regprocedure('public.issue_gst_credit_note(uuid, integer)') is not null
  then
    raise exception 'statutory invoice or credit-note issuance RPC must not exist';
  end if;

  if to_regprocedure('public.post_delivery_return(uuid, integer, text)') is null then
    raise exception 'M7.4B post_delivery_return must remain the stock writer';
  end if;

  select id into admin_id from auth.users where email = 'admin.m1s2qa@example.com';
  if admin_id is null then
    raise exception 'admin.m1s2qa is required';
  end if;

  select invoice_notes.* into note
  from public.invoice_notes
  join public.stock_dispatch_requests
    on stock_dispatch_requests.id = invoice_notes.dispatch_id
  where invoice_notes.status = 'reviewed'
    and stock_dispatch_requests.stock_consumed
    and stock_dispatch_requests.posted_transaction_id is not null
    and not exists (
      select 1
      from public.stock_delivery_returns
      where stock_delivery_returns.dispatch_id = invoice_notes.dispatch_id
    )
  order by invoice_notes.created_at desc
  limit 1;
  if note.id is null then
    raise exception 'reviewed invoice note without a delivery return is required';
  end if;

  select * into note_line
  from public.invoice_note_lines
  where invoice_note_lines.invoice_note_id = note.id
  order by invoice_note_lines.line_no
  limit 1;

  -- Independent expected values from the reviewed snapshot, not live prices.
  expected_qty := 1 * note_line.billed_units_per_case;
  expected_subtotal := round(expected_qty * note_line.unit_amount, 2);

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, reauthentication_token, email_change
  )
  values (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'closer.m75e1sql@example.com',
    extensions.crypt('local-only-m75e1', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
    replace(gen_random_uuid()::text, '-', '') || 'c',
    replace(gen_random_uuid()::text, '-', '') || 'r',
    replace(gen_random_uuid()::text, '-', '') || 'n',
    replace(gen_random_uuid()::text, '-', '') || 'e',
    replace(gen_random_uuid()::text, '-', '') || 'a',
    ''
  )
  returning id into closer_id;

  insert into public.profiles (id, full_name, is_active)
  values (closer_id, 'M75E1 closer', true)
  on conflict (id) do update set is_active = true;

  select id into godown_id from auth.users where email = 'godown.m75e1sql@example.com';
  if godown_id is null then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new,
      email_change_token_current, reauthentication_token, email_change
    )
    values (
      '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
      'godown.m75e1sql@example.com',
      extensions.crypt('local-only-m75e1', extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
      replace(gen_random_uuid()::text, '-', '') || 'c',
      replace(gen_random_uuid()::text, '-', '') || 'r',
      replace(gen_random_uuid()::text, '-', '') || 'n',
      replace(gen_random_uuid()::text, '-', '') || 'e',
      replace(gen_random_uuid()::text, '-', '') || 'a',
      ''
    )
    returning id into godown_id;
  end if;
  insert into public.profiles (id, full_name, is_active)
  values (godown_id, 'M75E1 GM', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select godown_id, roles.id, admin_id
  from public.roles
  where roles.code = 'godown_manager'
  on conflict do nothing;
  insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
  values (godown_id, note.branch_id, admin_id)
  on conflict do nothing;

  select count(*) into ledger_before from public.stock_ledger;

  perform set_config('app.delivery_return_write', 'on', true);
  insert into public.stock_delivery_returns (
    dispatch_id, branch_id, return_number, status, version,
    counted_at, counted_by, closed_at, closed_by, created_by
  )
  values (
    note.dispatch_id, note.branch_id, 'RET-E1-SQL-' || note.note_number,
    'closed_missing', 1, clock_timestamp(), admin_id, clock_timestamp(), closer_id, admin_id
  )
  returning id into ret_id;
  insert into public.stock_delivery_return_lots (
    return_id, order_line_id, product_id, lot_id, source_crate_id,
    dispatched_cases, delivered_cases, saleable_cases, damaged_cases, uncertain_cases, missing_cases
  )
  values (
    ret_id, note_line.order_line_id, note_line.product_id, note_line.lot_id, note_line.crate_id,
    note_line.shipped_cases, 0, 1, 0, 0, 0
  );
  perform set_config('app.delivery_return_write', 'off', true);

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  adj := public.prepare_credit_adjustment(ret_id, 'e1-sql-partial', 1);

  if adj ->> 'watermark' is distinct from U&'CREDIT ADJUSTMENT PREVIEW \2014 NOT A GST CREDIT NOTE' then
    raise exception 'watermark missing: %', adj ->> 'watermark';
  end if;
  if (adj ->> 'legal_issuance_blocked')::boolean is distinct from true then
    raise exception 'legal issuance must stay blocked';
  end if;
  if adj ->> 'legal_credit_note_number' is not null then
    raise exception 'legal credit-note number must stay null';
  end if;
  if (adj ->> 'credited_cases')::integer is distinct from 1 then
    raise exception 'partial return must credit 1 case, got %', adj ->> 'credited_cases';
  end if;
  if (adj ->> 'credited_quantity')::numeric is distinct from expected_qty then
    raise exception 'billed qty % <> independent %', adj ->> 'credited_quantity', expected_qty;
  end if;
  if (adj ->> 'subtotal_amount')::numeric is distinct from expected_subtotal then
    raise exception 'subtotal % <> independent %', adj ->> 'subtotal_amount', expected_subtotal;
  end if;
  if (adj ->> 'adjustment_total')::numeric is distinct from expected_subtotal
     and adj ->> 'tax_preview_state' <> 'tax_preview'
  then
    raise exception 'blocked tax must keep total equal to snapshot subtotal';
  end if;
  if adj ->> 'status' is distinct from 'preview' then
    raise exception 'status must stay preview-only';
  end if;
  if not exists (
    select 1
    from jsonb_array_elements(adj -> 'blockers') blocker
    where blocker ->> 'code' = 'gst_credit_note_disabled'
  ) then
    raise exception 'gst credit-note blocker missing';
  end if;
  if (adj -> 'lines' -> 0 ->> 'unit_amount')::numeric is distinct from note_line.unit_amount then
    raise exception 'historical unit price was not preserved';
  end if;
  if (adj -> 'lines' -> 0 ->> 'billed_units_per_case')::numeric
     is distinct from note_line.billed_units_per_case
  then
    raise exception 'historical billing conversion was not preserved';
  end if;

  replay := public.prepare_credit_adjustment(ret_id, 'e1-sql-partial', 1);
  if replay ->> 'id' is distinct from adj ->> 'id' then
    raise exception 'duplicate idempotency key must return the same adjustment';
  end if;
  if (replay ->> 'subtotal_amount')::numeric is distinct from expected_subtotal then
    raise exception 'retry must preserve original financial values';
  end if;

  replay := public.prepare_credit_adjustment(ret_id, 'e1-sql-partial-b', 1);
  if replay ->> 'id' is distinct from adj ->> 'id' then
    raise exception 'second key for the same return must not duplicate the adjustment';
  end if;

  if not exists (
    select 1
    from public.invoice_credit_adjustment_events
    where invoice_credit_adjustment_events.adjustment_id = (adj ->> 'id')::uuid
      and invoice_credit_adjustment_events.event_type = 'prepared'
  ) then
    raise exception 'prepared audit event missing';
  end if;

  begin
    update public.invoice_credit_adjustment_lines
    set unit_amount = 99
    where adjustment_id = (adj ->> 'id')::uuid;
    raise exception 'financial snapshot must be immutable';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  execute 'set local role postgres';
  set local session_replication_role = replica;
  update public.product_selling_prices
  set unit_amount = unit_amount + 50
  where product_id = note_line.product_id
    and is_active;
  update public.products
  set billed_units_per_case = billed_units_per_case + 3
  where id = note_line.product_id
    and billed_units_per_case is not null;
  set local session_replication_role = origin;

  execute 'set local role authenticated';
  replay := public.get_credit_adjustment((adj ->> 'id')::uuid);
  if (replay -> 'lines' -> 0 ->> 'unit_amount')::numeric is distinct from note_line.unit_amount then
    raise exception 'live price change must not alter the snapshot';
  end if;
  if (replay -> 'lines' -> 0 ->> 'billed_units_per_case')::numeric
     is distinct from note_line.billed_units_per_case
  then
    raise exception 'live billing conversion must not alter the snapshot';
  end if;
  if (replay ->> 'subtotal_amount')::numeric is distinct from expected_subtotal then
    raise exception 'live masters must not alter historical totals';
  end if;

  perform set_config('request.jwt.claim.sub', godown_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.prepare_credit_adjustment(ret_id, 'e1-sql-gm', 1);
    raise exception 'godown manager must not prepare credit adjustments';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  execute 'set local role postgres';

  select invoice_notes.* into unverified
  from public.invoice_notes
  join public.stock_dispatch_requests
    on stock_dispatch_requests.id = invoice_notes.dispatch_id
  where invoice_notes.status = 'reviewed'
    and invoice_notes.id <> note.id
    and not exists (
      select 1
      from public.stock_delivery_returns
      where stock_delivery_returns.dispatch_id = invoice_notes.dispatch_id
    )
  order by invoice_notes.created_at desc
  limit 1;
  if unverified.id is null then
    raise exception 'second reviewed note is required for unverified-return proof';
  end if;

  perform set_config('app.delivery_return_write', 'on', true);
  insert into public.stock_delivery_returns (
    dispatch_id, branch_id, return_number, status, created_by
  )
  values (
    unverified.dispatch_id, unverified.branch_id, 'RET-E1-SQL-UNV-' || unverified.note_number,
    'awaiting_handback', admin_id
  )
  returning id into unverified_id;
  perform set_config('app.delivery_return_write', 'off', true);

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.prepare_credit_adjustment(unverified_id, 'e1-sql-unv', 1);
    raise exception 'unverified return must be rejected';
  exception
    when others then
      if sqlstate not in ('23514') then
        raise;
      end if;
  end;

  execute 'set local role postgres';
  select invoice_notes.* into over_note
  from public.invoice_notes
  join public.stock_dispatch_requests
    on stock_dispatch_requests.id = invoice_notes.dispatch_id
  where invoice_notes.status = 'reviewed'
    and invoice_notes.id not in (note.id, unverified.id)
    and not exists (
      select 1
      from public.stock_delivery_returns
      where stock_delivery_returns.dispatch_id = invoice_notes.dispatch_id
    )
  order by invoice_notes.created_at desc
  limit 1;
  if over_note.id is null then
    raise exception 'third reviewed note is required for over-credit proof';
  end if;
  select * into over_line
  from public.invoice_note_lines
  where invoice_note_lines.invoice_note_id = over_note.id
  order by invoice_note_lines.line_no
  limit 1;

  set local session_replication_role = replica;
  update public.invoice_note_lines
  set shipped_cases = 1
  where id = over_line.id;
  set local session_replication_role = origin;

  perform set_config('app.delivery_return_write', 'on', true);
  insert into public.stock_delivery_returns (
    dispatch_id, branch_id, return_number, status, version,
    counted_at, counted_by, closed_at, closed_by, created_by
  )
  values (
    over_note.dispatch_id, over_note.branch_id, 'RET-E1-SQL-OVER-' || over_note.note_number,
    'closed_missing', 1, clock_timestamp(), admin_id, clock_timestamp(), closer_id, admin_id
  )
  returning id into over_return_id;
  insert into public.stock_delivery_return_lots (
    return_id, order_line_id, product_id, lot_id, source_crate_id,
    dispatched_cases, delivered_cases, saleable_cases, damaged_cases, uncertain_cases, missing_cases
  )
  values (
    over_return_id, over_line.order_line_id, over_line.product_id, over_line.lot_id, over_line.crate_id,
    2, 0, 2, 0, 0, 0
  );
  perform set_config('app.delivery_return_write', 'off', true);

  execute 'set local role authenticated';
  begin
    perform public.prepare_credit_adjustment(over_return_id, 'e1-sql-over', 1);
    raise exception 'over-credit must be rejected';
  exception
    when others then
      if sqlstate not in ('23514') then
        raise;
      end if;
  end;

  execute 'set local role postgres';
  select count(*) into ledger_after from public.stock_ledger;
  if ledger_before is distinct from ledger_after then
    raise exception 'credit-adjustment preview must not write stock';
  end if;

  readiness := public.assess_invoice_finalization_readiness(note.id);
  if (readiness ->> 'ready')::boolean is distinct from false
     or (readiness ->> 'legal_issuance_blocked')::boolean is distinct from true
  then
    raise exception 'statutory issuance must remain blocked';
  end if;

  if exists (
    select 1
    from public.invoice_financial_years
    where legal_allocation_enabled
  ) or exists (
    select 1
    from public.invoice_number_series
    where legal_allocation_enabled
  ) then
    raise exception 'legal numbering allocation must stay disabled';
  end if;
end;
$$;

rollback;
