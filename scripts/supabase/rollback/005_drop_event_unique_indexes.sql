-- Non-destructive rollback for migrations/005_review_event_idempotency.sql.
--
-- Precondition: drop apply_review first with 006_drop_apply_review_rpc.sql.
-- This removes uniqueness enforcement but deliberately retains both nullable
-- client_event_id columns and their values. Current clients then take their
-- documented rolling-deploy fallback without destroying the event ledger.

begin;

do $guard$
begin
  if to_regprocedure(
    'public.apply_review(bigint,text,smallint,timestamp with time zone,real,real,timestamp with time zone,smallint,boolean,integer,text,text)'
  ) is not null then
    raise exception 'drop apply_review before removing its idempotency index';
  end if;
end
$guard$;

drop index if exists public.review_log_card_client_event_uidx;
drop index if exists public.note_flags_card_client_event_uidx;

commit;
