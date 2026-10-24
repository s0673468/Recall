-- Refuse rollback while ANY like rows exist, including dismissed likes.
-- Keep their history; never delete preferences to fit a narrower constraint.
begin;

do $$
begin
  if exists (select 1 from public.note_flags where reason = 'like') then
    raise exception 'like flags exist; keep 010 or migrate them first';
  end if;
end
$$;

alter table public.note_flags
  drop constraint if exists note_flags_reason_check;

alter table public.note_flags
  add constraint note_flags_reason_check
  check (reason in ('wrong', 'confusing', 'too_long', 'duplicate', 'dislike', 'delete'));

commit;
