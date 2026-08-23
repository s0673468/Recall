-- cards.suspended: desktop-owned dormancy mirrored into Recall.
--
-- Provenance: copied from the deployed private runtime migration
-- recall-anki-sync/migrations/002_cards_suspended.sql. The current deck_counts
-- body is preserved; idempotent column/index DDL and an explicit grant were
-- added for repository ownership.

begin;

alter table public.cards
  add column if not exists suspended boolean not null default false;

create index if not exists idx_cards_user_active
  on public.cards (user_id)
  where not suspended and not deleted;

create or replace function public.deck_counts()
returns table(deck_id bigint, due integer, new integer)
language sql
stable
security invoker
set search_path = ''
as $$
  select n.deck_id,
         count(*) filter (where c.state <> 0 and c.due <= now())::integer as due,
         count(*) filter (where c.state = 0)::integer as new
    from public.cards c
    join public.notes n on n.id = c.note_id
   where c.deleted = false
     and n.deleted = false
     and c.suspended = false
     and c.user_id = auth.uid()
   group by n.deck_id;
$$;

grant execute on function public.deck_counts() to authenticated;

commit;
