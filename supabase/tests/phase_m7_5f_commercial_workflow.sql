-- M7.5F commercial workflow integration. Rolls back.
-- Does not issue tax invoices or GST credit notes, write stock, or flip flags.

begin;

do $$
declare
  admin_id uuid;
  closer_id uuid;
  godown_id uuid;
  note public.invoice_notes;
  note_line public.invoice_note_lines;
  dual_note public.invoice_notes;
  dual_line public.invoice_note_lines;
  ret_id uuid;
  dual_return_id uuid;
  posted_empty uuid;
  posted_version integer;
  adj jsonb;
  replay jsonb;
  driver_copy jsonb;
  accounts_copy jsonb;
  reconcil jsonb;
  readiness jsonb;
  cn_ready jsonb;
  ledger_before bigint;
  ledger_after bigint;
  expected_qty numeric;
  expected_subtotal numeric;
  credited_cases integer := 1;
  line_expected numeric;
  header_expected numeric := 0;
  tax_row record;
  tax_line record;
  rate numeric;
  oracle_taxable numeric;
  oracle_tax numeric;
  oracle_cgst numeric;
  oracle_sgst numeric;
  overlap_count integer;
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

  if not exists (
    select 1 from pg_constraint
    where conname = 'product_selling_prices_active_window_excl'
      and contype = 'x'
  ) then
    raise exception 'selling-price GiST exclusion is missing';
  end if;

  select count(*) into overlap_count
  from public.product_selling_prices a
  join public.product_selling_prices b
    on a.product_id = b.product_id
   and a.id < b.id
   and a.is_active
   and b.is_active
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
    raise exception 'statutory invoice or credit-note issuance RPC must not exist';
  end if;

  if exists (
    select 1 from public.invoice_financial_years where legal_allocation_enabled
  ) or exists (
    select 1 from public.invoice_number_series where legal_allocation_enabled
  ) or exists (
    select 1 from public.invoice_credit_note_number_series where legal_allocation_enabled
  ) then
    raise exception 'legal numbering must stay disabled';
  end if;

  if exists (
    select 1 from pg_class cls
    join pg_namespace nsp on nsp.oid = cls.relnamespace
    where nsp.nspname = 'public'
      and cls.relname in (
        'invoice_notes',
        'invoice_credit_adjustments',
        'stock_delivery_returns',
        'stock_delivery_return_lots'
      )
      and (not cls.relrowsecurity or not cls.relforcerowsecurity)
  ) then
    raise exception 'commercial tables must keep FORCE RLS';
  end if;

  select id into admin_id from auth.users where email = 'admin.m1s2qa@example.com';
  if admin_id is null then
    raise exception 'admin.m1s2qa is required';
  end if;

  -- Independent billed-unit oracle: billed_qty = cases × units/case; subtotal = round(qty × price, 2).
  -- PostgreSQL numeric round() is the oracle. Do not call gst_line_calc here.
  for note_line in
    select invoice_note_lines.*
    from public.invoice_note_lines
    join public.invoice_notes on invoice_notes.id = invoice_note_lines.invoice_note_id
    where invoice_notes.status = 'reviewed'
    order by invoice_notes.created_at desc, invoice_note_lines.line_no
    limit 40
  loop
    expected_qty := note_line.shipped_cases * note_line.billed_units_per_case;
    expected_subtotal := round(expected_qty * note_line.unit_amount, 2);
    if note_line.billed_quantity is distinct from expected_qty
      or note_line.line_amount is distinct from expected_subtotal
    then
      raise exception 'invoice-note line failed independent billed math: %', note_line.id;
    end if;
  end loop;

  -- Independent GST oracle against stored current previews, using round() not gst_line_calc.
  for tax_row in
    select *
    from public.invoice_tax_previews
    where is_current
    order by calculated_at desc
    limit 12
  loop
    if tax_row.watermark is distinct from U&'TAX CALCULATION PREVIEW \2014 NOT A TAX INVOICE' then
      raise exception 'tax preview watermark drifted';
    end if;
    for tax_line in
      select *
      from public.invoice_tax_preview_lines
      where preview_id = tax_row.id
    loop
      if tax_row.pricing_treatment = 'exclusive' then
        oracle_taxable := round(tax_line.line_amount, 2);
        oracle_cgst := round(oracle_taxable * tax_line.cgst_rate / 100, 2);
        oracle_sgst := round(oracle_taxable * tax_line.sgst_rate / 100, 2);
        oracle_tax := oracle_cgst + oracle_sgst
          + round(oracle_taxable * tax_line.igst_rate / 100, 2);
      else
        rate := case
          when tax_row.supply_kind = 'intra_state'
            then tax_line.cgst_rate + tax_line.sgst_rate
          else tax_line.igst_rate
        end;
        if rate = 0 then
          oracle_taxable := round(tax_line.line_amount, 2);
          oracle_tax := 0;
          oracle_cgst := 0;
          oracle_sgst := 0;
        else
          oracle_taxable := round(tax_line.line_amount * 100 / (100 + rate), 2);
          oracle_tax := round(tax_line.line_amount, 2) - oracle_taxable;
          if tax_row.supply_kind = 'intra_state' then
            oracle_cgst := round(oracle_tax * tax_line.cgst_rate / rate, 2);
            oracle_sgst := oracle_tax - oracle_cgst;
          else
            oracle_cgst := 0;
            oracle_sgst := 0;
          end if;
        end if;
      end if;
      if tax_line.taxable_value is distinct from oracle_taxable
        or tax_line.tax_amount is distinct from oracle_tax
        or tax_line.cgst_amount is distinct from oracle_cgst
        or tax_line.sgst_amount is distinct from oracle_sgst
      then
        raise exception 'tax preview line failed independent GST oracle: % vs taxable % tax %',
          tax_line.id, oracle_taxable, oracle_tax;
      end if;
    end loop;
  end loop;

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
  if note.tax_amount is distinct from 0 then
    raise exception 'invoice-note tax_amount must stay 0';
  end if;
  select * into note_line
  from public.invoice_note_lines
  where invoice_note_lines.invoice_note_id = note.id
  order by invoice_note_lines.line_no
  limit 1;

  header_expected := 0;
  for note_line in
    select * from public.invoice_note_lines where invoice_note_id = note.id
  loop
    line_expected := round(
      (note_line.shipped_cases * note_line.billed_units_per_case) * note_line.unit_amount,
      2
    );
    header_expected := header_expected + line_expected;
  end loop;
  if note.subtotal_amount is distinct from header_expected then
    raise exception 'invoice-note header failed independent subtotal oracle: % vs %',
      note.subtotal_amount, header_expected;
  end if;
  select * into note_line
  from public.invoice_note_lines
  where invoice_note_lines.invoice_note_id = note.id
  order by invoice_note_lines.line_no
  limit 1;

  select invoice_notes.* into dual_note
  from public.invoice_notes
  join public.stock_dispatch_requests
    on stock_dispatch_requests.id = invoice_notes.dispatch_id
  where invoice_notes.status = 'reviewed'
    and invoice_notes.id <> note.id
    and stock_dispatch_requests.stock_consumed
    and not exists (
      select 1
      from public.stock_delivery_returns
      where stock_delivery_returns.dispatch_id = invoice_notes.dispatch_id
    )
  order by invoice_notes.created_at desc
  limit 1;
  if dual_note.id is null then
    raise exception 'second reviewed note is required for dual-write fail-closed proof';
  end if;
  select * into dual_line
  from public.invoice_note_lines
  where invoice_note_lines.invoice_note_id = dual_note.id
  order by invoice_note_lines.line_no
  limit 1;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, reauthentication_token, email_change
  )
  values (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'closer.m75fsql@example.com',
    extensions.crypt('local-only-m75f', extensions.gen_salt('bf')),
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
  values (closer_id, 'M75F closer', true)
  on conflict (id) do update set is_active = true;

  select id into godown_id from auth.users where email = 'godown.m75fsql@example.com';
  if godown_id is null then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new,
      email_change_token_current, reauthentication_token, email_change
    )
    values (
      '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
      'godown.m75fsql@example.com',
      extensions.crypt('local-only-m75f', extensions.gen_salt('bf')),
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
  values (godown_id, 'M75F GM', true)
  on conflict (id) do update set is_active = true;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select godown_id, roles.id, admin_id
  from public.roles
  where roles.code = 'godown_manager'
  on conflict do nothing;
  insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
  values (godown_id, note.branch_id, admin_id)
  on conflict do nothing;
  insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
  values (godown_id, dual_note.branch_id, admin_id)
  on conflict do nothing;

  select count(*) into ledger_before from public.stock_ledger;

  perform set_config('app.delivery_return_write', 'on', true);
  insert into public.stock_delivery_returns (
    dispatch_id, branch_id, return_number, status, version,
    counted_at, counted_by, closed_at, closed_by, created_by
  )
  values (
    note.dispatch_id, note.branch_id, 'RET-F-SQL-' || note.note_number,
    'closed_missing', 1, clock_timestamp(), admin_id, clock_timestamp(), closer_id, admin_id
  )
  returning id into ret_id;
  insert into public.stock_delivery_return_lots (
    return_id, order_line_id, product_id, lot_id, source_crate_id,
    dispatched_cases, delivered_cases, saleable_cases, damaged_cases, uncertain_cases, missing_cases
  )
  values (
    ret_id, note_line.order_line_id, note_line.product_id, note_line.lot_id, note_line.crate_id,
    note_line.shipped_cases, 0, credited_cases, 0, 0, 0
  );

  begin
    insert into public.stock_delivery_returns (
      dispatch_id, branch_id, return_number, status, created_by
    )
    values (
      note.dispatch_id, note.branch_id, 'RET-F-SQL-DUP-' || note.note_number, 'awaiting_handback', admin_id
    );
    raise exception 'second return wave on one dispatch must fail';
  exception
    when unique_violation then
      null;
  end;

  -- Approved return used only to hit the dual-write fail-closed gate. Unresolved = 0.
  insert into public.stock_delivery_returns (
    dispatch_id, branch_id, return_number, status, version,
    counted_at, counted_by, approved_at, approved_by, created_by
  )
  values (
    dual_note.dispatch_id, dual_note.branch_id, 'RET-F-SQL-DW-' || dual_note.note_number,
    'approved', 1, clock_timestamp(), closer_id, clock_timestamp(), godown_id, admin_id
  )
  returning id into dual_return_id;
  insert into public.stock_delivery_return_lots (
    return_id, order_line_id, product_id, lot_id, source_crate_id,
    dispatched_cases, delivered_cases, saleable_cases, damaged_cases, uncertain_cases, missing_cases
  )
  values (
    dual_return_id, dual_line.order_line_id, dual_line.product_id, dual_line.lot_id, dual_line.crate_id,
    dual_line.shipped_cases, 0, dual_line.shipped_cases, 0, 0, 0
  );
  update public.stock_delivery_returns
  set approval_fingerprint = app_private.return_lot_fingerprint(dual_return_id)
  where id = dual_return_id;
  perform set_config('app.delivery_return_write', 'off', true);

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  driver_copy := public.get_invoice_note_preview(note.id, 'driver');
  if driver_copy ->> 'watermark' is distinct from U&'DRAFT INVOICE PREVIEW \2014 NOT A TAX INVOICE'
    or driver_copy ->> 'legal_invoice_number' is not null
    or driver_copy -> 'lines' -> 0 ->> 'unit_amount' is not null
    or driver_copy ? 'grand_total'
    or driver_copy ? 'tax_preview'
  then
    raise exception 'driver copy must keep the non-statutory overlay: %', driver_copy;
  end if;
  if (driver_copy -> 'lines' -> 0 ->> 'shipped_cases')::integer is distinct from note_line.shipped_cases then
    raise exception 'driver copy must keep shipped cases';
  end if;

  accounts_copy := public.get_invoice_note_preview(note.id, 'accounts');
  if accounts_copy ->> 'watermark' is distinct from U&'DRAFT INVOICE PREVIEW \2014 NOT A TAX INVOICE'
    or accounts_copy ->> 'legal_invoice_number' is not null
    or (accounts_copy -> 'lines' -> 0 ->> 'unit_amount')::numeric is distinct from note_line.unit_amount
    or (accounts_copy ->> 'subtotal_amount')::numeric is distinct from note.subtotal_amount
  then
    raise exception 'accounts copy must match the immutable invoice-note snapshot';
  end if;
  replay := public.get_invoice_note_preview(note.id, 'accounts');
  if (replay ->> 'subtotal_amount') is distinct from (accounts_copy ->> 'subtotal_amount')
    or (replay -> 'source' ->> 'invoice_note_version') is distinct from (accounts_copy -> 'source' ->> 'invoice_note_version')
  then
    raise exception 'repeated PDF preview must not mutate snapshots';
  end if;

  expected_qty := credited_cases * note_line.billed_units_per_case;
  expected_subtotal := round(expected_qty * note_line.unit_amount, 2);

  adj := public.prepare_credit_adjustment(ret_id, 'f-sql-approve', 1);
  if adj ->> 'status' is distinct from 'preview' then
    raise exception 'prepared status must start as preview: %', adj ->> 'status';
  end if;
  if (adj ->> 'credited_quantity')::numeric is distinct from expected_qty
    or (adj ->> 'subtotal_amount')::numeric is distinct from expected_subtotal
  then
    raise exception 'credit adjustment failed independent billed math: % vs qty % subtotal %',
      adj, expected_qty, expected_subtotal;
  end if;
  if (adj ->> 'legal_issuance_blocked')::boolean is distinct from true
    or adj ->> 'legal_credit_note_number' is not null
  then
    raise exception 'legal credit-note number must stay null';
  end if;

  reconcil := adj -> 'reconciliation';
  if (reconcil ->> 'returned_cases')::integer is distinct from credited_cases
    or reconcil ->> 'prices_from' is distinct from 'reviewed_invoice_note_snapshot'
  then
    raise exception 'reconciliation must use returned cases and invoice-note prices: %', reconcil;
  end if;

  replay := public.review_credit_adjustment(
    (adj ->> 'id')::uuid, 'approve', 'Internal Accounts reconciliation for F', 1
  );
  if replay ->> 'status' is distinct from 'approved' then
    raise exception 'approve must set approved: %', replay ->> 'status';
  end if;
  if (replay ->> 'subtotal_amount') is distinct from (adj ->> 'subtotal_amount') then
    raise exception 'review must not mutate financial snapshots';
  end if;
  if (replay -> 'reconciliation' ->> 'remaining_eligible_cases')::integer is distinct from 0 then
    raise exception 'remaining eligible cases must be 0 after occupying the returned case';
  end if;
  if (replay -> 'tax_readiness' ->> 'ready')::boolean is distinct from false
    or (replay -> 'tax_readiness' ->> 'legal_issuance_blocked')::boolean is distinct from true
  then
    raise exception 'tax readiness must stay blocked';
  end if;

  begin
    perform public.review_credit_adjustment(
      (adj ->> 'id')::uuid, 'approve', 'duplicate approve', (replay ->> 'version')::integer
    );
    raise exception 'duplicate approve must be rejected';
  exception
    when others then
      if sqlstate not in ('23514') then
        raise;
      end if;
  end;

  execute 'set local role postgres';
  select r.id, r.version into posted_empty, posted_version
  from public.stock_delivery_returns r
  where r.status = 'posted'
    and not exists (
      select 1 from public.stock_delivery_return_lots l where l.return_id = r.id
    )
  order by r.created_at desc
  limit 1;
  if posted_empty is null then
    raise exception 'posted owner return without lots is required for fail-closed proof';
  end if;
  execute 'set local role authenticated';
  begin
    perform public.prepare_credit_adjustment(posted_empty, 'f-sql-empty-lots', posted_version);
    raise exception 'posted return without lots must fail closed';
  exception
    when others then
      if sqlstate not in ('23514', '42501', 'P0002') then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', godown_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.post_delivery_return(dual_return_id, 1, 'f-sql-dual-write');
    raise exception 'post_delivery_return must fail closed while dual-write is off';
  exception
    when others then
      if sqlstate not in ('23514')
        or sqlerrm not ilike '%dual-write%'
      then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', godown_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.review_credit_adjustment(
      (adj ->> 'id')::uuid, 'reject', 'GM must not review', (adj ->> 'version')::integer
    );
    raise exception 'godown manager must not review credit adjustments';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  readiness := public.assess_invoice_finalization_readiness(note.id);
  cn_ready := public.assess_credit_note_issuance_readiness((adj ->> 'id')::uuid);
  if (readiness ->> 'ready')::boolean is distinct from false
    or (readiness ->> 'legal_issuance_blocked')::boolean is distinct from true
    or (cn_ready ->> 'ready')::boolean is distinct from false
    or (cn_ready ->> 'legal_issuance_blocked')::boolean is distinct from true
  then
    raise exception 'statutory issuance must stay blocked';
  end if;

  execute 'set local role postgres';
  select count(*) into ledger_after from public.stock_ledger;
  if ledger_before is distinct from ledger_after then
    raise exception 'commercial financial workflow must not write stock';
  end if;

  if exists (
    select 1 from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    )
      and value = 'true'::jsonb
  ) then
    raise exception 'operational stock flags leaked true';
  end if;
end;
$$;

rollback;
