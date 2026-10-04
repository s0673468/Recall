-- Roll back 007 without losing flags.
--
-- Run only after every open `dislike`/`delete` flag has been resolved or
-- dismissed; the narrower check is refused while such rows exist, so no flag
-- is ever deleted to make it fit. deck_counts() returns to the 002 body.

begin;

do $$
begin
  if exists (
    select 1 from public.note_flags where reason in ('dislike', 'delete')
  ) then
    raise exception 'dislike/delete flags exist; keep 007 or migrate them first';
  end if;
end
$$;

alter table public.note_flags
  drop constraint if exists note_flags_reason_check;

alter table public.note_flags
  add constraint note_flags_reason_check
  check (reason in ('wrong', 'confusing', 'too_long', 'duplicate'));

drop index if exists public.idx_note_flags_open_hidden;

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
