-- note_flags: one-tap "don't like" and "delete" reasons that hide a card.
--
-- Recall's review header flags a card as `dislike` (rewrite it) or `delete`
-- (remove it). While such a flag is open the card stays out of the queue; the
-- weekly Claude review resolves or dismisses it. This widens the reason set
-- and keeps deck_counts() consistent with the queue. It never touches rows.

begin;

alter table public.note_flags
  drop constraint if exists note_flags_reason_check;

alter table public.note_flags
  add constraint note_flags_reason_check
  check (reason in ('wrong', 'confusing', 'too_long', 'duplicate', 'dislike', 'delete'));

create index if not exists idx_note_flags_open_hidden
  on public.note_flags (user_id, card_id)
  where status = 'open' and reason in ('dislike', 'delete');

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
     and not exists (
       select 1
         from public.note_flags f
        where f.card_id = c.id
          and f.status = 'open'
          and f.reason in ('dislike', 'delete')
     )
   group by n.deck_id;
$$;

grant execute on function public.deck_counts() to authenticated;

commit;
