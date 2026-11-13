-- Keyset pagination by notes.guid needs bytewise order across mixed-case GUIDs.
-- Use C collation to match the deployed pagination contract. Values, uniqueness
-- and equality lookups are unchanged; only ordering changes. Replay is harmless.
begin;

do $$
begin
  if exists (
    select 1 from pg_attribute a left join pg_collation c on c.oid = a.attcollation
    where a.attrelid = 'public.notes'::regclass and a.attname = 'guid' and c.collname is distinct from 'C'
  ) then
    alter table public.notes alter column guid type text collate "C";
  end if;
end
$$;

commit;
