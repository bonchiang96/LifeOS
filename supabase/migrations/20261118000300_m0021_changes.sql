-- =============================================================================
-- LifeOS V2, migration 14: build changes of M-0021 D4 to D10.
--
-- D4: subject_delete rejects a Subject that still has an active Person Profile with
--   "invalid relationship". The Subject stays active.
-- D5: record_link_create rejects a divination_record-storyline link in either order.
--   The migration removes every stored link of this pair.
-- D6: _links lists each connected Subject once, keyed by Subject id. When several paths
--   lead to one Subject, via names the first path in this order: record_link,
--   observation_subject, payment_method, merchant, line_item, story_person_subject,
--   person_profile_subject. The Timeline subjects and links follow, because
--   _timeline_item builds both from _links.
-- D7: expense_delete on a purchase also soft-deletes each active Refund in the same
--   transaction, with its own history snapshot and the same reason. The return adds
--   deleted_refund_ids. The migration deletes every active Refund whose purchase is
--   already deleted, with the reason "purchase deleted before M-0021 D7".
-- D8: storyline_create and storyline_update reject an occurrence_end_date before
--   occurrence_date with "invalid input". storyline_update checks the state after the change.
-- D9: event_delete returns only an active Schedule to Planned. The Event's schedule
--   link is removed in both cases.
-- D10: in every search function, a p_filter ID of a deleted Record matches nothing
--   through links, without an error. Changed: event_search, observation_search,
--   expense_search, divination_search, story_person_search, communication_profile_search
--   and communication_message_history_search. storyline_search already skips deleted
--   Story Persons.
--
-- Changes existing functions with the same signatures. Creates no function, so every
-- grant stays as it is (implementation note 16).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- D4: a Person Subject that still has a Profile is not deleted.
-- -----------------------------------------------------------------------------
create or replace function lifeos.subject_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.subjects;
begin
  select * into s from lifeos.subjects where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(s.deleted_at));
  end if;
  if exists (select 1 from lifeos.communication_profiles p
             where p.person_subject_id = p_id and p.deleted_at is null) then
    raise exception 'invalid relationship' using detail = 'the Person Subject still has a Profile';
  end if;
  return lifeos._soft_delete('subjects', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- D5: a Divination Record and a Storyline cannot be linked, in either order.
-- record_link_create is the only function that inserts into lifeos.record_links.
-- subject_merge only moves links that hold a Subject, so it cannot create this pair.
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
  if (v_from_type = 'reading' and v_to_type = 'storyline') or (v_from_type = 'storyline' and v_to_type = 'reading') then
    raise exception 'invalid relationship' using detail = 'a Reading has no structured link to a Storyline';
  end if;
  if (v_from_type = 'divination_record' and v_to_type = 'storyline')
     or (v_from_type = 'storyline' and v_to_type = 'divination_record') then
    raise exception 'invalid relationship' using detail = 'a Divination Record has no structured link to a Storyline';
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

-- D5 data: remove every stored divination_record-storyline link. Both orders are covered,
-- although the stored pair order always puts divination_record first.
delete from lifeos.record_links
where (record_type_a = 'divination_record' and record_type_b = 'storyline')
   or (record_type_a = 'storyline' and record_type_b = 'divination_record');

-- -----------------------------------------------------------------------------
-- D6: each connected Subject appears once in links. The Reading rule of M-0020 S6
-- (a Record link wins over a Story Person) is now part of the general path order.
-- -----------------------------------------------------------------------------
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
  ), d(via, record_type, id) as (
    -- Every target that is not a Subject stays as it is.
    select c.via, c.record_type, c.id from c where c.record_type <> 'subject'
    union all
    -- D6: one row per Subject id, with the first path in the fixed order.
    (select distinct on (c.id) c.via, c.record_type, c.id
    from c where c.record_type = 'subject'
    order by c.id, case c.via
                     when 'record_link' then 1
                     when 'observation_subject' then 2
                     when 'payment_method' then 3
                     when 'merchant' then 4
                     when 'line_item' then 5
                     when 'story_person_subject' then 6
                     when 'person_profile_subject' then 7
                     else 8 end)
  )
  select coalesce(jsonb_agg(jsonb_build_object('via', d.via, 'record_type', d.record_type, 'id', d.id,
                                               'summary', t.info ->> 'summary',
                                               'occurrence_date', t.info -> 'occurrence_date')
                            order by d.via, d.record_type, t.info ->> 'occurrence_date' desc nulls last, d.id), '[]'::jsonb)
  from d cross join lateral (select lifeos._target_info(d.record_type, d.id) as info) t
  where t.info is not null
$$;

-- -----------------------------------------------------------------------------
-- D7: deleting a purchase also deletes its active Refunds.
-- -----------------------------------------------------------------------------
create or replace function lifeos.expense_delete(p_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  r lifeos.expenses;
  v_reason text;
  v_result jsonb;
  v_refunds jsonb := '[]'::jsonb;
begin
  if p_text is null or btrim(p_text) = '' then
    raise exception 'invalid input' using detail = 'p_text is the required deletion reason';
  end if;
  v_reason := btrim(p_text);
  select * into x from lifeos.expenses where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if x.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(x.deleted_at), 'deleted_refund_ids', '[]'::jsonb);
  end if;
  perform lifeos._expense_snapshot(x, v_reason);
  v_result := lifeos._soft_delete('expenses', p_id);
  if x.expense_type = 'purchase' then
    for r in select * from lifeos.expenses e
             where e.refund_of = p_id and e.deleted_at is null
             order by e.transaction_date, e.created_at, e.id
             for update loop
      perform lifeos._expense_snapshot(r, v_reason);
      perform lifeos._soft_delete('expenses', r.id);
      v_refunds := v_refunds || jsonb_build_array(r.id);
    end loop;
  end if;
  return v_result || jsonb_build_object('deleted_refund_ids', v_refunds);
end $$;

-- D7 data: every active Refund whose purchase is already deleted gets a history snapshot
-- and is soft-deleted. The dev data held 0 such rows when this migration was written.
do $$
declare
  r lifeos.expenses;
begin
  for r in select e.* from lifeos.expenses e join lifeos.expenses p on p.id = e.refund_of
           where e.expense_type = 'refund' and e.deleted_at is null and p.deleted_at is not null
           order by e.id
           for update of e loop
    perform lifeos._expense_snapshot(r, 'purchase deleted before M-0021 D7');
    perform lifeos._soft_delete('expenses', r.id);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- D8: a Storyline end date is never before its start date. The same day passes.
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
  if (v ->> 'occurrence_end_date')::date < (v ->> 'occurrence_date')::date then
    raise exception 'invalid input' using detail = 'occurrence_end_date is before occurrence_date';
  end if;
  v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
  v_id := lifeos._insert_row('storylines', lifeos._strip_top_nulls(v - 'story_person_ids'));
  insert into lifeos.storyline_story_persons (storyline_id, story_person_id) select v_id, u from unnest(v_persons) u;
  return (select lifeos._storyline_json(s) from lifeos.storylines s where s.id = v_id);
end $$;

create or replace function lifeos.storyline_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.storylines;
  v jsonb;
  v_persons uuid[];
  v_start date;
  v_end date;
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
  -- D8: the dates after the change. An omitted field keeps its stored value; null clears it.
  v_start := case when v ? 'occurrence_date' then (v ->> 'occurrence_date')::date else s.occurrence_date end;
  v_end := case when v ? 'occurrence_end_date' then (v ->> 'occurrence_end_date')::date else s.occurrence_end_date end;
  if v_end < v_start then
    raise exception 'invalid input' using detail = 'occurrence_end_date is before occurrence_date';
  end if;
  if v ? 'story_person_ids' then
    v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
    delete from lifeos.storyline_story_persons where storyline_id = p_id;
    insert into lifeos.storyline_story_persons (storyline_id, story_person_id) select p_id, u from unnest(v_persons) u;
  end if;
  perform lifeos._update_row('storylines', p_id, v - 'story_person_ids');
  return (select lifeos._storyline_json(x) from lifeos.storylines x where x.id = p_id);
end $$;

-- -----------------------------------------------------------------------------
-- D9: only an active Schedule returns to Planned. The link is removed in both cases.
-- -----------------------------------------------------------------------------
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
    update lifeos.schedules set status = 'planned', updated_at = v_now
     where id = e.schedule_id and deleted_at is null
    returning id into v_returned;
  end if;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_now), 'schedule_returned_to_planned', v_returned);
end $$;

-- -----------------------------------------------------------------------------
-- D10: a p_filter ID of a deleted Record matches nothing through links.
-- Each changed condition adds "the filter target is active". Other filters stay as they were.
-- -----------------------------------------------------------------------------
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
      and (v_schedule is null
           or (e.schedule_id = v_schedule
               and exists (select 1 from lifeos.schedules x where x.id = v_schedule and x.deleted_at is null)))
      and (v_from is null or e.occurred_date >= v_from)
      and (v_to is null or e.occurred_date <= v_to)
      and (v_pat is null or e.title ilike v_pat or e.description ilike v_pat or e.location ilike v_pat
           or e.time_text ilike v_pat or lifeos._remarks_match(e.remarks, v_pat))
    order by e.occurred_date desc, e.occurred_time desc nulls last, e.created_at desc, e.id
    limit v_limit offset v_offset
  ) e;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
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
      and (v_subject is null
           or (o.subject_id = v_subject
               and exists (select 1 from lifeos.subjects x where x.id = v_subject and x.deleted_at is null)))
      and (v_event is null
           or (o.event_id = v_event
               and exists (select 1 from lifeos.events x where x.id = v_event and x.deleted_at is null)))
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

create or replace function lifeos.expense_search(p_filter jsonb)
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
  v_type text;
  v_pay uuid;
  v_merchant uuid;
  v_item uuid;
  v_category text;
  v_tag text;
  v_refund_of uuid;
  v_currency text;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'from_date', 'to_date', 'expense_type',
    'payment_method_subject_id', 'merchant_subject_id', 'item_subject_id', 'category', 'tag', 'refund_of', 'currency',
    'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['payment_method_subject_id', 'merchant_subject_id', 'item_subject_id',
                                                  'refund_of']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  v_type := nullif(btrim(f ->> 'expense_type'), '');
  v_pay := (f ->> 'payment_method_subject_id')::uuid;
  v_merchant := (f ->> 'merchant_subject_id')::uuid;
  v_item := (f ->> 'item_subject_id')::uuid;
  v_category := nullif(btrim(f ->> 'category'), '');
  v_tag := nullif(btrim(f ->> 'tag'), '');
  v_refund_of := (f ->> 'refund_of')::uuid;
  v_currency := upper(nullif(btrim(f ->> 'currency'), ''));

  select coalesce(jsonb_agg(lifeos._expense_json(x) order by x.transaction_date desc, x.transaction_time desc nulls last, x.created_at desc, x.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.expenses x
    where (v_inc or x.deleted_at is null)
      and (v_from is null or x.transaction_date >= v_from)
      and (v_to is null or x.transaction_date <= v_to)
      and (v_type is null or x.expense_type = v_type)
      and (v_pay is null
           or (x.payment_method_subject_id = v_pay
               and exists (select 1 from lifeos.subjects s where s.id = v_pay and s.deleted_at is null)))
      and (v_merchant is null
           or (x.merchant_subject_id = v_merchant
               and exists (select 1 from lifeos.subjects s where s.id = v_merchant and s.deleted_at is null)))
      and (v_refund_of is null
           or (x.refund_of = v_refund_of
               and exists (select 1 from lifeos.expenses o where o.id = v_refund_of and o.deleted_at is null)))
      and (v_currency is null or x.currency = v_currency)
      and (v_item is null
           or (exists (select 1 from lifeos.expense_lines l where l.expense_id = x.id and l.item_subject_id = v_item)
               and exists (select 1 from lifeos.subjects s where s.id = v_item and s.deleted_at is null)))
      and (v_category is null or exists (select 1 from lifeos.expense_lines l where l.expense_id = x.id and l.category = v_category))
      and (v_tag is null or exists (select 1 from lifeos.expense_lines l where l.expense_id = x.id and v_tag = any (l.tags)))
      and (v_pat is null or x.merchant_name ilike v_pat or x.branch ilike v_pat or x.seller_name ilike v_pat
           or lifeos._remarks_match(x.remarks, v_pat)
           or exists (select 1 from lifeos.expense_lines l
                      where l.expense_id = x.id and (l.item_description ilike v_pat or l.source_item_text ilike v_pat)))
    order by x.transaction_date desc, x.transaction_time desc nulls last, x.created_at desc, x.id
    limit v_limit offset v_offset
  ) x;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
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
      and (v_person is null
           or (exists (select 1 from lifeos.reading_story_persons rsp
                       where rsp.reading_id = r.id and rsp.story_person_id = v_person)
               and exists (select 1 from lifeos.story_persons sp where sp.id = v_person and sp.deleted_at is null)))
      and (v_subject is null
           or (exists (select 1 from lifeos.subjects s where s.id = v_subject and s.deleted_at is null)
               and (exists (select 1 from lifeos.record_links l
                            where (l.record_type_a = 'reading' and l.record_id_a = r.id and l.record_type_b = 'subject' and l.record_id_b = v_subject)
                               or (l.record_type_b = 'reading' and l.record_id_b = r.id and l.record_type_a = 'subject' and l.record_id_a = v_subject))
                    or exists (select 1 from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
                               where rsp.reading_id = r.id and sp.subject_id = v_subject and sp.deleted_at is null))))
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
      and (v_subject is null
           or (s.subject_id = v_subject
               and exists (select 1 from lifeos.subjects x where x.id = v_subject and x.deleted_at is null)))
      and (v_pat is null or s.name ilike v_pat or s.description ilike v_pat or lifeos._array_match(s.aliases, v_pat))
    order by s.updated_at desc, s.id
    limit v_limit offset v_offset
  ) s;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.communication_profile_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_type text;
  v_subject uuid;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'profile_type', 'person_subject_id', 'include_deleted',
                                        'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['person_subject_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_type := nullif(btrim(f ->> 'profile_type'), '');
  v_subject := (f ->> 'person_subject_id')::uuid;

  select coalesce(jsonb_agg(lifeos._profile_json(p) order by p.name, p.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.communication_profiles p
    where (v_inc or p.deleted_at is null)
      and (v_type is null or p.profile_type = v_type)
      and (v_subject is null
           or (p.person_subject_id = v_subject
               and exists (select 1 from lifeos.subjects x where x.id = v_subject and x.deleted_at is null)))
      and (v_pat is null or p.name ilike v_pat or p.profile_key ilike v_pat or p.description ilike v_pat
           or lifeos._array_match(p.aliases, v_pat))
    order by p.name, p.id
    limit v_limit offset v_offset
  ) p;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.communication_message_history_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_pat text;
  v_profile uuid;
  v_lang text;
  v_platform text;
  v_intent text;
  v_mode text;
  v_from timestamptz;
  v_to timestamptz;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['profile_id', 'language_mode', 'platform', 'intent', 'message_mode', 'keyword',
                                        'query', 'from_date', 'to_date', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['profile_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_pat := lifeos._kw(f);
  v_profile := (f ->> 'profile_id')::uuid;
  v_lang := f ->> 'language_mode';
  v_platform := f ->> 'platform';
  v_intent := f ->> 'intent';
  v_mode := f ->> 'message_mode';
  v_from := lifeos._filter_ts_from(f ->> 'from_date');
  v_to := lifeos._filter_ts_to(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._message_json(m) order by m.finalized_at desc, m.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.communication_messages m
    where m.deleted_at is null
      and (v_profile is null
           or (m.profile_id = v_profile
               and exists (select 1 from lifeos.communication_profiles p where p.id = v_profile and p.deleted_at is null)))
      and (v_lang is null or m.language_mode = v_lang)
      and (v_platform is null or m.platform = v_platform)
      and (v_intent is null or m.intent = v_intent)
      and (v_mode is null or m.message_mode = v_mode)
      and (v_from is null or m.finalized_at >= v_from)
      and (v_to is null or m.finalized_at <= v_to)
      and (v_pat is null or m.message_text ilike v_pat or m.intent ilike v_pat)
    order by m.finalized_at desc, m.id
    limit v_limit offset v_offset
  ) m;

  return lifeos._search_shape(v_res, v_limit, v_offset);
end $$;
