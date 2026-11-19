-- =============================================================================
-- tests/08_communication_assistant.sql -- Module: Communication Assistant (Contract communication-assistant.md Chapter 8)
-- Profiles, Audience inheritance, Rules, Rule resolution, message finalize, history.
--
-- Tests in this file:
--   1. profile_create_person_group_audience_rules
--   2. profile_search_update_and_person_link
--   3. membership_set_remove_and_rejections
--   4. rule_upsert_create_update_delete
--   5. communication_resolve_precedence
--   6. communication_resolve_language_mode
--   7. rule_state_lists_scopes
--   8. message_finalize_saves_message_and_rule_changes
--   9. message_finalize_is_all_or_nothing
--   10. runtime_context_recent_messages_and_platform
--   11. message_history_search_read_delete
--   12. profile_delete_stops_rules_keeps_history
--   13. profile_and_message_search_filter_by_deleted_record_id_matches_nothing
--   14. profile_merge_moves_rules_and_message_history_and_deletes_merged_profile
--   15. profile_merge_rule_conflict_moves_nothing
--   16. profile_merge_rejects_group_and_audience_profiles
--   17. profile_merge_rejects_same_profile_twice
--   18. profile_merge_not_found_deleted_and_invalid_input
--
-- A fixture block between tests 4 and 5 builds the Profiles and Rules that tests 5 to 7 resolve.
-- Test setup that the Contract has no function for: tests 10 and 11 move
-- finalized_at of saved messages into the past, so newest-first order can be
-- told apart inside a single transaction. Test 14 reads lifeos.communication_messages to
-- check the stored profile_id of a moved deleted message, which no Contract return shows.
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

create function pg_temp.mk_subject(p_name text) returns uuid language sql as
$f$ select ((lifeos.subject_create(jsonb_build_object('name', p_name, 'subject_type', 'person')))->>'id')::uuid $f$;
create function pg_temp.mk_profile(p_key text, p_type text, p_subject uuid default null) returns uuid language sql as
$f$ select ((lifeos.communication_profile_create(jsonb_build_object('profile_key', p_key, 'profile_type', p_type, 'name', p_key, 'person_subject_id', p_subject)))->>'id')::uuid $f$;
-- Effective rule text of one dimension and rule_key in a communication_resolve result.
create function pg_temp.eff(p_res jsonb, p_dim text, p_key text) returns text language sql as
$f$ select r->>'rule_text' from jsonb_array_elements(p_res->'effective_rules'->p_dim) r where r->>'rule_key' = p_key $f$;
create function pg_temp.rule(p_profile uuid, p_lang text, p_dim text, p_key text, p_text text) returns jsonb language sql as
$f$ select lifeos.communication_rule_upsert(jsonb_build_object('profile_id', p_profile, 'language_mode', p_lang, 'dimension', p_dim, 'rule_key', p_key, 'rule_text', p_text)) $f$;

-- 1. Person, Group and Audience Profiles ------------------------------------------------
do $t$
declare t constant text := 'profile_create_person_group_audience_rules';
  s uuid := pg_temp.mk_subject('Mum (profile test)'); p jsonb; g jsonb; a jsonb;
begin
  p := lifeos.communication_profile_create(jsonb_build_object('profile_key','mum','profile_type','person','name','Mum','person_subject_id', s,'aliases', jsonb_build_array('Mom')));
  perform pg_temp.chk(p->>'profile_type' = 'person' and p->>'person_subject_id' = s::text and p->'aliases' = '["Mom"]'::jsonb and p->'metadata' = '{}'::jsonb, 'Person Profile stored');
  g := lifeos.communication_profile_create('{"profile_key":"book-club","profile_type":"group","name":"Book club"}');
  perform pg_temp.chk(g->>'person_subject_id' is null and g->'aliases' = '[]'::jsonb, 'Group Profile has no Subject');
  a := lifeos.communication_profile_create('{"profile_key":"family","profile_type":"audience","name":"Family"}');
  perform pg_temp.chk(a->>'profile_type' = 'audience', 'Audience Profile stored');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_create(%L::jsonb)', jsonb_build_object('profile_key','mum2','profile_type','person','name','Mum again','person_subject_id', s)), 'invalid relationship');
  perform pg_temp.expect_err($$select lifeos.communication_profile_create('{"profile_key":"p3","profile_type":"person","name":"No subject"}')$$, 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_create(%L::jsonb)', jsonb_build_object('profile_key','g2','profile_type','group','name','G','person_subject_id', s)), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_create(%L::jsonb)', jsonb_build_object('profile_key','p4','profile_type','audience','name','A','person_subject_id', s)), 'invalid input');
  perform pg_temp.expect_err($$select lifeos.communication_profile_create('{"profile_key":"x","name":"x"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.communication_profile_create('{"profile_key":"x","profile_type":"robot","name":"x"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.communication_profile_create('{"profile_key":"x","profile_type":"group","name":"x","bogus":1}')$$, 'unsupported field');
  perform pg_temp.chk(pg_temp.err_of($$select lifeos.communication_profile_create('{"profile_key":"family","profile_type":"group","name":"Dup key"}')$$) is not null, 'profile_key is unique');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Profile search and update --------------------------------------------------------------
do $t$
declare t constant text := 'profile_search_update_and_person_link';
  s1 uuid := pg_temp.mk_subject('Dad (profile test)'); s2 uuid := pg_temp.mk_subject('Dad Two'); p jsonb; r jsonb; u jsonb;
begin
  p := lifeos.communication_profile_create(jsonb_build_object('profile_key','dad','profile_type','person','name','Dad','description','my father','person_subject_id', s1,'aliases', jsonb_build_array('Papa')));
  r := lifeos.communication_profile_search(jsonb_build_object('person_subject_id', s1));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = p->>'id', 'search finds the Person Profile of a Subject');
  perform pg_temp.chk((lifeos.communication_profile_search('{"keyword":"papa"}')->>'returned_count')::int = 1, 'keyword matches aliases');
  perform pg_temp.chk((lifeos.communication_profile_search('{"keyword":"my father"}')->>'returned_count')::int = 1, 'keyword matches description');
  perform pg_temp.chk((lifeos.communication_profile_search('{"keyword":"DAD"}')->>'returned_count')::int = 1, 'keyword matches name and profile_key');
  perform pg_temp.chk((lifeos.communication_profile_search('{"keyword":"dad","profile_type":"group"}')->>'returned_count')::int = 0, 'profile_type filter');
  u := lifeos.communication_profile_update((p->>'id')::uuid, jsonb_build_object('name','Father','person_subject_id', s2));
  perform pg_temp.chk(u->>'name' = 'Father' and u->>'person_subject_id' = s2::text, 'update changes the name and the Person Subject');
  perform pg_temp.expect_err(format($$select lifeos.communication_profile_update(%L::uuid, '{"person_subject_id":null}')$$, p->>'id'), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.communication_profile_update(%L::uuid, '{"profile_type":"group"}')$$, p->>'id'), 'unsupported field');
  perform pg_temp.chk(lifeos.communication_profile_read((p->>'id')::uuid)->'parent_profiles' = '[]'::jsonb, 'profile_read returns parent_profiles');
  -- one Subject, one active Person Profile
  perform lifeos.communication_profile_create(jsonb_build_object('profile_key','dad-other','profile_type','person','name','Other','person_subject_id', s1));
  perform pg_temp.expect_err(format($$select lifeos.communication_profile_update(%L::uuid, jsonb_build_object('person_subject_id', %L::uuid))$$, p->>'id', s1), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Membership: set, update priority, remove, rejections -------------------------------------
do $t$
declare t constant text := 'membership_set_remove_and_rejections';
  s uuid := pg_temp.mk_subject('Member person'); person uuid; aud1 uuid; aud2 uuid; grp uuid; m jsonb; r jsonb;
begin
  person := pg_temp.mk_profile('member-person', 'person', s);
  aud1 := pg_temp.mk_profile('aud-one', 'audience');
  aud2 := pg_temp.mk_profile('aud-two', 'audience');
  grp  := pg_temp.mk_profile('grp-one', 'group');
  m := lifeos.communication_profile_membership_set(person, aud1, 3, '{"why":"test"}');
  perform pg_temp.chk(m->>'child_profile_id' = person::text and m->>'parent_profile_id' = aud1::text and (m->>'priority')::int = 3 and m->'metadata'->>'why' = 'test', 'membership created');
  m := lifeos.communication_profile_membership_set(person, aud1);
  perform pg_temp.chk((m->>'priority')::int = 0 and m->'metadata' = '{}'::jsonb, 'a second call updates the membership with the defaults');
  perform pg_temp.chk(jsonb_array_length(lifeos.communication_profile_read(person)->'parent_profiles') = 1, 'one parent after the update');
  r := lifeos.communication_profile_read(person);
  perform pg_temp.chk(r->'parent_profiles'->0->>'profile_id' = aud1::text and r->'parent_profiles'->0->>'name' = 'aud-one' and (r->'parent_profiles'->0->>'priority')::int = 0, 'parent_profiles lists profile_id, name and priority');
  -- rejections
  perform pg_temp.expect_err(format('select lifeos.communication_profile_membership_set(%L::uuid, %L::uuid)', person, person), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_membership_set(%L::uuid, %L::uuid)', person, grp), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_membership_set(%L::uuid, %L::uuid)', person, person), 'invalid relationship');
  perform lifeos.communication_profile_membership_set(aud1, aud2);
  perform pg_temp.expect_err(format('select lifeos.communication_profile_membership_set(%L::uuid, %L::uuid)', aud2, aud1), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_membership_set(%L::uuid, gen_random_uuid())', person), 'record not found');
  -- remove
  perform pg_temp.chk((lifeos.communication_profile_membership_remove(person, aud1)->>'removed')::boolean, 'membership removed');
  perform pg_temp.chk(not (lifeos.communication_profile_membership_remove(person, aud1)->>'removed')::boolean, 'a missing membership returns removed false');
  perform pg_temp.chk(jsonb_array_length(lifeos.communication_profile_read(person)->'parent_profiles') = 0, 'no parents after removal');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Rule upsert (create, update by key, update by id) and delete ---------------------------------
do $t$
declare t constant text := 'rule_upsert_create_update_delete';
  pf uuid := pg_temp.mk_profile('rule-profile', 'group'); r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; d jsonb;
begin
  r1 := pg_temp.rule(pf, null, 'tone', 'greeting', 'Say hello warmly');
  perform pg_temp.chk(r1->>'action' = 'created' and r1->>'profile_id' = pf::text and r1->>'language_mode' is null and r1->>'dimension' = 'tone' and r1->>'rule_key' = 'greeting', 'a new Rule is created');
  r2 := pg_temp.rule(pf, null, 'tone', 'greeting', 'Say hello very warmly');
  perform pg_temp.chk(r2->>'action' = 'updated' and r2->>'id' = r1->>'id' and r2->>'rule_text' = 'Say hello very warmly', 'the same profile, language_mode, dimension and rule_key updates the Rule');
  r3 := pg_temp.rule(pf, 'zh', 'tone', 'greeting', 'zh greeting');
  perform pg_temp.chk(r3->>'action' = 'created' and r3->>'id' <> r1->>'id', 'another language_mode makes another Rule');
  r4 := lifeos.communication_rule_upsert(jsonb_build_object('id', r1->>'id', 'rule_text', 'Say hello briefly'));
  perform pg_temp.chk(r4->>'action' = 'updated' and r4->>'id' = r1->>'id' and r4->>'rule_text' = 'Say hello briefly' and r4->>'dimension' = 'tone', 'with id the supplied fields replace the Rule values');
  r4 := lifeos.communication_rule_upsert('{"dimension":"style","rule_key":"global-one","rule_text":"Global text"}');
  perform pg_temp.chk(r4->>'profile_id' is null and r4->>'language_mode' is null and r4->'metadata' = '{}'::jsonb, 'defaults: Global scope, neutral language, metadata {}');
  perform pg_temp.expect_err($$select lifeos.communication_rule_upsert('{"dimension":"tone","rule_key":"k"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.communication_rule_upsert('{"rule_key":"k","rule_text":"t"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.communication_rule_upsert(jsonb_build_object('id', gen_random_uuid(), 'rule_text', 't'))$$, 'record not found');
  perform pg_temp.expect_err($$select lifeos.communication_rule_upsert('{"dimension":"d","rule_key":"k","rule_text":"t","bogus":1}')$$, 'unsupported field');
  d := lifeos.communication_rule_delete((r3->>'id')::uuid);
  perform pg_temp.chk(d->>'id' = r3->>'id' and (d->>'removed')::boolean, 'rule delete removes the Rule');
  perform pg_temp.chk(not (lifeos.communication_rule_delete((r3->>'id')::uuid)->>'removed')::boolean, 'deleting a removed Rule returns removed false');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lifeos.communication_rule_state(pf, 'zh')->'rules') x where x->>'id' = r3->>'id'), 'the removed Rule is gone from the state');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Shared fixture for tests 5 to 7: a Person Profile that inherits through two Audience levels ---------
do $t$
declare
  s uuid := pg_temp.mk_subject('Resolve person'); person uuid; far uuid; near1 uuid; near2 uuid;
begin
  person := pg_temp.mk_profile('res-person', 'person', s);
  far   := pg_temp.mk_profile('res-far', 'audience');
  near1 := pg_temp.mk_profile('res-near1', 'audience');
  near2 := pg_temp.mk_profile('res-near2', 'audience');
  perform lifeos.communication_profile_membership_set(near1, far, 0);
  perform lifeos.communication_profile_membership_set(person, near1, 1);
  perform lifeos.communication_profile_membership_set(person, near2, 5);
  perform pg_temp.keep('res_person', person); perform pg_temp.keep('res_far', far);
  perform pg_temp.keep('res_near1', near1); perform pg_temp.keep('res_near2', near2);
  -- Global
  perform pg_temp.rule(null, null, 'tone', 'greeting', 'G greeting');
  perform pg_temp.rule(null, null, 'tone', 'closing', 'G closing');
  perform pg_temp.rule(null, null, 'style', 'length', 'G length');
  perform pg_temp.rule(null, null, 'style', 'emoji', 'G emoji');
  perform pg_temp.rule(null, 'zh', 'tone', 'greeting', 'G greeting zh');
  -- far Audience (depth 2)
  perform pg_temp.rule(far, null, 'tone', 'greeting', 'far greeting');
  perform pg_temp.rule(far, null, 'tone', 'closing', 'far closing');
  perform pg_temp.rule(far, 'zh', 'tone', 'greeting', 'far greeting zh');
  -- near Audiences (depth 1, priorities 1 and 5)
  perform pg_temp.rule(near1, null, 'tone', 'closing', 'near1 closing');
  perform pg_temp.rule(near2, null, 'tone', 'closing', 'near2 closing');
  -- the Profile's own Rule
  perform pg_temp.rule(person, null, 'style', 'length', 'P length');
exception when others then raise notice 'FIXTURE FAILED: %', sqlerrm;
end $t$;

-- 5. Rule resolution: Profile > nearest Audience > Global; priority at the same depth ----------------
do $t$
declare t constant text := 'communication_resolve_precedence';
  person uuid := pg_temp.id('res_person'); res jsonb; g jsonb;
begin
  perform pg_temp.chk(person is not null, 'fixture present');
  res := lifeos.communication_resolve(person, null);
  perform pg_temp.chk(res->'profile'->>'id' = person::text, 'the result names the compact Profile');
  perform pg_temp.chk(pg_temp.eff(res, 'style', 'length') = 'P length', 'the Profile''s own Rule outranks inherited and Global Rules');
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'greeting') = 'far greeting', 'an inherited Rule outranks a Global Rule, got ' || coalesce(pg_temp.eff(res, 'tone', 'greeting'), '<none>'));
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'closing') = 'near2 closing', 'among Rules at the nearer depth the higher membership priority wins, got ' || coalesce(pg_temp.eff(res, 'tone', 'closing'), '<none>'));
  perform pg_temp.chk(pg_temp.eff(res, 'style', 'emoji') = 'G emoji', 'a Global Rule applies when nothing outranks it');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(res->'effective_rules'->'tone') r where r->>'rule_key' = 'closing') = 1, 'one Rule wins per dimension and rule_key');
  perform pg_temp.chk((select r->>'scope' from jsonb_array_elements(res->'effective_rules'->'style') r where r->>'rule_key' = 'length') = 'profile', 'scope profile reported');
  perform pg_temp.chk((select r->>'scope' from jsonb_array_elements(res->'effective_rules'->'tone') r where r->>'rule_key' = 'closing') = 'inherited', 'scope inherited reported');
  perform pg_temp.chk((select r->>'source_profile_id' from jsonb_array_elements(res->'effective_rules'->'tone') r where r->>'rule_key' = 'closing') = pg_temp.id('res_near2')::text, 'source_profile_id names the winning Audience');
  -- no Profile: Global only
  g := lifeos.communication_resolve(null, null);
  perform pg_temp.chk(g->'profile' is null or g->>'profile' is null or jsonb_typeof(g->'profile') = 'null', 'no Profile in a Global resolve');
  perform pg_temp.chk(pg_temp.eff(g, 'tone', 'greeting') = 'G greeting' and pg_temp.eff(g, 'style', 'length') = 'G length' and pg_temp.eff(g, 'tone', 'closing') = 'G closing', 'a Global resolve returns Global Rules');
  -- a nearer depth wins over a farther one: drop near1/near2 closing Rules, far closing remains
  perform lifeos.communication_profile_membership_remove(person, pg_temp.id('res_near2'));
  res := lifeos.communication_resolve(person, null);
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'closing') = 'near1 closing', 'with one nearer Audience left, its Rule outranks the farther Audience');
  perform lifeos.communication_profile_membership_set(person, pg_temp.id('res_near2'), 5);
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Rule resolution with a Language Mode -------------------------------------------------------------
do $t$
declare t constant text := 'communication_resolve_language_mode';
  person uuid := pg_temp.id('res_person'); res jsonb;
begin
  res := lifeos.communication_resolve(person, 'zh');
  perform pg_temp.chk(res->>'language_mode' = 'zh', 'the Language Mode is echoed');
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'greeting') = 'far greeting zh', 'within one scope the exact Language Mode outranks the neutral Rule, got ' || coalesce(pg_temp.eff(res, 'tone', 'greeting'), '<none>'));
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'closing') = 'near2 closing', 'neutral Rules still apply under a Language Mode');
  res := lifeos.communication_resolve(null, 'zh');
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'greeting') = 'G greeting zh', 'a Global resolve with zh picks the zh Global Rule');
  res := lifeos.communication_resolve(null, 'en');
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'greeting') = 'G greeting', 'a Language Mode without a specific Rule falls back to the neutral Rule');
  res := lifeos.communication_resolve(person, null);
  perform pg_temp.chk(pg_temp.eff(res, 'tone', 'greeting') = 'far greeting', 'language_mode null ignores language-specific Rules');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Raw rule state: scopes, depth and priority ---------------------------------------------------------
do $t$
declare t constant text := 'rule_state_lists_scopes';
  person uuid := pg_temp.id('res_person'); st jsonb; far_d int; near_d int;
begin
  st := lifeos.communication_rule_state(person, null);
  perform pg_temp.chk(st->>'profile_id' = person::text, 'profile_id echoed');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'scope' = 'profile' and r->>'rule_text' = 'P length'), 'state holds the Profile Rule');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'scope' = 'inherited' and r->>'rule_text' = 'far closing'), 'state holds inherited Rules from every ancestor');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'scope' = 'global' and r->>'rule_text' = 'G emoji'), 'state holds Global Rules');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'language_mode' = 'zh'), 'without a Language Mode only neutral Rules are returned');
  select (r->>'depth')::int into far_d from jsonb_array_elements(st->'rules') r where r->>'rule_text' = 'far closing';
  select (r->>'depth')::int into near_d from jsonb_array_elements(st->'rules') r where r->>'rule_text' = 'near1 closing';
  perform pg_temp.chk(far_d > near_d, 'the farther Audience has the greater depth');
  perform pg_temp.chk((select (r->>'priority')::int from jsonb_array_elements(st->'rules') r where r->>'rule_text' = 'near2 closing') = 5, 'membership priority reported');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'rule_text' = 'near1 closing') and exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'rule_text' = 'near2 closing'),
                      'state is raw: losing Rules are listed too');
  st := lifeos.communication_rule_state(null, null);
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'scope' <> 'global'), 'a null profile returns Global Rules only');
  st := lifeos.communication_rule_state(person, 'zh');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'language_mode' = 'zh') and exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'language_mode' is null),
                      'with a Language Mode both the matching and the neutral Rules are returned');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Finalize: message and consolidated Rule changes together -----------------------------------------
do $t$
declare t constant text := 'message_finalize_saves_message_and_rule_changes';
  pf uuid := pg_temp.mk_profile('fin-person', 'person', pg_temp.mk_subject('Finalize person')); r0 jsonb; r_old jsonb; res jsonb; m jsonb; ctx jsonb;
begin
  r_old := pg_temp.rule(pf, null, 'tone', 'old-rule', 'to be removed');
  r0 := pg_temp.rule(pf, null, 'tone', 'keep-rule', 'before');
  res := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf, 'message_text','Hi Mum, dinner at 7?','language_mode','en','platform','whatsapp','intent','invite to dinner','message_mode','casual',
          'metadata', jsonb_build_object('thread','x'),
          'rule_changes', jsonb_build_array(
            jsonb_build_object('action','upsert','profile_id', pf,'dimension','tone','rule_key','keep-rule','rule_text','after'),
            jsonb_build_object('action','upsert','profile_id', pf,'dimension','tone','rule_key','new-rule','rule_text','brand new'),
            jsonb_build_object('action','delete','id', r_old->>'id'))));
  m := res->'message';
  perform pg_temp.chk(m->>'message_text' = 'Hi Mum, dinner at 7?' and m->>'profile_id' = pf::text and m->>'language_mode' = 'en' and m->>'platform' = 'whatsapp'
                      and m->>'intent' = 'invite to dinner' and m->>'message_mode' = 'casual' and m->'metadata'->>'thread' = 'x', 'message fields stored');
  perform pg_temp.chk(m->>'finalized_at' is not null, 'finalized_at set');
  perform pg_temp.chk(jsonb_array_length(res->'rule_changes_applied') = 3, 'three Rule changes reported as applied, got ' || jsonb_array_length(res->'rule_changes_applied'));
  perform pg_temp.chk(res->'runtime_context' ? 'effective_rules' and res->'runtime_context' ? 'recent_messages', 'the runtime_context is returned');
  perform pg_temp.chk(pg_temp.eff(res->'runtime_context', 'tone', 'keep-rule') = 'after', 'the context shows the updated Rule');
  perform pg_temp.chk(pg_temp.eff(res->'runtime_context', 'tone', 'new-rule') = 'brand new', 'the context shows the new Rule');
  perform pg_temp.chk(pg_temp.eff(res->'runtime_context', 'tone', 'old-rule') is null, 'the deleted Rule no longer applies');
  ctx := lifeos.communication_resolve(pf, null);
  perform pg_temp.chk(pg_temp.eff(ctx, 'tone', 'keep-rule') = 'after' and pg_temp.eff(ctx, 'tone', 'old-rule') is null, 'the Rule changes persist');
  -- a message without Rule changes is still saved
  res := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf, 'message_text','Thanks!'));
  perform pg_temp.chk(res->'message'->>'id' is not null and res->'rule_changes_applied' = '[]'::jsonb, 'the message is saved with no Rule changes');
  perform pg_temp.chk(lifeos.communication_message_finalize('{"message_text":"No profile"}')->'message'->>'profile_id' is null, 'profile_id defaults to null');
  perform pg_temp.expect_err($$select lifeos.communication_message_finalize('{"profile_id":null}')$$, 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Finalize is all-or-nothing -------------------------------------------------------------------------
do $t$
declare t constant text := 'message_finalize_is_all_or_nothing';
  pf uuid := pg_temp.mk_profile('atomic-group', 'group'); e text; n int;
begin
  e := pg_temp.err_of(format('select lifeos.communication_message_finalize(%L::jsonb)', jsonb_build_object('profile_id', pf,'message_text','atomicprobe message',
        'rule_changes', jsonb_build_array(jsonb_build_object('action','upsert','profile_id', pf,'dimension','tone','rule_key','good','rule_text','fine'),
                                          jsonb_build_object('action','upsert','profile_id', pf,'dimension','tone','rule_key','bad'))))); -- no rule_text
  perform pg_temp.chk(e = 'invalid input', 'an invalid Rule change fails the call with invalid input, got ' || coalesce(e, '<no error>'));
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf, 'keyword','atomicprobe'))->>'returned_count')::int = 0, 'the message is not saved');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(pf, null), 'tone', 'good') is null, 'the valid Rule change is not applied either');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Runtime context: newest first, limit, platform first --------------------------------------------------
do $t$
declare t constant text := 'runtime_context_recent_messages_and_platform';
  pf uuid := pg_temp.mk_profile('ctx-group', 'group'); m1 jsonb; m2 jsonb; m3 jsonb; m4 jsonb; ctx jsonb; i int;
begin
  perform pg_temp.rule(pf, null, 'tone', 'warm', 'be warm');
  m1 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','m1 old email','platform','email','language_mode','en'))->'message';
  m2 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','m2 whatsapp','platform','whatsapp','language_mode','en'))->'message';
  m3 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','m3 newest email','platform','email','language_mode','en'))->'message';
  m4 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','m4 other language','platform','email','language_mode','zh'))->'message';
  -- Test setup: spread finalized_at (a transaction has one clock value).
  update lifeos.communication_messages set finalized_at = now() - interval '3 hours' where id = (m1->>'id')::uuid;
  update lifeos.communication_messages set finalized_at = now() - interval '2 hours' where id = (m2->>'id')::uuid;
  update lifeos.communication_messages set finalized_at = now() - interval '1 hour'  where id = (m3->>'id')::uuid;

  ctx := lifeos.communication_runtime_context(pf, 'en');
  perform pg_temp.chk(ctx->>'language_mode' = 'en' and ctx->'profile'->>'id' = pf::text, 'profile and language_mode returned');
  perform pg_temp.chk(pg_temp.eff(ctx, 'tone', 'warm') = 'be warm', 'effective_rules included');
  perform pg_temp.chk(jsonb_array_length(ctx->'recent_messages') = 3, 'messages of the Language Mode only (the zh message is excluded), got ' || jsonb_array_length(ctx->'recent_messages'));
  perform pg_temp.chk((select array_agg(x->>'message_text' order by ord) from jsonb_array_elements(ctx->'recent_messages') with ordinality q(x, ord)) = array['m3 newest email','m2 whatsapp','m1 old email'], 'recent messages are newest first');
  ctx := lifeos.communication_runtime_context(pf, 'en', null, 2);
  perform pg_temp.chk(jsonb_array_length(ctx->'recent_messages') = 2, 'p_history_limit limits the messages');
  ctx := lifeos.communication_runtime_context(pf, 'en', 'whatsapp', 3);
  perform pg_temp.chk(ctx->>'platform' = 'whatsapp' and ctx->'recent_messages'->0->>'message_text' = 'm2 whatsapp', 'messages on the supplied platform rank first');
  perform pg_temp.chk(jsonb_array_length(ctx->'recent_messages') = 3, 'other-platform messages follow');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Message history: search, read, delete --------------------------------------------------------------------
do $t$
declare t constant text := 'message_history_search_read_delete';
  pf uuid := pg_temp.mk_profile('hist-group', 'group'); a jsonb; b jsonb; r jsonb; d jsonb; td date := pg_temp.today();
begin
  a := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','Happy birthday xqhist','intent','greeting','platform','whatsapp','message_mode','warm','language_mode','en'))->'message';
  b := lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf,'message_text','Meeting moved xqhist','intent','schedule change','platform','email','message_mode','formal','language_mode','en'))->'message';
  update lifeos.communication_messages set finalized_at = now() - interval '5 days' where id = (a->>'id')::uuid;

  r := lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf));
  perform pg_temp.chk((r->>'returned_count')::int = 2 and r->'results'->0->>'id' = b->>'id' and r->'results'->1->>'id' = a->>'id', 'results ordered by finalized_at descending');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf,'keyword','BIRTHDAY'))->>'returned_count')::int = 1, 'keyword matches message_text');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf,'keyword','schedule change'))->>'returned_count')::int = 1, 'keyword matches intent');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf,'platform','email'))->>'returned_count')::int = 1, 'platform filter');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf,'message_mode','warm'))->>'returned_count')::int = 1, 'message_mode filter');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf,'intent','greeting'))->>'returned_count')::int = 1, 'intent filter');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf,'from_date', td,'to_date', td))->>'returned_count')::int = 1, 'a date-only range covers the whole KL day');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf,'from_date', td - 5,'to_date', td - 5))->>'returned_count')::int = 1, 'the earlier message is found on its KL date');
  perform pg_temp.chk(lifeos.communication_message_history_read((a->>'id')::uuid)->>'message_text' = 'Happy birthday xqhist', 'exact read');
  d := lifeos.communication_message_history_delete((a->>'id')::uuid);
  perform pg_temp.chk(d->>'deleted_at' is not null, 'delete returns deleted_at');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf))->>'returned_count')::int = 1, 'search hides the deleted message');
  perform pg_temp.chk(lifeos.communication_message_history_read((a->>'id')::uuid)->>'deleted_at' is not null, 'exact read still returns the deleted message');
  perform pg_temp.expect_err($$select lifeos.communication_message_history_read(gen_random_uuid())$$, 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Deleting a Profile stops its Rules, keeps its Message History ----------------------------------------------
do $t$
declare t constant text := 'profile_delete_stops_rules_keeps_history';
  s uuid := pg_temp.mk_subject('Deleted profile person'); person uuid; aud uuid; res jsonb; d jsonb; again uuid;
begin
  person := pg_temp.mk_profile('del-person', 'person', s);
  aud := pg_temp.mk_profile('del-aud', 'audience');
  perform lifeos.communication_profile_membership_set(person, aud);
  perform pg_temp.rule(aud, null, 'tone', 'inherit-me', 'inherited text');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(person, null), 'tone', 'inherit-me') = 'inherited text', 'the inherited Rule applies before the delete');
  perform lifeos.communication_message_finalize(jsonb_build_object('profile_id', aud, 'message_text','audience message xqdel'));
  d := lifeos.communication_profile_delete(aud);
  perform pg_temp.chk(d->>'deleted_at' is not null, 'delete returns deleted_at');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(person, null), 'tone', 'inherit-me') is null, 'the deleted Audience''s Rules stop applying');
  perform pg_temp.chk((lifeos.communication_message_history_search('{"keyword":"xqdel"}')->>'returned_count')::int = 1, 'the deleted Profile''s Message History stays');
  -- M-0021 D10: a filter by the deleted Profile ID matches nothing
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', aud, 'keyword','xqdel'))->>'returned_count')::int = 0, 'a filter by the deleted Profile ID matches nothing');
  perform pg_temp.chk(lifeos.communication_profile_read(aud)->>'deleted_at' is not null, 'profile_read returns the deleted Profile');
  perform pg_temp.chk((lifeos.communication_profile_search('{"keyword":"del-aud"}')->>'returned_count')::int = 0, 'search hides the deleted Profile');
  -- deleting a Person Profile ends its Person Subject link
  perform pg_temp.chk(lifeos.subject_read(s)->>'person_profile_id' = person::text, 'subject_read shows the Person Profile');
  perform lifeos.communication_profile_delete(person);
  perform pg_temp.chk(lifeos.subject_read(s)->>'person_profile_id' is null, 'after the delete subject_read shows no Person Profile');
  again := pg_temp.mk_profile('del-person-2', 'person', s);
  perform pg_temp.chk(again is not null, 'the Subject can take a new Person Profile');
  perform pg_temp.expect_err(format($$select lifeos.communication_profile_update(%L::uuid, '{"name":"x"}')$$, person), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 13. Profile and Message History search: a filter ID of a deleted Record matches nothing (M-0021 D10)
do $t$
declare t constant text := 'profile_and_message_search_filter_by_deleted_record_id_matches_nothing';
  s uuid := pg_temp.mk_subject('D10 profile person'); pf uuid;
begin
  pf := pg_temp.mk_profile('d10-person', 'person', s);
  perform lifeos.communication_message_finalize(jsonb_build_object('profile_id', pf, 'message_text','d10 message xqd10'));
  -- active targets match
  perform pg_temp.chk((lifeos.communication_profile_search(jsonb_build_object('person_subject_id', s))->>'returned_count')::int = 1, 'person_subject_id of an active Subject matches');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf))->>'returned_count')::int = 1, 'profile_id of an active Profile matches');
  -- deleted targets match nothing, without an error
  perform lifeos.communication_profile_delete(pf);
  perform lifeos.subject_delete(s);
  perform pg_temp.chk((lifeos.communication_profile_search(jsonb_build_object('person_subject_id', s, 'include_deleted', true))->>'returned_count')::int = 0, 'person_subject_id of a deleted Subject matches nothing, also with include_deleted');
  perform pg_temp.chk((lifeos.communication_profile_search('{"keyword":"d10-person","include_deleted":true}')->>'returned_count')::int = 1, 'the Profile stays findable by keyword with include_deleted');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', pf))->>'returned_count')::int = 0, 'profile_id of a deleted Profile matches nothing');
  perform pg_temp.chk((lifeos.communication_message_history_search('{"keyword":"xqd10"}')->>'returned_count')::int = 1, 'the message stays findable by keyword');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 14. Profile merge: Rules and Message History move to the kept Profile, the emptied Profile is deleted (M-0023 D5)
do $t$
declare t constant text := 'profile_merge_moves_rules_and_message_history_and_deletes_merged_profile';
  s_keep uuid := pg_temp.mk_subject('Merge keep person'); s_merge uuid := pg_temp.mk_subject('Merge duplicate person');
  keep uuid; dup uuid; r_n jsonb; r_zh jsonb; m1 jsonb; m2 jsonb; m3 jsonb; res jsonb; st jsonb; e text;
begin
  keep := pg_temp.mk_profile('merge-keep', 'person', s_keep);
  dup := pg_temp.mk_profile('merge-dup', 'person', s_merge);
  -- keep_id has an en Rule. merge_id has the same dimension and rule_key as neutral and zh, so nothing conflicts.
  perform pg_temp.rule(keep, 'en', 'tone', 'greeting', 'keep greeting en');
  r_n := pg_temp.rule(dup, null, 'tone', 'greeting', 'dup greeting neutral');
  r_zh := pg_temp.rule(dup, 'zh', 'tone', 'greeting', 'dup greeting zh');
  perform lifeos.communication_message_finalize(jsonb_build_object('profile_id', keep, 'message_text', 'keep message xqmerge'));
  m1 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', dup, 'message_text', 'dup message one xqmerge', 'language_mode', 'zh', 'platform', 'whatsapp'))->'message';
  m2 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', dup, 'message_text', 'dup message two xqmerge'))->'message';
  m3 := lifeos.communication_message_finalize(jsonb_build_object('profile_id', dup, 'message_text', 'dup deleted message xqmerge'))->'message';
  perform lifeos.communication_message_history_delete((m3->>'id')::uuid);

  res := lifeos.communication_profile_merge(jsonb_build_object('keep_id', keep, 'merge_id', dup));
  perform pg_temp.chk(res->'profile'->>'id' = keep::text and res->'profile'->>'person_subject_id' = s_keep::text, 'the result holds the complete kept Profile');
  perform pg_temp.chk(res->>'merged_id' = dup::text and res->>'deleted_at' is not null, 'the result names the merged Profile and its deleted_at');
  perform pg_temp.chk((res->'moved'->>'rules')::int = 2, 'two Rules moved, got ' || coalesce(res->'moved'->>'rules', '<none>'));
  perform pg_temp.chk((res->'moved'->>'messages')::int = 3, 'three messages moved, the deleted one included, got ' || coalesce(res->'moved'->>'messages', '<none>'));
  -- the moved Rules belong to the kept Profile and keep their text and language_mode
  st := lifeos.communication_rule_state(keep, 'zh');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'id' = r_zh->>'id' and r->>'scope' = 'profile' and r->>'source_profile_id' = keep::text and r->>'language_mode' = 'zh' and r->>'rule_text' = 'dup greeting zh'), 'the zh Rule is now a Rule of the kept Profile');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(st->'rules') r where r->>'id' = r_n->>'id' and r->>'scope' = 'profile' and r->>'language_mode' is null), 'the neutral Rule is now a Rule of the kept Profile');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(keep, 'en'), 'tone', 'greeting') = 'keep greeting en', 'the kept en Rule still wins under en');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(keep, 'zh'), 'tone', 'greeting') = 'dup greeting zh', 'the moved zh Rule applies to the kept Profile under zh');
  -- the active Message History belongs to the kept Profile
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', keep, 'keyword', 'xqmerge'))->>'returned_count')::int = 3, 'the kept Profile has its own message and the two moved active messages');
  perform pg_temp.chk(lifeos.communication_message_history_read((m1->>'id')::uuid)->>'profile_id' = keep::text, 'a moved message reads with the kept profile_id');
  perform pg_temp.chk(lifeos.communication_message_history_read((m1->>'id')::uuid)->>'platform' = 'whatsapp' and lifeos.communication_message_history_read((m1->>'id')::uuid)->>'finalized_at' = m1->>'finalized_at', 'a moved message keeps its other fields');
  perform pg_temp.chk(lifeos.communication_runtime_context(keep, 'zh')->'recent_messages'->0->>'id' = m1->>'id', 'the moved zh message is a recent example for the kept Profile');
  -- the deleted message moved and stays deleted (direct read: no Contract return shows its stored profile_id)
  perform pg_temp.chk((select profile_id from lifeos.communication_messages where id = (m3->>'id')::uuid) = keep, 'the deleted message is stored with the kept profile_id');
  perform pg_temp.chk(lifeos.communication_message_history_read((m3->>'id')::uuid)->>'deleted_at' is not null, 'the moved deleted message keeps its deleted_at');
  -- the emptied Profile is deleted
  perform pg_temp.chk(lifeos.communication_profile_read(dup)->>'deleted_at' = res->>'deleted_at', 'the merged Profile is deleted');
  e := pg_temp.err_of(format('select lifeos.communication_rule_state(%s)', pg_temp.q(dup)));
  perform pg_temp.chk(e = 'record deleted', 'the merged Profile no longer resolves Rules, got ' || coalesce(e, '<no error>'));
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', dup))->>'returned_count')::int = 0, 'no message is left on the merged Profile');
  -- the D5 flow continues: the two Subjects now merge
  perform pg_temp.chk(lifeos.subject_read(s_merge)->>'person_profile_id' is null, 'the duplicate Subject has no Person Profile after the merge');
  res := lifeos.subject_merge(jsonb_build_object('keep_id', s_keep, 'merge_id', s_merge, 'identity', jsonb_build_object('name', 'Merge keep person')));
  perform pg_temp.chk(res->'subject'->>'person_profile_id' = keep::text, 'subject_merge succeeds and the kept Subject keeps the kept Profile');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 15. Profile merge: a Rule on both Profiles with the same language_mode, dimension and rule_key moves nothing
do $t$
declare t constant text := 'profile_merge_rule_conflict_moves_nothing';
  keep uuid := pg_temp.mk_profile('conflict-keep', 'person', pg_temp.mk_subject('Conflict keep person'));
  dup uuid := pg_temp.mk_profile('conflict-dup', 'person', pg_temp.mk_subject('Conflict duplicate person'));
  r_free jsonb; e text; d text;
begin
  perform pg_temp.rule(keep, null, 'tone', 'greeting', 'keep greeting');
  perform pg_temp.rule(dup, null, 'tone', 'greeting', 'dup greeting');
  r_free := pg_temp.rule(dup, null, 'style', 'length', 'dup length');
  perform lifeos.communication_message_finalize(jsonb_build_object('profile_id', dup, 'message_text', 'conflict message xqconflict'));
  -- a neutral Rule on both Profiles is a conflict: null language_mode matches null
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', keep, 'merge_id', dup)), 'invalid relationship');
  begin
    perform lifeos.communication_profile_merge(jsonb_build_object('keep_id', keep, 'merge_id', dup));
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
  end;
  perform pg_temp.chk(d like '%neutral/tone/greeting%' and d not like '%length%', 'the detail names the conflicting Rule only, got ' || coalesce(d, '<none>'));
  -- nothing moved and nothing was deleted
  perform pg_temp.chk(lifeos.communication_profile_read(dup)->>'deleted_at' is null, 'the duplicate Profile stays active');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(dup, null), 'style', 'length') = 'dup length', 'the non-conflicting Rule stays on the duplicate Profile');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(dup, null), 'tone', 'greeting') = 'dup greeting', 'the conflicting Rule stays on the duplicate Profile');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(lifeos.communication_rule_state(keep, null)->'rules') r where r->>'scope' = 'profile' and r->>'rule_key' = 'length'), 'the kept Profile received no Rule');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', dup, 'keyword', 'xqconflict'))->>'returned_count')::int = 1, 'the message stays on the duplicate Profile');
  -- the same conflict under one Language Mode
  perform pg_temp.rule(keep, 'zh', 'style', 'emoji', 'keep emoji zh');
  perform pg_temp.rule(dup, 'zh', 'style', 'emoji', 'dup emoji zh');
  perform lifeos.communication_rule_delete((select (r->>'id')::uuid from jsonb_array_elements(lifeos.communication_rule_state(dup, null)->'rules') r where r->>'scope' = 'profile' and r->>'rule_key' = 'greeting'));
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', keep, 'merge_id', dup)), 'invalid relationship');
  -- after the Agent resolves the last conflict with the user, the merge succeeds
  perform lifeos.communication_rule_delete((select (r->>'id')::uuid from jsonb_array_elements(lifeos.communication_rule_state(dup, 'zh')->'rules') r where r->>'scope' = 'profile' and r->>'rule_key' = 'emoji'));
  perform pg_temp.chk((lifeos.communication_profile_merge(jsonb_build_object('keep_id', keep, 'merge_id', dup))->'moved'->>'rules')::int = 1, 'after the conflicts are resolved, the merge moves the remaining Rule');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(keep, null), 'style', 'length') = 'dup length', 'the remaining Rule now applies to the kept Profile');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 16. Profile merge: only Person Profiles merge ------------------------------------------------------------------
do $t$
declare t constant text := 'profile_merge_rejects_group_and_audience_profiles';
  person uuid := pg_temp.mk_profile('type-person', 'person', pg_temp.mk_subject('Type check person'));
  grp uuid := pg_temp.mk_profile('type-group', 'group'); aud uuid := pg_temp.mk_profile('type-audience', 'audience');
begin
  perform lifeos.communication_message_finalize(jsonb_build_object('profile_id', grp, 'message_text', 'group message xqtype'));
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', person, 'merge_id', grp)), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', person, 'merge_id', aud)), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', grp, 'merge_id', person)), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', aud, 'merge_id', person)), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', grp, 'merge_id', aud)), 'invalid relationship');
  perform pg_temp.chk(lifeos.communication_profile_read(person)->>'deleted_at' is null and lifeos.communication_profile_read(grp)->>'deleted_at' is null
                      and lifeos.communication_profile_read(aud)->>'deleted_at' is null, 'no Profile is deleted');
  perform pg_temp.chk((lifeos.communication_message_history_search(jsonb_build_object('profile_id', grp, 'keyword', 'xqtype'))->>'returned_count')::int = 1, 'the Group message stays on the Group Profile');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 17. Profile merge: keep_id and merge_id differ -----------------------------------------------------------------
do $t$
declare t constant text := 'profile_merge_rejects_same_profile_twice';
  person uuid := pg_temp.mk_profile('same-person', 'person', pg_temp.mk_subject('Same profile person'));
begin
  perform pg_temp.rule(person, null, 'tone', 'greeting', 'same greeting');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', person, 'merge_id', person)), 'invalid relationship');
  perform pg_temp.chk(lifeos.communication_profile_read(person)->>'deleted_at' is null, 'the Profile stays active');
  perform pg_temp.chk(pg_temp.eff(lifeos.communication_resolve(person, null), 'tone', 'greeting') = 'same greeting', 'the Profile keeps its Rule');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 18. Profile merge: unknown and deleted Profiles, invalid input -------------------------------------------------
do $t$
declare t constant text := 'profile_merge_not_found_deleted_and_invalid_input';
  person uuid := pg_temp.mk_profile('nf-person', 'person', pg_temp.mk_subject('Not found person'));
  gone uuid := pg_temp.mk_profile('nf-deleted', 'person', pg_temp.mk_subject('Deleted profile merge person'));
begin
  perform lifeos.communication_profile_delete(gone);
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(jsonb_build_object(''keep_id'', gen_random_uuid(), ''merge_id'', %s))', pg_temp.q(person)), 'record not found');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(jsonb_build_object(''keep_id'', %s, ''merge_id'', gen_random_uuid()))', pg_temp.q(person)), 'record not found');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', gone, 'merge_id', person)), 'record deleted');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', person, 'merge_id', gone)), 'record deleted');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', person)), 'invalid input');
  perform pg_temp.expect_err($$select lifeos.communication_profile_merge('{"keep_id":"not-a-uuid","merge_id":"also-not"}')$$, 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.communication_profile_merge(%L::jsonb)', jsonb_build_object('keep_id', person, 'merge_id', gone, 'bogus', 1)), 'unsupported field');
  perform pg_temp.chk(lifeos.communication_profile_read(person)->>'deleted_at' is null, 'the active Profile stays active');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
