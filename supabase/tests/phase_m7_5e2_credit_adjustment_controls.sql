-- M7.5E.2 credit-adjustment review, reconciliation, and credit-note readiness.
-- Rolls back. Does not issue GST credit notes, write stock, or flip flags.

begin;

do $$
declare
  admin_id uuid;
  closer_id uuid;
  godown_id uuid;
  note public.invoice_notes;
  note_line public.invoice_note_lines;
  reject_note public.invoice_notes;
  reject_line public.invoice_note_lines;
  ret_id uuid;
  reject_return_id uuid;
  adj jsonb;
  replay jsonb;
  reconcil jsonb;
  readiness jsonb;
  fy_id uuid;
  series_id uuid;
  first_num jsonb;
  second_num jsonb;
  ledger_before bigint;
  ledger_after bigint;
  codes text;
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
    or to_regprocedure('public.allocate_credit_note_number(uuid)') is not null
  then
    raise exception 'statutory invoice or credit-note issuance RPC must not exist';
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

  select invoice_notes.* into reject_note
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
  if reject_note.id is null then
    raise exception 'second reviewed note is required for rejection proof';
  end if;
  select * into reject_line
  from public.invoice_note_lines
  where invoice_note_lines.invoice_note_id = reject_note.id
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
    'closer.m75e2sql@example.com',
    extensions.crypt('local-only-m75e2', extensions.gen_salt('bf')),
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
  values (closer_id, 'M75E2 closer', true)
  on conflict (id) do update set is_active = true;

  select id into godown_id from auth.users where email = 'godown.m75e2sql@example.com';
  if godown_id is null then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new,
      email_change_token_current, reauthentication_token, email_change
    )
    values (
      '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
      'godown.m75e2sql@example.com',
      extensions.crypt('local-only-m75e2', extensions.gen_salt('bf')),
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
  values (godown_id, 'M75E2 GM', true)
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
    note.dispatch_id, note.branch_id, 'RET-E2-SQL-' || note.note_number,
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
  insert into public.stock_delivery_returns (
    dispatch_id, branch_id, return_number, status, version,
    counted_at, counted_by, closed_at, closed_by, created_by
  )
  values (
    reject_note.dispatch_id, reject_note.branch_id, 'RET-E2-SQL-REJ-' || reject_note.note_number,
    'closed_missing', 1, clock_timestamp(), admin_id, clock_timestamp(), closer_id, admin_id
  )
  returning id into reject_return_id;
  insert into public.stock_delivery_return_lots (
    return_id, order_line_id, product_id, lot_id, source_crate_id,
    dispatched_cases, delivered_cases, saleable_cases, damaged_cases, uncertain_cases, missing_cases
  )
  values (
    reject_return_id, reject_line.order_line_id, reject_line.product_id, reject_line.lot_id,
    reject_line.crate_id, reject_line.shipped_cases, 0, 1, 0, 0, 0
  );
  perform set_config('app.delivery_return_write', 'off', true);

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  adj := public.prepare_credit_adjustment(ret_id, 'e2-sql-approve', 1);
  if adj ->> 'status' is distinct from 'preview' then
    raise exception 'prepared status must start as preview: %', adj ->> 'status';
  end if;
  if (adj ->> 'legal_issuance_blocked')::boolean is distinct from true
    or adj ->> 'legal_credit_note_number' is not null
  then
    raise exception 'legal credit-note number must stay null';
  end if;

  reconcil := adj -> 'reconciliation';
  if (reconcil ->> 'returned_cases')::integer is distinct from 1
    or coalesce((
      select (grain ->> 'this_adjustment_cases')::integer
      from jsonb_array_elements(reconcil -> 'lines') grain
      where (grain ->> 'this_adjustment_cases')::integer > 0
      limit 1
    ), 0) is distinct from 1
  then
    raise exception 'reconciliation must use whole-case returned quantity: %', reconcil;
  end if;
  if reconcil ->> 'prices_from' is distinct from 'reviewed_invoice_note_snapshot' then
    raise exception 'reconciliation must use invoice-note prices';
  end if;

  replay := public.review_credit_adjustment(
    (adj ->> 'id')::uuid, 'approve', 'Internal Accounts reconciliation for E.2', 1
  );
  if replay ->> 'status' is distinct from 'approved' then
    raise exception 'approve must set approved: %', replay ->> 'status';
  end if;
  if replay ->> 'review_reason' is distinct from 'Internal Accounts reconciliation for E.2' then
    raise exception 'review reason must persist';
  end if;
  if (replay ->> 'subtotal_amount') is distinct from (adj ->> 'subtotal_amount') then
    raise exception 'review must not mutate financial snapshots';
  end if;
  if (replay -> 'tax_readiness' ->> 'ready')::boolean is distinct from false
    or (replay -> 'tax_readiness' ->> 'legal_issuance_blocked')::boolean is distinct from true
  then
    raise exception 'tax readiness must stay blocked: %', replay -> 'tax_readiness';
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

  replay := public.prepare_credit_adjustment(ret_id, 'e2-sql-approve-b', 1);
  if replay ->> 'id' is distinct from adj ->> 'id' then
    raise exception 'approved adjustment must occupy the return';
  end if;

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
  adj := public.prepare_credit_adjustment(reject_return_id, 'e2-sql-reject', 1);
  replay := public.review_credit_adjustment(
    (adj ->> 'id')::uuid, 'reject', 'Returned quantity is not eligible for internal credit', 1
  );
  if replay ->> 'status' is distinct from 'rejected' then
    raise exception 'reject must set rejected: %', replay ->> 'status';
  end if;
  replay := public.prepare_credit_adjustment(reject_return_id, 'e2-sql-reject-retry', 1);
  if replay ->> 'id' is not distinct from adj ->> 'id'
    or replay ->> 'status' is distinct from 'preview'
  then
    raise exception 'rejected return must allow a replacement preview';
  end if;

  readiness := public.assess_credit_note_issuance_readiness((adj ->> 'id')::uuid);
  codes := (
    select string_agg(value ->> 'code', ',')
    from jsonb_array_elements(readiness -> 'blockers')
  );
  if (readiness ->> 'ready')::boolean is distinct from false
    or (readiness ->> 'legal_issuance_blocked')::boolean is distinct from true
    or codes not ilike '%credit_note_issue_rpc_disabled%'
    or codes not ilike '%original_legal_invoice_missing%'
    or codes not ilike '%credit_note_tax_unapproved%'
    or codes not ilike '%legal_credit_note_numbering_disabled%'
  then
    raise exception 'credit-note readiness must stay fail-closed: %', readiness;
  end if;

  execute 'set local role postgres';
  select invoice_financial_years.id into fy_id
  from public.invoice_financial_years
  where invoice_financial_years.status = 'verified'
    and invoice_financial_years.legal_allocation_enabled = false
  order by invoice_financial_years.created_at
  limit 1;
  if fy_id is null then
    raise exception 'verified financial year is required for synthetic credit-note numbering';
  end if;
  perform set_config('app.credit_note_numbering_write', 'on', true);
  insert into public.invoice_credit_note_number_series (
    financial_year_id, series_code, prefix, pad_width, is_synthetic, created_by
  )
  values (fy_id, 'PROOF-E2', 'PROOF-CN-E2', 5, true, admin_id)
  returning id into series_id;
  perform set_config('app.credit_note_numbering_write', 'off', true);
  perform set_config('app.credit_note_number_proof', 'on', true);
  first_num := app_private.allocate_synthetic_credit_note_number(series_id);
  second_num := app_private.allocate_synthetic_credit_note_number(series_id);
  if first_num ->> 'formatted_number' is not distinct from second_num ->> 'formatted_number'
    or (first_num ->> 'is_legal')::boolean is distinct from false
    or first_num ->> 'formatted_number' not like 'PROOF-CN-%'
  then
    raise exception 'synthetic credit-note numbers must stay unique and illegal: % %',
      first_num, second_num;
  end if;
  perform set_config('app.credit_note_number_proof', 'off', true);

  if exists (
    select 1 from public.invoice_financial_years where legal_allocation_enabled
  ) or exists (
    select 1 from public.invoice_credit_note_number_series where legal_allocation_enabled
  ) then
    raise exception 'legal credit-note allocation must stay disabled';
  end if;

  select count(*) into ledger_after from public.stock_ledger;
  if ledger_before is distinct from ledger_after then
    raise exception 'credit-adjustment review must not write stock';
  end if;
end;
$$;

rollback;
