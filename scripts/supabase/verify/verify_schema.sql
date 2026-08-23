-- Read-only structural verification for Recall's complete Supabase contract.
-- Safe to run against production: this script reads catalog metadata only.
-- Success returns one row containing "VERIFY OK: Recall schema contract".

do $verify$
declare
  v_missing text;
  v_table text;
  v_function_def text;
begin
  with required(table_name, column_name, sql_type) as (
    values
      ('decks', 'id', 'bigint'),
      ('decks', 'user_id', 'uuid'),
      ('decks', 'deck_id', 'bigint'),
      ('decks', 'name', 'text'),
      ('decks', 'deleted', 'boolean'),
      ('decks', 'created_at', 'timestamp with time zone'),
      ('decks', 'updated_at', 'timestamp with time zone'),
      ('notes', 'id', 'bigint'),
      ('notes', 'user_id', 'uuid'),
      ('notes', 'guid', 'text'),
      ('notes', 'deck_id', 'bigint'),
      ('notes', 'mid', 'bigint'),
      ('notes', 'front', 'text'),
      ('notes', 'back', 'text'),
      ('notes', 'tags', 'text'),
      ('notes', 'has_latex', 'boolean'),
      ('notes', 'latex_svg', 'jsonb'),
      ('notes', 'deleted', 'boolean'),
      ('notes', 'anki_mod', 'bigint'),
      ('notes', 'created_at', 'timestamp with time zone'),
      ('notes', 'updated_at', 'timestamp with time zone'),
      ('cards', 'id', 'bigint'),
      ('cards', 'user_id', 'uuid'),
      ('cards', 'note_id', 'bigint'),
      ('cards', 'guid', 'text'),
      ('cards', 'stability', 'real'),
      ('cards', 'difficulty', 'real'),
      ('cards', 'due', 'timestamp with time zone'),
      ('cards', 'state', 'smallint'),
      ('cards', 'reps', 'integer'),
      ('cards', 'lapses', 'integer'),
      ('cards', 'last_review', 'timestamp with time zone'),
      ('cards', 'cloud_seen', 'boolean'),
      ('cards', 'deleted', 'boolean'),
      ('cards', 'created_at', 'timestamp with time zone'),
      ('cards', 'updated_at', 'timestamp with time zone'),
      ('cards', 'suspended', 'boolean'),
      ('review_log', 'id', 'bigint'),
      ('review_log', 'user_id', 'uuid'),
      ('review_log', 'card_id', 'bigint'),
      ('review_log', 'guid', 'text'),
      ('review_log', 'rating', 'smallint'),
      ('review_log', 'rating_at', 'timestamp with time zone'),
      ('review_log', 'stability_after', 'real'),
      ('review_log', 'difficulty_after', 'real'),
      ('review_log', 'due_after', 'timestamp with time zone'),
      ('review_log', 'state_after', 'smallint'),
      ('review_log', 'elapsed_ms', 'integer'),
      ('review_log', 'device', 'text'),
      ('review_log', 'created_at', 'timestamp with time zone'),
      ('review_log', 'client_event_id', 'text'),
      ('user_settings', 'id', 'integer'),
      ('user_settings', 'user_id', 'uuid'),
      ('user_settings', 'settings_key', 'text'),
      ('user_settings', 'settings_value', 'jsonb'),
      ('user_settings', 'updated_at', 'timestamp with time zone'),
      ('note_flags', 'id', 'bigint'),
      ('note_flags', 'user_id', 'uuid'),
      ('note_flags', 'card_id', 'bigint'),
      ('note_flags', 'guid', 'text'),
      ('note_flags', 'reason', 'text'),
      ('note_flags', 'flagged_at', 'timestamp with time zone'),
      ('note_flags', 'device', 'text'),
      ('note_flags', 'status', 'text'),
      ('note_flags', 'resolved_at', 'timestamp with time zone'),
      ('note_flags', 'resolution', 'text'),
      ('note_flags', 'created_at', 'timestamp with time zone'),
      ('note_flags', 'client_event_id', 'text'),
      ('concept_nodes', 'node_id', 'text'),
      ('concept_nodes', 'title', 'text'),
      ('concept_nodes', 'module', 'text'),
      ('concept_nodes', 'difficulty', 'integer'),
      ('concept_nodes', 'updated_at', 'timestamp with time zone'),
      ('concept_pages', 'node_id', 'text'),
      ('concept_pages', 'title', 'text'),
      ('concept_pages', 'body_html', 'text'),
      ('concept_pages', 'figure_svg', 'text'),
      ('concept_pages', 'updated_at', 'timestamp with time zone')
  )
  select string_agg(
           format('%I.%I expected %s, found %s',
             r.table_name, r.column_name, r.sql_type,
             coalesce(c.data_type, '<missing>')),
           '; ' order by r.table_name, r.column_name
         )
    into v_missing
    from required r
    left join information_schema.columns c
      on c.table_schema = 'public'
     and c.table_name = r.table_name
     and c.column_name = r.column_name
   where c.column_name is null or c.data_type <> r.sql_type;

  if v_missing is not null then
    raise exception 'VERIFY FAILED: %', v_missing;
  end if;

  foreach v_table in array array[
    'decks', 'notes', 'cards', 'review_log', 'user_settings', 'note_flags',
    'concept_nodes', 'concept_pages'
  ] loop
    if not exists (
      select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and c.relname = v_table
         and c.relrowsecurity
    ) then
      raise exception 'VERIFY FAILED: public.% does not have RLS enabled', v_table;
    end if;
  end loop;

  foreach v_table in array array[
    'decks', 'notes', 'cards', 'review_log', 'user_settings', 'note_flags'
  ] loop
    if not exists (
      select 1
        from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = v_table
         and policyname = 'own'
         and cmd = 'ALL'
         and qual like '%auth.uid()%user_id%'
         and with_check like '%auth.uid()%user_id%'
    ) then
      raise exception 'VERIFY FAILED: public.% own-user RLS policy is absent or drifted', v_table;
    end if;
  end loop;

  foreach v_table in array array['concept_nodes', 'concept_pages'] loop
    if not exists (
      select 1
        from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = v_table
         and policyname = 'read_all'
         and cmd = 'SELECT'
         and qual = 'true'
    ) then
      raise exception 'VERIFY FAILED: public.% read-only policy is absent or drifted', v_table;
    end if;
  end loop;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'review_log'
       and column_name = 'user_id'
       and is_nullable = 'NO'
       and column_default is not null
  ) then
    raise exception 'VERIFY FAILED: review_log.user_id needs a non-null owner default';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'note_flags'
       and column_name = 'user_id'
       and is_nullable = 'NO'
       and column_default is not null
  ) then
    raise exception 'VERIFY FAILED: note_flags.user_id needs a non-null owner default';
  end if;

  if to_regclass('public.review_log_card_client_event_uidx') is null
     or to_regclass('public.note_flags_card_client_event_uidx') is null then
    raise exception 'VERIFY FAILED: durable event-id unique indexes are absent';
  end if;

  if to_regclass('public.idx_notes_user_deck') is null
     or to_regclass('public.idx_cards_user_due') is null
     or to_regclass('public.idx_cards_user_state') is null
     or to_regclass('public.idx_review_log_user_date') is null
     or to_regclass('public.idx_cards_user_active') is null
     or to_regclass('public.idx_note_flags_open') is null then
    raise exception 'VERIFY FAILED: a required query index is absent';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.decks'::regclass
       and conname = 'decks_user_id_deck_id_key'
       and contype = 'u'
  ) or not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.notes'::regclass
       and conname = 'notes_user_id_guid_key'
       and contype = 'u'
  ) or not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.cards'::regclass
       and conname = 'cards_user_id_guid_key'
       and contype = 'u'
  ) or not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.user_settings'::regclass
       and conname = 'user_settings_user_id_settings_key_key'
       and contype = 'u'
  ) then
    raise exception 'VERIFY FAILED: an importer/settings upsert constraint is absent';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.note_flags'::regclass
       and conname = 'note_flags_reason_check'
       and pg_get_constraintdef(oid) like '%wrong%confusing%too_long%duplicate%'
  ) or not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.note_flags'::regclass
       and conname = 'note_flags_status_check'
       and pg_get_constraintdef(oid) like '%open%resolved%dismissed%'
  ) then
    raise exception 'VERIFY FAILED: note_flags reason/status lifecycle constraints drifted';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.cards'::regclass
       and conname = 'cards_note_id_fkey'
       and confrelid = 'public.notes'::regclass
  ) or not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.review_log'::regclass
       and conname = 'review_log_card_id_fkey'
       and confrelid = 'public.cards'::regclass
  ) or not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.note_flags'::regclass
       and conname = 'note_flags_card_id_fkey'
       and confrelid = 'public.cards'::regclass
  ) or not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.concept_pages'::regclass
       and conname = 'concept_pages_node_id_fkey'
       and confrelid = 'public.concept_nodes'::regclass
  ) then
    raise exception 'VERIFY FAILED: a required content/history foreign key is absent';
  end if;

  foreach v_table in array array[
    't_decks', 't_notes', 't_cards', 't_settings'
  ] loop
    if not exists (
      select 1
        from pg_catalog.pg_trigger
       where tgname = v_table
         and not tgisinternal
    ) then
      raise exception 'VERIFY FAILED: updated_at trigger % is absent', v_table;
    end if;
  end loop;

  if to_regprocedure('public.deck_counts()') is null then
    raise exception 'VERIFY FAILED: public.deck_counts() is absent';
  end if;
  select lower(pg_get_functiondef('public.deck_counts()'::regprocedure))
    into v_function_def;
  if position('c.suspended = false' in v_function_def) = 0 then
    raise exception 'VERIFY FAILED: deck_counts() does not exclude suspended cards';
  end if;

  if to_regprocedure(
    'public.apply_review(bigint,text,smallint,timestamp with time zone,real,real,timestamp with time zone,smallint,boolean,integer,text,text)'
  ) is null then
    raise exception 'VERIFY FAILED: public.apply_review(...) is absent';
  end if;

  if exists (
    select 1
      from pg_catalog.pg_proc
     where oid = 'public.apply_review(bigint,text,smallint,timestamp with time zone,real,real,timestamp with time zone,smallint,boolean,integer,text,text)'::regprocedure
       and prosecdef
  ) then
    raise exception 'VERIFY FAILED: apply_review must be SECURITY INVOKER';
  end if;

  if not has_function_privilege('authenticated', 'public.deck_counts()', 'EXECUTE')
     or not has_function_privilege(
       'authenticated',
       'public.apply_review(bigint,text,smallint,timestamp with time zone,real,real,timestamp with time zone,smallint,boolean,integer,text,text)',
       'EXECUTE'
     ) then
    raise exception 'VERIFY FAILED: authenticated RPC execute grants are absent';
  end if;

  if not has_table_privilege('authenticated', 'public.decks', 'SELECT')
     or not has_table_privilege('authenticated', 'public.notes', 'SELECT')
     or not has_table_privilege('authenticated', 'public.cards', 'SELECT,UPDATE')
     or not has_table_privilege('authenticated', 'public.review_log', 'SELECT,INSERT,DELETE')
     or not has_table_privilege('authenticated', 'public.user_settings', 'SELECT,INSERT,UPDATE,DELETE')
     or not has_table_privilege('authenticated', 'public.note_flags', 'SELECT,INSERT,UPDATE')
     or not has_table_privilege('authenticated', 'public.concept_nodes', 'SELECT')
     or not has_table_privilege('authenticated', 'public.concept_pages', 'SELECT') then
    raise exception 'VERIFY FAILED: an authenticated table grant is absent';
  end if;
end
$verify$;

select 'VERIFY OK: Recall schema contract' as result;
