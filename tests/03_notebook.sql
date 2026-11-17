-- =============================================================================
-- tests/03_notebook.sql -- Module: Notebook (Contract Chapter 3)
--
-- Tests in this file:
--   1. notebook_initialise_on_read_catalog_names
--   2. notebook_defaults_holds_currency_myr
--   3. notebook_custom_key_and_name
--   4. notebook_key_format_rejected
--   5. notebook_update_replaces_and_initialises
--   6. notebook_list_keyword_and_order
--
-- Single transaction: begin; tests; select results; rollback.
-- Run: see tests/README.md.
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

-- 1. A catalog Notebook that does not exist is created empty on read ------------
do $t$
declare t constant text := 'notebook_initialise_on_read_catalog_names';
  k text; expected_name text; r jsonb; r2 jsonb;
begin
  foreach k in array array['subject_types','subject_tags','expense_tags','note_types'] loop
    expected_name := case k when 'subject_types' then 'Subject Types' when 'subject_tags' then 'Subject Tags'
                            when 'expense_tags' then 'Expense Tags' else 'Note Types' end;
    r := lifeos.notebook_read(k);
    perform pg_temp.chk((r->>'initialised')::boolean, k || ': first read initialises');
    perform pg_temp.chk(r->>'name' = expected_name, k || ': catalog name is ' || expected_name || ', got ' || (r->>'name'));
    perform pg_temp.chk(r->>'content' = '', k || ': a new Notebook starts empty');
    r2 := lifeos.notebook_read(k);
    perform pg_temp.chk(not (r2->>'initialised')::boolean, k || ': second read does not initialise');
    perform pg_temp.chk(r2->>'created_at' = r->>'created_at', k || ': second read returns the Notebook unchanged');
  end loop;
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. The defaults Notebook holds the default currency ---------------------------
do $t$
declare t constant text := 'notebook_defaults_holds_currency_myr';
  r jsonb;
begin
  r := lifeos.notebook_read('defaults');
  perform pg_temp.chk(r->>'key' = 'defaults' and r->>'name' = 'Defaults', 'defaults Notebook is named Defaults');
  perform pg_temp.chk(r->>'content' = 'currency: MYR', 'defaults content is "currency: MYR", got "' || (r->>'content') || '"');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. A key outside the catalog takes the key as name, or the supplied name ------
do $t$
declare t constant text := 'notebook_custom_key_and_name';
  r jsonb;
begin
  r := lifeos.notebook_read('zz_free_key');
  perform pg_temp.chk((r->>'initialised')::boolean and r->>'name' = 'zz_free_key', 'unknown key takes the key as its name');
  r := lifeos.notebook_read('zz_named_key', 'My Vocabulary');
  perform pg_temp.chk((r->>'initialised')::boolean and r->>'name' = 'My Vocabulary', 'p_name names a new Notebook');
  r := lifeos.notebook_read('zz_named_key', 'Ignored Name');
  perform pg_temp.chk(not (r->>'initialised')::boolean and r->>'name' = 'My Vocabulary', 'p_name is ignored for an existing Notebook');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. A key must match ^[a-z][a-z0-9_]*$ -----------------------------------------
do $t$
declare t constant text := 'notebook_key_format_rejected';
  bad text; e text;
begin
  foreach bad in array array['Bad Key','1abc','UPPER','has-dash',''] loop
    e := pg_temp.err_of(format('select lifeos.notebook_read(%L)', bad));
    perform pg_temp.chk(e is not null, format('key "%s" is rejected', bad));
  end loop;
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. notebook_update replaces content, and initialises a missing key first -------
do $t$
declare t constant text := 'notebook_update_replaces_and_initialises';
  r jsonb;
begin
  perform lifeos.notebook_read('note_types');
  r := lifeos.notebook_update('note_types', '{"content":"Idea\nFeeling\nExperience"}');
  perform pg_temp.chk(r->>'content' = E'Idea\nFeeling\nExperience', 'content replaced');
  r := lifeos.notebook_update('note_types', '{"content":"Idea"}');
  perform pg_temp.chk(r->>'content' = 'Idea', 'a later update replaces the whole content');
  r := lifeos.notebook_update('note_types', '{"name":"Types of Note"}');
  perform pg_temp.chk(r->>'name' = 'Types of Note' and r->>'content' = 'Idea', 'name changes alone keep the content');
  r := lifeos.notebook_update('zz_new_by_update', '{"content":"hello"}');
  perform pg_temp.chk(r->>'key' = 'zz_new_by_update' and r->>'content' = 'hello', 'a missing key is initialised, then updated');
  perform pg_temp.expect_err($$select lifeos.notebook_update('note_types', '{"bogus":1}')$$, 'unsupported field');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. notebook_list keyword and key order ----------------------------------------
do $t$
declare t constant text := 'notebook_list_keyword_and_order';
  r jsonb;
begin
  perform lifeos.notebook_update('zz_b_list', '{"name":"Bravo","content":"uniquecontentmarker"}');
  perform lifeos.notebook_update('zz_a_list', '{"name":"Alpha","content":"other"}');
  r := lifeos.notebook_list('{"keyword":"_list"}');
  perform pg_temp.chk((r->>'returned_count')::int = 2, 'keyword matches key');
  perform pg_temp.chk(r->'results'->0->>'key' = 'zz_a_list' and r->'results'->1->>'key' = 'zz_b_list', 'results ordered by key');
  perform pg_temp.chk((r->'results'->1->>'content_length')::int = length('uniquecontentmarker'), 'content_length reported');
  perform pg_temp.chk(not (r->'results'->0 ? 'content'), 'list items carry no full content');
  r := lifeos.notebook_list('{"keyword":"uniquecontentmarker"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1, 'keyword matches content');
  r := lifeos.notebook_list('{"keyword":"Bravo"}');
  perform pg_temp.chk((r->>'returned_count')::int = 1, 'keyword matches name');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
