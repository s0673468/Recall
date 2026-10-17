-- apply_review: acknowledge a review whose card was hard-deleted while queued.
--
-- 006 inserted the review_log row before reading the card. review_log.card_id
-- references cards(id), so once a card is hard-deleted every retry of its
-- queued review raised 23503 (foreign_key_violation) and its "not found"
-- branch never ran. Recall's outbox delivers oldest-first and stops at the
-- first failure, so one such review held every later review on the device.
--
-- This replaces only the function body. The card row is now read (and locked)
-- before the log insert:
--   * card visible: identical to 006 (idempotent log append, then the merge);
--   * card not visible and absent: return 0 without a log row. 0 is never a
--     review_log id; every shipped client treats any integer as an
--     acknowledgement and drains the event, and a replay returns 0 again;
--   * card not visible but present (hidden by RLS): identical to 006. The log
--     insert's own RLS check and FK decide, exactly as before.
--
-- Signature, SECURITY INVOKER, search_path, the client_event_id requirement,
-- the (card_id, client_event_id) idempotency anchor, the newest-review-wins
-- merge and the execute grant are unchanged. Never change this to SECURITY
-- DEFINER: auth.uid() = user_id RLS on cards and review_log stays authoritative.

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
  v_card_found boolean;
  v_constraint text;
begin
  -- NULLs are distinct in a unique index, so NULL would defeat idempotency.
  if p_client_event_id is null then
    raise exception 'apply_review requires a client_event_id';
  end if;

  -- Ownership is enforced by RLS on this SELECT and the surrounding writes.
  -- An explicit user_id=auth.uid() predicate would make service-role/SQL-editor
  -- repair calls silently skip the merge while retaining the log row.
  select reps, lapses, last_review
    into v_reps, v_lapses, v_last
    from public.cards
   where id = p_card_id
   for update;
  v_card_found := found;

  if not v_card_found then
    -- Absent or hidden by RLS; this SECURITY INVOKER function cannot tell
    -- which without the FK. Only this branch catches an error, and it never
    -- merges: the subtransaction undoes nothing but the failed insert.
    begin
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
    exception when foreign_key_violation then
      get stacked diagnostics v_constraint = constraint_name;
      -- Any other foreign key (for example the owner) is still an error.
      if not exists (
        select 1
          from pg_catalog.pg_constraint
         where conname = v_constraint
           and conrelid = 'public.review_log'::regclass
           and confrelid = 'public.cards'::regclass
      ) then
        raise;
      end if;
      -- A card hard-deleted while its review was queued: acknowledge the
      -- event without a log row so later reviews are not held behind it.
      return 0;
    end;
  else
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
  end if;

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

  -- A card hidden by RLS keeps 006's behaviour: the log row, no merge.
  if not v_card_found then
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
