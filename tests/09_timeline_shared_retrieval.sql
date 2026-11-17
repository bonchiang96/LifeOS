-- =============================================================================
-- tests/09_timeline_shared_retrieval.sql -- Module: Timeline and Shared Retrieval (Contract Chapter 9)
-- timeline and subject_records.
--
-- Tests in this file:
--   1. timeline_includes_every_record_type_with_module
--   2. timeline_items_carry_connected_subjects
--   3. timeline_excludes_storylines_deleted_and_reference_data
--   4. timeline_order_date_basis_and_recorded_earlier
--   5. timeline_item_contents_schedule_status_event_observations_expense_reading
--   6. timeline_requires_a_period
--   7. subject_records_cross_module_retrieval
--   8. subject_records_filters_order_paging_and_deleted
--
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

-- Today in Asia/Kuala_Lumpur (Contract 1.7 item 4).
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

create function pg_temp.mk_subject(p_name text, p_type text default null) returns uuid language sql as
$f$ select ((lifeos.subject_create(jsonb_build_object('name', p_name, 'subject_type', p_type)))->>'id')::uuid $f$;
-- The Timeline item of one Record id, or null.
create function pg_temp.item(p_tl jsonb, p_id text) returns jsonb language sql as
$f$ select i from jsonb_array_elements(p_tl->'items') i where i->>'id' = p_id $f$;
create function pg_temp.pm(p_name text) returns uuid language sql as
$f$ select pg_temp.mk_subject(p_name, 'payment method') $f$;
create function pg_temp.expense(p_date date, p_pm uuid, p_total numeric, p_extra jsonb default '{}') returns jsonb language sql as
$f$ select lifeos.expense_create(jsonb_build_object('transaction_date', p_date, 'payment_method_subject_id', p_pm, 'expense_total', p_total, 'currency', 'MYR',
      'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','thing','unit_price', p_total,'line_total', p_total,'category','other'))) || p_extra) $f$;

-- 1. Every included Record Type appears, with its module --------------------------------------
do $t$
declare t constant text := 'timeline_includes_every_record_type_with_module';
  td date := pg_temp.today(); pm uuid := pg_temp.pm('Tl1 Card'); sc jsonb; ev jsonb; ob jsonb; nt jsonb; ex jsonb; rd jsonb; msg jsonb; subj uuid := pg_temp.mk_subject('Tl1 subject');
  tl jsonb; rec jsonb; i jsonb;
begin
  sc := lifeos.schedule_create(jsonb_build_object('title','Tl1 schedule','planned_date', td,'planned_time','10:00'));
  ev := lifeos.event_create(jsonb_build_object('title','Tl1 event','occurred_date', td,'occurred_time','11:00'));
  ob := lifeos.observation_create(jsonb_build_object('subject_id', subj,'observation_name','mood','value_text','ok','observed_date', td));
  nt := lifeos.note_create('{"note_type":"Idea","content":"Tl1 note"}');
  ex := pg_temp.expense(td, pm, 9);
  rd := lifeos.divination_record_save(jsonb_build_object('readings', jsonb_build_array(jsonb_build_object('question','Tl1 Q','method','tarot','result_text','R'))));
  msg := lifeos.communication_message_finalize('{"message_text":"Tl1 message"}')->'message';

  tl := lifeos.timeline(jsonb_build_object('from_date', td, 'to_date', td));
  perform pg_temp.chk(tl->>'from_date' = td::text and tl->>'to_date' = td::text and tl->>'date_basis' = 'occurrence', 'period and default date_basis occurrence returned');
  perform pg_temp.chk(pg_temp.item(tl, sc->>'id')->>'record_type' = 'schedule' and pg_temp.item(tl, sc->>'id')->>'module' = 'personal_records', 'Schedule item, module personal_records');
  perform pg_temp.chk(pg_temp.item(tl, ev->>'id')->>'record_type' = 'event' and pg_temp.item(tl, ev->>'id')->>'module' = 'personal_records', 'Event item');
  perform pg_temp.chk(pg_temp.item(tl, ob->>'id')->>'record_type' = 'observation' and pg_temp.item(tl, ob->>'id')->>'module' = 'personal_records', 'Observation item');
  perform pg_temp.chk(pg_temp.item(tl, nt->>'id')->>'record_type' = 'note' and pg_temp.item(tl, nt->>'id')->>'module' = 'personal_records', 'Note item dated on its record date');
  perform pg_temp.chk(pg_temp.item(tl, ex->>'id')->>'record_type' = 'expense' and pg_temp.item(tl, ex->>'id')->>'module' = 'financial_records', 'Expense item, module financial_records');
  perform pg_temp.chk(pg_temp.item(tl, rd->'readings'->0->>'id')->>'record_type' = 'reading' and pg_temp.item(tl, rd->'readings'->0->>'id')->>'module' = 'divination_reflection', 'Reading item, module divination_reflection');
  perform pg_temp.chk(pg_temp.item(tl, msg->>'id')->>'record_type' = 'communication_message' and pg_temp.item(tl, msg->>'id')->>'module' = 'communication_assistant', 'Communication Message item, module communication_assistant');
  i := pg_temp.item(tl, ev->>'id');
  perform pg_temp.chk(i->>'occurrence_date' = td::text and i->>'occurrence_time' = '11:00:00' and i->>'record_date' = td::text, 'item carries occurrence_date, occurrence_time and record_date');
  perform pg_temp.chk(i->'record'->>'title' = 'Tl1 event' and jsonb_typeof(i->'links') = 'array' and jsonb_typeof(i->'subjects') = 'array', 'item carries the complete record, links and subjects');
  perform pg_temp.chk(pg_temp.item(tl, nt->>'id')->>'occurrence_time' is null, 'a Note has no occurrence time');
  perform pg_temp.chk((tl->>'returned_count')::int = jsonb_array_length(tl->'items'), 'returned_count equals the number of items');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Every item carries its connected Subjects ------------------------------------------------------
do $t$
declare t constant text := 'timeline_items_carry_connected_subjects';
  s1 uuid := pg_temp.mk_subject('Tl2 Alice','person'); s2 uuid := pg_temp.pm('Tl2 Card'); s3 uuid := pg_temp.mk_subject('Tl2 Vitamin','product'); s4 uuid := pg_temp.mk_subject('Tl2 Story Subject','person');
  s5 uuid := pg_temp.mk_subject('Tl2 Merchant','brand');
  sc jsonb; ev jsonb; ob jsonb; ex jsonb; sp uuid; rd jsonb; pf uuid; msg jsonb; tl jsonb; tl2 jsonb; i jsonb;
begin
  sc := lifeos.schedule_create('{"title":"Tl2 schedule","planned_date":"2035-06-10"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','schedule','from_id', sc->>'id','to_type','subject','to_id', s1));
  ev := lifeos.event_create('{"title":"Tl2 event","occurred_date":"2035-06-10","occurred_time":"09:00"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', ev->>'id','to_type','subject','to_id', s1));
  ob := lifeos.observation_create(jsonb_build_object('subject_id', s1,'observation_name','weight','value_numeric',70,'observed_date','2035-06-10','event_id', ev->>'id'));
  ex := pg_temp.expense('2035-06-10', s2, 15, jsonb_build_object('merchant_subject_id', s5,
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','vit','unit_price',15,'line_total',15,'category','medical','item_subject_id', s3))));
  sp := ((lifeos.story_person_create(jsonb_build_object('name','Tl2 story person','subject_id', s4)))->>'id')::uuid;
  rd := lifeos.divination_record_save(jsonb_build_object('session_date','2035-06-10','readings', jsonb_build_array(jsonb_build_object('question','Tl2 Q','method','tarot','result_text','R','story_person_ids', jsonb_build_array(sp)))));
  pf := ((lifeos.communication_profile_create(jsonb_build_object('profile_key','tl2-alice','profile_type','person','name','Alice','person_subject_id', s1)))->>'id')::uuid;
  msg := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','Tl2 hello'))->'message';

  tl := lifeos.timeline('{"from_date":"2035-06-10","to_date":"2035-06-10"}');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(pg_temp.item(tl, sc->>'id')->'subjects') s where s->>'id' = s1::text and s->>'via' = 'record_link' and s->>'name' = 'Tl2 Alice' and s->>'subject_type' = 'person'),
    'Schedule carries the Subject linked by a Record link (id, name, subject_type, via)');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(pg_temp.item(tl, ev->>'id')->'subjects') s where s->>'id' = s1::text), 'Event carries its linked Subject');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(pg_temp.item(tl, ob->>'id')->'subjects') s where s->>'id' = s1::text and s->>'via' = 'observation_subject'), 'Observation carries its Subject (typed reference)');
  i := pg_temp.item(tl, ex->>'id');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(i->'subjects') s where s->>'id' = s2::text and s->>'via' = 'payment_method'), 'Expense carries its Payment Method Subject');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(i->'subjects') s where s->>'id' = s5::text and s->>'via' = 'merchant'), 'Expense carries its Merchant Subject');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(i->'subjects') s where s->>'id' = s3::text and s->>'via' = 'line_item'), 'Expense carries its Line Item Subject');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(pg_temp.item(tl, rd->'readings'->0->>'id')->'subjects') s where s->>'id' = s4::text and s->>'via' = 'story_person_subject'), 'Reading carries the Subject of its Story Person');
  tl2 := lifeos.timeline(jsonb_build_object('from_date', pg_temp.today(), 'to_date', pg_temp.today()));
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(pg_temp.item(tl2, msg->>'id')->'subjects') s where s->>'id' = s1::text and s->>'via' = 'person_profile_subject'), 'Communication Message carries its Person Profile Subject');
  -- a deleted Subject is no longer listed
  perform lifeos.subject_delete(s3);
  tl := lifeos.timeline('{"from_date":"2035-06-10","to_date":"2035-06-10"}');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(pg_temp.item(tl, ex->>'id')->'subjects') s where s->>'id' = s3::text), 'a deleted Subject is omitted from item subjects');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(tl->'items') x where x->>'record_type' = 'subject'), 'Subjects are never items');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. No Storylines, no deleted Records, no reference data ------------------------------------------------
do $t$
declare t constant text := 'timeline_excludes_storylines_deleted_and_reference_data';
  sp uuid := ((lifeos.story_person_create('{"name":"Tl3 story person"}'))->>'id')::uuid; sl jsonb; ev jsonb; ev2 jsonb; sc jsonb; tl jsonb; mem jsonb; nb jsonb;
begin
  sl := lifeos.storyline_create(jsonb_build_object('content','Tl3 storyline','occurrence_date','2035-07-04','story_person_ids', jsonb_build_array(sp)));
  ev := lifeos.event_create('{"title":"Tl3 kept event","occurred_date":"2035-07-04"}');
  ev2 := lifeos.event_create('{"title":"Tl3 deleted event","occurred_date":"2035-07-04"}');
  sc := lifeos.schedule_create('{"title":"Tl3 deleted schedule","planned_date":"2035-07-04"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','storyline','from_id', sl->>'id','to_type','event','to_id', ev->>'id'));
  perform lifeos.event_delete((ev2->>'id')::uuid);
  perform lifeos.schedule_delete((sc->>'id')::uuid);
  mem := lifeos.memory_create('{"content":"Tl3 memory"}');
  tl := lifeos.timeline('{"from_date":"2035-07-04","to_date":"2035-07-04"}');
  perform pg_temp.chk(pg_temp.item(tl, ev->>'id') is not null, 'the active Event is an item');
  perform pg_temp.chk(pg_temp.item(tl, sl->>'id') is null and not exists (select 1 from jsonb_array_elements(tl->'items') i where i->>'record_type' = 'storyline'), 'Storylines are not items');
  perform pg_temp.chk(pg_temp.item(tl, ev2->>'id') is null, 'a deleted Event is not an item');
  perform pg_temp.chk(pg_temp.item(tl, sc->>'id') is null, 'a deleted Schedule is not an item');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(tl->'items') i where i->>'record_type' in ('memory','notebook','subject','story_person','profile','rule','communication_profile','communication_rule')), 'reference data is not an item');
  perform pg_temp.chk(jsonb_array_length(tl->'items') = 1, 'only the active Event remains in the period, got ' || jsonb_array_length(tl->'items'));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Order, date_basis and recorded_earlier ------------------------------------------------------------------
do $t$
declare t constant text := 'timeline_order_date_basis_and_recorded_earlier';
  td date := pg_temp.today(); a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; tl jsonb; ids text[]; old_ev jsonb;
begin
  a := lifeos.event_create('{"title":"Tl4 ten","occurred_date":"2035-08-02","occurred_time":"10:00"}');
  b := lifeos.event_create('{"title":"Tl4 eight","occurred_date":"2035-08-02","occurred_time":"08:00"}');
  c := lifeos.event_create('{"title":"Tl4 untimed","occurred_date":"2035-08-02"}');
  d := lifeos.event_create('{"title":"Tl4 next day","occurred_date":"2035-08-03","occurred_time":"07:00"}');
  e := lifeos.event_create('{"title":"Tl4 day before","occurred_date":"2035-08-01","occurred_time":"23:00"}');
  tl := lifeos.timeline('{"from_date":"2035-08-01","to_date":"2035-08-03"}');
  select array_agg(i->>'id' order by ord) into ids from jsonb_array_elements(tl->'items') with ordinality q(i, ord);
  perform pg_temp.chk(ids = array[e->>'id', b->>'id', a->>'id', c->>'id', d->>'id'], 'ordered by date, then time, unknown time last within a date');

  -- occurrence basis: an Event recorded today for an earlier day is in recorded_earlier
  old_ev := lifeos.event_create(jsonb_build_object('title','Tl4 recorded late','occurred_date', td - 3));
  tl := lifeos.timeline(jsonb_build_object('from_date', td, 'to_date', td));
  perform pg_temp.chk(pg_temp.item(tl, old_ev->>'id') is null, 'occurrence basis: the earlier-day Event is not an item');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(tl->'recorded_earlier') i where i->>'id' = old_ev->>'id' and i->>'occurrence_date' = (td - 3)::text and i->>'record_date' = td::text),
    'recorded_earlier lists items recorded in the period with an earlier occurrence date');
  -- record basis: by record date
  tl := lifeos.timeline(jsonb_build_object('from_date', td, 'to_date', td, 'date_basis', 'record'));
  perform pg_temp.chk(tl->>'date_basis' = 'record', 'date_basis record echoed');
  perform pg_temp.chk(pg_temp.item(tl, old_ev->>'id') is not null, 'record basis: the Event is included by its record date');
  perform pg_temp.chk(pg_temp.item(tl, a->>'id') is not null, 'record basis: an Event recorded today for 2035 is included');
  tl := lifeos.timeline('{"from_date":"2035-08-01","to_date":"2035-08-03","date_basis":"record"}');
  perform pg_temp.chk(jsonb_array_length(tl->'items') = 0, 'record basis: nothing has a record date in 2035');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Item contents: Schedule status, Event observations, Expense lines, Refund, Reading analyses ---------------
do $t$
declare t constant text := 'timeline_item_contents_schedule_status_event_observations_expense_reading';
  subj uuid := pg_temp.mk_subject('Tl5 subject'); pm uuid := pg_temp.pm('Tl5 Card');
  s_planned jsonb; s_occ jsonb; s_missed jsonb; s_canc jsonb; ev jsonb; ob jsonb; ex jsonb; rf jsonb; rd jsonb; tl jsonb; i jsonb;
begin
  s_planned := lifeos.schedule_create('{"title":"Tl5 planned","planned_date":"2035-09-05"}');
  s_occ := lifeos.schedule_create('{"title":"Tl5 occurred","planned_date":"2035-09-05"}');
  s_missed := lifeos.schedule_create('{"title":"Tl5 missed","planned_date":"2035-09-05"}');
  s_canc := lifeos.schedule_create('{"title":"Tl5 cancelled","planned_date":"2035-09-05"}');
  ev := lifeos.event_create(jsonb_build_object('schedule_id', s_occ->>'id','occurred_date','2035-09-05'));
  perform lifeos.schedule_update((s_missed->>'id')::uuid, '{"status":"missed"}');
  perform lifeos.schedule_update((s_canc->>'id')::uuid, '{"status":"cancelled"}');
  ob := lifeos.observation_create(jsonb_build_object('subject_id', subj,'observation_name','bp','value_text','120/80','observed_date','2035-09-05','event_id', ev->>'id'));
  ex := pg_temp.expense('2035-09-05', pm, 50);
  rf := lifeos.expense_refund_create(jsonb_build_object('refund_of', ex->>'id','refund_amount',20,'transaction_date','2035-09-08','line_type','item'));
  rd := lifeos.divination_record_save('{"session_date":"2035-09-05","readings":[{"question":"Tl5 Q","method":"tarot","result_text":"R","analyses":[{"source":"S","overall_outcome":"reading outcome","key_reasoning":"K"}]}],
        "record_analyses":[{"source":"S","overall_outcome":"combined outcome","key_reasoning":"CK"}]}');

  tl := lifeos.timeline('{"from_date":"2035-09-05","to_date":"2035-09-05"}');
  perform pg_temp.chk(pg_temp.item(tl, s_planned->>'id')->'record'->>'status' = 'planned' and pg_temp.item(tl, s_occ->>'id')->'record'->>'status' = 'occurred'
                      and pg_temp.item(tl, s_missed->>'id')->'record'->>'status' = 'missed' and pg_temp.item(tl, s_canc->>'id')->'record'->>'status' = 'cancelled', 'Schedules of every Status are included');
  perform pg_temp.chk(pg_temp.item(tl, s_occ->>'id')->'record'->>'linked_event_id' = ev->>'id', 'an Occurred Schedule carries linked_event_id');
  i := pg_temp.item(tl, ev->>'id');
  perform pg_temp.chk(jsonb_array_length(i->'record'->'observations') = 1 and i->'record'->'observations'->0->>'id' = ob->>'id', 'an Event carries its observations');
  perform pg_temp.chk(pg_temp.item(tl, ob->>'id')->>'record_type' = 'observation' and pg_temp.item(tl, ob->>'id')->'record'->>'event_id' = ev->>'id', 'the Observation is also its own item with event_id');
  perform pg_temp.chk(jsonb_array_length(pg_temp.item(tl, ex->>'id')->'record'->'lines') = 1, 'an Expense item carries its lines');
  perform pg_temp.chk(pg_temp.item(tl, rf->>'id') is null, 'the Refund is not on the purchase date');
  tl := lifeos.timeline('{"from_date":"2035-09-08","to_date":"2035-09-08"}');
  i := pg_temp.item(tl, rf->>'id');
  perform pg_temp.chk(i is not null and i->>'record_type' = 'expense' and i->>'occurrence_date' = '2035-09-08' and i->'record'->>'expense_type' = 'refund', 'a Refund is an item on its own transaction date');
  tl := lifeos.timeline('{"from_date":"2035-09-05","to_date":"2035-09-05"}');
  i := pg_temp.item(tl, rd->'readings'->0->>'id');
  perform pg_temp.chk(i->'record'->'analyses'->0->>'overall_outcome' = 'reading outcome', 'a Reading item carries its own Analyses');
  perform pg_temp.chk(i->'record'->'record_analyses'->0->>'overall_outcome' = 'combined outcome', 'a Reading item carries the combined Analyses of its Divination Record');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(tl->'items') x where x->>'record_type' = 'analysis'), 'Analyses are not separate items');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Period required ------------------------------------------------------------------------------------------
do $t$
declare t constant text := 'timeline_requires_a_period';
begin
  perform pg_temp.expect_err($$select lifeos.timeline('{"from_date":"2035-01-01"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.timeline('{"to_date":"2035-01-01"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.timeline('{"from_date":"2035-02-01","to_date":"2035-01-01"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.timeline('{"from_date":"2035-01-01","to_date":"2035-01-02","date_basis":"created"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.timeline('{"from_date":"nonsense","to_date":"2035-01-02"}')$$, 'invalid date');
  perform pg_temp.chk((lifeos.timeline('{"from_date":"2036-01-01","to_date":"2036-01-02"}')->>'returned_count')::int = 0, 'an empty period returns no items');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. subject_records: Records connected to one Subject across Modules ---------------------------------------------
do $t$
declare t constant text := 'subject_records_cross_module_retrieval';
  s uuid := pg_temp.mk_subject('Sr Nicholas','person'); other uuid := pg_temp.mk_subject('Sr Other','person'); pm uuid := pg_temp.pm('Sr Card');
  ev jsonb; sc jsonb; nt jsonb; ob jsonb; ex_pm jsonb; ex_mer jsonb; ex_item jsonb; sp uuid; rd jsonb; sl jsonb; pf uuid; msg jsonb; unrelated jsonb; r jsonb; v jsonb;
begin
  ev := lifeos.event_create('{"title":"Sr dinner","occurred_date":"2036-03-10"}');
  sc := lifeos.schedule_create('{"title":"Sr plan","planned_date":"2036-03-11"}');
  nt := lifeos.note_create('{"note_type":"Feeling","content":"Sr note"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', ev->>'id','to_type','subject','to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type','schedule','from_id', sc->>'id','to_type','subject','to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type','note','from_id', nt->>'id','to_type','subject','to_id', s));
  ob := lifeos.observation_create(jsonb_build_object('subject_id', s,'observation_name','mood','value_text','good','observed_date','2036-03-12'));
  ex_pm := pg_temp.expense('2036-03-13', s, 10);
  ex_mer := pg_temp.expense('2036-03-14', pm, 11, jsonb_build_object('merchant_subject_id', s));
  ex_item := pg_temp.expense('2036-03-15', pm, 12, jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','gift','unit_price',12,'line_total',12,'category','gift','item_subject_id', s))));
  sp := ((lifeos.story_person_create(jsonb_build_object('name','Sr story Nick','subject_id', s)))->>'id')::uuid;
  rd := lifeos.divination_record_save(jsonb_build_object('session_date','2036-03-16','readings', jsonb_build_array(jsonb_build_object('question','Sr Q','method','tarot','result_text','R','story_person_ids', jsonb_build_array(sp)))));
  sl := lifeos.storyline_create(jsonb_build_object('content','Sr storyline','occurrence_date','2036-03-17','story_person_ids', jsonb_build_array(sp)));
  pf := ((lifeos.communication_profile_create(jsonb_build_object('profile_key','sr-nick','profile_type','person','name','Nick','person_subject_id', s)))->>'id')::uuid;
  msg := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','Sr hi'))->'message';
  unrelated := lifeos.event_create('{"title":"Sr unrelated","occurred_date":"2036-03-10"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', unrelated->>'id','to_type','subject','to_id', other));

  r := lifeos.subject_records(s, '{"limit":50}');
  perform pg_temp.chk((r->>'returned_count')::int = 10, 'ten connected Records, got ' || (r->>'returned_count'));
  perform pg_temp.chk(r->'results'->0 ?& array['record_type','id','via','occurrence_date','record'], 'each result holds record_type, id, via, occurrence_date and record');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(r->'results') x where x->>'id' = unrelated->>'id'), 'a Record of another Subject is not returned');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = ev->>'id') = 'record_link', 'Event via record_link');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = sc->>'id') = 'record_link' and (select x->>'record_type' from jsonb_array_elements(r->'results') x where x->>'id' = sc->>'id') = 'schedule', 'Schedule via record_link');
  perform pg_temp.chk((select x->>'record_type' from jsonb_array_elements(r->'results') x where x->>'id' = nt->>'id') = 'note', 'Note via record_link');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = ob->>'id') = 'observation_subject', 'Observation via observation_subject');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = ex_pm->>'id') = 'payment_method', 'Expense via payment_method');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = ex_mer->>'id') = 'merchant', 'Expense via merchant');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = ex_item->>'id') = 'line_item', 'Expense via line_item');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = rd->'readings'->0->>'id') = 'story_person_subject' and
                      (select x->>'record_type' from jsonb_array_elements(r->'results') x where x->>'id' = rd->'readings'->0->>'id') = 'reading', 'Reading via story_person_subject');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = sl->>'id') = 'story_person_subject' and
                      (select x->>'occurrence_date' from jsonb_array_elements(r->'results') x where x->>'id' = sl->>'id') = '2036-03-17', 'Storyline via story_person_subject with its occurrence_date');
  perform pg_temp.chk((select x->>'via' from jsonb_array_elements(r->'results') x where x->>'id' = msg->>'id') = 'person_profile_subject' and
                      (select x->>'record_type' from jsonb_array_elements(r->'results') x where x->>'id' = msg->>'id') = 'communication_message', 'Message via person_profile_subject');
  perform pg_temp.chk((select x->'record'->>'title' from jsonb_array_elements(r->'results') x where x->>'id' = ev->>'id') = 'Sr dinner', 'each result carries its stored Record');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. subject_records: filters, order, paging, deleted Records ---------------------------------------------------------
do $t$
declare t constant text := 'subject_records_filters_order_paging_and_deleted';
  s uuid := pg_temp.mk_subject('Sr2 Subject','person'); e1 jsonb; e2 jsonb; e3 jsonb; o1 jsonb; r jsonb; ids text[]; nt jsonb;
begin
  e1 := lifeos.event_create('{"title":"Sr2 early","occurred_date":"2036-05-01"}');
  e2 := lifeos.event_create('{"title":"Sr2 middle","occurred_date":"2036-05-10"}');
  e3 := lifeos.event_create('{"title":"Sr2 late","occurred_date":"2036-05-20"}');
  o1 := lifeos.observation_create(jsonb_build_object('subject_id', s,'observation_name','x','value_text','y','observed_date','2036-05-15'));
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', e1->>'id','to_type','subject','to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', e2->>'id','to_type','subject','to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', e3->>'id','to_type','subject','to_id', s));
  r := lifeos.subject_records(s, '{}');
  select array_agg(x->>'id' order by ord) into ids from jsonb_array_elements(r->'results') with ordinality q(x, ord);
  perform pg_temp.chk(ids = array[e3->>'id', o1->>'id', e2->>'id', e1->>'id'], 'results ordered by occurrence date descending');
  perform pg_temp.chk(r->>'limit' = '20' and r->>'offset' = '0', 'default limit 20 and offset 0');
  r := lifeos.subject_records(s, '{"limit":2,"offset":1}');
  perform pg_temp.chk((r->>'returned_count')::int = 2 and r->'results'->0->>'id' = o1->>'id' and r->>'limit' = '2' and r->>'offset' = '1', 'limit and offset page the results');
  r := lifeos.subject_records(s, '{"record_types":["observation"]}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = o1->>'id', 'record_types filter');
  r := lifeos.subject_records(s, '{"from_date":"2036-05-10","to_date":"2036-05-15"}');
  perform pg_temp.chk((r->>'returned_count')::int = 2, 'from_date and to_date filter the occurrence date inclusively, got ' || (r->>'returned_count'));
  -- deleted Records are omitted
  perform lifeos.event_delete((e2->>'id')::uuid);
  perform lifeos.observation_delete((o1->>'id')::uuid);
  r := lifeos.subject_records(s, '{}');
  perform pg_temp.chk((r->>'returned_count')::int = 2 and not exists (select 1 from jsonb_array_elements(r->'results') x where x->>'id' in (e2->>'id', o1->>'id')), 'deleted Records are omitted');
  -- a Note's occurrence date is its note_date
  nt := lifeos.note_create('{"note_type":"Idea","content":"Sr2 note"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','note','from_id', nt->>'id','to_type','subject','to_id', s));
  r := lifeos.subject_records(s, jsonb_build_object('from_date', pg_temp.today(), 'to_date', pg_temp.today()));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = nt->>'id' and r->'results'->0->>'occurrence_date' = pg_temp.today()::text, 'a Note is dated by its note_date');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
