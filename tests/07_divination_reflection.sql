-- =============================================================================
-- tests/07_divination_reflection.sql -- Module: Divination & Reflection (Contract Chapter 7)
-- Divination Record, Reading, Analysis, Reading Remark, Story Person, Storyline.
--
-- Tests in this file:
--   1.  divination_save_readings_and_analyses
--   2.  divination_save_rejects_invalid_input
--   3.  divination_search_short_view
--   4.  divination_search_by_subject_and_story_person
--   5.  divination_record_read_full_view
--   6.  reading_remark_add_and_update
--   7.  reading_create_analysis_add_and_story_persons_set
--   8.  divination_delete_cascades_reading_delete_keeps_combined
--   9.  story_person_create_search_read_delete
--   10. storyline_search_by_story_persons
--   11. storyline_update_delete_and_links
--   12. reading_remark_add_and_update_leave_reading_updated_at_unchanged
--
-- Test setup that the Contract has no function for: test 12 moves updated_at of one Reading
-- 5 days back, so a change of updated_at shows inside one transaction.
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

create function pg_temp.mk_sp(p_name text, p_subject uuid default null) returns uuid language sql as
$f$ select ((lifeos.story_person_create(jsonb_build_object('name', p_name, 'subject_id', p_subject)))->>'id')::uuid $f$;

-- 1. Save a session with Readings, Reading Analyses and a combined Analysis -------------
do $t$
declare t constant text := 'divination_save_readings_and_analyses';
  sp uuid := pg_temp.mk_sp('Mei (save test)'); d jsonb; r1 jsonb; r2 jsonb; txt text := E'Hexagram 11\n  Peace   (泰)\nChanging line 3';
begin
  d := lifeos.divination_record_save(jsonb_build_object('session_date','2032-10-01','title','Career question','topic','work',
        'readings', jsonb_build_array(
          jsonb_build_object('question','Should I take the new job?','method','i_ching','result_text', txt,'story_person_ids', jsonb_build_array(sp),
             'analyses', jsonb_build_array(jsonb_build_object('source','Claude','overall_outcome','Favourable','key_reasoning','Peace hexagram, line 3 warns of change','story_context','Mei is considering a move'))),
          jsonb_build_object('question','And the timing?','method','tarot','spread_name','Three cards','result_text','Sun, Moon, Star','reading_date','2032-10-02','reading_time','21:00',
             'analyses', jsonb_build_array(jsonb_build_object('source','Friend','overall_outcome','Wait a month','key_reasoning','Moon asks for patience')))),
        'record_analyses', jsonb_build_array(jsonb_build_object('source','Claude','overall_outcome','Move later in the year','key_reasoning','Both Readings point to patience'))));
  perform pg_temp.chk(d->>'session_date' = '2032-10-01' and d->>'title' = 'Career question' and d->>'topic' = 'work', 'record fields stored');
  perform pg_temp.chk(jsonb_array_length(d->'readings') = 2, 'two Readings');
  r1 := d->'readings'->0; r2 := d->'readings'->1;
  perform pg_temp.chk(r1->>'result_text' = txt, 'result_text is stored exactly as supplied');
  perform pg_temp.chk(r1->>'reading_date' = '2032-10-01', 'reading_date defaults to session_date');
  perform pg_temp.chk(r2->>'reading_date' = '2032-10-02' and r2->>'reading_time' = '21:00:00' and r2->>'spread_name' = 'Three cards', 'a supplied reading_date, time and spread_name are kept');
  perform pg_temp.chk(r1->'story_person_ids' = jsonb_build_array(sp), 'story_person_ids stored');
  perform pg_temp.chk(jsonb_array_length(r1->'analyses') = 1 and r1->'analyses'->0->>'source' = 'Claude' and r1->'analyses'->0->>'story_context' = 'Mei is considering a move', 'Reading Analysis stored with its story_context');
  perform pg_temp.chk(r1->'analyses'->0->>'analysis_date' = '2032-10-01', 'analysis_date defaults to session_date');
  perform pg_temp.chk(jsonb_array_length(d->'record_analyses') = 1 and d->'record_analyses'->0->>'reading_id' is null, 'the combined Analysis has reading_id null');
  perform pg_temp.chk(d->'record_analyses'->0->>'divination_record_id' = d->>'id', 'the combined Analysis belongs to the Divination Record');

  -- session_date defaults to today
  d := lifeos.divination_record_save('{"readings":[{"question":"Q","method":"tarot","result_text":"The Fool"}]}');
  perform pg_temp.chk(d->>'session_date' = pg_temp.today()::text and d->'readings'->0->>'reading_date' = pg_temp.today()::text, 'session_date and reading_date default to today');
  perform pg_temp.chk(d->'readings'->0->'story_person_ids' = '[]'::jsonb and d->'record_analyses' = '[]'::jsonb, 'arrays default to []');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Save validation ------------------------------------------------------------------
do $t$
declare t constant text := 'divination_save_rejects_invalid_input';
  rd jsonb := '{"question":"Q","method":"tarot","result_text":"R"}'; sp uuid := pg_temp.mk_sp('Deleted person'); n int;
begin
  perform pg_temp.expect_err($$select lifeos.divination_record_save('{"title":"no readings"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.divination_record_save('{"readings":[]}')$$, 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd || '{"method":"runes"}'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd - 'question'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd - 'result_text'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd - 'method'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd || '{"analyses":[{"overall_outcome":"x","key_reasoning":"y"}]}'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd), 'bogus', 1)), 'unsupported field');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd || jsonb_build_object('story_person_ids', jsonb_build_array(gen_random_uuid()))))), 'record not found');
  perform lifeos.story_person_delete(sp);
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('readings', jsonb_build_array(rd || jsonb_build_object('story_person_ids', jsonb_build_array(sp))))), 'record deleted');
  -- a failed save leaves nothing behind
  perform pg_temp.chk((lifeos.divination_search('{"keyword":"rollbackprobe"}')->>'returned_count')::int = 0, 'baseline for the all-or-nothing check');
  perform pg_temp.expect_err(format('select lifeos.divination_record_save(%L::jsonb)', jsonb_build_object('title','rollbackprobe','readings', jsonb_build_array(rd, rd - 'method'))), 'invalid input');
  perform pg_temp.chk((lifeos.divination_search('{"keyword":"rollbackprobe"}')->>'returned_count')::int = 0, 'a failed save stores nothing');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Search: the short view of matching Readings ---------------------------------------
do $t$
declare t constant text := 'divination_search_short_view';
  d1 jsonb; d2 jsonb; d3 jsonb; r jsonb; rd jsonb;
begin
  d1 := lifeos.divination_record_save('{"session_date":"2032-11-01","title":"Moving house srch","topic":"home","readings":[
        {"question":"Is the flat right srch?","method":"tarot","result_text":"Ten of Cups","reading_date":"2032-11-01",
          "analyses":[{"source":"Claude","overall_outcome":"Good fit","key_reasoning":"Cups mean harmony","story_context":"Lease ends soon"}]},
        {"question":"Another unrelated query","method":"i_ching","result_text":"Hexagram 1","reading_date":"2032-11-03"}],
        "record_analyses":[{"source":"Teacher","overall_outcome":"Overall positive","key_reasoning":"both agree"}]}');
  d2 := lifeos.divination_record_save('{"session_date":"2032-12-10","title":"Health srch","topic":"body","readings":[
        {"question":"Will I recover","method":"i_ching","result_text":"Hexagram 24 srch","reading_date":"2032-12-10"}]}');
  d3 := lifeos.divination_record_save('{"session_date":"2033-01-01","title":"Other","topic":"zzz","readings":[
        {"question":"Nothing","method":"tarot","result_text":"Death srch2","reading_date":"2033-01-01"}]}');

  r := lifeos.divination_search('{"keyword":"flat right"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = d1->>'id', 'keyword matches a Reading question');
  perform pg_temp.chk(jsonb_array_length(r->'results'->0->'readings') = 1, 'the result holds only the matching Reading');
  rd := r->'results'->0->'readings'->0;
  perform pg_temp.chk(rd ?& array['id','question','method','result_text','reading_date','analyses'], 'short view holds id, question, method, result_text, reading_date and analyses');
  perform pg_temp.chk(rd->'analyses'->0->>'overall_outcome' = 'Good fit' and rd->'analyses'->0->>'source' = 'Claude', 'each Analysis shows overall_outcome and source');
  perform pg_temp.chk(not (rd->'analyses'->0 ? 'key_reasoning') and not (rd->'analyses'->0 ? 'story_context'), 'the short view leaves out key_reasoning and story_context');
  perform pg_temp.chk(r->'results'->0->'record_analyses'->0->>'overall_outcome' = 'Overall positive' and r->'results'->0->'record_analyses'->0->>'source' = 'Teacher', 'combined Analyses appear the same way on the Divination Record');

  perform pg_temp.chk((lifeos.divination_search('{"keyword":"moving house srch"}')->'results'->0->'readings')::jsonb is not null, 'keyword matches the Divination Record title');
  perform pg_temp.chk((lifeos.divination_search('{"keyword":"body"}')->>'returned_count')::int = 1, 'keyword matches the topic');
  perform pg_temp.chk((lifeos.divination_search('{"keyword":"hexagram 24"}')->>'returned_count')::int = 1, 'keyword matches result_text');
  r := lifeos.divination_search('{"keyword":"srch"}');
  perform pg_temp.chk((r->>'returned_count')::int = 3, 'keyword "srch" finds three records (srch2 included)');
  perform pg_temp.chk(r->'results'->0->>'id' = d3->>'id' and r->'results'->1->>'id' = d2->>'id' and r->'results'->2->>'id' = d1->>'id', 'results ordered by latest reading_date descending');
  r := lifeos.divination_search('{"keyword":"hexagram 24","method":"i_ching"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = d2->>'id', 'method filter keeps a matching Reading');
  perform pg_temp.chk((lifeos.divination_search('{"keyword":"hexagram 24","method":"tarot"}')->>'returned_count')::int = 0, 'method filter drops a Reading of the other method');
  r := lifeos.divination_search('{"keyword":"srch","from_date":"2032-12-01","to_date":"2032-12-31"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = d2->>'id', 'reading_date range filter');
  r := lifeos.divination_search('{"keyword":"srch","limit":1,"offset":1}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = d2->>'id' and r->>'limit' = '1' and r->>'offset' = '1', 'limit and offset');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Search by Subject (Record link or Story Person) and by Story Person ------------------
do $t$
declare t constant text := 'divination_search_by_subject_and_story_person';
  subj uuid := (lifeos.subject_create('{"name":"Jamie (divination)","subject_type":"person"}')->>'id')::uuid;
  subj2 uuid := (lifeos.subject_create('{"name":"Other (divination)","subject_type":"person"}')->>'id')::uuid;
  sp uuid; sp2 uuid; d1 jsonb; d2 jsonb; d3 jsonb; r jsonb;
begin
  sp  := pg_temp.mk_sp('Jamie in story', subj);
  sp2 := pg_temp.mk_sp('Unrelated story person');
  d1 := lifeos.divination_record_save(jsonb_build_object('title','via story person','readings', jsonb_build_array(
          jsonb_build_object('question','Q1','method','tarot','result_text','R1','story_person_ids', jsonb_build_array(sp)))));
  d2 := lifeos.divination_record_save(jsonb_build_object('title','via record link','readings', jsonb_build_array(
          jsonb_build_object('question','Q2','method','tarot','result_text','R2'))));
  d3 := lifeos.divination_record_save(jsonb_build_object('title','neither','readings', jsonb_build_array(
          jsonb_build_object('question','Q3','method','tarot','result_text','R3','story_person_ids', jsonb_build_array(sp2)))));
  perform lifeos.record_link_create(jsonb_build_object('from_type','reading','from_id', d2->'readings'->0->>'id','to_type','subject','to_id', subj));

  r := lifeos.divination_search(jsonb_build_object('subject_id', subj));
  perform pg_temp.chk((r->>'returned_count')::int = 2, 'subject_id matches the linked Reading and the Story Person Reading, got ' || (r->>'returned_count'));
  perform pg_temp.chk((select count(*) from jsonb_array_elements(r->'results') x where x->>'id' in (d1->>'id', d2->>'id')) = 2, 'the right two Divination Records');
  perform pg_temp.chk((lifeos.divination_search(jsonb_build_object('subject_id', subj2))->>'returned_count')::int = 0, 'a Subject with no link finds nothing');
  r := lifeos.divination_search(jsonb_build_object('story_person_id', sp2));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = d3->>'id', 'story_person_id filter');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Full read: Key Reasoning, Story Context, Reading Remarks, links -------------------------
do $t$
declare t constant text := 'divination_record_read_full_view';
  subj uuid := (lifeos.subject_create('{"name":"Reader subject"}')->>'id')::uuid; d jsonb; r jsonb; rd jsonb;
begin
  d := lifeos.divination_record_save('{"session_date":"2033-02-01","title":"Full read","readings":[
        {"question":"Q","method":"tarot","result_text":"R","analyses":[{"source":"Claude","overall_outcome":"O","key_reasoning":"Because of K","story_context":"Context S"}]}],
        "record_analyses":[{"source":"Claude","overall_outcome":"CO","key_reasoning":"Combined K"}]}');
  perform lifeos.reading_remark_add((d->'readings'->0->>'id')::uuid, '{"text":"later note"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','reading','from_id', d->'readings'->0->>'id','to_type','subject','to_id', subj));
  r := lifeos.divination_record_read((d->>'id')::uuid);
  rd := r->'readings'->0;
  perform pg_temp.chk(rd->'analyses'->0->>'key_reasoning' = 'Because of K' and rd->'analyses'->0->>'story_context' = 'Context S', 'the full read holds key_reasoning and story_context');
  perform pg_temp.chk(r->'record_analyses'->0->>'key_reasoning' = 'Combined K', 'combined Analyses carry key_reasoning');
  perform pg_temp.chk(jsonb_array_length(rd->'remark_entries') = 1 and rd->'remark_entries'->0->>'text' = 'later note', 'the Reading Remark entries are returned');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(rd->'links') l where l->>'id' = subj::text), 'each Reading carries its links');
  perform pg_temp.expect_err($$select lifeos.divination_record_read(gen_random_uuid())$$, 'record not found');
  perform pg_temp.chk(lifeos.divination_record_update((d->>'id')::uuid, '{"title":"Renamed","topic":"t2"}')->>'title' = 'Renamed', 'divination_record_update changes descriptive fields');
  perform pg_temp.chk(jsonb_array_length(lifeos.divination_record_read((d->>'id')::uuid)->'readings') = 1, 'Readings stay after a record update');
  perform pg_temp.expect_err(format($$select lifeos.divination_record_update(%L::uuid, '{"readings":[]}')$$, d->>'id'), 'unsupported field');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Reading Remark: add, then correct one entry ---------------------------------------------
do $t$
declare t constant text := 'reading_remark_add_and_update';
  d jsonb; rid uuid; sl jsonb; r jsonb; e1 jsonb; e2 jsonb; u jsonb; before_an jsonb;
begin
  d := lifeos.divination_record_save('{"readings":[{"question":"Q","method":"tarot","result_text":"R","analyses":[{"source":"Claude","overall_outcome":"O","key_reasoning":"K"}]}]}');
  rid := (d->'readings'->0->>'id')::uuid;
  sl := lifeos.storyline_create('{"content":"The move happened in spring"}');
  r := lifeos.reading_remark_add(rid, jsonb_build_object('text','It matched what happened','storyline_id', sl->>'id'));
  e1 := r->'remark_entries'->0;
  perform pg_temp.chk(jsonb_array_length(r->'remark_entries') = 1, 'one entry added');
  perform pg_temp.chk(e1->>'entry_id' is not null and e1->>'timestamp' is not null and e1->>'text' = 'It matched what happened' and e1->>'storyline_id' = sl->>'id', 'entry holds entry_id, timestamp, text and storyline_id');
  r := lifeos.reading_remark_add(rid, '{"text":"A second thought"}');
  e2 := r->'remark_entries'->1;
  perform pg_temp.chk(jsonb_array_length(r->'remark_entries') = 2 and e2->>'storyline_id' is null and e2->>'entry_id' <> e1->>'entry_id', 'a second entry, storyline_id null by default, new entry_id');
  perform pg_temp.chk(r->>'question' = 'Q' and r->>'result_text' = 'R', 'the Reading is unchanged');

  u := lifeos.reading_remark_update(rid, jsonb_build_object('entry_id', e2->>'entry_id', 'text', 'A corrected thought'));
  perform pg_temp.chk(u->'remark_entries'->1->>'text' = 'A corrected thought' and u->'remark_entries'->1->>'entry_id' = e2->>'entry_id' and u->'remark_entries'->1->>'timestamp' = e2->>'timestamp', 'the correction keeps entry_id and timestamp');
  perform pg_temp.chk(u->'remark_entries'->0->>'text' = 'It matched what happened', 'other entries stay');
  u := lifeos.reading_remark_update(rid, jsonb_build_object('entry_id', e2->>'entry_id', 'storyline_id', sl->>'id'));
  perform pg_temp.chk(u->'remark_entries'->1->>'storyline_id' = sl->>'id' and u->'remark_entries'->1->>'text' = 'A corrected thought', 'storyline_id changed alone, text kept');
  -- the Reading Analyses stay
  perform pg_temp.chk(lifeos.divination_record_read((d->>'id')::uuid)->'readings'->0->'analyses'->0->>'key_reasoning' = 'K', 'Analyses stay unchanged');
  -- storyline_id is an explanatory text reference: deleting the Storyline keeps the entry's reference
  perform lifeos.storyline_delete((sl->>'id')::uuid);
  perform pg_temp.chk(lifeos.divination_record_read((d->>'id')::uuid)->'readings'->0->'remark_entries'->0->>'storyline_id' = sl->>'id', 'a deleted Storyline stays referenced by its id');
  perform pg_temp.expect_err(format($$select lifeos.reading_remark_add(%L::uuid, '{}')$$, rid), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.reading_remark_update(%L::uuid, jsonb_build_object('entry_id', gen_random_uuid(), 'text', 'x'))$$, rid), 'record not found');
  perform pg_temp.expect_err(format($$select lifeos.reading_remark_update(%L::uuid, jsonb_build_object('entry_id', %L::uuid))$$, rid, e1->>'entry_id'), 'invalid input');
  perform pg_temp.expect_err($$select lifeos.reading_remark_add(gen_random_uuid(), '{"text":"x"}')$$, 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Add a Reading, add Analyses, set Story Persons --------------------------------------------
do $t$
declare t constant text := 'reading_create_analysis_add_and_story_persons_set';
  d jsonb; rd jsonb; an jsonb; comb jsonb; sp1 uuid := pg_temp.mk_sp('Set A'); sp2 uuid := pg_temp.mk_sp('Set B'); u jsonb; fr jsonb;
begin
  d := lifeos.divination_record_save('{"title":"Add later","readings":[{"question":"Q1","method":"tarot","result_text":"R1","reading_date":"2033-03-01"}]}');
  rd := lifeos.reading_create(jsonb_build_object('divination_record_id', d->>'id','question','Q2 revised','method','i_ching','result_text','R2'));
  perform pg_temp.chk(rd->>'divination_record_id' = d->>'id' and rd->>'reading_date' = pg_temp.today()::text, 'reading_create defaults reading_date to today');
  perform pg_temp.chk(rd->'analyses' = '[]'::jsonb and rd->'story_person_ids' = '[]'::jsonb, 'analyses and story_person_ids default []');
  perform pg_temp.expect_err(format($$select lifeos.reading_create(jsonb_build_object('divination_record_id', %L::uuid,'question','q','method','tarot'))$$, d->>'id'), 'invalid input');
  perform pg_temp.expect_err($$select lifeos.reading_create(jsonb_build_object('divination_record_id', gen_random_uuid(),'question','q','method','tarot','result_text','r'))$$, 'record not found');

  an := lifeos.analysis_add(jsonb_build_object('reading_id', rd->>'id','source','Friend','overall_outcome','Go','key_reasoning','Gut feel'));
  perform pg_temp.chk(an->>'reading_id' = rd->>'id' and an->>'divination_record_id' = d->>'id', 'a Reading Analysis takes its Reading''s parent record');
  perform pg_temp.chk(an->>'analysis_date' = pg_temp.today()::text and an->>'story_context' is null, 'analysis_date defaults to today, story_context to null');
  comb := lifeos.analysis_add(jsonb_build_object('divination_record_id', d->>'id','source','Claude','overall_outcome','Combined','key_reasoning','All'));
  perform pg_temp.chk(comb->>'reading_id' is null and comb->>'divination_record_id' = d->>'id', 'with only divination_record_id the Analysis is combined');
  perform pg_temp.expect_err($$select lifeos.analysis_add('{"overall_outcome":"x","key_reasoning":"y","source":"s"}')$$, 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.analysis_add(jsonb_build_object('reading_id', %L::uuid,'overall_outcome','x','key_reasoning','y'))$$, rd->>'id'), 'invalid input');

  u := lifeos.reading_story_persons_set((rd->>'id')::uuid, jsonb_build_object('story_person_ids', jsonb_build_array(sp1, sp2)));
  perform pg_temp.chk(jsonb_array_length(u->'story_person_ids') = 2, 'two Story Persons set');
  u := lifeos.reading_story_persons_set((rd->>'id')::uuid, jsonb_build_object('story_person_ids', jsonb_build_array(sp2)));
  perform pg_temp.chk(u->'story_person_ids' = jsonb_build_array(sp2), 'the supplied array replaces the set');
  perform pg_temp.expect_err(format($$select lifeos.reading_story_persons_set(%L::uuid, jsonb_build_object('story_person_ids', jsonb_build_array(gen_random_uuid())))$$, rd->>'id'), 'record not found');
  perform pg_temp.expect_err(format($$select lifeos.reading_story_persons_set(%L::uuid, '{}')$$, rd->>'id'), 'invalid input');

  fr := lifeos.divination_record_read((d->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(fr->'readings') = 2 and (select r->>'result_text' from jsonb_array_elements(fr->'readings') r where r->>'question' = 'Q1') = 'R1', 'the earlier Reading stays unchanged');
  perform pg_temp.chk(jsonb_array_length(fr->'record_analyses') = 1, 'the combined Analysis is on the Divination Record');
  perform pg_temp.chk((lifeos.analysis_delete((an->>'id')::uuid)->>'deleted_at') is not null, 'analysis_delete returns deleted_at');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(lifeos.divination_record_read((d->>'id')::uuid)->'readings') r, jsonb_array_elements(r->'analyses') a) = 0, 'a deleted Analysis is hidden');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Deleting a Divination Record cascades; deleting a Reading keeps combined Analyses -----------
do $t$
declare t constant text := 'divination_delete_cascades_reading_delete_keeps_combined';
  d jsonb; d2 jsonb; del jsonb; fr jsonb; ra jsonb;
begin
  d := lifeos.divination_record_save('{"title":"cascade xq","readings":[
        {"question":"Q1","method":"tarot","result_text":"R1","analyses":[{"source":"S","overall_outcome":"O","key_reasoning":"K"}]},
        {"question":"Q2","method":"tarot","result_text":"R2"}],
        "record_analyses":[{"source":"S","overall_outcome":"CO","key_reasoning":"CK"}]}');
  del := lifeos.divination_record_delete((d->>'id')::uuid);
  perform pg_temp.chk(del->>'deleted_at' is not null and del->>'id' = d->>'id', 'delete returns id and deleted_at');
  fr := lifeos.divination_record_read((d->>'id')::uuid);
  perform pg_temp.chk(fr->>'deleted_at' = del->>'deleted_at', 'the Divination Record has the deleted_at');
  perform pg_temp.chk(jsonb_array_length(fr->'readings') = 2 and (select bool_and(r->>'deleted_at' = del->>'deleted_at') from jsonb_array_elements(fr->'readings') r), 'every Reading has the same deleted_at');
  perform pg_temp.chk((lifeos.divination_search('{"keyword":"cascade xq"}')->>'returned_count')::int = 0, 'search hides the deleted Divination Record');
  perform pg_temp.chk((lifeos.divination_search('{"keyword":"cascade xq","include_deleted":true}')->>'returned_count')::int = 1, 'include_deleted shows it');
  perform pg_temp.expect_err(format($$select lifeos.reading_create(jsonb_build_object('divination_record_id', %L::uuid,'question','q','method','tarot','result_text','r'))$$, d->>'id'), 'record deleted');

  d2 := lifeos.divination_record_save('{"title":"reading delete xq","readings":[
        {"question":"Q1","method":"tarot","result_text":"R1","analyses":[{"source":"S","overall_outcome":"O","key_reasoning":"K"}]},
        {"question":"Q2","method":"tarot","result_text":"R2"}],
        "record_analyses":[{"source":"S","overall_outcome":"CO","key_reasoning":"CK"}]}');
  del := lifeos.reading_delete((d2->'readings'->0->>'id')::uuid);
  perform pg_temp.chk(del->>'deleted_at' is not null, 'reading_delete returns deleted_at');
  fr := lifeos.divination_record_read((d2->>'id')::uuid);
  perform pg_temp.chk(fr->>'deleted_at' is null, 'the Divination Record stays active');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(fr->'readings') r where r->>'deleted_at' is null) = 1, 'one active Reading remains');
  perform pg_temp.chk(jsonb_array_length(fr->'record_analyses') = 1 and fr->'record_analyses'->0->>'deleted_at' is null, 'the combined Analysis stays');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lifeos.divination_search('{"keyword":"reading delete xq"}')->'results'->0->'readings') r where r->>'question' = 'Q1'),
                      'the deleted Reading is hidden from search');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Story Person: create, search, read, update, delete -------------------------------------------
do $t$
declare t constant text := 'story_person_create_search_read_delete';
  subj uuid := (lifeos.subject_create('{"name":"Real Alex","subject_type":"person"}')->>'id')::uuid; p jsonb; p2 jsonb; r jsonb; d jsonb; sl jsonb; rd jsonb;
begin
  p := lifeos.story_person_create(jsonb_build_object('name','Alex','gender','male','description','tall, works at the bank','aliases', jsonb_build_array('Al','Lex'),'subject_id', subj));
  perform pg_temp.chk(p->>'name' = 'Alex' and p->>'gender' = 'male' and p->>'subject_id' = subj::text and p->'aliases' = '["Al","Lex"]'::jsonb, 'Story Person fields stored');
  p2 := lifeos.story_person_create('{"name":"Blair"}');
  perform pg_temp.chk(p2->'aliases' = '[]'::jsonb and p2->>'subject_id' is null and p2->'metadata' = '{}'::jsonb, 'defaults aliases [], subject_id null, metadata {}');
  perform pg_temp.expect_err($$select lifeos.story_person_create('{"gender":"x"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.story_person_create(jsonb_build_object('name','x','subject_id', gen_random_uuid()))$$, 'record not found');

  perform pg_temp.chk((lifeos.story_person_search('{"keyword":"lex"}')->>'returned_count')::int = 1, 'keyword matches aliases');
  perform pg_temp.chk((lifeos.story_person_search('{"keyword":"the bank"}')->>'returned_count')::int = 1, 'keyword matches description');
  perform pg_temp.chk((lifeos.story_person_search('{"keyword":"BLAIR"}')->>'returned_count')::int = 1, 'keyword matches name');
  perform pg_temp.chk((lifeos.story_person_search(jsonb_build_object('subject_id', subj))->>'returned_count')::int = 1, 'subject_id filter');
  perform pg_temp.chk((lifeos.story_person_search('{"gender":"male"}')->>'returned_count')::int = 1, 'gender filter');

  sl := lifeos.storyline_create(jsonb_build_object('content','Alex got a promotion','story_person_ids', jsonb_build_array(p->>'id')));
  rd := lifeos.divination_record_save(jsonb_build_object('readings', jsonb_build_array(jsonb_build_object('question','Q','method','tarot','result_text','R','story_person_ids', jsonb_build_array(p->>'id')))));
  r := lifeos.story_person_read((p->>'id')::uuid);
  perform pg_temp.chk(r->'storyline_ids' = jsonb_build_array(sl->>'id') and r->'reading_ids' = jsonb_build_array(rd->'readings'->0->>'id'), 'story_person_read returns storyline_ids and reading_ids');
  r := lifeos.story_person_update((p->>'id')::uuid, '{"description":"tall, now a manager","subject_id":null}');
  perform pg_temp.chk(r->>'description' = 'tall, now a manager' and r->>'subject_id' is null and r->>'name' = 'Alex', 'update changes fields and clears the Subject association');
  d := lifeos.story_person_delete((p->>'id')::uuid);
  perform pg_temp.chk(d->>'deleted_at' is not null, 'delete returns deleted_at');
  perform pg_temp.chk(lifeos.story_person_read((p->>'id')::uuid)->>'deleted_at' is not null, 'read of a deleted Story Person returns deleted_at');
  perform pg_temp.chk((lifeos.story_person_search('{"keyword":"Alex"}')->>'returned_count')::int = 0, 'search hides the deleted Story Person');
  perform pg_temp.expect_err(format($$select lifeos.story_person_update(%L::uuid, '{"name":"x"}')$$, p->>'id'), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Storyline search through confirmed Story Persons ------------------------------------------------
do $t$
declare t constant text := 'storyline_search_by_story_persons';
  a uuid := pg_temp.mk_sp('Ann (storyline)'); b uuid := pg_temp.mk_sp('Ben (storyline)'); c uuid := pg_temp.mk_sp('Cy (storyline)');
  s1 jsonb; s2 jsonb; s3 jsonb; s4 jsonb; s5 jsonb; r jsonb; ids text[];
begin
  s1 := lifeos.storyline_create(jsonb_build_object('title','Wedding','content','Ann and Ben married slxq','occurrence_date','2031-06-01','story_person_ids', jsonb_build_array(a, b)));
  s2 := lifeos.storyline_create(jsonb_build_object('title','Promotion','content','Ann promoted slxq','occurrence_date','2032-01-15','story_person_ids', jsonb_build_array(a)));
  s3 := lifeos.storyline_create(jsonb_build_object('title','Move','content','Cy moved city slxq','occurrence_date','2032-06-01','time_text','before the wedding','story_person_ids', jsonb_build_array(c)));
  s4 := lifeos.storyline_create(jsonb_build_object('title','Undated','content','Ann and Ben quarrelled slxq','story_person_ids', jsonb_build_array(a, b)));
  s5 := lifeos.storyline_create('{"content":"No person slxq"}');
  perform pg_temp.chk(s5->>'occurrence_date' is null and s5->'story_person_ids' = '[]'::jsonb and s5->'metadata' = '{}'::jsonb, 'unknown dates stay null, story_person_ids and metadata default empty');

  r := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a, b)));
  perform pg_temp.chk((r->>'returned_count')::int = 3, 'person_match any (default): Storylines with Ann or Ben, got ' || (r->>'returned_count'));
  perform pg_temp.chk((select array_agg(x->>'id' order by ord) from jsonb_array_elements(r->'results') with ordinality q(x, ord)) = array[s2->>'id', s1->>'id', s4->>'id'],
    'ordered by occurrence_date descending with null last');
  perform pg_temp.chk((select (x->'matched_person_ids') @> jsonb_build_array(a, b) and jsonb_array_length(x->'matched_person_ids') = 2 from jsonb_array_elements(r->'results') x where x->>'id' = s1->>'id'), 'matched_person_ids lists both persons of a shared Storyline');
  perform pg_temp.chk((select x->'matched_person_ids' = jsonb_build_array(a) from jsonb_array_elements(r->'results') x where x->>'id' = s2->>'id'), 'matched_person_ids lists only Ann for her individual Storyline');

  r := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a, b), 'person_match', 'all'));
  perform pg_temp.chk((r->>'returned_count')::int = 2 and (select bool_and(x->>'id' in (s1->>'id', s4->>'id')) from jsonb_array_elements(r->'results') x), 'person_match all: Storylines with Ann and Ben');
  r := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a, c), 'person_match', 'all'));
  perform pg_temp.chk((r->>'returned_count')::int = 0, 'person_match all: nothing holds Ann and Cy');
  r := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a), 'from_date','2032-01-01','to_date','2032-12-31'));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = s2->>'id', 'a date filter excludes Storylines with unknown or other dates');
  r := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(c), 'keyword', 'BEFORE THE WEDDING'));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = s3->>'id', 'keyword matches time_text');
  r := lifeos.storyline_search('{"keyword":"slxq"}');
  perform pg_temp.chk((r->>'returned_count')::int = 5, 'keyword-only search needs no Story Persons');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Storyline update (no history), delete, links to an Event --------------------------------------------
do $t$
declare t constant text := 'storyline_update_delete_and_links';
  a uuid := pg_temp.mk_sp('Dee (storyline)'); b uuid := pg_temp.mk_sp('Eli (storyline)'); s jsonb; u jsonb; ev jsonb; r jsonb; d jsonb;
begin
  s := lifeos.storyline_create(jsonb_build_object('content','Dee met Eli','story_person_ids', jsonb_build_array(a)));
  u := lifeos.storyline_update((s->>'id')::uuid, jsonb_build_object('content','Dee met Eli at a cafe','occurrence_date','2032-02-02','story_person_ids', jsonb_build_array(a, b)));
  perform pg_temp.chk(u->>'content' = 'Dee met Eli at a cafe' and u->>'occurrence_date' = '2032-02-02' and jsonb_array_length(u->'story_person_ids') = 2, 'update replaces content, date and persons');
  perform pg_temp.expect_err(format($$select lifeos.storyline_update(%L::uuid, '{"bogus":1}')$$, s->>'id'), 'unsupported field');
  perform pg_temp.expect_err($$select lifeos.storyline_create('{"title":"no content"}')$$, 'invalid input');
  ev := lifeos.event_create('{"title":"Coffee with Eli","occurred_date":"2032-02-02"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','storyline','from_id', s->>'id','to_type','event','to_id', ev->>'id'));
  r := lifeos.storyline_read((s->>'id')::uuid);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(r->'links') l where l->>'id' = ev->>'id'), 'storyline_read lists the linked Event');
  d := lifeos.storyline_delete((s->>'id')::uuid);
  perform pg_temp.chk(d->>'deleted_at' is not null, 'delete returns deleted_at');
  perform pg_temp.chk((lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a)))->>'returned_count')::int = 0, 'a deleted Storyline is hidden from search');
  perform pg_temp.chk((lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(a), 'include_deleted', true))->>'returned_count')::int = 1, 'include_deleted shows it');
  perform pg_temp.chk(lifeos.storyline_read((s->>'id')::uuid)->>'deleted_at' is not null, 'storyline_read still returns it');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Reading Remarks leave the Reading's updated_at unchanged -------------------------------
do $t$
declare t constant text := 'reading_remark_add_and_update_leave_reading_updated_at_unchanged';
  d jsonb; rid uuid; r jsonb; before_updated timestamptz;
begin
  d := lifeos.divination_record_save('{"readings":[{"question":"Q12","method":"tarot","result_text":"R12"}]}');
  rid := (d->'readings'->0->>'id')::uuid;
  -- Test setup: move updated_at 5 days back (one transaction has one clock value).
  update lifeos.readings set updated_at = updated_at - interval '5 days' where id = rid;
  select updated_at into before_updated from lifeos.readings where id = rid;
  r := lifeos.reading_remark_add(rid, '{"text":"first thought"}');
  perform pg_temp.chk((select updated_at from lifeos.readings where id = rid) = before_updated, 'reading_remark_add leaves updated_at unchanged');
  perform pg_temp.chk((r->>'updated_at')::timestamptz = before_updated, 'the returned Reading carries the unchanged updated_at');
  perform pg_temp.chk(jsonb_array_length(r->'remark_entries') = 1, 'the entry is added');
  r := lifeos.reading_remark_update(rid, jsonb_build_object('entry_id', r->'remark_entries'->0->>'entry_id', 'text', 'corrected thought'));
  perform pg_temp.chk((select updated_at from lifeos.readings where id = rid) = before_updated, 'reading_remark_update leaves updated_at unchanged');
  perform pg_temp.chk(r->'remark_entries'->0->>'text' = 'corrected thought', 'the entry is corrected');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
