-- =============================================================================
-- tests/skills/divination-reflection.sql -- Skill flow tests: skills/divination-reflection/SKILL.md
-- Divination & Reflection: Story intake, Storybook, Reading save, later Analyses, retrieval, Reading Remarks. Contract: divination-reflection.md, shared.md.
-- Each test follows the database steps of one Skill flow, in the Skill's order, through the Contract
-- functions, and asserts the outcome that the Skill and the Knowledge Base state.
--
-- Tests in this file:
--    1. story_intake_finds_story_persons_storylines_and_earlier_readings
--    2. multi_person_storylines_shared_subgroup_and_individual
--    3. storyline_timing_known_dates_relative_order_and_unknown
--    4. storybook_saved_on_approval
--    5. reading_saved_once_per_session_with_analyses_story_persons_and_links
--    6. later_option_added_as_new_reading_earlier_reading_unchanged
--    7. later_outside_analysis_added_with_source_under_reading_date
--    8. wrong_reading_or_analysis_deleted_and_added_again
--    9. past_reading_short_view_first_full_view_on_request
--   10. reading_remark_after_storyline_save_add_correct_and_remove
--   11. reading_story_persons_changed_after_approval_not_an_edit
--   12. meihua_round_saved_as_second_separate_analysis_at_save_time
--   13. meihua_round_for_saved_reading_added_later_with_analysis_add
--   14. end_signal_cutoff_saved_on_approval_silent_stop_saves_nothing
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

create function pg_temp.mk_sp(p_name text, p_subject uuid default null) returns uuid language sql as
$f$ select ((lifeos.story_person_create(jsonb_build_object('name', p_name, 'subject_id', p_subject)))->>'id')::uuid $f$;

-- One Reading with one Analysis, saved as a session (divination-reflection.md 7.1.1).
create function pg_temp.mk_reading(p_question text, p_date date, p_sps jsonb default '[]'::jsonb) returns jsonb language sql as
$f$ select lifeos.divination_record_save(jsonb_build_object('session_date', p_date, 'title', p_question,
     'readings', jsonb_build_array(jsonb_build_object('question', p_question, 'method', 'tarot', 'spread_name', '关键阵占卜',
       'result_text', E'1. 关键：Six of Cups (upright)\n2. 重点：Two of Swords (reversed)\n3. 前方：The Star (upright)',
       'story_person_ids', p_sps,
       'analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT outcome', 'key_reasoning', 'SKT reasoning')))))) $f$;

-- 1. Section 4 Story intake: Story Persons, earlier Storylines and earlier Readings ---------------------
do $t$
declare t constant text := 'story_intake_finds_story_persons_storylines_and_earlier_readings';
  sp uuid; sl jsonb; d jsonb; r jsonb;
begin
  sp := (lifeos.story_person_create('{"name": "SKT_D1 Mei Ling", "gender": "female", "description": "SKT_D1 colleague from Penang", "aliases": ["SKT_D1 ML"]}'::jsonb) ->> 'id')::uuid;
  sl := lifeos.storyline_create(jsonb_build_object('title', 'SKT_D1 Mei Ling changed teams', 'content', 'SKT_D1 She moved to the audit team', 'occurrence_date', '2032-01-10', 'story_person_ids', jsonb_build_array(sp)));
  d := pg_temp.mk_reading('SKT_D1 How will my work with Mei Ling develop?', '2032-01-12', jsonb_build_array(sp));
  -- step 3: names, aliases and clues
  perform pg_temp.chk(pg_temp.cnt(lifeos.story_person_search('{"keyword": "SKT_D1 ML"}'::jsonb) -> 'results', sp) = 1, 'found by Alias');
  perform pg_temp.chk(pg_temp.cnt(lifeos.story_person_search('{"keyword": "SKT_D1 colleague from Penang", "gender": "female"}'::jsonb) -> 'results', sp) = 1, 'found by an identifying clue and gender');
  -- step 4
  r := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(sp)));
  perform pg_temp.chk(pg_temp.cnt(r -> 'results', (sl ->> 'id')::uuid) = 1 and pg_temp.find(r -> 'results', (sl ->> 'id')::uuid) -> 'matched_person_ids' = jsonb_build_array(sp), 'the earlier Storyline is found through the confirmed person');
  -- step 10: earlier Readings of the confirmed person
  r := lifeos.divination_search(jsonb_build_object('story_person_id', sp));
  perform pg_temp.chk(pg_temp.cnt(r -> 'results', (d ->> 'id')::uuid) = 1, 'the earlier Reading is recognised');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Section 4 steps 7 and 8: several persons; shared, subgroup and individual Storylines ---------------
do $t$
declare t constant text := 'multi_person_storylines_shared_subgroup_and_individual';
  a uuid := pg_temp.mk_sp('SKT_D2 Ali'); b uuid := pg_temp.mk_sp('SKT_D2 Bala'); c uuid := pg_temp.mk_sp('SKT_D2 Chong');
  abc jsonb; ab jsonb; oa jsonb; r jsonb; al jsonb;
begin
  abc := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D2 the three opened a cafe', 'story_person_ids', jsonb_build_array(a, b, c)));
  ab := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D2 Ali and Bala argued about money', 'story_person_ids', jsonb_build_array(a, b)));
  oa := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D2 Ali grew up in Kedah', 'story_person_ids', jsonb_build_array(a)));
  r := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a, b, c)));
  perform pg_temp.chk(jsonb_array_length(pg_temp.find(r -> 'results', (abc ->> 'id')::uuid) -> 'matched_person_ids') = 3, 'shared Storyline: all three matched');
  perform pg_temp.chk(jsonb_array_length(pg_temp.find(r -> 'results', (ab ->> 'id')::uuid) -> 'matched_person_ids') = 2, 'subgroup Storyline: two matched');
  perform pg_temp.chk(pg_temp.find(r -> 'results', (oa ->> 'id')::uuid) -> 'matched_person_ids' = jsonb_build_array(a), 'individual background: one matched');
  al := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a, b), 'person_match', 'all'));
  perform pg_temp.chk(pg_temp.cnt(al -> 'results', (abc ->> 'id')::uuid) = 1 and pg_temp.cnt(al -> 'results', (ab ->> 'id')::uuid) = 1 and pg_temp.cnt(al -> 'results', (oa ->> 'id')::uuid) = 0, 'person_match all keeps the directly shared Storylines');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Section 5 Storyline identity and timing ----------------------------------------------------------
do $t$
declare t constant text := 'storyline_timing_known_dates_relative_order_and_unknown';
  sp uuid := pg_temp.mk_sp('SKT_D3 Farah'); p jsonb; same jsonb; rel jsonb; f jsonb; u jsonb;
begin
  -- step 5: a known period
  p := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D3 Farah''s family trip', 'occurrence_date', '2032-02-01', 'occurrence_end_date', '2032-02-03', 'story_person_ids', jsonb_build_array(sp)));
  perform pg_temp.chk(p ->> 'occurrence_date' = '2032-02-01' and p ->> 'occurrence_end_date' = '2032-02-03', 'the period is kept');
  -- step 8: the end is never before the start; the same day is allowed
  perform pg_temp.expect_err(format('select lifeos.storyline_create(%L::jsonb)', jsonb_build_object('content', 'SKT_D3 bad dates', 'occurrence_date', '2032-02-05', 'occurrence_end_date', '2032-02-04')), 'invalid input');
  same := lifeos.storyline_create('{"content": "SKT_D3 one-day event", "occurrence_date": "2032-02-10", "occurrence_end_date": "2032-02-10"}'::jsonb);
  perform pg_temp.chk(same ->> 'occurrence_end_date' = '2032-02-10', 'the same day is allowed');
  -- steps 6 and 7: relative order in time_text, unknown dates stay unknown
  rel := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D3 Farah quarrelled with her brother', 'time_text', 'before the wedding', 'story_person_ids', jsonb_build_array(sp)));
  perform pg_temp.chk(rel ->> 'time_text' = 'before the wedding' and rel ->> 'occurrence_date' is null and rel ->> 'occurrence_end_date' is null, 'relative order kept, no invented date');
  f := lifeos.storyline_search('{"keyword": "SKT_D3", "from_date": "2032-02-01", "to_date": "2032-02-28"}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(f -> 'results', (rel ->> 'id')::uuid) = 0 and pg_temp.cnt(f -> 'results', (p ->> 'id')::uuid) = 1, 'an unknown date does not match a date filter');
  perform pg_temp.chk(pg_temp.cnt(lifeos.storyline_search('{"keyword": "SKT_D3"}'::jsonb) -> 'results', (rel ->> 'id')::uuid) = 1, 'without a date filter the undated Storyline is found');
  -- outcome kind 2: a corrected account replaces content; the date rule holds after the change
  u := lifeos.storyline_update((p ->> 'id')::uuid, '{"content": "SKT_D3 Farah''s family trip to Langkawi", "occurrence_end_date": "2032-02-04"}'::jsonb);
  perform pg_temp.chk(u ->> 'content' like '%Langkawi' and u ->> 'occurrence_end_date' = '2032-02-04', 'the corrected account replaces the content');
  perform pg_temp.expect_err(format($$select lifeos.storyline_update(%s, '{"occurrence_end_date": "2032-01-31"}'::jsonb)$$, pg_temp.q((p ->> 'id')::uuid)), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Section 6 Storybook save at the cutoff: the approved save ------------------------
do $t$
declare t constant text := 'storybook_saved_on_approval';
  s uuid := pg_temp.mk_subject('SKT_D4 Jason', 'person'); s3 uuid := pg_temp.mk_subject('SKT_D4 Kevin', 'person');
  sp1 jsonb; sp2 jsonb; sp3 uuid; u jsonb; sl jsonb; sl2 jsonb; e jsonb; rd jsonb;
begin
  sp3 := pg_temp.mk_sp('SKT_D4 Kevin from school');
  -- approved: steps 5 and 6, with and without an approved Subject association
  sp1 := lifeos.story_person_create(jsonb_build_object('name', 'SKT_D4 Jason', 'gender', 'male', 'description', 'SKT_D4 neighbour', 'subject_id', s));
  sp2 := lifeos.story_person_create('{"name": "SKT_D4 Jason''s wife", "gender": "female"}'::jsonb);
  perform pg_temp.chk(sp1 ->> 'subject_id' = s::text and sp2 ->> 'subject_id' is null, 'the Subject association only where approved');
  -- step 7: an approved change, including a new Subject association
  u := lifeos.story_person_update(sp3, jsonb_build_object('subject_id', s3, 'aliases', jsonb_build_array('SKT_D4 KV')));
  perform pg_temp.chk(u ->> 'subject_id' = s3::text and u -> 'aliases' = '["SKT_D4 KV"]'::jsonb, 'the existing Story Person is updated');
  -- step 8
  sl := lifeos.storyline_create(jsonb_build_object('title', 'SKT_D4 housewarming', 'content', 'SKT_D4 Jason and his wife held a housewarming',
          'occurrence_date', '2032-03-05', 'story_person_ids', jsonb_build_array(sp1 ->> 'id', sp2 ->> 'id')));
  perform pg_temp.chk(jsonb_array_length(sl -> 'story_person_ids') = 2, 'the Storyline holds both Story Persons');
  -- step 9: added details to the confirmed Storyline
  sl2 := lifeos.storyline_update((sl ->> 'id')::uuid, jsonb_build_object('content', (sl ->> 'content') || '. SKT_D4 They announced a baby.'));
  perform pg_temp.chk(sl2 ->> 'content' like '%announced a baby.', 'details added, latest content kept');
  -- step 11: the user's Personal Event of the same matter
  e := lifeos.event_create('{"title": "SKT_D4 went to Jason''s housewarming", "occurred_date": "2032-03-05"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'storyline', 'from_id', sl ->> 'id', 'to_type', 'event', 'to_id', e ->> 'id'));
  rd := lifeos.storyline_read((sl ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(rd -> 'links', (e ->> 'id')::uuid) = 1, 'the Storyline links to the Personal Event');
  perform pg_temp.chk(pg_temp.cnt(lifeos.subject_records(s, '{"record_types": ["storyline"]}'::jsonb) -> 'results', (sl ->> 'id')::uuid) = 1, 'the Subject reaches the Storyline through its Story Person');
  -- a declined save makes no call (Agent step), so it has no database result to check
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Section 11 Reading save: one Divination Record per session -----------------------------------------
do $t$
declare t constant text := 'reading_saved_once_per_session_with_analyses_story_persons_and_links';
  s uuid := pg_temp.mk_subject('SKT_D5 Amy', 'person'); sp uuid; sl jsonb; e jsonb; d jsonb; r1 jsonb; r2 jsonb; tarot text; iching text; rec jsonb;
begin
  sp := pg_temp.mk_sp('SKT_D5 Amy', s);
  tarot := E'1. 关键：Three of Pentacles (upright)\n2. 重点：Page of Cups (reversed)\n3. 前方：Ten of Wands (upright)';
  iching := E'本卦：地天泰\n动爻：九三\n变卦：地泽临';
  -- steps 3 to 10
  d := lifeos.divination_record_save(jsonb_build_object('session_date', '2032-04-02', 'title', 'SKT_D5 job offers', 'topic', 'career',
         'readings', jsonb_build_array(
           jsonb_build_object('question', 'SKT_D5 If I accept offer A, how will my career develop in one year?', 'method', 'tarot', 'spread_name', '关键阵占卜',
             'result_text', tarot, 'reading_time', '21:15', 'story_person_ids', jsonb_build_array(sp),
             'analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D5 steady growth', 'key_reasoning', 'SKT_D5 Three of Pentacles shows teamwork',
               'story_context', 'SKT_D5 Amy is the hiring manager'))),
           jsonb_build_object('question', 'SKT_D5 If I accept offer B, how will my career develop in one year?', 'method', 'i_ching', 'result_text', iching,
             'analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D5 good start, later pressure', 'key_reasoning', 'SKT_D5 Tai turning to Lin')))),
         'record_analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D5 offer A aligns better', 'key_reasoning', 'SKT_D5 comparison against the objective'))));
  r1 := d -> 'readings' -> 0; r2 := d -> 'readings' -> 1;
  perform pg_temp.chk(jsonb_array_length(d -> 'readings') = 2 and r1 ->> 'reading_date' = '2032-04-02', 'one Divination Record holds both Readings of the session');
  perform pg_temp.chk(r1 ->> 'result_text' = tarot and r2 ->> 'result_text' = iching, 'step 4: each Result text is kept whole');
  perform pg_temp.chk(jsonb_array_length(r1 -> 'analyses') = 1 and r1 -> 'analyses' -> 0 ->> 'source' = 'Claude' and r1 -> 'analyses' -> 0 ->> 'story_context' = 'SKT_D5 Amy is the hiring manager', 'step 5 and 7: one sourced Analysis per Reading with Story Context');
  perform pg_temp.chk(jsonb_array_length(d -> 'record_analyses') = 1 and d -> 'record_analyses' -> 0 ->> 'reading_id' is null, 'step 8: the shared Analysis is stored once');
  perform pg_temp.chk(r1 -> 'story_person_ids' = jsonb_build_array(sp) and r2 -> 'story_person_ids' = '[]'::jsonb, 'step 9: each Reading has its confirmed Story Persons');
  -- step 11: the Reading's Subject comes through its Story Person, with no link call
  rec := lifeos.subject_records(s, '{"record_types": ["reading"]}'::jsonb);
  perform pg_temp.chk(pg_temp.find(rec -> 'results', (r1 ->> 'id')::uuid) ->> 'via' = 'story_person_subject', 'the Subject reaches the Reading via story_person_subject');
  perform pg_temp.chk(pg_temp.cnt(lifeos.divination_search(jsonb_build_object('subject_id', s)) -> 'results', (d ->> 'id')::uuid) = 1, 'divination_search by Subject finds the session');
  -- step 12: the corresponding Personal Event
  e := lifeos.event_create('{"title": "SKT_D5 interview for offer A", "occurred_date": "2032-04-01"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'reading', 'from_id', r1 ->> 'id', 'to_type', 'event', 'to_id', e ->> 'id'));
  perform pg_temp.chk(pg_temp.cnt(lifeos.record_links_read('reading', (r1 ->> 'id')::uuid) -> 'links', (e ->> 'id')::uuid) = 1, 'the Reading links to the Personal Event');
  -- rule 8: no structured link to a Storyline
  sl := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D5 Amy called with offer A', 'story_person_ids', jsonb_build_array(sp)));
  perform pg_temp.expect_err(format('select lifeos.record_link_create(%L::jsonb)', jsonb_build_object('from_type', 'reading', 'from_id', r1 ->> 'id', 'to_type', 'storyline', 'to_id', sl ->> 'id')), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.record_link_create(%L::jsonb)', jsonb_build_object('from_type', 'storyline', 'from_id', sl ->> 'id', 'to_type', 'divination_record', 'to_id', d ->> 'id')), 'invalid relationship');
  -- a declined save makes no call (Agent step), so it has no database result to check
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Section 11 step 13: a later or revised option is a new Reading of the same Divination Record --------
do $t$
declare t constant text := 'later_option_added_as_new_reading_earlier_reading_unchanged';
  d jsonb; r0 jsonb; nr jsonb; full_rec jsonb; earlier_rec jsonb;
begin
  d := pg_temp.mk_reading('SKT_D6 If I move to Penang, how will my finances develop?', '2032-04-05');
  r0 := d -> 'readings' -> 0;
  nr := lifeos.reading_create(jsonb_build_object('divination_record_id', d ->> 'id', 'question', 'SKT_D6 If I move to Johor instead, how will my finances develop?',
          'method', 'i_ching', 'result_text', E'本卦：水雷屯\n静爻', 'reading_date', '2032-04-08',
          'analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D6 slow start', 'key_reasoning', 'SKT_D6 Zhun is difficulty at the beginning'))));
  perform pg_temp.chk(nr ->> 'divination_record_id' = d ->> 'id' and nr ->> 'reading_date' = '2032-04-08' and jsonb_array_length(nr -> 'analyses') = 1, 'the new Reading joins the session with its Analysis');
  full_rec := lifeos.divination_record_read((d ->> 'id')::uuid);
  earlier_rec := pg_temp.find(full_rec -> 'readings', (r0 ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(full_rec -> 'readings') = 2, 'two Readings in the Divination Record');
  perform pg_temp.chk(earlier_rec ->> 'question' = r0 ->> 'question' and earlier_rec ->> 'result_text' = r0 ->> 'result_text' and earlier_rec ->> 'updated_at' = r0 ->> 'updated_at', 'the earlier Reading stays unchanged');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Section 12 Later outside Analysis, shown under the original Reading Date ---------------------------
do $t$
declare t constant text := 'later_outside_analysis_added_with_source_under_reading_date';
  d jsonb; r0 jsonb; a jsonb; c jsonb; tl jsonb; it jsonb;
begin
  d := pg_temp.mk_reading('SKT_D7 How will the shop do this quarter?', '2032-04-15');
  r0 := d -> 'readings' -> 0;
  -- steps 2 to 4
  a := lifeos.analysis_add(jsonb_build_object('reading_id', r0 ->> 'id', 'source', 'SKT_D7 friend Kai', 'overall_outcome', 'SKT_D7 hold stock', 'key_reasoning', 'SKT_D7 the Star suggests patience', 'analysis_date', '2032-04-20'));
  perform pg_temp.chk(a ->> 'reading_id' = r0 ->> 'id' and a ->> 'divination_record_id' = d ->> 'id' and a ->> 'source' = 'SKT_D7 friend Kai' and a ->> 'analysis_date' = '2032-04-20', 'the Analysis belongs to the Reading with its author');
  c := lifeos.analysis_add(jsonb_build_object('divination_record_id', d ->> 'id', 'source', 'SKT_D7 ChatGPT', 'overall_outcome', 'SKT_D7 combined view', 'key_reasoning', 'SKT_D7 all cards together'));
  perform pg_temp.chk(c ->> 'reading_id' is null and c ->> 'divination_record_id' = d ->> 'id', 'a combined Analysis on the Divination Record');
  perform pg_temp.expect_err(format('select lifeos.analysis_add(%L::jsonb)', jsonb_build_object('reading_id', r0 ->> 'id', 'overall_outcome', 'x', 'key_reasoning', 'y')), 'invalid input');
  -- outcome: the original and earlier Analyses stay; the Timeline shows the later Analysis on the Reading Date
  perform pg_temp.chk(jsonb_array_length(lifeos.divination_record_read((d ->> 'id')::uuid) -> 'readings' -> 0 -> 'analyses') = 2, 'the earlier Analysis stays next to the later one');
  tl := lifeos.timeline('{"from_date": "2032-04-15", "to_date": "2032-04-15"}'::jsonb);
  it := pg_temp.find(tl -> 'items', (r0 ->> 'id')::uuid);
  perform pg_temp.chk(it ->> 'module' = 'divination_reflection' and pg_temp.cnt(it -> 'record' -> 'analyses', (a ->> 'id')::uuid) = 1
                      and pg_temp.cnt(it -> 'record' -> 'record_analyses', (c ->> 'id')::uuid) = 1, 'the Reading item on its date carries the later Analyses');
  perform pg_temp.chk(pg_temp.cnt(lifeos.timeline('{"from_date": "2032-04-20", "to_date": "2032-04-20"}'::jsonb) -> 'items', (a ->> 'id')::uuid) = 0, 'an Analysis is no item of its own date');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Section 12 Correction by delete and re-add; session update and delete -------------------------------
do $t$
declare t constant text := 'wrong_reading_or_analysis_deleted_and_added_again';
  d jsonb; r0 jsonb; c jsonb; nr jsonb; na jsonb; full_rec jsonb; del jsonb; u jsonb;
begin
  d := pg_temp.mk_reading('SKT_D8 Will the renovation finish on time?', '2032-04-22');
  r0 := d -> 'readings' -> 0;
  c := lifeos.analysis_add(jsonb_build_object('divination_record_id', d ->> 'id', 'source', 'Claude', 'overall_outcome', 'SKT_D8 combined', 'key_reasoning', 'SKT_D8 r'));
  -- step 6: the wrong Reading is deleted, then added again correctly
  perform lifeos.reading_delete((r0 ->> 'id')::uuid);
  nr := lifeos.reading_create(jsonb_build_object('divination_record_id', d ->> 'id', 'question', 'SKT_D8 Will the renovation finish on time?', 'method', 'tarot',
          'result_text', E'1. 关键：The Tower (upright)\n2. 重点：Eight of Pentacles (upright)\n3. 前方：Four of Wands (upright)', 'reading_date', '2032-04-22',
          'analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D8 delays first', 'key_reasoning', 'SKT_D8 the Tower'))));
  full_rec := lifeos.divination_record_read((d ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(full_rec -> 'readings') = 1 and full_rec -> 'readings' -> 0 ->> 'id' = nr ->> 'id', 'only the corrected Reading is active');
  perform pg_temp.chk(pg_temp.cnt(full_rec -> 'record_analyses', (c ->> 'id')::uuid) = 1, 'the combined Analysis stays');
  -- step 7: the wrong Analysis is deleted, then added again
  perform lifeos.analysis_delete((nr -> 'analyses' -> 0 ->> 'id')::uuid);
  na := lifeos.analysis_add(jsonb_build_object('reading_id', nr ->> 'id', 'source', 'Claude', 'overall_outcome', 'SKT_D8 delays, then celebration', 'key_reasoning', 'SKT_D8 the Tower, then Four of Wands'));
  full_rec := lifeos.divination_record_read((d ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(full_rec -> 'readings' -> 0 -> 'analyses') = 1 and full_rec -> 'readings' -> 0 -> 'analyses' -> 0 ->> 'id' = na ->> 'id', 'only the corrected Analysis is active');
  -- step 9: descriptive fields only
  u := lifeos.divination_record_update((d ->> 'id')::uuid, '{"title": "SKT_D8 renovation", "topic": "home"}'::jsonb);
  perform pg_temp.chk(u ->> 'title' = 'SKT_D8 renovation' and u ->> 'topic' = 'home', 'title and topic changed');
  perform pg_temp.expect_err(format($$select lifeos.divination_record_update(%s, '{"question": "edited"}'::jsonb)$$, pg_temp.q((d ->> 'id')::uuid)), 'unsupported field');
  -- step 8: the whole session
  del := lifeos.divination_record_delete((d ->> 'id')::uuid);
  full_rec := lifeos.divination_record_read((d ->> 'id')::uuid);
  perform pg_temp.chk(full_rec ->> 'deleted_at' = del ->> 'deleted_at' and full_rec -> 'readings' -> 0 ->> 'deleted_at' = del ->> 'deleted_at', 'the session and its Readings share the deletion time');
  perform pg_temp.chk((lifeos.divination_search('{"keyword": "SKT_D8"}'::jsonb) ->> 'returned_count')::integer = 0, 'the deleted session is out of the search');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Section 13 Past Reading retrieval: short view first, full view on request ---------------------------
do $t$
declare t constant text := 'past_reading_short_view_first_full_view_on_request';
  s uuid := pg_temp.mk_subject('SKT_D9 Uncle Lee', 'person'); sp uuid; d jsonb; r0 jsonb; sv jsonb; rd jsonb; fr jsonb;
begin
  sp := pg_temp.mk_sp('SKT_D9 Uncle Lee', s);
  d := lifeos.divination_record_save(jsonb_build_object('session_date', '2032-05-06', 'topic', 'SKT_D9 family',
         'readings', jsonb_build_array(jsonb_build_object('question', 'SKT_D9 How will Uncle Lee''s health develop?', 'method', 'i_ching', 'result_text', E'本卦：山雷颐\n动爻：六四',
           'story_person_ids', jsonb_build_array(sp),
           'analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D9 recovery with care', 'key_reasoning', 'SKT_D9 Yi is nourishment', 'story_context', 'SKT_D9 he had surgery'))))));
  r0 := d -> 'readings' -> 0;
  perform lifeos.reading_remark_add((r0 ->> 'id')::uuid, '{"text": "SKT_D9 he walked again after two weeks"}'::jsonb);
  -- steps 1 and 2: by Subject, topic or date
  sv := lifeos.divination_search(jsonb_build_object('subject_id', s));
  perform pg_temp.chk(pg_temp.cnt(sv -> 'results', (d ->> 'id')::uuid) = 1, 'found by Subject');
  perform pg_temp.chk(pg_temp.cnt(lifeos.divination_search('{"keyword": "SKT_D9 family"}'::jsonb) -> 'results', (d ->> 'id')::uuid) = 1, 'found by topic');
  perform pg_temp.chk(pg_temp.cnt(lifeos.divination_search('{"from_date": "2032-05-06", "to_date": "2032-05-06"}'::jsonb) -> 'results', (d ->> 'id')::uuid) = 1, 'found by date');
  rd := pg_temp.find(sv -> 'results', (d ->> 'id')::uuid) -> 'readings' -> 0;
  perform pg_temp.chk(rd ->> 'question' = r0 ->> 'question' and rd ->> 'result_text' = r0 ->> 'result_text' and rd -> 'analyses' -> 0 ->> 'overall_outcome' = 'SKT_D9 recovery with care', 'the short view shows Question, Result and Overall Outcome');
  perform pg_temp.chk(not (rd -> 'analyses' -> 0 ? 'key_reasoning') and not (rd -> 'analyses' -> 0 ? 'story_context') and not (rd ? 'remark_entries'), 'the short view holds no Key Reasoning, Story Context or Remarks');
  -- steps 3 and 4
  fr := pg_temp.find(lifeos.divination_record_read((d ->> 'id')::uuid) -> 'readings', (r0 ->> 'id')::uuid);
  perform pg_temp.chk(fr -> 'analyses' -> 0 ->> 'key_reasoning' = 'SKT_D9 Yi is nourishment' and fr -> 'analyses' -> 0 ->> 'story_context' = 'SKT_D9 he had surgery'
                      and fr -> 'remark_entries' -> 0 ->> 'text' = 'SKT_D9 he walked again after two weeks', 'the full view has Key Reasoning, Story Context and Remarks');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Section 14 Reading Remark after the approved Storyline save: add, later entries, correct, remove ---------
do $t$
declare t constant text := 'reading_remark_after_storyline_save_add_correct_and_remove';
  sp uuid := pg_temp.mk_sp('SKT_D10 Hui Min'); d jsonb; r0 jsonb; sl1 jsonb; sl2 jsonb; x jsonb; e1 text; e2 text; ts1 text;
begin
  d := pg_temp.mk_reading('SKT_D10 How will my friendship with Hui Min develop?', '2032-05-02', jsonb_build_array(sp));
  r0 := d -> 'readings' -> 0;
  -- step 4: the Storyline save comes first (Section 6), then the separate Reading Remark offer
  sl1 := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D10 Hui Min apologised', 'occurrence_date', '2032-05-20', 'story_person_ids', jsonb_build_array(sp)));
  -- steps 5 to 7
  x := lifeos.reading_remark_add((r0 ->> 'id')::uuid, jsonb_build_object('storyline_id', sl1 ->> 'id', 'text', '  SKT_D10 the apology matches the Star as renewal  '));
  e1 := x -> 'remark_entries' -> 0 ->> 'entry_id'; ts1 := x -> 'remark_entries' -> 0 ->> 'timestamp';
  perform pg_temp.chk(jsonb_array_length(x -> 'remark_entries') = 1 and x -> 'remark_entries' -> 0 ->> 'storyline_id' = sl1 ->> 'id'
                      and x -> 'remark_entries' -> 0 ->> 'text' = 'SKT_D10 the apology matches the Star as renewal' and e1 is not null, 'the entry holds the Storyline reference and the description');
  -- step 8: a later approved follow-up adds an entry to the same Reading Remark
  sl2 := lifeos.storyline_create(jsonb_build_object('content', 'SKT_D10 Hui Min and I travelled together', 'occurrence_date', '2032-06-10', 'story_person_ids', jsonb_build_array(sp)));
  x := lifeos.reading_remark_add((r0 ->> 'id')::uuid, jsonb_build_object('storyline_id', sl2 ->> 'id', 'text', 'SKT_D10 the trip shows the friendship restored'));
  e2 := x -> 'remark_entries' -> 1 ->> 'entry_id';
  perform pg_temp.chk(jsonb_array_length(x -> 'remark_entries') = 2, 'two entries');
  -- step 10: a correction replaces the whole entry; an omitted storyline_id becomes null
  x := lifeos.reading_remark_update((r0 ->> 'id')::uuid, jsonb_build_object('entry_id', e1, 'text', 'SKT_D10 the apology matches the Star'));
  perform pg_temp.chk(x -> 'remark_entries' -> 0 ->> 'text' = 'SKT_D10 the apology matches the Star' and x -> 'remark_entries' -> 0 ->> 'storyline_id' is null
                      and x -> 'remark_entries' -> 0 ->> 'entry_id' = e1 and x -> 'remark_entries' -> 0 ->> 'timestamp' = ts1, 'the whole entry is replaced, id and timestamp kept');
  x := lifeos.reading_remark_update((r0 ->> 'id')::uuid, jsonb_build_object('entry_id', e1, 'text', 'SKT_D10 the apology matches the Star', 'storyline_id', sl1 ->> 'id'));
  perform pg_temp.chk(x -> 'remark_entries' -> 0 ->> 'storyline_id' = sl1 ->> 'id' and x -> 'remark_entries' -> 1 ->> 'entry_id' = e2, 'the reference is supplied again; the other entry is unchanged');
  -- step 11
  x := lifeos.reading_remark_delete((r0 ->> 'id')::uuid, jsonb_build_object('entry_id', e2));
  perform pg_temp.chk(jsonb_array_length(x -> 'remark_entries') = 1 and x -> 'remark_entries' -> 0 ->> 'entry_id' = e1, 'one entry removed');
  -- outcome: the Reading and its Analysis stay unchanged; a Remark change is not an edit
  perform pg_temp.chk(x ->> 'question' = r0 ->> 'question' and x ->> 'result_text' = r0 ->> 'result_text' and x ->> 'updated_at' = r0 ->> 'updated_at'
                      and jsonb_array_length(x -> 'analyses') = 1, 'Reading and Analysis unchanged');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Section 14 step 12: change a saved Reading's Story Persons after approval ---------------------------
do $t$
declare t constant text := 'reading_story_persons_changed_after_approval_not_an_edit';
  s1 uuid := pg_temp.mk_subject('SKT_D11 Raj', 'person'); s2 uuid := pg_temp.mk_subject('SKT_D11 Rajesh', 'person');
  sp1 uuid; sp2 uuid; d jsonb; r0 jsonb; x jsonb;
begin
  sp1 := pg_temp.mk_sp('SKT_D11 Raj', s1); sp2 := pg_temp.mk_sp('SKT_D11 Rajesh', s2);
  d := pg_temp.mk_reading('SKT_D11 Will Raj join the project?', '2032-05-12', jsonb_build_array(sp1));
  r0 := d -> 'readings' -> 0;
  x := lifeos.reading_story_persons_set((r0 ->> 'id')::uuid, jsonb_build_object('story_person_ids', jsonb_build_array(sp2, sp2)));
  perform pg_temp.chk(x -> 'story_person_ids' = jsonb_build_array(sp2), 'the set is replaced and a repeated ID is stored once');
  perform pg_temp.chk(x ->> 'updated_at' = r0 ->> 'updated_at' and x ->> 'question' = r0 ->> 'question' and x ->> 'result_text' = r0 ->> 'result_text' and jsonb_array_length(x -> 'analyses') = 1, 'not an edit: content and Analyses unchanged');
  perform pg_temp.chk(pg_temp.cnt(lifeos.divination_search(jsonb_build_object('story_person_id', sp2)) -> 'results', (d ->> 'id')::uuid) = 1
                      and pg_temp.cnt(lifeos.divination_search(jsonb_build_object('story_person_id', sp1)) -> 'results', (d ->> 'id')::uuid) = 0, 'retrieval follows the new Story Person');
  perform pg_temp.chk(pg_temp.cnt(lifeos.subject_records(s2, '{"record_types": ["reading"]}'::jsonb) -> 'results', (r0 ->> 'id')::uuid) = 1
                      and pg_temp.cnt(lifeos.subject_records(s1, '{"record_types": ["reading"]}'::jsonb) -> 'results', (r0 ->> 'id')::uuid) = 0, 'the Reading''s Subject follows its Story Persons');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Section 10 steps 16 to 20, then Section 11 step 5: the 梅花易数 round is a second, separate Analysis ---------
do $t$
declare t constant text := 'meihua_round_saved_as_second_separate_analysis_at_save_time';
  iching text := E'本卦：火天大有\n动爻：九四\n变卦：山天大畜'; d jsonb; r jsonb; full_rec jsonb; fr jsonb;
begin
  -- Section 10 steps 1 to 15: the standard I Ching interpretation; steps 16 to 20: the user chooses the 梅花易数 round (Agent steps)
  -- Section 11 step 2: the user approves the save (Agent step); steps 3 to 10: one call with two Analyses in the Reading
  d := lifeos.divination_record_save(jsonb_build_object('session_date', '2032-07-03', 'title', 'SKT_D12 shop lease',
         'readings', jsonb_build_array(jsonb_build_object('question', 'SKT_D12 If I renew the shop lease, how will the business develop this year?',
           'method', 'i_ching', 'result_text', iching,
           'analyses', jsonb_build_array(
             jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D12 standard: steady growth with care in the fourth month',
               'key_reasoning', 'SKT_D12 大有 with 九四 asks for restraint'),
             jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D12 梅花易数: timing favours the second half of the year',
               'key_reasoning', 'SKT_D12 体用 and 应期 from the trigrams'))))));
  -- one Reading: the 梅花易数 round is no new Reading and no combined Analysis
  perform pg_temp.chk(jsonb_array_length(d -> 'readings') = 1 and d -> 'record_analyses' = '[]'::jsonb, 'one Reading, no combined Analysis');
  r := d -> 'readings' -> 0;
  perform pg_temp.chk(r ->> 'result_text' = iching, 'the Result text is kept whole');
  perform pg_temp.chk(jsonb_array_length(r -> 'analyses') = 2 and r -> 'analyses' -> 0 ->> 'id' <> r -> 'analyses' -> 1 ->> 'id', 'two separate Analyses');
  perform pg_temp.chk((select bool_and(a ->> 'reading_id' = r ->> 'id') from jsonb_array_elements(r -> 'analyses') a), 'both Analyses belong to the same Reading');
  -- read back: both rounds stay distinct
  full_rec := lifeos.divination_record_read((d ->> 'id')::uuid);
  fr := pg_temp.find(full_rec -> 'readings', (r ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(fr -> 'analyses') = 2
                      and exists (select 1 from jsonb_array_elements(fr -> 'analyses') a where a ->> 'overall_outcome' like 'SKT_D12 standard:%')
                      and exists (select 1 from jsonb_array_elements(fr -> 'analyses') a where a ->> 'overall_outcome' like 'SKT_D12 梅花易数:%'), 'the standard and the 梅花易数 Analysis are stored apart');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 13. Section 12 step 5: a 梅花易数 round for an already saved Reading is added later with analysis_add -------------
do $t$
declare t constant text := 'meihua_round_for_saved_reading_added_later_with_analysis_add';
  d jsonb; r0 jsonb; a0 jsonb; s jsonb; a jsonb; full_rec jsonb; fr jsonb; old_a jsonb; it jsonb;
begin
  d := lifeos.divination_record_save(jsonb_build_object('session_date', '2032-07-10', 'title', 'SKT_D13 new job',
         'readings', jsonb_build_array(jsonb_build_object('question', 'SKT_D13 If I take the new job, how will my work develop?', 'method', 'i_ching',
           'result_text', E'本卦：地风升\n静爻',
           'analyses', jsonb_build_array(jsonb_build_object('source', 'Claude', 'overall_outcome', 'SKT_D13 standard: gradual rise', 'key_reasoning', 'SKT_D13 升 is growth step by step'))))));
  r0 := d -> 'readings' -> 0; a0 := r0 -> 'analyses' -> 0;
  -- step 1: find the Reading (Section 13)
  s := lifeos.divination_search('{"keyword": "SKT_D13 new job"}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(s -> 'results', (d ->> 'id')::uuid) = 1, 'the saved session is found');
  -- step 5: the later 梅花易数 round is a second, separate Analysis with that reading_id
  a := lifeos.analysis_add(jsonb_build_object('reading_id', r0 ->> 'id', 'source', 'Claude', 'overall_outcome', 'SKT_D13 梅花易数: the change comes after three months',
         'key_reasoning', 'SKT_D13 体用 and 应期', 'analysis_date', '2032-07-12'));
  perform pg_temp.chk(a ->> 'reading_id' = r0 ->> 'id' and a ->> 'divination_record_id' = d ->> 'id' and a ->> 'id' <> a0 ->> 'id', 'a new Analysis of the same Reading');
  -- outcome: the Reading and the standard Analysis stay unchanged
  full_rec := lifeos.divination_record_read((d ->> 'id')::uuid);
  fr := pg_temp.find(full_rec -> 'readings', (r0 ->> 'id')::uuid);
  old_a := pg_temp.find(fr -> 'analyses', (a0 ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(full_rec -> 'readings') = 1 and jsonb_array_length(fr -> 'analyses') = 2, 'still one Reading, now with two Analyses');
  perform pg_temp.chk(old_a ->> 'overall_outcome' = a0 ->> 'overall_outcome' and old_a ->> 'updated_at' = a0 ->> 'updated_at'
                      and fr ->> 'result_text' = r0 ->> 'result_text', 'the Reading and the standard Analysis are unchanged');
  -- the Timeline shows the later round under the original Reading Date
  it := pg_temp.find(lifeos.timeline('{"from_date": "2032-07-10", "to_date": "2032-07-10"}'::jsonb) -> 'items', (r0 ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(it -> 'record' -> 'analyses', (a ->> 'id')::uuid) = 1 and pg_temp.cnt(it -> 'record' -> 'analyses', (a0 ->> 'id')::uuid) = 1, 'both Analyses under the Reading Date');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 14. Section 6 steps 1 and 2: an end signal is a Story Context Cutoff; a stop without a signal saves nothing -------
do $t$
declare t constant text := 'end_signal_cutoff_saved_on_approval_silent_stop_saves_nothing';
  sp jsonb; sl jsonb; sr jsonb; cnt_sl integer; cnt_sp integer;
begin
  -- conversation 1: the user tells about cousin Wei Ling's wedding plans, then says "thanks, that is all for now"
  -- step 1: the end signal is a Story Context Cutoff; steps 3 and 4: present the updates, ask; the user approves (Agent steps)
  -- steps 5 and 8: save the new Story Person and the new Storyline
  sp := lifeos.story_person_create('{"name": "SKT_D14 Wei Ling", "gender": "female", "description": "SKT_D14 cousin in Seremban"}'::jsonb);
  sl := lifeos.storyline_create(jsonb_build_object('title', 'SKT_D14 wedding plans', 'content', 'SKT_D14 Wei Ling plans her wedding for August',
          'occurrence_date', '2032-08-01', 'story_person_ids', jsonb_build_array(sp ->> 'id')));
  sr := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(sp ->> 'id')));
  perform pg_temp.chk((sr ->> 'returned_count')::integer = 1 and sr -> 'results' -> 0 ->> 'id' = sl ->> 'id', 'the approved Storyline is saved');
  -- conversation 2: Section 4 intake finds the Story Person and her Storyline
  perform pg_temp.chk(pg_temp.cnt(lifeos.story_person_search('{"keyword": "SKT_D14 Wei Ling"}'::jsonb) -> 'results', (sp ->> 'id')::uuid) = 1, 'intake finds the Story Person');
  -- the user says the wedding moved to December and that her brother Wei Han helps; then the conversation stops without a signal
  -- step 2: no cutoff, so no save question and no save call (Agent step)
  -- outcome: the stored Storybook is as conversation 1 left it
  sr := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(sp ->> 'id')));
  cnt_sl := (sr ->> 'returned_count')::integer;
  perform pg_temp.chk(cnt_sl = 1 and sr -> 'results' -> 0 ->> 'content' = 'SKT_D14 Wei Ling plans her wedding for August'
                      and sr -> 'results' -> 0 ->> 'updated_at' = sl ->> 'updated_at', 'the Storyline is unchanged, got ' || sr::text);
  cnt_sp := (lifeos.story_person_search('{"keyword": "SKT_D14"}'::jsonb) ->> 'returned_count')::integer;
  perform pg_temp.chk(cnt_sp = 1, 'no new Story Person is saved, got ' || cnt_sp);
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
