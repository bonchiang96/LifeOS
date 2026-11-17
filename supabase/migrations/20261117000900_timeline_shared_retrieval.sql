-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 9 of 10: Timeline and Shared Retrieval (Contract Chapter 9)
--
-- Creates:
--   1. The internal helpers _timeline_candidates and _timeline_item.
--   2. The Contract functions timeline and subject_records.
--
-- Occurrence and record dates follow the Contract 9.3 field table, in Asia/Kuala_Lumpur.
-- =============================================================================

-- Every active Timeline Record with its occurrence date, occurrence time and record date (Contract 9.1, 9.3).
create or replace function lifeos._timeline_candidates()
returns table (record_type text, id uuid, occurrence_date date, occurrence_time time, record_date date,
               created_at timestamptz)
language sql stable set search_path = lifeos, pg_temp
as $$
  select 'schedule', s.id, s.planned_date, s.planned_time, lifeos._kl_date(s.created_at), s.created_at
  from lifeos.schedules s where s.deleted_at is null
  union all
  select 'event', e.id, e.occurred_date, e.occurred_time, lifeos._kl_date(e.created_at), e.created_at
  from lifeos.events e where e.deleted_at is null
  union all
  select 'observation', o.id, o.observed_date, o.observed_time, lifeos._kl_date(o.created_at), o.created_at
  from lifeos.observations o where o.deleted_at is null
  union all
  select 'note', n.id, lifeos._kl_date(coalesce(n.edited_at, n.created_at)), null::time, lifeos._kl_date(n.created_at), n.created_at
  from lifeos.notes n where n.deleted_at is null
  union all
  select 'expense', x.id, x.transaction_date, x.transaction_time, lifeos._kl_date(x.created_at), x.created_at
  from lifeos.expenses x where x.deleted_at is null
  union all
  select 'reading', r.id, r.reading_date, r.reading_time, lifeos._kl_date(r.created_at), r.created_at
  from lifeos.readings r join lifeos.divination_records d on d.id = r.divination_record_id
  where r.deleted_at is null and d.deleted_at is null
  union all
  select 'communication_message', m.id, lifeos._kl_date(m.finalized_at), lifeos._kl_time(m.finalized_at),
         lifeos._kl_date(m.finalized_at), m.created_at
  from lifeos.communication_messages m where m.deleted_at is null
$$;

-- One Timeline item (Contract 9.1 return shape).
create or replace function lifeos._timeline_item(p_type text, p_id uuid, p_occurrence_date date, p_occurrence_time time,
                                                 p_record_date date)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_record jsonb;
  v_links jsonb;
  v_subject_links jsonb;
  v_subjects jsonb;
begin
  v_record := lifeos._record_json(p_type, p_id);
  if p_type = 'reading' then
    -- A Reading item carries its own Analyses and the combined Analyses of its Divination Record.
    v_record := v_record || jsonb_build_object('record_analyses', coalesce((
      select jsonb_agg(lifeos._analysis_json(a) order by a.analysis_date, a.created_at)
      from lifeos.analyses a join lifeos.readings r on r.divination_record_id = a.divination_record_id
      where r.id = p_id and a.reading_id is null and a.deleted_at is null), '[]'::jsonb));
  end if;

  if p_type = 'communication_message' then
    v_links := '[]'::jsonb;
    v_subject_links := lifeos._links('communication_message', p_id);
  else
    v_links := lifeos._links(p_type, p_id);
    v_subject_links := v_links;
  end if;

  select coalesce(jsonb_agg(distinct jsonb_build_object('id', s.id, 'name', s.name, 'subject_type', s.subject_type,
                                                        'via', l ->> 'via')), '[]'::jsonb)
    into v_subjects
  from jsonb_array_elements(v_subject_links) l
  join lifeos.subjects s on s.id = (l ->> 'id')::uuid and s.deleted_at is null
  where l ->> 'record_type' = 'subject';

  return jsonb_build_object(
    'record_type', p_type,
    'module', case p_type
                when 'expense' then 'financial_records'
                when 'reading' then 'divination_reflection'
                when 'communication_message' then 'communication_assistant'
                else 'personal_records' end,
    'id', p_id,
    'occurrence_date', p_occurrence_date,
    'occurrence_time', p_occurrence_time,
    'record_date', p_record_date,
    'record', v_record,
    'subjects', v_subjects,
    'links', v_links);
end $$;

create or replace function lifeos.timeline(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_from date;
  v_to date;
  v_basis text;
  v_items jsonb;
  v_earlier jsonb := '[]'::jsonb;
begin
  perform lifeos._check_fields(f, array['from_date', 'to_date', 'date_basis']);
  perform lifeos._require(f, array['from_date', 'to_date']);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  if v_from > v_to then
    raise exception 'invalid input' using detail = 'from_date is after to_date';
  end if;
  v_basis := coalesce(nullif(btrim(f ->> 'date_basis'), ''), 'occurrence');
  if v_basis not in ('occurrence', 'record') then
    raise exception 'invalid input' using detail = 'date_basis is occurrence or record';
  end if;

  select coalesce(jsonb_agg(lifeos._timeline_item(c.record_type, c.id, c.occurrence_date, c.occurrence_time, c.record_date)
                            order by c.occurrence_date, c.occurrence_time nulls last, c.created_at, c.id), '[]'::jsonb)
    into v_items
  from lifeos._timeline_candidates() c
  where (v_basis = 'occurrence' and c.occurrence_date between v_from and v_to)
     or (v_basis = 'record' and c.record_date between v_from and v_to);

  if v_basis = 'occurrence' then
    select coalesce(jsonb_agg(lifeos._timeline_item(c.record_type, c.id, c.occurrence_date, c.occurrence_time, c.record_date)
                              order by c.occurrence_date, c.occurrence_time nulls last, c.created_at, c.id), '[]'::jsonb)
      into v_earlier
    from lifeos._timeline_candidates() c
    where c.record_date between v_from and v_to and c.occurrence_date < v_from;
  end if;

  return jsonb_build_object(
    'from_date', v_from,
    'to_date', v_to,
    'date_basis', v_basis,
    'items', v_items,
    'recorded_earlier', v_earlier,
    'returned_count', jsonb_array_length(v_items));
end $$;

create or replace function lifeos.subject_records(p_id uuid, p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_all text[] := array['schedule', 'event', 'observation', 'note', 'expense', 'reading', 'storyline', 'communication_message'];
  v_types text[];
  v_from date;
  v_to date;
  v_limit integer;
  v_offset integer;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['record_types', 'from_date', 'to_date', 'limit', 'offset']);
  if not exists (select 1 from lifeos.subjects s where s.id = p_id) then
    raise exception 'record not found';
  end if;
  v_types := coalesce(lifeos._text_list(f -> 'record_types'), v_all);
  if cardinality(v_types) = 0 then
    v_types := v_all;
  end if;
  if exists (select 1 from unnest(v_types) t where t <> all (v_all)) then
    raise exception 'invalid input' using detail = 'record_types accepts schedule, event, observation, note, expense, reading, storyline and communication_message';
  end if;
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);

  with c (record_type, id, via, rank) as (
    select case when l.record_type_a = 'subject' and l.record_id_a = p_id then l.record_type_b else l.record_type_a end,
           case when l.record_type_a = 'subject' and l.record_id_a = p_id then l.record_id_b else l.record_id_a end,
           'record_link', 1
    from lifeos.record_links l
    where (l.record_type_a = 'subject' and l.record_id_a = p_id) or (l.record_type_b = 'subject' and l.record_id_b = p_id)
    union all
    select 'observation', o.id, 'observation_subject', 2 from lifeos.observations o where o.subject_id = p_id
    union all
    select 'expense', x.id, 'payment_method', 3 from lifeos.expenses x where x.payment_method_subject_id = p_id
    union all
    select 'expense', x.id, 'merchant', 4 from lifeos.expenses x where x.merchant_subject_id = p_id
    union all
    select 'expense', l.expense_id, 'line_item', 5 from lifeos.expense_lines l where l.item_subject_id = p_id
    union all
    select 'reading', rsp.reading_id, 'story_person_subject', 6
    from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
    where sp.subject_id = p_id and sp.deleted_at is null
    union all
    select 'storyline', ssp.storyline_id, 'story_person_subject', 6
    from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
    where sp.subject_id = p_id and sp.deleted_at is null
    union all
    select 'communication_message', m.id, 'person_profile_subject', 7
    from lifeos.communication_messages m join lifeos.communication_profiles p on p.id = m.profile_id
    where p.person_subject_id = p_id and p.profile_type = 'person' and p.deleted_at is null
  ), d as (
    select distinct on (c.record_type, c.id) c.record_type, c.id, c.via
    from c where c.record_type = any (v_types)
    order by c.record_type, c.id, c.rank
  ), dated as (
    select d.*, (t.info ->> 'occurrence_date')::date as occurrence_date
    from d cross join lateral (select lifeos._target_info(d.record_type, d.id) as info) t
    where t.info is not null
  ), paged as (
    select dated.* from dated
    where (v_from is null and v_to is null)
       or (dated.occurrence_date is not null
           and (v_from is null or dated.occurrence_date >= v_from)
           and (v_to is null or dated.occurrence_date <= v_to))
    order by dated.occurrence_date desc nulls last, dated.record_type, dated.id
    limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(jsonb_build_object('record_type', pg.record_type, 'id', pg.id, 'via', pg.via,
                                               'occurrence_date', pg.occurrence_date,
                                               'record', lifeos._record_json(pg.record_type, pg.id))
                            order by pg.occurrence_date desc nulls last, pg.record_type, pg.id), '[]'::jsonb)
    into v_res
  from paged pg;

  return lifeos._search_shape(v_res, v_limit, v_offset);
end $$;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
