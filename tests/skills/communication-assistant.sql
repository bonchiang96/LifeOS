-- =============================================================================
-- tests/skills/communication-assistant.sql -- Skill flow tests: skills/communication-assistant/SKILL.md
-- Communication Assistant: Profiles, inheritance, Rules, drafting context, finalization, Message History, cross-module retrieval. Contract: communication-assistant.md, shared.md.
-- Each test follows the database steps of one Skill flow, in the Skill's order, through the Contract
-- functions, and asserts the outcome that the Skill and the Knowledge Base state.
--
-- Tests in this file:
--    1. profile_selected_by_name_or_person_subject
--    2. person_profile_set_up_after_subject_decision_or_global_rules_without
--    3. group_and_audience_profiles_inherit_by_priority_and_removal
--    4. profile_relinked_to_correct_person_keeps_rules_and_history
--    5. profile_deleted_subject_stays_rules_stop_history_stays
--    6. person_subject_with_profile_deleted_after_profile_outcome
--    7. rule_resolution_profile_inherited_global_and_language_mode
--    8. message_drafting_context_with_rules_examples_and_platform
--    9. message_finalized_with_rule_changes_or_none
--   10. message_history_search_read_and_delete
--   11. cross_module_retrieval_follows_profile_person_subject
--   12. two_person_profiles_merged_after_rule_conflict_with_aliases_and_memberships
--   13. group_and_audience_profiles_set_up_changed_and_removed_without_approval
--   14. rule_added_changed_and_removed_outside_a_message_without_confirmation
--   15. send_ready_message_unfinalized_at_conversation_end_saves_nothing
--   16. language_mode_and_platform_values_reused_from_notebooks
--
-- Single transaction: begin; tests; select results; rollback.
-- Fixture text starts with SKT_ and business dates lie in 2032, unless a flow needs today
-- (Note date, Message finalized_at, overdue check, recorded_earlier). Those tests filter by their own IDs.
-- =============================================================================
begin;

-- Test harness. Everything below lives in the session and disappears at rollback.
create temp table t_results (seq serial, test text, status text, detail text);

create function pg_temp.pass(p_test text) returns void language plpgsql as $f$
begin
  insert into t_results (test, status) values (p_test, 'PASS');
  raise notice 'PASS %', p_test;
end $f$;

create function pg_temp.fail(p_test text, p_detail text) returns void language plpgsql as $f$
begin
  insert into t_results (test, status, detail) values (p_test, 'FAIL', p_detail);
  raise notice 'FAIL % -- %', p_test, p_detail;
end $f$;

-- Raises an exception when the condition is not true.
create function pg_temp.chk(p_cond boolean, p_msg text) returns void language plpgsql as $f$
begin
  if p_cond is not true then raise exception 'assertion failed: %', p_msg; end if;
end $f$;

-- Runs a statement and returns its error text, or null when it succeeds.
-- The statement runs in a sub-transaction, so a failure leaves no change behind.
create function pg_temp.err_of(p_sql text) returns text language plpgsql as $f$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end $f$;

-- Raises an exception unless the statement fails with exactly the Contract error text.
create function pg_temp.expect_err(p_sql text, p_expected text) returns void language plpgsql as $f$
declare v text := pg_temp.err_of(p_sql);
begin
  if v is distinct from p_expected then
    raise exception 'expected error "%" but got "%" for: %', p_expected, coalesce(v, '<no error>'), left(p_sql, 160);
  end if;
end $f$;

-- Today in Asia/Kuala_Lumpur (Contract shared.md 1.7 item 4).
create function pg_temp.today() returns date language sql as
$f$ select (now() at time zone 'Asia/Kuala_Lumpur')::date $f$;

-- Fixture ids shared between the tests of one file.
create temp table t_ids (k text primary key, v uuid);
create function pg_temp.id(p_k text) returns uuid language sql as
$f$ select v from t_ids where k = p_k $f$;
create function pg_temp.keep(p_k text, p_v uuid) returns uuid language plpgsql as $f$
begin insert into t_ids values (p_k, p_v) on conflict (k) do update set v = excluded.v; return p_v; end $f$;

-- Quote helper for building statements that contain a uuid.
create function pg_temp.q(p uuid) returns text language sql as $f$ select quote_literal(p::text) || '::uuid' $f$;

-- JSON array helpers. A non-array value counts as an empty array.
create function pg_temp.arr(p jsonb) returns jsonb language sql as
$f$ select case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end $f$;
-- The first element whose "id" is p_id, or null.
create function pg_temp.find(p_arr jsonb, p_id uuid) returns jsonb language sql as
$f$ select e from jsonb_array_elements(pg_temp.arr(p_arr)) with ordinality x(e, o) where e ->> 'id' = p_id::text order by o limit 1 $f$;
-- How many elements have "id" p_id.
create function pg_temp.cnt(p_arr jsonb, p_id uuid) returns integer language sql as
$f$ select count(*)::integer from jsonb_array_elements(pg_temp.arr(p_arr)) e where e ->> 'id' = p_id::text $f$;
-- 1-based position of the first element with "id" p_id, or null.
create function pg_temp.pos(p_arr jsonb, p_id uuid) returns integer language sql as
$f$ select min(o)::integer from jsonb_array_elements(pg_temp.arr(p_arr)) with ordinality x(e, o) where e ->> 'id' = p_id::text $f$;
-- True when a text array in JSON holds p_val.
create function pg_temp.has_text(p_arr jsonb, p_val text) returns boolean language sql as
$f$ select exists (select 1 from jsonb_array_elements_text(pg_temp.arr(p_arr)) v where v = p_val) $f$;

-- Subject fixture through the Contract (shared.md 5.1).
create function pg_temp.mk_subject(p_name text, p_type text default null) returns uuid language sql as
$f$ select ((lifeos.subject_create(jsonb_build_object('name', p_name, 'subject_type', p_type)))->>'id')::uuid $f$;

-- The user Subject, found as the entry Skill Section 6 step 6 says (subject_search with is_user true).
-- When the project has none, the test creates it.
create function pg_temp.user_subject() returns uuid language plpgsql as $f$
declare r jsonb := lifeos.subject_search('{"is_user": true}'::jsonb);
begin
  if (r ->> 'returned_count')::integer > 0 then
    return (r -> 'results' -> 0 ->> 'id')::uuid;
  end if;
  return (lifeos.subject_create('{"name": "SKT_User", "subject_type": "person", "is_user": true}'::jsonb) ->> 'id')::uuid;
end $f$;

create function pg_temp.mk_profile(p_key text, p_type text, p_subject uuid default null) returns uuid language sql as
$f$ select ((lifeos.communication_profile_create(jsonb_build_object('profile_key', p_key, 'profile_type', p_type, 'name', p_key, 'person_subject_id', p_subject)))->>'id')::uuid $f$;
-- Effective rule text of one dimension and rule_key in a resolve or runtime context result.
create function pg_temp.eff(p_res jsonb, p_dim text, p_key text) returns text language sql as
$f$ select r ->> 'rule_text' from jsonb_array_elements(pg_temp.arr(p_res -> 'effective_rules' -> p_dim)) r where r ->> 'rule_key' = p_key $f$;
create function pg_temp.rule(p_profile uuid, p_lang text, p_dim text, p_key text, p_text text) returns jsonb language sql as
$f$ select lifeos.communication_rule_upsert(jsonb_build_object('profile_id', p_profile, 'language_mode', p_lang, 'dimension', p_dim, 'rule_key', p_key, 'rule_text', p_text)) $f$;
create function pg_temp.fin(p_profile uuid, p_text text, p_lang text default null, p_platform text default null) returns jsonb language sql as
$f$ select lifeos.communication_message_finalize(jsonb_build_object('profile_id', p_profile, 'message_text', p_text, 'language_mode', p_lang, 'platform', p_platform)) $f$;

-- The values of a Notebook, one per non-empty line, as the Skill Section 6 reads language_modes and platforms.
create function pg_temp.nb_values(p_key text) returns text[] language sql as
$f$ select coalesce(array_agg(btrim(l) order by o) filter (where btrim(l) <> ''), '{}'::text[])
    from regexp_split_to_table(coalesce(lifeos.notebook_read(p_key) ->> 'content', ''), E'\n') with ordinality x(l, o) $f$;
-- Section 6 steps 2 to 4 and 7 to 9: reuse the value when it is in the Notebook; add it only when no value fits.
create function pg_temp.nb_value(p_key text, p_value text) returns text language plpgsql as $f$
declare n jsonb := lifeos.notebook_read(p_key);
begin
  if not (p_value = any (pg_temp.nb_values(p_key))) then
    perform lifeos.notebook_update(p_key, jsonb_build_object('content', concat_ws(E'\n', nullif(n ->> 'content', ''), p_value)));
  end if;
  return p_value;
end $f$;
-- The Rules of one Profile with scope profile, once each, read without a Language Mode and with each value of
-- the language_modes Notebook (Section 5 "Steps for two Person Profiles of one person", steps 3 to 5).
create function pg_temp.own_rules(p_profile uuid) returns jsonb language plpgsql as $f$
declare lm text; acc jsonb := '[]'::jsonb;
begin
  for lm in select null::text union all select unnest(pg_temp.nb_values('language_modes')) loop
    acc := acc || coalesce((select jsonb_agg(x) from jsonb_array_elements(lifeos.communication_rule_state(p_profile, lm) -> 'rules') x
                            where x ->> 'scope' = 'profile'), '[]'::jsonb);
  end loop;
  return coalesce((select jsonb_agg(e order by e ->> 'dimension', e ->> 'rule_key', e ->> 'language_mode')
                   from (select distinct on (e ->> 'id') e from jsonb_array_elements(acc) e order by e ->> 'id') d), '[]'::jsonb);
end $f$;

-- 1. Section 4 steps 1 to 3: Profile selection ---------------------------------------------------------
do $t$
declare t constant text := 'profile_selected_by_name_or_person_subject';
  s uuid := pg_temp.mk_subject('SKT_C1 Mum', 'person'); p jsonb; rc jsonb;
begin
  p := lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-c1-mum', 'profile_type', 'person', 'name', 'SKT_C1 Mum', 'aliases', jsonb_build_array('SKT_C1 Mak'), 'person_subject_id', s));
  -- step 1: the wording the user used
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_profile_search('{"keyword": "SKT_C1 Mak"}'::jsonb) -> 'results', (p ->> 'id')::uuid) = 1, 'found by Alias');
  -- step 2: a known Subject
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_profile_search(jsonb_build_object('person_subject_id', s)) -> 'results', (p ->> 'id')::uuid) = 1, 'found by person_subject_id');
  -- step 3: the active Profile drives the context
  rc := lifeos.communication_runtime_context((p ->> 'id')::uuid, null, null);
  perform pg_temp.chk(rc -> 'profile' ->> 'id' = p ->> 'id', 'the runtime context names the active Profile');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Section 4 steps 4 to 12: Person Profile setup, reuse, or no Profile when the user declines ------------
do $t$
declare t constant text := 'person_profile_set_up_after_subject_decision_or_global_rules_without';
  s jsonb; p jsonb; ex uuid := pg_temp.mk_subject('SKT_C2 Aunty Rose', 'person'); rose_p uuid; pr uuid := pg_temp.mk_profile('skt-c2-other-group', 'group'); g jsonb;
begin
  -- approved new Subject, then its Person Profile
  perform pg_temp.chk(not (lifeos.subject_check('SKT_C2 Daniel') ->> 'exists')::boolean, 'no Subject yet');
  s := lifeos.subject_create('{"name": "SKT_C2 Daniel", "subject_type": "person", "description": "SKT_C2 new client"}'::jsonb);
  perform pg_temp.chk((lifeos.communication_profile_search(jsonb_build_object('person_subject_id', s ->> 'id')) ->> 'returned_count')::integer = 0, 'the Subject has no Profile yet');
  p := lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-c2-daniel', 'profile_type', 'person', 'name', 'SKT_C2 Daniel',
         'description', 'SKT_C2 client, prefers English', 'person_subject_id', s ->> 'id'));
  perform pg_temp.chk(p ->> 'profile_type' = 'person' and p ->> 'person_subject_id' = s ->> 'id', 'step 8: the Person Profile identifies the approved Subject');
  -- step 7: an existing Subject's single Person Profile is reused
  rose_p := pg_temp.mk_profile('skt-c2-rose', 'person', ex);
  perform pg_temp.chk(lifeos.communication_profile_search(jsonb_build_object('person_subject_id', ex)) -> 'results' -> 0 ->> 'id' = rose_p::text, 'the existing Profile is found for reuse');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_create(%L::jsonb)', jsonb_build_object('profile_key', 'skt-c2-rose-2', 'profile_type', 'person', 'name', 'x', 'person_subject_id', ex)), 'invalid relationship');
  -- steps 9 and 10: declined; drafting with no Profile uses Global Rules only
  perform pg_temp.rule(null, null, 'skt_c2_tone', 'greeting', 'SKT_C2 global greeting');
  perform pg_temp.rule(pr, null, 'skt_c2_tone', 'greeting', 'SKT_C2 group greeting');
  g := lifeos.communication_runtime_context(null, null, null);
  perform pg_temp.chk(jsonb_typeof(g -> 'profile') = 'null' and pg_temp.eff(g, 'skt_c2_tone', 'greeting') = 'SKT_C2 global greeting', 'no Profile: Global Rules only');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Section 4 steps 13 to 18: Group and Audience Profiles and inheritance --------------------------------
do $t$
declare t constant text := 'group_and_audience_profiles_inherit_by_priority_and_removal';
  grp uuid := pg_temp.mk_profile('skt-c3-badminton', 'group'); fr uuid := pg_temp.mk_profile('skt-c3-friends', 'audience'); sp uuid := pg_temp.mk_profile('skt-c3-sports', 'audience');
  s uuid := pg_temp.mk_subject('SKT_C3 Hafiz', 'person'); per uuid; m jsonb; r jsonb;
begin
  per := pg_temp.mk_profile('skt-c3-hafiz', 'person', s);
  perform pg_temp.expect_err(format('select lifeos.communication_profile_create(%L::jsonb)', jsonb_build_object('profile_key', 'skt-c3-bad', 'profile_type', 'group', 'name', 'x', 'person_subject_id', s)), 'invalid input');
  perform pg_temp.rule(fr, null, 'skt_c3_tone', 'register', 'SKT_C3 casual');
  perform pg_temp.rule(sp, null, 'skt_c3_tone', 'register', 'SKT_C3 hype');
  -- steps 16 and 17
  m := lifeos.communication_profile_membership_set(grp, fr, 1);
  perform pg_temp.chk((m ->> 'priority')::integer = 1, 'the Group inherits from friends');
  perform lifeos.communication_profile_membership_set(grp, sp, 5);
  perform lifeos.communication_profile_membership_set(per, fr);
  r := lifeos.communication_resolve(grp, null);
  perform pg_temp.chk(pg_temp.eff(r, 'skt_c3_tone', 'register') = 'SKT_C3 hype', 'the higher priority Audience wins at the same depth');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(per, null), 'skt_c3_tone', 'register') = 'SKT_C3 casual', 'a Person inherits from its Audience');
  perform pg_temp.chk(jsonb_array_length(lifeos.communication_profile_read(grp) -> 'parent_profiles') = 2, 'the Group has two parent Audiences');
  -- step 18
  perform pg_temp.chk((lifeos.communication_profile_membership_remove(grp, sp) ->> 'removed')::boolean, 'the inheritance is removed');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(grp, null), 'skt_c3_tone', 'register') = 'SKT_C3 casual', 'the remaining Audience applies');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Section 5 steps 1 to 5: a Profile belongs to another person ------------------------------------------
do $t$
declare t constant text := 'profile_relinked_to_correct_person_keeps_rules_and_history';
  s1 uuid := pg_temp.mk_subject('SKT_C4 Siti', 'person'); s2 uuid := pg_temp.mk_subject('SKT_C4 Siti Aminah', 'person'); p uuid; m jsonb; u jsonb;
begin
  p := pg_temp.mk_profile('skt-c4-siti', 'person', s1);
  perform pg_temp.rule(p, null, 'skt_c4_style', 'length', 'SKT_C4 short');
  m := pg_temp.fin(p, 'SKT_C4 Hi Siti, see you at 8', 'en', 'whatsapp');
  -- step 3 after approval
  u := lifeos.communication_profile_update(p, jsonb_build_object('person_subject_id', s2));
  perform pg_temp.chk(u ->> 'person_subject_id' = s2::text, 'the Profile identifies the correct Subject');
  -- step 4
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(lifeos.communication_rule_state(p, null) -> 'rules') r where r ->> 'rule_text' = 'SKT_C4 short' and r ->> 'scope' = 'profile'), 'the Rules stay with the Profile');
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_message_history_search(jsonb_build_object('profile_id', p)) -> 'results', (m -> 'message' ->> 'id')::uuid) = 1, 'the Message History stays with the Profile');
  -- step 5
  perform pg_temp.chk(lifeos.subject_read(s1) ->> 'deleted_at' is null and lifeos.subject_read(s1) ->> 'person_profile_id' is null and lifeos.subject_read(s2) ->> 'person_profile_id' = p::text, 'the earlier Subject stays; the Profile now belongs to the correct one');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Section 5 steps 6 and 7: Profile deletion --------------------------------------------------------
do $t$
declare t constant text := 'profile_deleted_subject_stays_rules_stop_history_stays';
  s uuid := pg_temp.mk_subject('SKT_C5 Ex-colleague', 'person'); p uuid; m jsonb; aud uuid := pg_temp.mk_profile('skt-c5-office', 'audience'); q uuid;
begin
  p := pg_temp.mk_profile('skt-c5-excolleague', 'person', s);
  perform pg_temp.rule(p, null, 'skt_c5_tone', 'formality', 'SKT_C5 formal');
  m := pg_temp.fin(p, 'SKT_C5 Dear Mr Wong, thank you', 'en', 'email');
  perform lifeos.communication_profile_delete(p);
  perform pg_temp.chk(lifeos.subject_read(s) ->> 'deleted_at' is null and lifeos.subject_read(s) ->> 'person_profile_id' is null, 'the Subject stays, without a Profile');
  perform pg_temp.expect_err(format('select lifeos.communication_resolve(%s)', pg_temp.q(p)), 'record deleted');
  perform pg_temp.chk(lifeos.communication_message_history_read((m -> 'message' ->> 'id')::uuid) ->> 'deleted_at' is null, 'the Message History stays stored');
  -- a deleted Audience's Rules stop applying to its members
  q := pg_temp.mk_profile('skt-c5-member', 'group');
  perform pg_temp.rule(aud, null, 'skt_c5_tone', 'formality', 'SKT_C5 office tone');
  perform lifeos.communication_profile_membership_set(q, aud);
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(q, null), 'skt_c5_tone', 'formality') = 'SKT_C5 office tone', 'inherited before the deletion');
  perform lifeos.communication_profile_delete(aud);
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(q, null), 'skt_c5_tone', 'formality') is null, 'not inherited after the deletion');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Section 5 steps 8 to 10: deleting a Person Subject that has a Profile (both outcomes) ------------------
do $t$
declare t constant text := 'person_subject_with_profile_deleted_after_profile_outcome';
  a uuid := pg_temp.mk_subject('SKT_C6 Lily', 'person'); a2 uuid := pg_temp.mk_subject('SKT_C6 Lily Tan', 'person'); b uuid := pg_temp.mk_subject('SKT_C6 Old landlord', 'person');
  pa uuid; pb uuid;
begin
  pa := pg_temp.mk_profile('skt-c6-lily', 'person', a);
  pb := pg_temp.mk_profile('skt-c6-landlord', 'person', b);
  perform pg_temp.expect_err(format('select lifeos.subject_delete(%s)', pg_temp.q(a)), 'invalid relationship');
  -- outcome 1: the Profile links to its correct Subject
  perform lifeos.communication_profile_update(pa, jsonb_build_object('person_subject_id', a2));
  perform pg_temp.chk(lifeos.subject_delete(a) ->> 'deleted_at' is not null and lifeos.communication_profile_read(pa) ->> 'person_subject_id' = a2::text, 'relinked, then the Subject is deleted');
  -- outcome 2: the Profile is deleted first
  perform lifeos.communication_profile_delete(pb);
  perform pg_temp.chk(lifeos.subject_delete(b) ->> 'deleted_at' is not null, 'Profile deleted, then the Subject is deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Section 6 Rule scope and resolution -------------------------------------------------------------------
do $t$
declare t constant text := 'rule_resolution_profile_inherited_global_and_language_mode';
  s uuid := pg_temp.mk_subject('SKT_C7 Boss', 'person'); p uuid; aud uuid := pg_temp.mk_profile('skt-c7-work', 'audience'); zh jsonb; neu jsonb; st jsonb;
begin
  p := pg_temp.mk_profile('skt-c7-boss', 'person', s);
  perform lifeos.communication_profile_membership_set(p, aud, 0);
  perform pg_temp.rule(null, null, 'skt_c7_tone', 'greeting', 'SKT_C7 G greeting');
  perform pg_temp.rule(aud, null, 'skt_c7_tone', 'greeting', 'SKT_C7 A greeting');
  perform pg_temp.rule(p, 'zh', 'skt_c7_tone', 'greeting', 'SKT_C7 P greeting zh');
  perform pg_temp.rule(null, null, 'skt_c7_tone', 'sign_off', 'SKT_C7 G sign-off');
  perform pg_temp.rule(null, 'zh', 'skt_c7_tone', 'sign_off', 'SKT_C7 G sign-off zh');
  perform pg_temp.rule(null, null, 'skt_c7_style', 'emoji', 'SKT_C7 G emoji');
  -- steps 10 to 12
  zh := lifeos.communication_resolve(p, 'zh');
  perform pg_temp.chk(pg_temp.eff(zh, 'skt_c7_tone', 'greeting') = 'SKT_C7 P greeting zh', 'the Profile Rule outranks inherited and Global Rules');
  perform pg_temp.chk(pg_temp.eff(zh, 'skt_c7_tone', 'sign_off') = 'SKT_C7 G sign-off zh', 'a language-specific Rule outranks a neutral one in the same scope');
  perform pg_temp.chk(pg_temp.eff(zh, 'skt_c7_style', 'emoji') = 'SKT_C7 G emoji', 'Effective Rules are grouped by dimension');
  neu := lifeos.communication_resolve(p, null);
  perform pg_temp.chk(pg_temp.eff(neu, 'skt_c7_tone', 'greeting') = 'SKT_C7 A greeting' and pg_temp.eff(neu, 'skt_c7_tone', 'sign_off') = 'SKT_C7 G sign-off', 'without a Language Mode only neutral Rules apply; inherited outranks Global');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(zh -> 'effective_rules' -> 'skt_c7_tone') r where r ->> 'rule_key' = 'greeting') = 1, 'one Rule per dimension and rule_key');
  -- step 14: raw Rules for inspection
  st := lifeos.communication_rule_state(p, 'zh');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st -> 'rules') r where r ->> 'rule_text' = 'SKT_C7 A greeting' and r ->> 'scope' = 'inherited' and (r ->> 'depth')::integer = 1)
                      and exists (select 1 from jsonb_array_elements(st -> 'rules') r where r ->> 'rule_text' = 'SKT_C7 G greeting' and r ->> 'scope' = 'global')
                      and exists (select 1 from jsonb_array_elements(st -> 'rules') r where r ->> 'rule_text' = 'SKT_C7 P greeting zh' and r ->> 'scope' = 'profile'), 'the raw state lists every applicable Rule with its scope');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Section 7 Message drafting: runtime context, examples and Platform ----------------------------------
do $t$
declare t constant text := 'message_drafting_context_with_rules_examples_and_platform';
  s uuid := pg_temp.mk_subject('SKT_C8 Kak Yati', 'person'); p uuid; m1 jsonb; m2 jsonb; m3 jsonb; rc jsonb; hs jsonb;
begin
  p := pg_temp.mk_profile('skt-c8-yati', 'person', s);
  perform pg_temp.rule(p, 'en', 'skt_c8_tone', 'warmth', 'SKT_C8 warm and short');
  m1 := pg_temp.fin(p, 'SKT_C8 Thanks kak, see you Sunday!', 'en', 'whatsapp');
  m2 := pg_temp.fin(p, 'SKT_C8 Dear Kak Yati, attached is the invoice.', 'en', 'email');
  m3 := pg_temp.fin(p, 'SKT_C8 谢谢姐', 'zh', 'whatsapp');
  -- step 1
  rc := lifeos.communication_runtime_context(p, 'en', 'email', 5);
  perform pg_temp.chk(pg_temp.eff(rc, 'skt_c8_tone', 'warmth') = 'SKT_C8 warm and short' and rc ->> 'platform' = 'email' and rc ->> 'language_mode' = 'en', 'the Effective Rules for the Profile and Language Mode');
  -- step 3: recent finalized messages of the Profile and Language Mode, the Platform first
  perform pg_temp.chk(pg_temp.pos(rc -> 'recent_messages', (m2 -> 'message' ->> 'id')::uuid) = 1 and pg_temp.cnt(rc -> 'recent_messages', (m1 -> 'message' ->> 'id')::uuid) = 1, 'messages on the Platform rank first');
  perform pg_temp.chk(pg_temp.cnt(rc -> 'recent_messages', (m3 -> 'message' ->> 'id')::uuid) = 0, 'a message of another Language Mode is no example');
  -- step 5: more examples on request
  hs := lifeos.communication_message_history_search(jsonb_build_object('profile_id', p, 'platform', 'whatsapp'));
  perform pg_temp.chk((hs ->> 'returned_count')::integer = 2, 'history search gives further examples');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Section 8 Finalization with Rule consolidation, or with no Rule change --------------------------------
do $t$
declare t constant text := 'message_finalized_with_rule_changes_or_none';
  s uuid := pg_temp.mk_subject('SKT_C9 Darren', 'person'); p uuid; earlier_rec jsonb; keep jsonb; f jsonb; f2 jsonb; ap jsonb;
begin
  p := pg_temp.mk_profile('skt-c9-darren', 'person', s);
  earlier_rec := pg_temp.rule(p, null, 'skt_c9_style', 'emoji', 'SKT_C9 use many emoji');
  keep := pg_temp.rule(p, null, 'skt_c9_style', 'length', 'SKT_C9 short');
  -- steps 11 and 12: upsert create, upsert update by key, delete
  f := lifeos.communication_message_finalize(jsonb_build_object('profile_id', p, 'message_text', 'SKT_C9 Bro, meeting moved to 3pm.', 'language_mode', 'en', 'platform', 'whatsapp',
         'intent', 'reschedule', 'rule_changes', jsonb_build_array(
           jsonb_build_object('action', 'upsert', 'profile_id', p, 'dimension', 'skt_c9_style', 'rule_key', 'opening', 'rule_text', 'SKT_C9 start with Bro'),
           jsonb_build_object('action', 'upsert', 'profile_id', p, 'dimension', 'skt_c9_style', 'rule_key', 'length', 'rule_text', 'SKT_C9 one line'),
           jsonb_build_object('action', 'delete', 'id', earlier_rec ->> 'id'))));
  ap := f -> 'rule_changes_applied';
  perform pg_temp.chk(f -> 'message' ->> 'message_text' = 'SKT_C9 Bro, meeting moved to 3pm.' and f -> 'message' ->> 'finalized_at' is not null, 'the adopted message is saved');
  perform pg_temp.chk(ap -> 0 ->> 'action' = 'created' and ap -> 1 ->> 'action' = 'updated' and ap -> 1 ->> 'id' = keep ->> 'id'
                      and ap -> 2 ->> 'action' = 'deleted' and (ap -> 2 ->> 'removed')::boolean, 'create, update and remove applied in order');
  perform pg_temp.chk(pg_temp.eff(f -> 'runtime_context', 'skt_c9_style', 'opening') = 'SKT_C9 start with Bro' and pg_temp.eff(f -> 'runtime_context', 'skt_c9_style', 'emoji') is null, 'the refreshed context holds the latest Rules');
  -- step 13: saved even with no Rule change
  f2 := pg_temp.fin(p, 'SKT_C9 Ok see you', 'en', 'whatsapp');
  perform pg_temp.chk(f2 -> 'rule_changes_applied' = '[]'::jsonb and f2 -> 'message' ->> 'id' is not null, 'a message without Rule changes is saved');
  -- the call is all or nothing
  perform pg_temp.expect_err(format('select lifeos.communication_message_finalize(%L::jsonb)', jsonb_build_object('profile_id', p, 'message_text', 'SKT_C9 never saved',
            'rule_changes', jsonb_build_array(jsonb_build_object('action', 'rename', 'id', keep ->> 'id')))), 'invalid input');
  perform pg_temp.chk((lifeos.communication_message_history_search('{"keyword": "SKT_C9 never saved"}'::jsonb) ->> 'returned_count')::integer = 0, 'a rejected finalize saves no message');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Section 9 Message History retrieval and deletion ------------------------------------------------------
do $t$
declare t constant text := 'message_history_search_read_and_delete';
  s uuid := pg_temp.mk_subject('SKT_C10 Priya', 'person'); p uuid; m jsonb; mid uuid; d jsonb;
begin
  p := pg_temp.mk_profile('skt-c10-priya', 'person', s);
  m := lifeos.communication_message_finalize(jsonb_build_object('profile_id', p, 'message_text', 'SKT_C10 Happy birthday Priya!', 'language_mode', 'en', 'platform', 'whatsapp', 'intent', 'SKT_C10 birthday wish'));
  mid := (m -> 'message' ->> 'id')::uuid;
  -- step 1
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_message_history_search('{"keyword": "SKT_C10 Happy birthday"}'::jsonb) -> 'results', mid) = 1, 'found by wording');
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_message_history_search(jsonb_build_object('profile_id', p, 'platform', 'whatsapp', 'from_date', pg_temp.today(), 'to_date', pg_temp.today())) -> 'results', mid) = 1, 'found by Profile, Platform and date');
  -- step 2
  perform pg_temp.chk(lifeos.communication_message_history_read(mid) ->> 'intent' = 'SKT_C10 birthday wish', 'the full message is read');
  -- step 4
  d := lifeos.communication_message_history_delete(mid);
  perform pg_temp.chk(d ->> 'deleted_at' is not null, 'the message is deleted');
  perform pg_temp.chk((lifeos.communication_message_history_search('{"keyword": "SKT_C10 Happy birthday"}'::jsonb) ->> 'returned_count')::integer = 0, 'the deleted message is out of the search');
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_runtime_context(p, 'en', 'whatsapp') -> 'recent_messages', mid) = 0, 'the deleted message no longer serves as an example');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Section 10 Cross-module retrieval through the Profile's Person Subject -------------------------------
do $t$
declare t constant text := 'cross_module_retrieval_follows_profile_person_subject';
  s uuid := pg_temp.mk_subject('SKT_C11 Nicholas', 'person'); pm uuid := pg_temp.mk_subject('SKT_C11 Card', 'payment method'); p jsonb; e jsonb; x jsonb; m jsonb; rec jsonb;
begin
  p := lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-c11-nicholas', 'profile_type', 'person', 'name', 'SKT_C11 Nicholas', 'person_subject_id', s));
  e := lifeos.event_create('{"title": "SKT_C11 dinner with Nicholas", "occurred_date": "2032-06-18"}'::jsonb);
  x := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-06-18', 'payment_method_subject_id', pm, 'merchant_name', 'SKT_C11 Restoran', 'expense_total', 80, 'currency', 'MYR',
         'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'SKT_C11 dinner', 'unit_price', 80, 'line_total', 80, 'category', 'food'))));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'expense', 'from_id', x ->> 'id', 'to_type', 'subject', 'to_id', s));
  m := pg_temp.fin((p ->> 'id')::uuid, 'SKT_C11 Thanks for dinner!', 'en', 'whatsapp');
  -- steps 1 and 2: the approved association is the Profile's person_subject_id
  rec := lifeos.subject_records((lifeos.communication_profile_read((p ->> 'id')::uuid) ->> 'person_subject_id')::uuid, '{}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(rec -> 'results', (e ->> 'id')::uuid) = 1 and pg_temp.cnt(rec -> 'results', (x ->> 'id')::uuid) = 1, 'source-owned Records of other Modules are reached');
  perform pg_temp.chk(pg_temp.find(rec -> 'results', (m -> 'message' ->> 'id')::uuid) ->> 'via' = 'person_profile_subject'
                      and pg_temp.find(rec -> 'results', (m -> 'message' ->> 'id')::uuid) ->> 'record_type' = 'communication_message', 'the message is reached through the Person Profile');
  -- step 3: each Record keeps its own type
  perform pg_temp.chk(pg_temp.find(rec -> 'results', (x ->> 'id')::uuid) ->> 'record_type' = 'expense' and pg_temp.find(rec -> 'results', (e ->> 'id')::uuid) ->> 'record_type' = 'event', 'each Record keeps its Module type');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Section 5 Steps for two Person Profiles of one person: show, choose, resolve the Rule conflict, keep, merge --
-- The entry Skill Section 8 step 4 hands the two Profiles to this flow after the user approved the Subject merge.
do $t$
declare t constant text := 'two_person_profiles_merged_after_rule_conflict_with_aliases_and_memberships';
  a uuid := pg_temp.mk_subject('SKT_C12 Ah Kow', 'person'); b uuid := pg_temp.mk_subject('SKT_C12 Kow Ming Hui', 'person');
  fam uuid := pg_temp.mk_profile('skt-c12-family', 'audience'); wrk uuid := pg_temp.mk_profile('skt-c12-work', 'audience');
  en text; zh text; ka uuid; kb uuid; a_greet jsonb; a_len jsonb; b_greet jsonb; b_len jsonb; b_emoji jsonb; ma jsonb; mb1 jsonb; mb2 jsonb;
  rda jsonb; rdb jsonb; own_a jsonb; own_b jsonb; conflicts jsonb; mg jsonb; kept jsonb; st jsonb; r jsonb;
begin
  -- fixture: two Language Modes in the Notebook, and two Person Profiles of one person, each with own Rules,
  -- messages and an Audience membership
  en := pg_temp.nb_value('language_modes', 'skt_c12_en');
  zh := pg_temp.nb_value('language_modes', 'skt_c12_zh');
  ka := ((lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-c12-ah-kow', 'profile_type', 'person', 'name', 'SKT_C12 Ah Kow',
          'aliases', jsonb_build_array('SKT_C12 Kow'), 'person_subject_id', a))) ->> 'id')::uuid;
  kb := ((lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-c12-ming-hui', 'profile_type', 'person', 'name', 'SKT_C12 Ming Hui',
          'aliases', jsonb_build_array('SKT_C12 MH'), 'person_subject_id', b))) ->> 'id')::uuid;
  perform lifeos.communication_profile_membership_set(ka, wrk, 1);
  perform lifeos.communication_profile_membership_set(kb, fam, 2);
  a_greet := pg_temp.rule(ka, null, 'skt_c12_tone', 'greeting', 'SKT_C12 A start with Bro');
  a_len := pg_temp.rule(ka, en, 'skt_c12_style', 'length', 'SKT_C12 A one line in English');
  b_greet := pg_temp.rule(kb, null, 'skt_c12_tone', 'greeting', 'SKT_C12 B start with Ming Hui');
  b_len := pg_temp.rule(kb, zh, 'skt_c12_style', 'length', 'SKT_C12 B short Chinese');
  b_emoji := pg_temp.rule(kb, null, 'skt_c12_style', 'emoji', 'SKT_C12 B no emoji');
  ma := pg_temp.fin(ka, 'SKT_C12 Bro, dinner at 8?', en, 'whatsapp');
  mb1 := pg_temp.fin(kb, 'SKT_C12 明辉，明天见', zh, 'whatsapp');
  mb2 := pg_temp.fin(kb, 'SKT_C12 wrong message', en, 'whatsapp');
  perform lifeos.communication_message_history_delete((mb2 -> 'message' ->> 'id')::uuid);
  -- step 1: each Subject's Person Profile
  perform pg_temp.chk(lifeos.subject_read(a) ->> 'person_profile_id' = ka::text and lifeos.subject_read(b) ->> 'person_profile_id' = kb::text, 'both Subjects name their Person Profile');
  -- step 2: read each Profile; parent_profiles lists its Audience memberships
  rda := lifeos.communication_profile_read(ka);
  rdb := lifeos.communication_profile_read(kb);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(rdb -> 'parent_profiles') x where x ->> 'profile_id' = fam::text), 'the merged Profile shows its family membership');
  -- steps 3 to 5: read language_modes, then each Profile's own Rules without and with each Language Mode
  perform pg_temp.chk(en = any (pg_temp.nb_values('language_modes')) and zh = any (pg_temp.nb_values('language_modes')), 'both Language Modes are Notebook values');
  own_a := pg_temp.own_rules(ka);
  own_b := pg_temp.own_rules(kb);
  perform pg_temp.chk(jsonb_array_length(own_a) = 2 and jsonb_array_length(own_b) = 3, 'own Rules: 2 and 3, got ' || own_a::text || ' / ' || own_b::text);
  perform pg_temp.chk(pg_temp.cnt(own_b, (b_len ->> 'id')::uuid) = 1 and pg_temp.cnt(own_a, (a_len ->> 'id')::uuid) = 1, 'the language-specific Rules are found through the Notebook values');
  -- step 6: recent finalized messages of each Profile
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', ka)) ->> 'returned_count')::integer = 1
                      and (lifeos.communication_message_history_search(jsonb_build_object('profile_id', kb)) ->> 'returned_count')::integer = 1, 'one active recent message each');
  -- steps 7 and 8: both Profiles are shown; the user keeps Ah Kow's Profile (Agent steps)
  -- step 9: a conflict is the same Language Mode, dimension and rule_key; a neutral Rule conflicts only with a neutral Rule
  conflicts := coalesce((select jsonb_agg(jsonb_build_object('kept', x ->> 'id', 'merged', y ->> 'id'))
                         from jsonb_array_elements(own_a) x join jsonb_array_elements(own_b) y
                           on x ->> 'dimension' = y ->> 'dimension' and x ->> 'rule_key' = y ->> 'rule_key'
                          and (x ->> 'language_mode') is not distinct from (y ->> 'language_mode')), '[]'::jsonb);
  perform pg_temp.chk(conflicts = jsonb_build_array(jsonb_build_object('kept', a_greet ->> 'id', 'merged', b_greet ->> 'id')),
                      'one conflict, the neutral greeting; length in two Language Modes is none, got ' || conflicts::text);
  -- Contract guard (communication-assistant.md 8.1.8 item 4), not a Skill step: with the conflict open nothing moves
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', ka, 'merge_id', kb)), 'invalid relationship');
  perform pg_temp.chk(jsonb_array_length(pg_temp.own_rules(kb)) = 3 and lifeos.communication_profile_read(kb) ->> 'deleted_at' is null, 'the rejected merge moved no Rule and kept the Profile');
  -- step 10: the user chooses the merged Profile's greeting Rule (Agent step)
  -- step 11: delete the other Rule of the conflict
  perform pg_temp.chk((lifeos.communication_rule_delete((a_greet ->> 'id')::uuid) ->> 'removed')::boolean, 'the Rule not chosen is deleted');
  -- step 12: keep the identity details of the merged Profile as aliases, supplying the whole array
  kept := lifeos.communication_profile_update(ka, jsonb_build_object('aliases', (rda -> 'aliases') || jsonb_build_array(rdb ->> 'name') || (rdb -> 'aliases')));
  perform pg_temp.chk(kept -> 'aliases' = '["SKT_C12 Kow", "SKT_C12 Ming Hui", "SKT_C12 MH"]'::jsonb, 'the kept Profile keeps every name, got ' || (kept -> 'aliases')::text);
  -- step 13: the family membership still applies, so the kept Profile gets it
  perform lifeos.communication_profile_membership_set(ka, fam, 2);
  -- steps 14 to 16
  mg := lifeos.communication_profile_merge(jsonb_build_object('keep_id', ka, 'merge_id', kb));
  perform pg_temp.chk(mg -> 'profile' ->> 'id' = ka::text and mg ->> 'merged_id' = kb::text and mg ->> 'deleted_at' is not null, 'the merged Profile is deleted');
  perform pg_temp.chk((mg -> 'moved' ->> 'rules')::integer = 3 and (mg -> 'moved' ->> 'messages')::integer = 2, 'three Rules and two messages moved, the deleted one too, got ' || (mg -> 'moved')::text);
  -- outcome: one Person Profile holds the Rules and Message History of both
  own_a := pg_temp.own_rules(ka);
  perform pg_temp.chk(jsonb_array_length(own_a) = 4 and pg_temp.cnt(own_a, (b_greet ->> 'id')::uuid) = 1 and pg_temp.cnt(own_a, (a_greet ->> 'id')::uuid) = 0
                      and pg_temp.cnt(own_a, (b_emoji ->> 'id')::uuid) = 1 and pg_temp.cnt(own_a, (b_len ->> 'id')::uuid) = 1 and pg_temp.cnt(own_a, (a_len ->> 'id')::uuid) = 1,
                      'the kept Profile has the chosen greeting and every other Rule, got ' || own_a::text);
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(ka, zh), 'skt_c12_tone', 'greeting') = 'SKT_C12 B start with Ming Hui'
                      and pg_temp.eff(lifeos.communication_resolve(ka, zh), 'skt_c12_style', 'length') = 'SKT_C12 B short Chinese'
                      and pg_temp.eff(lifeos.communication_resolve(ka, en), 'skt_c12_style', 'length') = 'SKT_C12 A one line in English', 'the moved Rules apply to the kept Profile');
  st := lifeos.communication_message_history_search(jsonb_build_object('profile_id', ka));
  perform pg_temp.chk((st ->> 'returned_count')::integer = 2 and pg_temp.cnt(st -> 'results', (ma -> 'message' ->> 'id')::uuid) = 1
                      and pg_temp.cnt(st -> 'results', (mb1 -> 'message' ->> 'id')::uuid) = 1, 'both active messages are in the kept Message History');
  perform pg_temp.chk(lifeos.communication_message_history_read((mb2 -> 'message' ->> 'id')::uuid) ->> 'profile_id' = ka::text
                      and lifeos.communication_message_history_read((mb2 -> 'message' ->> 'id')::uuid) ->> 'deleted_at' is not null, 'the deleted message moved and stays deleted');
  rda := lifeos.communication_profile_read(ka);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(rda -> 'parent_profiles') x where x ->> 'profile_id' = fam::text)
                      and exists (select 1 from jsonb_array_elements(rda -> 'parent_profiles') x where x ->> 'profile_id' = wrk::text), 'the kept Profile has both memberships');
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_profile_search('{"keyword": "SKT_C12 MH"}'::jsonb) -> 'results', ka) = 1
                      and pg_temp.cnt(lifeos.communication_profile_search('{"keyword": "SKT_C12 MH"}'::jsonb) -> 'results', kb) = 0, 'the merged names find the kept Profile only');
  perform pg_temp.expect_err(format('select lifeos.communication_resolve(%s)', pg_temp.q(kb)), 'record deleted');
  -- step 18: back to the entry Skill Section 8, which runs subject_merge
  r := lifeos.subject_merge(jsonb_build_object('keep_id', a, 'merge_id', b, 'identity', jsonb_build_object('name', 'SKT_C12 Ah Kow', 'aliases', jsonb_build_array('SKT_C12 Kow Ming Hui'))));
  perform pg_temp.chk(r -> 'subject' ->> 'person_profile_id' = ka::text and lifeos.subject_read(b) ->> 'merged_into_id' = a::text, 'the Subject merge follows and keeps the kept Profile');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 13. Section 4 steps 13 to 18: the Agent sets up, changes and removes Group and Audience Profiles by itself ----
-- No step in this flow asks the user: the Agent decides each Group, Audience and membership without approval.
do $t$
declare t constant text := 'group_and_audience_profiles_set_up_changed_and_removed_without_approval';
  s uuid := pg_temp.mk_subject('SKT_C13 Faizal', 'person'); per uuid; grp jsonb; aud jsonb; m jsonb; u jsonb;
begin
  per := pg_temp.mk_profile('skt-c13-faizal', 'person', s);
  -- steps 13 to 15: a hiking group and an outdoor audience are useful, so the Agent creates them
  grp := lifeos.communication_profile_create('{"profile_key": "skt-c13-hiking", "profile_type": "group", "name": "SKT_C13 Hiking group"}'::jsonb);
  aud := lifeos.communication_profile_create('{"profile_key": "skt-c13-outdoor", "profile_type": "audience", "name": "SKT_C13 Outdoor friends"}'::jsonb);
  perform pg_temp.chk(grp ->> 'profile_type' = 'group' and grp ->> 'person_subject_id' is null and aud ->> 'profile_type' = 'audience', 'the Group and the Audience exist');
  perform pg_temp.rule((aud ->> 'id')::uuid, null, 'skt_c13_tone', 'register', 'SKT_C13 relaxed');
  -- steps 16 and 17: both inherit from the Audience
  perform lifeos.communication_profile_membership_set((grp ->> 'id')::uuid, (aud ->> 'id')::uuid, 1);
  m := lifeos.communication_profile_membership_set(per, (aud ->> 'id')::uuid, 0);
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve((grp ->> 'id')::uuid, null), 'skt_c13_tone', 'register') = 'SKT_C13 relaxed'
                      and pg_temp.eff(lifeos.communication_resolve(per, null), 'skt_c13_tone', 'register') = 'SKT_C13 relaxed', 'the Group and the Person inherit the Audience Rule');
  -- step 14: changes by the Agent: the Group description and the membership priority
  u := lifeos.communication_profile_update((grp ->> 'id')::uuid, '{"description": "SKT_C13 Sunday hikers"}'::jsonb);
  perform pg_temp.chk(u ->> 'description' = 'SKT_C13 Sunday hikers', 'the Group is changed');
  m := lifeos.communication_profile_membership_set(per, (aud ->> 'id')::uuid, 3);
  perform pg_temp.chk((m ->> 'priority')::integer = 3 and (lifeos.communication_profile_read(per) -> 'parent_profiles' -> 0 ->> 'priority')::integer = 3, 'the membership priority is changed');
  -- step 18: the Person no longer inherits
  perform pg_temp.chk((lifeos.communication_profile_membership_remove(per, (aud ->> 'id')::uuid) ->> 'removed')::boolean, 'the membership is removed');
  perform pg_temp.chk(lifeos.communication_profile_read(per) -> 'parent_profiles' = '[]'::jsonb and pg_temp.eff(lifeos.communication_resolve(per, null), 'skt_c13_tone', 'register') is null, 'the Person inherits nothing');
  -- step 14: the Agent removes the Audience it no longer finds useful
  perform lifeos.communication_profile_delete((aud ->> 'id')::uuid);
  perform pg_temp.chk((lifeos.communication_profile_search('{"keyword": "skt-c13-outdoor"}'::jsonb) ->> 'returned_count')::integer = 0
                      and lifeos.communication_profile_read((grp ->> 'id')::uuid) -> 'parent_profiles' = '[]'::jsonb, 'the Audience is gone and the Group no longer lists it');
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_profile_search('{"profile_type": "group", "keyword": "SKT_C13"}'::jsonb) -> 'results', (grp ->> 'id')::uuid) = 1, 'the Group stays');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 14. Section 11 Rule changes outside a message: the Agent decides the scope and saves without confirmation ------
do $t$
declare t constant text := 'rule_added_changed_and_removed_outside_a_message_without_confirmation';
  s uuid := pg_temp.mk_subject('SKT_C14 Daniel', 'person'); per uuid; en text; st jsonb; g jsonb; g2 jsonb; pr jsonb; d jsonb;
begin
  per := pg_temp.mk_profile('skt-c14-daniel', 'person', s);
  -- request 1: "always end my messages with Cheers" holds for everyone: Global scope (steps 1, 2 and 9)
  st := lifeos.communication_rule_state(null, null);
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(st -> 'rules') x where x ->> 'dimension' = 'skt_c14_closing'), 'step 6: no current Rule decides the matter yet');
  g := lifeos.communication_rule_upsert('{"dimension": "skt_c14_closing", "rule_key": "sign_off", "rule_text": "SKT_C14 end with Cheers"}'::jsonb);
  perform pg_temp.chk(g ->> 'action' = 'created' and g ->> 'profile_id' is null and g ->> 'language_mode' is null, 'a Global, neutral Rule is created');
  -- request 2: "for Daniel in English, no sign-off": Person scope, one Language Mode from the Notebook (steps 3 to 8)
  en := pg_temp.nb_value('language_modes', 'skt_c14_en');
  st := lifeos.communication_rule_state(per, en);
  -- step 7: reuse the dimension and rule_key of the existing Rule that decides the same matter
  pr := lifeos.communication_rule_upsert(jsonb_build_object('profile_id', per, 'language_mode', en,
          'dimension', (select x ->> 'dimension' from jsonb_array_elements(st -> 'rules') x where x ->> 'id' = g ->> 'id'),
          'rule_key', (select x ->> 'rule_key' from jsonb_array_elements(st -> 'rules') x where x ->> 'id' = g ->> 'id'), 'rule_text', 'SKT_C14 no sign-off'));
  perform pg_temp.chk(pr ->> 'action' = 'created' and pr ->> 'profile_id' = per::text and pr ->> 'dimension' = 'skt_c14_closing' and pr ->> 'rule_key' = 'sign_off', 'the narrow exception reuses dimension and rule_key');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(per, en), 'skt_c14_closing', 'sign_off') = 'SKT_C14 no sign-off'
                      and pg_temp.eff(lifeos.communication_resolve(per, null), 'skt_c14_closing', 'sign_off') = 'SKT_C14 end with Cheers', 'the exception applies to English only');
  -- request 3: change the Global Rule: step 8 updates the same Rule
  g2 := lifeos.communication_rule_upsert('{"dimension": "skt_c14_closing", "rule_key": "sign_off", "rule_text": "SKT_C14 end with Cheers and my name"}'::jsonb);
  perform pg_temp.chk(g2 ->> 'action' = 'updated' and g2 ->> 'id' = g ->> 'id' and g2 ->> 'rule_text' = 'SKT_C14 end with Cheers and my name', 'the Global Rule keeps its ID and takes the new text');
  -- request 4: remove the exception: step 10
  d := lifeos.communication_rule_delete((pr ->> 'id')::uuid);
  perform pg_temp.chk((d ->> 'removed')::boolean, 'the Person Rule is removed');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(per, en), 'skt_c14_closing', 'sign_off') = 'SKT_C14 end with Cheers and my name', 'the Global Rule applies again');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lifeos.communication_rule_state(per, en) -> 'rules') x where x ->> 'scope' = 'profile'), 'the Person has no own Rule left');
  -- outcome: the changes were saved outside a message, so the Profile has no Message History
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', per)) ->> 'returned_count')::integer = 0, 'no message is saved with a Rule change');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 15. Section 8 step 3: the conversation ends without NEW MESSAGE or approval; nothing is saved for the message ---
do $t$
declare t constant text := 'send_ready_message_unfinalized_at_conversation_end_saves_nothing';
  s uuid := pg_temp.mk_subject('SKT_C15 Mei', 'person'); p uuid; en text; wa text; r0 jsonb; m0 jsonb; rc jsonb; gs jsonb; hs jsonb; st jsonb; g jsonb;
begin
  en := pg_temp.nb_value('language_modes', 'skt_c15_en');
  wa := pg_temp.nb_value('platforms', 'skt_c15_whatsapp');
  p := pg_temp.mk_profile('skt-c15-mei', 'person', s);
  r0 := pg_temp.rule(p, null, 'skt_c15_tone', 'warmth', 'SKT_C15 warm');
  m0 := pg_temp.fin(p, 'SKT_C15 Thanks Mei, see you Friday', en, wa);
  -- Section 7 step 1: the drafting context
  rc := lifeos.communication_runtime_context(p, en, wa);
  perform pg_temp.chk(jsonb_array_length(rc -> 'recent_messages') = 1 and pg_temp.cnt(rc -> 'recent_messages', (m0 -> 'message' ->> 'id')::uuid) = 1, 'one earlier finalized example');
  -- Section 7 steps 6 to 10: draft "SKT_C15 Hi Mei, can we move to Saturday?" and revise it after "shorter please" (Agent steps)
  -- Section 7 steps 13 and 14: the final check reads the Global scope Rules
  g := pg_temp.rule(null, null, 'skt_c15_closing', 'sign_off', 'SKT_C15 G sign-off');
  gs := lifeos.communication_rule_state(null, en);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(gs -> 'rules') x where x ->> 'id' = g ->> 'id' and x ->> 'scope' = 'global') and not exists (select 1 from jsonb_array_elements(gs -> 'rules') x where x ->> 'scope' <> 'global'), 'the final check reads the Global scope Rules only, got ' || gs::text);
  -- Section 8 step 3: the conversation ends without NEW MESSAGE or approval: no communication_message_finalize call
  -- outcome: the stored Message History and Rules are as before the draft
  hs := lifeos.communication_message_history_search(jsonb_build_object('profile_id', p));
  perform pg_temp.chk((hs ->> 'returned_count')::integer = 1 and hs -> 'results' -> 0 ->> 'id' = m0 -> 'message' ->> 'id', 'the Profile holds only the earlier finalized message, got ' || hs::text);
  perform pg_temp.chk(jsonb_array_length(lifeos.communication_runtime_context(p, en, wa) -> 'recent_messages') = 1, 'the unfinalized message is no example');
  st := pg_temp.own_rules(p);
  perform pg_temp.chk(jsonb_array_length(st) = 1 and st -> 0 ->> 'id' = r0 ->> 'id' and st -> 0 ->> 'rule_text' = 'SKT_C15 warm', 'the draft feedback became no Rule, got ' || st::text);
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 16. Sections 6, 8 and 9: Language Mode and Platform values come from the Notebooks and are reused ----------------
do $t$
declare t constant text := 'language_mode_and_platform_values_reused_from_notebooks';
  s uuid := pg_temp.mk_subject('SKT_C16 Ah Seng', 'person'); p uuid; lm jsonb; pf jsonb; v1 text; v2 text; w1 text; w2 text;
  before text; m1 jsonb; m2 jsonb; rc jsonb; hs jsonb;
begin
  p := pg_temp.mk_profile('skt-c16-ah-seng', 'person', s);
  -- Section 6 steps 2 to 4: read language_modes; no value fits Manglish, so the Agent adds it as the full new content
  lm := lifeos.notebook_read('language_modes');
  perform pg_temp.chk(lm ->> 'name' = 'Language Modes', 'the catalog Notebook language_modes is read');
  perform pg_temp.chk(not ('skt_c16_manglish' = any (pg_temp.nb_values('language_modes'))), 'no fitting value yet');
  v1 := pg_temp.nb_value('language_modes', 'skt_c16_manglish');
  perform pg_temp.chk(v1 = any (pg_temp.nb_values('language_modes')), 'the new value is in the Notebook');
  -- Section 6 steps 7 to 9: the same for platforms
  pf := lifeos.notebook_read('platforms');
  perform pg_temp.chk(pf ->> 'name' = 'Platforms', 'the catalog Notebook platforms is read');
  w1 := pg_temp.nb_value('platforms', 'skt_c16_whatsapp');
  -- Section 8 steps 10 and 11: the message is finalized with the Notebook values
  m1 := pg_temp.fin(p, 'SKT_C16 Eh bro, jom makan', v1, w1);
  perform pg_temp.chk(m1 -> 'message' ->> 'language_mode' = v1 and m1 -> 'message' ->> 'platform' = w1, 'the message stores the Notebook values');
  -- the next message in the same language on the same app: the existing values fit, so they are reused
  before := lifeos.notebook_read('language_modes') ->> 'content';
  v2 := pg_temp.nb_value('language_modes', 'skt_c16_manglish');
  w2 := pg_temp.nb_value('platforms', 'skt_c16_whatsapp');
  perform pg_temp.chk(lifeos.notebook_read('language_modes') ->> 'content' = before, 'a reused value leaves the Notebook unchanged');
  perform pg_temp.chk(array_length(array_positions(pg_temp.nb_values('language_modes'), v2), 1) = 1
                      and array_length(array_positions(pg_temp.nb_values('platforms'), w2), 1) = 1, 'each value is stored once');
  -- a Rule in that Language Mode (Section 8 step 9), then the second message
  m2 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', p, 'message_text', 'SKT_C16 Ok lah, see you', 'language_mode', v2, 'platform', w2,
          'rule_changes', jsonb_build_array(jsonb_build_object('action', 'upsert', 'profile_id', p, 'language_mode', v2, 'dimension', 'skt_c16_tone', 'rule_key', 'particles', 'rule_text', 'SKT_C16 use lah'))));
  -- outcome: Rule resolution and examples match the stored values
  rc := lifeos.communication_runtime_context(p, v1, w1);
  perform pg_temp.chk(pg_temp.eff(rc, 'skt_c16_tone', 'particles') = 'SKT_C16 use lah' and jsonb_array_length(rc -> 'recent_messages') = 2, 'the Rule and both examples match the reused value');
  -- Section 9 step 1: the search uses the Notebook values
  hs := lifeos.communication_message_history_search(jsonb_build_object('profile_id', p, 'language_mode', v1, 'platform', w1));
  perform pg_temp.chk((hs ->> 'returned_count')::integer = 2, 'both messages are found by the Notebook values');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
