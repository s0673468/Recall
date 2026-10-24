-- Likes are standing style preferences. They never hide cards or affect
-- deck_counts(); 007's dislike/delete-only predicate remains unchanged.
begin;

alter table public.note_flags
  drop constraint if exists note_flags_reason_check;

alter table public.note_flags
  add constraint note_flags_reason_check
  check (reason in ('wrong', 'confusing', 'too_long', 'duplicate', 'dislike', 'delete', 'like'));

commit;
