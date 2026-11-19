-- =============================================================================
-- tests/skills/personal-records.sql -- Skill flow tests: skills/personal-records/SKILL.md
-- Personal Records: Schedule, series, Event, overdue check, Observation, Note, amendment, deletion. Contract: personal-records.md, shared.md.
-- Each test follows the database steps of one Skill flow, in the Skill's order, through the Contract
-- functions, and asserts the outcome that the Skill and the Knowledge Base state.
--
-- Tests in this file:
--    1. schedule_recorded_after_duplicate_search_starts_planned
--    2. schedule_series_finite_with_one_series_id
--    3. schedule_added_to_existing_series_shares_series_id
--    4. schedule_change_one_reschedule_cancel_missed_and_correction
--    5. schedule_series_change_from_now_on_inclusive_date
--    6. schedule_series_stop_cancels_later_planned_only
--    7. event_recorded_with_confirmed_schedule_match_or_without
--    8. event_confirmed_for_cancelled_or_missed_schedule_sets_occurred
--    9. event_linked_to_schedule_after_its_schedule_was_deleted
--   10. overdue_check_answers_missed_happened_and_unanswered
--   11. observation_with_event_of_same_statement_and_without_event
--   12. observation_correction_keeps_time_and_later_change_is_new
--   13. note_type_from_notebook_dated_on_record_day_and_linked
--   14. feeling_about_earlier_day_event_and_note_linked_both_branches
--   15. amend_record_by_remark_or_structured_update_without_duplicate
--   16. delete_records_event_delete_returns_schedule_to_planned
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

-- 1. Section 4 Record a Schedule ---------------------------------------------------------------
do $t$
declare t constant text := 'schedule_recorded_after_duplicate_search_starts_planned';
  s jsonb; dup jsonb; subj uuid := pg_temp.mk_subject('SKT_P1 Dr Tan', 'person');
begin
  -- step 1: no prior Schedule for the matter
  dup := lifeos.schedule_search('{"keyword": "SKT_P1 dental check"}'::jsonb);
  perform pg_temp.chk((dup ->> 'returned_count')::integer = 0, 'no duplicate Schedule exists');
  -- step 2
  s := lifeos.schedule_create('{"title": "SKT_P1 dental check", "schedule_case": "appointment", "planned_date": "2032-01-14", "planned_time": "15:00",
         "location": "SKT_P1 Klinik", "time_text": "after lunch"}'::jsonb);
  perform pg_temp.chk(s ->> 'status' = 'planned' and s ->> 'series_id' is null and s ->> 'linked_event_id' is null, 'one Planned single Schedule');
  perform pg_temp.chk(s ->> 'planned_date' = '2032-01-14' and s ->> 'planned_time' = '15:00:00' and s ->> 'time_text' = 'after lunch' and s ->> 'schedule_case' = 'appointment', 'planned date, time, timing wording and case stored');
  -- step 3: link to its Subject
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'schedule', 'from_id', s ->> 'id', 'to_type', 'subject', 'to_id', subj));
  perform pg_temp.chk(pg_temp.cnt(lifeos.schedule_read((s ->> 'id')::uuid) -> 'links', subj) = 1, 'the Schedule links to its Subject');
  perform pg_temp.chk((lifeos.schedule_search('{"keyword": "SKT_P1 dental check"}'::jsonb) ->> 'returned_count')::integer = 1, 'the later search finds it');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Section 5 Record a repeating series -----------------------------------------------------------
do $t$
declare t constant text := 'schedule_series_finite_with_one_series_id';
  r jsonb; sid text;
begin
  -- step 1 is the user's confirmed duration (three weeks); steps 2 to 4
  r := lifeos.schedule_create_series('{"series_description": "SKT_P2 piano lesson every Monday 17:00 for three weeks from 2 Feb 2032",
         "schedules": [
           {"title": "SKT_P2 piano lesson", "planned_date": "2032-02-16", "planned_time": "17:00"},
           {"title": "SKT_P2 piano lesson", "planned_date": "2032-02-02", "planned_time": "17:00"},
           {"title": "SKT_P2 piano lesson", "planned_date": "2032-02-09", "planned_time": "17:00"}]}'::jsonb);
  sid := r ->> 'series_id';
  perform pg_temp.chk(sid is not null and jsonb_array_length(r -> 'schedules') = 3, 'three Schedules in one series');
  perform pg_temp.chk((select bool_and(x ->> 'series_id' = sid and x ->> 'series_description' = r ->> 'series_description' and x ->> 'status' = 'planned')
                       from jsonb_array_elements(r -> 'schedules') x), 'each Schedule has the Series ID, the description and its own Planned Status');
  perform pg_temp.chk(r -> 'schedules' -> 0 ->> 'planned_date' = '2032-02-02' and r -> 'schedules' -> 2 ->> 'planned_date' = '2032-02-16', 'returned in planned order');
  perform pg_temp.chk((lifeos.schedule_search(jsonb_build_object('series_id', sid)) ->> 'returned_count')::integer = 3, 'the series is found by its Series ID and is finite');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Section 6 Add a Schedule to an existing series -------------------------------------------------
do $t$
declare t constant text := 'schedule_added_to_existing_series_shares_series_id';
  r jsonb; sid text; found jsonb; one jsonb; more jsonb;
begin
  r := lifeos.schedule_create_series('{"series_description": "SKT_P3 physio every Thursday in March 2032",
         "schedules": [{"title": "SKT_P3 physio", "planned_date": "2032-03-04"}, {"title": "SKT_P3 physio", "planned_date": "2032-03-11"}]}'::jsonb);
  -- step 1: find the series and read its Series ID
  found := lifeos.schedule_search('{"keyword": "SKT_P3 physio"}'::jsonb);
  sid := found -> 'results' -> 0 ->> 'series_id';
  perform pg_temp.chk(sid = r ->> 'series_id', 'the Series ID is read from a found Schedule');
  -- step 2: one more Schedule copies the Series description
  one := lifeos.schedule_create(jsonb_build_object('title', 'SKT_P3 physio', 'planned_date', '2032-03-18', 'series_id', sid));
  perform pg_temp.chk(one ->> 'series_id' = sid and one ->> 'series_description' = 'SKT_P3 physio every Thursday in March 2032', 'the new Schedule copies the Series ID and description');
  -- step 3: several more with the existing Series ID
  more := lifeos.schedule_create_series(jsonb_build_object('series_id', sid, 'schedules', jsonb_build_array(
            jsonb_build_object('title', 'SKT_P3 physio', 'planned_date', '2032-03-25'))));
  perform pg_temp.chk(more ->> 'series_id' = sid and more -> 'schedules' -> 0 ->> 'series_description' = 'SKT_P3 physio every Thursday in March 2032', 'the extension joins the series');
  perform pg_temp.chk((lifeos.schedule_search(jsonb_build_object('series_id', sid)) ->> 'returned_count')::integer = 4, 'the series holds four Schedules');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Section 7 Change one Schedule -------------------------------------------------------------------
do $t$
declare t constant text := 'schedule_change_one_reschedule_cancel_missed_and_correction';
  r jsonb; a uuid; b uuid; u jsonb; occ jsonb;
begin
  r := lifeos.schedule_create_series('{"series_description": "SKT_P4 dentist two visits", "schedules": [
         {"title": "SKT_P4 dentist", "planned_date": "2032-04-02", "planned_time": "10:00"},
         {"title": "SKT_P4 dentist", "planned_date": "2032-04-09", "planned_time": "10:00"}]}'::jsonb);
  a := (r -> 'schedules' -> 0 ->> 'id')::uuid; b := (r -> 'schedules' -> 1 ->> 'id')::uuid;
  -- step 1: find the intended Schedule
  perform pg_temp.chk(pg_temp.cnt(lifeos.schedule_search('{"keyword": "SKT_P4 dentist", "from_date": "2032-04-02", "to_date": "2032-04-02"}'::jsonb) -> 'results', a) = 1, 'the intended Schedule is found');
  -- step 4: a reschedule needs no Status
  u := lifeos.schedule_update(a, '{"planned_time": "15:00"}'::jsonb);
  perform pg_temp.chk(u ->> 'planned_time' = '15:00:00' and u ->> 'status' = 'planned', 'reschedule changes the time only');
  perform pg_temp.chk(lifeos.schedule_read(b) ->> 'planned_time' = '10:00:00', 'step 5: "this one" leaves the other series Schedule unchanged');
  -- cancellation, missed, and a Status correction back to Planned
  perform pg_temp.chk(lifeos.schedule_update(a, '{"status": "cancelled"}'::jsonb) ->> 'status' = 'cancelled', 'cancellation sets Cancelled');
  perform pg_temp.chk(lifeos.schedule_update(a, '{"status": "missed"}'::jsonb) ->> 'status' = 'missed', 'a missed matter sets Missed');
  perform pg_temp.chk(lifeos.schedule_update(a, '{"status": "planned"}'::jsonb) ->> 'status' = 'planned', 'a correction without a linked Event sets Planned again');
  -- a Schedule with a linked Event keeps Occurred
  occ := lifeos.event_create(jsonb_build_object('schedule_id', b, 'occurred_date', '2032-04-09'));
  perform pg_temp.expect_err(format($$select lifeos.schedule_update(%s, '{"status": "planned"}'::jsonb)$$, pg_temp.q(b)), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Section 8 Change a series from now on ---------------------------------------------------------
do $t$
declare t constant text := 'schedule_series_change_from_now_on_inclusive_date';
  r jsonb; sid uuid; d02 uuid; d09 uuid; d16 uuid; d23 uuid; u jsonb; mv jsonb;
begin
  r := lifeos.schedule_create_series('{"series_description": "SKT_P5 yoga every Monday 19:00 in August 2032", "schedules": [
         {"title": "SKT_P5 yoga", "planned_date": "2032-08-02", "planned_time": "19:00"},
         {"title": "SKT_P5 yoga", "planned_date": "2032-08-09", "planned_time": "19:00"},
         {"title": "SKT_P5 yoga", "planned_date": "2032-08-16", "planned_time": "19:00"},
         {"title": "SKT_P5 yoga", "planned_date": "2032-08-23", "planned_time": "19:00"}]}'::jsonb);
  sid := (r ->> 'series_id')::uuid;
  d02 := (r -> 'schedules' -> 0 ->> 'id')::uuid; d09 := (r -> 'schedules' -> 1 ->> 'id')::uuid;
  d16 := (r -> 'schedules' -> 2 ->> 'id')::uuid; d23 := (r -> 'schedules' -> 3 ->> 'id')::uuid;
  perform lifeos.event_create(jsonb_build_object('schedule_id', d02, 'occurred_date', '2032-08-02'));
  -- steps 1 to 4: "from 16 August on, 20:00", that date included, description amended
  u := lifeos.schedule_update_series(jsonb_build_object('series_id', sid, 'from_date', '2032-08-16', 'changes', jsonb_build_object(
         'planned_time', '20:00', 'series_description', 'SKT_P5 yoga every Monday in August 2032, at 20:00 from 16 August')));
  perform pg_temp.chk((u ->> 'updated_count')::integer = 2, 'two later Planned Schedules changed, got ' || (u ->> 'updated_count'));
  perform pg_temp.chk(lifeos.schedule_read(d16) ->> 'planned_time' = '20:00:00' and lifeos.schedule_read(d23) ->> 'planned_time' = '20:00:00', 'the from_date Schedule itself is included');
  perform pg_temp.chk(lifeos.schedule_read(d16) ->> 'series_description' like '%from 16 August', 'targets carry the amended description');
  perform pg_temp.chk(lifeos.schedule_read(d09) ->> 'planned_time' = '19:00:00' and lifeos.schedule_read(d09) ->> 'series_description' = 'SKT_P5 yoga every Monday 19:00 in August 2032', 'an earlier Schedule keeps its content and description');
  perform pg_temp.chk(lifeos.schedule_read(d02) ->> 'status' = 'occurred' and lifeos.schedule_read(d02) ->> 'planned_time' = '19:00:00', 'the Occurred Schedule stays unchanged');
  -- step 5: a date change per Schedule
  mv := lifeos.schedule_update(d23, '{"planned_date": "2032-08-24"}'::jsonb);
  perform pg_temp.chk(mv ->> 'planned_date' = '2032-08-24' and mv ->> 'series_id' = sid::text, 'a date change is made on one Schedule');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Section 9 Stop a series ------------------------------------------------------------------------
do $t$
declare t constant text := 'schedule_series_stop_cancels_later_planned_only';
  r jsonb; sid uuid; s1 uuid; s2 uuid; s3 uuid; ev jsonb; st jsonb;
begin
  r := lifeos.schedule_create_series('{"series_description": "SKT_P6 tuition every Sunday in September 2032", "schedules": [
         {"title": "SKT_P6 tuition", "planned_date": "2032-09-05"},
         {"title": "SKT_P6 tuition", "planned_date": "2032-09-12"},
         {"title": "SKT_P6 tuition", "planned_date": "2032-09-19"}]}'::jsonb);
  sid := (r ->> 'series_id')::uuid; s1 := (r -> 'schedules' -> 0 ->> 'id')::uuid; s2 := (r -> 'schedules' -> 1 ->> 'id')::uuid; s3 := (r -> 'schedules' -> 2 ->> 'id')::uuid;
  ev := lifeos.event_create(jsonb_build_object('schedule_id', s1, 'occurred_date', '2032-09-05', 'description', 'SKT_P6 chapter 3'));
  -- steps 1 and 3
  st := lifeos.schedule_stop_series(jsonb_build_object('series_id', sid, 'from_date', '2032-09-12'));
  perform pg_temp.chk((st ->> 'cancelled_count')::integer = 2, 'the two later Planned Schedules are cancelled');
  perform pg_temp.chk(lifeos.schedule_read(s2) ->> 'status' = 'cancelled' and lifeos.schedule_read(s3) ->> 'status' = 'cancelled', 'later Schedules are Cancelled');
  perform pg_temp.chk(lifeos.schedule_read(s1) ->> 'status' = 'occurred', 'the past Schedule stays Occurred');
  perform pg_temp.chk(lifeos.event_read((ev ->> 'id')::uuid) ->> 'description' = 'SKT_P6 chapter 3' and lifeos.event_read((ev ->> 'id')::uuid) ->> 'deleted_at' is null, 'the Event stays unchanged');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Section 10 Record an Event: the user confirms the match, or does not ----------------------------
do $t$
declare t constant text := 'event_recorded_with_confirmed_schedule_match_or_without';
  s jsonb; s2 jsonb; cand jsonb; e jsonb; e2 jsonb;
begin
  s := lifeos.schedule_create('{"title": "SKT_P7 dentist", "description": "SKT_P7 scaling", "planned_date": "2032-10-04", "planned_time": "15:00", "location": "SKT_P7 Klinik"}'::jsonb);
  s2 := lifeos.schedule_create('{"title": "SKT_P7 haircut", "planned_date": "2032-10-05", "planned_time": "11:00"}'::jsonb);
  -- step 1: the Agent searches for a matching Schedule before the Event
  cand := lifeos.schedule_search('{"keyword": "SKT_P7 dentist", "status": "planned", "from_date": "2032-10-04", "to_date": "2032-10-04"}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(cand -> 'results', (s ->> 'id')::uuid) = 1, 'the candidate Schedule is found');
  -- step 3: confirmed; the actual time comes from the user
  e := lifeos.event_create(jsonb_build_object('schedule_id', s ->> 'id', 'occurred_date', '2032-10-04', 'occurred_time', '15:20'));
  perform pg_temp.chk(e ->> 'title' = 'SKT_P7 dentist' and e ->> 'location' = 'SKT_P7 Klinik' and e ->> 'description' = 'SKT_P7 scaling', 'the Event copies the Schedule content');
  perform pg_temp.chk(e ->> 'planned_date' = '2032-10-04' and e ->> 'planned_time' = '15:00:00', 'the planned date and time are copied as planned values');
  perform pg_temp.chk(e ->> 'occurred_date' = '2032-10-04' and e ->> 'occurred_time' = '15:20:00', 'the actual date and time come from the input');
  perform pg_temp.chk(e -> 'schedule' ->> 'status' = 'occurred' and lifeos.schedule_read((s ->> 'id')::uuid) ->> 'linked_event_id' = e ->> 'id', 'the Schedule becomes Occurred with its Event');
  -- "Run this once": a second Event for the same Schedule is rejected
  perform pg_temp.expect_err(format('select lifeos.event_create(%L::jsonb)', jsonb_build_object('schedule_id', s ->> 'id', 'occurred_date', '2032-10-04')), 'invalid relationship');
  -- step 4: the user does not confirm the haircut match; an ordinary Event, the Schedule stays Planned
  e2 := lifeos.event_create('{"title": "SKT_P7 haircut at another shop", "occurred_date": "2032-10-05"}'::jsonb);
  perform pg_temp.chk(e2 ->> 'schedule_id' is null and e2 ->> 'planned_date' is null and e2 ->> 'occurred_time' is null, 'an ordinary Event without a Schedule link, unknown time stays unknown');
  perform pg_temp.chk(lifeos.schedule_read((s2 ->> 'id')::uuid) ->> 'status' = 'planned' and lifeos.schedule_read((s2 ->> 'id')::uuid) ->> 'linked_event_id' is null, 'the unconfirmed Schedule stays Planned');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Section 10 step 3: a Cancelled or Missed Schedule also becomes Occurred ---------------------------
do $t$
declare t constant text := 'event_confirmed_for_cancelled_or_missed_schedule_sets_occurred';
  c jsonb; m jsonb; e1 jsonb; e2 jsonb;
begin
  c := lifeos.schedule_update(((lifeos.schedule_create('{"title": "SKT_P8 meetup", "planned_date": "2032-10-06"}'::jsonb)) ->> 'id')::uuid, '{"status": "cancelled"}'::jsonb);
  m := lifeos.schedule_update(((lifeos.schedule_create('{"title": "SKT_P8 call mum", "planned_date": "2032-10-07"}'::jsonb)) ->> 'id')::uuid, '{"status": "missed"}'::jsonb);
  e1 := lifeos.event_create(jsonb_build_object('schedule_id', c ->> 'id', 'occurred_date', '2032-10-06'));
  e2 := lifeos.event_create(jsonb_build_object('schedule_id', m ->> 'id', 'occurred_date', '2032-10-08', 'title', 'SKT_P8 called mum a day late'));
  perform pg_temp.chk(e1 -> 'schedule' ->> 'status' = 'occurred', 'a Cancelled Schedule becomes Occurred');
  perform pg_temp.chk(e2 -> 'schedule' ->> 'status' = 'occurred' and e2 ->> 'title' = 'SKT_P8 called mum a day late' and e2 ->> 'occurred_date' = '2032-10-08', 'a Missed Schedule becomes Occurred, the user details win');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Section 11 Link an existing Event to a Schedule (its first Schedule was deleted) -----------------
do $t$
declare t constant text := 'event_linked_to_schedule_after_its_schedule_was_deleted';
  a jsonb; b jsonb; e jsonb; l jsonb;
begin
  a := lifeos.schedule_create('{"title": "SKT_P9 car service", "planned_date": "2032-10-10"}'::jsonb);
  e := lifeos.event_create(jsonb_build_object('schedule_id', a ->> 'id', 'occurred_date', '2032-10-11', 'title', 'SKT_P9 car serviced'));
  perform lifeos.schedule_delete((a ->> 'id')::uuid);
  perform pg_temp.chk(lifeos.event_read((e ->> 'id')::uuid) ->> 'schedule_id' is null, 'the Event shows no Schedule after its Schedule is deleted');
  perform pg_temp.chk(lifeos.schedule_read((a ->> 'id')::uuid) ->> 'status' = 'occurred', 'the deleted Schedule keeps its Status');
  b := lifeos.schedule_create('{"title": "SKT_P9 car service, rebooked", "planned_date": "2032-10-11", "planned_time": "09:30"}'::jsonb);
  -- step 1: find both; step 3: link after the user confirms
  perform pg_temp.chk(pg_temp.cnt(lifeos.event_search('{"keyword": "SKT_P9 car serviced"}'::jsonb) -> 'results', (e ->> 'id')::uuid) = 1
                      and pg_temp.cnt(lifeos.schedule_search('{"keyword": "SKT_P9 car service, rebooked"}'::jsonb) -> 'results', (b ->> 'id')::uuid) = 1, 'both Records are found');
  l := lifeos.event_link_schedule((e ->> 'id')::uuid, (b ->> 'id')::uuid);
  perform pg_temp.chk(l ->> 'schedule_id' = b ->> 'id' and l ->> 'planned_date' = '2032-10-11' and l ->> 'planned_time' = '09:30:00', 'the Event carries the new Schedule''s planned date and time');
  perform pg_temp.chk(l ->> 'title' = 'SKT_P9 car serviced' and l -> 'schedule' ->> 'status' = 'occurred', 'Event content unchanged, the Schedule becomes Occurred');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Section 12 Overdue check on "what happens today" ----------------------------------------------
-- The check works on yesterday and today only, so this test uses those dates and filters by its own IDs.
do $t$
declare t constant text := 'overdue_check_answers_missed_happened_and_unanswered';
  y date := pg_temp.today() - 1; y1 jsonb; y2 jsonb; y3 jsonb; hd jsonb; tl jsonb; c1 jsonb; c2 jsonb; ev jsonb;
begin
  y1 := lifeos.schedule_create(jsonb_build_object('title', 'SKT_P10 pay the bill', 'planned_date', y));
  y2 := lifeos.schedule_create(jsonb_build_object('title', 'SKT_P10 call the bank', 'planned_date', y, 'planned_time', '09:00'));
  y3 := lifeos.schedule_create(jsonb_build_object('title', 'SKT_P10 gym', 'planned_date', y, 'planned_time', '10:00'));
  hd := lifeos.schedule_update(((lifeos.schedule_create(jsonb_build_object('title', 'SKT_P10 handled', 'planned_date', y))) ->> 'id')::uuid, '{"status": "cancelled"}'::jsonb);
  -- step 1: the Timeline for today
  tl := lifeos.timeline(jsonb_build_object('from_date', pg_temp.today(), 'to_date', pg_temp.today()));
  perform pg_temp.chk(tl ? 'items', 'the Timeline for today is returned');
  -- step 2
  c1 := lifeos.schedule_overdue_check('{}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(c1 -> 'results', (y1 ->> 'id')::uuid) = 1 and pg_temp.cnt(c1 -> 'results', (y2 ->> 'id')::uuid) = 1 and pg_temp.cnt(c1 -> 'results', (y3 ->> 'id')::uuid) = 1, 'the three passed Planned Schedules are returned');
  perform pg_temp.chk(pg_temp.cnt(c1 -> 'results', (hd ->> 'id')::uuid) = 0, 'step 5: a handled Schedule is not asked about');
  perform pg_temp.chk(pg_temp.pos(c1 -> 'results', (y2 ->> 'id')::uuid) < pg_temp.pos(c1 -> 'results', (y3 ->> 'id')::uuid)
                      and pg_temp.pos(c1 -> 'results', (y3 ->> 'id')::uuid) < pg_temp.pos(c1 -> 'results', (y1 ->> 'id')::uuid), 'timed first in order, the date-only Schedule last');
  -- step 4: answers
  perform pg_temp.chk(lifeos.schedule_update((y1 ->> 'id')::uuid, '{"status": "missed"}'::jsonb) ->> 'status' = 'missed', 'missed: Status set');
  ev := lifeos.event_create(jsonb_build_object('schedule_id', y2 ->> 'id', 'occurred_date', y, 'occurred_time', '09:10'));
  perform pg_temp.chk(ev -> 'schedule' ->> 'status' = 'occurred', 'it happened: the Event with the confirmed Schedule');
  -- outcome: the unanswered one stays Planned and is asked again; answered ones are not
  c2 := lifeos.schedule_overdue_check(null);
  perform pg_temp.chk(pg_temp.cnt(c2 -> 'results', (y3 ->> 'id')::uuid) = 1 and pg_temp.cnt(c2 -> 'results', (y1 ->> 'id')::uuid) = 0 and pg_temp.cnt(c2 -> 'results', (y2 ->> 'id')::uuid) = 0, 'only the unanswered Schedule is returned again');
  perform pg_temp.chk(lifeos.schedule_read((y3 ->> 'id')::uuid) ->> 'status' = 'planned', 'the unanswered Schedule stays Planned');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Section 13 Observation: with the Event of the same statement, and without an Event ---------------
do $t$
declare t constant text := 'observation_with_event_of_same_statement_and_without_event';
  u uuid := pg_temp.user_subject(); mem uuid := pg_temp.mk_subject('SKT_P11 Aeon membership', 'membership');
  e jsonb; bp jsonb; w jsonb; er jsonb; pts jsonb;
begin
  -- step 2: the Event first; steps 3 and 4: the Observations link to it without a proposal
  e := lifeos.event_create('{"title": "SKT_P11 doctor visit", "occurred_date": "2032-11-03", "occurred_time": "10:00"}'::jsonb);
  bp := lifeos.observation_create(jsonb_build_object('subject_id', u, 'observation_name', 'blood pressure', 'value_text', '120/80', 'observed_date', '2032-11-03', 'observed_time', '10:15', 'event_id', e ->> 'id'));
  w := lifeos.observation_create(jsonb_build_object('subject_id', u, 'observation_name', 'weight', 'value_numeric', 70.55, 'unit', 'kg', 'observed_date', '2032-11-03', 'event_id', e ->> 'id'));
  er := lifeos.event_read((e ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(er -> 'observations') = 2, 'one Event holds both Observations');
  perform pg_temp.chk((w ->> 'value_numeric')::numeric = 70.55 and w ->> 'unit' = 'kg' and bp ->> 'value_text' = '120/80', 'values kept with exact precision');
  perform pg_temp.chk(bp ->> 'subject_id' = u::text, 'the Observation belongs to the user Subject');
  -- step 6: an Observation without an Event; no Event is created
  pts := lifeos.observation_create(jsonb_build_object('subject_id', mem, 'observation_name', 'membership points', 'value_numeric', 1200, 'unit', 'points', 'observed_date', '2032-11-04'));
  perform pg_temp.chk(pts ->> 'event_id' is null, 'no Event link');
  perform pg_temp.chk((lifeos.event_search('{"from_date": "2032-11-04", "to_date": "2032-11-04"}'::jsonb) ->> 'returned_count')::integer = 0, 'no Event was created for the day');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Section 14 Correct an Observation, or record a later change ----------------------------------
do $t$
declare t constant text := 'observation_correction_keeps_time_and_later_change_is_new';
  s uuid := pg_temp.mk_subject('SKT_P12 Ah Ma', 'person'); o jsonb; c jsonb; n jsonb; sr jsonb;
begin
  o := lifeos.observation_create(jsonb_build_object('subject_id', s, 'observation_name', 'SKT_P12 weight', 'value_numeric', 71, 'unit', 'kg', 'observed_date', '2032-11-10', 'observed_time', '08:00'));
  -- step 1 and 2: a correction keeps the original observation time
  perform pg_temp.chk(pg_temp.cnt(lifeos.observation_search(jsonb_build_object('subject_id', s)) -> 'results', (o ->> 'id')::uuid) = 1, 'the Observation is found');
  c := lifeos.observation_update((o ->> 'id')::uuid, '{"value_numeric": 70.8}'::jsonb);
  perform pg_temp.chk((c ->> 'value_numeric')::numeric = 70.8 and c ->> 'observed_date' = '2032-11-10' and c ->> 'observed_time' = '08:00:00', 'corrected value, original time kept');
  perform pg_temp.expect_err(format($$select lifeos.observation_update(%s, '{"observed_date": "2032-11-11"}'::jsonb)$$, pg_temp.q((o ->> 'id')::uuid)), 'unsupported field');
  -- step 3: a later real-world change is a new Observation
  n := lifeos.observation_create(jsonb_build_object('subject_id', s, 'observation_name', 'SKT_P12 weight', 'value_numeric', 69.9, 'unit', 'kg', 'observed_date', '2032-11-20'));
  sr := lifeos.observation_search(jsonb_build_object('subject_id', s, 'observation_name', 'skt_p12 WEIGHT'));
  perform pg_temp.chk((sr ->> 'returned_count')::integer = 2 and sr -> 'results' -> 0 ->> 'id' = n ->> 'id', 'both Observations relate through the Subject, newest first');
  perform pg_temp.chk((lifeos.observation_read((o ->> 'id')::uuid) ->> 'value_numeric')::numeric = 70.8, 'the earlier Observation keeps its corrected value');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 13. Section 15 Record a Note -------------------------------------------------------------------------
do $t$
declare t constant text := 'note_type_from_notebook_dated_on_record_day_and_linked';
  nb jsonb; n jsonb; n2 jsonb; subj uuid := pg_temp.mk_subject('SKT_P13 Grandpa', 'person'); lk jsonb;
begin
  -- steps 1 and 2
  nb := lifeos.notebook_read('note_types');
  perform pg_temp.chk(nb ->> 'content' like '%Feeling%', 'the Note Types include Feeling');
  -- step 4
  n := lifeos.note_create('{"note_type": "Feeling", "title": "SKT_P13 missing grandpa", "content": "SKT_P13 I miss grandpa''s stories"}'::jsonb);
  perform pg_temp.chk(n ->> 'note_date' = pg_temp.today()::text and n ->> 'edited_at' is null, 'the Note is dated on its record day');
  -- step 3: a new Note Type when none fits
  perform lifeos.notebook_update('note_types', jsonb_build_object('content', (nb ->> 'content') || E'\nSKT_P13 Gratitude'));
  perform pg_temp.chk(lifeos.notebook_read('note_types') ->> 'content' like '%SKT_P13 Gratitude%', 'the new Note Type is in the Notebook');
  n2 := lifeos.note_create('{"note_type": "SKT_P13 Gratitude", "content": "SKT_P13 thankful for the family dinner"}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(lifeos.note_search('{"note_type": "skt_p13 gratitude"}'::jsonb) -> 'results', (n2 ->> 'id')::uuid) = 1, 'the Note is found by its Note Type');
  -- step 5: link to the Subject; the type stays
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'note', 'from_id', n ->> 'id', 'to_type', 'subject', 'to_id', subj));
  lk := lifeos.note_read((n ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lk -> 'links', subj) = 1 and lk ->> 'note_type' = 'Feeling', 'linked, and the Note keeps its type');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 14. Section 16 Feeling about an earlier day: the Event of that day, a Note of today, linked ------------
do $t$
declare t constant text := 'feeling_about_earlier_day_event_and_note_linked_both_branches';
  f jsonb; e jsonb; n jsonb; ex jsonb; n2 jsonb; lk jsonb;
begin
  -- branch: no Event for that day; the Agent creates it
  f := lifeos.event_search('{"from_date": "2032-12-07", "to_date": "2032-12-07"}'::jsonb);
  perform pg_temp.chk((f ->> 'returned_count')::integer = 0, 'no Event for the earlier day');
  e := lifeos.event_create('{"title": "SKT_P14 presentation at work", "occurred_date": "2032-12-07"}'::jsonb);
  n := lifeos.note_create('{"note_type": "Feeling", "content": "SKT_P14 still proud of last Tuesday''s presentation"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'note', 'from_id', n ->> 'id', 'to_type', 'event', 'to_id', e ->> 'id'));
  lk := lifeos.record_links_read('note', (n ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lk -> 'links', (e ->> 'id')::uuid) = 1, 'the Note links to the Event');
  perform pg_temp.chk(e ->> 'occurred_date' = '2032-12-07' and n ->> 'note_date' = pg_temp.today()::text, 'the Event holds the earlier day, the Note holds today');
  -- branch: the Event exists; it is found and reused
  ex := lifeos.event_create('{"title": "SKT_P14 argument with brother", "occurred_date": "2032-12-14"}'::jsonb);
  f := lifeos.event_search('{"from_date": "2032-12-14", "to_date": "2032-12-14"}'::jsonb);
  perform pg_temp.chk((f ->> 'returned_count')::integer = 1 and f -> 'results' -> 0 ->> 'id' = ex ->> 'id', 'the existing Event is found by its date');
  n2 := lifeos.note_create('{"note_type": "Feeling", "content": "SKT_P14 sad about the argument"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'note', 'from_id', n2 ->> 'id', 'to_type', 'event', 'to_id', ex ->> 'id'));
  perform pg_temp.chk((lifeos.event_search('{"from_date": "2032-12-14", "to_date": "2032-12-14"}'::jsonb) ->> 'returned_count')::integer = 1, 'no second Event');
  perform pg_temp.chk(pg_temp.cnt(lifeos.event_read((ex ->> 'id')::uuid) -> 'links', (n2 ->> 'id')::uuid) = 1, 'the Event lists the Note');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 15. Section 17 Amend a Record: a Remark or a structured update, no duplicate --------------------------
do $t$
declare t constant text := 'amend_record_by_remark_or_structured_update_without_duplicate';
  u uuid := pg_temp.user_subject(); s jsonb; e jsonb; o jsonb; n jsonb; r jsonb;
begin
  s := lifeos.schedule_create('{"title": "SKT_P15 karaoke", "planned_date": "2032-12-20"}'::jsonb);
  e := lifeos.event_create('{"title": "SKT_P15 karaoke night", "occurred_date": "2032-12-20"}'::jsonb);
  o := lifeos.observation_create(jsonb_build_object('subject_id', u, 'observation_name', 'SKT_P15 voice', 'value_text', 'hoarse', 'observed_date', '2032-12-21'));
  n := lifeos.note_create('{"note_type": "Experience", "content": "SKT_P15 learned two new songs"}'::jsonb);
  -- step 1: retrieve the prior Records
  perform pg_temp.chk((lifeos.event_search('{"keyword": "SKT_P15 karaoke"}'::jsonb) ->> 'returned_count')::integer = 1, 'the prior Event is found');
  -- step 4: a simple additive detail is a Remark
  r := lifeos.record_add_remark('event', (e ->> 'id')::uuid, 'SKT_P15 we sang until 2 am');
  perform pg_temp.chk(jsonb_array_length(r -> 'remarks') = 1, 'Remark on the Event');
  -- step 5: structured updates
  perform pg_temp.chk(lifeos.schedule_update((s ->> 'id')::uuid, '{"location": "SKT_P15 Red Box"}'::jsonb) ->> 'location' = 'SKT_P15 Red Box', 'Schedule updated');
  perform pg_temp.chk(lifeos.event_update((e ->> 'id')::uuid, '{"location": "SKT_P15 Red Box", "occurred_time": "21:00"}'::jsonb) ->> 'occurred_time' = '21:00:00', 'Event updated');
  perform pg_temp.chk(lifeos.observation_update((o ->> 'id')::uuid, '{"value_text": "lost voice"}'::jsonb) ->> 'value_text' = 'lost voice', 'Observation updated');
  r := lifeos.note_update((n ->> 'id')::uuid, '{"content": "SKT_P15 learned three new songs"}'::jsonb);
  perform pg_temp.chk(r ->> 'edited_at' is not null and r ->> 'note_date' = pg_temp.today()::text, 'Note edited, its date is the edit date');
  -- outcome: latest content and no duplicate
  perform pg_temp.chk((lifeos.event_search('{"keyword": "SKT_P15 karaoke"}'::jsonb) ->> 'returned_count')::integer = 1
                      and (lifeos.note_search('{"keyword": "SKT_P15 learned"}'::jsonb) ->> 'returned_count')::integer = 1, 'no duplicate Records');
  perform pg_temp.chk(lifeos.event_read((e ->> 'id')::uuid) ->> 'location' = 'SKT_P15 Red Box' and jsonb_array_length(lifeos.event_read((e ->> 'id')::uuid) -> 'remarks') = 1, 'the Event holds its latest content and the Remark');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 16. Section 18 Delete a Record ---------------------------------------------------------------------------
do $t$
declare t constant text := 'delete_records_event_delete_returns_schedule_to_planned';
  subj uuid := pg_temp.mk_subject('SKT_P16 Mr Lim', 'person'); s jsonb; e jsonb; d jsonb; ms jsonb; s3 jsonb; e3 jsonb; o jsonb; n jsonb;
begin
  -- an Event linked to an active Schedule
  s := lifeos.schedule_create('{"title": "SKT_P16 piano recital", "planned_date": "2032-12-27"}'::jsonb);
  e := lifeos.event_create(jsonb_build_object('schedule_id', s ->> 'id', 'occurred_date', '2032-12-27'));
  d := lifeos.event_delete((e ->> 'id')::uuid);
  perform pg_temp.chk(d ->> 'schedule_returned_to_planned' = s ->> 'id', 'the linked active Schedule returns to Planned');
  perform pg_temp.chk(lifeos.schedule_read((s ->> 'id')::uuid) ->> 'status' = 'planned' and lifeos.schedule_read((s ->> 'id')::uuid) ->> 'linked_event_id' is null, 'the Schedule is Planned without a linked Event');
  -- a deleted Schedule keeps its Status
  ms := lifeos.schedule_update(((lifeos.schedule_create('{"title": "SKT_P16 swim", "planned_date": "2032-12-28"}'::jsonb)) ->> 'id')::uuid, '{"status": "missed"}'::jsonb);
  perform lifeos.schedule_delete((ms ->> 'id')::uuid);
  perform pg_temp.chk(lifeos.schedule_read((ms ->> 'id')::uuid) ->> 'status' = 'missed' and lifeos.schedule_read((ms ->> 'id')::uuid) ->> 'deleted_at' is not null, 'the deleted Schedule keeps Missed');
  s3 := lifeos.schedule_create('{"title": "SKT_P16 bake sale", "planned_date": "2032-12-29"}'::jsonb);
  e3 := lifeos.event_create(jsonb_build_object('schedule_id', s3 ->> 'id', 'occurred_date', '2032-12-29'));
  perform lifeos.schedule_delete((s3 ->> 'id')::uuid);
  d := lifeos.event_delete((e3 ->> 'id')::uuid);
  perform pg_temp.chk(d ->> 'schedule_returned_to_planned' is null and lifeos.schedule_read((s3 ->> 'id')::uuid) ->> 'status' = 'occurred', 'an Event of a deleted Schedule: the Schedule keeps Occurred');
  -- Observation and Note; their links stay stored and are ignored
  o := lifeos.observation_create(jsonb_build_object('subject_id', subj, 'observation_name', 'SKT_P16 mood', 'value_text', 'calm', 'observed_date', '2032-12-30'));
  n := lifeos.note_create('{"note_type": "General", "content": "SKT_P16 Mr Lim lent me a book"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'note', 'from_id', n ->> 'id', 'to_type', 'subject', 'to_id', subj));
  perform lifeos.observation_delete((o ->> 'id')::uuid);
  perform lifeos.note_delete((n ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lifeos.record_links_read('subject', subj) -> 'links', (n ->> 'id')::uuid) = 0
                      and pg_temp.cnt(lifeos.record_links_read('subject', subj) -> 'links', (o ->> 'id')::uuid) = 0, 'the Subject ignores the deleted Note and Observation');
  perform pg_temp.chk((lifeos.note_search('{"keyword": "SKT_P16 Mr Lim"}'::jsonb) ->> 'returned_count')::integer = 0
                      and (lifeos.note_search('{"keyword": "SKT_P16 Mr Lim", "include_deleted": true}'::jsonb) ->> 'returned_count')::integer = 1, 'the deleted Note is out of the normal search');
  perform pg_temp.chk((lifeos.observation_search(jsonb_build_object('subject_id', subj)) ->> 'returned_count')::integer = 0, 'the deleted Observation is out of the search');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
