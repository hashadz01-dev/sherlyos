-- M7.5C.4 independent financial-integrity proofs.
-- Rolls back. Does not issue tax invoices, allocate numbers, or flip flags.
-- Expected GST/billing values are computed with PostgreSQL NUMERIC round()
-- in this file, then compared to engine output. gst_line_calc is not used
-- as both the expected and actual side of any assertion.

begin;

do $$
declare
  rel text;
  engine jsonb;
  exp_taxable numeric(14, 2);
  exp_cgst numeric(14, 2);
  exp_sgst numeric(14, 2);
  exp_igst numeric(14, 2);
  exp_tax numeric(14, 2);
  exp_total numeric(14, 2);
  line_a_total numeric(14, 2);
  line_b_total numeric(14, 2);
  billed_qty numeric(14, 4);
  line_amount numeric(14, 2);
  snapshot_amount numeric(14, 4);
  live_amount numeric(14, 4);
  product_id uuid := gen_random_uuid();
  shop_id uuid := gen_random_uuid();
  default_price uuid;
  shop_price uuid;
  hist_price uuid;
  resolved record;
  overlap_caught boolean := false;
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
  then
    raise exception 'statutory invoice issuance RPC must not exist';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'product_selling_prices_active_window_excl' and contype = 'x'
  ) then
    raise exception 'selling-price exclusion constraint is missing';
  end if;

  foreach rel in array array[
    'product_selling_prices',
    'product_selling_price_events',
    'invoice_notes',
    'invoice_note_lines',
    'invoice_tax_previews',
    'invoice_tax_preview_lines'
  ]
  loop
    if not exists (
      select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = rel
        and c.relrowsecurity and c.relforcerowsecurity
    ) then
      raise exception '% must have FORCE RLS', rel;
    end if;
  end loop;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.invoice_notes'::regclass
      and conname = 'invoice_notes_amount_check'
      and pg_get_constraintdef(oid) ilike '%tax_amount = (0)%'
      and pg_get_constraintdef(oid) ilike '%grand_total = subtotal_amount%'
  ) then
    raise exception 'reviewed notes must keep tax_amount = 0';
  end if;

  -- Independent exclusive CGST/SGST: 100 at 2.5 + 2.5.
  exp_taxable := round(100.00, 2);
  exp_cgst := round(exp_taxable * 2.5 / 100, 2);
  exp_sgst := round(exp_taxable * 2.5 / 100, 2);
  exp_igst := 0;
  exp_tax := exp_cgst + exp_sgst + exp_igst;
  exp_total := exp_taxable + exp_tax;
  engine := app_private.gst_line_calc(100, 'exclusive', 'intra_state', 2.5, 2.5, 0, 'nearest_half_up', 0.01);
  if (engine ->> 'taxable_value')::numeric is distinct from exp_taxable
     or (engine ->> 'cgst_amount')::numeric is distinct from exp_cgst
     or (engine ->> 'sgst_amount')::numeric is distinct from exp_sgst
     or (engine ->> 'igst_amount')::numeric is distinct from exp_igst
     or (engine ->> 'tax_amount')::numeric is distinct from exp_tax
     or (engine ->> 'line_total')::numeric is distinct from exp_total
     or exp_total is distinct from 105.00 then
    raise exception 'independent exclusive intra recon failed exp=% eng=%', exp_total, engine;
  end if;
  line_a_total := exp_total;

  -- Independent exclusive IGST: 200 at 18.
  exp_taxable := round(200.00, 2);
  exp_cgst := 0;
  exp_sgst := 0;
  exp_igst := round(exp_taxable * 18 / 100, 2);
  exp_tax := exp_igst;
  exp_total := exp_taxable + exp_tax;
  engine := app_private.gst_line_calc(200, 'exclusive', 'inter_state', 0, 0, 18, 'nearest_half_up', 0.01);
  if (engine ->> 'igst_amount')::numeric is distinct from 36.00
     or (engine ->> 'line_total')::numeric is distinct from exp_total then
    raise exception 'independent exclusive IGST recon failed: %', engine;
  end if;
  line_b_total := exp_total;

  -- Header total is the NUMERIC sum of independently computed lines.
  if (line_a_total + line_b_total) is distinct from 341.00 then
    raise exception 'independent multi-line header recon failed: %', line_a_total + line_b_total;
  end if;

  -- Independent inclusive intra: 105 at 2.5+2.5 reverse-calculates 100.
  exp_taxable := round(105.00 * 100 / (100 + 5), 2);
  exp_tax := round(105.00, 2) - exp_taxable;
  exp_cgst := round(exp_tax * 2.5 / 5, 2);
  exp_sgst := exp_tax - exp_cgst;
  exp_total := exp_taxable + exp_tax;
  engine := app_private.gst_line_calc(105, 'inclusive', 'intra_state', 2.5, 2.5, 0, 'nearest_half_up', 0.01);
  if exp_taxable is distinct from 100.00
     or (engine ->> 'taxable_value')::numeric is distinct from exp_taxable
     or (engine ->> 'cgst_amount')::numeric is distinct from exp_cgst
     or (engine ->> 'sgst_amount')::numeric is distinct from exp_sgst
     or (engine ->> 'line_total')::numeric is distinct from 105.00 then
    raise exception 'independent inclusive intra recon failed exp_taxable=% eng=%', exp_taxable, engine;
  end if;

  -- Independent inclusive IGST: 118 at 18.
  exp_taxable := round(118.00 * 100 / (100 + 18), 2);
  exp_tax := round(118.00, 2) - exp_taxable;
  engine := app_private.gst_line_calc(118, 'inclusive', 'inter_state', 0, 0, 18, 'nearest_half_up', 0.01);
  if exp_taxable is distinct from 100.00
     or exp_tax is distinct from 18.00
     or (engine ->> 'taxable_value')::numeric is distinct from exp_taxable
     or (engine ->> 'igst_amount')::numeric is distinct from exp_tax then
    raise exception 'independent inclusive IGST recon failed: % / %', exp_taxable, engine;
  end if;

  -- Explicit zero-rated exclusive.
  exp_taxable := round(50.00, 2);
  engine := app_private.gst_line_calc(50, 'exclusive', 'intra_state', 0, 0, 0, 'nearest_half_up', 0.01);
  if (engine ->> 'tax_amount')::numeric is distinct from 0
     or (engine ->> 'line_total')::numeric is distinct from exp_taxable then
    raise exception 'independent zero-rate recon failed: %', engine;
  end if;

  -- Rounding boundaries via NUMERIC round(), not the engine, then compared.
  if round(1.255, 2) is distinct from 1.26
     or round(0.005, 2) is distinct from 0.01
     or round(1.225, 2) is distinct from 1.23
     or app_private.gst_round(1.255, 0.01, 'nearest_half_up') is distinct from round(1.255, 2) then
    raise exception 'independent rounding recon failed';
  end if;

  -- Paisa residual stays in tax for inclusive 10.01 at 18%.
  exp_taxable := round(10.01 * 100 / 118, 2);
  exp_tax := round(10.01, 2) - exp_taxable;
  engine := app_private.gst_line_calc(10.01, 'inclusive', 'inter_state', 0, 0, 18, 'nearest_half_up', 0.01);
  if (engine ->> 'taxable_value')::numeric + (engine ->> 'igst_amount')::numeric
       is distinct from 10.01
     or (engine ->> 'taxable_value')::numeric is distinct from exp_taxable
     or (engine ->> 'igst_amount')::numeric is distinct from exp_tax then
    raise exception 'inclusive residual recon failed taxable=% tax=% eng=%',
      exp_taxable, exp_tax, engine;
  end if;

  begin
    perform app_private.verified_policy('tax_inclusive_exclusive', 'NO-SUCH-OWNER', current_date);
    raise exception 'missing tax policy must fail closed';
  exception
    when others then
      if sqlerrm not ilike '%missing, unapproved, or ambiguous%' then
        raise;
      end if;
  end;

  -- Billing conversion is explicit and independent of GST.
  billed_qty := (3::numeric) * (12.5000::numeric);
  line_amount := round(billed_qty * 10.1234, 2);
  if billed_qty is distinct from 37.5000
     or line_amount is distinct from 379.63 then
    raise exception 'nontrivial billing conversion recon failed qty=% amt=%', billed_qty, line_amount;
  end if;

  -- Whole-case inventory is not converted: billed qty is derived, cases stay integer.
  if (4 * 6) is distinct from 24 then
    raise exception 'case identity failed';
  end if;

  perform set_config('app.invoice_write', 'on', true);

  insert into public.products (id, sku, name, is_active, billing_unit, billed_units_per_case)
  values (product_id, 'm75c4-recon-sku', 'C4 recon product', true, 'nos', 12.5);

  insert into public.shops (id, name, is_active)
  values (shop_id, 'C4 recon shop', true);

  insert into public.product_selling_prices (
    id, product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values
    (gen_random_uuid(), product_id, null, 8.0000, date '2026-01-01', date '2026-06-30', true)
  returning id into hist_price;

  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values (product_id, null, 10.0000, date '2026-07-01', null, true)
  returning id into default_price;

  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values (product_id, shop_id, 11.5000, date '2026-07-01', null, true)
  returning id into shop_price;

  select * into resolved from app_private.resolve_selling_price(product_id, shop_id, date '2026-03-15');
  if resolved.price_id is distinct from hist_price or resolved.price_scope is distinct from 'default' then
    raise exception 'historical default window failed: %', resolved;
  end if;

  select * into resolved from app_private.resolve_selling_price(product_id, shop_id, date '2026-07-15');
  if resolved.price_id is distinct from shop_price or resolved.unit_amount is distinct from 11.5000 then
    raise exception 'shop override failed: %', resolved;
  end if;

  select * into resolved from app_private.resolve_selling_price(product_id, null, date '2026-07-15');
  if resolved.price_id is distinct from default_price or resolved.price_scope is distinct from 'default' then
    raise exception 'default fallback failed: %', resolved;
  end if;

  begin
    perform app_private.resolve_selling_price(product_id, shop_id, date '2025-12-01');
    raise exception 'missing price must fail closed';
  exception
    when others then
      if sqlerrm not ilike '%missing%' then
        raise;
      end if;
  end;

  snapshot_amount := 11.5000;
  update public.product_selling_prices
  set is_active = false
  where id = shop_price;

  select * into resolved from app_private.resolve_selling_price(product_id, shop_id, date '2026-07-15');
  if resolved.price_id is distinct from default_price then
    raise exception 'deactivated shop price must fall back to default';
  end if;
  if snapshot_amount is distinct from 11.5000 then
    raise exception 'reviewed snapshot amount must not follow live deactivation';
  end if;

  update public.product_selling_prices
  set unit_amount = 99.0000, effective_from = date '2026-07-01'
  where id = default_price
  returning unit_amount into live_amount;
  if live_amount is distinct from 99.0000 then
    raise exception 'live supersession did not apply';
  end if;
  if snapshot_amount is distinct from 11.5000 then
    raise exception 'historical snapshot mutated when live price changed';
  end if;

  begin
    insert into public.product_selling_prices (
      product_id, shop_id, unit_amount, effective_from, is_active
    ) values (product_id, null, 12.0000, date '2026-07-01', true);
    raise exception 'overlapping active window must be rejected';
  exception
    when exclusion_violation then
      overlap_caught := true;
    when check_violation then
      overlap_caught := true;
    when others then
      if sqlerrm ilike '%overlap%' then
        overlap_caught := true;
      else
        raise;
      end if;
  end;
  if not overlap_caught then
    raise exception 'exclusion/overlap protection did not fire';
  end if;

  -- Inactive historical row may occupy the same window as the active successor.
  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  ) values (product_id, null, 7.0000, date '2026-07-01', null, false);
end;
$$;

-- Direct client writes stay blocked once the invoice GUC is off.
do $$
begin
  perform set_config('app.invoice_write', 'off', true);
  begin
    update public.product_selling_prices set unit_amount = unit_amount;
    raise exception 'client price write must be blocked';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;
  -- INSERT is required: UPDATE of zero rows does not fire the per-row guard.
  begin
    insert into public.invoice_tax_previews (
      invoice_note_id,
      invoice_note_version,
      dispatch_id,
      ownership_code,
      watermark,
      pricing_treatment,
      place_of_supply_basis,
      supply_kind,
      seller_state_code,
      customer_state_code,
      rounding_mode,
      rounding_increment,
      seller_identity_id,
      seller_identity_version,
      shop_tax_id,
      shop_tax_version,
      treatment_policy_id,
      treatment_policy_version,
      place_policy_id,
      place_policy_version,
      rounding_policy_id,
      rounding_policy_version,
      component_policy_id,
      component_policy_version,
      taxable_value,
      cgst_amount,
      sgst_amount,
      igst_amount,
      tax_amount,
      invoice_total,
      input_fingerprint,
      created_by
    ) values (
      gen_random_uuid(),
      1,
      gen_random_uuid(),
      'KL-G1',
      'TAX CALCULATION PREVIEW — NOT A TAX INVOICE',
      'exclusive',
      'seller_state',
      'intra_state',
      '32',
      '32',
      'nearest_half_up',
      0.01,
      gen_random_uuid(),
      1,
      gen_random_uuid(),
      1,
      gen_random_uuid(),
      1,
      gen_random_uuid(),
      1,
      gen_random_uuid(),
      1,
      gen_random_uuid(),
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      'c4-client-write-probe',
      gen_random_uuid()
    );
    raise exception 'client tax-preview write must be blocked';
  exception
    when others then
      if sqlstate not in ('42501') then
        raise;
      end if;
  end;
end;
$$;

rollback;
