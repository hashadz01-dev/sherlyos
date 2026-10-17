-- Phase 4.2F local SQL checks: stale-version raises PT409 (not 40001). Rolls back.
begin;

do $$
declare
  sigs text[] := array[
    'generate_delivery_note(uuid,integer,text)',
    'void_delivery_note(uuid,integer,text,text)',
    'send_delivery_note(uuid,integer,text)',
    'acknowledge_delivery_note(uuid,integer,text)',
    'cancel_order(uuid,integer,text,text)',
    'set_order(uuid,integer,uuid,uuid,text,text,text,jsonb,text)',
    'submit_order(uuid,integer,text)',
    'hold_order(uuid,integer,text,text)',
    'verify_order(uuid,integer,text)'
  ];
  sig text;
  def text;
begin
  foreach sig in array sigs
  loop
    def := pg_get_functiondef(('public.' || sig)::regprocedure);
    if def like '%errcode = ''40001''%' then
      raise exception '% still uses 40001', sig;
    end if;
    if def not like '%errcode = ''PT409''%' then
      raise exception '% missing PT409', sig;
    end if;
  end loop;
end $$;

select 'phase_4_2f_stale_version ok' as result;

rollback;
