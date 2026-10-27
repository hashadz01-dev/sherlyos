-- Local disposable checks for Phase 3.1. The transaction rolls back.
-- Run with the local database only.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

create temp table refs (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated;
grant select, insert, update, delete on refs to authenticated;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('godown_b', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('keeper2', gen_random_uuid()),
  ('keeper_b', gen_random_uuid()),
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
  fixture.name || '.phase31@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

-- Repeatable on a shared local database that already has an administrator.
-- Does not delete the existing admin and does not change bootstrap authorization.
do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'),
      'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values ((select id from fixture where name = 'admin'), 'Phase 3.1 Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'godown' then 'godown_manager'
  when 'godown_b' then 'godown_manager'
  when 'accounts' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'delivery' then 'delivery_person'
  when 'keeper' then 'store_keeper'
  when 'keeper2' then 'store_keeper'
  when 'keeper_b' then 'store_keeper'
  when 'inactive' then 'store_keeper'
end
where fixture.name <> 'admin';

update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');

create or replace function public.phase31_claim(actor text)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (
      select json_build_object('sub', id, 'role', 'authenticated')::text
      from fixture
      where name = actor
    ),
    true
  );
end;
$$;

create or replace function public.phase31_line(
  product uuid,
  crate uuid,
  document_cases integer,
  counted_cases integer,
  damaged_cases integer
)
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'product_id', product,
    'destination_crate_id', crate,
    'document_cases', document_cases,
    'counted_cases', counted_cases,
    'damaged_cases', damaged_cases
  );
$$;

create or replace function public.phase31_balance(target_crate uuid, target_product uuid)
returns integer
language sql
security definer
set search_path = ''
as $$
  select coalesce((
    select quantity
    from public.stock_balances
    where crate_id = target_crate
      and product_id = target_product
  ), 0);
$$;

select public.phase31_claim('admin');
set local role authenticated;

insert into refs (name, id)
values
  ('branch_a', public.create_branch('phase31_a', 'Phase 31 A')),
  ('branch_b', public.create_branch('phase31_b', 'Phase 31 B'));

insert into refs (name, id)
values
  ('zone_a', public.create_zone((select id from refs where name = 'branch_a'), 'za', 'Zone A', null)),
  ('zone_a2', public.create_zone((select id from refs where name = 'branch_a'), 'za2', 'Zone A2', null)),
  ('zone_off', public.create_zone((select id from refs where name = 'branch_a'), 'zoff', 'Zone Off', null)),
  ('zone_b', public.create_zone((select id from refs where name = 'branch_b'), 'zb', 'Zone B', null));

insert into refs (name, id)
values
  ('crate_a1', public.create_crate((select id from refs where name = 'zone_a'), 'ca1', 'Crate A1', null)),
  ('crate_a2', public.create_crate((select id from refs where name = 'zone_a2'), 'ca2', 'Crate A2', null)),
  ('crate_off', public.create_crate((select id from refs where name = 'zone_off'), 'coff', 'Crate Off', null)),
  ('crate_dead', public.create_crate((select id from refs where name = 'zone_a'), 'cdead', 'Crate Dead', null)),
  ('crate_fail', public.create_crate((select id from refs where name = 'zone_a'), 'cfail', 'Crate Fail', null)),
  ('crate_b1', public.create_crate((select id from refs where name = 'zone_b'), 'cb1', 'Crate B1', null)),
  ('soap', public.create_product('p31-soap', 'Phase 31 Soap', null, null)),
  ('oil', public.create_product('p31-oil', 'Phase 31 Oil', null, null)),
  ('dead_product', public.create_product('p31-dead', 'Phase 31 Dead', null, null)),
  ('supplier', public.create_supplier('Phase 31 Supplier', null, null)),
  ('supplier_b', public.create_supplier('Phase 31 Supplier B', null, null)),
  ('dead_supplier', public.create_supplier('Phase 31 Dead Supplier', null, null));

select public.assign_user_branch((select id from fixture where name = 'godown'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'godown_b'), (select id from refs where name = 'branch_b'));
select public.assign_user_branch((select id from fixture where name = 'accounts'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'keeper'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'keeper2'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'keeper_b'), (select id from refs where name = 'branch_b'));
select public.assign_user_branch((select id from fixture where name = 'inactive'), (select id from refs where name = 'branch_a'));
select public.set_product_active((select id from refs where name = 'dead_product'), false);
select public.set_supplier_active((select id from refs where name = 'dead_supplier'), false);
select public.set_crate_active((select id from refs where name = 'crate_dead'), false);
select public.set_zone_active((select id from refs where name = 'zone_off'), false);

do $$
begin
  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'receiving.execute'
      and roles.code <> 'store_keeper'
  ) or exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'receiving.verify'
      and roles.code <> 'godown_manager'
  ) or exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code in ('receiving.execute', 'receiving.verify')
      and roles.code = 'admin'
  ) then
    raise exception 'receiving grants changed';
  end if;
end;
$$;

select public.phase31_claim('keeper');

insert into refs (name, id)
select 'main', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier'),
  '  INV   15 ',
  current_date,
  'morning delivery',
  jsonb_build_array(public.phase31_line(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_a1'),
    8, 6, 1
  ))
) ->> 'id')::uuid;

do $$
declare
  accepted integer;
  normalized text;
begin
  select stock_receipt_lines.accepted_cases
  into accepted
  from public.stock_receipt_lines
  where receipt_id = (select id from refs where name = 'main');
  if accepted <> 5 then
    raise exception 'accepted quantity was not counted minus damaged';
  end if;

  select normalized_document_reference
  into normalized
  from public.stock_receipts
  where id = (select id from refs where name = 'main');
  if normalized <> 'inv 15' then
    raise exception 'document reference was not normalized';
  end if;

  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> 0 then
    raise exception 'an unverified receipt changed stock';
  end if;
end;
$$;

select public.update_stock_receipt(
  (select id from refs where name = 'main'),
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier'),
  'INV 15',
  current_date,
  'corrected count',
  jsonb_build_array(
    jsonb_build_object(
      'product_id', (select id from refs where name = 'soap'),
      'destination_crate_id', (select id from refs where name = 'crate_a1'),
      'document_cases', 9,
      'counted_cases', 7,
      'damaged_cases', 2,
      'accepted_cases', 99
    ),
    public.phase31_line(
      (select id from refs where name = 'oil'),
      (select id from refs where name = 'crate_a2'),
      4, 4, 0
    )
  )
);

do $$
declare
  soap_accepted integer;
  line_count integer;
begin
  select accepted_cases
  into soap_accepted
  from public.stock_receipt_lines
  where receipt_id = (select id from refs where name = 'main')
    and product_id = (select id from refs where name = 'soap');
  select count(*)
  into line_count
  from public.stock_receipt_lines
  where receipt_id = (select id from refs where name = 'main');
  if soap_accepted <> 5 or line_count <> 2 then
    raise exception 'multiple products and crates were not saved, or accepted cases were trusted from the client';
  end if;
end;
$$;

select public.phase31_claim('keeper2');

insert into refs (name, id)
select 'keeper2_draft', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier'),
  'KEEPER2-DOC',
  current_date,
  null,
  jsonb_build_array(public.phase31_line(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_a1'),
    1, 1, 0
  ))
) ->> 'id')::uuid;

select public.phase31_claim('keeper');

do $$
begin
  perform public.update_stock_receipt(
    (select id from refs where name = 'keeper2_draft'),
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'KEEPER2-DOC',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      2, 2, 0
    ))
  );
  raise exception 'store keeper edited another keeper draft';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.cancel_stock_receipt((select id from refs where name = 'keeper2_draft'), 'not mine');
  raise exception 'store keeper cancelled another keeper draft';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.get_stock_receipt((select id from refs where name = 'keeper2_draft'));
  raise exception 'guessed receipt was visible';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  if exists (
    select 1
    from jsonb_array_elements(public.list_stock_receipts()) as item
    where item ->> 'id' = (select id::text from refs where name = 'keeper2_draft')
  ) then
    raise exception 'store keeper listed another keeper receipt';
  end if;
end;
$$;

select public.submit_stock_receipt((select id from refs where name = 'main'));

do $$
begin
  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> 0 then
    raise exception 'submission posted stock';
  end if;
  perform public.verify_stock_receipt((select id from refs where name = 'main'), 'keeper-verify-key');
  raise exception 'store keeper verified a receipt';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

insert into refs (name, id)
select 'own_cancel', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier'),
  'CANCEL-ME',
  current_date,
  null,
  jsonb_build_array(public.phase31_line(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_a1'),
    1, 1, 0
  ))
) ->> 'id')::uuid;

select public.cancel_stock_receipt((select id from refs where name = 'own_cancel'), 'wrong delivery');

do $$
begin
  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> 0 then
    raise exception 'cancelled receipt changed stock';
  end if;
  perform public.submit_stock_receipt((select id from refs where name = 'own_cancel'));
  raise exception 'cancelled receipt was reopened';
exception
  when insufficient_privilege then
    if sqlerrm <> 'receipt cannot be submitted' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'cancel-me',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'cancelled document reference was reused';
exception
  when unique_violation then
    if sqlerrm <> 'document reference was already used' then
      raise;
    end if;
end;
$$;

insert into refs (name, id)
select 'other_supplier', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier_b'),
  'CANCEL-ME',
  current_date,
  null,
  jsonb_build_array(public.phase31_line(
    (select id from refs where name = 'oil'),
    (select id from refs where name = 'crate_a2'),
    1, 1, 0
  ))
) ->> 'id')::uuid;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    null,
    'NO-SUPPLIER',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'missing supplier was accepted';
exception
  when others then
    if sqlerrm not in ('supplier is inactive or missing', 'not authorized') then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    '   ',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'blank document reference was accepted';
exception
  when check_violation then
    if sqlerrm <> 'document reference is invalid' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'INV 15',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'oil'),
      (select id from refs where name = 'crate_a2'),
      1, 1, 0
    ))
  );
  raise exception 'duplicate document reference was accepted';
exception
  when unique_violation then
    if sqlerrm <> 'document reference was already used' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_b'),
    (select id from refs where name = 'supplier'),
    'OTHER-GODOWN',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_b1'),
      1, 1, 0
    ))
  );
  raise exception 'unauthorized godown was accepted';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'NEG',
    current_date,
    null,
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from refs where name = 'soap'),
      'destination_crate_id', (select id from refs where name = 'crate_a1'),
      'document_cases', -1,
      'counted_cases', 1,
      'damaged_cases', 0
    ))
  );
  raise exception 'negative quantity was accepted';
exception
  when check_violation then
    if sqlerrm <> 'quantity must be a whole number of carton cases' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'DECIMAL',
    current_date,
    null,
    '[{"product_id":"00000000-0000-0000-0000-000000000000","destination_crate_id":"00000000-0000-0000-0000-000000000000","document_cases":1.5,"counted_cases":1,"damaged_cases":0}]'::jsonb
  );
  raise exception 'decimal quantity was accepted';
exception
  when check_violation then
    if sqlerrm <> 'quantity must be a whole number of carton cases' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'DAMAGE',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      3, 2, 3
    ))
  );
  raise exception 'damaged cases above the count were accepted';
exception
  when check_violation then
    if sqlerrm <> 'damaged cases cannot exceed counted cases' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'CROSS',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_b1'),
      1, 1, 0
    ))
  );
  raise exception 'cross-godown allocation was accepted';
exception
  when insufficient_privilege or check_violation then
    if sqlerrm not in ('not authorized', 'destination crate is outside this godown', 'crates must belong to the same godown') then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'dead_supplier'),
    'DEAD-SUP',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'inactive supplier was accepted';
exception
  when check_violation then
    if sqlerrm <> 'supplier is inactive or missing' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'DEAD-PROD',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'dead_product'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'inactive product was accepted';
exception
  when check_violation then
    if sqlerrm <> 'product is inactive or missing' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'DEAD-CRATE',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_dead'),
      1, 1, 0
    ))
  );
  raise exception 'inactive crate was accepted';
exception
  when check_violation then
    if sqlerrm <> 'location is inactive' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'DEAD-ZONE',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_off'),
      1, 1, 0
    ))
  );
  raise exception 'inactive zone was accepted';
exception
  when check_violation then
    if sqlerrm <> 'location is inactive' then
      raise;
    end if;
end;
$$;

select public.phase31_claim('keeper_b');

insert into refs (name, id)
select 'branch_b_receipt', (public.create_stock_receipt(
  (select id from refs where name = 'branch_b'),
  (select id from refs where name = 'supplier'),
  'GODOWN-B',
  current_date,
  null,
  jsonb_build_array(public.phase31_line(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_b1'),
    2, 2, 0
  ))
) ->> 'id')::uuid;

select public.submit_stock_receipt((select id from refs where name = 'branch_b_receipt'));

select public.phase31_claim('godown');

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'MANAGER-CREATE',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'godown manager created a receipt';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.verify_stock_receipt((select id from refs where name = 'branch_b_receipt'), 'wrong-godown-key');
  raise exception 'godown manager verified another godown';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

select public.phase31_claim('keeper');

insert into refs (name, id)
select 'hold_me', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier'),
  'HOLD-ME',
  current_date,
  null,
  jsonb_build_array(public.phase31_line(
    (select id from refs where name = 'oil'),
    (select id from refs where name = 'crate_a2'),
    3, 3, 0
  ))
) ->> 'id')::uuid;

select public.submit_stock_receipt((select id from refs where name = 'hold_me'));
select public.phase31_claim('godown');
select public.hold_stock_receipt((select id from refs where name = 'hold_me'), 'count does not match the document');

do $$
begin
  if public.phase31_balance(
    (select id from refs where name = 'crate_a2'),
    (select id from refs where name = 'oil')
  ) <> 0 then
    raise exception 'held receipt changed stock';
  end if;
  perform public.verify_stock_receipt((select id from refs where name = 'hold_me'), 'held-verify-key');
  raise exception 'held receipt was posted';
exception
  when insufficient_privilege then
    if sqlerrm <> 'receipt cannot be verified' then
      raise;
    end if;
end;
$$;

insert into refs (name, id)
select 'manager_cancel', (
  select id from refs where name = 'other_supplier'
);

select public.cancel_stock_receipt((select id from refs where name = 'manager_cancel'), 'supplier sent the goods back');

do $$
declare
  posted jsonb;
  balance integer;
  txn_count integer;
begin
  posted := public.verify_stock_receipt((select id from refs where name = 'main'), 'verify-main-key');
  if posted ->> 'status' <> 'posted' then
    raise exception 'verified receipt was not posted';
  end if;
  if jsonb_array_length(posted -> 'transactions') <> 2 then
    raise exception 'verified receipt did not post every accepted line';
  end if;
  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> 5 then
    raise exception 'verified receipt did not post only accepted cases';
  end if;
  if public.phase31_balance(
    (select id from refs where name = 'crate_a2'),
    (select id from refs where name = 'oil')
  ) <> 4 then
    raise exception 'second receipt line was not posted';
  end if;

  balance := public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  );
  perform public.verify_stock_receipt((select id from refs where name = 'main'), 'verify-main-key');
  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> balance then
    raise exception 'duplicate verification posted stock again';
  end if;

  begin
    perform public.verify_stock_receipt((select id from refs where name = 'main'), 'verify-other-key');
    raise exception 'conflicting idempotency key was accepted';
  exception
    when unique_violation then
      if sqlerrm <> 'idempotency key was already used for a different request' then
        raise;
      end if;
  end;

  select count(*)
  into txn_count
  from public.stock_transactions
  where receipt_id = (select id from refs where name = 'main');
  if txn_count <> 2 then
    raise exception 'receipt transactions were duplicated';
  end if;
end;
$$;

do $$
begin
  perform public.phase31_claim('keeper');
  perform public.update_stock_receipt(
    (select id from refs where name = 'main'),
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'INV 15',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'posted receipt was edited';
exception
  when insufficient_privilege then
    if sqlerrm <> 'receipt cannot be edited' and sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  perform public.cancel_stock_receipt((select id from refs where name = 'main'), 'undo');
  raise exception 'posted receipt was cancelled';
exception
  when insufficient_privilege then
    if sqlerrm <> 'receipt cannot be cancelled' then
      raise;
    end if;
end;
$$;

select public.phase31_claim('keeper');

insert into refs (name, id)
select 'zero_line', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier'),
  'ZERO-LINE',
  current_date,
  null,
  jsonb_build_array(
    public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      2, 2, 2
    ),
    public.phase31_line(
      (select id from refs where name = 'oil'),
      (select id from refs where name = 'crate_a2'),
      3, 3, 1
    )
  )
) ->> 'id')::uuid;

select public.submit_stock_receipt((select id from refs where name = 'zero_line'));
select public.phase31_claim('godown');

do $$
declare
  posted jsonb;
  before_soap integer;
begin
  before_soap := public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  );
  posted := public.verify_stock_receipt((select id from refs where name = 'zero_line'), 'verify-zero-line');
  if jsonb_array_length(posted -> 'transactions') <> 1 then
    raise exception 'zero-accepted line created a ledger movement';
  end if;
  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> before_soap then
    raise exception 'damaged-only line increased stock';
  end if;
  if public.phase31_balance(
    (select id from refs where name = 'crate_a2'),
    (select id from refs where name = 'oil')
  ) <> 6 then
    raise exception 'accepted cases on a mixed receipt were not added to existing stock';
  end if;
end;
$$;

select public.phase31_claim('keeper');

insert into refs (name, id)
select 'all_zero', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier_b'),
  'ALL-ZERO',
  current_date,
  null,
  jsonb_build_array(public.phase31_line(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_a1'),
    5, 4, 4
  ))
) ->> 'id')::uuid;

select public.submit_stock_receipt((select id from refs where name = 'all_zero'));
select public.phase31_claim('godown');

do $$
declare
  posted jsonb;
  before_balance integer;
begin
  before_balance := public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  );
  posted := public.verify_stock_receipt((select id from refs where name = 'all_zero'), 'verify-all-zero');
  if posted ->> 'status' <> 'posted' or jsonb_array_length(posted -> 'transactions') <> 0 then
    raise exception 'zero-accepted receipt did not keep history without a stock movement';
  end if;
  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> before_balance then
    raise exception 'zero-accepted receipt changed stock';
  end if;
end;
$$;

select public.phase31_claim('keeper');

insert into refs (name, id)
select 'fail_post', (public.create_stock_receipt(
  (select id from refs where name = 'branch_a'),
  (select id from refs where name = 'supplier_b'),
  'FAIL-POST',
  current_date,
  null,
  jsonb_build_array(
    public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ),
    public.phase31_line(
      (select id from refs where name = 'oil'),
      (select id from refs where name = 'crate_fail'),
      1, 1, 0
    )
  )
) ->> 'id')::uuid;

select public.submit_stock_receipt((select id from refs where name = 'fail_post'));
select public.phase31_claim('admin');
select public.set_crate_active((select id from refs where name = 'crate_fail'), false);
select public.phase31_claim('godown');

do $$
declare
  before_count integer;
begin
  select count(*) into before_count from public.stock_transactions;
  begin
    perform public.verify_stock_receipt((select id from refs where name = 'fail_post'), 'verify-fail-key');
    raise exception 'inactive destination was posted';
  exception
    when check_violation then
      if sqlerrm <> 'location is inactive' then
        raise;
      end if;
  end;
  if (select count(*) from public.stock_transactions) <> before_count then
    raise exception 'failed verification left a stock transaction';
  end if;
  if (select status from public.stock_receipts where id = (select id from refs where name = 'fail_post')) <> 'submitted' then
    raise exception 'failed verification changed the receipt status';
  end if;
end;
$$;

select public.phase31_claim('accounts');

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'ACCOUNTS',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'accounts created a receipt';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.verify_stock_receipt((select id from refs where name = 'fail_post'), 'accounts-verify');
  raise exception 'accounts verified a receipt';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase31_claim('salesperson');

do $$
begin
  perform public.list_stock_receipts();
  raise exception 'salesperson listed receipts';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.verify_stock_receipt((select id from refs where name = 'fail_post'), 'sales-verify');
  raise exception 'salesperson verified a receipt';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase31_claim('delivery');

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'DELIVERY',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'delivery person created a receipt';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.verify_stock_receipt((select id from refs where name = 'fail_post'), 'delivery-verify');
  raise exception 'delivery person verified a receipt';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase31_claim('inactive');

do $$
begin
  perform public.create_stock_receipt(
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'INACTIVE',
    current_date,
    null,
    jsonb_build_array(public.phase31_line(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1, 1, 0
    ))
  );
  raise exception 'inactive user created a receipt';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.get_stock_receipt((select id from refs where name = 'main'));
  raise exception 'inactive user read a receipt';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.phase31_claim('admin');

do $$
declare
  visible integer;
begin
  select count(*)
  into visible
  from jsonb_array_elements(public.list_stock_receipts()) as item
  where item ->> 'id' = (select id::text from refs where name = 'main');
  if visible <> 1 then
    raise exception 'admin monitor could not see a receipt';
  end if;
  perform public.verify_stock_receipt((select id from refs where name = 'fail_post'), 'admin-verify-key');
  raise exception 'admin verified a receipt';
exception
  when insufficient_privilege then
    if sqlerrm <> 'not authorized' then
      raise;
    end if;
end;
$$;

do $$
begin
  insert into public.stock_receipts (
    receipt_number, godown_id, supplier_id, document_reference,
    normalized_document_reference, received_date, created_by
  )
  values (
    'RC-DIRECT',
    (select id from refs where name = 'branch_a'),
    (select id from refs where name = 'supplier'),
    'DIRECT',
    'direct',
    current_date,
    (select id from fixture where name = 'admin')
  );
  raise exception 'direct receipt insert was allowed';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at
  )
  values (
    gen_random_uuid(),
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_a1'),
    1,
    (select id from fixture where name = 'admin'),
    now()
  );
  raise exception 'direct ledger insert was allowed';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  insert into public.stock_balances (crate_id, product_id, quantity)
  values (
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap'),
    1
  );
  raise exception 'direct balance insert was allowed';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from public.audit_logs
    where entity_table = 'stock_receipts'
      and entity_id = (select id from refs where name = 'main')
      and action = 'verify_stock_receipt'
  ) then
    raise exception 'verification was not audited';
  end if;
end;
$$;

select public.post_opening_stock(
  (select id from refs where name = 'soap'),
  (select id from refs where name = 'crate_a2'),
  6,
  'phase31-opening',
  null
);

select public.post_crate_transfer(
  (select id from refs where name = 'soap'),
  (select id from refs where name = 'crate_a1'),
  (select id from refs where name = 'crate_a2'),
  2,
  'phase31-transfer',
  null
);

do $$
declare
  mismatches integer;
  negatives integer;
  unlinked integer;
begin
  if public.phase31_balance(
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'soap')
  ) <> 3 then
    raise exception 'opening stock or transfer changed a receipt balance incorrectly';
  end if;

  -- Scope reconciliation to this file's crates/products. The shared local
  -- database may contain replica-seeded disposable balances from later suites.
  select count(*)
  into mismatches
  from public.stock_balances
  where (
      stock_balances.crate_id in (select id from refs)
      or stock_balances.product_id in (select id from refs)
    )
    and quantity <> (
    select coalesce(sum(stock_ledger.quantity), 0)
    from public.stock_ledger
    where stock_ledger.crate_id = stock_balances.crate_id
      and stock_ledger.product_id = stock_balances.product_id
  );
  if mismatches <> 0 then
    raise exception 'ledger reconciliation found mismatches';
  end if;

  select count(*) into negatives
  from public.stock_balances
  where (
      stock_balances.crate_id in (select id from refs)
      or stock_balances.product_id in (select id from refs)
    )
    and quantity < 0;
  if negatives <> 0 then
    raise exception 'negative stock exists';
  end if;

  select count(*)
  into unlinked
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.transaction_type = 'RECEIPT'
    and (
      stock_transactions.receipt_id is null
      or stock_transactions.receipt_line_id is null
    );
  if unlinked <> 0 then
    raise exception 'a receipt ledger entry has no receipt reference';
  end if;

  if exists (
    select 1
    from public.stock_ledger
    where quantity = 0
  ) then
    raise exception 'a zero-quantity ledger entry exists';
  end if;
end;
$$;

reset role;

drop function public.phase31_balance(uuid, uuid);
drop function public.phase31_line(uuid, uuid, integer, integer, integer);
drop function public.phase31_claim(text);

rollback;
