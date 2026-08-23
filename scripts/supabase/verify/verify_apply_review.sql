-- Behavioral verification for public.apply_review.
--
-- Provenance: copied from Health's deployed
-- scripts/supabase_verify_recall_review_rpc.sql. It pins the SQL conflict policy
-- to the same cases as lib/features/review/data/review_replay.dart.
--
-- Safe on production: every write occurs inside this DO statement, which always
-- raises. PostgreSQL rolls the entire statement back. Read the final exception:
-- "VERIFY OK" means pass; any "VERIFY FAILED" names the broken case.
-- The selected card is locked for milliseconds so a real concurrent review
-- waits instead of moving the baseline under the assertions.

do $verify$
declare
  v_card_id bigint;
  v_reps0 integer; v_lapses0 integer; v_lr0 timestamptz;
  v_reps integer; v_lapses integer; v_lr timestamptz; v_stab real;
  t_new timestamptz; t_old timestamptz;
  v_id1 bigint; v_id2 bigint; v_logs integer;
  v_due timestamptz; v_state smallint;
  ev text; ev1 text; ev2 text; ev3 text;
  fails text := '';
begin
  if to_regprocedure(
    'public.apply_review(bigint,text,smallint,timestamp with time zone,real,real,timestamp with time zone,smallint,boolean,integer,text,text)'
  ) is null then
    raise exception 'VERIFY FAILED: apply_review is not deployed';
  end if;

  select id, reps, lapses, last_review
    into v_card_id, v_reps0, v_lapses0, v_lr0
    from public.cards
   where deleted = false
   order by id
   limit 1
   for update;

  if v_card_id is null then
    raise exception 'VERIFY FAILED: no non-deleted card to exercise';
  end if;

  ev := 'verify-' || gen_random_uuid()::text;
  ev1 := ev || '-1';
  ev2 := ev || '-2';
  ev3 := ev || '-3';
  t_new := coalesce(v_lr0, now()) + interval '1 hour';
  t_old := coalesce(v_lr0, now()) - interval '1 hour';

  -- A. A newer review wins the schedule and counts its rep.
  v_id1 := public.apply_review(v_card_id, 'g', 3::smallint, t_new, 20::real,
    5::real, t_new + interval '10 days', 2::smallint, false, 1000, 'phone', ev1);
  select reps, last_review into v_reps, v_lr
    from public.cards where id = v_card_id;
  if v_reps <> v_reps0 + 1 then fails := fails || 'A:reps '; end if;
  if v_lr <> t_new then fails := fails || 'A:schedule '; end if;

  -- B. Replaying one client_event_id changes nothing.
  v_id2 := public.apply_review(v_card_id, 'g', 3::smallint, t_new, 99::real,
    9::real, t_new + interval '99 days', 2::smallint, true, 1000, 'phone', ev1);
  select reps, lapses, stability, due, state
    into v_reps, v_lapses, v_stab, v_due, v_state
    from public.cards where id = v_card_id;
  if v_id2 <> v_id1 then fails := fails || 'B:log_id '; end if;
  if v_reps <> v_reps0 + 1 then fails := fails || 'B:double_count '; end if;
  if v_lapses <> v_lapses0 then fails := fails || 'B:lapses '; end if;
  if v_stab <> 20::real then fails := fails || 'B:scheduling_touched '; end if;
  if v_due <> t_new + interval '10 days' then fails := fails || 'B:due '; end if;
  if v_state <> 2 then fails := fails || 'B:state '; end if;

  -- C. An older review counts but does not rewind the schedule.
  perform public.apply_review(v_card_id, 'g', 1::smallint, t_old, 2::real,
    7::real, t_old + interval '1 day', 3::smallint, true, 1000, 'ipad', ev2);
  select reps, lapses, last_review, stability
    into v_reps, v_lapses, v_lr, v_stab
    from public.cards where id = v_card_id;
  if v_reps <> v_reps0 + 2 then fails := fails || 'C:reps '; end if;
  if v_lapses <> v_lapses0 + 1 then fails := fails || 'C:lapses '; end if;
  if v_lr <> t_new or v_stab <> 20::real then fails := fails || 'C:rewound '; end if;

  -- D. An exact timestamp tie counts and keeps the first schedule.
  perform public.apply_review(v_card_id, 'g', 3::smallint, t_new, 55::real,
    5::real, t_new + interval '5 days', 2::smallint, false, 1000, 'ipad', ev3);
  select reps, stability into v_reps, v_stab
    from public.cards where id = v_card_id;
  select count(*) into v_logs
    from public.review_log
   where card_id = v_card_id
     and client_event_id like ev || '%';
  if v_reps <> v_reps0 + 3 then fails := fails || 'D:tie_rep_dropped '; end if;
  if v_stab <> 20::real then fails := fails || 'D:tie_took_schedule '; end if;
  if v_logs <> 3 then fails := fails || 'D:log_count '; end if;

  if fails = '' then
    raise exception 'VERIFY OK (rolled back; card % untouched)', v_card_id;
  end if;
  raise exception 'VERIFY FAILED: %', fails;
end
$verify$;
