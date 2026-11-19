-- =============================================================================
-- tests/04_personal_records.sql -- Module: Personal Records (Contract personal-records.md 4.1 to 4.4, shared.md 4.5 and 4.6)
-- Schedule, Event, Observation, Note, Record links, Remarks, deletion.
--
-- Tests in this file:
--   1.  schedule_create_defaults_and_validation
--   2.  schedule_series_create_and_extend
--   3.  schedule_update_this_one_only
--   4.  schedule_update_series_from_date_inclusive
--   5.  schedule_stop_series_from_date_inclusive
--   6.  event_actualises_schedule_copies_planned_date_and_time
--   7.  event_link_schedule_existing_event
--   8.  schedule_status_locked_while_event_linked
--   9.  schedule_overdue_check
--   10. event_delete_returns_schedule_to_planned
--   11. observation_linked_to_event
--   12. observation_update_keeps_observed_time
--   13. note_date_after_edit_unchanged_after_remark
--   14. record_links_ignore_deleted_targets
--   15. record_add_remark_rules
--   16. soft_delete_read_and_search_deleted
--   17. record_update_remark_and_record_delete_remark_leave_record_dates_unchanged
--   18. record_link_create_rejects_reading_storyline_pair
--   19. record_link_create_rejects_divination_record_storyline_pair
--   20. event_delete_keeps_status_of_deleted_schedule
--   21. event_and_observation_search_filter_by_deleted_record_id_matches_nothing
--   22. record_links_read_on_subject_lists_each_record_once_with_every_path
--   23. record_links_read_on_record_lists_each_subject_once_without_via_list
--
-- Test setup that the Contract has no function for: test 13 moves created_at of
-- one Note into the past, so the Note date can be told apart from today inside a
-- single transaction. Test 15 moves updated_at of one Schedule 5 days back, so a
-- change of updated_at shows inside one transaction. Test 17 moves updated_at of one
-- Schedule and created_at and updated_at of one Note back in the same way. Test 17
-- also reads the five Record tables to check that every stored Remark has a remark_id.
-- Test 20 reads lifeos.events to check that the stored schedule link is removed.
-- Every other step calls Contract functions only.
-- Single transaction: begin; tests; select results; rollback.
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

-- 1. Schedule create: defaults, derived field and validation ---------------------
do $t$
declare t constant text := 'schedule_create_defaults_and_validation';
  s jsonb;
begin
  s := lifeos.schedule_create('{"title":"Dentist","planned_date":"2031-03-10","planned_time":"14:30","schedule_case":"appointment","location":"Clinic A"}');
  perform pg_temp.chk(s->>'status' = 'planned', 'new Schedule is planned');
  perform pg_temp.chk(s->>'planned_date' = '2031-03-10' and s->>'planned_time' = '14:30:00', 'planned date and time stored as KL wall-clock values');
  perform pg_temp.chk(s->>'series_id' is null, 'single Schedule has no series_id');
  perform pg_temp.chk(s ? 'linked_event_id' and s->>'linked_event_id' is null, 'linked_event_id is null without an Event');
  perform pg_temp.chk(s->'remarks' = '[]'::jsonb and s->'metadata' = '{}'::jsonb, 'remarks [] and metadata {} by default');

  s := lifeos.schedule_create('{"title":"Pay rent","planned_date":"2031-03-11"}');
  perform pg_temp.chk(s->>'planned_time' is null, 'planned_time null when no clock time applies');

  perform pg_temp.expect_err($$select lifeos.schedule_create('{"planned_date":"2031-03-10"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.schedule_create('{"title":"x"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.schedule_create('{"title":"x","planned_date":"2031-03-10","status":"occurred"}')$$, 'unsupported field');
  perform pg_temp.expect_err($$select lifeos.schedule_create('{"title":"x","planned_date":"2031-03-10","bogus":1}')$$, 'unsupported field');
  perform pg_temp.expect_err($$select lifeos.schedule_create('{"title":"x","planned_date":"not-a-date"}')$$, 'invalid date');
  perform pg_temp.expect_err($$select lifeos.schedule_create('{"title":"x","planned_date":"2031-03-10","schedule_case":"party"}')$$, 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.schedule_create(jsonb_build_object('title','x','planned_date','2031-03-10','series_id',%L))$$, gen_random_uuid()), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Series: create, extend with schedule_create_series and schedule_create ------
do $t$
declare t constant text := 'schedule_series_create_and_extend';
  r jsonb; sid uuid; x jsonb; sr jsonb;
begin
  r := lifeos.schedule_create_series('{"series_description":"Every Monday for three weeks, 7am gym","schedules":[
        {"title":"Gym","planned_date":"2031-04-14","planned_time":"07:00"},
        {"title":"Gym","planned_date":"2031-04-07","planned_time":"07:00"},
        {"title":"Gym","planned_date":"2031-04-21","planned_time":"07:00"}]}');
  sid := (r->>'series_id')::uuid;
  perform pg_temp.chk(sid is not null, 'series_id generated');
  perform pg_temp.chk(jsonb_array_length(r->'schedules') = 3, 'three Schedules created');
  perform pg_temp.chk(r->>'series_description' = 'Every Monday for three weeks, 7am gym', 'series_description returned');
  perform pg_temp.chk(r->'schedules'->0->>'planned_date' = '2031-04-07' and r->'schedules'->2->>'planned_date' = '2031-04-21', 'schedules ordered by planned_date');
  perform pg_temp.chk((select count(distinct e->>'series_id') from jsonb_array_elements(r->'schedules') e) = 1
                      and r->'schedules'->0->>'series_id' = sid::text, 'every Schedule shares the series_id');
  perform pg_temp.chk((select count(distinct e->>'series_description') from jsonb_array_elements(r->'schedules') e) = 1, 'every Schedule shares the series_description');
  perform pg_temp.chk((select bool_and(e->>'status' = 'planned') from jsonb_array_elements(r->'schedules') e), 'every Schedule is planned');

  -- extend with schedule_create_series, description omitted
  x := lifeos.schedule_create_series(jsonb_build_object('series_id', sid, 'schedules', jsonb_build_array(jsonb_build_object('title','Gym','planned_date','2031-04-28','planned_time','07:00'))));
  perform pg_temp.chk(x->>'series_id' = sid::text and x->>'series_description' = 'Every Monday for three weeks, 7am gym', 'extension copies the series description');
  -- extend with schedule_create, description omitted
  x := lifeos.schedule_create(jsonb_build_object('title','Gym','planned_date','2031-05-05','series_id', sid));
  perform pg_temp.chk(x->>'series_id' = sid::text and x->>'series_description' = 'Every Monday for three weeks, 7am gym', 'schedule_create joins the series and copies the description');
  sr := lifeos.schedule_search(jsonb_build_object('series_id', sid));
  perform pg_temp.chk((sr->>'returned_count')::int = 5, 'series_id search returns all five Schedules');

  -- a new series needs a description, an item needs title and planned_date
  perform pg_temp.expect_err($$select lifeos.schedule_create_series('{"schedules":[{"title":"A","planned_date":"2031-04-07"}]}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.schedule_create_series('{"series_description":"d","schedules":[]}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.schedule_create_series('{"series_description":"d","schedules":[{"title":"A"}]}')$$, 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. "This one": schedule_update changes one Schedule only -----------------------
do $t$
declare t constant text := 'schedule_update_this_one_only';
  r jsonb; ids uuid[]; u jsonb; o jsonb;
begin
  r := lifeos.schedule_create_series('{"series_description":"Weekly piano","schedules":[
        {"title":"Piano","planned_date":"2031-05-05","planned_time":"10:00"},
        {"title":"Piano","planned_date":"2031-05-12","planned_time":"10:00"},
        {"title":"Piano","planned_date":"2031-05-19","planned_time":"10:00"}]}');
  select array_agg((e->>'id')::uuid order by e->>'planned_date') into ids from jsonb_array_elements(r->'schedules') e;
  u := lifeos.schedule_update(ids[2], '{"planned_date":"2031-05-13","planned_time":"11:00","location":"Studio"}');
  perform pg_temp.chk(u->>'planned_date' = '2031-05-13' and u->>'planned_time' = '11:00:00' and u->>'location' = 'Studio', 'reschedule changes date, time and location');
  perform pg_temp.chk(u->>'status' = 'planned', 'a reschedule keeps the Status planned');
  o := lifeos.schedule_read(ids[1]);
  perform pg_temp.chk(o->>'planned_date' = '2031-05-05' and o->>'location' is null, 'the first Schedule is unchanged');
  o := lifeos.schedule_read(ids[3]);
  perform pg_temp.chk(o->>'planned_date' = '2031-05-19' and o->>'planned_time' = '10:00:00', 'the third Schedule is unchanged');
  u := lifeos.schedule_update(ids[3], '{"status":"missed"}');
  perform pg_temp.chk(u->>'status' = 'missed', 'status missed accepted');
  u := lifeos.schedule_update(ids[3], '{"status":"cancelled"}');
  perform pg_temp.chk(u->>'status' = 'cancelled', 'status cancelled accepted');
  u := lifeos.schedule_update(ids[3], '{"status":"planned"}');
  perform pg_temp.chk(u->>'status' = 'planned', 'status planned accepted');
  perform pg_temp.expect_err(format($$select lifeos.schedule_update(%L::uuid, '{"status":"occurred"}')$$, ids[3]), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.schedule_update(%L::uuid, '{"series_id":"%s"}')$$, ids[3], gen_random_uuid()), 'unsupported field');
  perform pg_temp.expect_err(format($$select lifeos.schedule_update(%L::uuid, '{}')$$, ids[3]), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. "From now on": from_date counts, other Statuses and earlier dates stay -------
do $t$
declare t constant text := 'schedule_update_series_from_date_inclusive';
  r jsonb; ids uuid[]; u jsonb; o jsonb; sid uuid;
begin
  r := lifeos.schedule_create_series('{"series_description":"Weekly yoga at 6pm for five weeks","schedules":[
        {"title":"Yoga","planned_date":"2031-06-02","planned_time":"18:00","location":"Hall"},
        {"title":"Yoga","planned_date":"2031-06-09","planned_time":"18:00","location":"Hall"},
        {"title":"Yoga","planned_date":"2031-06-16","planned_time":"18:00","location":"Hall"},
        {"title":"Yoga","planned_date":"2031-06-23","planned_time":"18:00","location":"Hall"},
        {"title":"Yoga","planned_date":"2031-06-30","planned_time":"18:00","location":"Hall"}]}');
  sid := (r->>'series_id')::uuid;
  select array_agg((e->>'id')::uuid order by e->>'planned_date') into ids from jsonb_array_elements(r->'schedules') e;
  perform lifeos.schedule_update(ids[4], '{"status":"missed"}');   -- another Status: must stay unchanged

  u := lifeos.schedule_update_series(jsonb_build_object('series_id', sid, 'from_date', '2031-06-16',
        'changes', jsonb_build_object('planned_time','19:00','location','Studio','series_description','Weekly yoga; from 2031-06-16 at 7pm in Studio')));
  perform pg_temp.chk((u->>'updated_count')::int = 2, 'two target Schedules updated (from_date itself counts, the missed one does not), got ' || (u->>'updated_count'));
  perform pg_temp.chk(u->>'series_id' = sid::text, 'series_id returned');
  o := lifeos.schedule_read(ids[3]);
  perform pg_temp.chk(o->>'planned_time' = '19:00:00' and o->>'location' = 'Studio', 'Schedule on from_date is changed (inclusive)');
  perform pg_temp.chk(o->>'series_description' = 'Weekly yoga; from 2031-06-16 at 7pm in Studio', 'target gets the amended series_description');
  o := lifeos.schedule_read(ids[5]);
  perform pg_temp.chk(o->>'planned_time' = '19:00:00', 'a later planned Schedule is changed');
  o := lifeos.schedule_read(ids[2]);
  perform pg_temp.chk(o->>'planned_time' = '18:00:00' and o->>'location' = 'Hall' and o->>'series_description' = 'Weekly yoga at 6pm for five weeks',
    'a Schedule before from_date keeps its content and its series_description');
  o := lifeos.schedule_read(ids[4]);
  perform pg_temp.chk(o->>'status' = 'missed' and o->>'planned_time' = '18:00:00', 'a Schedule with another Status stays unchanged');
  perform pg_temp.chk(o->>'planned_date' = '2031-06-23', 'dates are not changed by the series update');

  perform pg_temp.expect_err(format($$select lifeos.schedule_update_series(jsonb_build_object('series_id', %L::uuid, 'changes', '{"location":"x"}'::jsonb))$$, sid), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.schedule_update_series(jsonb_build_object('series_id', %L::uuid, 'from_date', '2031-06-16', 'changes', '{"planned_date":"2031-07-01"}'::jsonb))$$, sid), 'unsupported field');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Stop a series: later planned Schedules become cancelled --------------------
do $t$
declare t constant text := 'schedule_stop_series_from_date_inclusive';
  r jsonb; ids uuid[]; u jsonb; o jsonb; sid uuid; e jsonb;
begin
  r := lifeos.schedule_create_series('{"series_description":"Weekly swim","schedules":[
        {"title":"Swim","planned_date":"2031-07-07"},
        {"title":"Swim","planned_date":"2031-07-14"},
        {"title":"Swim","planned_date":"2031-07-21"},
        {"title":"Swim","planned_date":"2031-07-28"}]}');
  sid := (r->>'series_id')::uuid;
  select array_agg((x->>'id')::uuid order by x->>'planned_date') into ids from jsonb_array_elements(r->'schedules') x;
  -- the third Schedule has occurred through an Event, so it keeps its Status
  e := lifeos.event_create(jsonb_build_object('occurred_date','2031-07-21','schedule_id', ids[3]));

  u := lifeos.schedule_stop_series(jsonb_build_object('series_id', sid, 'from_date', '2031-07-14'));
  perform pg_temp.chk((u->>'cancelled_count')::int = 2, 'two Schedules cancelled (07-14 inclusive and 07-28), got ' || (u->>'cancelled_count'));
  perform pg_temp.chk(u->>'series_id' = sid::text and jsonb_array_length(u->'schedules') = 2, 'cancelled Schedules returned');
  perform pg_temp.chk((select bool_and(x->>'status' = 'cancelled') from jsonb_array_elements(u->'schedules') x), 'returned Schedules are cancelled');
  perform pg_temp.chk(lifeos.schedule_read(ids[1])->>'status' = 'planned', 'a Schedule before from_date stays planned');
  perform pg_temp.chk(lifeos.schedule_read(ids[2])->>'status' = 'cancelled', 'a Schedule on from_date is cancelled (inclusive)');
  o := lifeos.schedule_read(ids[3]);
  perform pg_temp.chk(o->>'status' = 'occurred' and o->>'linked_event_id' = e->>'id', 'an occurred Schedule keeps its Status and its Event');
  perform pg_temp.chk(lifeos.event_read((e->>'id')::uuid)->>'deleted_at' is null, 'the Event stays active');
  perform pg_temp.expect_err(format($$select lifeos.schedule_stop_series(jsonb_build_object('series_id', %L::uuid))$$, sid), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Event actualises a Schedule and copies the planned date and time ------------
do $t$
declare t constant text := 'event_actualises_schedule_copies_planned_date_and_time';
  s jsonb; e jsonb; sid uuid; r jsonb; e2 jsonb;
begin
  s := lifeos.schedule_create('{"title":"Dentist","description":"Check-up","location":"Clinic A","planned_date":"2031-08-04","planned_time":"09:30"}');
  sid := (s->>'id')::uuid;
  e := lifeos.event_create(jsonb_build_object('schedule_id', sid, 'occurred_date', '2031-08-05', 'occurred_time', '10:15'));
  perform pg_temp.chk(e->>'title' = 'Dentist' and e->>'description' = 'Check-up' and e->>'location' = 'Clinic A', 'omitted title, description and location are copied from the Schedule');
  perform pg_temp.chk(e->>'occurred_date' = '2031-08-05' and e->>'occurred_time' = '10:15:00', 'actual date and time come from the input');
  perform pg_temp.chk(e->>'planned_date' = '2031-08-04' and e->>'planned_time' = '09:30:00', 'planned_date and planned_time are copied from the Schedule');
  perform pg_temp.chk(e->>'schedule_id' = sid::text, 'Event holds the schedule_id');
  perform pg_temp.chk(e->'schedule'->>'status' = 'occurred' and e->'schedule'->>'id' = sid::text, 'event_create returns the Schedule as occurred');
  r := lifeos.schedule_read(sid);
  perform pg_temp.chk(r->>'status' = 'occurred' and r->>'linked_event_id' = e->>'id', 'Schedule is occurred with linked_event_id');
  perform pg_temp.chk(r->>'planned_date' = '2031-08-04', 'the Schedule keeps its planned date');

  -- occurred_time unknown stays unknown; supplied title overrides the copy
  s := lifeos.schedule_create('{"title":"Lunch","planned_date":"2031-08-06","planned_time":"12:00"}');
  e2 := lifeos.event_create(jsonb_build_object('schedule_id', s->>'id', 'occurred_date', '2031-08-06', 'title', 'Long lunch with Sam'));
  perform pg_temp.chk(e2->>'occurred_time' is null, 'an unknown actual time stays unknown');
  perform pg_temp.chk(e2->>'title' = 'Long lunch with Sam', 'a supplied title is kept');
  perform pg_temp.chk(e2->>'planned_time' = '12:00:00', 'planned_time still copied');

  -- one Schedule has at most one active linked Event
  perform pg_temp.expect_err(format($$select lifeos.event_create(jsonb_build_object('schedule_id', %L::uuid, 'occurred_date', '2031-08-05'))$$, sid), 'invalid relationship');

  -- an ordinary Event has no Schedule link and no planned fields
  e := lifeos.event_create('{"title":"Walk","occurred_date":"2031-08-07"}');
  perform pg_temp.chk(e->>'schedule_id' is null and e->>'planned_date' is null and e->>'planned_time' is null, 'ordinary Event has no Schedule link and no planned fields');
  perform pg_temp.expect_err($$select lifeos.event_create('{"title":"x"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.event_create('{"occurred_date":"2031-08-07"}')$$, 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Link an existing Event to a Schedule ---------------------------------------
do $t$
declare t constant text := 'event_link_schedule_existing_event';
  s jsonb; e jsonb; r jsonb; s2 jsonb;
begin
  s := lifeos.schedule_create('{"title":"Meeting","planned_date":"2031-09-01","planned_time":"15:00"}');
  e := lifeos.event_create('{"title":"Team meeting","occurred_date":"2031-09-01","occurred_time":"15:20"}');
  r := lifeos.event_link_schedule((e->>'id')::uuid, (s->>'id')::uuid);
  perform pg_temp.chk(r->>'schedule_id' = s->>'id', 'Event holds the schedule_id');
  perform pg_temp.chk(r->>'planned_date' = '2031-09-01' and r->>'planned_time' = '15:00:00', 'planned date and time copied');
  perform pg_temp.chk(r->>'title' = 'Team meeting' and r->>'occurred_time' = '15:20:00', 'other Event content stays unchanged');
  perform pg_temp.chk(r->'schedule'->>'status' = 'occurred', 'Schedule is occurred');
  -- the Event already has a link
  s2 := lifeos.schedule_create('{"title":"Other","planned_date":"2031-09-02"}');
  perform pg_temp.expect_err(format($$select lifeos.event_link_schedule(%L::uuid, %L::uuid)$$, e->>'id', s2->>'id'), 'invalid relationship');
  -- the Schedule already has an Event
  e := lifeos.event_create('{"title":"Second","occurred_date":"2031-09-01"}');
  perform pg_temp.expect_err(format($$select lifeos.event_link_schedule(%L::uuid, %L::uuid)$$, e->>'id', s->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.event_link_schedule(%L::uuid, gen_random_uuid())$$, e->>'id'), 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. A Schedule with a linked Event rejects a status change ----------------------
do $t$
declare t constant text := 'schedule_status_locked_while_event_linked';
  s jsonb; e jsonb; u jsonb;
begin
  s := lifeos.schedule_create('{"title":"Haircut","planned_date":"2031-09-10"}');
  e := lifeos.event_create(jsonb_build_object('schedule_id', s->>'id', 'occurred_date', '2031-09-10'));
  perform pg_temp.expect_err(format($$select lifeos.schedule_update(%L::uuid, '{"status":"cancelled"}')$$, s->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.schedule_update(%L::uuid, '{"status":"missed"}')$$, s->>'id'), 'invalid relationship');
  u := lifeos.schedule_update((s->>'id')::uuid, '{"location":"Salon X"}');
  perform pg_temp.chk(u->>'location' = 'Salon X' and u->>'status' = 'occurred', 'a non-status change is still allowed and the Status stays occurred');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Overdue check: planned, yesterday or today, passed, no linked Event ---------
do $t$
declare t constant text := 'schedule_overdue_check';
  td date := pg_temp.today(); r jsonb; ids text[];
  a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; f jsonb; g jsonb; h jsonb;
begin
  a := lifeos.schedule_create(jsonb_build_object('title','OD timed yesterday','planned_date', td - 1, 'planned_time', '09:00'));
  b := lifeos.schedule_create(jsonb_build_object('title','OD date-only yesterday','planned_date', td - 1));
  c := lifeos.schedule_create(jsonb_build_object('title','OD date-only today','planned_date', td));
  d := lifeos.schedule_create(jsonb_build_object('title','OD timed later today','planned_date', td, 'planned_time', '23:59:59'));
  e := lifeos.schedule_create(jsonb_build_object('title','OD two days ago','planned_date', td - 2, 'planned_time', '09:00'));
  f := lifeos.schedule_create(jsonb_build_object('title','OD yesterday but occurred','planned_date', td - 1, 'planned_time', '08:00'));
  g := lifeos.schedule_create(jsonb_build_object('title','OD yesterday but missed','planned_date', td - 1, 'planned_time', '07:00'));
  h := lifeos.schedule_create(jsonb_build_object('title','OD yesterday but cancelled','planned_date', td - 1, 'planned_time', '06:00'));
  perform lifeos.event_create(jsonb_build_object('schedule_id', f->>'id', 'occurred_date', td - 1));
  perform lifeos.schedule_update((g->>'id')::uuid, '{"status":"missed"}');
  perform lifeos.schedule_update((h->>'id')::uuid, '{"status":"cancelled"}');

  r := lifeos.schedule_overdue_check('{}');
  select array_agg(x->>'id') into ids from jsonb_array_elements(r->'results') x;
  perform pg_temp.chk((a->>'id') = any(ids), 'a timed Schedule of yesterday has passed');
  perform pg_temp.chk((b->>'id') = any(ids), 'a date-only Schedule of yesterday has passed');
  perform pg_temp.chk(not ((c->>'id') = any(coalesce(ids, '{}'))), 'a date-only Schedule of today has not passed');
  perform pg_temp.chk(not ((d->>'id') = any(coalesce(ids, '{}'))), 'a timed Schedule later today has not passed');
  perform pg_temp.chk(not ((e->>'id') = any(coalesce(ids, '{}'))), 'a Schedule two days ago is outside the window');
  perform pg_temp.chk(not ((f->>'id') = any(coalesce(ids, '{}'))), 'an occurred Schedule is not returned');
  perform pg_temp.chk(not ((g->>'id') = any(coalesce(ids, '{}'))), 'a missed Schedule is not returned');
  perform pg_temp.chk(not ((h->>'id') = any(coalesce(ids, '{}'))), 'a cancelled Schedule is not returned');
  perform pg_temp.chk((r->>'returned_count')::int = cardinality(ids), 'returned_count matches results');
  -- order: planned_date then planned_time (timed 09:00 before the date-only one, nulls last)
  perform pg_temp.chk(r->'results'->0->>'id' = a->>'id', 'results ordered by planned_date, planned_time');
  -- null filter allowed
  r := lifeos.schedule_overdue_check(null);
  perform pg_temp.chk((r->>'returned_count')::int = cardinality(ids), 'a null filter is accepted');
  -- handling one removes it from the next check
  perform lifeos.schedule_update((a->>'id')::uuid, '{"status":"missed"}');
  r := lifeos.schedule_overdue_check('{}');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(r->'results') x where x->>'id' = a->>'id') = 0, 'a handled Schedule is not asked again');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Event delete returns the Schedule to planned -------------------------------
do $t$
declare t constant text := 'event_delete_returns_schedule_to_planned';
  s jsonb; e jsonb; d jsonb; r jsonb; e2 jsonb; sr jsonb; er jsonb;
begin
  s := lifeos.schedule_create('{"title":"Gym session","planned_date":"2031-10-03","planned_time":"07:00"}');
  e := lifeos.event_create(jsonb_build_object('schedule_id', s->>'id', 'occurred_date', '2031-10-03'));
  d := lifeos.event_delete((e->>'id')::uuid);
  perform pg_temp.chk(d->>'id' = e->>'id' and d->>'deleted_at' is not null, 'delete returns id and deleted_at');
  perform pg_temp.chk(d->>'schedule_returned_to_planned' = s->>'id', 'schedule_returned_to_planned names the Schedule');
  sr := lifeos.schedule_read((s->>'id')::uuid);
  perform pg_temp.chk(sr->>'status' = 'planned' and sr->>'linked_event_id' is null, 'Schedule is planned again with no linked Event');
  er := lifeos.event_read((e->>'id')::uuid);
  perform pg_temp.chk(er->>'deleted_at' is not null and er->>'schedule_id' is null, 'the deleted Event has no Schedule link');
  -- the Schedule is free to take a new Event
  e2 := lifeos.event_create(jsonb_build_object('schedule_id', s->>'id', 'occurred_date', '2031-10-04'));
  perform pg_temp.chk(e2->'schedule'->>'status' = 'occurred', 'the returned Schedule can be actualised again');
  -- deleting an Event without a Schedule
  e := lifeos.event_create('{"title":"Stroll","occurred_date":"2031-10-05"}');
  d := lifeos.event_delete((e->>'id')::uuid);
  perform pg_temp.chk(d->>'schedule_returned_to_planned' is null, 'schedule_returned_to_planned is null without a Schedule');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Observation linked to an Event --------------------------------------------
do $t$
declare t constant text := 'observation_linked_to_event';
  subj jsonb; e jsonb; o1 jsonb; o2 jsonb; o3 jsonb; er jsonb; r jsonb;
begin
  subj := lifeos.subject_create('{"name":"Me (obs test)","subject_type":"person"}');
  e := lifeos.event_create('{"title":"Doctor visit","occurred_date":"2031-11-03","occurred_time":"10:00"}');
  o1 := lifeos.observation_create(jsonb_build_object('subject_id', subj->>'id', 'observation_name', 'weight', 'value_numeric', 72.55, 'unit', 'kg',
          'observed_date', '2031-11-03', 'observed_time', '10:05', 'event_id', e->>'id'));
  o2 := lifeos.observation_create(jsonb_build_object('subject_id', subj->>'id', 'observation_name', 'blood pressure', 'value_text', '120/80',
          'observed_date', '2031-11-03', 'event_id', e->>'id'));
  o3 := lifeos.observation_create(jsonb_build_object('subject_id', subj->>'id', 'observation_name', 'weight', 'value_numeric', 72.1, 'unit', 'kg',
          'observed_date', '2031-11-10'));
  perform pg_temp.chk((o1->>'value_numeric')::numeric = 72.55, 'numeric precision is kept');
  perform pg_temp.chk(o2->>'value_text' = '120/80' and o2->>'value_numeric' is null, 'compound reading stored as text');
  perform pg_temp.chk(o1->>'event_id' = e->>'id', 'Observation holds the event_id');
  perform pg_temp.chk(o3->>'event_id' is null, 'an Observation without event_id links only to its Subject');
  er := lifeos.event_read((e->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(er->'observations') = 2, 'the Event lists its two Observations');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(er->'observations') x where x->>'id' in (o1->>'id', o2->>'id')) = 2, 'the listed Observations are the linked ones');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(er->'links') l where l->>'via' = 'observation_event' and l->>'id' = o1->>'id'), 'event_read links include observation_event');
  r := lifeos.observation_search(jsonb_build_object('subject_id', subj->>'id', 'observation_name', 'WEIGHT'));
  perform pg_temp.chk((r->>'returned_count')::int = 2, 'observation_name is a case-insensitive exact match');
  perform pg_temp.chk(r->'results'->0->>'id' = o3->>'id', 'results ordered by observed_date descending');
  r := lifeos.observation_search(jsonb_build_object('event_id', e->>'id'));
  perform pg_temp.chk((r->>'returned_count')::int = 2, 'search by event_id');
  r := lifeos.observation_search(jsonb_build_object('subject_id', subj->>'id', 'from_date','2031-11-10','to_date','2031-11-10'));
  perform pg_temp.chk((r->>'returned_count')::int = 1, 'from_date and to_date filter observed_date inclusively');
  r := lifeos.observation_read((o1->>'id')::uuid);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(r->'links') l where l->>'via' = 'observation_subject' and l->>'id' = subj->>'id'), 'observation_read links include the Subject');
  -- validation
  perform pg_temp.expect_err(format($$select lifeos.observation_create(jsonb_build_object('subject_id', %L::uuid, 'observation_name','x','observed_date','2031-11-03'))$$, subj->>'id'), 'invalid input');
  perform pg_temp.expect_err($$select lifeos.observation_create('{"observation_name":"x","value_text":"y","observed_date":"2031-11-03"}')$$, 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.observation_create(jsonb_build_object('subject_id', %L::uuid, 'observation_name','x','value_text','y'))$$, subj->>'id'), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.observation_create(jsonb_build_object('subject_id', %L::uuid, 'observation_name','x','value_text','y','observed_date','2031-11-03','event_id', gen_random_uuid()))$$, subj->>'id'), 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Observation correction keeps the observation time --------------------------
do $t$
declare t constant text := 'observation_update_keeps_observed_time';
  subj jsonb; o jsonb; u jsonb;
begin
  subj := lifeos.subject_create('{"name":"Me (obs update test)"}');
  o := lifeos.observation_create(jsonb_build_object('subject_id', subj->>'id', 'observation_name', 'weight', 'value_numeric', 80, 'unit','kg',
        'observed_date','2031-12-01','observed_time','08:00'));
  u := lifeos.observation_update((o->>'id')::uuid, '{"value_numeric": 79.5}');
  perform pg_temp.chk((u->>'value_numeric')::numeric = 79.5, 'value corrected');
  perform pg_temp.chk(u->>'observed_date' = '2031-12-01' and u->>'observed_time' = '08:00:00', 'observed date and time unchanged');
  perform pg_temp.expect_err(format($$select lifeos.observation_update(%L::uuid, '{"observed_date":"2031-12-02"}')$$, o->>'id'), 'unsupported field');
  perform pg_temp.expect_err(format($$select lifeos.observation_update(%L::uuid, '{"observed_time":"09:00"}')$$, o->>'id'), 'unsupported field');
  -- the result must still hold a value
  perform pg_temp.expect_err(format($$select lifeos.observation_update(%L::uuid, '{"value_numeric":null}')$$, o->>'id'), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 13. Note date: edit moves it, a Remark does not --------------------------------
do $t$
declare t constant text := 'note_date_after_edit_unchanged_after_remark';
  n jsonb; nid uuid; td date := pg_temp.today(); r jsonb; u jsonb; before_updated timestamptz; s jsonb;
begin
  n := lifeos.note_create('{"note_type":"Feeling","content":"Felt calm after the walk","title":"Calm"}');
  nid := (n->>'id')::uuid;
  perform pg_temp.chk(n->>'note_date' = td::text, 'a new Note is dated on its record date (today)');
  perform pg_temp.chk(n->>'edited_at' is null, 'edited_at is null before an edit');
  perform pg_temp.expect_err($$select lifeos.note_create('{"note_type":"Idea","content":"x","note_date":"2031-01-01"}')$$, 'unsupported field');
  perform pg_temp.expect_err($$select lifeos.note_create('{"note_type":"Idea"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.note_create('{"content":"x"}')$$, 'invalid input');

  -- Test setup: move created_at 10 days into the past (one transaction has one clock value).
  update lifeos.notes set created_at = created_at - interval '10 days', updated_at = updated_at - interval '10 days' where id = nid;
  r := lifeos.note_read(nid);
  perform pg_temp.chk(r->>'note_date' = (td - 10)::text, 'the Note is dated on its created date until it is edited, got ' || (r->>'note_date'));
  before_updated := (r->>'updated_at')::timestamptz;

  r := lifeos.record_add_remark('note', nid, '  Still feeling calm  ');
  perform pg_temp.chk(r->>'note_date' = (td - 10)::text, 'a Remark leaves the Note date unchanged');
  perform pg_temp.chk(r->>'edited_at' is null, 'a Remark leaves edited_at null');
  perform pg_temp.chk((r->>'updated_at')::timestamptz = before_updated, 'a Remark leaves updated_at unchanged');
  perform pg_temp.chk(r->'remarks'->0->>'text' = 'Still feeling calm', 'Remark text is trimmed');

  u := lifeos.note_update(nid, '{"content":"Felt calm and rested after the walk"}');
  perform pg_temp.chk(u->>'edited_at' is not null, 'note_update sets edited_at');
  perform pg_temp.chk(u->>'note_date' = td::text, 'after an edit the Note date is the edit date, got ' || (u->>'note_date'));
  perform pg_temp.chk(u->>'content' = 'Felt calm and rested after the walk' and u->>'title' = 'Calm', 'content replaced, title kept');

  -- note_search filters by note_date
  s := lifeos.note_search(jsonb_build_object('from_date', td, 'to_date', td, 'keyword', 'rested'));
  perform pg_temp.chk((s->>'returned_count')::int = 1, 'the edited Note is found on today''s note_date');
  s := lifeos.note_search(jsonb_build_object('from_date', td - 10, 'to_date', td - 10, 'keyword', 'rested'));
  perform pg_temp.chk((s->>'returned_count')::int = 0, 'the edited Note is no longer found on its created date');
  perform pg_temp.chk(lifeos.note_search('{"note_type":"FEELING","keyword":"rested"}')->>'returned_count' = '1', 'note_type is a case-insensitive exact match');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 14. Record links: create, dedupe, delete, and ignored deleted targets ----------
do $t$
declare t constant text := 'record_links_ignore_deleted_targets';
  n jsonb; e jsonb; s jsonb; l1 jsonb; l2 jsonb; rl jsonb; subj jsonb; ev jsonb; er jsonb; sr jsonb;
begin
  e := lifeos.event_create('{"title":"Dinner","occurred_date":"2032-01-05"}');
  n := lifeos.note_create('{"note_type":"Feeling","content":"Dinner made me happy"}');
  subj := lifeos.subject_create('{"name":"Nicholas (link test)","subject_type":"person"}');
  l1 := lifeos.record_link_create(jsonb_build_object('from_type','note','from_id', n->>'id','to_type','event','to_id', e->>'id'));
  perform pg_temp.chk(l1->>'link_id' is not null and l1->>'from_type' = 'note' and l1->>'to_type' = 'event', 'link created');
  l2 := lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', e->>'id','to_type','note','to_id', n->>'id'));
  perform pg_temp.chk(l2->>'link_id' = l1->>'link_id', 'the same pair in the other direction returns the existing link');
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', e->>'id','to_type','subject','to_id', subj->>'id'));

  rl := lifeos.record_links_read('note', (n->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rl->'links') = 1 and rl->'links'->0->>'record_type' = 'event' and rl->'links'->0->>'via' = 'record_link', 'record_links_read from the Note shows the Event');
  perform pg_temp.chk(rl->'links'->0->>'summary' = 'Dinner' and rl->'links'->0->>'occurrence_date' = '2032-01-05', 'link summary and occurrence_date');
  rl := lifeos.record_links_read('event', (e->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rl->'links') = 2, 'the Event lists the Note and the Subject');

  -- invalid links
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', %L::uuid,'to_type','event','to_id', %L::uuid))$$, e->>'id', e->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','subject','from_id', %L::uuid,'to_type','subject','to_id', %L::uuid))$$, subj->>'id', subj->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','note','from_id', %L::uuid,'to_type','event','to_id', gen_random_uuid()))$$, n->>'id'), 'record not found');

  -- delete the Event: the Note's links ignore it, the Subject link of the Event stays stored
  perform lifeos.event_delete((e->>'id')::uuid);
  rl := lifeos.record_links_read('note', (n->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rl->'links') = 0, 'a deleted Event is omitted from the Note''s links');
  perform pg_temp.chk(lifeos.note_read((n->>'id')::uuid) ? 'links' and jsonb_array_length(lifeos.note_read((n->>'id')::uuid)->'links') = 0, 'note_read links omit the deleted Event');
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','note','from_id', %L::uuid,'to_type','event','to_id', %L::uuid))$$, n->>'id', e->>'id'), 'record deleted');

  -- scalar reference: Event.schedule_id and Observation.event_id read as null once the target is deleted
  s := lifeos.schedule_create('{"title":"Planned dinner","planned_date":"2032-01-05"}');
  ev := lifeos.event_create(jsonb_build_object('schedule_id', s->>'id', 'occurred_date', '2032-01-05'));
  perform lifeos.schedule_delete((s->>'id')::uuid);
  er := lifeos.event_read((ev->>'id')::uuid);
  perform pg_temp.chk(er->>'schedule_id' is null, 'event.schedule_id reads null after the Schedule is deleted');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(er->'links') l where l->>'via' = 'schedule'), 'the deleted Schedule is omitted from event links');
  e := lifeos.event_create('{"title":"Check-up","occurred_date":"2032-01-06"}');
  perform lifeos.observation_create(jsonb_build_object('subject_id', subj->>'id','observation_name','pulse','value_numeric',60,'observed_date','2032-01-06','event_id', e->>'id'));
  perform lifeos.event_delete((e->>'id')::uuid);
  perform pg_temp.chk((lifeos.observation_search(jsonb_build_object('subject_id', subj->>'id','observation_name','pulse'))->'results'->0->>'event_id') is null,
    'observation.event_id reads null after the Event is deleted');

  -- record_link_delete
  e := lifeos.event_create('{"title":"Coffee","occurred_date":"2032-01-07"}');
  n := lifeos.note_create('{"note_type":"General","content":"coffee note"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','note','from_id', n->>'id','to_type','event','to_id', e->>'id'));
  perform pg_temp.chk((lifeos.record_link_delete(jsonb_build_object('from_type','event','from_id', e->>'id','to_type','note','to_id', n->>'id'))->>'removed')::boolean, 'link removed in either direction');
  perform pg_temp.chk(not (lifeos.record_link_delete(jsonb_build_object('from_type','event','from_id', e->>'id','to_type','note','to_id', n->>'id'))->>'removed')::boolean, 'a missing link returns removed false');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 15. Remarks: append, validation, Records that cannot take a Remark --------------
do $t$
declare t constant text := 'record_add_remark_rules';
  s jsonb; r jsonb; e jsonb; before_updated timestamptz;
begin
  s := lifeos.schedule_create('{"title":"Visit museum","planned_date":"2032-02-01"}');
  -- Test setup: move updated_at 5 days back (one transaction has one clock value).
  update lifeos.schedules set updated_at = updated_at - interval '5 days' where id = (s->>'id')::uuid;
  select updated_at into before_updated from lifeos.schedules where id = (s->>'id')::uuid;
  r := lifeos.record_add_remark('schedule', (s->>'id')::uuid, '  bring the camera ');
  perform pg_temp.chk((select updated_at from lifeos.schedules where id = (s->>'id')::uuid) = before_updated, 'a Remark leaves updated_at unchanged');
  perform pg_temp.chk(jsonb_array_length(r->'remarks') = 1 and r->'remarks'->0->>'text' = 'bring the camera', 'one trimmed Remark appended');
  perform pg_temp.chk(r->'remarks'->0->>'timestamp' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', 'the Remark has an ISO 8601 timestamp');
  r := lifeos.record_add_remark('schedule', (s->>'id')::uuid, 'and the tickets');
  perform pg_temp.chk(jsonb_array_length(r->'remarks') = 2, 'a second Remark is appended');
  perform pg_temp.chk(r->>'title' = 'Visit museum' and r->>'planned_date' = '2032-02-01', 'the Record content is unchanged');
  -- Remarks given at create time follow Contract shared.md 1.5 item 10
  e := lifeos.event_create('{"title":"Museum","occurred_date":"2032-02-01","remarks":["plain string",{"text":"object form","timestamp":"2032-02-01T08:00:00+08:00"}]}');
  perform pg_temp.chk(jsonb_array_length(e->'remarks') = 2 and e->'remarks'->0->>'text' = 'plain string' and e->'remarks'->0->>'timestamp' is not null, 'string Remark gets a timestamp');
  perform pg_temp.chk(e->'remarks'->1->>'timestamp' like '2032-02-01T00:00:00%', 'a supplied timestamp is normalised to UTC, got ' || (e->'remarks'->1->>'timestamp'));
  -- search sees Remark text
  perform pg_temp.chk((lifeos.schedule_search('{"keyword":"TICKETS"}')->>'returned_count')::int = 1, 'schedule_search keyword matches Remark text');
  -- errors
  perform pg_temp.expect_err(format($$select lifeos.record_add_remark('schedule', %L::uuid, '   ')$$, s->>'id'), 'invalid input');
  perform pg_temp.expect_err($$select lifeos.record_add_remark('subject', gen_random_uuid(), 'x')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.record_add_remark('schedule', gen_random_uuid(), 'x')$$, 'record not found');
  perform lifeos.schedule_delete((s->>'id')::uuid);
  perform pg_temp.expect_err(format($$select lifeos.record_add_remark('schedule', %L::uuid, 'x')$$, s->>'id'), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 16. Soft delete: read after delete, search with include_deleted, no update ------
do $t$
declare t constant text := 'soft_delete_read_and_search_deleted';
  s jsonb; d1 jsonb; d2 jsonb; r jsonb; n jsonb;
begin
  s := lifeos.schedule_create('{"title":"Doomed schedule xq","planned_date":"2032-03-01"}');
  d1 := lifeos.schedule_delete((s->>'id')::uuid);
  d2 := lifeos.schedule_delete((s->>'id')::uuid);
  perform pg_temp.chk(d1->>'deleted_at' = d2->>'deleted_at', 'a second delete returns the existing deleted_at');
  r := lifeos.schedule_read((s->>'id')::uuid);
  perform pg_temp.chk(r->>'deleted_at' is not null, 'schedule_read returns a deleted Schedule');
  perform pg_temp.chk((lifeos.schedule_search('{"keyword":"Doomed schedule xq"}')->>'returned_count')::int = 0, 'search hides a deleted Schedule by default');
  r := lifeos.schedule_search('{"keyword":"Doomed schedule xq","include_deleted":true}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and (r->>'include_deleted')::boolean, 'include_deleted shows it');
  perform pg_temp.expect_err(format($$select lifeos.schedule_update(%L::uuid, '{"title":"x"}')$$, s->>'id'), 'record deleted');
  perform pg_temp.expect_err($$select lifeos.schedule_read(gen_random_uuid())$$, 'record not found');
  n := lifeos.note_create('{"note_type":"General","content":"doomed note xq"}');
  perform lifeos.note_delete((n->>'id')::uuid);
  perform pg_temp.chk((lifeos.note_search('{"keyword":"doomed note xq"}')->>'returned_count')::int = 0, 'search hides a deleted Note');
  perform pg_temp.expect_err(format($$select lifeos.note_update(%L::uuid, '{"content":"x"}')$$, n->>'id'), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 17. Remark change and delete: remark_id, unchanged dates, no Expense version (M-0020 F1, D2)
do $t$
declare t constant text := 'record_update_remark_and_record_delete_remark_leave_record_dates_unchanged';
  td date := pg_temp.today(); s jsonb; r jsonb; e jsonb; n jsonb; x jsonb; sid uuid; nid uuid; xid uuid;
  rid1 text; rid2 text; ts1 text; before_updated timestamptz; pm uuid; missing int;
begin
  -- record_add_remark and create-time Remarks carry a remark_id
  s := lifeos.schedule_create('{"title":"Visit gallery","planned_date":"2032-04-01","remarks":["bring water"]}');
  sid := (s->>'id')::uuid;
  perform pg_temp.chk((s->'remarks'->0->>'remark_id')::uuid is not null, 'a create-time Remark has a remark_id');
  r := lifeos.record_add_remark('schedule', sid, 'bring the camera');
  rid1 := r->'remarks'->0->>'remark_id';
  rid2 := r->'remarks'->1->>'remark_id';
  ts1 := r->'remarks'->0->>'timestamp';
  perform pg_temp.chk(rid2::uuid is not null and rid1 <> rid2, 'record_add_remark appends a Remark with a new remark_id');

  -- Test setup: move updated_at 5 days back (one transaction has one clock value).
  update lifeos.schedules set updated_at = updated_at - interval '5 days' where id = sid;
  select updated_at into before_updated from lifeos.schedules where id = sid;

  r := lifeos.record_update_remark('schedule', sid, rid1::uuid, '  bring two bottles of water ');
  perform pg_temp.chk(r->'remarks'->0->>'text' = 'bring two bottles of water', 'record_update_remark replaces the trimmed text');
  perform pg_temp.chk(r->'remarks'->0->>'remark_id' = rid1 and r->'remarks'->0->>'timestamp' = ts1, 'remark_id and timestamp stay');
  perform pg_temp.chk(r->'remarks'->1->>'text' = 'bring the camera', 'the other Remark stays');
  perform pg_temp.chk(r->>'title' = 'Visit gallery' and r ? 'linked_event_id', 'record_update_remark returns the complete Record');
  perform pg_temp.chk((select updated_at from lifeos.schedules where id = sid) = before_updated, 'record_update_remark leaves updated_at unchanged');
  r := lifeos.record_delete_remark('schedule', sid, rid1::uuid);
  perform pg_temp.chk(jsonb_array_length(r->'remarks') = 1 and r->'remarks'->0->>'remark_id' = rid2, 'record_delete_remark removes only that Remark');
  perform pg_temp.chk(r->>'title' = 'Visit gallery', 'record_delete_remark returns the complete Record');
  perform pg_temp.chk((select updated_at from lifeos.schedules where id = sid) = before_updated, 'record_delete_remark leaves updated_at unchanged');

  -- Note: edited_at, Note date and updated_at stay
  n := lifeos.note_create('{"note_type":"General","content":"Gallery thoughts"}');
  nid := (n->>'id')::uuid;
  -- Test setup: move created_at and updated_at 10 days back.
  update lifeos.notes set created_at = created_at - interval '10 days', updated_at = updated_at - interval '10 days' where id = nid;
  select updated_at into before_updated from lifeos.notes where id = nid;
  r := lifeos.record_add_remark('note', nid, 'first remark');
  r := lifeos.record_update_remark('note', nid, (r->'remarks'->0->>'remark_id')::uuid, 'changed remark');
  perform pg_temp.chk(r->'remarks'->0->>'text' = 'changed remark', 'the Note Remark is changed');
  perform pg_temp.chk(r->>'edited_at' is null and r->>'note_date' = (td - 10)::text, 'a Remark change leaves edited_at and the Note date unchanged');
  perform pg_temp.chk((r->>'updated_at')::timestamptz = before_updated, 'a Remark change leaves the Note updated_at unchanged');
  r := lifeos.record_delete_remark('note', nid, (r->'remarks'->0->>'remark_id')::uuid);
  perform pg_temp.chk(r->'remarks' = '[]'::jsonb, 'the Note Remark is deleted');
  perform pg_temp.chk(r->>'edited_at' is null and r->>'note_date' = (td - 10)::text and (r->>'updated_at')::timestamptz = before_updated,
    'a Remark delete leaves edited_at, the Note date and updated_at unchanged');

  -- Expense: no correction version
  pm := ((lifeos.subject_create('{"name":"Card remark test","subject_type":"payment method"}'))->>'id')::uuid;
  x := lifeos.expense_create(jsonb_build_object('transaction_date','2032-04-02','payment_method_subject_id', pm,'expense_total', 12,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',12,'line_total',12,'category','food'))));
  xid := (x->>'id')::uuid;
  r := lifeos.record_add_remark('expense', xid, 'shared with a friend');
  r := lifeos.record_update_remark('expense', xid, (r->'remarks'->0->>'remark_id')::uuid, 'shared with two friends');
  perform pg_temp.chk(r->'remarks'->0->>'text' = 'shared with two friends' and (r->>'version')::int = 1, 'a Remark change on an Expense creates no correction version');
  r := lifeos.record_delete_remark('expense', xid, (r->'remarks'->0->>'remark_id')::uuid);
  perform pg_temp.chk(r->'remarks' = '[]'::jsonb and (r->>'version')::int = 1, 'a Remark delete on an Expense creates no correction version');
  perform pg_temp.chk((select count(*) from lifeos.expense_versions h where h.expense_id = xid) = 0, 'the Expense has no history version');

  -- errors
  perform pg_temp.expect_err(format($$select lifeos.record_update_remark('schedule', %L::uuid, %L::uuid, '  ')$$, sid, rid2), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.record_update_remark('subject', %L::uuid, %L::uuid, 'x')$$, sid, rid2), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.record_delete_remark('reading', %L::uuid, %L::uuid)$$, sid, rid2), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.record_update_remark('schedule', %L::uuid, gen_random_uuid(), 'x')$$, sid), 'record not found');
  perform pg_temp.expect_err(format($$select lifeos.record_delete_remark('schedule', %L::uuid, gen_random_uuid())$$, sid), 'record not found');
  perform pg_temp.expect_err(format($$select lifeos.record_delete_remark('schedule', %L::uuid, %L::uuid)$$, sid, rid1), 'record not found');
  perform pg_temp.expect_err(format($$select lifeos.record_update_remark('schedule', gen_random_uuid(), %L::uuid, 'x')$$, rid2), 'record not found');
  perform lifeos.schedule_delete(sid);
  perform pg_temp.expect_err(format($$select lifeos.record_update_remark('schedule', %L::uuid, %L::uuid, 'x')$$, sid, rid2), 'record deleted');
  perform pg_temp.expect_err(format($$select lifeos.record_delete_remark('schedule', %L::uuid, %L::uuid)$$, sid, rid2), 'record deleted');

  -- backfill: every stored Remark of the five Record tables has a remark_id
  select count(*) into missing from (
    select remarks from lifeos.schedules union all select remarks from lifeos.events
    union all select remarks from lifeos.observations union all select remarks from lifeos.notes
    union all select remarks from lifeos.expenses) a
  cross join lateral jsonb_array_elements(a.remarks) e(v)
  where not (e.v ? 'remark_id');
  perform pg_temp.chk(missing = 0, 'every stored Remark has a remark_id, missing ' || missing);
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 18. Record links: a Reading and a Storyline cannot be linked (M-0020 F2) ---------
do $t$
declare t constant text := 'record_link_create_rejects_reading_storyline_pair';
  d jsonb; rid text; sl jsonb; ev jsonb;
begin
  d := lifeos.divination_record_save('{"readings":[{"question":"Link Q","method":"tarot","result_text":"Link R"}]}');
  rid := d->'readings'->0->>'id';
  sl := lifeos.storyline_create('{"content":"Link test storyline"}');
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','reading','from_id', %L::uuid,'to_type','storyline','to_id', %L::uuid))$$, rid, sl->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','storyline','from_id', %L::uuid,'to_type','reading','to_id', %L::uuid))$$, sl->>'id', rid), 'invalid relationship');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lifeos.record_links_read('reading', rid::uuid)->'links') l where l->>'record_type' = 'storyline'), 'the Reading has no Storyline link');
  -- a Reading and a Storyline still link to other Records
  ev := lifeos.event_create('{"title":"Link test event","occurred_date":"2032-04-03"}');
  perform pg_temp.chk(lifeos.record_link_create(jsonb_build_object('from_type','reading','from_id', rid,'to_type','event','to_id', ev->>'id'))->>'link_id' is not null, 'a Reading links to an Event');
  perform pg_temp.chk(lifeos.record_link_create(jsonb_build_object('from_type','storyline','from_id', sl->>'id','to_type','event','to_id', ev->>'id'))->>'link_id' is not null, 'a Storyline links to an Event');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 19. A Divination Record and a Storyline never link, in either order (M-0021 D5) ------------------
do $t$
declare t constant text := 'record_link_create_rejects_divination_record_storyline_pair';
  d jsonb; did text; sl jsonb; ev jsonb;
begin
  d := lifeos.divination_record_save('{"readings":[{"question":"D5 Q","method":"tarot","result_text":"D5 R"}]}');
  did := d->>'id';
  sl := lifeos.storyline_create('{"content":"D5 storyline"}');
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','divination_record','from_id', %L::uuid,'to_type','storyline','to_id', %L::uuid))$$, did, sl->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','storyline','from_id', %L::uuid,'to_type','divination_record','to_id', %L::uuid))$$, sl->>'id', did), 'invalid relationship');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lifeos.record_links_read('divination_record', did::uuid)->'links') l where l->>'record_type' = 'storyline'), 'the Divination Record has no Storyline link');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lifeos.record_links_read('storyline', (sl->>'id')::uuid)->'links') l where l->>'record_type' = 'divination_record'), 'the Storyline has no Divination Record link');
  -- the Reading rule of M-0020 stays, and both Records still link to other Records
  perform pg_temp.expect_err(format($$select lifeos.record_link_create(jsonb_build_object('from_type','reading','from_id', %L::uuid,'to_type','storyline','to_id', %L::uuid))$$, d->'readings'->0->>'id', sl->>'id'), 'invalid relationship');
  ev := lifeos.event_create('{"title":"D5 event","occurred_date":"2032-04-04"}');
  perform pg_temp.chk(lifeos.record_link_create(jsonb_build_object('from_type','divination_record','from_id', did,'to_type','event','to_id', ev->>'id'))->>'link_id' is not null, 'a Divination Record links to an Event');
  perform pg_temp.chk(lifeos.record_link_create(jsonb_build_object('from_type','storyline','from_id', sl->>'id','to_type','event','to_id', ev->>'id'))->>'link_id' is not null, 'a Storyline links to an Event');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 20. Deleting an Event leaves the Status of its deleted Schedule unchanged (M-0021 D9) --------------
do $t$
declare t constant text := 'event_delete_keeps_status_of_deleted_schedule';
  s jsonb; e jsonb; d jsonb; before jsonb; after jsonb; v_stored uuid;
begin
  s := lifeos.schedule_create('{"title":"D9 schedule","planned_date":"2031-11-03"}');
  e := lifeos.event_create(jsonb_build_object('schedule_id', s->>'id', 'occurred_date', '2031-11-03'));
  perform pg_temp.chk(e->'schedule'->>'status' = 'occurred', 'the Schedule is Occurred before the deletes');
  perform lifeos.schedule_delete((s->>'id')::uuid);
  before := lifeos.schedule_read((s->>'id')::uuid);
  d := lifeos.event_delete((e->>'id')::uuid);
  perform pg_temp.chk(d->>'id' = e->>'id' and d->>'deleted_at' is not null, 'delete returns id and deleted_at');
  perform pg_temp.chk(d ? 'schedule_returned_to_planned' and d->>'schedule_returned_to_planned' is null, 'schedule_returned_to_planned is null for a deleted Schedule');
  after := lifeos.schedule_read((s->>'id')::uuid);
  perform pg_temp.chk(after->>'status' = 'occurred', 'the deleted Schedule keeps its Status, got ' || coalesce(after->>'status', 'null'));
  perform pg_temp.chk(after->>'updated_at' = before->>'updated_at', 'the deleted Schedule is not touched');
  select x.schedule_id into v_stored from lifeos.events x where x.id = (e->>'id')::uuid;
  perform pg_temp.chk(v_stored is null, 'the Event''s stored schedule link is removed');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 21. event_search and observation_search: a filter ID of a deleted Record matches nothing (M-0021 D10)
do $t$
declare t constant text := 'event_and_observation_search_filter_by_deleted_record_id_matches_nothing';
  subj jsonb; sc jsonb; ev jsonb; ev2 jsonb; ob jsonb; r jsonb;
begin
  subj := lifeos.subject_create('{"name":"D10 person","subject_type":"person"}');
  sc := lifeos.schedule_create('{"title":"D10xq planned","planned_date":"2032-05-01"}');
  ev2 := lifeos.event_create(jsonb_build_object('schedule_id', sc->>'id', 'occurred_date', '2032-05-01'));
  ev := lifeos.event_create('{"title":"D10xq event","occurred_date":"2032-05-01"}');
  ob := lifeos.observation_create(jsonb_build_object('subject_id', subj->>'id','observation_name','d10metric','value_numeric',1,'observed_date','2032-05-01','event_id', ev->>'id'));
  -- active targets match
  perform pg_temp.chk((lifeos.event_search(jsonb_build_object('schedule_id', sc->>'id'))->>'returned_count')::int = 1, 'schedule_id of an active Schedule matches its Event');
  perform pg_temp.chk((lifeos.observation_search(jsonb_build_object('subject_id', subj->>'id'))->>'returned_count')::int = 1, 'subject_id of an active Subject matches');
  perform pg_temp.chk((lifeos.observation_search(jsonb_build_object('event_id', ev->>'id'))->>'returned_count')::int = 1, 'event_id of an active Event matches');
  -- deleted targets match nothing, without an error
  perform lifeos.schedule_delete((sc->>'id')::uuid);
  perform pg_temp.chk((lifeos.event_search(jsonb_build_object('schedule_id', sc->>'id'))->>'returned_count')::int = 0, 'schedule_id of a deleted Schedule matches nothing');
  perform pg_temp.chk((lifeos.event_search(jsonb_build_object('schedule_id', sc->>'id', 'include_deleted', true))->>'returned_count')::int = 0, 'also with include_deleted');
  r := lifeos.event_search('{"keyword":"D10xq","from_date":"2032-05-01","to_date":"2032-05-01"}');
  perform pg_temp.chk((r->>'returned_count')::int = 2 and exists (select 1 from jsonb_array_elements(r->'results') x where x->>'id' = ev2->>'id'), 'the Event stays findable by keyword and dates');
  perform lifeos.subject_delete((subj->>'id')::uuid);
  perform pg_temp.chk((lifeos.observation_search(jsonb_build_object('subject_id', subj->>'id'))->>'returned_count')::int = 0, 'subject_id of a deleted Subject matches nothing');
  perform lifeos.event_delete((ev->>'id')::uuid);
  perform pg_temp.chk((lifeos.observation_search(jsonb_build_object('event_id', ev->>'id'))->>'returned_count')::int = 0, 'event_id of a deleted Event matches nothing');
  r := lifeos.observation_search('{"observation_name":"d10metric","from_date":"2032-05-01","to_date":"2032-05-01"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = ob->>'id', 'the Observation stays findable by name and dates');
  perform pg_temp.chk((lifeos.observation_search(jsonb_build_object('subject_id', gen_random_uuid()))->>'returned_count')::int = 0, 'an unknown ID matches nothing');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 22. record_links_read on a Subject lists each Record once with every path (M-0022 D4) -----------
do $t$
declare t constant text := 'record_links_read_on_subject_lists_each_record_once_with_every_path';
  c uuid; ex jsonb; ex2 jsonb; ex3 jsonb; ob jsonb; n jsonb; sp jsonb; pr jsonb; rl jsonb; l jsonb; vias text[];
begin
  c := ((lifeos.subject_create('{"name":"D4 person and card","subject_type":"person"}'))->>'id')::uuid;
  -- an Expense whose Payment Method, Merchant and two Line Items are the Subject, plus a Record link to it
  ex := lifeos.expense_create(jsonb_build_object('transaction_date','2032-06-01','payment_method_subject_id', c,'merchant_subject_id', c,
        'expense_total', 15,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',10,'line_total',10,'category','other','item_subject_id', c),
                                   jsonb_build_object('line_type','item','unit_price',5,'line_total',5,'category','other','item_subject_id', c))));
  perform lifeos.record_link_create(jsonb_build_object('from_type','subject','from_id', c,'to_type','expense','to_id', ex->>'id'));
  -- an Expense whose Payment Method and Merchant are the Subject, without a Record link
  ex2 := lifeos.expense_create(jsonb_build_object('transaction_date','2032-06-02','payment_method_subject_id', c,'merchant_subject_id', c,
        'expense_total', 7,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',7,'line_total',7,'category','food'))));
  -- an Expense that one path reaches
  ex3 := lifeos.expense_create(jsonb_build_object('transaction_date','2032-06-03','payment_method_subject_id', c,
        'expense_total', 3,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',3,'line_total',3,'category','food'))));
  -- an Observation of the Subject that is also linked by a Record link
  ob := lifeos.observation_create(jsonb_build_object('subject_id', c,'observation_name','d4 weight','value_numeric',70,'observed_date','2032-06-01'));
  perform lifeos.record_link_create(jsonb_build_object('from_type','observation','from_id', ob->>'id','to_type','subject','to_id', c));
  -- a Note, a Story Person and a Person Profile that one path each reaches
  n := lifeos.note_create('{"note_type":"General","content":"D4 note"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','note','from_id', n->>'id','to_type','subject','to_id', c));
  sp := lifeos.story_person_create(jsonb_build_object('name','D4 story person','subject_id', c));
  pr := lifeos.communication_profile_create(jsonb_build_object('profile_key','m0022-d4-person','profile_type','person','name','D4 person','person_subject_id', c));

  rl := lifeos.record_links_read('subject', c);
  perform pg_temp.chk(rl->>'record_type' = 'subject' and rl->>'id' = c::text, 'the return names the Subject');
  perform pg_temp.chk(jsonb_array_length(rl->'links') = 7, 'seven connected Records, got ' || jsonb_array_length(rl->'links'));
  perform pg_temp.chk((select count(*) = count(distinct (x->>'record_type') || '/' || (x->>'id')) from jsonb_array_elements(rl->'links') x), 'each connected Record appears once');
  perform pg_temp.chk((select bool_and(x->>'via' = x->'via_list'->>0) from jsonb_array_elements(rl->'links') x), 'via is the first path of via_list');

  -- several paths: every path in the fixed order
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = ex->>'id';
  perform pg_temp.chk(l->'via_list' = '["record_link","payment_method","merchant","line_item"]'::jsonb, 'the linked Expense keeps every path in order, got ' || coalesce((l->'via_list')::text, 'null'));
  perform pg_temp.chk(l->>'via' = 'record_link' and l->>'record_type' = 'expense' and l->>'summary' = 'Expense MYR 15' and l->>'occurrence_date' = '2032-06-01', 'the other fields stay as before');
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = ex2->>'id';
  perform pg_temp.chk(l->'via_list' = '["payment_method","merchant"]'::jsonb and l->>'via' = 'payment_method', 'Payment Method comes before Merchant');
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = ob->>'id';
  perform pg_temp.chk(l->'via_list' = '["record_link","observation_subject"]'::jsonb and l->>'record_type' = 'observation', 'the linked Observation keeps both paths');
  -- one path: via_list holds that path
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = ex3->>'id';
  perform pg_temp.chk(l->'via_list' = '["payment_method"]'::jsonb, 'one path gives a via_list of one');
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = n->>'id';
  perform pg_temp.chk(l->'via_list' = '["record_link"]'::jsonb and l->>'record_type' = 'note', 'a Record link alone');
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = sp->>'id';
  perform pg_temp.chk(l->'via_list' = '["story_person_subject"]'::jsonb and l->>'record_type' = 'story_person', 'the Story Person');
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = pr->>'id';
  perform pg_temp.chk(l->'via_list' = '["person_profile_subject"]'::jsonb and l->>'record_type' = 'communication_profile', 'the Person Profile');

  -- order: via, then record_type, as before
  select array_agg(x->>'via' || '/' || (x->>'record_type') order by o) into vias from jsonb_array_elements(rl->'links') with ordinality e(x, o);
  perform pg_temp.chk(vias = (select array_agg(v order by v) from unnest(vias) v), 'links ordered by via and record_type, got ' || array_to_string(vias, ', '));

  -- a deleted Record is omitted; a removed Record link leaves the other paths
  perform lifeos.expense_delete((ex3->>'id')::uuid, 'D4 test');
  perform lifeos.record_link_delete(jsonb_build_object('from_type','expense','from_id', ex->>'id','to_type','subject','to_id', c));
  rl := lifeos.record_links_read('subject', c);
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(rl->'links') x where x->>'id' = ex3->>'id'), 'a deleted Expense is omitted');
  select x into l from jsonb_array_elements(rl->'links') x where x->>'id' = ex->>'id';
  perform pg_temp.chk(l->'via_list' = '["payment_method","merchant","line_item"]'::jsonb and l->>'via' = 'payment_method', 'without the Record link the next path leads');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 23. record_links_read on a Record is unchanged by M-0022 D4 ----------------------------------------
do $t$
declare t constant text := 'record_links_read_on_record_lists_each_subject_once_without_via_list';
  c uuid; ex jsonb; ev jsonb; rl jsonb;
begin
  c := ((lifeos.subject_create('{"name":"D4 card","subject_type":"payment method"}'))->>'id')::uuid;
  ex := lifeos.expense_create(jsonb_build_object('transaction_date','2032-06-04','payment_method_subject_id', c,'merchant_subject_id', c,
        'expense_total', 9,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',9,'line_total',9,'category','food','item_subject_id', c))));
  ev := lifeos.event_create('{"title":"D4 lunch","occurred_date":"2032-06-04"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','expense','from_id', ex->>'id','to_type','event','to_id', ev->>'id'));
  rl := lifeos.record_links_read('expense', (ex->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rl->'links') = 2, 'the Expense lists its Subject once and its Event, got ' || jsonb_array_length(rl->'links'));
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(rl->'links') x where x->>'id' = c::text and x->>'via' = 'payment_method'), 'the Subject carries the first path');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(rl->'links') x where x->>'id' = ev->>'id' and x->>'via' = 'record_link'), 'the Event is a Record link');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(rl->'links') x where x ? 'via_list'), 'a Record return has no via_list');
  perform pg_temp.chk((select bool_and((select array_agg(k order by k) from jsonb_object_keys(x) k) = array['id','occurrence_date','record_type','summary','via'])
                       from jsonb_array_elements(rl->'links') x), 'each entry keeps the 4.5.3 fields');
  -- the other Record side, an unknown Record Type and an unknown Subject
  perform pg_temp.chk(jsonb_array_length(lifeos.record_links_read('event', (ev->>'id')::uuid)->'links') = 1, 'the Event lists the Expense');
  perform pg_temp.expect_err(format($$select lifeos.record_links_read('story_person', %L::uuid)$$, c), 'invalid input');
  perform pg_temp.expect_err($$select lifeos.record_links_read('subject', gen_random_uuid())$$, 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
