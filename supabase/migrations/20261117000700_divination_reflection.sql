-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 7 of 10: Divination & Reflection (Contract Chapter 7)
--
-- Creates:
--   1. The internal helpers _analysis_json, _reading_json, _divination_json,
--      _story_person_json, _storyline_json, _story_person_ids, _analysis_insert
--      and _reading_insert.
--   2. The Contract functions:
--      Divination Record and Reading: divination_record_save, divination_record_read,
--        divination_search, divination_record_update, divination_record_delete,
--        reading_create, reading_story_persons_set, reading_delete.
--      Analysis: analysis_add, analysis_delete.
--      Reading Remark: reading_remark_add, reading_remark_update.
--      Story Person: story_person_create, story_person_read, story_person_search,
--        story_person_update, story_person_delete.
--      Storyline: storyline_create, storyline_read, storyline_search, storyline_update,
--        storyline_delete.
--
-- story_person_ids are stored in lifeos.reading_story_persons and
-- lifeos.storyline_story_persons (implementation note 9).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Builders
-- -----------------------------------------------------------------------------

create or replace function lifeos._analysis_json(a lifeos.analyses)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$ select lifeos._row_json(a) $$;

-- Complete Reading with story_person_ids and analyses. Analyses deleted together with the Reading stay visible on its read.
create or replace function lifeos._reading_json(r lifeos.readings, p_with_links boolean default false)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(r)
    || jsonb_build_object(
         'story_person_ids', coalesce((
            select jsonb_agg(sp.id order by rsp.created_at, sp.id)
            from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
            where rsp.reading_id = r.id and sp.deleted_at is null), '[]'::jsonb),
         'analyses', coalesce((
            select jsonb_agg(lifeos._analysis_json(a) order by a.analysis_date, a.created_at)
            from lifeos.analyses a
            where a.reading_id = r.id and (a.deleted_at is null or a.deleted_at = r.deleted_at)), '[]'::jsonb))
    || case when p_with_links then jsonb_build_object('links', lifeos._links('reading', r.id)) else '{}'::jsonb end
$$;

-- Complete Divination Record with readings and record_analyses (combined Analyses).
create or replace function lifeos._divination_json(d lifeos.divination_records, p_with_links boolean default false)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(d)
    || jsonb_build_object(
         'readings', coalesce((
            select jsonb_agg(lifeos._reading_json(r, p_with_links) order by r.reading_date, r.reading_time nulls last, r.created_at)
            from lifeos.readings r
            where r.divination_record_id = d.id and (r.deleted_at is null or r.deleted_at = d.deleted_at)), '[]'::jsonb),
         'record_analyses', coalesce((
            select jsonb_agg(lifeos._analysis_json(a) order by a.analysis_date, a.created_at)
            from lifeos.analyses a
            where a.divination_record_id = d.id and a.reading_id is null
              and (a.deleted_at is null or a.deleted_at = d.deleted_at)), '[]'::jsonb))
$$;

create or replace function lifeos._story_person_json(s lifeos.story_persons)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s)
    || jsonb_build_object('subject_id', (select x.id from lifeos.subjects x where x.id = s.subject_id and x.deleted_at is null))
$$;

create or replace function lifeos._storyline_json(s lifeos.storylines)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s)
    || jsonb_build_object('story_person_ids', coalesce((
         select jsonb_agg(sp.id order by ssp.created_at, sp.id)
         from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
         where ssp.storyline_id = s.id and sp.deleted_at is null), '[]'::jsonb))
$$;

-- -----------------------------------------------------------------------------
-- Insert helpers
-- -----------------------------------------------------------------------------

-- Validates a story_person_ids array: each value is an active Story Person.
create or replace function lifeos._story_person_ids(p jsonb)
returns uuid[] language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_ids uuid[] := lifeos._uuid_list(p);
  v_id uuid;
begin
  foreach v_id in array v_ids loop
    perform lifeos._require_active('story_persons', v_id);
  end loop;
  return v_ids;
end $$;

create or replace function lifeos._analysis_insert(p_record_id uuid, p_reading_id uuid, p_input jsonb, p_default_date date)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
begin
  perform lifeos._check_fields(v, array['source', 'overall_outcome', 'key_reasoning', 'story_context', 'analysis_date',
                                        'metadata']);
  perform lifeos._require(v, array['source', 'overall_outcome', 'key_reasoning']);
  perform lifeos._check_types(v, p_dates => array['analysis_date'], p_objects => array['metadata']);
  return lifeos._insert_row('analyses',
    jsonb_build_object('analysis_date', p_default_date)
    || lifeos._strip_top_nulls(v)
    || jsonb_build_object('divination_record_id', p_record_id, 'reading_id', p_reading_id));
end $$;

-- Validates and inserts one Reading with its story persons and Analyses. Returns the new ID.
create or replace function lifeos._reading_insert(p_record_id uuid, p_input jsonb, p_default_date date,
                                                  p_analysis_default_date date)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
  v_persons uuid[];
  v_analysis jsonb;
begin
  perform lifeos._check_fields(v, array['question', 'method', 'spread_name', 'result_text', 'reading_date', 'reading_time',
                                        'story_person_ids', 'analyses', 'metadata']);
  perform lifeos._require(v, array['question', 'method', 'result_text']);
  perform lifeos._check_types(v, p_dates => array['reading_date'], p_times => array['reading_time'],
                              p_objects => array['metadata']);
  if v ->> 'method' not in ('i_ching', 'tarot') then
    raise exception 'invalid input' using detail = 'method is i_ching or tarot';
  end if;
  if v ? 'analyses' and jsonb_typeof(v -> 'analyses') not in ('array', 'null') then
    raise exception 'invalid input' using detail = 'analyses must be an array';
  end if;
  v_persons := lifeos._story_person_ids(v -> 'story_person_ids');

  v_id := lifeos._insert_row('readings',
    jsonb_build_object('reading_date', p_default_date)
    || lifeos._strip_top_nulls(v - 'story_person_ids' - 'analyses')
    || jsonb_build_object('divination_record_id', p_record_id));

  insert into lifeos.reading_story_persons (reading_id, story_person_id)
  select v_id, u from unnest(v_persons) u;

  for v_analysis in select value from jsonb_array_elements(coalesce(nullif(v -> 'analyses', 'null'::jsonb), '[]'::jsonb)) loop
    perform lifeos._analysis_insert(p_record_id, v_id, v_analysis, p_analysis_default_date);
  end loop;
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- 7.1 Divination Record and Reading
-- -----------------------------------------------------------------------------

create or replace function lifeos.divination_record_save(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_session date;
  v_id uuid;
  v_item jsonb;
begin
  perform lifeos._check_fields(v, array['session_date', 'title', 'topic', 'metadata', 'readings', 'record_analyses']);
  perform lifeos._require(v, array['readings']);
  perform lifeos._check_types(v, p_dates => array['session_date'], p_objects => array['metadata']);
  if jsonb_typeof(v -> 'readings') <> 'array' or jsonb_array_length(v -> 'readings') = 0 then
    raise exception 'invalid input' using detail = 'readings needs at least one item';
  end if;
  if v ? 'record_analyses' and jsonb_typeof(v -> 'record_analyses') not in ('array', 'null') then
    raise exception 'invalid input' using detail = 'record_analyses must be an array';
  end if;
  v_session := coalesce((nullif(v ->> 'session_date', ''))::date, lifeos._kl_today());

  v_id := lifeos._insert_row('divination_records',
    lifeos._strip_top_nulls(v - 'readings' - 'record_analyses') || jsonb_build_object('session_date', v_session));

  for v_item in select value from jsonb_array_elements(v -> 'readings') loop
    perform lifeos._reading_insert(v_id, v_item, v_session, v_session);
  end loop;
  for v_item in select value from jsonb_array_elements(coalesce(nullif(v -> 'record_analyses', 'null'::jsonb), '[]'::jsonb)) loop
    perform lifeos._analysis_insert(v_id, null, v_item, v_session);
  end loop;

  return (select lifeos._divination_json(d, false) from lifeos.divination_records d where d.id = v_id);
end $$;

create or replace function lifeos.divination_record_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  d lifeos.divination_records;
begin
  select * into d from lifeos.divination_records where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._divination_json(d, true);
end $$;

create or replace function lifeos.divination_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_subject uuid;
  v_person uuid;
  v_method text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'subject_id', 'story_person_id', 'method', 'from_date',
                                        'to_date', 'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['subject_id', 'story_person_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_subject := (f ->> 'subject_id')::uuid;
  v_person := (f ->> 'story_person_id')::uuid;
  v_method := nullif(btrim(f ->> 'method'), '');
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  with rd as (
    select r.*
    from lifeos.readings r join lifeos.divination_records d on d.id = r.divination_record_id
    where (v_inc or (r.deleted_at is null and d.deleted_at is null))
      and (v_method is null or r.method = v_method)
      and (v_from is null or r.reading_date >= v_from)
      and (v_to is null or r.reading_date <= v_to)
      and (v_pat is null or d.title ilike v_pat or d.topic ilike v_pat or r.question ilike v_pat or r.result_text ilike v_pat)
      and (v_person is null or exists (select 1 from lifeos.reading_story_persons rsp
                                       where rsp.reading_id = r.id and rsp.story_person_id = v_person))
      and (v_subject is null
           or exists (select 1 from lifeos.record_links l
                      where (l.record_type_a = 'reading' and l.record_id_a = r.id and l.record_type_b = 'subject' and l.record_id_b = v_subject)
                         or (l.record_type_b = 'reading' and l.record_id_b = r.id and l.record_type_a = 'subject' and l.record_id_a = v_subject))
           or exists (select 1 from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
                      where rsp.reading_id = r.id and sp.subject_id = v_subject and sp.deleted_at is null))
  ), g as (
    select rd.divination_record_id as id, max(rd.reading_date) as latest
    from rd group by rd.divination_record_id
    order by latest desc, rd.divination_record_id
    limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'session_date', d.session_date,
           'title', d.title,
           'topic', d.topic,
           'deleted_at', lifeos._ts(d.deleted_at),
           'readings', (
             select jsonb_agg(jsonb_build_object(
                      'id', rd.id, 'question', rd.question, 'method', rd.method, 'result_text', rd.result_text,
                      'reading_date', rd.reading_date,
                      'analyses', coalesce((
                        select jsonb_agg(jsonb_build_object('overall_outcome', a.overall_outcome, 'source', a.source)
                                         order by a.analysis_date, a.created_at)
                        from lifeos.analyses a
                        where a.reading_id = rd.id and (v_inc or a.deleted_at is null)), '[]'::jsonb))
                    order by rd.reading_date desc, rd.reading_time desc nulls last, rd.created_at)
             from rd where rd.divination_record_id = d.id),
           'record_analyses', coalesce((
             select jsonb_agg(jsonb_build_object('overall_outcome', a.overall_outcome, 'source', a.source)
                              order by a.analysis_date, a.created_at)
             from lifeos.analyses a
             where a.divination_record_id = d.id and a.reading_id is null and (v_inc or a.deleted_at is null)), '[]'::jsonb))
         order by g.latest desc, g.id), '[]'::jsonb)
    into v_res
  from g join lifeos.divination_records d on d.id = g.id;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.divination_record_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  d lifeos.divination_records;
  v jsonb;
begin
  select * into d from lifeos.divination_records where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if d.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'topic', 'session_date', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['session_date'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['session_date'], p_objects => array['metadata']);
  perform lifeos._update_row('divination_records', p_id, v);
  return (select lifeos._divination_json(x, false) from lifeos.divination_records x where x.id = p_id);
end $$;

create or replace function lifeos.divination_record_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  d lifeos.divination_records;
  v_now timestamptz := now();
begin
  select * into d from lifeos.divination_records where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if d.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(d.deleted_at));
  end if;
  update lifeos.divination_records set deleted_at = v_now, updated_at = v_now where id = p_id;
  update lifeos.readings set deleted_at = v_now, updated_at = v_now
   where divination_record_id = p_id and deleted_at is null;
  update lifeos.analyses set deleted_at = v_now, updated_at = v_now
   where divination_record_id = p_id and deleted_at is null;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_now));
end $$;

create or replace function lifeos.reading_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_record uuid;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['divination_record_id', 'question', 'method', 'spread_name', 'result_text',
                                        'reading_date', 'reading_time', 'story_person_ids', 'analyses', 'metadata']);
  perform lifeos._require(v, array['divination_record_id', 'question', 'method', 'result_text']);
  perform lifeos._check_types(v, p_uuids => array['divination_record_id']);
  v_record := (v ->> 'divination_record_id')::uuid;
  perform lifeos._require_active('divination_records', v_record);
  v_id := lifeos._reading_insert(v_record, v - 'divination_record_id', lifeos._kl_today(), lifeos._kl_today());
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = v_id);
end $$;

create or replace function lifeos.reading_story_persons_set(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_persons uuid[];
begin
  perform lifeos._check_fields(v, array['story_person_ids']);
  if not (v ? 'story_person_ids') or jsonb_typeof(v -> 'story_person_ids') <> 'array' then
    raise exception 'invalid input' using detail = 'story_person_ids is a required array';
  end if;
  perform lifeos._require_active('readings', p_id);
  v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
  delete from lifeos.reading_story_persons where reading_id = p_id;
  insert into lifeos.reading_story_persons (reading_id, story_person_id) select p_id, u from unnest(v_persons) u;
  update lifeos.readings set updated_at = now() where id = p_id;
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = p_id);
end $$;

create or replace function lifeos.reading_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  r lifeos.readings;
  v_now timestamptz := now();
begin
  select * into r from lifeos.readings where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(r.deleted_at));
  end if;
  update lifeos.readings set deleted_at = v_now, updated_at = v_now where id = p_id;
  update lifeos.analyses set deleted_at = v_now, updated_at = v_now where reading_id = p_id and deleted_at is null;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_now));
end $$;

-- -----------------------------------------------------------------------------
-- 7.2 Analysis
-- -----------------------------------------------------------------------------

create or replace function lifeos.analysis_add(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  r lifeos.readings;
  v_record uuid;
  v_reading uuid;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['reading_id', 'divination_record_id', 'source', 'overall_outcome', 'key_reasoning',
                                        'story_context', 'analysis_date', 'metadata']);
  perform lifeos._check_types(v, p_uuids => array['reading_id', 'divination_record_id']);
  v := lifeos._strip_top_nulls(v);
  if not (v ? 'reading_id') and not (v ? 'divination_record_id') then
    raise exception 'invalid input' using detail = 'reading_id or divination_record_id is required';
  end if;
  if v ? 'reading_id' then
    v_reading := (v ->> 'reading_id')::uuid;
    select * into r from lifeos.readings where id = v_reading;
    if not found then
      raise exception 'record not found' using detail = 'reading_id';
    end if;
    if r.deleted_at is not null then
      raise exception 'record deleted' using detail = 'reading_id';
    end if;
    if v ? 'divination_record_id' and (v ->> 'divination_record_id')::uuid <> r.divination_record_id then
      raise exception 'invalid relationship' using detail = 'the Reading belongs to another Divination Record';
    end if;
    v_record := r.divination_record_id;
  else
    v_record := (v ->> 'divination_record_id')::uuid;
  end if;
  perform lifeos._require_active('divination_records', v_record);
  v_id := lifeos._analysis_insert(v_record, v_reading, v - 'reading_id' - 'divination_record_id', lifeos._kl_today());
  return (select lifeos._analysis_json(a) from lifeos.analyses a where a.id = v_id);
end $$;

create or replace function lifeos.analysis_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('analyses', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 7.3 Reading Remark
-- -----------------------------------------------------------------------------

create or replace function lifeos.reading_remark_add(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
begin
  perform lifeos._check_fields(v, array['text', 'storyline_id']);
  perform lifeos._require(v, array['text']);
  perform lifeos._check_types(v, p_uuids => array['storyline_id']);
  perform lifeos._require_active('readings', p_id);
  update lifeos.readings
     set remark_entries = remark_entries || jsonb_build_array(jsonb_build_object(
           'entry_id', gen_random_uuid(),
           'timestamp', lifeos._ts(now()),
           'storyline_id', nullif(v ->> 'storyline_id', '')::uuid,
           'text', btrim(v ->> 'text'))),
         updated_at = now()
   where id = p_id;
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = p_id);
end $$;

create or replace function lifeos.reading_remark_update(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  r lifeos.readings;
  v_index integer;
  v_entry jsonb;
begin
  perform lifeos._check_fields(v, array['entry_id', 'text', 'storyline_id']);
  perform lifeos._require(v, array['entry_id']);
  perform lifeos._check_types(v, p_uuids => array['entry_id', 'storyline_id']);
  if not (v ? 'text') and not (v ? 'storyline_id') then
    raise exception 'invalid input' using detail = 'text or storyline_id is required';
  end if;
  if v ? 'text' and coalesce(btrim(v ->> 'text'), '') = '' then
    raise exception 'invalid input' using detail = 'text cannot be empty';
  end if;
  select * into r from lifeos.readings where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  select e.ord - 1, e.value into v_index, v_entry
  from jsonb_array_elements(r.remark_entries) with ordinality e(value, ord)
  where e.value ->> 'entry_id' = v ->> 'entry_id';
  if v_index is null then
    raise exception 'record not found' using detail = 'entry_id';
  end if;
  if v ? 'text' then
    v_entry := jsonb_set(v_entry, '{text}', to_jsonb(btrim(v ->> 'text')));
  end if;
  if v ? 'storyline_id' then
    v_entry := jsonb_set(v_entry, '{storyline_id}', coalesce(v -> 'storyline_id', 'null'::jsonb));
  end if;
  update lifeos.readings
     set remark_entries = jsonb_set(remark_entries, array[v_index::text], v_entry), updated_at = now()
   where id = p_id;
  return (select lifeos._reading_json(x, false) from lifeos.readings x where x.id = p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 7.4 Story Person
-- -----------------------------------------------------------------------------

create or replace function lifeos.story_person_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['name', 'gender', 'description', 'aliases', 'subject_id', 'metadata']);
  perform lifeos._require(v, array['name']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['subject_id'], p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);
  if v ? 'subject_id' then
    perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  end if;
  v_id := lifeos._insert_row('story_persons', v);
  return (select lifeos._story_person_json(s) from lifeos.story_persons s where s.id = v_id);
end $$;

create or replace function lifeos.story_person_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.story_persons;
begin
  select * into s from lifeos.story_persons where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._story_person_json(s) || jsonb_build_object(
    'storyline_ids', coalesce((
      select jsonb_agg(sl.id order by sl.occurrence_date desc nulls last, sl.created_at desc)
      from lifeos.storyline_story_persons ssp join lifeos.storylines sl on sl.id = ssp.storyline_id
      where ssp.story_person_id = p_id and sl.deleted_at is null), '[]'::jsonb),
    'reading_ids', coalesce((
      select jsonb_agg(r.id order by r.reading_date desc, r.created_at desc)
      from lifeos.reading_story_persons rsp join lifeos.readings r on r.id = rsp.reading_id
      where rsp.story_person_id = p_id and r.deleted_at is null), '[]'::jsonb));
end $$;

create or replace function lifeos.story_person_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_gender text;
  v_subject uuid;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'gender', 'subject_id', 'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['subject_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_gender := nullif(btrim(f ->> 'gender'), '');
  v_subject := (f ->> 'subject_id')::uuid;

  select coalesce(jsonb_agg(lifeos._story_person_json(s) order by s.updated_at desc, s.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.story_persons s
    where (v_inc or s.deleted_at is null)
      and (v_gender is null or lower(s.gender) = lower(v_gender))
      and (v_subject is null or s.subject_id = v_subject)
      and (v_pat is null or s.name ilike v_pat or s.description ilike v_pat or lifeos._array_match(s.aliases, v_pat))
    order by s.updated_at desc, s.id
    limit v_limit offset v_offset
  ) s;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.story_person_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.story_persons;
  v jsonb;
begin
  select * into s from lifeos.story_persons where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['name', 'gender', 'description', 'aliases', 'subject_id', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['subject_id'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['name'], p_arrays => array['aliases'], p_objects => array['metadata']);
  if v ? 'subject_id' and jsonb_typeof(v -> 'subject_id') <> 'null' then
    perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  end if;
  perform lifeos._update_row('story_persons', p_id, v);
  return (select lifeos._story_person_json(x) from lifeos.story_persons x where x.id = p_id);
end $$;

create or replace function lifeos.story_person_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('story_persons', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 7.5 Storyline
-- -----------------------------------------------------------------------------

create or replace function lifeos.storyline_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_persons uuid[];
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['title', 'content', 'occurrence_date', 'occurrence_end_date', 'time_text',
                                        'story_person_ids', 'metadata']);
  perform lifeos._require(v, array['content']);
  perform lifeos._check_types(v, p_dates => array['occurrence_date', 'occurrence_end_date'], p_objects => array['metadata']);
  v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
  v_id := lifeos._insert_row('storylines', lifeos._strip_top_nulls(v - 'story_person_ids'));
  insert into lifeos.storyline_story_persons (storyline_id, story_person_id) select v_id, u from unnest(v_persons) u;
  return (select lifeos._storyline_json(s) from lifeos.storylines s where s.id = v_id);
end $$;

create or replace function lifeos.storyline_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.storylines;
begin
  select * into s from lifeos.storylines where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._storyline_json(s) || jsonb_build_object('links', lifeos._links('storyline', p_id));
end $$;

create or replace function lifeos.storyline_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_persons uuid[];
  v_match text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['story_person_ids', 'person_match', 'keyword', 'query', 'from_date', 'to_date',
                                        'include_deleted', 'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_persons := case when f ? 'story_person_ids' and jsonb_typeof(f -> 'story_person_ids') <> 'null'
                    then lifeos._uuid_list(f -> 'story_person_ids') end;
  if cardinality(v_persons) = 0 then
    v_persons := null;
  end if;
  v_match := coalesce(nullif(btrim(f ->> 'person_match'), ''), 'any');
  if v_match not in ('any', 'all') then
    raise exception 'invalid input' using detail = 'person_match is any or all';
  end if;
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._storyline_json(x) || jsonb_build_object('matched_person_ids', to_jsonb(s.matched))
                            order by s.occurrence_date desc nulls last, s.created_at desc, s.id), '[]'::jsonb)
    into v_res
  from (
    select sl.id, sl.occurrence_date, sl.created_at, m.matched
    from lifeos.storylines sl
    cross join lateral (
      select coalesce(array_agg(ssp.story_person_id order by ssp.story_person_id), '{}'::uuid[]) as matched
      from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
      where ssp.storyline_id = sl.id and sp.deleted_at is null
        and v_persons is not null and ssp.story_person_id = any (v_persons)
    ) m
    where (v_inc or sl.deleted_at is null)
      and (v_persons is null
           or (v_match = 'any' and cardinality(m.matched) > 0)
           or (v_match = 'all' and cardinality(m.matched) = cardinality(v_persons)))
      and (v_pat is null or sl.title ilike v_pat or sl.content ilike v_pat or sl.time_text ilike v_pat)
      and ((v_from is null and v_to is null)
           or (sl.occurrence_date is not null
               and (v_from is null or sl.occurrence_date >= v_from)
               and (v_to is null or sl.occurrence_date <= v_to)))
    order by sl.occurrence_date desc nulls last, sl.created_at desc, sl.id
    limit v_limit offset v_offset
  ) s
  join lifeos.storylines x on x.id = s.id;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.storyline_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.storylines;
  v jsonb;
  v_persons uuid[];
begin
  select * into s from lifeos.storylines where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'content', 'occurrence_date', 'occurrence_end_date', 'time_text',
                                               'story_person_ids', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['occurrence_date', 'occurrence_end_date'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['content'], p_objects => array['metadata']);
  if v ? 'story_person_ids' then
    v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
    delete from lifeos.storyline_story_persons where storyline_id = p_id;
    insert into lifeos.storyline_story_persons (storyline_id, story_person_id) select p_id, u from unnest(v_persons) u;
  end if;
  perform lifeos._update_row('storylines', p_id, v - 'story_person_ids');
  return (select lifeos._storyline_json(x) from lifeos.storylines x where x.id = p_id);
end $$;

create or replace function lifeos.storyline_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('storylines', p_id);
end $$;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
