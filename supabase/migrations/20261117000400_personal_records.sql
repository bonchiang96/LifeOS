-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 4 of 10: Personal Records (Contract Chapter 4)
--
-- Creates:
--   1. The internal Record builders _schedule_json, _event_json, _observation_json
--      and _note_json, the insert helper _schedule_insert, and the shared link helpers
--      _target_info, _links and _record_json that later Chapters also use.
--   2. The Contract functions:
--      Schedule: schedule_create, schedule_create_series, schedule_read, schedule_search,
--        schedule_update, schedule_update_series, schedule_stop_series,
--        schedule_overdue_check, schedule_delete.
--      Event: event_create, event_link_schedule, event_read, event_search, event_update,
--        event_delete.
--      Observation: observation_create, observation_read, observation_search,
--        observation_update, observation_delete.
--      Note: note_create, note_read, note_search, note_update, note_delete.
--      Record links: record_link_create, record_link_delete, record_links_read.
--      Remarks: record_add_remark.
--
-- Uses the tables of migration 1. The builders of later Chapters resolve at call time.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Record builders
-- -----------------------------------------------------------------------------

create or replace function lifeos._schedule_json(s lifeos.schedules)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s) || jsonb_build_object('linked_event_id',
    (select e.id from lifeos.events e where e.schedule_id = s.id and e.deleted_at is null limit 1))
$$;

create or replace function lifeos._observation_json(o lifeos.observations)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(o)
    || jsonb_build_object(
         'subject_id', (select x.id from lifeos.subjects x where x.id = o.subject_id and x.deleted_at is null),
         'event_id', (select x.id from lifeos.events x where x.id = o.event_id and x.deleted_at is null))
$$;

create or replace function lifeos._event_json(e lifeos.events)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(e)
    || jsonb_build_object(
         'schedule_id', (select s.id from lifeos.schedules s where s.id = e.schedule_id and s.deleted_at is null),
         'observations', coalesce((
            select jsonb_agg(lifeos._observation_json(o) order by o.observed_date, o.observed_time nulls last, o.created_at)
            from lifeos.observations o where o.event_id = e.id and o.deleted_at is null), '[]'::jsonb))
$$;

create or replace function lifeos._note_json(n lifeos.notes)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(n) || jsonb_build_object('note_date', lifeos._kl_date(coalesce(n.edited_at, n.created_at)))
$$;

-- -----------------------------------------------------------------------------
-- Link helpers (Contract 4.5.3)
-- -----------------------------------------------------------------------------

-- Summary and occurrence date of an active link target. null when the target is missing or deleted.
create or replace function lifeos._target_info(p_type text, p_id uuid)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_summary text;
  v_date date;
  v_found boolean;
begin
  case p_type
    when 'schedule' then
      select true, s.title, s.planned_date into v_found, v_summary, v_date
      from lifeos.schedules s where s.id = p_id and s.deleted_at is null;
    when 'event' then
      select true, e.title, e.occurred_date into v_found, v_summary, v_date
      from lifeos.events e where e.id = p_id and e.deleted_at is null;
    when 'observation' then
      select true,
             o.observation_name || ': ' || coalesce(o.value_numeric::text || coalesce(' ' || o.unit, ''), o.value_text),
             o.observed_date
        into v_found, v_summary, v_date
      from lifeos.observations o where o.id = p_id and o.deleted_at is null;
    when 'note' then
      select true, coalesce(n.title, left(n.content, 200)), lifeos._kl_date(coalesce(n.edited_at, n.created_at))
        into v_found, v_summary, v_date
      from lifeos.notes n where n.id = p_id and n.deleted_at is null;
    when 'expense' then
      select true,
             concat_ws(' ', coalesce(x.merchant_name, case when x.expense_type = 'refund' then 'Refund' else 'Expense' end),
                       x.currency, x.expense_total::text),
             x.transaction_date
        into v_found, v_summary, v_date
      from lifeos.expenses x where x.id = p_id and x.deleted_at is null;
    when 'subject' then
      select true, s.name, null::date into v_found, v_summary, v_date
      from lifeos.subjects s where s.id = p_id and s.deleted_at is null;
    when 'divination_record' then
      select true, coalesce(d.title, d.topic, 'Divination Record'), d.session_date into v_found, v_summary, v_date
      from lifeos.divination_records d where d.id = p_id and d.deleted_at is null;
    when 'reading' then
      select true, left(r.question, 200), r.reading_date into v_found, v_summary, v_date
      from lifeos.readings r join lifeos.divination_records d on d.id = r.divination_record_id
      where r.id = p_id and r.deleted_at is null and d.deleted_at is null;
    when 'storyline' then
      select true, coalesce(s.title, left(s.content, 200)), s.occurrence_date into v_found, v_summary, v_date
      from lifeos.storylines s where s.id = p_id and s.deleted_at is null;
    when 'story_person' then
      select true, s.name, null::date into v_found, v_summary, v_date
      from lifeos.story_persons s where s.id = p_id and s.deleted_at is null;
    when 'communication_profile' then
      select true, p.name, null::date into v_found, v_summary, v_date
      from lifeos.communication_profiles p where p.id = p_id and p.deleted_at is null;
    when 'communication_message' then
      select true, left(m.message_text, 200), lifeos._kl_date(m.finalized_at) into v_found, v_summary, v_date
      from lifeos.communication_messages m where m.id = p_id and m.deleted_at is null;
    else
      return null;
  end case;
  if v_found is null then
    return null;
  end if;
  return jsonb_build_object('summary', v_summary, 'occurrence_date', v_date);
end $$;

-- Every active Record linked to one Record: Record links in both directions and typed reference fields.
create or replace function lifeos._links(p_type text, p_id uuid)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  with c(via, record_type, id) as (
    -- Record links, both directions
    select 'record_link',
           case when l.record_type_a = p_type and l.record_id_a = p_id then l.record_type_b else l.record_type_a end,
           case when l.record_type_a = p_type and l.record_id_a = p_id then l.record_id_b else l.record_id_a end
    from lifeos.record_links l
    where (l.record_type_a = p_type and l.record_id_a = p_id) or (l.record_type_b = p_type and l.record_id_b = p_id)
    -- Schedule -> its Event
    union all
    select 'event', 'event', e.id from lifeos.events e where p_type = 'schedule' and e.schedule_id = p_id
    -- Event -> its Schedule and Observations
    union all
    select 'schedule', 'schedule', e.schedule_id from lifeos.events e
    where p_type = 'event' and e.id = p_id and e.schedule_id is not null
    union all
    select 'observation_event', 'observation', o.id from lifeos.observations o where p_type = 'event' and o.event_id = p_id
    -- Observation -> Subject and Event
    union all
    select 'observation_subject', 'subject', o.subject_id from lifeos.observations o where p_type = 'observation' and o.id = p_id
    union all
    select 'observation_event', 'event', o.event_id from lifeos.observations o
    where p_type = 'observation' and o.id = p_id and o.event_id is not null
    -- Expense -> Subjects, original and Refunds
    union all
    select 'payment_method', 'subject', x.payment_method_subject_id from lifeos.expenses x where p_type = 'expense' and x.id = p_id
    union all
    select 'merchant', 'subject', x.merchant_subject_id from lifeos.expenses x
    where p_type = 'expense' and x.id = p_id and x.merchant_subject_id is not null
    union all
    select distinct 'line_item', 'subject', l.item_subject_id from lifeos.expense_lines l
    where p_type = 'expense' and l.expense_id = p_id and l.item_subject_id is not null
    union all
    select 'refund_of', 'expense', x.refund_of from lifeos.expenses x where p_type = 'expense' and x.id = p_id and x.refund_of is not null
    union all
    select 'refund_of', 'expense', x.id from lifeos.expenses x where p_type = 'expense' and x.refund_of = p_id
    -- Subject -> referring Records
    union all
    select 'observation_subject', 'observation', o.id from lifeos.observations o where p_type = 'subject' and o.subject_id = p_id
    union all
    select 'payment_method', 'expense', x.id from lifeos.expenses x where p_type = 'subject' and x.payment_method_subject_id = p_id
    union all
    select 'merchant', 'expense', x.id from lifeos.expenses x where p_type = 'subject' and x.merchant_subject_id = p_id
    union all
    select distinct 'line_item', 'expense', l.expense_id from lifeos.expense_lines l where p_type = 'subject' and l.item_subject_id = p_id
    union all
    select 'story_person_subject', 'story_person', s.id from lifeos.story_persons s where p_type = 'subject' and s.subject_id = p_id
    union all
    select 'person_profile_subject', 'communication_profile', p.id from lifeos.communication_profiles p
    where p_type = 'subject' and p.person_subject_id = p_id
    -- Reading and Storyline -> Subjects of their Story Persons
    union all
    select distinct 'story_person_subject', 'subject', sp.subject_id
    from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
    where p_type = 'reading' and rsp.reading_id = p_id and sp.deleted_at is null and sp.subject_id is not null
    union all
    select distinct 'story_person_subject', 'subject', sp.subject_id
    from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
    where p_type = 'storyline' and ssp.storyline_id = p_id and sp.deleted_at is null and sp.subject_id is not null
    -- Communication Message -> Subject of its Person Profile (used by timeline)
    union all
    select 'person_profile_subject', 'subject', p.person_subject_id
    from lifeos.communication_messages m join lifeos.communication_profiles p on p.id = m.profile_id
    where p_type = 'communication_message' and m.id = p_id and p.deleted_at is null and p.person_subject_id is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object('via', c.via, 'record_type', c.record_type, 'id', c.id,
                                               'summary', t.info ->> 'summary',
                                               'occurrence_date', t.info -> 'occurrence_date')
                            order by c.via, c.record_type, t.info ->> 'occurrence_date' desc nulls last, c.id), '[]'::jsonb)
  from c cross join lateral (select lifeos._target_info(c.record_type, c.id) as info) t
  where t.info is not null
$$;

-- Complete Record of any Record Type, or null when the ID is unknown.
create or replace function lifeos._record_json(p_type text, p_id uuid)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
begin
  case p_type
    when 'schedule' then select lifeos._schedule_json(s) into v from lifeos.schedules s where s.id = p_id;
    when 'event' then select lifeos._event_json(e) into v from lifeos.events e where e.id = p_id;
    when 'observation' then select lifeos._observation_json(o) into v from lifeos.observations o where o.id = p_id;
    when 'note' then select lifeos._note_json(n) into v from lifeos.notes n where n.id = p_id;
    when 'expense' then select lifeos._expense_json(x) into v from lifeos.expenses x where x.id = p_id;
    when 'subject' then select lifeos._subject_json(s) into v from lifeos.subjects s where s.id = p_id;
    when 'divination_record' then
      select lifeos._divination_json(d, false) into v from lifeos.divination_records d where d.id = p_id;
    when 'reading' then select lifeos._reading_json(r, false) into v from lifeos.readings r where r.id = p_id;
    when 'storyline' then select lifeos._storyline_json(s) into v from lifeos.storylines s where s.id = p_id;
    when 'communication_message' then
      select lifeos._message_json(m) into v from lifeos.communication_messages m where m.id = p_id;
    else
      v := null;
  end case;
  return v;
end $$;

-- -----------------------------------------------------------------------------
-- 4.1 Schedule
-- -----------------------------------------------------------------------------

-- Validates and inserts one Schedule (Contract 4.1.1). Returns the new ID.
create or replace function lifeos._schedule_insert(p_input jsonb)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_desc text;
begin
  perform lifeos._check_fields(v, array['title', 'description', 'schedule_case', 'planned_date', 'planned_time',
    'end_date', 'end_time', 'time_text', 'location', 'series_id', 'series_description', 'remarks', 'metadata']);
  perform lifeos._require(v, array['title', 'planned_date']);
  perform lifeos._check_types(v, p_dates => array['planned_date', 'end_date'], p_times => array['planned_time', 'end_time'],
                              p_uuids => array['series_id'], p_objects => array['metadata']);
  if v ? 'schedule_case' and jsonb_typeof(v -> 'schedule_case') <> 'null'
     and v ->> 'schedule_case' not in ('appointment', 'planned_activity', 'deadline', 'expected_activity') then
    raise exception 'invalid input' using detail = 'schedule_case is appointment, planned_activity, deadline or expected_activity';
  end if;
  v := lifeos._strip_top_nulls(v);
  if v ? 'series_description' and btrim(v ->> 'series_description') = '' then
    v := v - 'series_description';
  end if;
  if v ? 'series_id' and not (v ? 'series_description') then
    select s.series_description into v_desc
    from lifeos.schedules s
    where s.series_id = (v ->> 'series_id')::uuid
    order by (s.deleted_at is null) desc, s.planned_date desc, s.created_at desc
    limit 1;
    if v_desc is null then
      raise exception 'invalid input' using detail = 'series_description is required for a new series';
    end if;
    v := v || jsonb_build_object('series_description', v_desc);
  end if;
  v := v || jsonb_build_object('status', 'planned', 'remarks', lifeos._remarks_normalize(v -> 'remarks'));
  return lifeos._insert_row('schedules', v);
end $$;

create or replace function lifeos.schedule_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_input ? 'status' then
    raise exception 'unsupported field' using detail = 'field: status';
  end if;
  v_id := lifeos._schedule_insert(p_input);
  return (select lifeos._schedule_json(s) from lifeos.schedules s where s.id = v_id);
end $$;

create or replace function lifeos.schedule_create_series(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_series uuid;
  v_desc text;
  v_item jsonb;
  v_ids uuid[] := '{}';
begin
  perform lifeos._check_fields(v, array['series_id', 'series_description', 'schedules']);
  perform lifeos._require(v, array['schedules']);
  perform lifeos._check_types(v, p_uuids => array['series_id']);
  if jsonb_typeof(v -> 'schedules') <> 'array' or jsonb_array_length(v -> 'schedules') = 0 then
    raise exception 'invalid input' using detail = 'schedules needs at least one item';
  end if;

  v_series := coalesce(nullif(v ->> 'series_id', '')::uuid, gen_random_uuid());
  v_desc := nullif(btrim(v ->> 'series_description'), '');
  if v_desc is null then
    select s.series_description into v_desc
    from lifeos.schedules s
    where s.series_id = v_series
    order by (s.deleted_at is null) desc, s.planned_date desc, s.created_at desc
    limit 1;
  end if;
  if v_desc is null then
    raise exception 'invalid input' using detail = 'series_description is required for a new series';
  end if;

  for v_item in select value from jsonb_array_elements(v -> 'schedules') loop
    v_item := lifeos._obj(v_item);
    perform lifeos._check_fields(v_item, array['title', 'description', 'schedule_case', 'planned_date', 'planned_time',
      'end_date', 'end_time', 'time_text', 'location', 'remarks', 'metadata']);
    v_ids := v_ids || lifeos._schedule_insert(v_item || jsonb_build_object('series_id', v_series, 'series_description', v_desc));
  end loop;

  return jsonb_build_object(
    'series_id', v_series,
    'series_description', v_desc,
    'schedules', (select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
                  from lifeos.schedules s where s.id = any (v_ids)));
end $$;

create or replace function lifeos.schedule_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.schedules;
begin
  select * into s from lifeos.schedules where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._schedule_json(s) || jsonb_build_object('links', lifeos._links('schedule', p_id));
end $$;

create or replace function lifeos.schedule_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_status text[];
  v_case text;
  v_series uuid;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'status', 'schedule_case', 'series_id', 'from_date', 'to_date',
                                        'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['series_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_status := lifeos._text_list(f -> 'status');
  v_case := nullif(f ->> 'schedule_case', '');
  v_series := (f ->> 'series_id')::uuid;
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at, s.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.schedules s
    where (v_inc or s.deleted_at is null)
      and (v_status is null or s.status = any (v_status))
      and (v_case is null or s.schedule_case = v_case)
      and (v_series is null or s.series_id = v_series)
      and (v_from is null or s.planned_date >= v_from)
      and (v_to is null or s.planned_date <= v_to)
      and (v_pat is null or s.title ilike v_pat or s.description ilike v_pat or s.location ilike v_pat
           or s.series_description ilike v_pat or s.time_text ilike v_pat or lifeos._remarks_match(s.remarks, v_pat))
    order by s.planned_date, s.planned_time nulls last, s.created_at, s.id
    limit v_limit offset v_offset
  ) s;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.schedule_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  s lifeos.schedules;
begin
  select * into s from lifeos.schedules where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'description', 'schedule_case', 'planned_date', 'planned_time',
    'end_date', 'end_time', 'time_text', 'location', 'status', 'series_description', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['planned_date', 'end_date'], p_times => array['planned_time', 'end_time'],
                              p_objects => array['metadata']);
  if v ? 'schedule_case' and jsonb_typeof(v -> 'schedule_case') <> 'null'
     and v ->> 'schedule_case' not in ('appointment', 'planned_activity', 'deadline', 'expected_activity') then
    raise exception 'invalid input' using detail = 'schedule_case is appointment, planned_activity, deadline or expected_activity';
  end if;
  if v ? 'status' then
    if v ->> 'status' is null or v ->> 'status' not in ('planned', 'missed', 'cancelled') then
      raise exception 'invalid input' using detail = 'status accepts planned, missed and cancelled';
    end if;
    if exists (select 1 from lifeos.events e where e.schedule_id = p_id and e.deleted_at is null) then
      raise exception 'invalid relationship' using detail = 'the Schedule has an active linked Event';
    end if;
  end if;
  v := lifeos._prep_changes(v, p_required => array['title', 'planned_date', 'status'], p_objects => array['metadata']);
  perform lifeos._update_row('schedules', p_id, v);
  return (select lifeos._schedule_json(x) from lifeos.schedules x where x.id = p_id);
end $$;

create or replace function lifeos.schedule_update_series(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_changes jsonb;
  v_series uuid;
  v_from date;
  v_ids uuid[];
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['series_id', 'from_date', 'changes']);
  perform lifeos._require(v, array['series_id', 'from_date', 'changes']);
  perform lifeos._check_types(v, p_uuids => array['series_id']);
  v_series := (v ->> 'series_id')::uuid;
  v_from := lifeos._filter_date(v ->> 'from_date');
  v_changes := lifeos._check_changes(v -> 'changes', array['title', 'description', 'schedule_case', 'planned_time',
    'end_time', 'time_text', 'location', 'series_description', 'metadata']);
  perform lifeos._check_types(v_changes, p_times => array['planned_time', 'end_time'], p_objects => array['metadata']);
  if v_changes ? 'schedule_case' and jsonb_typeof(v_changes -> 'schedule_case') <> 'null'
     and v_changes ->> 'schedule_case' not in ('appointment', 'planned_activity', 'deadline', 'expected_activity') then
    raise exception 'invalid input' using detail = 'schedule_case is appointment, planned_activity, deadline or expected_activity';
  end if;
  v_changes := lifeos._prep_changes(v_changes, p_required => array['title', 'series_description'], p_objects => array['metadata']);

  if not exists (select 1 from lifeos.schedules s where s.series_id = v_series) then
    raise exception 'record not found' using detail = 'no Schedule has this series_id';
  end if;

  select coalesce(array_agg(s.id), '{}') into v_ids
  from lifeos.schedules s
  where s.series_id = v_series and s.deleted_at is null and s.status = 'planned' and s.planned_date >= v_from;

  foreach v_id in array v_ids loop
    perform lifeos._update_row('schedules', v_id, v_changes);
  end loop;

  return jsonb_build_object(
    'series_id', v_series,
    'updated_count', cardinality(v_ids),
    'schedules', (select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
                  from lifeos.schedules s where s.id = any (v_ids)));
end $$;

create or replace function lifeos.schedule_stop_series(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_series uuid;
  v_from date;
  v_ids uuid[];
begin
  perform lifeos._check_fields(v, array['series_id', 'from_date']);
  perform lifeos._require(v, array['series_id', 'from_date']);
  perform lifeos._check_types(v, p_uuids => array['series_id']);
  v_series := (v ->> 'series_id')::uuid;
  v_from := lifeos._filter_date(v ->> 'from_date');

  if not exists (select 1 from lifeos.schedules s where s.series_id = v_series) then
    raise exception 'record not found' using detail = 'no Schedule has this series_id';
  end if;

  with u as (
    update lifeos.schedules s set status = 'cancelled', updated_at = now()
    where s.series_id = v_series and s.deleted_at is null and s.status = 'planned' and s.planned_date >= v_from
    returning s.id
  )
  select coalesce(array_agg(u.id), '{}') into v_ids from u;

  return jsonb_build_object(
    'series_id', v_series,
    'cancelled_count', cardinality(v_ids),
    'schedules', (select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
                  from lifeos.schedules s where s.id = any (v_ids)));
end $$;

create or replace function lifeos.schedule_overdue_check(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_today date := lifeos._kl_today();
  v_now timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_res jsonb;
begin
  perform lifeos._check_fields(lifeos._obj(p_filter), '{}'::text[]);
  select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
    into v_res
  from lifeos.schedules s
  where s.deleted_at is null
    and s.status = 'planned'
    and s.planned_date between v_today - 1 and v_today
    and not exists (select 1 from lifeos.events e where e.schedule_id = s.id and e.deleted_at is null)
    and ((s.planned_time is not null and (s.planned_date + s.planned_time) < v_now)
         or (s.planned_time is null and s.planned_date < v_today));
  return jsonb_build_object('results', v_res, 'returned_count', jsonb_array_length(v_res));
end $$;

create or replace function lifeos.schedule_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('schedules', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 4.2 Event
-- -----------------------------------------------------------------------------

create or replace function lifeos.event_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  s lifeos.schedules;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['title', 'description', 'occurred_date', 'occurred_time', 'end_date', 'end_time',
                                        'time_text', 'location', 'schedule_id', 'remarks', 'metadata']);
  perform lifeos._require(v, array['occurred_date']);
  perform lifeos._check_types(v, p_dates => array['occurred_date', 'end_date'], p_times => array['occurred_time', 'end_time'],
                              p_uuids => array['schedule_id'], p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);

  if v ? 'schedule_id' then
    select * into s from lifeos.schedules where id = (v ->> 'schedule_id')::uuid for update;
    if not found then
      raise exception 'record not found' using detail = 'schedule_id';
    end if;
    if s.deleted_at is not null then
      raise exception 'record deleted' using detail = 'schedule_id';
    end if;
    if exists (select 1 from lifeos.events e where e.schedule_id = s.id and e.deleted_at is null) then
      raise exception 'invalid relationship' using detail = 'the Schedule already has an active linked Event';
    end if;
    v := lifeos._strip_top_nulls(jsonb_build_object('title', s.title, 'description', s.description, 'location', s.location))
         || v
         || jsonb_build_object('planned_date', s.planned_date, 'planned_time', s.planned_time);
  else
    perform lifeos._require(v, array['title']);
  end if;

  v := v || jsonb_build_object('remarks', lifeos._remarks_normalize(v -> 'remarks'));
  v_id := lifeos._insert_row('events', v);

  if s.id is not null then
    update lifeos.schedules set status = 'occurred', updated_at = now() where id = s.id;
    return (select lifeos._event_json(e) from lifeos.events e where e.id = v_id)
           || jsonb_build_object('schedule', (select lifeos._schedule_json(x) from lifeos.schedules x where x.id = s.id));
  end if;
  return (select lifeos._event_json(e) from lifeos.events e where e.id = v_id);
end $$;

create or replace function lifeos.event_link_schedule(p_id uuid, p_schedule_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  e lifeos.events;
  s lifeos.schedules;
begin
  select * into e from lifeos.events where id = p_id for update;
  if not found then
    raise exception 'record not found' using detail = 'event';
  end if;
  if e.deleted_at is not null then
    raise exception 'record deleted' using detail = 'event';
  end if;
  select * into s from lifeos.schedules where id = p_schedule_id for update;
  if not found then
    raise exception 'record not found' using detail = 'schedule';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted' using detail = 'schedule';
  end if;
  if e.schedule_id is not null
     and exists (select 1 from lifeos.schedules x where x.id = e.schedule_id and x.deleted_at is null) then
    raise exception 'invalid relationship' using detail = 'the Event already has a Schedule link';
  end if;
  if exists (select 1 from lifeos.events x where x.schedule_id = s.id and x.deleted_at is null and x.id <> e.id) then
    raise exception 'invalid relationship' using detail = 'the Schedule already has an active linked Event';
  end if;

  update lifeos.events
     set schedule_id = s.id, planned_date = s.planned_date, planned_time = s.planned_time, updated_at = now()
   where id = e.id;
  update lifeos.schedules set status = 'occurred', updated_at = now() where id = s.id;

  return (select lifeos._event_json(x) from lifeos.events x where x.id = p_id)
         || jsonb_build_object('schedule', (select lifeos._schedule_json(x) from lifeos.schedules x where x.id = s.id));
end $$;

create or replace function lifeos.event_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  e lifeos.events;
begin
  select * into e from lifeos.events where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._event_json(e) || jsonb_build_object('links', lifeos._links('event', p_id));
end $$;

create or replace function lifeos.event_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_from date;
  v_to date;
  v_schedule uuid;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'from_date', 'to_date', 'schedule_id', 'include_deleted',
                                        'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['schedule_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  v_schedule := (f ->> 'schedule_id')::uuid;

  select coalesce(jsonb_agg(lifeos._event_json(e) order by e.occurred_date desc, e.occurred_time desc nulls last, e.created_at desc, e.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.events e
    where (v_inc or e.deleted_at is null)
      and (v_schedule is null or e.schedule_id = v_schedule)
      and (v_from is null or e.occurred_date >= v_from)
      and (v_to is null or e.occurred_date <= v_to)
      and (v_pat is null or e.title ilike v_pat or e.description ilike v_pat or e.location ilike v_pat
           or e.time_text ilike v_pat or lifeos._remarks_match(e.remarks, v_pat))
    order by e.occurred_date desc, e.occurred_time desc nulls last, e.created_at desc, e.id
    limit v_limit offset v_offset
  ) e;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.event_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  e lifeos.events;
begin
  select * into e from lifeos.events where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if e.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'description', 'occurred_date', 'occurred_time', 'end_date',
                                               'end_time', 'time_text', 'location', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['occurred_date', 'end_date'], p_times => array['occurred_time', 'end_time'],
                              p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['title', 'occurred_date'], p_objects => array['metadata']);
  perform lifeos._update_row('events', p_id, v);
  return (select lifeos._event_json(x) from lifeos.events x where x.id = p_id);
end $$;

create or replace function lifeos.event_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  e lifeos.events;
  v_now timestamptz := now();
  v_returned uuid;
begin
  select * into e from lifeos.events where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if e.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(e.deleted_at), 'schedule_returned_to_planned', null);
  end if;
  update lifeos.events set deleted_at = v_now, updated_at = v_now, schedule_id = null where id = p_id;
  if e.schedule_id is not null then
    update lifeos.schedules set status = 'planned', updated_at = v_now where id = e.schedule_id
    returning id into v_returned;
  end if;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_now), 'schedule_returned_to_planned', v_returned);
end $$;

-- -----------------------------------------------------------------------------
-- 4.3 Observation
-- -----------------------------------------------------------------------------

create or replace function lifeos.observation_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['subject_id', 'observation_name', 'value_numeric', 'unit', 'value_text',
    'observed_date', 'observed_time', 'time_text', 'location', 'event_id', 'remarks', 'metadata']);
  perform lifeos._require(v, array['subject_id', 'observation_name', 'observed_date']);
  perform lifeos._check_types(v, p_dates => array['observed_date'], p_times => array['observed_time'],
                              p_nums => array['value_numeric'], p_uuids => array['subject_id', 'event_id'],
                              p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);
  if not (v ? 'value_numeric') and coalesce(btrim(v ->> 'value_text'), '') = '' then
    raise exception 'invalid input' using detail = 'value_numeric or value_text is required';
  end if;
  perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  if v ? 'event_id' then
    perform lifeos._require_active('events', (v ->> 'event_id')::uuid);
  end if;
  v := v || jsonb_build_object('remarks', lifeos._remarks_normalize(v -> 'remarks'));
  v_id := lifeos._insert_row('observations', v);
  return (select lifeos._observation_json(o) from lifeos.observations o where o.id = v_id);
end $$;

create or replace function lifeos.observation_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  o lifeos.observations;
begin
  select * into o from lifeos.observations where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._observation_json(o) || jsonb_build_object('links', lifeos._links('observation', p_id));
end $$;

create or replace function lifeos.observation_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_subject uuid;
  v_event uuid;
  v_name text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'subject_id', 'observation_name', 'event_id', 'from_date',
                                        'to_date', 'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['subject_id', 'event_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_subject := (f ->> 'subject_id')::uuid;
  v_event := (f ->> 'event_id')::uuid;
  v_name := nullif(btrim(f ->> 'observation_name'), '');
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._observation_json(o) order by o.observed_date desc, o.observed_time desc nulls last, o.created_at desc, o.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.observations o
    where (v_inc or o.deleted_at is null)
      and (v_subject is null or o.subject_id = v_subject)
      and (v_event is null or o.event_id = v_event)
      and (v_name is null or lower(o.observation_name) = lower(v_name))
      and (v_from is null or o.observed_date >= v_from)
      and (v_to is null or o.observed_date <= v_to)
      and (v_pat is null or o.observation_name ilike v_pat or o.value_text ilike v_pat or o.unit ilike v_pat
           or o.location ilike v_pat or lifeos._remarks_match(o.remarks, v_pat))
    order by o.observed_date desc, o.observed_time desc nulls last, o.created_at desc, o.id
    limit v_limit offset v_offset
  ) o;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.observation_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  o lifeos.observations;
  v_num_present boolean;
  v_text_present boolean;
begin
  select * into o from lifeos.observations where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if o.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['subject_id', 'observation_name', 'value_numeric', 'unit', 'value_text',
                                               'location', 'event_id', 'metadata']);
  perform lifeos._check_types(v, p_nums => array['value_numeric'], p_uuids => array['subject_id', 'event_id'],
                              p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['subject_id', 'observation_name'], p_objects => array['metadata']);

  v_num_present := case when v ? 'value_numeric' then jsonb_typeof(v -> 'value_numeric') <> 'null'
                        else o.value_numeric is not null end;
  v_text_present := case when v ? 'value_text' then coalesce(btrim(v ->> 'value_text'), '') <> ''
                         else o.value_text is not null end;
  if not (v_num_present or v_text_present) then
    raise exception 'invalid input' using detail = 'value_numeric or value_text is required';
  end if;
  if v ? 'subject_id' then
    perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  end if;
  if v ? 'event_id' and jsonb_typeof(v -> 'event_id') <> 'null' then
    perform lifeos._require_active('events', (v ->> 'event_id')::uuid);
  end if;
  perform lifeos._update_row('observations', p_id, v);
  return (select lifeos._observation_json(x) from lifeos.observations x where x.id = p_id);
end $$;

create or replace function lifeos.observation_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('observations', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 4.4 Note
-- -----------------------------------------------------------------------------

create or replace function lifeos.note_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['note_type', 'title', 'content', 'remarks', 'metadata']);
  perform lifeos._require(v, array['note_type', 'content']);
  perform lifeos._check_types(v, p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v) || jsonb_build_object('remarks', lifeos._remarks_normalize(v -> 'remarks'));
  v_id := lifeos._insert_row('notes', v);
  return (select lifeos._note_json(n) from lifeos.notes n where n.id = v_id);
end $$;

create or replace function lifeos.note_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  n lifeos.notes;
begin
  select * into n from lifeos.notes where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._note_json(n) || jsonb_build_object('links', lifeos._links('note', p_id));
end $$;

create or replace function lifeos.note_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_type text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'note_type', 'from_date', 'to_date', 'include_deleted',
                                        'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_type := nullif(btrim(f ->> 'note_type'), '');
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._note_json(n) order by s.note_date desc, s.created_at desc, s.id), '[]'::jsonb)
    into v_res
  from (
    select n.id, n.created_at, lifeos._kl_date(coalesce(n.edited_at, n.created_at)) as note_date
    from lifeos.notes n
    where (v_inc or n.deleted_at is null)
      and (v_type is null or lower(n.note_type) = lower(v_type))
      and (v_from is null or lifeos._kl_date(coalesce(n.edited_at, n.created_at)) >= v_from)
      and (v_to is null or lifeos._kl_date(coalesce(n.edited_at, n.created_at)) <= v_to)
      and (v_pat is null or n.title ilike v_pat or n.content ilike v_pat or lifeos._remarks_match(n.remarks, v_pat))
    order by note_date desc, n.created_at desc, n.id
    limit v_limit offset v_offset
  ) s
  cross join lateral (select x.* from lifeos.notes x where x.id = s.id) n;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.note_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  n lifeos.notes;
begin
  select * into n from lifeos.notes where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if n.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['note_type', 'title', 'content', 'metadata']);
  perform lifeos._check_types(v, p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['note_type', 'content'], p_objects => array['metadata']);
  perform lifeos._update_row('notes', p_id, v || jsonb_build_object('edited_at', now()));
  return (select lifeos._note_json(x) from lifeos.notes x where x.id = p_id);
end $$;

create or replace function lifeos.note_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('notes', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 4.5 Record links
-- -----------------------------------------------------------------------------

create or replace function lifeos.record_link_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_from_type text;
  v_to_type text;
  v_from_id uuid;
  v_to_id uuid;
  v_a_type text;
  v_a_id uuid;
  v_b_type text;
  v_b_id uuid;
  l lifeos.record_links;
begin
  perform lifeos._check_fields(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._require(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._check_types(v, p_uuids => array['from_id', 'to_id']);
  v_from_type := v ->> 'from_type';
  v_to_type := v ->> 'to_type';
  v_from_id := (v ->> 'from_id')::uuid;
  v_to_id := (v ->> 'to_id')::uuid;
  if lifeos._record_table(v_from_type) is null or lifeos._record_table(v_to_type) is null then
    raise exception 'invalid input' using detail = 'from_type and to_type are Record Type names';
  end if;
  if v_from_type = v_to_type and v_from_id = v_to_id then
    raise exception 'invalid relationship' using detail = 'a Record cannot link to itself';
  end if;
  if v_from_type = 'subject' and v_to_type = 'subject' then
    raise exception 'invalid relationship' using detail = 'a Subject cannot link to another Subject';
  end if;
  perform lifeos._require_active(lifeos._record_table(v_from_type), v_from_id);
  perform lifeos._require_active(lifeos._record_table(v_to_type), v_to_id);

  if (v_from_type, v_from_id::text) < (v_to_type, v_to_id::text) then
    v_a_type := v_from_type; v_a_id := v_from_id; v_b_type := v_to_type; v_b_id := v_to_id;
  else
    v_a_type := v_to_type; v_a_id := v_to_id; v_b_type := v_from_type; v_b_id := v_from_id;
  end if;

  insert into lifeos.record_links (record_type_a, record_id_a, record_type_b, record_id_b)
  values (v_a_type, v_a_id, v_b_type, v_b_id)
  on conflict on constraint record_links_pair_unique do nothing;

  select * into l from lifeos.record_links
  where record_type_a = v_a_type and record_id_a = v_a_id and record_type_b = v_b_type and record_id_b = v_b_id;

  return jsonb_build_object('link_id', l.id, 'from_type', v_from_type, 'from_id', v_from_id,
                            'to_type', v_to_type, 'to_id', v_to_id, 'created_at', lifeos._ts(l.created_at));
end $$;

create or replace function lifeos.record_link_delete(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_from_type text;
  v_to_type text;
  v_from_id uuid;
  v_to_id uuid;
  v_rows integer;
begin
  perform lifeos._check_fields(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._require(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._check_types(v, p_uuids => array['from_id', 'to_id']);
  v_from_type := v ->> 'from_type';
  v_to_type := v ->> 'to_type';
  v_from_id := (v ->> 'from_id')::uuid;
  v_to_id := (v ->> 'to_id')::uuid;
  delete from lifeos.record_links l
  where (l.record_type_a = v_from_type and l.record_id_a = v_from_id and l.record_type_b = v_to_type and l.record_id_b = v_to_id)
     or (l.record_type_a = v_to_type and l.record_id_a = v_to_id and l.record_type_b = v_from_type and l.record_id_b = v_from_id);
  get diagnostics v_rows = row_count;
  return jsonb_build_object('removed', v_rows > 0);
end $$;

create or replace function lifeos.record_links_read(p_record_type text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text := lifeos._record_table(p_record_type);
  v_found boolean;
begin
  if v_table is null then
    raise exception 'invalid input' using detail = 'p_record_type is a Record Type name';
  end if;
  execute format('select true from lifeos.%I where id = $1', v_table) into v_found using p_id;
  if v_found is null then
    raise exception 'record not found';
  end if;
  return jsonb_build_object('record_type', p_record_type, 'id', p_id, 'links', lifeos._links(p_record_type, p_id));
end $$;

-- -----------------------------------------------------------------------------
-- 4.6 Remarks
-- -----------------------------------------------------------------------------

create or replace function lifeos.record_add_remark(p_record_type text, p_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text;
begin
  if p_record_type is null or p_record_type not in ('schedule', 'event', 'observation', 'note', 'expense') then
    raise exception 'invalid input' using detail = 'p_record_type is schedule, event, observation, note or expense';
  end if;
  if p_text is null or btrim(p_text) = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  v_table := lifeos._record_table(p_record_type);
  perform lifeos._require_active(v_table, p_id);
  execute format('update lifeos.%I set remarks = remarks || jsonb_build_array($2), updated_at = now() where id = $1', v_table)
    using p_id, jsonb_build_object('timestamp', lifeos._ts(now()), 'text', btrim(p_text));
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
