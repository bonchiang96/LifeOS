-- =============================================================================
-- tests/10_qa_regression.sql -- QA regression of M-0021 D4 to D10 and M-0022 D4
-- Re-creates the J-0021 Item L2 behaviour assertions (Job Record 4.4) and adds
-- M-0022 D4: record_links_read on a Subject lists each connected Record once with
-- an ordered via_list.
--
-- Each test is named after its J-0021 assertion ID (qa_d<n>_<k>_...) or its
-- M-0022 Decision (qa_m22_d4_<k>_...).
--
-- Tests in this file:
--   M-0021 D4, Person Subject with a Profile
--     qa_d4_1_delete_person_subject_with_profile_rejected
--     qa_d4_2_rejection_detail_names_the_profile
--     qa_d4_3_rejected_subject_stays_active
--     qa_d4_4_rejected_subject_keeps_its_profile
--     qa_d4_5_subject_without_profile_is_deleted
--     qa_d4_6_profile_deleted_then_subject_deleted
--     qa_d4_7_subject_read_shows_the_deletion
--     qa_d4_8_profile_relinked_then_old_subject_deleted
--     qa_d4_9_relinked_profile_active_on_new_subject
--     qa_d4_10_new_person_subject_delete_rejected
--   M-0021 D5, no Record link between Divination Record or Reading and Storyline
--     qa_d5_1_divination_record_to_storyline_rejected
--     qa_d5_2_storyline_to_divination_record_rejected
--     qa_d5_3_reading_to_storyline_rejected
--     qa_d5_4_storyline_to_reading_rejected
--     qa_d5_5_no_stored_link_for_rejected_pairs
--     qa_d5_6_control_reading_to_event_link_created
--     qa_d5_7_control_storyline_to_event_link_created
--     qa_d5_8_reading_remark_entry_holds_storyline_id
--   M-0021 D6, each Subject once per Record
--     qa_d6_1_timeline_observation_subject_once_via_record_link
--     qa_d6_2_timeline_observation_links_subject_once
--     qa_d6_3_timeline_expense_subject_once_via_record_link
--     qa_d6_4_timeline_expense_links_subject_once
--     qa_d6_5_control_two_distinct_subjects_both_listed
--     qa_d6_6_timeline_reading_subject_once_via_record_link
--     qa_d6_7_timeline_reading_links_subject_once
--     qa_d6_8_observation_read_links_subject_once
--     qa_d6_9_expense_read_links_subject_once
--     qa_d6_10_record_links_read_expense_subject_once
--     qa_d6_11_divination_record_read_reading_links_subject_once
--     qa_d6_12_divination_search_by_subject_lists_reading_once
--   M-0021 D7, purchase delete with Refunds
--     qa_d7_1_refund_alone_delete_returns_no_refund_ids
--     qa_d7_2_purchase_stays_active_after_refund_delete
--     qa_d7_3_purchase_delete_returns_refund_ids_in_refunds_order
--     qa_d7_4_refund_r1_gets_purchase_deleted_at
--     qa_d7_5_refund_r2_gets_purchase_deleted_at
--     qa_d7_6_refund_r1_own_history_version
--     qa_d7_7_refund_r2_own_history_version
--     qa_d7_8_purchase_history_version
--     qa_d7_9_already_deleted_refund_untouched
--     qa_d7_10_second_purchase_delete_changes_nothing
--     qa_d7_11_purchase_without_refunds_returns_no_refund_ids
--     qa_d7_12_refund_alone_delete_keeps_purchase_active
--   M-0021 D8, Storyline end date never before start date
--     qa_d8_1_create_end_before_start_rejected
--     qa_d8_2_create_same_day_accepted
--     qa_d8_3_create_end_after_start_accepted
--     qa_d8_4_create_end_date_only_accepted
--     qa_d8_5_update_end_before_stored_start_rejected
--     qa_d8_6_update_start_after_stored_end_rejected
--     qa_d8_7_rejected_update_leaves_dates_unchanged
--     qa_d8_8_update_start_to_stored_end_same_day_accepted
--     qa_d8_9_update_end_to_stored_start_same_day_accepted
--     qa_d8_10_update_both_dates_end_before_start_rejected
--     qa_d8_11_update_both_dates_valid_accepted
--     qa_d8_12_update_without_date_change_accepted
--   M-0021 D9, Event delete and its Schedule
--     qa_d9_0_event_create_sets_schedule_occurred
--     qa_d9_1_event_delete_returns_active_schedule_to_planned
--     qa_d9_2_returned_schedule_is_planned_without_event
--     qa_d9_3_stored_event_schedule_id_cleared
--     qa_d9_4_deleted_schedule_keeps_status
--     qa_d9_5_deleted_schedule_reads_occurred_and_deleted
--     qa_d9_6_stored_status_of_deleted_schedule_is_occurred
--     qa_d9_7_stored_event_schedule_id_cleared_for_deleted_schedule
--     qa_d9_8_event_without_schedule_returns_null
--   M-0021 D10, a deleted Record ID in p_filter matches nothing
--     qa_d10_1 to qa_d10_34 (event, observation, expense, divination, story person,
--     storyline, communication profile and message searches)
--   M-0022 D4, one listing per Record from a Subject
--     qa_m22_d4_1_subject_several_paths_one_expense_listed_once
--     qa_m22_d4_2_subject_paths_without_record_link_in_order
--     qa_m22_d4_3_record_reached_by_one_path_has_via_list_of_one
--     qa_m22_d4_4_observation_two_paths_in_order
--     qa_m22_d4_5_every_subject_entry_once_with_ordered_via_list
--     qa_m22_d4_6_record_side_entries_have_no_via_list
--
-- Test setup that the Contract has no function for: qa_d5_5 reads
-- lifeos.record_links, qa_d9_3 and qa_d9_7 read lifeos.events, and qa_d9_6 reads
-- lifeos.schedules, to check stored values that no Contract return shows.
-- Every other step calls Contract functions only.
--
-- Setup blocks record a row only when they fail (name ending in _setup).
-- A transaction has one clock value, so every deleted_at in this file is equal.
-- qa_d7_4, qa_d7_5 and qa_d7_10 therefore also check history counts and reasons.
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

-- Runs a statement and returns the PostgreSQL detail text of its error, or null.
create function pg_temp.err_detail_of(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v = pg_exception_detail;
  return v;
end $f$;

-- Raises an exception unless the statement fails with exactly the Contract error text.
create function pg_temp.expect_err(p_sql text, p_expected text) returns void language plpgsql as $f$
declare v text := pg_temp.err_of(p_sql);
begin
  if v is distinct from p_expected then
    raise exception 'expected error "%" but got "%" for: %', p_expected, coalesce(v, '<no error>'), left(p_sql, 200);
  end if;
end $f$;

-- Fixture ids and values shared between the tests of this file.
create temp table t_ids (k text primary key, v uuid);
create function pg_temp.id(p_k text) returns uuid language sql as
$f$ select v from t_ids where k = p_k $f$;
create function pg_temp.keep(p_k text, p_v uuid) returns uuid language plpgsql as $f$
begin
  if p_v is null then raise exception 'setup: no id returned for %', p_k; end if;
  insert into t_ids values (p_k, p_v) on conflict (k) do update set v = excluded.v;
  return p_v;
end $f$;

create temp table t_vals (k text primary key, v text);
create function pg_temp.val(p_k text) returns text language sql as
$f$ select v from t_vals where k = p_k $f$;
create function pg_temp.put(p_k text, p_v text) returns void language plpgsql as $f$
begin insert into t_vals values (p_k, p_v) on conflict (k) do update set v = excluded.v; end $f$;

-- Quote helper for building statements that contain a uuid.
create function pg_temp.q(p uuid) returns text language sql as $f$ select quote_literal(p::text) || '::uuid' $f$;

-- Statement text of record_link_create for an expect_err call.
create function pg_temp.link_sql(p_ft text, p_fid uuid, p_tt text, p_tid uuid) returns text language sql as $f$
  select format('select lifeos.record_link_create(%L::jsonb)',
    jsonb_build_object('from_type', p_ft, 'from_id', p_fid, 'to_type', p_tt, 'to_id', p_tid)::text)
$f$;

-- Creates a Record link and returns the call's return.
create function pg_temp.link(p_ft text, p_fid uuid, p_tt text, p_tid uuid) returns jsonb language sql as $f$
  select lifeos.record_link_create(jsonb_build_object('from_type', p_ft, 'from_id', p_fid, 'to_type', p_tt, 'to_id', p_tid))
$f$;

-- Number of entries with this id in a JSON array (Timeline subjects or Contract shared.md 4.5.3 links).
create function pg_temp.cnt(p_arr jsonb, p_id uuid) returns int language sql as $f$
  select count(*)::int from jsonb_array_elements(coalesce(p_arr, '[]'::jsonb)) e where e->>'id' = p_id::text
$f$;

-- The via of the first entry with this id.
create function pg_temp.via_of(p_arr jsonb, p_id uuid) returns text language sql as $f$
  select e->>'via' from jsonb_array_elements(coalesce(p_arr, '[]'::jsonb)) with ordinality x(e, n)
  where e->>'id' = p_id::text order by n limit 1
$f$;

-- The entry with this id in a JSON array.
create function pg_temp.entry(p_arr jsonb, p_id uuid) returns jsonb language sql as $f$
  select e from jsonb_array_elements(coalesce(p_arr, '[]'::jsonb)) with ordinality x(e, n)
  where e->>'id' = p_id::text order by n limit 1
$f$;

-- The Timeline item of one Record.
create function pg_temp.tl_item(p_tl jsonb, p_id uuid) returns jsonb language sql as $f$
  select pg_temp.entry(p_tl->'items', p_id)
$f$;

-- Text values of a JSON array, in array order.
create function pg_temp.txt_arr(p_arr jsonb) returns text[] language sql as $f$
  select coalesce(array_agg(v order by n), '{}'::text[]) from jsonb_array_elements_text(coalesce(p_arr, '[]'::jsonb)) with ordinality x(v, n)
$f$;

-- The id fields of a JSON array of objects, in array order.
create function pg_temp.ids_of(p_arr jsonb) returns text[] language sql as $f$
  select coalesce(array_agg(e->>'id' order by n), '{}'::text[]) from jsonb_array_elements(coalesce(p_arr, '[]'::jsonb)) with ordinality x(e, n)
$f$;

-- Number of results of a search return.
create function pg_temp.nres(p jsonb) returns int language sql as $f$
  select jsonb_array_length(coalesce(p->'results', '[]'::jsonb))
$f$;

-- Number of Readings over all results of a divination_search return.
create function pg_temp.nreadings(p jsonb) returns int language sql as $f$
  select count(*)::int from jsonb_array_elements(coalesce(p->'results', '[]'::jsonb)) d,
         jsonb_array_elements(coalesce(d->'readings', '[]'::jsonb)) r
$f$;

-- Number of times one Reading appears over all results of a divination_search return.
create function pg_temp.nreading(p jsonb, p_id uuid) returns int language sql as $f$
  select count(*)::int from jsonb_array_elements(coalesce(p->'results', '[]'::jsonb)) d,
         jsonb_array_elements(coalesce(d->'readings', '[]'::jsonb)) r
  where r->>'id' = p_id::text
$f$;

-- The id of the first Reading of a Divination Record return.
create function pg_temp.reading_id(p jsonb, p_n int) returns uuid language sql as $f$
  select (p->'readings'->p_n->>'id')::uuid
$f$;

-- Creates one purchase Expense with one item Line. Null Subject ids are left out.
create function pg_temp.purchase(p_pm uuid, p_merchant uuid, p_item uuid, p_date date, p_total numeric, p_merchant_name text)
returns jsonb language sql as $f$
  select lifeos.expense_create(jsonb_strip_nulls(jsonb_build_object(
    'transaction_date', p_date, 'merchant_name', p_merchant_name,
    'merchant_subject_id', p_merchant, 'payment_method_subject_id', p_pm,
    'expense_total', p_total, 'currency', 'MYR',
    'lines', jsonb_build_array(jsonb_build_object(
      'line_type', 'item', 'item_description', 'QA item', 'unit_price', p_total,
      'line_total', p_total, 'category', 'food', 'item_subject_id', p_item)))))
$f$;

-- The M-0022 D2 position of a via value, or null for a value outside the order.
create function pg_temp.via_rank(p text) returns int language sql as $f$
  select array_position(array['record_link','observation_subject','payment_method','merchant',
                              'line_item','story_person_subject','person_profile_subject'], p)
$f$;

-- =============================================================================
-- M-0021 D4: a Person Subject with an active Profile cannot be deleted
-- =============================================================================
do $t$
declare t constant text := 'qa_d4_setup';
  s1 uuid; s3 uuid; s4 uuid; p jsonb;
begin
  s1 := pg_temp.keep('d4_s1', (lifeos.subject_create('{"name":"QA D4 Person One","subject_type":"person"}')->>'id')::uuid);
  perform pg_temp.keep('d4_s2', (lifeos.subject_create('{"name":"QA D4 Person Two","subject_type":"person"}')->>'id')::uuid);
  s3 := pg_temp.keep('d4_s3', (lifeos.subject_create('{"name":"QA D4 Person Three","subject_type":"person"}')->>'id')::uuid);
  s4 := pg_temp.keep('d4_s4', (lifeos.subject_create('{"name":"QA D4 Person Four","subject_type":"person"}')->>'id')::uuid);
  p := lifeos.communication_profile_create(jsonb_build_object('profile_key','qa_m21_d4_p1','profile_type','person','name','QA D4 Profile One','person_subject_id', s1));
  perform pg_temp.keep('d4_p1', (p->>'id')::uuid);
  p := lifeos.communication_profile_create(jsonb_build_object('profile_key','qa_m21_d4_p3','profile_type','person','name','QA D4 Profile Three','person_subject_id', s3));
  perform pg_temp.keep('d4_p3', (p->>'id')::uuid);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-1 (D4.5): subject_delete on a Person Subject with an active Profile is rejected.
do $t$
declare t constant text := 'qa_d4_1_delete_person_subject_with_profile_rejected';
begin
  perform pg_temp.expect_err(format('select lifeos.subject_delete(%s)', pg_temp.q(pg_temp.id('d4_s1'))), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-2 (D4.5): the error detail names the cause.
do $t$
declare t constant text := 'qa_d4_2_rejection_detail_names_the_profile';
  d text;
begin
  d := pg_temp.err_detail_of(format('select lifeos.subject_delete(%s)', pg_temp.q(pg_temp.id('d4_s1'))));
  perform pg_temp.chk(d = 'the Person Subject still has a Profile', format('detail is "the Person Subject still has a Profile", got "%s"', coalesce(d, '<none>')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-3 (D4.5): the rejected Subject stays active.
do $t$
declare t constant text := 'qa_d4_3_rejected_subject_stays_active';
  s jsonb;
begin
  s := lifeos.subject_read(pg_temp.id('d4_s1'));
  perform pg_temp.chk(s ? 'deleted_at' and s->>'deleted_at' is null, 'subject_read shows deleted_at null after the rejected delete');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-4 (D4.5): the rejected Subject keeps its Profile.
do $t$
declare t constant text := 'qa_d4_4_rejected_subject_keeps_its_profile';
  s jsonb;
begin
  s := lifeos.subject_read(pg_temp.id('d4_s1'));
  perform pg_temp.chk(s->>'person_profile_id' = pg_temp.id('d4_p1')::text, 'person_profile_id is still the Profile');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-5 (D4.1): a Person Subject without a Profile is deleted directly.
do $t$
declare t constant text := 'qa_d4_5_subject_without_profile_is_deleted';
  d jsonb;
begin
  d := lifeos.subject_delete(pg_temp.id('d4_s2'));
  perform pg_temp.chk(d->>'id' = pg_temp.id('d4_s2')::text, 'delete returns the Subject id');
  perform pg_temp.chk(d->>'deleted_at' is not null, 'delete returns deleted_at');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-6 (D4.4): after the Profile is deleted, the Subject can be deleted.
do $t$
declare t constant text := 'qa_d4_6_profile_deleted_then_subject_deleted';
  d jsonb;
begin
  perform lifeos.communication_profile_delete(pg_temp.id('d4_p1'));
  d := lifeos.subject_delete(pg_temp.id('d4_s1'));
  perform pg_temp.chk(d->>'deleted_at' is not null, 'subject_delete returns deleted_at after the Profile delete');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-7 (D4.4): the Subject now reads as deleted.
do $t$
declare t constant text := 'qa_d4_7_subject_read_shows_the_deletion';
begin
  perform pg_temp.chk(lifeos.subject_read(pg_temp.id('d4_s1'))->>'deleted_at' is not null, 'subject_read shows deleted_at set');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-8 (D4.3): after the Profile moves to another Subject, the old Subject can be deleted.
do $t$
declare t constant text := 'qa_d4_8_profile_relinked_then_old_subject_deleted';
  d jsonb;
begin
  perform lifeos.communication_profile_update(pg_temp.id('d4_p3'), jsonb_build_object('person_subject_id', pg_temp.id('d4_s4')));
  d := lifeos.subject_delete(pg_temp.id('d4_s3'));
  perform pg_temp.chk(d->>'deleted_at' is not null, 'subject_delete of the old Subject returns deleted_at');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-9 (D4.3): the moved Profile stays active on its new Subject.
do $t$
declare t constant text := 'qa_d4_9_relinked_profile_active_on_new_subject';
  p jsonb;
begin
  p := lifeos.communication_profile_read(pg_temp.id('d4_p3'));
  perform pg_temp.chk(p->>'deleted_at' is null, 'the Profile is active');
  perform pg_temp.chk(p->>'person_subject_id' = pg_temp.id('d4_s4')::text, 'person_subject_id is the new Subject');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D4-10 (D4.5): the new Person Subject, now holding the Profile, cannot be deleted.
do $t$
declare t constant text := 'qa_d4_10_new_person_subject_delete_rejected';
begin
  perform pg_temp.expect_err(format('select lifeos.subject_delete(%s)', pg_temp.q(pg_temp.id('d4_s4'))), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- =============================================================================
-- M-0021 D5: no Record link between a Divination Record or a Reading and a Storyline
-- =============================================================================
do $t$
declare t constant text := 'qa_d5_setup';
  d jsonb;
begin
  d := lifeos.divination_record_save('{"title":"QA D5 Divination","session_date":"2031-02-10",
        "readings":[{"question":"QA D5 question","method":"i_ching","result_text":"QA D5 result"}]}');
  perform pg_temp.keep('d5_dr', (d->>'id')::uuid);
  perform pg_temp.keep('d5_r', pg_temp.reading_id(d, 0));
  perform pg_temp.keep('d5_sl', (lifeos.storyline_create('{"title":"QA D5 Storyline","content":"QA D5 story"}')->>'id')::uuid);
  perform pg_temp.keep('d5_ev', (lifeos.event_create('{"title":"QA D5 Event","occurred_date":"2031-02-10"}')->>'id')::uuid);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-1 (D5.3)
do $t$
declare t constant text := 'qa_d5_1_divination_record_to_storyline_rejected';
begin
  perform pg_temp.expect_err(pg_temp.link_sql('divination_record', pg_temp.id('d5_dr'), 'storyline', pg_temp.id('d5_sl')), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-2 (D5.3)
do $t$
declare t constant text := 'qa_d5_2_storyline_to_divination_record_rejected';
begin
  perform pg_temp.expect_err(pg_temp.link_sql('storyline', pg_temp.id('d5_sl'), 'divination_record', pg_temp.id('d5_dr')), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-3 (D5.1, Reading)
do $t$
declare t constant text := 'qa_d5_3_reading_to_storyline_rejected';
begin
  perform pg_temp.expect_err(pg_temp.link_sql('reading', pg_temp.id('d5_r'), 'storyline', pg_temp.id('d5_sl')), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-4 (D5.1, Reading)
do $t$
declare t constant text := 'qa_d5_4_storyline_to_reading_rejected';
begin
  perform pg_temp.expect_err(pg_temp.link_sql('storyline', pg_temp.id('d5_sl'), 'reading', pg_temp.id('d5_r')), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-5 (D5.3): no link is stored for the rejected pairs. Reads lifeos.record_links.
do $t$
declare t constant text := 'qa_d5_5_no_stored_link_for_rejected_pairs';
  dr uuid := pg_temp.id('d5_dr'); r uuid := pg_temp.id('d5_r'); sl uuid := pg_temp.id('d5_sl');
  l jsonb; n int;
begin
  l := lifeos.record_links_read('storyline', sl);
  perform pg_temp.chk(pg_temp.cnt(l->'links', dr) = 0 and pg_temp.cnt(l->'links', r) = 0, 'record_links_read on the Storyline lists neither the Divination Record nor the Reading');
  select count(*) into n from lifeos.record_links
   where (record_id_a in (dr, r) and record_id_b = sl) or (record_id_b in (dr, r) and record_id_a = sl);
  perform pg_temp.chk(n = 0, format('stored record_links for the pairs is 0, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-6 (control): a Reading still links to an Event.
do $t$
declare t constant text := 'qa_d5_6_control_reading_to_event_link_created';
  l jsonb;
begin
  l := pg_temp.link('reading', pg_temp.id('d5_r'), 'event', pg_temp.id('d5_ev'));
  perform pg_temp.chk(l->>'link_id' is not null, 'link_id returned');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-7 (control): a Storyline still links to an Event.
do $t$
declare t constant text := 'qa_d5_7_control_storyline_to_event_link_created';
  l jsonb;
begin
  l := pg_temp.link('storyline', pg_temp.id('d5_sl'), 'event', pg_temp.id('d5_ev'));
  perform pg_temp.chk(l->>'link_id' is not null, 'link_id returned');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D5-8 (D5.2): the relation goes in a Reading Remark entry with storyline_id.
do $t$
declare t constant text := 'qa_d5_8_reading_remark_entry_holds_storyline_id';
  r jsonb; e jsonb;
begin
  r := lifeos.reading_remark_add(pg_temp.id('d5_r'), jsonb_build_object('text', 'QA D5 matches the Storyline', 'storyline_id', pg_temp.id('d5_sl')));
  e := r->'remark_entries'-> -1;
  perform pg_temp.chk(e->>'storyline_id' = pg_temp.id('d5_sl')::text, 'the new entry holds the storyline_id');
  perform pg_temp.chk(e->>'entry_id' is not null and e->>'text' = 'QA D5 matches the Storyline', 'the new entry has entry_id and text');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- =============================================================================
-- M-0021 D6: each connected Subject appears once per Record (Contract shared.md 1.5 item 15)
-- Period 2031-05-01 to 2031-05-03.
-- =============================================================================
do $t$
declare t constant text := 'qa_d6_setup';
  x uuid; y uuid; y2 uuid; z uuid; sp uuid; o uuid; e uuid; d jsonb;
begin
  x  := pg_temp.keep('d6_x',  (lifeos.subject_create('{"name":"QA D6 Subject X"}')->>'id')::uuid);
  y  := pg_temp.keep('d6_y',  (lifeos.subject_create('{"name":"QA D6 Subject Y"}')->>'id')::uuid);
  y2 := pg_temp.keep('d6_y2', (lifeos.subject_create('{"name":"QA D6 Subject Y2"}')->>'id')::uuid);
  z  := pg_temp.keep('d6_z',  (lifeos.subject_create('{"name":"QA D6 Subject Z","subject_type":"person"}')->>'id')::uuid);

  -- Observation of X, also linked to X by a Record link: two paths.
  o := pg_temp.keep('d6_o', (lifeos.observation_create(jsonb_build_object('subject_id', x, 'observation_name', 'qa d6 weight',
        'value_numeric', 70.5, 'unit', 'kg', 'observed_date', '2031-05-02'))->>'id')::uuid);
  perform pg_temp.link('observation', o, 'subject', x);

  -- Expense with Y as Payment Method, Merchant and Line Item, also linked by a Record link: four paths.
  e := pg_temp.keep('d6_e', (pg_temp.purchase(y, y, y, '2031-05-02', 12.50, 'QA D6 Shop')->>'id')::uuid);
  perform pg_temp.link('expense', e, 'subject', y);

  -- Control Expense: Payment Method Y2, Merchant Y.
  perform pg_temp.keep('d6_e2', (pg_temp.purchase(y2, y, null, '2031-05-02', 8.00, 'QA D6 Control')->>'id')::uuid);

  -- Reading with a Story Person of Z, also linked to Z by a Record link: two paths.
  sp := pg_temp.keep('d6_sp', (lifeos.story_person_create(jsonb_build_object('name', 'QA D6 Story Person Z', 'subject_id', z))->>'id')::uuid);
  d := lifeos.divination_record_save(jsonb_build_object('title', 'QA D6 Divination', 'session_date', '2031-05-02',
        'readings', jsonb_build_array(jsonb_build_object('question', 'QA D6 question', 'method', 'i_ching',
          'result_text', 'QA D6 result', 'reading_date', '2031-05-02', 'story_person_ids', jsonb_build_array(sp)))));
  perform pg_temp.keep('d6_dr', (d->>'id')::uuid);
  perform pg_temp.keep('d6_r', pg_temp.reading_id(d, 0));
  perform pg_temp.link('reading', pg_temp.id('d6_r'), 'subject', z);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-1: Timeline subjects of the Observation list X once, via record_link.
do $t$
declare t constant text := 'qa_d6_1_timeline_observation_subject_once_via_record_link';
  i jsonb;
begin
  i := pg_temp.tl_item(lifeos.timeline('{"from_date":"2031-05-01","to_date":"2031-05-03"}'), pg_temp.id('d6_o'));
  perform pg_temp.chk(i is not null, 'the Observation is a Timeline item');
  perform pg_temp.chk(pg_temp.cnt(i->'subjects', pg_temp.id('d6_x')) = 1, format('X appears once in subjects, got %s', pg_temp.cnt(i->'subjects', pg_temp.id('d6_x'))));
  perform pg_temp.chk(pg_temp.via_of(i->'subjects', pg_temp.id('d6_x')) = 'record_link', 'via is record_link');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-2: Timeline links of the Observation list X once.
do $t$
declare t constant text := 'qa_d6_2_timeline_observation_links_subject_once';
  i jsonb;
begin
  i := pg_temp.tl_item(lifeos.timeline('{"from_date":"2031-05-01","to_date":"2031-05-03"}'), pg_temp.id('d6_o'));
  perform pg_temp.chk(pg_temp.cnt(i->'links', pg_temp.id('d6_x')) = 1, format('X appears once in links, got %s', pg_temp.cnt(i->'links', pg_temp.id('d6_x'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-3: Timeline subjects of the Expense list Y once, via record_link.
do $t$
declare t constant text := 'qa_d6_3_timeline_expense_subject_once_via_record_link';
  i jsonb;
begin
  i := pg_temp.tl_item(lifeos.timeline('{"from_date":"2031-05-01","to_date":"2031-05-03"}'), pg_temp.id('d6_e'));
  perform pg_temp.chk(i is not null, 'the Expense is a Timeline item');
  perform pg_temp.chk(pg_temp.cnt(i->'subjects', pg_temp.id('d6_y')) = 1, format('Y appears once in subjects, got %s', pg_temp.cnt(i->'subjects', pg_temp.id('d6_y'))));
  perform pg_temp.chk(pg_temp.via_of(i->'subjects', pg_temp.id('d6_y')) = 'record_link', 'via is record_link');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-4: Timeline links of the Expense list Y once.
do $t$
declare t constant text := 'qa_d6_4_timeline_expense_links_subject_once';
  i jsonb;
begin
  i := pg_temp.tl_item(lifeos.timeline('{"from_date":"2031-05-01","to_date":"2031-05-03"}'), pg_temp.id('d6_e'));
  perform pg_temp.chk(pg_temp.cnt(i->'links', pg_temp.id('d6_y')) = 1, format('Y appears once in links, got %s', pg_temp.cnt(i->'links', pg_temp.id('d6_y'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-5 (control): two different Subjects on one Expense are both listed.
do $t$
declare t constant text := 'qa_d6_5_control_two_distinct_subjects_both_listed';
  i jsonb; n int; nd int;
begin
  i := pg_temp.tl_item(lifeos.timeline('{"from_date":"2031-05-01","to_date":"2031-05-03"}'), pg_temp.id('d6_e2'));
  select count(*), count(distinct e->>'id') into n, nd from jsonb_array_elements(coalesce(i->'subjects', '[]'::jsonb)) e;
  perform pg_temp.chk(n = 2 and nd = 2, format('2 subjects, 2 distinct, got %s / %s', n, nd));
  perform pg_temp.chk(pg_temp.via_of(i->'subjects', pg_temp.id('d6_y2')) = 'payment_method', 'Y2 via payment_method');
  perform pg_temp.chk(pg_temp.via_of(i->'subjects', pg_temp.id('d6_y')) = 'merchant', 'Y via merchant');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-6: Timeline subjects of the Reading list Z once, via record_link.
do $t$
declare t constant text := 'qa_d6_6_timeline_reading_subject_once_via_record_link';
  i jsonb;
begin
  i := pg_temp.tl_item(lifeos.timeline('{"from_date":"2031-05-01","to_date":"2031-05-03"}'), pg_temp.id('d6_r'));
  perform pg_temp.chk(i is not null, 'the Reading is a Timeline item');
  perform pg_temp.chk(pg_temp.cnt(i->'subjects', pg_temp.id('d6_z')) = 1, format('Z appears once in subjects, got %s', pg_temp.cnt(i->'subjects', pg_temp.id('d6_z'))));
  perform pg_temp.chk(pg_temp.via_of(i->'subjects', pg_temp.id('d6_z')) = 'record_link', 'via is record_link');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-7: Timeline links of the Reading list Z once.
do $t$
declare t constant text := 'qa_d6_7_timeline_reading_links_subject_once';
  i jsonb;
begin
  i := pg_temp.tl_item(lifeos.timeline('{"from_date":"2031-05-01","to_date":"2031-05-03"}'), pg_temp.id('d6_r'));
  perform pg_temp.chk(pg_temp.cnt(i->'links', pg_temp.id('d6_z')) = 1, format('Z appears once in links, got %s', pg_temp.cnt(i->'links', pg_temp.id('d6_z'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-8 (Contract shared.md 1.5 item 15): observation_read links list X once.
do $t$
declare t constant text := 'qa_d6_8_observation_read_links_subject_once';
  r jsonb;
begin
  r := lifeos.observation_read(pg_temp.id('d6_o'));
  perform pg_temp.chk(pg_temp.cnt(r->'links', pg_temp.id('d6_x')) = 1, format('X appears once, got %s', pg_temp.cnt(r->'links', pg_temp.id('d6_x'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-9 (Contract shared.md 1.5 item 15): expense_read links list Y once.
do $t$
declare t constant text := 'qa_d6_9_expense_read_links_subject_once';
  r jsonb;
begin
  r := lifeos.expense_read(pg_temp.id('d6_e'));
  perform pg_temp.chk(pg_temp.cnt(r->'links', pg_temp.id('d6_y')) = 1, format('Y appears once, got %s', pg_temp.cnt(r->'links', pg_temp.id('d6_y'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-10 (Contract shared.md 4.5.3 item 5): record_links_read on the Expense lists Y once.
do $t$
declare t constant text := 'qa_d6_10_record_links_read_expense_subject_once';
  r jsonb;
begin
  r := lifeos.record_links_read('expense', pg_temp.id('d6_e'));
  perform pg_temp.chk(pg_temp.cnt(r->'links', pg_temp.id('d6_y')) = 1, format('Y appears once, got %s', pg_temp.cnt(r->'links', pg_temp.id('d6_y'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-11 (Contract shared.md 1.5 item 15): divination_record_read Reading links list Z once.
do $t$
declare t constant text := 'qa_d6_11_divination_record_read_reading_links_subject_once';
  rd jsonb;
begin
  rd := pg_temp.entry(lifeos.divination_record_read(pg_temp.id('d6_dr'))->'readings', pg_temp.id('d6_r'));
  perform pg_temp.chk(rd is not null, 'the Reading is in the read');
  perform pg_temp.chk(pg_temp.cnt(rd->'links', pg_temp.id('d6_z')) = 1, format('Z appears once, got %s', pg_temp.cnt(rd->'links', pg_temp.id('d6_z'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D6-12 (supplementary): divination_search by Z lists the Reading once, though two paths lead to it.
do $t$
declare t constant text := 'qa_d6_12_divination_search_by_subject_lists_reading_once';
  s jsonb;
begin
  s := lifeos.divination_search(jsonb_build_object('subject_id', pg_temp.id('d6_z')));
  perform pg_temp.chk(pg_temp.nreading(s, pg_temp.id('d6_r')) = 1, format('the Reading appears once, got %s', pg_temp.nreading(s, pg_temp.id('d6_r'))));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- =============================================================================
-- M-0021 D7: deleting a purchase also deletes its active Refunds
-- Purchase P = 100 MYR on 2031-06-01. R1 = 10 on 06-05, R2 = 20 on 06-03, R3 = 5 on 06-04.
-- =============================================================================
do $t$
declare t constant text := 'qa_d7_setup';
  pm uuid; p uuid; p3 uuid;
begin
  pm := pg_temp.keep('d7_pm', (lifeos.subject_create('{"name":"QA D7 Card","subject_type":"payment method"}')->>'id')::uuid);
  p := pg_temp.keep('d7_p', (pg_temp.purchase(pm, null, null, '2031-06-01', 100, 'QA D7 Shop')->>'id')::uuid);
  perform pg_temp.keep('d7_r1', (lifeos.expense_refund_create(jsonb_build_object('refund_of', p, 'refund_amount', 10, 'transaction_date', '2031-06-05', 'line_type', 'item'))->>'id')::uuid);
  perform pg_temp.keep('d7_r2', (lifeos.expense_refund_create(jsonb_build_object('refund_of', p, 'refund_amount', 20, 'transaction_date', '2031-06-03', 'line_type', 'item'))->>'id')::uuid);
  perform pg_temp.keep('d7_r3', (lifeos.expense_refund_create(jsonb_build_object('refund_of', p, 'refund_amount', 5, 'transaction_date', '2031-06-04', 'line_type', 'item'))->>'id')::uuid);
  perform pg_temp.keep('d7_p2', (pg_temp.purchase(pm, null, null, '2031-06-01', 40, 'QA D7 Shop Two')->>'id')::uuid);
  p3 := pg_temp.keep('d7_p3', (pg_temp.purchase(pm, null, null, '2031-06-01', 60, 'QA D7 Shop Three')->>'id')::uuid);
  perform pg_temp.keep('d7_r4', (lifeos.expense_refund_create(jsonb_build_object('refund_of', p3, 'refund_amount', 6, 'transaction_date', '2031-06-02', 'line_type', 'adjustment'))->>'id')::uuid);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-1 (Refund alone): deleting a Refund deletes only it and returns no Refund ids.
do $t$
declare t constant text := 'qa_d7_1_refund_alone_delete_returns_no_refund_ids';
  d jsonb;
begin
  d := lifeos.expense_delete(pg_temp.id('d7_r3'), 'QA-D7 refund alone');
  perform pg_temp.chk(d->>'deleted_at' is not null, 'the Refund delete returns deleted_at');
  perform pg_temp.chk(d->'deleted_refund_ids' = '[]'::jsonb, format('deleted_refund_ids is [], got %s', coalesce(d->>'deleted_refund_ids', '<missing>')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-2 (Refund alone): the purchase stays active and lists its two other Refunds.
do $t$
declare t constant text := 'qa_d7_2_purchase_stays_active_after_refund_delete';
  r jsonb;
begin
  r := lifeos.expense_read(pg_temp.id('d7_p'));
  perform pg_temp.chk(r->>'deleted_at' is null, 'the purchase is active');
  perform pg_temp.chk(pg_temp.ids_of(r->'refunds') = array[pg_temp.id('d7_r2')::text, pg_temp.id('d7_r1')::text],
                      format('refunds are [R2, R1] by transaction_date, got %s', pg_temp.ids_of(r->'refunds')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-3 (D7.1, J-0008 3.1 item 4): deleting the purchase returns its deleted Refunds in refunds order.
do $t$
declare t constant text := 'qa_d7_3_purchase_delete_returns_refund_ids_in_refunds_order';
  d jsonb;
begin
  d := lifeos.expense_delete(pg_temp.id('d7_p'), 'QA-D7 purchase deleted');
  perform pg_temp.chk(d->>'deleted_at' is not null, 'the purchase delete returns deleted_at');
  perform pg_temp.chk(pg_temp.txt_arr(d->'deleted_refund_ids') = array[pg_temp.id('d7_r2')::text, pg_temp.id('d7_r1')::text],
                      format('deleted_refund_ids is [R2, R1], got %s', pg_temp.txt_arr(d->'deleted_refund_ids')));
  perform pg_temp.put('d7_p_deleted_at', d->>'deleted_at');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-4 (D7.1): R1 carries the deleted_at of the purchase.
do $t$
declare t constant text := 'qa_d7_4_refund_r1_gets_purchase_deleted_at';
  r jsonb; p jsonb;
begin
  r := lifeos.expense_read(pg_temp.id('d7_r1'));
  p := lifeos.expense_read(pg_temp.id('d7_p'));
  perform pg_temp.chk(r->>'deleted_at' is not null and r->>'deleted_at' = p->>'deleted_at', 'R1 deleted_at equals the purchase deleted_at');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-5 (D7.1): R2 carries the deleted_at of the purchase.
do $t$
declare t constant text := 'qa_d7_5_refund_r2_gets_purchase_deleted_at';
  r jsonb; p jsonb;
begin
  r := lifeos.expense_read(pg_temp.id('d7_r2'));
  p := lifeos.expense_read(pg_temp.id('d7_p'));
  perform pg_temp.chk(r->>'deleted_at' is not null and r->>'deleted_at' = p->>'deleted_at', 'R2 deleted_at equals the purchase deleted_at');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-6 (D7.1, own history): R1 gets one history version with the purchase reason.
do $t$
declare t constant text := 'qa_d7_6_refund_r1_own_history_version';
  h jsonb;
begin
  h := lifeos.expense_history(pg_temp.id('d7_r1'))->'history';
  perform pg_temp.chk(jsonb_array_length(h) = 2, format('2 versions, got %s', jsonb_array_length(h)));
  perform pg_temp.chk(h-> -1->>'correction_reason' = 'QA-D7 purchase deleted', format('reason is the purchase reason, got %s', h-> -1->>'correction_reason'));
  perform pg_temp.chk(h-> -1->>'corrected_at' is not null, 'corrected_at set');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-7 (D7.1, own history): R2 gets one history version with the purchase reason.
do $t$
declare t constant text := 'qa_d7_7_refund_r2_own_history_version';
  h jsonb;
begin
  h := lifeos.expense_history(pg_temp.id('d7_r2'))->'history';
  perform pg_temp.chk(jsonb_array_length(h) = 2, format('2 versions, got %s', jsonb_array_length(h)));
  perform pg_temp.chk(h-> -1->>'correction_reason' = 'QA-D7 purchase deleted', format('reason is the purchase reason, got %s', h-> -1->>'correction_reason'));
  perform pg_temp.chk(h-> -1->>'corrected_at' is not null, 'corrected_at set');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-8 (D7.1): the purchase gets one history version with its reason.
do $t$
declare t constant text := 'qa_d7_8_purchase_history_version';
  h jsonb;
begin
  h := lifeos.expense_history(pg_temp.id('d7_p'))->'history';
  perform pg_temp.chk(jsonb_array_length(h) = 2, format('2 versions, got %s', jsonb_array_length(h)));
  perform pg_temp.chk(h-> -1->>'correction_reason' = 'QA-D7 purchase deleted', format('reason is the purchase reason, got %s', h-> -1->>'correction_reason'));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-9: the Refund deleted earlier is left alone: no new version, its own reason kept.
do $t$
declare t constant text := 'qa_d7_9_already_deleted_refund_untouched';
  h jsonb;
begin
  h := lifeos.expense_history(pg_temp.id('d7_r3'))->'history';
  perform pg_temp.chk(jsonb_array_length(h) = 2, format('still 2 versions, got %s', jsonb_array_length(h)));
  perform pg_temp.chk(h-> -1->>'correction_reason' = 'QA-D7 refund alone', format('own reason kept, got %s', h-> -1->>'correction_reason'));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-10 (Contract financial-records.md 6.7 item 2): deleting the deleted purchase again changes nothing.
do $t$
declare t constant text := 'qa_d7_10_second_purchase_delete_changes_nothing';
  d jsonb; h jsonb;
begin
  d := lifeos.expense_delete(pg_temp.id('d7_p'), 'QA-D7 second delete');
  perform pg_temp.chk(d->>'deleted_at' = pg_temp.val('d7_p_deleted_at'), 'the existing deleted_at is returned');
  perform pg_temp.chk(d->'deleted_refund_ids' = '[]'::jsonb, format('deleted_refund_ids is [], got %s', coalesce(d->>'deleted_refund_ids', '<missing>')));
  h := lifeos.expense_history(pg_temp.id('d7_p'))->'history';
  perform pg_temp.chk(jsonb_array_length(h) = 2 and h-> -1->>'correction_reason' = 'QA-D7 purchase deleted', 'no new history version');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-11 (return shape): a purchase without Refunds returns deleted_refund_ids [].
do $t$
declare t constant text := 'qa_d7_11_purchase_without_refunds_returns_no_refund_ids';
  d jsonb;
begin
  d := lifeos.expense_delete(pg_temp.id('d7_p2'), 'QA-D7 no refunds');
  perform pg_temp.chk(d->'deleted_refund_ids' = '[]'::jsonb, format('deleted_refund_ids is [], got %s', coalesce(d->>'deleted_refund_ids', '<missing>')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D7-12 (Refund alone): after its only Refund is deleted, the purchase stays active with refunds [].
do $t$
declare t constant text := 'qa_d7_12_refund_alone_delete_keeps_purchase_active';
  r jsonb;
begin
  perform lifeos.expense_delete(pg_temp.id('d7_r4'), 'QA-D7 refund of P3 alone');
  r := lifeos.expense_read(pg_temp.id('d7_p3'));
  perform pg_temp.chk(r->>'deleted_at' is null, 'P3 is active');
  perform pg_temp.chk(r->'refunds' = '[]'::jsonb, format('refunds is [], got %s', coalesce(r->>'refunds', '<missing>')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- =============================================================================
-- M-0021 D8: a Storyline end date is never before its start date
-- =============================================================================
do $t$
declare t constant text := 'qa_d8_setup';
begin
  perform pg_temp.keep('d8_u', (lifeos.storyline_create('{"title":"QA D8 Storyline U","content":"QA D8 u","occurrence_date":"2031-04-10","occurrence_end_date":"2031-04-20"}')->>'id')::uuid);
  perform pg_temp.keep('d8_v', (lifeos.storyline_create('{"title":"QA D8 Storyline V","content":"QA D8 v","occurrence_date":"2031-04-10","occurrence_end_date":"2031-04-20"}')->>'id')::uuid);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-1 (D8.1, D8.2)
do $t$
declare t constant text := 'qa_d8_1_create_end_before_start_rejected';
begin
  perform pg_temp.expect_err($$select lifeos.storyline_create('{"content":"QA D8 1","occurrence_date":"2031-03-10","occurrence_end_date":"2031-03-09"}')$$, 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-2 (D8.1, same day allowed)
do $t$
declare t constant text := 'qa_d8_2_create_same_day_accepted';
  s jsonb;
begin
  s := lifeos.storyline_create('{"content":"QA D8 2","occurrence_date":"2031-03-10","occurrence_end_date":"2031-03-10"}');
  perform pg_temp.chk(s->>'occurrence_date' = '2031-03-10' and s->>'occurrence_end_date' = '2031-03-10', 'same-day Storyline created');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-3 (D8.1)
do $t$
declare t constant text := 'qa_d8_3_create_end_after_start_accepted';
  s jsonb;
begin
  s := lifeos.storyline_create('{"content":"QA D8 3","occurrence_date":"2031-03-10","occurrence_end_date":"2031-03-12"}');
  perform pg_temp.chk(s->>'occurrence_date' = '2031-03-10' and s->>'occurrence_end_date' = '2031-03-12', 'Storyline created with both dates');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-4: the rule applies only when both dates are present.
do $t$
declare t constant text := 'qa_d8_4_create_end_date_only_accepted';
  s jsonb;
begin
  s := lifeos.storyline_create('{"content":"QA D8 4","occurrence_end_date":"2031-03-12"}');
  perform pg_temp.chk(s->>'occurrence_date' is null and s->>'occurrence_end_date' = '2031-03-12', 'Storyline created with the end date only');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-5 (Contract divination-reflection.md 7.5.4 item 1): an omitted start keeps its stored value for the check.
do $t$
declare t constant text := 'qa_d8_5_update_end_before_stored_start_rejected';
begin
  perform pg_temp.expect_err(format('select lifeos.storyline_update(%s, %L::jsonb)', pg_temp.q(pg_temp.id('d8_u')), '{"occurrence_end_date":"2031-04-05"}'), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-6 (Contract divination-reflection.md 7.5.4 item 1): an omitted end keeps its stored value for the check.
do $t$
declare t constant text := 'qa_d8_6_update_start_after_stored_end_rejected';
begin
  perform pg_temp.expect_err(format('select lifeos.storyline_update(%s, %L::jsonb)', pg_temp.q(pg_temp.id('d8_u')), '{"occurrence_date":"2031-04-21"}'), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-7 (D8.2): the rejected updates changed nothing.
do $t$
declare t constant text := 'qa_d8_7_rejected_update_leaves_dates_unchanged';
  s jsonb;
begin
  s := lifeos.storyline_read(pg_temp.id('d8_u'));
  perform pg_temp.chk(s->>'occurrence_date' = '2031-04-10' and s->>'occurrence_end_date' = '2031-04-20',
                      format('dates stay 2031-04-10..2031-04-20, got %s..%s', s->>'occurrence_date', s->>'occurrence_end_date'));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-8: moving the start onto the stored end date is allowed.
do $t$
declare t constant text := 'qa_d8_8_update_start_to_stored_end_same_day_accepted';
  s jsonb;
begin
  s := lifeos.storyline_update(pg_temp.id('d8_u'), '{"occurrence_date":"2031-04-20"}');
  perform pg_temp.chk(s->>'occurrence_date' = '2031-04-20' and s->>'occurrence_end_date' = '2031-04-20', 'dates are 2031-04-20..2031-04-20');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-9: moving the end onto the stored start date is allowed.
do $t$
declare t constant text := 'qa_d8_9_update_end_to_stored_start_same_day_accepted';
  s jsonb;
begin
  s := lifeos.storyline_update(pg_temp.id('d8_v'), '{"occurrence_end_date":"2031-04-10"}');
  perform pg_temp.chk(s->>'occurrence_date' = '2031-04-10' and s->>'occurrence_end_date' = '2031-04-10', 'dates are 2031-04-10..2031-04-10');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-10 (D8.2): both dates supplied with the end before the start.
do $t$
declare t constant text := 'qa_d8_10_update_both_dates_end_before_start_rejected';
begin
  perform pg_temp.expect_err(format('select lifeos.storyline_update(%s, %L::jsonb)', pg_temp.q(pg_temp.id('d8_u')),
                             '{"occurrence_date":"2031-05-25","occurrence_end_date":"2031-05-20"}'), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-11 (D8.1): both dates supplied in order.
do $t$
declare t constant text := 'qa_d8_11_update_both_dates_valid_accepted';
  s jsonb;
begin
  s := lifeos.storyline_update(pg_temp.id('d8_u'), '{"occurrence_date":"2031-05-20","occurrence_end_date":"2031-05-25"}');
  perform pg_temp.chk(s->>'occurrence_date' = '2031-05-20' and s->>'occurrence_end_date' = '2031-05-25', 'dates are 2031-05-20..2031-05-25');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D8-12: an update without a date change is accepted.
do $t$
declare t constant text := 'qa_d8_12_update_without_date_change_accepted';
  s jsonb;
begin
  s := lifeos.storyline_update(pg_temp.id('d8_u'), '{"title":"QA D8 Storyline U renamed"}');
  perform pg_temp.chk(s->>'title' = 'QA D8 Storyline U renamed', 'title updated');
  perform pg_temp.chk(s->>'occurrence_date' = '2031-05-20' and s->>'occurrence_end_date' = '2031-05-25', 'dates unchanged');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- =============================================================================
-- M-0021 D9: Event delete and its Schedule
-- =============================================================================
do $t$
declare t constant text := 'qa_d9_setup';
  s2 uuid;
begin
  perform pg_temp.keep('d9_s1', (lifeos.schedule_create('{"title":"QA D9 Schedule One","planned_date":"2031-07-01"}')->>'id')::uuid);
  s2 := pg_temp.keep('d9_s2', (lifeos.schedule_create('{"title":"QA D9 Schedule Two","planned_date":"2031-07-02"}')->>'id')::uuid);
  perform pg_temp.keep('d9_e2', (lifeos.event_create(jsonb_build_object('schedule_id', s2, 'occurred_date', '2031-07-02'))->>'id')::uuid);
  perform pg_temp.keep('d9_e3', (lifeos.event_create('{"title":"QA D9 Event Three","occurred_date":"2031-07-03"}')->>'id')::uuid);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-0 (setup assertion): an Event with schedule_id sets the Schedule to occurred.
do $t$
declare t constant text := 'qa_d9_0_event_create_sets_schedule_occurred';
  e jsonb; s jsonb;
begin
  e := lifeos.event_create(jsonb_build_object('schedule_id', pg_temp.id('d9_s1'), 'occurred_date', '2031-07-01'));
  perform pg_temp.keep('d9_e1', (e->>'id')::uuid);
  s := lifeos.schedule_read(pg_temp.id('d9_s1'));
  perform pg_temp.chk(s->>'status' = 'occurred', format('S1 is occurred, got %s', s->>'status'));
  perform pg_temp.chk(s->>'linked_event_id' = e->>'id', 'S1 linked_event_id is E1');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-1 (D9.1): deleting the Event returns its active Schedule to planned.
do $t$
declare t constant text := 'qa_d9_1_event_delete_returns_active_schedule_to_planned';
  d jsonb;
begin
  d := lifeos.event_delete(pg_temp.id('d9_e1'));
  perform pg_temp.chk(d->>'schedule_returned_to_planned' = pg_temp.id('d9_s1')::text,
                      format('schedule_returned_to_planned is S1, got %s', coalesce(d->>'schedule_returned_to_planned', '<null>')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-2 (D9.1)
do $t$
declare t constant text := 'qa_d9_2_returned_schedule_is_planned_without_event';
  s jsonb;
begin
  s := lifeos.schedule_read(pg_temp.id('d9_s1'));
  perform pg_temp.chk(s->>'status' = 'planned', format('S1 is planned, got %s', s->>'status'));
  perform pg_temp.chk(s ? 'linked_event_id' and s->>'linked_event_id' is null, 'S1 linked_event_id is null');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-3 (D9.1): the stored schedule_id of E1 is cleared. Reads lifeos.events.
do $t$
declare t constant text := 'qa_d9_3_stored_event_schedule_id_cleared';
  v uuid; found_row boolean;
begin
  select true, schedule_id into found_row, v from lifeos.events where id = pg_temp.id('d9_e1');
  perform pg_temp.chk(found_row, 'E1 row exists');
  perform pg_temp.chk(v is null, format('stored events.schedule_id is null, got %s', v));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-4 (D9.2): deleting the Event of a deleted Schedule returns no Schedule and raises no error.
do $t$
declare t constant text := 'qa_d9_4_deleted_schedule_keeps_status';
  d jsonb;
begin
  perform lifeos.schedule_delete(pg_temp.id('d9_s2'));
  d := lifeos.event_delete(pg_temp.id('d9_e2'));
  perform pg_temp.chk(d->>'deleted_at' is not null, 'the Event delete succeeds');
  perform pg_temp.chk(d ? 'schedule_returned_to_planned' and d->>'schedule_returned_to_planned' is null,
                      format('schedule_returned_to_planned is null, got %s', coalesce(d->>'schedule_returned_to_planned', '<null or missing>')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-5 (D9.2): the deleted Schedule reads occurred and deleted.
do $t$
declare t constant text := 'qa_d9_5_deleted_schedule_reads_occurred_and_deleted';
  s jsonb;
begin
  s := lifeos.schedule_read(pg_temp.id('d9_s2'));
  perform pg_temp.chk(s->>'status' = 'occurred', format('S2 keeps occurred, got %s', s->>'status'));
  perform pg_temp.chk(s->>'deleted_at' is not null, 'S2 is deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-6 (D9.2): the stored status of the deleted Schedule is occurred. Reads lifeos.schedules.
do $t$
declare t constant text := 'qa_d9_6_stored_status_of_deleted_schedule_is_occurred';
  v text;
begin
  select status into v from lifeos.schedules where id = pg_temp.id('d9_s2');
  perform pg_temp.chk(v = 'occurred', format('stored schedules.status is occurred, got %s', coalesce(v, '<null>')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-7 (Contract personal-records.md 4.2.6 item 2): the stored schedule_id of E2 is cleared. Reads lifeos.events.
do $t$
declare t constant text := 'qa_d9_7_stored_event_schedule_id_cleared_for_deleted_schedule';
  v uuid; found_row boolean;
begin
  select true, schedule_id into found_row, v from lifeos.events where id = pg_temp.id('d9_e2');
  perform pg_temp.chk(found_row, 'E2 row exists');
  perform pg_temp.chk(v is null, format('stored events.schedule_id is null, got %s', v));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D9-8 (control): an Event without a Schedule returns null.
do $t$
declare t constant text := 'qa_d9_8_event_without_schedule_returns_null';
  d jsonb;
begin
  d := lifeos.event_delete(pg_temp.id('d9_e3'));
  perform pg_temp.chk(d ? 'schedule_returned_to_planned' and d->>'schedule_returned_to_planned' is null, 'schedule_returned_to_planned is null');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- =============================================================================
-- M-0021 D10: a p_filter ID of a deleted Record matches nothing, other filters work
-- Period 2031-08-01 to 2031-08-31. Each setup runs the same filter with the active
-- ID before the delete and keeps the count; each "deleted target" test checks it.
-- =============================================================================

-- Event: Schedule SC with linked Event EV, then SC deleted.
do $t$
declare t constant text := 'qa_d10_event_setup';
  sc uuid;
begin
  sc := pg_temp.keep('d10_sc', (lifeos.schedule_create('{"title":"QA D10 Schedule","planned_date":"2031-08-10"}')->>'id')::uuid);
  perform pg_temp.keep('d10_ev', (lifeos.event_create(jsonb_build_object('schedule_id', sc, 'occurred_date', '2031-08-10', 'title', 'qad10evt Event'))->>'id')::uuid);
  perform pg_temp.put('pre_event_schedule', pg_temp.nres(lifeos.event_search(jsonb_build_object('schedule_id', sc)))::text);
  perform lifeos.schedule_delete(sc);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-1 (D10.2)
do $t$
declare t constant text := 'qa_d10_1_event_search_deleted_schedule_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_event_schedule') = '1', format('before the delete the filter matched 1, got %s', pg_temp.val('pre_event_schedule')));
  n := pg_temp.nres(lifeos.event_search(jsonb_build_object('schedule_id', pg_temp.id('d10_sc'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-2 (D10.2, include_deleted)
do $t$
declare t constant text := 'qa_d10_2_event_search_deleted_schedule_include_deleted_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.event_search(jsonb_build_object('schedule_id', pg_temp.id('d10_sc'), 'include_deleted', true)));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-3 (D10.2, with dates)
do $t$
declare t constant text := 'qa_d10_3_event_search_deleted_schedule_with_dates_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.event_search(jsonb_build_object('schedule_id', pg_temp.id('d10_sc'), 'from_date', '2031-08-01', 'to_date', '2031-08-31')));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-4 (D10.3): the Event stays findable by other filters.
do $t$
declare t constant text := 'qa_d10_4_event_search_other_filters_find_event';
  s jsonb;
begin
  s := lifeos.event_search('{"from_date":"2031-08-01","to_date":"2031-08-31","keyword":"qad10evt"}');
  perform pg_temp.chk(pg_temp.nres(s) = 1 and s->'results'->0->>'id' = pg_temp.id('d10_ev')::text, format('the Event is found, got %s results', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Observation: Subject SO and Event EO with two Observations, then SO and EO deleted.
do $t$
declare t constant text := 'qa_d10_observation_setup';
  so uuid; eo uuid;
begin
  so := pg_temp.keep('d10_so', (lifeos.subject_create('{"name":"QA D10 Observed"}')->>'id')::uuid);
  eo := pg_temp.keep('d10_eo', (lifeos.event_create('{"title":"QA D10 Observation Event","occurred_date":"2031-08-11"}')->>'id')::uuid);
  perform lifeos.observation_create(jsonb_build_object('subject_id', so, 'event_id', eo, 'observation_name', 'qad10 metric', 'value_numeric', 1, 'observed_date', '2031-08-11'));
  perform lifeos.observation_create(jsonb_build_object('subject_id', so, 'event_id', eo, 'observation_name', 'qad10 metric', 'value_numeric', 2, 'observed_date', '2031-08-11'));
  perform pg_temp.put('pre_obs_subject', pg_temp.nres(lifeos.observation_search(jsonb_build_object('subject_id', so)))::text);
  perform pg_temp.put('pre_obs_event', pg_temp.nres(lifeos.observation_search(jsonb_build_object('event_id', eo)))::text);
  perform lifeos.subject_delete(so);
  perform lifeos.event_delete(eo);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-5 (D10.2)
do $t$
declare t constant text := 'qa_d10_5_observation_search_deleted_subject_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_obs_subject') = '2', format('before the delete the filter matched 2, got %s', pg_temp.val('pre_obs_subject')));
  n := pg_temp.nres(lifeos.observation_search(jsonb_build_object('subject_id', pg_temp.id('d10_so'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-6 (D10.2, include_deleted)
do $t$
declare t constant text := 'qa_d10_6_observation_search_deleted_subject_include_deleted_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.observation_search(jsonb_build_object('subject_id', pg_temp.id('d10_so'), 'include_deleted', true)));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-7 (D10.2)
do $t$
declare t constant text := 'qa_d10_7_observation_search_deleted_event_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_obs_event') = '2', format('before the delete the filter matched 2, got %s', pg_temp.val('pre_obs_event')));
  n := pg_temp.nres(lifeos.observation_search(jsonb_build_object('event_id', pg_temp.id('d10_eo'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-8 (D10.2, include_deleted and observation_name)
do $t$
declare t constant text := 'qa_d10_8_observation_search_deleted_event_with_name_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.observation_search(jsonb_build_object('event_id', pg_temp.id('d10_eo'), 'include_deleted', true, 'observation_name', 'qad10 metric')));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-9 (D10.3)
do $t$
declare t constant text := 'qa_d10_9_observation_search_other_filters_find_both';
  n int;
begin
  n := pg_temp.nres(lifeos.observation_search('{"observation_name":"qad10 metric","from_date":"2031-08-01","to_date":"2031-08-31"}'));
  perform pg_temp.chk(n = 2, format('both Observations found, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Expense: EX1 and EX2 with Payment Method PMx, Merchant MEx and Item ITx; Refund RF of EX2.
-- Then EX2 is deleted (RF goes with it) and PMx, MEx and ITx are deleted.
do $t$
declare t constant text := 'qa_d10_expense_setup';
  pm uuid; me uuid; it uuid; ex2 uuid;
begin
  pm := pg_temp.keep('d10_pm', (lifeos.subject_create('{"name":"QA D10 Card","subject_type":"payment method"}')->>'id')::uuid);
  me := pg_temp.keep('d10_me', (lifeos.subject_create('{"name":"QA D10 Merchant","subject_type":"brand"}')->>'id')::uuid);
  it := pg_temp.keep('d10_it', (lifeos.subject_create('{"name":"QA D10 Item","subject_type":"product"}')->>'id')::uuid);
  perform pg_temp.keep('d10_ex1', (pg_temp.purchase(pm, me, it, '2031-08-12', 20, 'QAD10 Shop')->>'id')::uuid);
  ex2 := pg_temp.keep('d10_ex2', (pg_temp.purchase(pm, me, it, '2031-08-12', 30, 'QAD10 Shop')->>'id')::uuid);
  perform pg_temp.keep('d10_rf', (lifeos.expense_refund_create(jsonb_build_object('refund_of', ex2, 'refund_amount', 5, 'transaction_date', '2031-08-13', 'line_type', 'item'))->>'id')::uuid);
  -- EX1, EX2 and RF (a Refund copies Payment Method and Merchant); Items only on EX1 and EX2.
  perform pg_temp.put('pre_exp_pm', pg_temp.nres(lifeos.expense_search(jsonb_build_object('payment_method_subject_id', pm)))::text);
  perform pg_temp.put('pre_exp_me', pg_temp.nres(lifeos.expense_search(jsonb_build_object('merchant_subject_id', me)))::text);
  perform pg_temp.put('pre_exp_it', pg_temp.nres(lifeos.expense_search(jsonb_build_object('item_subject_id', it)))::text);
  perform pg_temp.put('pre_exp_refund_of', pg_temp.nres(lifeos.expense_search(jsonb_build_object('refund_of', ex2)))::text);
  perform lifeos.expense_delete(ex2, 'QA D10 purchase deleted');
  perform lifeos.subject_delete(pm);
  perform lifeos.subject_delete(me);
  perform lifeos.subject_delete(it);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-10 (D10.2)
do $t$
declare t constant text := 'qa_d10_10_expense_search_deleted_payment_method_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_exp_pm') = '3', format('before the delete the filter matched 3, got %s', pg_temp.val('pre_exp_pm')));
  n := pg_temp.nres(lifeos.expense_search(jsonb_build_object('payment_method_subject_id', pg_temp.id('d10_pm'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-11 (D10.2)
do $t$
declare t constant text := 'qa_d10_11_expense_search_deleted_merchant_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_exp_me') = '3', format('before the delete the filter matched 3, got %s', pg_temp.val('pre_exp_me')));
  n := pg_temp.nres(lifeos.expense_search(jsonb_build_object('merchant_subject_id', pg_temp.id('d10_me'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-12 (D10.2)
do $t$
declare t constant text := 'qa_d10_12_expense_search_deleted_item_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_exp_it') = '2', format('before the delete the filter matched 2, got %s', pg_temp.val('pre_exp_it')));
  n := pg_temp.nres(lifeos.expense_search(jsonb_build_object('item_subject_id', pg_temp.id('d10_it'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-13 (D10.2, include_deleted)
do $t$
declare t constant text := 'qa_d10_13_expense_search_deleted_merchant_include_deleted_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.expense_search(jsonb_build_object('merchant_subject_id', pg_temp.id('d10_me'), 'include_deleted', true)));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-14 (D10.2): refund_of a deleted purchase, include_deleted.
do $t$
declare t constant text := 'qa_d10_14_expense_search_refund_of_deleted_purchase_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_exp_refund_of') = '1', format('before the delete the filter matched 1, got %s', pg_temp.val('pre_exp_refund_of')));
  n := pg_temp.nres(lifeos.expense_search(jsonb_build_object('refund_of', pg_temp.id('d10_ex2'), 'include_deleted', true)));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-15 (D10.2, with category and dates)
do $t$
declare t constant text := 'qa_d10_15_expense_search_deleted_item_with_category_and_dates_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.expense_search(jsonb_build_object('item_subject_id', pg_temp.id('d10_it'), 'category', 'food', 'from_date', '2031-08-01', 'to_date', '2031-08-31')));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-16 (D10.3)
do $t$
declare t constant text := 'qa_d10_16_expense_search_other_filters_find_expense';
  s jsonb;
begin
  s := lifeos.expense_search('{"keyword":"QAD10 Shop","from_date":"2031-08-01","to_date":"2031-08-31"}');
  perform pg_temp.chk(pg_temp.nres(s) = 1 and s->'results'->0->>'id' = pg_temp.id('d10_ex1')::text, format('the active Expense is found, got %s results', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-17 (D10.3): the deleted Refund stays findable with include_deleted and dates.
do $t$
declare t constant text := 'qa_d10_17_expense_search_finds_deleted_refund_by_other_filters';
  s jsonb;
begin
  s := lifeos.expense_search('{"expense_type":"refund","include_deleted":true,"from_date":"2031-08-01","to_date":"2031-08-31"}');
  perform pg_temp.chk(pg_temp.nres(s) = 1 and s->'results'->0->>'id' = pg_temp.id('d10_rf')::text, format('the deleted Refund is found, got %s results', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Divination and Story Person: Subject SD; Story Person SPD of SD; Story Person SPE.
-- Reading Ra linked to SD, Reading Rb with SPD, Reading Rc with SPE. Then SD and SPE deleted.
do $t$
declare t constant text := 'qa_d10_divination_setup';
  sd uuid; spd uuid; spe uuid; d jsonb;
begin
  sd := pg_temp.keep('d10_sd', (lifeos.subject_create('{"name":"QA D10 Divination Subject","subject_type":"person"}')->>'id')::uuid);
  spd := pg_temp.keep('d10_spd', (lifeos.story_person_create(jsonb_build_object('name', 'QAD10 Teller', 'subject_id', sd))->>'id')::uuid);
  spe := pg_temp.keep('d10_spe', (lifeos.story_person_create('{"name":"QAD10 Stranger"}')->>'id')::uuid);
  d := lifeos.divination_record_save(jsonb_build_object('title', 'QAD10 Divination', 'session_date', '2031-08-15',
        'readings', jsonb_build_array(
          jsonb_build_object('question', 'QA D10 question a', 'method', 'i_ching', 'result_text', 'QA D10 result a', 'reading_date', '2031-08-15'),
          jsonb_build_object('question', 'QA D10 question b', 'method', 'i_ching', 'result_text', 'QA D10 result b', 'reading_date', '2031-08-15', 'story_person_ids', jsonb_build_array(spd)),
          jsonb_build_object('question', 'QA D10 question c', 'method', 'i_ching', 'result_text', 'QA D10 result c', 'reading_date', '2031-08-15', 'story_person_ids', jsonb_build_array(spe)))));
  perform pg_temp.keep('d10_ra', pg_temp.reading_id(d, 0));
  perform pg_temp.link('reading', pg_temp.id('d10_ra'), 'subject', sd);
  perform pg_temp.put('pre_div_subject', pg_temp.nreadings(lifeos.divination_search(jsonb_build_object('subject_id', sd)))::text);
  perform pg_temp.put('pre_div_story_person', pg_temp.nreadings(lifeos.divination_search(jsonb_build_object('story_person_id', spe)))::text);
  perform pg_temp.put('pre_sp_subject', pg_temp.nres(lifeos.story_person_search(jsonb_build_object('subject_id', sd)))::text);
  perform lifeos.subject_delete(sd);
  perform lifeos.story_person_delete(spe);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-18 (D10.2): record_link and Story Person paths both match nothing.
do $t$
declare t constant text := 'qa_d10_18_divination_search_deleted_subject_matches_nothing';
  s jsonb;
begin
  perform pg_temp.chk(pg_temp.val('pre_div_subject') = '2', format('before the delete the filter matched 2 Readings, got %s', pg_temp.val('pre_div_subject')));
  s := lifeos.divination_search(jsonb_build_object('subject_id', pg_temp.id('d10_sd')));
  perform pg_temp.chk(pg_temp.nres(s) = 0, format('0 results, got %s', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-19 (D10.2, include_deleted)
do $t$
declare t constant text := 'qa_d10_19_divination_search_deleted_subject_include_deleted_matches_nothing';
  s jsonb;
begin
  s := lifeos.divination_search(jsonb_build_object('subject_id', pg_temp.id('d10_sd'), 'include_deleted', true));
  perform pg_temp.chk(pg_temp.nres(s) = 0, format('0 results, got %s', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-20 (D10.2)
do $t$
declare t constant text := 'qa_d10_20_divination_search_deleted_story_person_matches_nothing';
  s jsonb;
begin
  perform pg_temp.chk(pg_temp.val('pre_div_story_person') = '1', format('before the delete the filter matched 1 Reading, got %s', pg_temp.val('pre_div_story_person')));
  s := lifeos.divination_search(jsonb_build_object('story_person_id', pg_temp.id('d10_spe')));
  perform pg_temp.chk(pg_temp.nres(s) = 0, format('0 results, got %s', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-21 (D10.2, with method and dates)
do $t$
declare t constant text := 'qa_d10_21_divination_search_deleted_story_person_with_method_and_dates_matches_nothing';
  s jsonb;
begin
  s := lifeos.divination_search(jsonb_build_object('story_person_id', pg_temp.id('d10_spe'), 'method', 'i_ching', 'from_date', '2031-08-01', 'to_date', '2031-08-31'));
  perform pg_temp.chk(pg_temp.nres(s) = 0, format('0 results, got %s', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-22 (D10.2)
do $t$
declare t constant text := 'qa_d10_22_story_person_search_deleted_subject_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_sp_subject') = '1', format('before the delete the filter matched 1, got %s', pg_temp.val('pre_sp_subject')));
  n := pg_temp.nres(lifeos.story_person_search(jsonb_build_object('subject_id', pg_temp.id('d10_sd'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-23 (D10.2, include_deleted)
do $t$
declare t constant text := 'qa_d10_23_story_person_search_deleted_subject_include_deleted_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.story_person_search(jsonb_build_object('subject_id', pg_temp.id('d10_sd'), 'include_deleted', true)));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-24 (D10.3): the three Readings stay findable by keyword and dates.
do $t$
declare t constant text := 'qa_d10_24_divination_search_other_filters_find_three_readings';
  n int;
begin
  n := pg_temp.nreadings(lifeos.divination_search('{"keyword":"QAD10 Divination","from_date":"2031-08-01","to_date":"2031-08-31"}'));
  perform pg_temp.chk(n = 3, format('3 Readings, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-25 (D10.3): the Story Person of the deleted Subject stays findable by keyword.
do $t$
declare t constant text := 'qa_d10_25_story_person_search_other_filters_find_story_person';
  s jsonb;
begin
  s := lifeos.story_person_search('{"keyword":"QAD10 Teller"}');
  perform pg_temp.chk(pg_temp.nres(s) = 1 and s->'results'->0->>'id' = pg_temp.id('d10_spd')::text, format('the Story Person is found, got %s results', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Storyline: Story Persons SP3 and SP4; SL3 with SP3, SL4 with SP4. Then SP3 deleted.
do $t$
declare t constant text := 'qa_d10_storyline_setup';
  sp3 uuid; sp4 uuid;
begin
  sp3 := pg_temp.keep('d10_sp3', (lifeos.story_person_create('{"name":"QAD10 Narrator three"}')->>'id')::uuid);
  sp4 := pg_temp.keep('d10_sp4', (lifeos.story_person_create('{"name":"QAD10 Narrator four"}')->>'id')::uuid);
  perform pg_temp.keep('d10_sl3', (lifeos.storyline_create(jsonb_build_object('title', 'QAD10 Storyline three', 'content', 'QA D10 story three', 'story_person_ids', jsonb_build_array(sp3)))->>'id')::uuid);
  perform pg_temp.keep('d10_sl4', (lifeos.storyline_create(jsonb_build_object('title', 'QAD10 Storyline four', 'content', 'QA D10 story four', 'story_person_ids', jsonb_build_array(sp4)))->>'id')::uuid);
  perform pg_temp.put('pre_sl_story_person', pg_temp.nres(lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(sp3))))::text);
  perform lifeos.story_person_delete(sp3);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-26 (D10.2)
do $t$
declare t constant text := 'qa_d10_26_storyline_search_deleted_story_person_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_sl_story_person') = '1', format('before the delete the filter matched 1, got %s', pg_temp.val('pre_sl_story_person')));
  n := pg_temp.nres(lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(pg_temp.id('d10_sp3')))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-27 (D10.2, include_deleted)
do $t$
declare t constant text := 'qa_d10_27_storyline_search_deleted_story_person_include_deleted_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(pg_temp.id('d10_sp3')), 'include_deleted', true)));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-28: a deleted and an active Story Person in one call; only the active one matches.
do $t$
declare t constant text := 'qa_d10_28_storyline_search_deleted_and_active_story_person_matches_active_only';
  s jsonb;
begin
  s := lifeos.storyline_search(jsonb_build_object('story_person_ids', jsonb_build_array(pg_temp.id('d10_sp3'), pg_temp.id('d10_sp4')), 'person_match', 'any'));
  perform pg_temp.chk(pg_temp.ids_of(s->'results') = array[pg_temp.id('d10_sl4')::text], format('only SL4, got %s', pg_temp.ids_of(s->'results')));
  perform pg_temp.chk(pg_temp.txt_arr(s->'results'->0->'matched_person_ids') = array[pg_temp.id('d10_sp4')::text],
                      format('matched_person_ids is [SP4], got %s', pg_temp.txt_arr(s->'results'->0->'matched_person_ids')));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-29 (D10.3)
do $t$
declare t constant text := 'qa_d10_29_storyline_search_other_filters_find_storyline';
  s jsonb;
begin
  s := lifeos.storyline_search('{"keyword":"QAD10 Storyline three"}');
  perform pg_temp.chk(pg_temp.nres(s) = 1 and s->'results'->0->>'id' = pg_temp.id('d10_sl3')::text, format('SL3 is found, got %s results', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Communication: Person Subject SC1 with Profile PC and one message. Then PC and SC1 deleted.
do $t$
declare t constant text := 'qa_d10_communication_setup';
  sc1 uuid; pc uuid;
begin
  sc1 := pg_temp.keep('d10_sc1', (lifeos.subject_create('{"name":"QA D10 Person","subject_type":"person"}')->>'id')::uuid);
  pc := pg_temp.keep('d10_pc', (lifeos.communication_profile_create(jsonb_build_object('profile_key', 'qa_m21_d10_profile', 'profile_type', 'person', 'name', 'QAD10 Profile', 'person_subject_id', sc1))->>'id')::uuid);
  perform lifeos.communication_message_finalize(jsonb_build_object('profile_id', pc, 'message_text', 'qad10 message text'));
  perform pg_temp.put('pre_profile_subject', pg_temp.nres(lifeos.communication_profile_search(jsonb_build_object('person_subject_id', sc1)))::text);
  perform pg_temp.put('pre_message_profile', pg_temp.nres(lifeos.communication_message_history_search(jsonb_build_object('profile_id', pc)))::text);
  perform lifeos.communication_profile_delete(pc);
  perform lifeos.subject_delete(sc1);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-30 (D10.2, include_deleted)
do $t$
declare t constant text := 'qa_d10_30_profile_search_deleted_person_subject_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_profile_subject') = '1', format('before the delete the filter matched 1, got %s', pg_temp.val('pre_profile_subject')));
  n := pg_temp.nres(lifeos.communication_profile_search(jsonb_build_object('person_subject_id', pg_temp.id('d10_sc1'), 'include_deleted', true)));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-31 (D10.3)
do $t$
declare t constant text := 'qa_d10_31_profile_search_other_filters_find_profile';
  s jsonb;
begin
  s := lifeos.communication_profile_search('{"keyword":"QAD10 Profile","include_deleted":true}');
  perform pg_temp.chk(pg_temp.nres(s) = 1 and s->'results'->0->>'id' = pg_temp.id('d10_pc')::text, format('the Profile is found, got %s results', pg_temp.nres(s)));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-32 (D10.2)
do $t$
declare t constant text := 'qa_d10_32_message_search_deleted_profile_matches_nothing';
  n int;
begin
  perform pg_temp.chk(pg_temp.val('pre_message_profile') = '1', format('before the delete the filter matched 1, got %s', pg_temp.val('pre_message_profile')));
  n := pg_temp.nres(lifeos.communication_message_history_search(jsonb_build_object('profile_id', pg_temp.id('d10_pc'))));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-33 (D10.2, with keyword)
do $t$
declare t constant text := 'qa_d10_33_message_search_deleted_profile_with_keyword_matches_nothing';
  n int;
begin
  n := pg_temp.nres(lifeos.communication_message_history_search(jsonb_build_object('profile_id', pg_temp.id('d10_pc'), 'keyword', 'qad10 message')));
  perform pg_temp.chk(n = 0, format('0 results, got %s', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- D10-34 (D10.3)
do $t$
declare t constant text := 'qa_d10_34_message_search_other_filters_find_message';
  n int;
begin
  n := pg_temp.nres(lifeos.communication_message_history_search('{"keyword":"qad10 message"}'));
  perform pg_temp.chk(n = 1, format('the message is found, got %s results', n));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- =============================================================================
-- M-0022 D4: record_links_read on a Subject lists each connected Record once.
-- via_list holds every path in the D2 order; via = via_list[0].
-- On a Record, each entry keeps its five fields and has no via_list.
-- =============================================================================
do $t$
declare t constant text := 'qa_m22_d4_setup';
  q uuid; eq uuid; oq uuid; sp uuid; d jsonb;
begin
  q := pg_temp.keep('m22_q', (lifeos.subject_create('{"name":"QA M22 Subject Q","subject_type":"person"}')->>'id')::uuid);
  -- EQ: Payment Method, Merchant and Line Item are Q, plus a Record link: four paths.
  eq := pg_temp.keep('m22_eq', (pg_temp.purchase(q, q, q, '2031-09-02', 15, 'QA M22 Shop')->>'id')::uuid);
  perform pg_temp.link('expense', eq, 'subject', q);
  -- EQ2: Payment Method, Merchant and Line Item are Q, no Record link: three paths.
  perform pg_temp.keep('m22_eq2', (pg_temp.purchase(q, q, q, '2031-09-03', 9, 'QA M22 Shop Two')->>'id')::uuid);
  -- OQ: Observation of Q, plus a Record link: two paths.
  oq := pg_temp.keep('m22_oq', (lifeos.observation_create(jsonb_build_object('subject_id', q, 'observation_name', 'qa m22 mood', 'value_text', 'calm', 'observed_date', '2031-09-02'))->>'id')::uuid);
  perform pg_temp.link('observation', oq, 'subject', q);
  -- OQ2: Observation of Q only: one path.
  perform pg_temp.keep('m22_oq2', (lifeos.observation_create(jsonb_build_object('subject_id', q, 'observation_name', 'qa m22 mood', 'value_text', 'busy', 'observed_date', '2031-09-03'))->>'id')::uuid);
  -- Note linked to Q by a Record link only: one path.
  perform pg_temp.keep('m22_note', (lifeos.note_create('{"note_type":"General","content":"QA M22 note"}')->>'id')::uuid);
  perform pg_temp.link('note', pg_temp.id('m22_note'), 'subject', q);
  -- Reading with a Story Person of Q, plus a Record link.
  sp := pg_temp.keep('m22_sp', (lifeos.story_person_create(jsonb_build_object('name', 'QA M22 Story Person', 'subject_id', q))->>'id')::uuid);
  d := lifeos.divination_record_save(jsonb_build_object('title', 'QA M22 Divination', 'session_date', '2031-09-02',
        'readings', jsonb_build_array(jsonb_build_object('question', 'QA M22 question', 'method', 'tarot',
          'result_text', 'QA M22 result', 'reading_date', '2031-09-02', 'story_person_ids', jsonb_build_array(sp)))));
  perform pg_temp.keep('m22_r', pg_temp.reading_id(d, 0));
  perform pg_temp.link('reading', pg_temp.id('m22_r'), 'subject', q);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- M-0022 D4.1 and D4.3: one Expense reached by four paths is listed once with the full ordered via_list.
do $t$
declare t constant text := 'qa_m22_d4_1_subject_several_paths_one_expense_listed_once';
  l jsonb; e jsonb;
begin
  l := lifeos.record_links_read('subject', pg_temp.id('m22_q'));
  perform pg_temp.chk(l->>'record_type' = 'subject' and l->>'id' = pg_temp.id('m22_q')::text, 'the return names the Subject');
  perform pg_temp.chk(pg_temp.cnt(l->'links', pg_temp.id('m22_eq')) = 1, format('EQ appears once, got %s', pg_temp.cnt(l->'links', pg_temp.id('m22_eq'))));
  e := pg_temp.entry(l->'links', pg_temp.id('m22_eq'));
  perform pg_temp.chk(e->>'record_type' = 'expense', 'the entry is the Expense');
  perform pg_temp.chk(e->'via_list' = '["record_link","payment_method","merchant","line_item"]'::jsonb,
                      format('via_list is [record_link, payment_method, merchant, line_item], got %s', coalesce(e->>'via_list', '<missing>')));
  perform pg_temp.chk(e->>'via' = 'record_link', format('via is record_link, got %s', e->>'via'));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- M-0022 D2 and D4.3: without a Record link, the order starts at payment_method.
do $t$
declare t constant text := 'qa_m22_d4_2_subject_paths_without_record_link_in_order';
  l jsonb; e jsonb;
begin
  l := lifeos.record_links_read('subject', pg_temp.id('m22_q'));
  perform pg_temp.chk(pg_temp.cnt(l->'links', pg_temp.id('m22_eq2')) = 1, format('EQ2 appears once, got %s', pg_temp.cnt(l->'links', pg_temp.id('m22_eq2'))));
  e := pg_temp.entry(l->'links', pg_temp.id('m22_eq2'));
  perform pg_temp.chk(e->'via_list' = '["payment_method","merchant","line_item"]'::jsonb,
                      format('via_list is [payment_method, merchant, line_item], got %s', coalesce(e->>'via_list', '<missing>')));
  perform pg_temp.chk(e->>'via' = 'payment_method', format('via is payment_method, got %s', e->>'via'));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- M-0022 D4.2: a Record reached by one path has a via_list of one.
do $t$
declare t constant text := 'qa_m22_d4_3_record_reached_by_one_path_has_via_list_of_one';
  l jsonb; e jsonb;
begin
  l := lifeos.record_links_read('subject', pg_temp.id('m22_q'));
  e := pg_temp.entry(l->'links', pg_temp.id('m22_oq2'));
  perform pg_temp.chk(pg_temp.cnt(l->'links', pg_temp.id('m22_oq2')) = 1, 'OQ2 appears once');
  perform pg_temp.chk(e->'via_list' = '["observation_subject"]'::jsonb, format('OQ2 via_list is [observation_subject], got %s', coalesce(e->>'via_list', '<missing>')));
  perform pg_temp.chk(e->>'via' = 'observation_subject', 'OQ2 via is observation_subject');
  e := pg_temp.entry(l->'links', pg_temp.id('m22_note'));
  perform pg_temp.chk(pg_temp.cnt(l->'links', pg_temp.id('m22_note')) = 1, 'the Note appears once');
  perform pg_temp.chk(e->'via_list' = '["record_link"]'::jsonb, format('Note via_list is [record_link], got %s', coalesce(e->>'via_list', '<missing>')));
  perform pg_temp.chk(e->>'via' = 'record_link', 'Note via is record_link');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- M-0022 D2 and D4.3: an Observation with a Record link and its subject_id lists both, record_link first.
do $t$
declare t constant text := 'qa_m22_d4_4_observation_two_paths_in_order';
  l jsonb; e jsonb;
begin
  l := lifeos.record_links_read('subject', pg_temp.id('m22_q'));
  perform pg_temp.chk(pg_temp.cnt(l->'links', pg_temp.id('m22_oq')) = 1, format('OQ appears once, got %s', pg_temp.cnt(l->'links', pg_temp.id('m22_oq'))));
  e := pg_temp.entry(l->'links', pg_temp.id('m22_oq'));
  perform pg_temp.chk(e->'via_list' = '["record_link","observation_subject"]'::jsonb,
                      format('via_list is [record_link, observation_subject], got %s', coalesce(e->>'via_list', '<missing>')));
  perform pg_temp.chk(e->>'via' = 'record_link', 'via is record_link');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- M-0022 D4.1 to D4.3: every entry on the Subject is listed once, via_list follows the D2 order
-- without repeats, and via equals via_list[0]. Covers the Reading with two paths as well.
do $t$
declare t constant text := 'qa_m22_d4_5_every_subject_entry_once_with_ordered_via_list';
  l jsonb; e jsonb; p text; prev int; r int; n int; nd int;
begin
  l := lifeos.record_links_read('subject', pg_temp.id('m22_q'));
  select count(*), count(distinct (x->>'record_type') || ':' || (x->>'id')) into n, nd from jsonb_array_elements(coalesce(l->'links', '[]'::jsonb)) x;
  perform pg_temp.chk(n = nd, format('each Record once: %s entries, %s distinct', n, nd));
  perform pg_temp.chk(pg_temp.cnt(l->'links', pg_temp.id('m22_r')) = 1, format('the Reading appears once, got %s', pg_temp.cnt(l->'links', pg_temp.id('m22_r'))));
  for e in select x from jsonb_array_elements(coalesce(l->'links', '[]'::jsonb)) x loop
    perform pg_temp.chk(jsonb_typeof(e->'via_list') = 'array' and jsonb_array_length(e->'via_list') >= 1, format('entry %s has a non-empty via_list', e->>'id'));
    perform pg_temp.chk(e->>'via' = e->'via_list'->>0, format('entry %s via equals via_list[0]', e->>'id'));
    prev := 0;
    for p in select v from jsonb_array_elements_text(e->'via_list') with ordinality y(v, k) order by k loop
      r := pg_temp.via_rank(p);
      perform pg_temp.chk(r is not null and r > prev, format('entry %s via_list %s follows the D2 order without repeats', e->>'id', e->>'via_list'));
      prev := r;
    end loop;
  end loop;
  perform pg_temp.chk(pg_temp.entry(l->'links', pg_temp.id('m22_r'))->>'via' = 'record_link', 'the Reading via is record_link');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- M-0022 feed D4: on a Record, each entry keeps its five fields and has no via_list.
do $t$
declare t constant text := 'qa_m22_d4_6_record_side_entries_have_no_via_list';
  five constant text[] := array['id','occurrence_date','record_type','summary','via'];
  arr jsonb; e jsonb; k text[];
begin
  foreach arr in array array[
      lifeos.record_links_read('expense', pg_temp.id('m22_eq'))->'links',
      lifeos.record_links_read('observation', pg_temp.id('m22_oq'))->'links',
      lifeos.expense_read(pg_temp.id('m22_eq'))->'links'] loop
    perform pg_temp.chk(jsonb_array_length(coalesce(arr, '[]'::jsonb)) >= 1, 'the Record has at least one link');
    for e in select x from jsonb_array_elements(arr) x loop
      perform pg_temp.chk(not (e ? 'via_list'), format('entry %s has no via_list', e->>'id'));
      select array_agg(j order by j) into k from jsonb_object_keys(e) j;
      perform pg_temp.chk(k = five, format('entry %s has exactly the five fields, got %s', e->>'id', k));
    end loop;
  end loop;
  -- The Expense lists Q once, via record_link (M-0021 D6 with the D2 order).
  arr := lifeos.record_links_read('expense', pg_temp.id('m22_eq'))->'links';
  perform pg_temp.chk(pg_temp.cnt(arr, pg_temp.id('m22_q')) = 1 and pg_temp.via_of(arr, pg_temp.id('m22_q')) = 'record_link', 'Q appears once on the Expense, via record_link');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
