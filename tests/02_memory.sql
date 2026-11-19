-- =============================================================================
-- tests/02_memory.sql -- Module: LifeOS Memory (Contract lifeos-memory.md Chapter 2)
--
-- Tests in this file:
--   1. memory_create_defaults_and_read
--   2. memory_create_rejects_bad_input
--   3. memory_search_keyword_categories_tags
--   4. memory_search_order_paging_and_deleted
--   5. memory_update_partial_and_delete
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

-- 1. Memory save with defaults, and exact read ---------------------------------
do $t$
declare t constant text := 'memory_create_defaults_and_read';
  m jsonb; r jsonb;
begin
  m := lifeos.memory_create(jsonb_build_object('content', 'Always reply in Mandarin to Mum'));
  perform pg_temp.chk(m->>'id' is not null, 'id returned');
  perform pg_temp.chk(m->>'title' is null, 'title defaults to null');
  perform pg_temp.chk(m->'categories' = '[]'::jsonb, 'categories default []');
  perform pg_temp.chk(m->'tags' = '[]'::jsonb, 'tags default []');
  perform pg_temp.chk(m->'metadata' = '{}'::jsonb, 'metadata defaults {}');
  perform pg_temp.chk(m->>'deleted_at' is null, 'deleted_at null');
  perform pg_temp.chk(m ? 'created_at' and m ? 'updated_at', 'created_at and updated_at present');
  r := lifeos.memory_read((m->>'id')::uuid);
  perform pg_temp.chk(r->>'content' = 'Always reply in Mandarin to Mum', 'read returns the content');
  perform pg_temp.expect_err('select lifeos.memory_read(gen_random_uuid())', 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Memory validation errors ---------------------------------------------------
do $t$
declare t constant text := 'memory_create_rejects_bad_input';
begin
  perform pg_temp.expect_err($$select lifeos.memory_create('{"title":"no content"}'::jsonb)$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.memory_create('{"content":"x","source_record_id":"abc"}'::jsonb)$$, 'unsupported field');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Memory search by keyword, categories and tags ----------------------------
do $t$
declare t constant text := 'memory_search_keyword_categories_tags';
  a uuid; b uuid; c uuid; r jsonb;
begin
  a := (lifeos.memory_create(jsonb_build_object('title','Tone with Mum','content','Use a gentle TONE with Mum',
        'categories', jsonb_build_array('User Operating Rules','Behavioural Patterns'), 'tags', jsonb_build_array('mum','tone'))))->>'id';
  b := (lifeos.memory_create(jsonb_build_object('title','Vocabulary','content','Say "kopi" for coffee',
        'categories', jsonb_build_array('Vocabulary'), 'tags', jsonb_build_array('food'))))->>'id';
  c := (lifeos.memory_create(jsonb_build_object('content','Plain memory zzqq-unique')))->>'id';

  r := lifeos.memory_search(jsonb_build_object('keyword', 'tone'));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = a::text, 'keyword is case-insensitive over title and content');
  perform pg_temp.chk(r->>'limit' = '20' and r->>'offset' = '0', 'default limit 20 and offset 0');
  perform pg_temp.chk(r ? 'include_deleted' and r->>'include_deleted' = 'false', 'include_deleted returned and false');

  r := lifeos.memory_search(jsonb_build_object('categories', jsonb_build_array('Vocabulary','Processing Conventions')));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = b::text, 'a Memory matches when it holds at least one supplied category');

  r := lifeos.memory_search(jsonb_build_object('categories', jsonb_build_array('User Operating Rules'), 'tags', jsonb_build_array('food')));
  perform pg_temp.chk((r->>'returned_count')::int = 0, 'category and tag arrays both need a match');

  r := lifeos.memory_search(jsonb_build_object('categories', jsonb_build_array('User Operating Rules'), 'tags', jsonb_build_array('tone','food')));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = a::text, 'one tag of the array is enough');

  r := lifeos.memory_search(jsonb_build_object('query', 'zzqq-unique'));
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = c::text, 'query is an alias of keyword');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Memory ordering, paging and deleted Memories ------------------------------
do $t$
declare t constant text := 'memory_search_order_paging_and_deleted';
  a uuid; b uuid; c uuid; r jsonb;
begin
  a := (lifeos.memory_create('{"content":"ordertest alpha"}'))->>'id';
  b := (lifeos.memory_create('{"content":"ordertest beta"}'))->>'id';
  c := (lifeos.memory_create('{"content":"ordertest gamma"}'))->>'id';
  -- Test setup: a transaction has one clock value, so spread updated_at directly.
  update lifeos.memories set updated_at = now() - interval '3 days' where id = a;
  update lifeos.memories set updated_at = now() - interval '2 days' where id = b;
  update lifeos.memories set updated_at = now() - interval '1 day'  where id = c;

  r := lifeos.memory_search('{"keyword":"ordertest"}');
  perform pg_temp.chk(r->'results'->0->>'id' = c::text and r->'results'->1->>'id' = b::text and r->'results'->2->>'id' = a::text,
    'results ordered by updated_at descending');

  r := lifeos.memory_search('{"keyword":"ordertest","limit":1,"offset":1}');
  perform pg_temp.chk((r->>'returned_count')::int = 1 and r->'results'->0->>'id' = b::text and r->>'limit' = '1' and r->>'offset' = '1',
    'limit and offset page the results');

  perform lifeos.memory_delete(b);
  r := lifeos.memory_search('{"keyword":"ordertest"}');
  perform pg_temp.chk((r->>'returned_count')::int = 2, 'deleted Memory is hidden by default');
  r := lifeos.memory_search('{"keyword":"ordertest","include_deleted":true}');
  perform pg_temp.chk((r->>'returned_count')::int = 3 and (r->>'include_deleted')::boolean, 'include_deleted shows the deleted Memory');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Memory update (partial) and soft delete -----------------------------------
do $t$
declare t constant text := 'memory_update_partial_and_delete';
  id uuid; u jsonb; d1 jsonb; d2 jsonb; r jsonb;
begin
  id := (lifeos.memory_create('{"title":"Old","content":"First","categories":["Vocabulary"],"tags":["a","b"]}'))->>'id';
  u := lifeos.memory_update(id, '{"content":"Second"}');
  perform pg_temp.chk(u->>'content' = 'Second' and u->>'title' = 'Old' and u->'tags' = '["a","b"]'::jsonb, 'omitted fields stay unchanged');
  u := lifeos.memory_update(id, '{"title":null,"tags":["c"]}');
  perform pg_temp.chk(u->>'title' is null, 'null clears an optional field');
  perform pg_temp.chk(u->'tags' = '["c"]'::jsonb, 'a supplied array replaces the stored array');
  perform pg_temp.expect_err(format($$select lifeos.memory_update(%L::uuid, '{}'::jsonb)$$, id), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.memory_update(%L::uuid, '{"bogus":1}'::jsonb)$$, id), 'unsupported field');

  d1 := lifeos.memory_delete(id);
  perform pg_temp.chk(d1->>'id' = id::text and d1->>'deleted_at' is not null, 'delete returns id and deleted_at');
  d2 := lifeos.memory_delete(id);
  perform pg_temp.chk(d2->>'deleted_at' = d1->>'deleted_at', 'second delete returns the existing deleted_at');
  r := lifeos.memory_read(id);
  perform pg_temp.chk(r->>'deleted_at' is not null, 'read still returns the deleted Memory');
  perform pg_temp.expect_err(format($$select lifeos.memory_update(%L::uuid, '{"content":"x"}'::jsonb)$$, id), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
