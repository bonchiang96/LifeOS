-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 10 of 10: grants
--
-- Sets the access model of implementation notes 5 to 8:
--   1. Revokes EXECUTE on every lifeos function from PUBLIC, anon and authenticated.
--   2. Grants USAGE on schema lifeos to anon and authenticated.
--   3. Grants EXECUTE on the 95 Contract functions to anon and authenticated.
--      Internal helpers (names starting with an underscore) stay revoked.
--   4. Revokes every table privilege from PUBLIC, anon and authenticated.
--   5. Checks that the schema holds exactly the 95 Contract functions plus helpers,
--      each with one signature, SECURITY DEFINER and search_path = lifeos, pg_temp.
-- =============================================================================

revoke all on all functions in schema lifeos from public, anon, authenticated;
revoke all on all tables in schema lifeos from public, anon, authenticated;
revoke all on all sequences in schema lifeos from public, anon, authenticated;

grant usage on schema lifeos to anon, authenticated;

do $$
declare
  v_contract text[] := array[
    -- Chapter 2: LifeOS Memory
    'memory_create', 'memory_read', 'memory_search', 'memory_update', 'memory_delete',
    -- Chapter 3: Notebook
    'notebook_read', 'notebook_list', 'notebook_update',
    -- Chapter 4: Personal Records
    'schedule_create', 'schedule_create_series', 'schedule_read', 'schedule_search', 'schedule_update',
    'schedule_update_series', 'schedule_stop_series', 'schedule_overdue_check', 'schedule_delete',
    'event_create', 'event_link_schedule', 'event_read', 'event_search', 'event_update', 'event_delete',
    'observation_create', 'observation_read', 'observation_search', 'observation_update', 'observation_delete',
    'note_create', 'note_read', 'note_search', 'note_update', 'note_delete',
    'record_link_create', 'record_link_delete', 'record_links_read', 'record_add_remark',
    -- Chapter 5: Subject
    'subject_create', 'subject_read', 'subject_search', 'subject_check', 'subject_update', 'subject_add_alias',
    'subject_merge', 'subject_delete',
    -- Chapter 6: Financial Records
    'expense_create', 'expense_create_batch', 'expense_read', 'expense_search', 'expense_update', 'expense_history',
    'expense_delete', 'expense_refund_create', 'expense_spending_report', 'expense_category_list',
    -- Chapter 7: Divination & Reflection
    'divination_record_save', 'divination_record_read', 'divination_search', 'divination_record_update',
    'divination_record_delete', 'reading_create', 'reading_story_persons_set', 'reading_delete',
    'analysis_add', 'analysis_delete', 'reading_remark_add', 'reading_remark_update',
    'story_person_create', 'story_person_read', 'story_person_search', 'story_person_update', 'story_person_delete',
    'storyline_create', 'storyline_read', 'storyline_search', 'storyline_update', 'storyline_delete',
    -- Chapter 8: Communication Assistant
    'communication_profile_create', 'communication_profile_read', 'communication_profile_search',
    'communication_profile_update', 'communication_profile_delete', 'communication_profile_membership_set',
    'communication_profile_membership_remove', 'communication_rule_upsert', 'communication_rule_delete',
    'communication_rule_state', 'communication_resolve', 'communication_runtime_context',
    'communication_message_finalize', 'communication_message_history_read', 'communication_message_history_search',
    'communication_message_history_delete',
    -- Chapter 9: Timeline and Shared Retrieval
    'timeline', 'subject_records'];
  v_name text;
  v_bad text;
begin
  if cardinality(v_contract) <> 95 then
    raise exception 'grants: the Contract list holds % names, expected 95', cardinality(v_contract);
  end if;

  -- Every Contract function exists with exactly one signature.
  select string_agg(n, ', ') into v_bad
  from unnest(v_contract) n
  where (select count(*) from pg_proc p where p.pronamespace = 'lifeos'::regnamespace and p.proname = n) <> 1;
  if v_bad is not null then
    raise exception 'grants: missing or overloaded Contract functions: %', v_bad;
  end if;

  -- No Agent-facing function outside the Contract: every other function is an underscore helper.
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'lifeos'::regnamespace and p.proname <> all (v_contract) and p.proname !~ '^_';
  if v_bad is not null then
    raise exception 'grants: functions outside the Contract without an underscore prefix: %', v_bad;
  end if;

  -- Contract functions are SECURITY DEFINER with search_path = lifeos, pg_temp.
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'lifeos'::regnamespace and p.proname = any (v_contract)
    and (not p.prosecdef or not coalesce(p.proconfig, '{}') @> array['search_path=lifeos, pg_temp']);
  if v_bad is not null then
    raise exception 'grants: Contract functions without SECURITY DEFINER and search_path: %', v_bad;
  end if;

  foreach v_name in array v_contract loop
    execute format('grant execute on function lifeos.%I to anon, authenticated', v_name);
  end loop;
end $$;
