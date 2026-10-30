-- M8.2B.1 shop statement grants and read contract. Rolls back.
-- Does not post payments, issue tax invoices, or write stock.

begin;

do $$
declare
  admin_has boolean;
  accounts_has boolean;
  salesperson_has boolean;
  delivery_has boolean;
  store_has boolean;
  godown_has boolean;
  fn_src text;
begin
  select exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'admin'
      and permissions.code = 'shops.statement.read'
  ) into admin_has;

  select exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'accounts'
      and permissions.code = 'shops.statement.read'
  ) into accounts_has;

  select exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'salesperson'
      and permissions.code = 'shops.statement.read'
  ) into salesperson_has;

  select exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'delivery_person'
      and permissions.code = 'shops.statement.read'
  ) into delivery_has;

  select exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'store_keeper'
      and permissions.code = 'shops.statement.read'
  ) into store_has;

  select exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code = 'shops.statement.read'
  ) into godown_has;

  if not admin_has or not accounts_has then
    raise exception 'shops.statement.read must be granted to admin and accounts';
  end if;

  if salesperson_has or delivery_has or store_has or godown_has then
    raise exception 'shops.statement.read must not be granted to salesperson, delivery_person, store_keeper, or godown_manager';
  end if;

  if not exists (
    select 1
    from pg_proc
    join pg_namespace on pg_namespace.oid = pg_proc.pronamespace
    where pg_namespace.nspname = 'public'
      and pg_proc.proname = 'get_shop_sales_statement'
  ) then
    raise exception 'get_shop_sales_statement is missing';
  end if;

  -- Contract: payment fields stay JSON null / false in the function source.
  fn_src := pg_get_functiondef('public.get_shop_sales_statement(uuid, date, date, text)'::regprocedure);
  if position('amount_received_available' in fn_src) = 0
     or position('running_balance_available' in fn_src) = 0
     or fn_src like '%shop_payment%'
  then
    raise exception 'statement RPC must keep payment fields unavailable and must not read payment tables';
  end if;
end $$;

rollback;
