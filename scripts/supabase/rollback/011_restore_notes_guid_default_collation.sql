-- Restore the database default ordering without changing any note values.
-- Older clients that compare GUID order in Dart can fail again after rollback;
-- deploy the collation-independent progress check before restoring this order.
begin;

alter table public.notes alter column guid type text collate "default";

commit;
