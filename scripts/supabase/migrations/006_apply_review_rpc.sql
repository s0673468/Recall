-- Transactional review replay for Recall.
--
-- Provenance: copied from Health's deployed
-- scripts/supabase_migrate_recall_review_rpc.sql. Recall's outbox is
-- at-least-once, so apply_review anchors the log append and scheduling merge on
-- client_event_id in one transaction.
--
-- Conflict policy, matching lib/features/review/data/review_replay.dart:
--   * scheduling is newest-review-wins on rating_at (strict >; ties keep the
--     first writer's schedule);
--   * reps/lapses always accumulate from server state.
--
-- SECURITY INVOKER is intentional: auth.uid() = user_id RLS on cards and
-- review_log remains authoritative. Never change this to SECURITY DEFINER.

begin;

do $guard$
begin
  if to_regclass('public.review_log_card_client_event_uidx') is null then
    raise exception
      'apply_review requires review_log_card_client_event_uidx; apply 005_review_event_idempotency.sql first';
  end if;
end
$guard$;

create or replace function public.apply_review(
  p_card_id bigint,
  p_guid text,
  p_rating smallint,
  p_rating_at timestamptz,
  p_stability real,
  p_difficulty real,
  p_due timestamptz,
  p_state smallint,
  p_lapsed boolean,
  p_elapsed_ms integer,
  p_device text,
  p_client_event_id text
) returns bigint
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_log_id bigint;
  v_reps integer;
  v_lapses integer;
  v_last timestamptz;
begin
  -- NULLs are distinct in a unique index, so NULL would defeat idempotency.
  if p_client_event_id is null then
    raise exception 'apply_review requires a client_event_id';
  end if;

  insert into public.review_log (
    card_id, guid, rating, rating_at, stability_after, difficulty_after,
    due_after, state_after, elapsed_ms, device, client_event_id
  )
  values (
    p_card_id, p_guid, p_rating, p_rating_at, p_stability, p_difficulty,
    p_due, p_state, p_elapsed_ms, p_device, p_client_event_id
  )
  on conflict (card_id, client_event_id) do nothing
  returning id into v_log_id;

  -- A committed log row implies a committed merge because both happen in this
  -- function transaction. Do not wrap the merge in a caught EXCEPTION block or
  -- insert client_event_id review rows through another path.
  if v_log_id is null then
    select id into v_log_id
      from public.review_log
     where card_id = p_card_id
       and client_event_id = p_client_event_id;
    return v_log_id;
  end if;

  -- Ownership is enforced by RLS on this SELECT and the surrounding writes.
  -- An explicit user_id=auth.uid() predicate would make service-role/SQL-editor
  -- repair calls silently skip the merge while retaining the log row.
  select reps, lapses, last_review
    into v_reps, v_lapses, v_last
    from public.cards
   where id = p_card_id
   for update;

  -- A card hard-deleted while queued retains its review history.
  if not found then
    return v_log_id;
  end if;

  if v_last is null or p_rating_at > v_last then
    update public.cards
       set reps = v_reps + 1,
           lapses = v_lapses + (case when p_lapsed then 1 else 0 end),
           cloud_seen = true,
           stability = p_stability,
           difficulty = p_difficulty,
           due = p_due,
           state = p_state,
           last_review = p_rating_at
     where id = p_card_id;
  else
    update public.cards
       set reps = v_reps + 1,
           lapses = v_lapses + (case when p_lapsed then 1 else 0 end),
           cloud_seen = true
     where id = p_card_id;
  end if;

  return v_log_id;
end;
$$;

grant execute on function public.apply_review(
  bigint, text, smallint, timestamptz, real, real, timestamptz, smallint,
  boolean, integer, text, text
) to authenticated;

commit;
