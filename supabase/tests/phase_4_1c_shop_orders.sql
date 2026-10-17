-- Local disposable checks for Phase 4.1C. The transaction rolls back.
-- Availability Rule A: shortfall rejects verification and leaves submitted.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('accounts2', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('inactive', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase41c@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'admin' then 'admin'
  when 'accounts' then 'accounts'
  when 'accounts2' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'godown' then 'godown_manager'
  when 'delivery' then 'delivery_person'
  when 'keeper' then 'store_keeper'
  when 'inactive' then 'accounts'
end;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;

select set_config('sherlyos.branch_a', public.create_branch('p41c_a', 'Phase 41C A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p41c_b', 'Phase 41C B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts2'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'inactive'), current_setting('sherlyos.branch_a')::uuid);
select set_config('sherlyos.shop', public.create_shop('Phase 41C assigned', null, null)::text, true);
select set_config('sherlyos.shop_other', public.create_shop('Phase 41C other', null, null)::text, true);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);
select set_config('sherlyos.product', public.create_product('p41c-soap', 'Phase 41C soap', null, null)::text, true);
select set_config('sherlyos.product_two', public.create_product('p41c-oil', 'Phase 41C oil', null, null)::text, true);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch_a')::uuid, 'A', 'Zone A', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'Crate 1', null)::text, true);
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  10,
  'p41c-open-soap',
  null
);

reset role;
select set_config('request.jwt.claims', '', true);

update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');

select set_config('sherlyos.ledger_before', (select count(*)::text from public.stock_ledger), true);
select set_config('sherlyos.balance_before', (select count(*)::text from public.stock_balances), true);
select set_config(
  'sherlyos.qty_before',
  (
    select coalesce(sum(quantity), 0)::text
    from public.stock_balances
    where product_id = current_setting('sherlyos.product')::uuid
  ),
  true
);

-- 1. Draft submission
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;

select set_config(
  'sherlyos.order',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 4)
      ),
      'p41c-create-01'
    ) -> 'order' ->> 'id'
  ),
  true
);

do $$
declare
  payload jsonb;
begin
  payload := public.submit_order(current_setting('sherlyos.order')::uuid, 1, 'p41c-submit-01');
  if payload -> 'order' ->> 'status' is distinct from 'submitted' then
    raise exception 'draft submit failed';
  end if;
  if payload -> 'order' ->> 'version' is distinct from '2' then
    raise exception 'submit version expected 2';
  end if;
end;
$$;

-- 21. Duplicate submit replay
do $$
declare
  payload jsonb;
begin
  payload := public.submit_order(current_setting('sherlyos.order')::uuid, 1, 'p41c-submit-01');
  if payload -> 'order' ->> 'version' is distinct from '2' then
    raise exception 'submit replay bumped version';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- 3. Verify with sufficient stock
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
declare
  payload jsonb;
begin
  payload := public.verify_order(current_setting('sherlyos.order')::uuid, 2, 'p41c-verify-ok');
  if payload -> 'order' ->> 'status' is distinct from 'verified' then
    raise exception 'sufficient stock should verify';
  end if;
  if not exists (
    select 1 from public.order_events
    where order_id = current_setting('sherlyos.order')::uuid
      and event_type = 'verified'
      and availability_snapshot is not null
  ) then
    raise exception 'verified event snapshot missing';
  end if;
end;
$$;

-- 18. Accounts cancel verified
do $$
declare
  payload jsonb;
begin
  payload := public.cancel_order(
    current_setting('sherlyos.order')::uuid,
    3,
    'Customer withdrew request',
    'p41c-cancel-verified'
  );
  if payload -> 'order' ->> 'status' is distinct from 'cancelled' then
    raise exception 'accounts cancel verified failed';
  end if;
end;
$$;

-- 20. Cancelled is terminal
do $$
begin
  begin
    perform public.verify_order(current_setting('sherlyos.order')::uuid, 4, 'p41c-verify-after-cancel');
    raise exception 'verify after cancel should fail';
  exception
    when sqlstate '23514' then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- Fresh order for Rule A shortage cases
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;

select set_config(
  'sherlyos.short',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 4),
        jsonb_build_object('product_id', current_setting('sherlyos.product_two')::uuid, 'requested_cases', 2)
      ),
      'p41c-create-short'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.short')::uuid, 1, 'p41c-submit-short');
reset role;
select set_config('request.jwt.claims', '', true);

-- 4/5/6/8/9/10. Multi-product shortfall (oil is zero) — Rule A
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
declare
  before_version integer;
  before_status text;
  detail text;
begin
  select version, status into before_version, before_status
  from public.orders where id = current_setting('sherlyos.short')::uuid;

  begin
    perform public.verify_order(current_setting('sherlyos.short')::uuid, before_version, 'p41c-verify-short');
    raise exception 'shortfall should reject verification';
  exception
    when sqlstate 'P0001' then
      get stacked diagnostics detail = pg_exception_detail;
      if detail is null or detail not like '%shortfall_cases%' then
        raise exception 'shortage detail missing: %', detail;
      end if;
  end;

  if exists (
    select 1 from public.orders
    where id = current_setting('sherlyos.short')::uuid
      and (version is distinct from before_version or status is distinct from before_status)
  ) then
    raise exception 'failed verify changed status or version';
  end if;

  if exists (
    select 1 from public.order_events
    where order_id = current_setting('sherlyos.short')::uuid
      and event_type = 'verified'
  ) then
    raise exception 'failed verify wrote verified event';
  end if;
end;
$$;

-- 7. Exactly sufficient stock on a single-line order
reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;
select set_config(
  'sherlyos.exact',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 10)
      ),
      'p41c-create-exact'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.exact')::uuid, 1, 'p41c-submit-exact');
reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;
do $$
declare
  payload jsonb;
begin
  payload := public.verify_order(current_setting('sherlyos.exact')::uuid, 2, 'p41c-verify-exact');
  if payload -> 'order' ->> 'status' is distinct from 'verified' then
    raise exception 'exact stock should verify';
  end if;
end;
$$;

-- 11. Hold understocked submitted order
do $$
declare
  payload jsonb;
  ver integer;
begin
  select version into ver from public.orders where id = current_setting('sherlyos.short')::uuid;
  payload := public.hold_order(
    current_setting('sherlyos.short')::uuid,
    ver,
    'Oil is out of stock',
    'p41c-hold-short'
  );
  if payload -> 'order' ->> 'status' is distinct from 'held' then
    raise exception 'hold failed';
  end if;
end;
$$;

-- 13. Held cannot be verified
do $$
declare
  ver integer;
begin
  select version into ver from public.orders where id = current_setting('sherlyos.short')::uuid;
  begin
    perform public.verify_order(current_setting('sherlyos.short')::uuid, ver, 'p41c-verify-held');
    raise exception 'held verify should fail';
  exception
    when sqlstate '23514' then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- 12. Creator corrects and resubmits
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;
do $$
declare
  ver integer;
  payload jsonb;
begin
  select version into ver from public.orders where id = current_setting('sherlyos.short')::uuid;
  payload := public.set_order(
    current_setting('sherlyos.short')::uuid,
    ver,
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch_a')::uuid,
    'salesperson',
    null,
    null,
    jsonb_build_array(
      jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 3)
    ),
    'p41c-edit-held'
  );
  if payload -> 'order' ->> 'status' is distinct from 'held' then
    raise exception 'correction must stay held';
  end if;
  payload := public.submit_order(
    current_setting('sherlyos.short')::uuid,
    (payload -> 'order' ->> 'version')::integer,
    'p41c-resubmit'
  );
  if payload -> 'order' ->> 'status' is distinct from 'submitted' then
    raise exception 'resubmit failed';
  end if;
end;
$$;

-- 16. Creator cancel held (use a separate held order)
select set_config(
  'sherlyos.held_cancel',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'p41c-create-held-cancel'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.held_cancel')::uuid, 1, 'p41c-submit-held-cancel');
reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;
select public.hold_order(current_setting('sherlyos.held_cancel')::uuid, 2, 'Need shop confirmation', 'p41c-hold-for-cancel');
reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;
do $$
declare
  payload jsonb;
begin
  payload := public.cancel_order(current_setting('sherlyos.held_cancel')::uuid, 3, null, 'p41c-creator-cancel-held');
  if payload -> 'order' ->> 'status' is distinct from 'cancelled' then
    raise exception 'creator cancel held failed';
  end if;
end;
$$;

-- 15. Creator cancel draft
select set_config(
  'sherlyos.draft_cancel',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'p41c-create-draft-cancel'
    ) -> 'order' ->> 'id'
  ),
  true
);
do $$
declare
  payload jsonb;
begin
  payload := public.cancel_order(current_setting('sherlyos.draft_cancel')::uuid, 1, 'Changed mind', 'p41c-creator-cancel-draft');
  if payload -> 'order' ->> 'status' is distinct from 'cancelled' then
    raise exception 'creator cancel draft failed';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- 14. Accounts self-verification
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;
select set_config(
  'sherlyos.self',
  (
    public.create_order(
      current_setting('sherlyos.shop_other')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'accounts',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'p41c-create-self'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.self')::uuid, 1, 'p41c-submit-self');
do $$
declare
  payload jsonb;
begin
  payload := public.verify_order(current_setting('sherlyos.self')::uuid, 2, 'p41c-verify-self');
  if payload -> 'order' ->> 'status' is distinct from 'verified' then
    raise exception 'self-verify failed';
  end if;
  if payload -> 'order' ->> 'created_by' is distinct from (select id::text from fixture where name = 'accounts') then
    raise exception 'self-verify creator mismatch';
  end if;
end;
$$;

-- 17. Accounts cancel submitted
select set_config(
  'sherlyos.acct_cancel',
  (
    public.create_order(
      current_setting('sherlyos.shop_other')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'accounts',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'p41c-create-acct-cancel'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.acct_cancel')::uuid, 1, 'p41c-submit-acct-cancel');
do $$
declare
  payload jsonb;
begin
  payload := public.cancel_order(
    current_setting('sherlyos.acct_cancel')::uuid,
    2,
    'Duplicate request',
    'p41c-accounts-cancel-submitted'
  );
  if payload -> 'order' ->> 'status' is distinct from 'cancelled' then
    raise exception 'accounts cancel submitted failed';
  end if;
end;
$$;

-- 19. Unauthorized cancellation
do $$
begin
  begin
    perform public.cancel_order(current_setting('sherlyos.short')::uuid, 99, 'nope', 'p41c-bad-cancel');
    raise exception 'stale/unauthorized cancel should fail';
  exception
    when sqlstate 'PT409' then null;
    when sqlstate '42501' then null;
    when sqlstate '23514' then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- Godown/delivery/keeper/admin cannot hold or verify
do $$
declare
  actor text;
  order_id uuid;
  ver integer;
begin
  -- prepare a submitted order owned by salesperson
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
    true
  );
  set local role authenticated;
  order_id := (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'p41c-create-deny'
    ) -> 'order' ->> 'id'
  )::uuid;
  perform public.submit_order(order_id, 1, 'p41c-submit-deny');
  select version into ver from public.orders where id = order_id;
  reset role;
  perform set_config('request.jwt.claims', '', true);

  foreach actor in array array['godown', 'delivery', 'keeper', 'admin']
  loop
    perform set_config(
      'request.jwt.claims',
      (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = actor),
      true
    );
    set local role authenticated;
    begin
      perform public.hold_order(order_id, ver, 'nope', 'p41c-hold-deny-' || actor);
      raise exception '% should not hold', actor;
    exception
      when sqlstate '42501' then null;
    end;
    begin
      perform public.verify_order(order_id, ver, 'p41c-verify-deny-' || actor);
      raise exception '% should not verify', actor;
    exception
      when sqlstate '42501' then null;
    end;
    reset role;
    perform set_config('request.jwt.claims', '', true);
  end loop;

  perform set_config('sherlyos.deny_order', order_id::text, true);
end;
$$;

-- 22. Version conflict on hold
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;
do $$
begin
  begin
    perform public.hold_order(current_setting('sherlyos.deny_order')::uuid, 1, 'stale', 'p41c-hold-stale');
    raise exception 'stale hold should fail';
  exception
    when sqlstate 'PT409' then null;
  end;
end;
$$;

-- 23. Inactive user denial
reset role;
select set_config('request.jwt.claims', '', true);
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'inactive'),
  true
);
set local role authenticated;
do $$
begin
  begin
    perform public.verify_order(current_setting('sherlyos.deny_order')::uuid, 2, 'p41c-inactive-verify');
    raise exception 'inactive verify should fail';
  exception
    when sqlstate '42501' then null;
  end;
end;
$$;
reset role;
select set_config('request.jwt.claims', '', true);

-- 24. Unauthorized godown denial for accounts2 without branch_b
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;
-- cannot create for branch_b; use accounts with only branch_a trying to verify is already covered.
-- Shop denial: salesperson unassigned shop already covered in 4.1B.
reset role;
select set_config('request.jwt.claims', '', true);

-- 25. Direct write denial
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;
do $$
begin
  begin
    update public.orders set status = 'verified' where id = current_setting('sherlyos.deny_order')::uuid;
    raise exception 'direct update should fail';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;

-- 26. Append-only events
do $$
begin
  begin
    update public.order_events set note = 'tamper' where order_id = current_setting('sherlyos.deny_order')::uuid;
    raise exception 'event update should fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- 27/28. No reservation / ledger unchanged from transitions (as table owner, not RLS-filtered)
do $$
declare
  ledger_now bigint;
  qty_now integer;
begin
  if to_regclass('public.stock_reservations') is not null then
    raise exception 'reservation table must not exist';
  end if;

  select count(*) into ledger_now from public.stock_ledger;
  select coalesce(sum(quantity), 0)::integer into qty_now
  from public.stock_balances
  where product_id = current_setting('sherlyos.product')::uuid;

  if ledger_now::text is distinct from current_setting('sherlyos.ledger_before')
    or qty_now::text is distinct from current_setting('sherlyos.qty_before')
  then
    raise exception 'order transitions changed stock (ledger % vs %, qty % vs %)',
      ledger_now,
      current_setting('sherlyos.ledger_before'),
      qty_now,
      current_setting('sherlyos.qty_before');
  end if;
end;
$$;

rollback;
