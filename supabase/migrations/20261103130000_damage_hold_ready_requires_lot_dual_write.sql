-- DMG-03A cutover guard: refuse damage.stock_hold_ready=true unless lot
-- dual-write is already enabled. Null-lot storage holds cannot reduce
-- lot-scoped picking_available_cases; enabling isolation before dual-write
-- would leave allocatable stock unprotected in the lot path.
-- Does not flip any operational flags. Additive only.

create or replace function app_private.guard_damage_hold_configuration()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op in ('INSERT', 'UPDATE')
    and new.key = 'damage.stock_hold_ready'
    and new.value = 'true'::jsonb
  then
    if not app_private.damage_stock_isolation_installed() then
      raise exception 'damage stock isolation is not ready' using errcode = '23514';
    end if;

    -- Lot-aware picking subtracts holds by lot_id. Require dual-write so
    -- isolate_storage_damage demands lot_id and avail readers stay consistent.
    if not app_private.stock_lots_dual_write_enabled() then
      raise exception
        'damage stock isolation requires lot dual-write before readiness'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

comment on function app_private.guard_damage_hold_configuration() is
  'Blocks damage.stock_hold_ready=true until isolation is installed and stock.lots.dual_write_enabled is true.';
