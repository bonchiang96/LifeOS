-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 2 of 10: LifeOS Memory (Contract Chapter 2)
--
-- Creates the Contract functions:
--   memory_create, memory_read, memory_search, memory_update, memory_delete.
--
-- Uses the table lifeos.memories and the helpers of migration 1.
-- =============================================================================

create or replace function lifeos.memory_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
  r lifeos.memories;
begin
  perform lifeos._check_fields(v, array['title', 'content', 'categories', 'tags', 'metadata']);
  perform lifeos._require(v, array['content']);
  perform lifeos._check_types(v, p_arrays => array['categories', 'tags'], p_objects => array['metadata']);
  v_id := lifeos._insert_row('memories', lifeos._strip_top_nulls(v));
  select * into r from lifeos.memories where id = v_id;
  return lifeos._row_json(r);
end $$;

create or replace function lifeos.memory_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  r lifeos.memories;
begin
  select * into r from lifeos.memories where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._row_json(r);
end $$;

create or replace function lifeos.memory_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_cats text[];
  v_tags text[];
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'categories', 'tags', 'include_deleted', 'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_cats := lifeos._text_list(f -> 'categories');
  v_tags := lifeos._text_list(f -> 'tags');

  select coalesce(jsonb_agg(lifeos._row_json(m) order by m.updated_at desc, m.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.memories m
    where (v_inc or m.deleted_at is null)
      and (v_pat is null or m.title ilike v_pat or m.content ilike v_pat)
      and (v_cats is null or m.categories && v_cats)
      and (v_tags is null or m.tags && v_tags)
    order by m.updated_at desc, m.id
    limit v_limit offset v_offset
  ) m;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.memory_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  r lifeos.memories;
begin
  select * into r from lifeos.memories where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'content', 'categories', 'tags', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['categories', 'tags'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['content'], p_arrays => array['categories', 'tags'],
                            p_objects => array['metadata']);
  perform lifeos._update_row('memories', p_id, v);
  select * into r from lifeos.memories where id = p_id;
  return lifeos._row_json(r);
end $$;

create or replace function lifeos.memory_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('memories', p_id);
end $$;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
