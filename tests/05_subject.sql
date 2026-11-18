-- =============================================================================
-- tests/05_subject.sql -- Module: Subject (Contract Chapter 5)
-- Discovery, Alias, existence check, update, duplicate merge, delete.
--
-- Tests in this file:
--   1. subject_create_defaults_and_single_user
--   2. subject_search_compact_and_exact_first
--   3. subject_alias_and_check
--   4. subject_merge_moves_references_and_applies_identity
--   5. subject_merge_user_flag_and_duplicate_links
--   6. subject_merge_rejections
--   7. subject_update_read_and_delete
--   8. subject_merge_rejects_empty_identity
--   9. subject_delete_rejects_person_subject_with_active_profile
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

-- 1. Subject create: defaults and the single user Subject ------------------------
do $t$
declare t constant text := 'subject_create_defaults_and_single_user';
  s jsonb; u jsonb;
begin
  s := lifeos.subject_create('{"name":"Nicholas","subject_type":"person"}');
  perform pg_temp.chk(s->'aliases' = '[]'::jsonb and s->'tags' = '[]'::jsonb and s->'metadata' = '{}'::jsonb, 'aliases, tags and metadata default empty');
  perform pg_temp.chk((s->>'is_user')::boolean = false, 'is_user defaults to false');
  perform pg_temp.chk(s->>'merged_into_id' is null and s->>'deleted_at' is null, 'merged_into_id and deleted_at are null');
  u := lifeos.subject_create('{"name":"Me","is_user":true}');
  perform pg_temp.chk((u->>'is_user')::boolean, 'the user Subject is created');
  perform pg_temp.expect_err($$select lifeos.subject_create('{"name":"Me too","is_user":true}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.subject_create('{"subject_type":"person"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.subject_create('{"name":"x","bogus":1}')$$, 'unsupported field');
  -- release the user flag so later tests can create their own user Subject
  perform lifeos.subject_delete((u->>'id')::uuid);
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Subject search: keyword scope, tags, compact shape, exact matches first -----
do $t$
declare t constant text := 'subject_search_compact_and_exact_first';
  a jsonb; b jsonb; c jsonb; r jsonb; d jsonb;
begin
  a := lifeos.subject_create('{"name":"Shampoo Zed","subject_type":"product","description":"anti-dandruff","tags":["bathroom","hair"]}');
  b := lifeos.subject_create('{"name":"Zed Clinic","subject_type":"place","description":"mentions shampoo zed in text"}');
  c := lifeos.subject_create('{"name":"Someone","aliases":["Shampoo Zed"],"subject_type":"person"}');
  r := lifeos.subject_search('{"keyword":"shampoo zed"}');
  perform pg_temp.chk((r->>'returned_count')::int = 3, 'keyword matches name, alias and description, got ' || (r->>'returned_count'));
  perform pg_temp.chk(r->'results'->0->>'id' in (a->>'id', c->>'id') and r->'results'->1->>'id' in (a->>'id', c->>'id'), 'exact name and alias matches come first');
  perform pg_temp.chk(r->'results'->2->>'id' = b->>'id', 'other matches follow');
  perform pg_temp.chk(r->'results'->0 ?& array['id','name','subject_type','aliases','tags','is_user','description'], 'each result is compact with the listed fields');
  r := lifeos.subject_search('{"keyword":"anti-dandruff"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1, 'keyword matches description');
  r := lifeos.subject_search('{"keyword":"PRODUCT"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1, 'keyword matches subject_type');
  r := lifeos.subject_search('{"keyword":"hair"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1, 'keyword matches tags');
  r := lifeos.subject_search('{"tags":["nothere","bathroom"]}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = a->>'id', 'tags match at least one supplied Tag');
  r := lifeos.subject_search('{"subject_type":"person","keyword":"someone"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1, 'subject_type filter');
  d := lifeos.subject_create('{"name":"Searcher (user)","is_user":true}');
  r := lifeos.subject_search('{"is_user":true}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = d->>'id', 'is_user filter returns the user Subject only');
  perform lifeos.subject_delete((d->>'id')::uuid);
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Alias add (no duplicates) and existence check --------------------------------
do $t$
declare t constant text := 'subject_alias_and_check';
  s jsonb; r jsonb; c jsonb;
begin
  s := lifeos.subject_create('{"name":"Nicholas Tan","subject_type":"person"}');
  r := lifeos.subject_add_alias((s->>'id')::uuid, '  Nick  ');
  perform pg_temp.chk(r->'aliases' = '["Nick"]'::jsonb, 'the trimmed Alias is added');
  r := lifeos.subject_add_alias((s->>'id')::uuid, 'NICK');
  perform pg_temp.chk(jsonb_array_length(r->'aliases') = 1, 'an Alias already present (case-insensitive) is not added twice');
  r := lifeos.subject_add_alias((s->>'id')::uuid, 'Nic');
  perform pg_temp.chk(jsonb_array_length(r->'aliases') = 2, 'a different Alias is added');

  c := lifeos.subject_check('  nicholas TAN ');
  perform pg_temp.chk((c->>'exists')::boolean and c->'matches'->0->>'id' = s->>'id' and c->'matches'->0->>'matched_on' = 'name', 'check matches name, trimmed and case-insensitive');
  perform pg_temp.chk(c->'matches'->0->>'subject_type' = 'person', 'match carries subject_type');
  c := lifeos.subject_check('nick');
  perform pg_temp.chk((c->>'exists')::boolean and c->'matches'->0->>'matched_on' = 'alias', 'check matches an Alias');
  c := lifeos.subject_check('Nick T');
  perform pg_temp.chk(not (c->>'exists')::boolean and jsonb_array_length(c->'matches') = 0, 'check is an exact match, a substring is not a match');
  perform lifeos.subject_delete((s->>'id')::uuid);
  c := lifeos.subject_check('Nicholas Tan');
  perform pg_temp.chk(not (c->>'exists')::boolean, 'check ignores deleted Subjects');
  perform pg_temp.expect_err($$select lifeos.subject_add_alias(gen_random_uuid(), 'x')$$, 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Merge: references move, identity supplied by the Agent replaces the fields ---
do $t$
declare t constant text := 'subject_merge_moves_references_and_applies_identity';
  keep jsonb; dup jsonb; pm jsonb; n jsonb; o jsonb; x jsonb; sp jsonb; m jsonb; rd jsonb; kd jsonb; ev jsonb; links jsonb; ob jsonb;
begin
  keep := lifeos.subject_create('{"name":"Nicholas","subject_type":"person","description":"colleague","aliases":["Nick"],"tags":["work"]}');
  dup  := lifeos.subject_create('{"name":"Nick T","subject_type":"person","description":"tennis friend","aliases":["NT"],"tags":["sport"]}');
  pm   := lifeos.subject_create('{"name":"Cash","subject_type":"payment method"}');
  ev   := lifeos.event_create('{"title":"Dinner","occurred_date":"2032-04-01"}');
  -- references to the duplicate: Record link, Observation, Expense item and merchant, Story Person
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', ev->>'id','to_type','subject','to_id', dup->>'id'));
  ob := lifeos.observation_create(jsonb_build_object('subject_id', dup->>'id','observation_name','mood','value_text','good','observed_date','2032-04-01'));
  x := lifeos.expense_create(jsonb_build_object('transaction_date','2032-04-01','payment_method_subject_id', pm->>'id','expense_total', 10,'currency','MYR',
        'merchant_subject_id', dup->>'id',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','gift','unit_price',10,'line_total',10,'category','gift','item_subject_id', dup->>'id'))));
  sp := lifeos.story_person_create(jsonb_build_object('name','Nick (story)','subject_id', dup->>'id'));

  m := lifeos.subject_merge(jsonb_build_object('keep_id', keep->>'id', 'merge_id', dup->>'id',
        'identity', jsonb_build_object('name','Nicholas Tan','subject_type','person','description','colleague and tennis friend','aliases', jsonb_build_array('Nick','NT','Nick T'),'tags', jsonb_build_array('work','sport'))));
  kd := m->'subject';
  perform pg_temp.chk(m->>'merged_id' = dup->>'id' and kd->>'id' = keep->>'id', 'result names the kept Subject and the merged id');
  perform pg_temp.chk(kd->>'name' = 'Nicholas Tan' and kd->>'description' = 'colleague and tennis friend', 'the supplied identity replaces name and description');
  perform pg_temp.chk(kd->'aliases' = '["Nick","NT","Nick T"]'::jsonb and kd->'tags' = '["work","sport"]'::jsonb, 'the supplied identity replaces aliases and tags');
  perform pg_temp.chk(m ? 'moved_references' and jsonb_typeof(m->'moved_references') = 'object', 'moved_references is an object');
  perform pg_temp.chk((select coalesce(sum(v::int),0) from jsonb_each_text(m->'moved_references') e(k, v)) >= 5, 'at least five references moved, got ' || (m->>'moved_references'));

  rd := lifeos.subject_read((dup->>'id')::uuid);
  perform pg_temp.chk(rd->>'merged_into_id' = keep->>'id' and rd->>'deleted_at' is not null, 'the merged Subject has merged_into_id and deleted_at');
  perform pg_temp.chk(rd->>'name' = 'Nick T', 'the merged Subject keeps its own fields');

  perform pg_temp.chk(lifeos.observation_read((ob->>'id')::uuid)->>'subject_id' = keep->>'id', 'Observation now points to the kept Subject');
  o := lifeos.expense_read((x->>'id')::uuid);
  perform pg_temp.chk(o->>'merchant_subject_id' = keep->>'id', 'Expense Merchant now points to the kept Subject');
  perform pg_temp.chk(o->'lines'->0->>'item_subject_id' = keep->>'id', 'Expense Line Item now points to the kept Subject');
  perform pg_temp.chk(lifeos.story_person_read((sp->>'id')::uuid)->>'subject_id' = keep->>'id', 'Story Person now points to the kept Subject');
  links := lifeos.record_links_read('event', (ev->>'id')::uuid);
  perform pg_temp.chk(links->'links'->0->>'id' = keep->>'id', 'Record link now points to the kept Subject');
  perform pg_temp.chk(o->>'transaction_date' = '2032-04-01' and (o->>'expense_total')::numeric = 10, 'source Records stay unchanged');
  perform pg_temp.chk(lifeos.subject_check('Nick T')->>'exists' = 'true', 'the supplied alias keeps the old name findable on the kept Subject');
  perform pg_temp.chk(lifeos.subject_check('Nick T')->'matches'->0->>'id' = keep->>'id', 'the old name resolves to the kept Subject only');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Merge: the user flag transfers, a duplicate link pair is removed -------------
do $t$
declare t constant text := 'subject_merge_user_flag_and_duplicate_links';
  keep jsonb; dup jsonb; ev jsonb; m jsonb; rl jsonb;
begin
  keep := lifeos.subject_create('{"name":"Rocher"}');
  dup  := lifeos.subject_create('{"name":"Myself","is_user":true}');
  ev   := lifeos.event_create('{"title":"Run","occurred_date":"2032-04-02"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', ev->>'id','to_type','subject','to_id', keep->>'id'));
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', ev->>'id','to_type','subject','to_id', dup->>'id'));
  m := lifeos.subject_merge(jsonb_build_object('keep_id', keep->>'id', 'merge_id', dup->>'id', 'identity', jsonb_build_object('name','Rocher')));
  perform pg_temp.chk((m->'subject'->>'is_user')::boolean, 'the kept Subject becomes the user Subject');
  rl := lifeos.record_links_read('event', (ev->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rl->'links') = 1 and rl->'links'->0->>'id' = keep->>'id', 'two links that become one pair leave a single link');
  perform pg_temp.chk(lifeos.subject_search('{"is_user":true}')->'results'->0->>'id' = keep->>'id', 'only the kept Subject is the user');
  perform lifeos.subject_delete((keep->>'id')::uuid);   -- release the user flag for later tests
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Merge rejections -----------------------------------------------------------
do $t$
declare t constant text := 'subject_merge_rejections';
  a jsonb; b jsonb; pa jsonb; pb jsonb; c jsonb; m jsonb;
begin
  a := lifeos.subject_create('{"name":"Alex A"}');
  b := lifeos.subject_create('{"name":"Alex B"}');
  pa := lifeos.communication_profile_create(jsonb_build_object('profile_key','alex-a','profile_type','person','name','Alex A','person_subject_id', a->>'id'));
  pb := lifeos.communication_profile_create(jsonb_build_object('profile_key','alex-b','profile_type','person','name','Alex B','person_subject_id', b->>'id'));
  perform pg_temp.expect_err(format($$select lifeos.subject_merge(jsonb_build_object('keep_id', %L::uuid, 'merge_id', %L::uuid, 'identity', '{"name":"Alex"}'::jsonb))$$, a->>'id', b->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.subject_merge(jsonb_build_object('keep_id', %L::uuid, 'merge_id', %L::uuid, 'identity', '{"name":"Alex"}'::jsonb))$$, a->>'id', a->>'id'), 'invalid relationship');
  perform pg_temp.expect_err(format($$select lifeos.subject_merge(jsonb_build_object('keep_id', %L::uuid, 'merge_id', gen_random_uuid(), 'identity', '{"name":"Alex"}'::jsonb))$$, a->>'id'), 'record not found');
  perform pg_temp.expect_err(format($$select lifeos.subject_merge(jsonb_build_object('keep_id', %L::uuid, 'merge_id', %L::uuid))$$, a->>'id', b->>'id'), 'invalid input');
  -- after the user removes one Profile, the merge goes through and the Profile moves to the kept Subject
  perform lifeos.communication_profile_delete((pb->>'id')::uuid);
  m := lifeos.subject_merge(jsonb_build_object('keep_id', a->>'id', 'merge_id', b->>'id', 'identity', '{"name":"Alex"}'::jsonb));
  perform pg_temp.chk(m->'subject'->>'name' = 'Alex', 'merge succeeds once one Profile is resolved');
  -- a deleted Subject cannot be merged again
  perform pg_temp.expect_err(format($$select lifeos.subject_merge(jsonb_build_object('keep_id', %L::uuid, 'merge_id', %L::uuid, 'identity', '{"name":"Alex"}'::jsonb))$$, a->>'id', b->>'id'), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Update, read with derived fields, delete ------------------------------------
do $t$
declare t constant text := 'subject_update_read_and_delete';
  s jsonb; u jsonb; r jsonb; d jsonb; p jsonb; sp jsonb;
begin
  s := lifeos.subject_create('{"name":"Surgeryxq","subject_type":"place"}');
  u := lifeos.subject_update((s->>'id')::uuid, '{"description":"Dr Lee''s clinic","tags":["health"]}');
  perform pg_temp.chk(u->>'description' = 'Dr Lee''s clinic' and u->'tags' = '["health"]'::jsonb and u->>'name' = 'Surgeryxq', 'partial update');
  u := lifeos.subject_update((s->>'id')::uuid, '{"description":null}');
  perform pg_temp.chk(u->>'description' is null, 'null clears description');
  perform pg_temp.expect_err(format($$select lifeos.subject_update(%L::uuid, '{"merged_into_id":"%s"}')$$, s->>'id', gen_random_uuid()), 'unsupported field');
  p := lifeos.subject_create('{"name":"Sam","subject_type":"person"}');
  perform lifeos.subject_create('{"name":"Me","is_user":true}');
  perform pg_temp.expect_err(format($$select lifeos.subject_update(%L::uuid, '{"is_user":true}')$$, p->>'id'), 'invalid input');
  -- derived fields on subject_read
  perform lifeos.communication_profile_create(jsonb_build_object('profile_key','sam','profile_type','person','name','Sam','person_subject_id', p->>'id'));
  sp := lifeos.story_person_create(jsonb_build_object('name','Sam in story','subject_id', p->>'id'));
  r := lifeos.subject_read((p->>'id')::uuid);
  perform pg_temp.chk(r->>'person_profile_id' is not null, 'subject_read returns person_profile_id');
  perform pg_temp.chk(r->'story_person_ids' @> jsonb_build_array(sp->>'id'), 'subject_read returns story_person_ids');
  d := lifeos.subject_delete((s->>'id')::uuid);
  perform pg_temp.chk(d->>'deleted_at' is not null, 'delete returns deleted_at');
  perform pg_temp.chk(lifeos.subject_read((s->>'id')::uuid)->>'deleted_at' is not null, 'read still returns the deleted Subject');
  perform pg_temp.chk((lifeos.subject_search('{"keyword":"Surgeryxq"}')->>'returned_count')::int = 0, 'search hides the deleted Subject');
  perform pg_temp.chk((lifeos.subject_search('{"keyword":"Surgeryxq","include_deleted":true}')->>'returned_count')::int = 1, 'include_deleted shows it');
  perform pg_temp.expect_err(format($$select lifeos.subject_update(%L::uuid, '{"name":"x"}')$$, s->>'id'), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Merge: an empty identity is rejected and changes nothing (M-0020 S2) -----------
do $t$
declare t constant text := 'subject_merge_rejects_empty_identity';
  a jsonb; b jsonb;
begin
  a := lifeos.subject_create('{"name":"Empty identity keep","subject_type":"person"}');
  b := lifeos.subject_create('{"name":"Empty identity merge","subject_type":"person"}');
  perform pg_temp.expect_err(format($$select lifeos.subject_merge(jsonb_build_object('keep_id', %L::uuid, 'merge_id', %L::uuid, 'identity', '{}'::jsonb))$$, a->>'id', b->>'id'), 'invalid input');
  perform pg_temp.chk(lifeos.subject_read((a->>'id')::uuid)->>'name' = 'Empty identity keep', 'the kept Subject is unchanged');
  perform pg_temp.chk(lifeos.subject_read((b->>'id')::uuid)->>'deleted_at' is null, 'the other Subject stays active');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Delete: a Person Subject with an active Profile is rejected (M-0021 D4) ------------------------
do $t$
declare t constant text := 'subject_delete_rejects_person_subject_with_active_profile';
  s jsonb; c jsonb; pf jsonb; d jsonb; d2 jsonb; v_msg text; v_det text;
begin
  s := lifeos.subject_create('{"name":"D4 person","subject_type":"person"}');
  c := lifeos.subject_create('{"name":"D4 correct person","subject_type":"person"}');
  pf := lifeos.communication_profile_create(jsonb_build_object('profile_key','d4-person','profile_type','person','name','D4','person_subject_id', s->>'id'));
  begin
    perform lifeos.subject_delete((s->>'id')::uuid);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_det = pg_exception_detail;
  end;
  perform pg_temp.chk(v_msg = 'invalid relationship', 'the delete returns invalid relationship, got ' || coalesce(v_msg, '<no error>'));
  perform pg_temp.chk(v_det = 'the Person Subject still has a Profile', 'the detail names the Profile, got ' || coalesce(v_det, 'null'));
  perform pg_temp.chk(lifeos.subject_read((s->>'id')::uuid)->>'deleted_at' is null, 'the Subject stays active');
  -- the Profile belongs to another person: link it to the correct Subject, then delete
  perform lifeos.communication_profile_update((pf->>'id')::uuid, jsonb_build_object('person_subject_id', c->>'id'));
  d := lifeos.subject_delete((s->>'id')::uuid);
  perform pg_temp.chk(d->>'id' = s->>'id' and d->>'deleted_at' is not null, 'the Subject is deleted after its Profile moved');
  d2 := lifeos.subject_delete((s->>'id')::uuid);
  perform pg_temp.chk(d2->>'deleted_at' = d->>'deleted_at', 'a second delete returns the existing deleted_at');
  -- the user no longer wants the Profile: delete it, then delete the Subject
  perform pg_temp.expect_err(format($$select lifeos.subject_delete(%L::uuid)$$, c->>'id'), 'invalid relationship');
  perform lifeos.communication_profile_delete((pf->>'id')::uuid);
  d := lifeos.subject_delete((c->>'id')::uuid);
  perform pg_temp.chk(d->>'deleted_at' is not null, 'a Subject whose Profile is deleted is deleted');
  perform pg_temp.expect_err($$select lifeos.subject_delete(gen_random_uuid())$$, 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
