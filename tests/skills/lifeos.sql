-- =============================================================================
-- tests/skills/lifeos.sql -- Skill flow tests: skills/lifeos/SKILL.md
-- Entry Skill: connection, routing, Subject, Record links, Remarks, Timeline, Subject questions, Memory, Notebook. Contract: shared.md, lifeos-memory.md, notebook.md.
-- Each test follows the database steps of one Skill flow, in the Skill's order, through the Contract
-- functions, and asserts the outcome that the Skill and the Knowledge Base state.
--
-- Tests in this file:
--    1. connect_named_parameter_calls_return_one_jsonb
--    2. user_subject_created_when_missing_then_reused_at_start
--    3. route_reads_memory_then_runs_each_module_and_links
--    4. subject_discovery_candidate_confirmed_then_linked
--    5. subject_discovery_no_match_creates_only_after_user_decides
--    6. subject_discovery_guidance_from_subject_types_and_subject_tags
--    7. subject_maintenance_alias_correction_and_tags
--    8. subject_merge_after_approval_combines_identity_and_moves_references
--    9. subject_merge_two_person_profiles_profile_merge_then_subject_merge
--   10. subject_delete_without_profile_links_kept_and_ignored
--   11. subject_delete_with_profile_after_profile_outcome_both_branches
--   12. record_links_dinner_example_each_item_once_with_via_order
--   13. remarks_add_change_remove_and_structured_update_for_time
--   14. timeline_period_by_occurrence_and_by_record_date
--   15. timeline_data_supports_presentation_steps
--   16. subject_questions_retrieve_across_modules_by_priority
--   17. memory_retrieve_learn_improve_consolidate_and_correct
--   18. notebook_read_reuse_maintain_and_new_key
--   19. notebook_language_modes_and_platforms_reuse_or_add_value
--
-- Test 2 must run before any test that calls pg_temp.user_subject(): it checks the start without a user Subject.
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

-- The user Subject, found as Section 4 "Steps for the user Subject" says (subject_search with is_user true).
-- In this file test 2 creates it first. The create below runs only when no user Subject exists.
create function pg_temp.user_subject() returns uuid language plpgsql as $f$
declare r jsonb := lifeos.subject_search('{"is_user": true}'::jsonb);
begin
  if (r ->> 'returned_count')::integer > 0 then
    return (r -> 'results' -> 0 ->> 'id')::uuid;
  end if;
  return (lifeos.subject_create('{"name": "SKT_User", "subject_type": "person", "is_user": true}'::jsonb) ->> 'id')::uuid;
end $f$;

-- A one-Line purchase Expense (financial-records.md 6.1), for flows that need an Expense as context.
create function pg_temp.mk_expense(p_date date, p_pm uuid, p_total numeric, p_merchant text default null, p_merchant_subject uuid default null)
returns jsonb language sql as
$f$ select lifeos.expense_create(jsonb_build_object('transaction_date', p_date, 'payment_method_subject_id', p_pm,
     'merchant_name', p_merchant, 'merchant_subject_id', p_merchant_subject, 'expense_total', p_total, 'currency', 'MYR',
     'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', coalesce(p_merchant, 'SKT_item'),
       'unit_price', p_total, 'line_total', p_total, 'category', 'food')))) $f$;

-- 1. Section 4 Connect: named-parameter RPC calls in the schema lifeos, one jsonb value each ----------
-- Reading LifeOS Config from Google Drive (steps 1 to 6) is an Agent step. This test covers steps 8 and 9.
do $t$
declare t constant text := 'connect_named_parameter_calls_return_one_jsonb';
  a jsonb; b jsonb; c jsonb;
begin
  a := lifeos.notebook_read(p_key => 'defaults');
  b := lifeos.subject_search(p_filter => '{"limit": 1}'::jsonb);
  c := lifeos.expense_category_list();
  perform pg_temp.chk(jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' and jsonb_typeof(c) = 'object', 'every call returns one jsonb object');
  perform pg_temp.chk(a ->> 'key' = 'defaults' and b ? 'results' and c ? 'categories', 'the calls reach the Contract functions');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Section 4 Steps for the user Subject: missing at the first start, then found at a later start ---------
-- Before a run the project holds no Subject (only the notebooks defaults and note_types), so step 1 finds none.
do $t$
declare t constant text := 'user_subject_created_when_missing_then_reused_at_start';
  s jsonb; u jsonb; s2 jsonb;
begin
  -- step 1: find the user Subject
  s := lifeos.subject_search('{"is_user": true}'::jsonb);
  perform pg_temp.chk((s ->> 'returned_count')::integer = 0, 'missing: no active Subject has is_user true, got ' || s::text);
  -- step 3: the Agent asks the user's name, unless it is already known (Agent step)
  -- step 4: create the user Subject with the name and is_user true; it needs no separate approval
  u := lifeos.subject_create('{"name": "SKT_L2 User", "subject_type": "person", "is_user": true}'::jsonb);
  perform pg_temp.chk((u ->> 'is_user')::boolean and u ->> 'name' = 'SKT_L2 User' and u ->> 'deleted_at' is null, 'the user Subject is created with is_user true');
  -- a later start: step 1 finds it, and step 2 uses it in every flow
  s2 := lifeos.subject_search('{"is_user": true}'::jsonb);
  perform pg_temp.chk((s2 ->> 'returned_count')::integer = 1 and s2 -> 'results' -> 0 ->> 'id' = u ->> 'id', 'exists: the search finds the created user Subject, got ' || s2::text);
  perform pg_temp.chk(pg_temp.user_subject() = (u ->> 'id')::uuid, 'later flows find the same user Subject');
  -- Contract guard (shared.md 5.1), not a Skill step: a second user Subject is rejected, so step 2 reuses the found one
  perform pg_temp.expect_err($$select lifeos.subject_create('{"name": "SKT_L2 User again", "subject_type": "person", "is_user": true}'::jsonb)$$, 'invalid input');
  perform pg_temp.chk((lifeos.subject_search('{"is_user": true}'::jsonb) ->> 'returned_count')::integer = 1, 'still exactly one user Subject');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Section 5 Route: Memory first, then each Module's flow, then the link --------------------------
do $t$
declare t constant text := 'route_reads_memory_then_runs_each_module_and_links';
  m jsonb; s jsonb; pm uuid := pg_temp.mk_subject('SKT_L3 Card', 'payment method'); e jsonb; x jsonb; tl jsonb; ie jsonb; ix jsonb;
begin
  -- step 1: an earlier saved direction is found for the request
  m := lifeos.memory_create(jsonb_build_object('title', 'SKT_L3 routing', 'content', 'SKT_L3 "makan with someone" is a dinner Event plus an Expense',
         'categories', jsonb_build_array('Processing Conventions'), 'tags', jsonb_build_array('skt-l3')));
  s := lifeos.memory_search('{"keyword": "SKT_L3"}'::jsonb);
  perform pg_temp.chk((s ->> 'returned_count')::integer = 1 and s -> 'results' -> 0 ->> 'id' = m ->> 'id', 'memory_search returns the routing Memory');
  -- step 5: one statement touches Personal Records and Financial Records
  e := lifeos.event_create('{"title": "SKT_L3 makan", "occurred_date": "2032-01-05", "occurred_time": "19:30"}'::jsonb);
  x := pg_temp.mk_expense('2032-01-05', pm, 25, 'SKT_L3 Warung');
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'expense', 'to_id', x ->> 'id'));
  tl := lifeos.timeline('{"from_date": "2032-01-05", "to_date": "2032-01-05"}'::jsonb);
  ie := pg_temp.find(tl -> 'items', (e ->> 'id')::uuid);
  ix := pg_temp.find(tl -> 'items', (x ->> 'id')::uuid);
  perform pg_temp.chk(ie ->> 'module' = 'personal_records' and ie ->> 'record_type' = 'event', 'the Event keeps Personal Records ownership');
  perform pg_temp.chk(ix ->> 'module' = 'financial_records' and ix ->> 'record_type' = 'expense', 'the Expense keeps Financial Records ownership');
  perform pg_temp.chk(pg_temp.cnt(ie -> 'links', (x ->> 'id')::uuid) = 1, 'the Event links to the Expense');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Section 6 Subject Discovery: candidates, evidence, confirmation, then the link -----------------
do $t$
declare t constant text := 'subject_discovery_candidate_confirmed_then_linked';
  u uuid; nb jsonb; s1 uuid; s2 uuid; earlier_rec jsonb; ck jsonb; sr jsonb; rd jsonb; rec jsonb; e jsonb; lk jsonb;
begin
  -- step 6: the user Subject is found by is_user and needs no confirmation
  u := pg_temp.user_subject();
  perform pg_temp.chk((lifeos.subject_read(u) ->> 'is_user')::boolean, 'the user Subject is found with is_user true');
  -- step 3: read the catalog Notebooks subject_types and subject_tags with notebook_read.
  -- notebook.md 3.1 items 2 to 4: a first read creates the Notebook with its catalog name and empty content
  -- and returns initialised true. On a project where the Notebook already exists, check the key and name only.
  nb := lifeos.notebook_read('subject_types');
  perform pg_temp.chk(nb ->> 'key' = 'subject_types' and nb ->> 'name' = 'Subject Types'
                      and (not (nb ->> 'initialised')::boolean or coalesce(nb ->> 'content', '') = ''),
                      'read of subject_types: catalog name, and empty content when just initialised, got ' || nb::text);
  nb := lifeos.notebook_read('subject_tags');
  perform pg_temp.chk(nb ->> 'key' = 'subject_tags' and nb ->> 'name' = 'Subject Tags'
                      and (not (nb ->> 'initialised')::boolean or coalesce(nb ->> 'content', '') = ''),
                      'read of subject_tags: catalog name, and empty content when just initialised, got ' || nb::text);
  perform pg_temp.chk(not (lifeos.notebook_read('subject_types') ->> 'initialised')::boolean, 'a later read reuses the Notebook');
  -- two Subjects share one name; one has an earlier shared Event
  s1 := (lifeos.subject_create('{"name": "SKT_L4 Nicholas", "subject_type": "person", "description": "SKT_L4 colleague, lives in Bangsar"}'::jsonb) ->> 'id')::uuid;
  s2 := (lifeos.subject_create('{"name": "SKT_L4 Nicholas", "subject_type": "person", "description": "SKT_L4 cousin in Ipoh"}'::jsonb) ->> 'id')::uuid;
  earlier_rec := lifeos.event_create('{"title": "SKT_L4 team dinner", "occurred_date": "2032-01-20"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', earlier_rec ->> 'id', 'to_type', 'subject', 'to_id', s1));
  -- step 4: Existence Check and compact Search give candidates only
  ck := lifeos.subject_check('SKT_L4 Nicholas');
  perform pg_temp.chk((ck ->> 'exists')::boolean and jsonb_array_length(ck -> 'matches') = 2, 'a single name gives two candidates, so the name alone is no evidence');
  perform pg_temp.chk((select bool_and(m ->> 'matched_on' = 'name') from jsonb_array_elements(ck -> 'matches') m), 'matches are on name');
  sr := lifeos.subject_search('{"keyword": "Bangsar"}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(sr -> 'results', s1) = 1 and pg_temp.cnt(sr -> 'results', s2) = 0, 'a differentiating clue narrows the candidates');
  rd := lifeos.subject_read(s1);
  perform pg_temp.chk(rd ->> 'description' like '%Bangsar%', 'the exact Read gives the identity information');
  -- step 10: the proposal describes the candidate through its shared Records
  rec := lifeos.subject_records(s1, '{}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(rec -> 'results', (earlier_rec ->> 'id')::uuid) = 1, 'subject_records gives the shared Event for the proposal');
  -- the user confirms s1: the new Record links to it
  e := lifeos.event_create('{"title": "SKT_L4 lunch with Nicholas", "occurred_date": "2032-01-27"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', s1));
  lk := lifeos.record_links_read('event', (e ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lk -> 'links', s1) = 1 and pg_temp.cnt(lk -> 'links', s2) = 0, 'the Record links to the confirmed Subject only');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Section 6 steps 12 and 13: no match; creation only after the user decides (both branches) -------
do $t$
declare t constant text := 'subject_discovery_no_match_creates_only_after_user_decides';
  e1 jsonb; e2 jsonb; s jsonb; lk jsonb;
begin
  perform pg_temp.chk(not (lifeos.subject_check('SKT_L5 Aunt Mei') ->> 'exists')::boolean, 'no Subject matches');
  -- branch: the user declines a continuing Subject; the Record proceeds without a Subject link
  e1 := lifeos.event_create('{"title": "SKT_L5 visited Aunt Mei", "occurred_date": "2032-01-28"}'::jsonb);
  lk := lifeos.record_links_read('event', (e1 ->> 'id')::uuid);
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lk -> 'links') l where l ->> 'record_type' = 'subject'), 'declined: no Subject link');
  -- branch: the user wants the Subject; it is created, then linked
  s := lifeos.subject_create('{"name": "SKT_L5 Aunt Mei", "subject_type": "person", "description": "SKT_L5 mother''s sister in Klang"}'::jsonb);
  perform pg_temp.chk(s ->> 'is_user' = 'false' and s -> 'aliases' = '[]'::jsonb, 'Subject created with defaults');
  e2 := lifeos.event_create('{"title": "SKT_L5 visited Aunt Mei again", "occurred_date": "2032-01-29"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e2 ->> 'id', 'to_type', 'subject', 'to_id', s ->> 'id'));
  perform pg_temp.chk((lifeos.subject_check('SKT_L5 Aunt Mei') ->> 'exists')::boolean, 'approved: the Subject exists');
  perform pg_temp.chk(pg_temp.cnt(lifeos.record_links_read('event', (e2 ->> 'id')::uuid) -> 'links', (s ->> 'id')::uuid) = 1, 'approved: the Record links to the new Subject');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Section 6 step 3: the Subject Discovery Guidance is the content of subject_types and subject_tags ------
-- The Agent keeps the guidance in both Notebooks (Section 16, no approval). Discovery reads both keys and
-- uses their content: the entity category and the contextual clue narrow two same-name candidates.
do $t$
declare t constant text := 'subject_discovery_guidance_from_subject_types_and_subject_tags';
  ty jsonb; tg jsonb; g_type text; g_tag text; pet uuid; per uuid; ck jsonb; sr jsonb; e jsonb; lk jsonb;
begin
  -- earlier Notebook maintenance (Section 16 step 5): the guidance entries, written as the full new content
  ty := lifeos.notebook_read('subject_types');
  perform lifeos.notebook_update('subject_types', jsonb_build_object('content',
          concat_ws(E'\n', nullif(ty ->> 'content', ''), 'skt_l6_pet: an animal of the household; search hint: the pet''s name')));
  tg := lifeos.notebook_read('subject_tags');
  perform lifeos.notebook_update('subject_tags', jsonb_build_object('content',
          concat_ws(E'\n', nullif(tg ->> 'content', ''), 'skt-l6-cat: a cat; contextual clue: vet visits, cat food, litter')));
  pet := (lifeos.subject_create('{"name": "SKT_L6 Milo", "subject_type": "skt_l6_pet", "tags": ["skt-l6-cat"], "description": "SKT_L6 grey cat"}'::jsonb) ->> 'id')::uuid;
  per := (lifeos.subject_create('{"name": "SKT_L6 Milo", "subject_type": "person", "description": "SKT_L6 neighbour''s son"}'::jsonb) ->> 'id')::uuid;
  -- the statement: "I took Milo to the vet"
  -- step 3: read both guidance keys with notebook_read; the guidance is their stored content
  ty := lifeos.notebook_read('subject_types');
  tg := lifeos.notebook_read('subject_tags');
  perform pg_temp.chk(not (ty ->> 'initialised')::boolean and not (tg ->> 'initialised')::boolean, 'both guidance Notebooks are reused, not initialised');
  g_type := substring(ty ->> 'content' from '(skt_l6_pet):');
  g_tag := substring(tg ->> 'content' from '(skt-l6-cat): [a-z ;]*contextual clue: vet');
  perform pg_temp.chk(g_type = 'skt_l6_pet' and g_tag = 'skt-l6-cat', 'the guidance gives the category and the vet clue, got ' || coalesce(g_type, '<none>') || ' / ' || coalesce(g_tag, '<none>'));
  -- step 4: the name alone gives two candidates
  ck := lifeos.subject_check('SKT_L6 Milo');
  perform pg_temp.chk(jsonb_array_length(ck -> 'matches') = 2, 'two candidates share the name');
  -- steps 4 and 7: search with the guidance category and Tag; name plus the vet clue are two pieces of evidence
  sr := lifeos.subject_search(jsonb_build_object('keyword', 'SKT_L6 Milo', 'subject_type', g_type, 'tags', jsonb_build_array(g_tag)));
  perform pg_temp.chk((sr ->> 'returned_count')::integer = 1 and sr -> 'results' -> 0 ->> 'id' = pet::text, 'the guidance narrows the candidates to the pet, got ' || sr::text);
  -- step 8: link directly
  e := lifeos.event_create('{"title": "SKT_L6 vet visit with Milo", "occurred_date": "2032-02-12"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', pet));
  lk := lifeos.record_links_read('event', (e ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lk -> 'links', pet) = 1 and pg_temp.cnt(lk -> 'links', per) = 0, 'the Event links to the pet Subject only');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Section 7 Subject maintenance: Alias, correction, own Type and Tags ----------------------------
do $t$
declare t constant text := 'subject_maintenance_alias_correction_and_tags';
  s uuid; a jsonb; ck jsonb; u jsonb;
begin
  s := (lifeos.subject_create('{"name": "SKT_L7 Ah Beng", "subject_type": "person", "tags": ["friend"]}'::jsonb) ->> 'id')::uuid;
  -- steps 1 and 4: a clear or a confirmed Alias
  a := lifeos.subject_add_alias(s, 'SKT_L7 Beng');
  perform pg_temp.chk(pg_temp.has_text(a -> 'aliases', 'SKT_L7 Beng'), 'Alias added');
  a := lifeos.subject_add_alias(s, 'skt_l7 beng');
  perform pg_temp.chk(jsonb_array_length(a -> 'aliases') = 1, 'the same Alias in another case is not added twice');
  ck := lifeos.subject_check('SKT_L7 Beng');
  perform pg_temp.chk(ck -> 'matches' -> 0 ->> 'id' = s::text and ck -> 'matches' -> 0 ->> 'matched_on' = 'alias', 'the Alias finds the Subject');
  -- step 2: an evidence-supported correction
  u := lifeos.subject_update(s, '{"description": "SKT_L7 moved to Penang"}'::jsonb);
  perform pg_temp.chk(u ->> 'description' = 'SKT_L7 moved to Penang' and u ->> 'name' = 'SKT_L7 Ah Beng', 'correction applied, other fields unchanged');
  -- step 5: the Subject's own Tags from the subject_tags Notebook
  perform pg_temp.chk(lifeos.notebook_read('subject_tags') ->> 'key' = 'subject_tags', 'subject_tags Notebook read');
  u := lifeos.subject_update(s, '{"tags": ["friend", "skt-l7-penang"]}'::jsonb);
  perform pg_temp.chk(u -> 'tags' = '["friend", "skt-l7-penang"]'::jsonb, 'Tags replaced as a whole array');
  perform pg_temp.chk(pg_temp.cnt(lifeos.subject_search('{"tags": ["skt-l7-penang"]}'::jsonb) -> 'results', s) = 1, 'the Subject is searchable by its Tag');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Section 8 Duplicate merge after explicit approval: steps 1 and 3, then steps 5 and 6 (no Person Profiles) --
do $t$
declare t constant text := 'subject_merge_after_approval_combines_identity_and_moves_references';
  k uuid; d uuid; e jsonb; o jsonb; r jsonb; dm jsonb;
begin
  k := (lifeos.subject_create('{"name": "SKT_L8 Siew Ling", "subject_type": "person", "description": "SKT_L8 sister"}'::jsonb) ->> 'id')::uuid;
  d := (lifeos.subject_create('{"name": "SKT_L8 Ling", "subject_type": "person", "aliases": ["SKT_L8 SL"]}'::jsonb) ->> 'id')::uuid;
  e := lifeos.event_create('{"title": "SKT_L8 birthday dinner", "occurred_date": "2032-06-02"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', d));
  o := lifeos.observation_create(jsonb_build_object('subject_id', d, 'observation_name', 'SKT_L8 height', 'value_numeric', 160, 'unit', 'cm', 'observed_date', '2032-06-02'));
  -- step 1: read both; step 2 (approval) is an Agent step
  perform pg_temp.chk(lifeos.subject_read(k) ->> 'name' = 'SKT_L8 Siew Ling' and lifeos.subject_read(d) ->> 'name' = 'SKT_L8 Ling', 'both Subjects read');
  -- step 3: neither Subject has a Person Profile, so step 4 does not apply
  perform pg_temp.chk(lifeos.subject_read(k) ->> 'person_profile_id' is null and lifeos.subject_read(d) ->> 'person_profile_id' is null, 'no Person Profile on either Subject');
  -- steps 5 and 6: combine the identity, then merge
  r := lifeos.subject_merge(jsonb_build_object('keep_id', k, 'merge_id', d, 'identity', jsonb_build_object(
         'name', 'SKT_L8 Siew Ling', 'aliases', jsonb_build_array('SKT_L8 Ling', 'SKT_L8 SL'), 'description', 'SKT_L8 sister, also called Ling')));
  perform pg_temp.chk(r -> 'subject' ->> 'id' = k::text and r ->> 'merged_id' = d::text, 'kept and merged IDs returned');
  perform pg_temp.chk(r -> 'subject' -> 'aliases' = '["SKT_L8 Ling", "SKT_L8 SL"]'::jsonb and r -> 'subject' ->> 'description' = 'SKT_L8 sister, also called Ling', 'the kept Subject takes the combined identity');
  perform pg_temp.chk((r -> 'moved_references' ->> 'record_link')::integer = 1 and (r -> 'moved_references' ->> 'observation_subject')::integer = 1, 'references moved, got ' || (r -> 'moved_references')::text);
  dm := lifeos.subject_read(d);
  perform pg_temp.chk(dm ->> 'merged_into_id' = k::text and dm ->> 'deleted_at' is not null, 'the merged Subject points to the kept one and is deleted');
  -- source Records stay unchanged apart from their Subject reference
  perform pg_temp.chk(lifeos.event_read((e ->> 'id')::uuid) ->> 'title' = 'SKT_L8 birthday dinner', 'Event content unchanged');
  perform pg_temp.chk(pg_temp.cnt(lifeos.record_links_read('event', (e ->> 'id')::uuid) -> 'links', k) = 1, 'the Event now links to the kept Subject');
  perform pg_temp.chk(lifeos.observation_read((o ->> 'id')::uuid) ->> 'subject_id' = k::text and (lifeos.observation_read((o ->> 'id')::uuid) ->> 'value_numeric')::numeric = 160, 'the Observation moved to the kept Subject, value unchanged');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Section 8 steps 3 to 6: both Subjects have a Person Profile; the two Profiles merge, then the Subjects ---
-- Step 4 hands the two Profiles to the communication-assistant Skill Section 5 "Steps for two Person Profiles of
-- one person". That flow, with a Rule conflict, memberships and aliases, is tested in full in
-- communication-assistant.sql. This test takes the case without a Rule conflict and checks the hand-over order.
do $t$
declare t constant text := 'subject_merge_two_person_profiles_profile_merge_then_subject_merge';
  a uuid := pg_temp.mk_subject('SKT_L9 Kumar', 'person'); b uuid := pg_temp.mk_subject('SKT_L9 Kumar R', 'person');
  pa uuid; pb uuid; ra jsonb; rb jsonb; ma jsonb; mb jsonb; rdb jsonb; mg jsonb; r jsonb; st jsonb; rec jsonb;
begin
  pa := ((lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-l9-kumar', 'profile_type', 'person', 'name', 'SKT_L9 Kumar', 'person_subject_id', a))) ->> 'id')::uuid;
  pb := ((lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-l9-kumar-r', 'profile_type', 'person', 'name', 'SKT_L9 Kumar R', 'person_subject_id', b))) ->> 'id')::uuid;
  ra := lifeos.communication_rule_upsert(jsonb_build_object('profile_id', pa, 'dimension', 'skt_l9_tone', 'rule_key', 'greeting', 'rule_text', 'SKT_L9 start with Hi Kumar'));
  rb := lifeos.communication_rule_upsert(jsonb_build_object('profile_id', pb, 'dimension', 'skt_l9_style', 'rule_key', 'length', 'rule_text', 'SKT_L9 short lines'));
  ma := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pa, 'message_text', 'SKT_L9 Hi Kumar, see you at 7'));
  mb := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pb, 'message_text', 'SKT_L9 Noted, thanks'));
  -- step 1: read both; step 2 (approval) is an Agent step
  perform pg_temp.chk(lifeos.subject_read(a) ->> 'name' = 'SKT_L9 Kumar' and lifeos.subject_read(b) ->> 'name' = 'SKT_L9 Kumar R', 'both Subjects read');
  -- step 3: subject_read shows a Person Profile on both Subjects
  perform pg_temp.chk(lifeos.subject_read(a) ->> 'person_profile_id' = pa::text and lifeos.subject_read(b) ->> 'person_profile_id' = pb::text, 'both Subjects have a Person Profile');
  -- Contract guard (shared.md 5.7 item 4), not a Skill step: the Subject merge waits for the Profile merge
  perform pg_temp.expect_err(format('select lifeos.subject_merge(%L::jsonb)', jsonb_build_object('keep_id', a, 'merge_id', b, 'identity', jsonb_build_object('name', 'SKT_L9 Kumar'))), 'invalid relationship');
  -- step 4, in the communication-assistant flow: read both Profiles with their own Rules and recent messages
  rdb := lifeos.communication_profile_read(pb);
  perform lifeos.notebook_read('language_modes');
  st := lifeos.communication_rule_state(pb, null);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st -> 'rules') x where x ->> 'id' = rb ->> 'id' and x ->> 'scope' = 'profile'), 'the merged Profile shows its own Rule');
  perform pg_temp.chk(pg_temp.cnt(lifeos.communication_message_history_search(jsonb_build_object('profile_id', pb)) -> 'results', (mb -> 'message' ->> 'id')::uuid) = 1, 'the merged Profile shows its recent message');
  -- the user keeps Kumar's Profile (Agent step); no Rule conflict exists; the identity details stay on the kept Profile
  perform lifeos.communication_profile_update(pa, jsonb_build_object('aliases', jsonb_build_array(rdb ->> 'name')));
  mg := lifeos.communication_profile_merge(jsonb_build_object('keep_id', pa, 'merge_id', pb));
  perform pg_temp.chk(mg -> 'profile' ->> 'id' = pa::text and mg ->> 'merged_id' = pb::text and mg ->> 'deleted_at' is not null, 'the Profile merge keeps pa and deletes pb');
  perform pg_temp.chk((mg -> 'moved' ->> 'rules')::integer = 1 and (mg -> 'moved' ->> 'messages')::integer = 1, 'one Rule and one message moved, got ' || (mg -> 'moved')::text);
  perform pg_temp.chk(lifeos.subject_read(b) ->> 'person_profile_id' is null, 'the merged Subject has no active Person Profile any more');
  -- steps 5 and 6: combine the identity, then merge the Subjects
  r := lifeos.subject_merge(jsonb_build_object('keep_id', a, 'merge_id', b, 'identity', jsonb_build_object('name', 'SKT_L9 Kumar', 'aliases', jsonb_build_array('SKT_L9 Kumar R'))));
  perform pg_temp.chk(r -> 'subject' ->> 'person_profile_id' = pa::text and r -> 'subject' -> 'aliases' = '["SKT_L9 Kumar R"]'::jsonb, 'the kept Subject keeps its Person Profile and takes the combined identity');
  perform pg_temp.chk(lifeos.subject_read(b) ->> 'merged_into_id' = a::text, 'the Subject merge is done');
  -- outcome: the kept Profile holds the Rules and Message History of both
  st := lifeos.communication_rule_state(pa, null);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st -> 'rules') x where x ->> 'id' = ra ->> 'id' and x ->> 'scope' = 'profile')
                      and exists (select 1 from jsonb_array_elements(st -> 'rules') x where x ->> 'id' = rb ->> 'id' and x ->> 'scope' = 'profile'), 'both Rules are the kept Profile''s own Rules');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pa)) ->> 'returned_count')::integer = 2, 'both messages are in the kept Profile''s Message History');
  rec := lifeos.subject_records(a, '{}'::jsonb);
  perform pg_temp.chk(pg_temp.find(rec -> 'results', (mb -> 'message' ->> 'id')::uuid) ->> 'via' = 'person_profile_subject', 'the kept Subject reaches the moved message through its Person Profile');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Section 9 Subject deletion without a Person Profile -----------------------------------------
do $t$
declare t constant text := 'subject_delete_without_profile_links_kept_and_ignored';
  s uuid := pg_temp.mk_subject('SKT_L10 old car WXY1234', 'vehicle'); e jsonb; d jsonb;
begin
  e := lifeos.event_create('{"title": "SKT_L10 car service", "occurred_date": "2032-07-01"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', s));
  -- step 2: no Person Profile
  perform pg_temp.chk(lifeos.subject_read(s) ->> 'person_profile_id' is null, 'the Subject has no Person Profile');
  d := lifeos.subject_delete(s);
  perform pg_temp.chk(d ->> 'id' = s::text and d ->> 'deleted_at' is not null, 'Subject deleted');
  perform pg_temp.chk(pg_temp.cnt(lifeos.record_links_read('event', (e ->> 'id')::uuid) -> 'links', s) = 0, 'the Event ignores its link to the deleted Subject');
  perform pg_temp.chk(lifeos.event_read((e ->> 'id')::uuid) ->> 'deleted_at' is null, 'the Event stays active');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Section 9 Subject deletion with a Person Profile: both Profile outcomes first ---------------------
do $t$
declare t constant text := 'subject_delete_with_profile_after_profile_outcome_both_branches';
  s1 uuid := pg_temp.mk_subject('SKT_L11 Wei', 'person'); s2 uuid := pg_temp.mk_subject('SKT_L11 Wei Jie', 'person'); s3 uuid := pg_temp.mk_subject('SKT_L11 Old boss', 'person');
  p1 jsonb; p3 jsonb;
begin
  p1 := lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-l11-wei', 'profile_type', 'person', 'name', 'SKT_L11 Wei', 'person_subject_id', s1));
  p3 := lifeos.communication_profile_create(jsonb_build_object('profile_key', 'skt-l11-boss', 'profile_type', 'person', 'name', 'SKT_L11 Old boss', 'person_subject_id', s3));
  -- step 2: subject_read shows the Person Profile, so the user decides its outcome first
  perform pg_temp.chk(lifeos.subject_read(s1) ->> 'person_profile_id' = p1 ->> 'id', 'subject_read shows the Person Profile');
  perform pg_temp.expect_err(format('select lifeos.subject_delete(%s)', pg_temp.q(s1)), 'invalid relationship');
  -- branch: the Profile belongs to another person
  perform lifeos.communication_profile_update((p1 ->> 'id')::uuid, jsonb_build_object('person_subject_id', s2));
  perform pg_temp.chk(lifeos.subject_delete(s1) ->> 'deleted_at' is not null, 'relinked: the Subject is deleted');
  perform pg_temp.chk(lifeos.communication_profile_read((p1 ->> 'id')::uuid) ->> 'person_subject_id' = s2::text, 'relinked: the Profile keeps its correct Subject');
  -- branch: the user no longer wants the Profile
  perform lifeos.communication_profile_delete((p3 ->> 'id')::uuid);
  perform pg_temp.chk(lifeos.subject_delete(s3) ->> 'deleted_at' is not null, 'Profile deleted: the Subject is deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Section 10 Record links: the dinner example, list-once rule, via order, correction ------------
do $t$
declare t constant text := 'record_links_dinner_example_each_item_once_with_via_order';
  n uuid := pg_temp.mk_subject('SKT_L12 Nicholas', 'person'); pm uuid := pg_temp.mk_subject('SKT_L12 Card', 'payment method');
  mer uuid := pg_temp.mk_subject('SKT_L12 Kopitiam', 'brand'); wrong uuid := pg_temp.mk_subject('SKT_L12 Nick Lee', 'person');
  e jsonb; x jsonb; l1 jsonb; l2 jsonb; lx jsonb; ls jsonb; lm jsonb; d jsonb; ent jsonb;
begin
  e := lifeos.event_create('{"title": "SKT_L12 dinner with Nicholas", "occurred_date": "2032-01-12"}'::jsonb);
  x := pg_temp.mk_expense('2032-01-12', pm, 80, 'SKT_L12 Kopitiam', mer);
  -- steps 1 and 2: the Records link to each other and to the shared Subject
  l1 := lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'expense', 'to_id', x ->> 'id'));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', n));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'expense', 'from_id', x ->> 'id', 'to_type', 'subject', 'to_id', n));
  -- a clear link the user states: the Expense to its Merchant Subject, which is also its typed field
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'expense', 'from_id', x ->> 'id', 'to_type', 'subject', 'to_id', mer));
  l2 := lifeos.record_link_create(jsonb_build_object('from_type', 'expense', 'from_id', x ->> 'id', 'to_type', 'event', 'to_id', e ->> 'id'));
  perform pg_temp.chk(l2 ->> 'link_id' = l1 ->> 'link_id', 'a repeated pair returns the existing link');
  -- step 7 and the listing rule on a Record: each Subject once
  lx := lifeos.record_links_read('expense', (x ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lx -> 'links', n) = 1 and pg_temp.cnt(lx -> 'links', (e ->> 'id')::uuid) = 1, 'the Expense lists Nicholas and the Event once each');
  perform pg_temp.chk(pg_temp.cnt(lx -> 'links', mer) = 1 and pg_temp.find(lx -> 'links', mer) ->> 'via' = 'record_link', 'the Merchant appears once, via the first path record_link');
  perform pg_temp.chk(pg_temp.find(lx -> 'links', pm) ->> 'via' = 'payment_method', 'the Payment Method comes through its typed field');
  -- listing rule on a Subject: each Record once, every path in via_list
  lm := lifeos.record_links_read('subject', mer);
  ent := pg_temp.find(lm -> 'links', (x ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lm -> 'links', (x ->> 'id')::uuid) = 1, 'the Merchant lists the Expense once');
  perform pg_temp.chk(ent -> 'via_list' = '["record_link", "merchant"]'::jsonb and ent ->> 'via' = 'record_link', 'via_list keeps every path in order, via is the first, got ' || coalesce(ent::text, '<none>'));
  ls := lifeos.record_links_read('subject', n);
  perform pg_temp.chk(pg_temp.cnt(ls -> 'links', (e ->> 'id')::uuid) = 1 and pg_temp.cnt(ls -> 'links', (x ->> 'id')::uuid) = 1, 'Nicholas lists the dinner Event and the Expense once each');
  -- step 6: a link the user corrects as wrong is removed
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', wrong));
  d := lifeos.record_link_delete(jsonb_build_object('from_type', 'subject', 'from_id', wrong, 'to_type', 'event', 'to_id', e ->> 'id'));
  perform pg_temp.chk((d ->> 'removed')::boolean, 'the wrong link is removed in either direction');
  perform pg_temp.chk(pg_temp.cnt(lifeos.record_links_read('event', (e ->> 'id')::uuid) -> 'links', wrong) = 0, 'the Event no longer lists the wrong Subject');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 13. Section 11 Remarks: add, change, remove; a structured change uses the update function ---------
do $t$
declare t constant text := 'remarks_add_change_remove_and_structured_update_for_time';
  s jsonb; r jsonb; rid text; ts text; n jsonb; nr jsonb; nu jsonb; before_upd text;
begin
  s := lifeos.schedule_create('{"title": "SKT_L13 zoo visit", "planned_date": "2032-01-30", "planned_time": "10:00"}'::jsonb);
  -- step 1: retrieve the prior Record
  perform pg_temp.chk((lifeos.schedule_search('{"keyword": "SKT_L13 zoo"}'::jsonb) ->> 'returned_count')::integer = 1, 'the prior Schedule is found');
  before_upd := s ->> 'updated_at';
  -- step 3: a small detail is a Remark
  r := lifeos.record_add_remark('schedule', (s ->> 'id')::uuid, '  Bring the camera  ');
  rid := r -> 'remarks' -> 0 ->> 'remark_id'; ts := r -> 'remarks' -> 0 ->> 'timestamp';
  perform pg_temp.chk(jsonb_array_length(r -> 'remarks') = 1 and r -> 'remarks' -> 0 ->> 'text' = 'Bring the camera' and rid is not null, 'Remark appended with a remark_id and trimmed text');
  perform pg_temp.chk(r ->> 'updated_at' = before_upd and r ->> 'planned_time' = '10:00:00', 'a Remark leaves updated_at and the structured fields unchanged');
  -- step 4: a Remark change replaces its whole content
  r := lifeos.record_update_remark('schedule', (s ->> 'id')::uuid, rid::uuid, 'Bring the camera and a tripod');
  perform pg_temp.chk(r -> 'remarks' -> 0 ->> 'text' = 'Bring the camera and a tripod' and r -> 'remarks' -> 0 ->> 'remark_id' = rid and r -> 'remarks' -> 0 ->> 'timestamp' = ts, 'Remark text replaced, id and timestamp kept');
  -- step 6: a changed visit time is a structured update of the Schedule
  r := lifeos.schedule_update((s ->> 'id')::uuid, '{"planned_time": "14:00"}'::jsonb);
  perform pg_temp.chk(r ->> 'planned_time' = '14:00:00' and jsonb_array_length(r -> 'remarks') = 1, 'planned time updated, Remark kept');
  -- step 5: remove one Remark
  r := lifeos.record_delete_remark('schedule', (s ->> 'id')::uuid, rid::uuid);
  perform pg_temp.chk(r -> 'remarks' = '[]'::jsonb, 'Remark removed');
  -- a Remark on a Note leaves the Note date; an edit moves it (edited_at)
  n := lifeos.note_create('{"note_type": "Idea", "content": "SKT_L13 zoo photo book"}'::jsonb);
  nr := lifeos.record_add_remark('note', (n ->> 'id')::uuid, 'SKT_L13 ask about prints');
  perform pg_temp.chk(nr ->> 'edited_at' is null and nr ->> 'note_date' = pg_temp.today()::text, 'a Remark is not an edit of the Note');
  nu := lifeos.note_update((n ->> 'id')::uuid, '{"content": "SKT_L13 zoo photo book, 20 pages"}'::jsonb);
  perform pg_temp.chk(nu ->> 'edited_at' is not null, 'an edit sets edited_at, unlike a Remark');
  perform pg_temp.chk((lifeos.schedule_search('{"keyword": "SKT_L13 zoo"}'::jsonb) ->> 'returned_count')::integer = 1, 'no duplicate Schedule exists');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 14. Section 12 Timeline: the period, past or future, occurrence date or record date ----------------
do $t$
declare t constant text := 'timeline_period_by_occurrence_and_by_record_date';
  u uuid := pg_temp.user_subject(); pm uuid := pg_temp.mk_subject('SKT_L14 Card', 'payment method');
  s jsonb; e jsonb; x jsonb; o jsonb; outside jsonb; tl jsonb; tr jsonb;
begin
  s := lifeos.schedule_create('{"title": "SKT_L14 dentist", "planned_date": "2032-02-03", "planned_time": "09:00"}'::jsonb);
  e := lifeos.event_create('{"title": "SKT_L14 badminton", "occurred_date": "2032-02-04"}'::jsonb);
  x := pg_temp.mk_expense('2032-02-05', pm, 12.50, 'SKT_L14 Mamak');
  o := lifeos.observation_create(jsonb_build_object('subject_id', u, 'observation_name', 'SKT_L14 weight', 'value_numeric', 70.5, 'unit', 'kg', 'observed_date', '2032-02-06'));
  outside := lifeos.event_create('{"title": "SKT_L14 outside the week", "occurred_date": "2032-02-10"}'::jsonb);
  -- step 3: the week, by occurrence date (default)
  tl := lifeos.timeline('{"from_date": "2032-02-02", "to_date": "2032-02-08"}'::jsonb);
  perform pg_temp.chk(tl ->> 'date_basis' = 'occurrence', 'date_basis defaults to occurrence');
  perform pg_temp.chk(pg_temp.cnt(tl -> 'items', (s ->> 'id')::uuid) = 1 and pg_temp.cnt(tl -> 'items', (e ->> 'id')::uuid) = 1
                      and pg_temp.cnt(tl -> 'items', (x ->> 'id')::uuid) = 1 and pg_temp.cnt(tl -> 'items', (o ->> 'id')::uuid) = 1, 'the week holds the Schedule, Event, Expense and Observation');
  perform pg_temp.chk(pg_temp.cnt(tl -> 'items', (outside ->> 'id')::uuid) = 0, 'a Record outside the period is left out');
  perform pg_temp.chk(pg_temp.pos(tl -> 'items', (s ->> 'id')::uuid) < pg_temp.pos(tl -> 'items', (e ->> 'id')::uuid)
                      and pg_temp.pos(tl -> 'items', (e ->> 'id')::uuid) < pg_temp.pos(tl -> 'items', (x ->> 'id')::uuid), 'items follow the occurrence date');
  -- Choices: what the user recorded today uses the record date
  tr := lifeos.timeline(jsonb_build_object('from_date', pg_temp.today(), 'to_date', pg_temp.today(), 'date_basis', 'record'));
  perform pg_temp.chk(tr ->> 'date_basis' = 'record' and pg_temp.cnt(tr -> 'items', (s ->> 'id')::uuid) = 1 and pg_temp.cnt(tr -> 'items', (outside ->> 'id')::uuid) = 1, 'the record-date view lists what was recorded today');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 15. Section 13 Timeline presentation: the data each presentation step relies on --------------------
do $t$
declare t constant text := 'timeline_data_supports_presentation_steps';
  u uuid := pg_temp.user_subject(); pm uuid := pg_temp.mk_subject('SKT_L15 Card', 'payment method');
  sa jsonb; ev jsonb; ob jsonb; dateonly jsonb; plan jsonb; miss jsonb; canc jsonb; ser jsonb; x jsonb; rf jsonb; past jsonb; dv jsonb; rd jsonb; la jsonb; msg jsonb;
  tl jsonb; it jsonb; tt jsonb;
begin
  sa := lifeos.schedule_create('{"title": "SKT_L15 clinic", "planned_date": "2032-03-02", "planned_time": "08:00"}'::jsonb);
  ev := lifeos.event_create(jsonb_build_object('schedule_id', sa ->> 'id', 'occurred_date', '2032-03-02', 'occurred_time', '08:20'));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', ev ->> 'id', 'to_type', 'subject', 'to_id', u));
  ob := lifeos.observation_create(jsonb_build_object('subject_id', u, 'observation_name', 'SKT_L15 blood pressure', 'value_text', '120/80',
          'observed_date', '2032-03-02', 'observed_time', '08:30', 'event_id', ev ->> 'id'));
  dateonly := lifeos.event_create('{"title": "SKT_L15 pharmacy, time unknown", "occurred_date": "2032-03-02"}'::jsonb);
  plan := lifeos.schedule_create('{"title": "SKT_L15 review", "planned_date": "2032-03-05"}'::jsonb);
  miss := lifeos.schedule_update(((lifeos.schedule_create('{"title": "SKT_L15 gym", "planned_date": "2032-03-03"}'::jsonb)) ->> 'id')::uuid, '{"status": "missed"}'::jsonb);
  canc := lifeos.schedule_update(((lifeos.schedule_create('{"title": "SKT_L15 haircut", "planned_date": "2032-03-04"}'::jsonb)) ->> 'id')::uuid, '{"status": "cancelled"}'::jsonb);
  ser := lifeos.schedule_create_series('{"series_description": "SKT_L15 swimming every Saturday in March 2032", "schedules": [
           {"title": "SKT_L15 swimming", "planned_date": "2032-03-06", "planned_time": "07:00"}]}'::jsonb);
  x := pg_temp.mk_expense('2032-03-01', pm, 50, 'SKT_L15 Shop');
  rf := lifeos.expense_refund_create(jsonb_build_object('refund_of', x ->> 'id', 'refund_amount', 20, 'transaction_date', '2032-03-06', 'line_type', 'adjustment'));
  tl := lifeos.timeline('{"from_date": "2032-03-01", "to_date": "2032-03-07"}'::jsonb);
  -- step 2 and 3: known clock times first within a date, date-only entries after them
  perform pg_temp.chk(pg_temp.pos(tl -> 'items', (sa ->> 'id')::uuid) < pg_temp.pos(tl -> 'items', (dateonly ->> 'id')::uuid)
                      and pg_temp.pos(tl -> 'items', (ob ->> 'id')::uuid) < pg_temp.pos(tl -> 'items', (dateonly ->> 'id')::uuid), 'timed entries come before date-only entries of the same date');
  perform pg_temp.chk(pg_temp.find(tl -> 'items', (dateonly ->> 'id')::uuid) ->> 'occurrence_time' is null, 'a date-only entry has no occurrence_time');
  -- step 4: an Occurred Schedule shows its Event
  it := pg_temp.find(tl -> 'items', (sa ->> 'id')::uuid);
  perform pg_temp.chk(it -> 'record' ->> 'status' = 'occurred' and it -> 'record' ->> 'linked_event_id' = ev ->> 'id', 'the Occurred Schedule carries linked_event_id');
  -- step 5: Observations with their Event
  it := pg_temp.find(tl -> 'items', (ev ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(it -> 'record' -> 'observations', (ob ->> 'id')::uuid) = 1, 'the Event item carries its Observation');
  perform pg_temp.chk(pg_temp.find(tl -> 'items', (ob ->> 'id')::uuid) -> 'record' ->> 'event_id' = ev ->> 'id', 'the Observation item names its Event');
  -- steps 6, 8: a plan and plans that did not happen, with their Status
  perform pg_temp.chk(pg_temp.find(tl -> 'items', (plan ->> 'id')::uuid) -> 'record' ->> 'status' = 'planned', 'an upcoming Planned Schedule');
  perform pg_temp.chk(pg_temp.find(tl -> 'items', (miss ->> 'id')::uuid) -> 'record' ->> 'status' = 'missed'
                      and pg_temp.find(tl -> 'items', (canc ->> 'id')::uuid) -> 'record' ->> 'status' = 'cancelled', 'Missed and Cancelled Schedules are included');
  -- step 7: a series item carries its Series description
  perform pg_temp.chk(pg_temp.find(tl -> 'items', (ser -> 'schedules' -> 0 ->> 'id')::uuid) -> 'record' ->> 'series_description' = 'SKT_L15 swimming every Saturday in March 2032', 'the series item carries its description');
  -- step 10: the Expense once on its date, the Refund as a negative amount on its own date
  perform pg_temp.chk(pg_temp.cnt(tl -> 'items', (x ->> 'id')::uuid) = 1 and pg_temp.find(tl -> 'items', (x ->> 'id')::uuid) ->> 'occurrence_date' = '2032-03-01', 'the Expense appears once on its Transaction Date');
  it := pg_temp.find(tl -> 'items', (rf ->> 'id')::uuid);
  perform pg_temp.chk(it ->> 'occurrence_date' = '2032-03-06' and (it -> 'record' ->> 'expense_total')::numeric = -20, 'the Refund is a negative amount on its own date');
  -- step 11: a Reading on its original Reading Date, with a later Analysis under it
  dv := lifeos.divination_record_save('{"session_date": "2032-03-03", "readings": [{"question": "SKT_L15 How will the clinic visit go?", "method": "tarot",
           "result_text": "SKT_L15 The Star (upright)", "analyses": [{"source": "Claude", "overall_outcome": "SKT_L15 calm", "key_reasoning": "SKT_L15 the Star"}]}]}'::jsonb);
  rd := dv -> 'readings' -> 0;
  la := lifeos.analysis_add(jsonb_build_object('reading_id', rd ->> 'id', 'source', 'SKT_L15 friend', 'overall_outcome', 'SKT_L15 later view', 'key_reasoning', 'SKT_L15 r', 'analysis_date', '2032-03-20'));
  tl := lifeos.timeline('{"from_date": "2032-03-01", "to_date": "2032-03-07"}'::jsonb);
  it := pg_temp.find(tl -> 'items', (rd ->> 'id')::uuid);
  perform pg_temp.chk(it ->> 'occurrence_date' = '2032-03-03' and it ->> 'record_type' = 'reading' and pg_temp.cnt(it -> 'record' -> 'analyses', (la ->> 'id')::uuid) = 1, 'the Reading is on its Reading Date and carries the later Analysis');
  perform pg_temp.chk(pg_temp.cnt(lifeos.timeline('{"from_date": "2032-03-20", "to_date": "2032-03-20"}'::jsonb) -> 'items', (la ->> 'id')::uuid) = 0
                      and pg_temp.cnt(lifeos.timeline('{"from_date": "2032-03-20", "to_date": "2032-03-20"}'::jsonb) -> 'items', (rd ->> 'id')::uuid) = 0, 'nothing appears on the later Analysis date');
  -- step 13: Business Type, Module and Subjects on each item
  it := pg_temp.find(tl -> 'items', (ev ->> 'id')::uuid);
  perform pg_temp.chk(it ->> 'record_type' = 'event' and it ->> 'module' = 'personal_records' and pg_temp.cnt(it -> 'subjects', u) = 1, 'the item keeps its type, Module and its Subject once');
  -- step 14: recorded_earlier for a matter recorded today that occurred before the period
  past := lifeos.event_create(jsonb_build_object('title', 'SKT_L15 last week receipt matter', 'occurred_date', pg_temp.today() - 7));
  -- step 12: a Message is on its Message History date. finalized_at is the current time, so this uses today.
  -- That the date alone does not show delivery is an Agent wording step.
  msg := lifeos.communication_message_finalize('{"message_text": "SKT_L15 See you at the clinic", "platform": "whatsapp"}'::jsonb);
  tt := lifeos.timeline(jsonb_build_object('from_date', pg_temp.today(), 'to_date', pg_temp.today()));
  it := pg_temp.find(tt -> 'items', (msg -> 'message' ->> 'id')::uuid);
  perform pg_temp.chk(it ->> 'record_type' = 'communication_message' and it ->> 'module' = 'communication_assistant' and it ->> 'occurrence_date' = pg_temp.today()::text,
                      'the Message is on its Message History date, got ' || coalesce(it::text, '<none>'));
  perform pg_temp.chk(pg_temp.cnt(tt -> 'recorded_earlier', (past ->> 'id')::uuid) = 1 and pg_temp.cnt(tt -> 'items', (past ->> 'id')::uuid) = 0, 'recorded_earlier lists the earlier matter for the closing note');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 16. Section 14 Subject questions: identify, retrieve across Modules, read, filter -----------------
do $t$
declare t constant text := 'subject_questions_retrieve_across_modules_by_priority';
  s uuid := pg_temp.mk_subject('SKT_L16 Nicholas', 'person'); pm uuid := pg_temp.mk_subject('SKT_L16 Card', 'payment method');
  e jsonb; x jsonb; sc jsonb; nt jsonb; rec jsonb; money jsonb; apr jsonb; xr jsonb; m jsonb;
begin
  e := lifeos.event_create('{"title": "SKT_L16 dinner with Nicholas", "occurred_date": "2032-04-10", "location": "SKT_L16 Restoran"}'::jsonb);
  x := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-04-10', 'payment_method_subject_id', pm, 'merchant_name', 'SKT_L16 Restoran',
         'expense_total', 80, 'currency', 'MYR', 'lines', jsonb_build_array(
           jsonb_build_object('line_type', 'item', 'item_description', 'SKT_L16 nasi lemak', 'unit_price', 30, 'line_total', 30, 'category', 'food'),
           jsonb_build_object('line_type', 'item', 'item_description', 'SKT_L16 satay', 'unit_price', 50, 'line_total', 50, 'category', 'food'))));
  sc := lifeos.schedule_create('{"title": "SKT_L16 hiking with Nicholas", "planned_date": "2032-05-20"}'::jsonb);
  nt := lifeos.note_create('{"note_type": "Experience", "content": "SKT_L16 Nicholas taught me to bargain"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'expense', 'from_id', x ->> 'id', 'to_type', 'subject', 'to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'schedule', 'from_id', sc ->> 'id', 'to_type', 'subject', 'to_id', s));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'note', 'from_id', nt ->> 'id', 'to_type', 'subject', 'to_id', s));
  -- step 1
  perform pg_temp.chk((lifeos.subject_check('SKT_L16 Nicholas') -> 'matches' -> 0 ->> 'id') = s::text, 'the Subject is identified');
  -- step 3: every connected Record across Modules, newest occurrence first
  rec := lifeos.subject_records(s, '{}'::jsonb);
  perform pg_temp.chk((rec ->> 'returned_count')::integer = 4, 'four connected Records, got ' || (rec ->> 'returned_count'));
  perform pg_temp.chk(pg_temp.pos(rec -> 'results', (sc ->> 'id')::uuid) < pg_temp.pos(rec -> 'results', (e ->> 'id')::uuid), 'ordered by occurrence date descending');
  -- step 6: a money question gets the amounts; the dinner question leads with amount and dishes
  money := lifeos.subject_records(s, '{"record_types": ["expense"]}'::jsonb);
  perform pg_temp.chk((money ->> 'returned_count')::integer = 1 and (money -> 'results' -> 0 -> 'record' ->> 'expense_total')::numeric = 80, 'the money question gets the Expense amount');
  xr := lifeos.expense_read((x ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(xr -> 'lines') = 2 and xr -> 'lines' -> 1 ->> 'item_description' = 'SKT_L16 satay', 'step 4: the Module read gives the dishes');
  -- a range for a general question (money up to one to three months)
  apr := lifeos.subject_records(s, '{"from_date": "2032-04-01", "to_date": "2032-04-30"}'::jsonb);
  perform pg_temp.chk((apr ->> 'returned_count')::integer = 2 and pg_temp.cnt(apr -> 'results', (sc ->> 'id')::uuid) = 0, 'a date range narrows the Records');
  -- Choices: a presentation direction is saved to LifeOS Memory
  m := lifeos.memory_create('{"content": "SKT_L16 For questions about a person, show places and food first; skip spending totals", "categories": ["User Operating Rules"]}'::jsonb);
  perform pg_temp.chk(pg_temp.cnt(lifeos.memory_search('{"keyword": "SKT_L16", "categories": ["User Operating Rules"]}'::jsonb) -> 'results', (m ->> 'id')::uuid) = 1, 'the direction is retrievable');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 17. Section 15 LifeOS Memory: retrieval, learning, improvement, consolidation, negative feedback -----
do $t$
declare t constant text := 'memory_retrieve_learn_improve_consolidate_and_correct';
  m1 jsonb; m2 jsonb; m3 jsonb; s jsonb; u jsonb;
begin
  -- learning step 1 and 3: save without approval, Categories and Tags by the Agent
  m1 := lifeos.memory_create('{"title": "SKT_L17 Shopee vouchers", "content": "SKT_L17 Shopee vouchers are Adjustment Lines", "categories": ["Processing Conventions"], "tags": ["skt-l17", "expense"]}'::jsonb);
  m2 := lifeos.memory_create('{"title": "SKT_L17 Shopee coins", "content": "SKT_L17 Shopee coins are discounts", "categories": ["Processing Conventions", "Vocabulary"], "tags": ["skt-l17"]}'::jsonb);
  m3 := lifeos.memory_create('{"content": "SKT_L17 the user always pays by cash", "categories": ["Behavioural Patterns"], "tags": ["skt-l17"]}'::jsonb);
  perform pg_temp.chk(m1 -> 'categories' = '["Processing Conventions"]'::jsonb and m3 ->> 'title' is null and m3 -> 'metadata' = '{}'::jsonb, 'Memory saved with Categories, Tags and defaults');
  -- retrieval step 1
  s := lifeos.memory_search('{"keyword": "SKT_L17 Shopee", "categories": ["Processing Conventions"], "tags": ["skt-l17"]}'::jsonb);
  perform pg_temp.chk((s ->> 'returned_count')::integer = 2, 'retrieval finds both Shopee Memories');
  -- learning steps 6 and 7: improve and consolidate
  u := lifeos.memory_update((m1 ->> 'id')::uuid, '{"content": "SKT_L17 Shopee vouchers and coins are bill-wide Adjustment Lines", "categories": ["Processing Conventions", "Vocabulary"]}'::jsonb);
  perform pg_temp.chk(u ->> 'content' like '%vouchers and coins%' and u ->> 'title' = 'SKT_L17 Shopee vouchers', 'the Learning is improved, other fields kept');
  perform lifeos.memory_delete((m2 ->> 'id')::uuid);
  s := lifeos.memory_search('{"keyword": "SKT_L17 Shopee"}'::jsonb);
  perform pg_temp.chk((s ->> 'returned_count')::integer = 1 and s -> 'results' -> 0 ->> 'id' = m1 ->> 'id', 'one consolidated Memory remains');
  perform pg_temp.chk(pg_temp.cnt(lifeos.memory_search('{"keyword": "SKT_L17 Shopee", "include_deleted": true}'::jsonb) -> 'results', (m2 ->> 'id')::uuid) = 1, 'the merged Memory is soft deleted');
  -- negative feedback: the wrong Memory is removed, the valid one stays
  perform lifeos.memory_delete((m3 ->> 'id')::uuid);
  perform pg_temp.chk(lifeos.memory_read((m3 ->> 'id')::uuid) ->> 'deleted_at' is not null and lifeos.memory_read((m1 ->> 'id')::uuid) ->> 'deleted_at' is null, 'wrong Memory removed, valid Memory kept');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 18. Section 16 Notebook: read by key, reuse, maintain by full content, list, a new key -----------
do $t$
declare t constant text := 'notebook_read_reuse_maintain_and_new_key';
  nt jsonb; df jsonb; et jsonb; up jsonb; again jsonb; lst jsonb; nw jsonb;
begin
  nt := lifeos.notebook_read('note_types');
  perform pg_temp.chk(nt ->> 'content' like '%Feeling%' and nt ->> 'name' = 'Note Types', 'note_types holds its default Note Types');
  df := lifeos.notebook_read('defaults');
  perform pg_temp.chk(df ->> 'content' like '%currency: MYR%', 'defaults holds the default Currency MYR');
  -- step 5: write the full new content
  et := lifeos.notebook_read('expense_tags');
  perform pg_temp.chk(et ->> 'name' = 'Expense Tags', 'expense_tags read or initialised');
  up := lifeos.notebook_update('expense_tags', jsonb_build_object('content', concat_ws(E'\n', nullif(et ->> 'content', ''), 'skt-l18-vitamin')));
  perform pg_temp.chk(up ->> 'content' like '%skt-l18-vitamin%', 'the new Tag is in the content');
  again := lifeos.notebook_read('expense_tags');
  perform pg_temp.chk(not (again ->> 'initialised')::boolean and again ->> 'content' = up ->> 'content', 'a later read reuses the Notebook');
  -- step 2: list the catalog
  lst := lifeos.notebook_list('{"keyword": "skt-l18"}'::jsonb);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(lst -> 'results') r where r ->> 'key' = 'expense_tags'), 'the catalog lists the Notebook');
  -- step 6: another justified vocabulary under a new key
  nw := lifeos.notebook_read('skt_l18_fuel_stations', 'SKT_L18 Fuel stations');
  perform pg_temp.chk((nw ->> 'initialised')::boolean and nw ->> 'name' = 'SKT_L18 Fuel stations' and coalesce(nw ->> 'content', '') = '', 'a new key starts empty with the supplied name');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 19. Section 16 step 4: language_modes and platforms reuse an existing value; a new value only when none fits ---
do $t$
declare t constant text := 'notebook_language_modes_and_platforms_reuse_or_add_value';
  lm jsonb; pf jsonb; up jsonb; again jsonb; v text; g jsonb;
begin
  -- step 1: read by the catalog keys; a first read initialises an empty Notebook with its catalog name
  lm := lifeos.notebook_read('language_modes');
  pf := lifeos.notebook_read('platforms');
  perform pg_temp.chk(lm ->> 'name' = 'Language Modes' and (not (lm ->> 'initialised')::boolean or coalesce(lm ->> 'content', '') = ''), 'language_modes: catalog name, empty when just initialised, got ' || lm::text);
  perform pg_temp.chk(pf ->> 'name' = 'Platforms' and (not (pf ->> 'initialised')::boolean or coalesce(pf ->> 'content', '') = ''), 'platforms: catalog name, empty when just initialised, got ' || pf::text);
  -- steps 3 to 5: no existing value fits English, so the new value is added as the full new content
  perform pg_temp.chk(not exists (select 1 from regexp_split_to_table(coalesce(lm ->> 'content', ''), E'\n') l where btrim(l) = 'skt_l19_en'), 'the value is not there yet');
  up := lifeos.notebook_update('language_modes', jsonb_build_object('content', concat_ws(E'\n', nullif(lm ->> 'content', ''), 'skt_l19_en')));
  perform lifeos.notebook_update('platforms', jsonb_build_object('content', concat_ws(E'\n', nullif(pf ->> 'content', ''), 'skt_l19_whatsapp')));
  -- a later message in English: the existing value fits, so it is reused and the Notebook stays as it is
  again := lifeos.notebook_read('language_modes');
  perform pg_temp.chk(not (again ->> 'initialised')::boolean and again ->> 'content' = up ->> 'content', 'the later read reuses the stored content');
  v := (select btrim(l) from regexp_split_to_table(again ->> 'content', E'\n') l where btrim(l) = 'skt_l19_en');
  perform pg_temp.chk(v = 'skt_l19_en', 'the reused value is read from the Notebook');
  -- a message in mixed English and Malay: no existing value fits, so one new value is added
  up := lifeos.notebook_update('language_modes', jsonb_build_object('content', concat_ws(E'\n', nullif(again ->> 'content', ''), 'skt_l19_en_ms')));
  perform pg_temp.chk((select count(*) from regexp_split_to_table(up ->> 'content', E'\n') l where btrim(l) = 'skt_l19_en') = 1
                      and (select count(*) from regexp_split_to_table(up ->> 'content', E'\n') l where btrim(l) = 'skt_l19_en_ms') = 1, 'each value is stored once, got ' || (up ->> 'content'));
  perform pg_temp.chk((select count(*) from regexp_split_to_table(lifeos.notebook_read('platforms') ->> 'content', E'\n') l where btrim(l) = 'skt_l19_whatsapp') = 1, 'the Platform value is stored once');
  -- outcome: Rule resolution matches the stored value
  g := lifeos.communication_rule_upsert(jsonb_build_object('language_mode', v, 'dimension', 'skt_l19_tone', 'rule_key', 'register', 'rule_text', 'SKT_L19 plain English'));
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(lifeos.communication_resolve(null, v) -> 'effective_rules' -> 'skt_l19_tone') x where x ->> 'id' = g ->> 'id'), 'a Rule with the stored Language Mode value applies to that value');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
