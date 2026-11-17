-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 8 of 10: Communication Assistant (Contract Chapter 8)
--
-- Creates:
--   1. The internal helpers _profile_json, _profile_compact, _rule_json, _message_json,
--      _membership_json, _profile_for_rules, _rule_candidates, _resolve, _rule_upsert,
--      _rule_delete and _runtime_context.
--   2. The Contract functions:
--      Profiles: communication_profile_create, communication_profile_read,
--        communication_profile_search, communication_profile_update,
--        communication_profile_delete, communication_profile_membership_set,
--        communication_profile_membership_remove.
--      Rules: communication_rule_upsert, communication_rule_delete,
--        communication_rule_state, communication_resolve.
--      Messages: communication_runtime_context, communication_message_finalize,
--        communication_message_history_read, communication_message_history_search,
--        communication_message_history_delete.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Builders
-- -----------------------------------------------------------------------------

create or replace function lifeos._profile_json(p lifeos.communication_profiles)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(p)
    || jsonb_build_object('person_subject_id',
         (select s.id from lifeos.subjects s where s.id = p.person_subject_id and s.deleted_at is null))
$$;

create or replace function lifeos._profile_compact(p_id uuid)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('id', p.id, 'profile_key', p.profile_key, 'profile_type', p.profile_type, 'name', p.name)
  from lifeos.communication_profiles p where p.id = p_id
$$;

create or replace function lifeos._rule_json(r lifeos.communication_rules)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$ select lifeos._row_json(r) $$;

create or replace function lifeos._message_json(m lifeos.communication_messages)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(m)
    || jsonb_build_object('profile_id',
         (select p.id from lifeos.communication_profiles p where p.id = m.profile_id and p.deleted_at is null))
$$;

create or replace function lifeos._membership_json(m lifeos.communication_profile_memberships)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('child_profile_id', m.child_profile_id, 'parent_profile_id', m.parent_profile_id,
                            'priority', m.priority, 'metadata', m.metadata,
                            'created_at', lifeos._ts(m.created_at), 'updated_at', lifeos._ts(m.updated_at))
$$;

-- -----------------------------------------------------------------------------
-- Rule resolution helpers (Contract 8.2.3, 8.2.4)
-- -----------------------------------------------------------------------------

-- Checks the Profile used for Rule resolution. null means Global Rules only.
create or replace function lifeos._profile_for_rules(p_profile_id uuid)
returns void language plpgsql stable set search_path = lifeos, pg_temp
as $$
begin
  if p_profile_id is not null then
    perform lifeos._require_active('communication_profiles', p_profile_id);
  end if;
end $$;

-- Every current Rule that applies to a Profile and Language Mode, with its scope, depth and priority.
create or replace function lifeos._rule_candidates(p_profile_id uuid, p_language_mode text)
returns table (id uuid, dimension text, rule_key text, rule_text text, language_mode text, scope text,
               scope_rank integer, source_profile_id uuid, depth integer, priority integer, updated_at timestamptz)
language sql stable set search_path = lifeos, pg_temp
as $$
  with recursive anc (profile_id, depth, priority, path) as (
    select m.parent_profile_id, 1, m.priority, array[m.child_profile_id, m.parent_profile_id]
    from lifeos.communication_profile_memberships m
    join lifeos.communication_profiles pp on pp.id = m.parent_profile_id
    where p_profile_id is not null and m.child_profile_id = p_profile_id
      and pp.deleted_at is null and pp.profile_type = 'audience'
    union all
    select m.parent_profile_id, a.depth + 1, m.priority, a.path || m.parent_profile_id
    from anc a
    join lifeos.communication_profile_memberships m on m.child_profile_id = a.profile_id
    join lifeos.communication_profiles pp on pp.id = m.parent_profile_id
    where pp.deleted_at is null and pp.profile_type = 'audience' and not (m.parent_profile_id = any (a.path))
  ), best as (
    select distinct on (anc.profile_id) anc.profile_id, anc.depth, anc.priority
    from anc order by anc.profile_id, anc.depth, anc.priority desc
  ), lang as (
    select r.* from lifeos.communication_rules r
    where r.language_mode is null or (p_language_mode is not null and r.language_mode = p_language_mode)
  )
  select r.id, r.dimension, r.rule_key, r.rule_text, r.language_mode, 'profile', 0, r.profile_id, 0, null::integer, r.updated_at
  from lang r where p_profile_id is not null and r.profile_id = p_profile_id
  union all
  select r.id, r.dimension, r.rule_key, r.rule_text, r.language_mode, 'inherited', 1, b.profile_id, b.depth, b.priority, r.updated_at
  from lang r join best b on b.profile_id = r.profile_id
  union all
  select r.id, r.dimension, r.rule_key, r.rule_text, r.language_mode, 'global', 2, null::uuid, null::integer, null::integer, r.updated_at
  from lang r where r.profile_id is null
$$;

-- Effective Rules: one winning Rule per dimension and rule_key (Contract 8.2.4).
create or replace function lifeos._resolve(p_profile_id uuid, p_language_mode text)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  with w as (
    select distinct on (c.dimension, c.rule_key) c.*
    from lifeos._rule_candidates(p_profile_id, p_language_mode) c
    order by c.dimension, c.rule_key, c.scope_rank, c.depth nulls last, c.priority desc nulls last,
             (c.language_mode is not null) desc, c.updated_at desc, c.id
  ), d as (
    select w.dimension,
           jsonb_agg(jsonb_build_object('id', w.id, 'rule_key', w.rule_key, 'rule_text', w.rule_text,
                                        'scope', w.scope, 'source_profile_id', w.source_profile_id) order by w.rule_key) as rules
    from w group by w.dimension
  )
  select jsonb_build_object(
    'profile', case when p_profile_id is null then null else lifeos._profile_compact(p_profile_id) end,
    'language_mode', p_language_mode,
    'effective_rules', coalesce((select jsonb_object_agg(d.dimension, d.rules) from d), '{}'::jsonb))
$$;

-- Creates or updates one current Rule (Contract 8.2.1). Returns the Rule plus action.
create or replace function lifeos._rule_upsert(p_input jsonb)
returns jsonb language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  c jsonb;
  v_id uuid;
  v_action text;
begin
  perform lifeos._check_fields(v, array['id', 'profile_id', 'language_mode', 'dimension', 'rule_key', 'rule_text', 'metadata']);
  perform lifeos._check_types(v, p_uuids => array['id', 'profile_id'], p_objects => array['metadata']);

  if v ? 'id' and jsonb_typeof(v -> 'id') <> 'null' then
    v_id := (v ->> 'id')::uuid;
    perform 1 from lifeos.communication_rules r where r.id = v_id for update;
    if not found then
      raise exception 'record not found';
    end if;
    c := lifeos._check_changes(v - 'id', array['profile_id', 'language_mode', 'dimension', 'rule_key', 'rule_text', 'metadata']);
    c := lifeos._prep_changes(c, p_required => array['dimension', 'rule_key', 'rule_text'], p_objects => array['metadata']);
    if c ? 'profile_id' and jsonb_typeof(c -> 'profile_id') <> 'null' then
      perform lifeos._require_active('communication_profiles', (c ->> 'profile_id')::uuid);
    end if;
    perform lifeos._update_row('communication_rules', v_id, c);
    v_action := 'updated';
  else
    v := lifeos._strip_top_nulls(v - 'id');
    perform lifeos._require(v, array['dimension', 'rule_key', 'rule_text']);
    if v ? 'profile_id' then
      perform lifeos._require_active('communication_profiles', (v ->> 'profile_id')::uuid);
    end if;
    select r.id into v_id
    from lifeos.communication_rules r
    where r.profile_id is not distinct from (v ->> 'profile_id')::uuid
      and r.language_mode is not distinct from (v ->> 'language_mode')
      and r.dimension = v ->> 'dimension'
      and r.rule_key = v ->> 'rule_key'
    for update;
    if v_id is not null then
      perform lifeos._update_row('communication_rules', v_id,
        jsonb_build_object('rule_text', v -> 'rule_text')
        || case when v ? 'metadata' then jsonb_build_object('metadata', v -> 'metadata') else '{}'::jsonb end);
      v_action := 'updated';
    else
      v_id := lifeos._insert_row('communication_rules', v);
      v_action := 'created';
    end if;
  end if;

  return (select lifeos._rule_json(r) from lifeos.communication_rules r where r.id = v_id)
         || jsonb_build_object('action', v_action);
end $$;

-- Physically removes one Rule (Contract 8.2.2).
create or replace function lifeos._rule_delete(p_id uuid)
returns jsonb language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_rows integer;
begin
  delete from lifeos.communication_rules where id = p_id;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('id', p_id, 'removed', v_rows > 0);
end $$;

-- Effective Rules plus recent finalized messages (Contract 8.3.1).
create or replace function lifeos._runtime_context(p_profile_id uuid, p_language_mode text, p_platform text,
                                                   p_history_limit integer)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_resolved jsonb;
begin
  if p_history_limit is null or p_history_limit < 0 then
    raise exception 'invalid input' using detail = 'history limit is zero or positive';
  end if;
  perform lifeos._profile_for_rules(p_profile_id);
  v_resolved := lifeos._resolve(p_profile_id, p_language_mode);
  return jsonb_build_object(
    'profile', v_resolved -> 'profile',
    'language_mode', p_language_mode,
    'platform', p_platform,
    'effective_rules', v_resolved -> 'effective_rules',
    'recent_messages', coalesce((
      select jsonb_agg(lifeos._message_json(y) order by s.platform_rank, s.finalized_at desc, s.id)
      from (
        select x.id, x.finalized_at,
               case when p_platform is not null and x.platform = p_platform then 0 else 1 end as platform_rank
        from lifeos.communication_messages x
        where x.deleted_at is null
          and x.profile_id is not distinct from p_profile_id
          and x.language_mode is not distinct from p_language_mode
        order by platform_rank, x.finalized_at desc, x.id
        limit p_history_limit
      ) s
      join lifeos.communication_messages y on y.id = s.id), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- 8.1 Profiles
-- -----------------------------------------------------------------------------

create or replace function lifeos.communication_profile_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['profile_key', 'profile_type', 'name', 'description', 'aliases', 'person_subject_id',
                                        'metadata']);
  perform lifeos._require(v, array['profile_key', 'profile_type', 'name']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['person_subject_id'],
                              p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);
  if v ->> 'profile_type' not in ('person', 'group', 'audience') then
    raise exception 'invalid input' using detail = 'profile_type is person, group or audience';
  end if;
  if v ->> 'profile_type' = 'person' then
    perform lifeos._require(v, array['person_subject_id']);
    perform lifeos._require_active('subjects', (v ->> 'person_subject_id')::uuid);
    if exists (select 1 from lifeos.communication_profiles p
               where p.person_subject_id = (v ->> 'person_subject_id')::uuid and p.deleted_at is null) then
      raise exception 'invalid relationship' using detail = 'the Subject already has an active Person Profile';
    end if;
  elsif v ? 'person_subject_id' then
    raise exception 'invalid input' using detail = 'a Group or Audience Profile has no person_subject_id';
  end if;
  v_id := lifeos._insert_row('communication_profiles', v);
  return (select lifeos._profile_json(p) from lifeos.communication_profiles p where p.id = v_id);
end $$;

create or replace function lifeos.communication_profile_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  p lifeos.communication_profiles;
begin
  select * into p from lifeos.communication_profiles where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._profile_json(p) || jsonb_build_object('parent_profiles', coalesce((
    select jsonb_agg(jsonb_build_object('profile_id', pp.id, 'name', pp.name, 'priority', m.priority)
                     order by m.priority desc, pp.name)
    from lifeos.communication_profile_memberships m
    join lifeos.communication_profiles pp on pp.id = m.parent_profile_id
    where m.child_profile_id = p_id and pp.deleted_at is null), '[]'::jsonb));
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
      and (v_subject is null or p.person_subject_id = v_subject)
      and (v_pat is null or p.name ilike v_pat or p.profile_key ilike v_pat or p.description ilike v_pat
           or lifeos._array_match(p.aliases, v_pat))
    order by p.name, p.id
    limit v_limit offset v_offset
  ) p;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.communication_profile_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  p lifeos.communication_profiles;
  v jsonb;
begin
  select * into p from lifeos.communication_profiles where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if p.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['profile_key', 'name', 'description', 'aliases', 'person_subject_id', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['person_subject_id'],
                              p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['profile_key', 'name'], p_arrays => array['aliases'],
                            p_objects => array['metadata']);
  if v ? 'person_subject_id' then
    if p.profile_type = 'person' then
      if jsonb_typeof(v -> 'person_subject_id') = 'null' then
        raise exception 'invalid input' using detail = 'a Person Profile keeps exactly one person_subject_id';
      end if;
      perform lifeos._require_active('subjects', (v ->> 'person_subject_id')::uuid);
      if exists (select 1 from lifeos.communication_profiles x
                 where x.person_subject_id = (v ->> 'person_subject_id')::uuid and x.deleted_at is null and x.id <> p_id) then
        raise exception 'invalid relationship' using detail = 'the Subject already has an active Person Profile';
      end if;
    elsif jsonb_typeof(v -> 'person_subject_id') <> 'null' then
      raise exception 'invalid input' using detail = 'a Group or Audience Profile has no person_subject_id';
    end if;
  end if;
  perform lifeos._update_row('communication_profiles', p_id, v);
  return (select lifeos._profile_json(x) from lifeos.communication_profiles x where x.id = p_id);
end $$;

create or replace function lifeos.communication_profile_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('communication_profiles', p_id);
end $$;

create or replace function lifeos.communication_profile_membership_set(p_child_profile_id uuid, p_parent_profile_id uuid,
                                                                       p_priority integer default 0,
                                                                       p_metadata jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  parent lifeos.communication_profiles;
  m lifeos.communication_profile_memberships;
  v_metadata jsonb := lifeos._obj(p_metadata);
begin
  perform lifeos._require_active('communication_profiles', p_child_profile_id);
  select * into parent from lifeos.communication_profiles where id = p_parent_profile_id;
  if not found then
    raise exception 'record not found' using detail = 'parent profile';
  end if;
  if parent.deleted_at is not null then
    raise exception 'record deleted' using detail = 'parent profile';
  end if;
  if parent.profile_type <> 'audience' then
    raise exception 'invalid relationship' using detail = 'the parent is an Audience Profile';
  end if;
  if p_child_profile_id = p_parent_profile_id then
    raise exception 'invalid relationship' using detail = 'a Profile cannot inherit from itself';
  end if;
  -- A cycle forms when the child is already an ancestor of the parent.
  if exists (
    with recursive up (profile_id, path) as (
      select m2.parent_profile_id, array[m2.parent_profile_id]
      from lifeos.communication_profile_memberships m2 where m2.child_profile_id = p_parent_profile_id
      union all
      select m2.parent_profile_id, up.path || m2.parent_profile_id
      from up join lifeos.communication_profile_memberships m2 on m2.child_profile_id = up.profile_id
      where not (m2.parent_profile_id = any (up.path))
    )
    select 1 from up where up.profile_id = p_child_profile_id) then
    raise exception 'invalid relationship' using detail = 'the membership would create an inheritance cycle';
  end if;

  insert into lifeos.communication_profile_memberships (child_profile_id, parent_profile_id, priority, metadata)
  values (p_child_profile_id, p_parent_profile_id, coalesce(p_priority, 0), v_metadata)
  on conflict (child_profile_id, parent_profile_id)
  do update set priority = excluded.priority, metadata = excluded.metadata, updated_at = now()
  returning * into m;
  return lifeos._membership_json(m);
end $$;

create or replace function lifeos.communication_profile_membership_remove(p_child_profile_id uuid, p_parent_profile_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_rows integer;
begin
  delete from lifeos.communication_profile_memberships
  where child_profile_id = p_child_profile_id and parent_profile_id = p_parent_profile_id;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('removed', v_rows > 0);
end $$;

-- -----------------------------------------------------------------------------
-- 8.2 Rules
-- -----------------------------------------------------------------------------

create or replace function lifeos.communication_rule_upsert(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._rule_upsert(p_input);
end $$;

create or replace function lifeos.communication_rule_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._rule_delete(p_id);
end $$;

create or replace function lifeos.communication_rule_state(p_profile_id uuid default null, p_language_mode text default null)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  perform lifeos._profile_for_rules(p_profile_id);
  return jsonb_build_object(
    'profile_id', p_profile_id,
    'language_mode', p_language_mode,
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'dimension', c.dimension, 'rule_key', c.rule_key,
                                          'rule_text', c.rule_text, 'language_mode', c.language_mode, 'scope', c.scope,
                                          'source_profile_id', c.source_profile_id, 'depth', c.depth,
                                          'priority', c.priority)
                       order by c.scope_rank, c.depth nulls last, c.priority desc nulls last, c.dimension, c.rule_key,
                                (c.language_mode is not null) desc)
      from lifeos._rule_candidates(p_profile_id, p_language_mode) c), '[]'::jsonb));
end $$;

create or replace function lifeos.communication_resolve(p_profile_id uuid default null, p_language_mode text default null)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  perform lifeos._profile_for_rules(p_profile_id);
  return lifeos._resolve(p_profile_id, p_language_mode);
end $$;

-- -----------------------------------------------------------------------------
-- 8.3 Messages
-- -----------------------------------------------------------------------------

create or replace function lifeos.communication_runtime_context(p_profile_id uuid default null,
                                                                p_language_mode text default null,
                                                                p_platform text default null,
                                                                p_history_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._runtime_context(p_profile_id, p_language_mode, p_platform, p_history_limit);
end $$;

create or replace function lifeos.communication_message_finalize(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_changes jsonb;
  v_change jsonb;
  v_applied jsonb := '[]'::jsonb;
  v_limit integer;
  v_id uuid;
  m lifeos.communication_messages;
begin
  perform lifeos._check_fields(v, array['profile_id', 'message_text', 'language_mode', 'platform', 'intent', 'message_mode',
                                        'metadata', 'history_limit', 'rule_changes']);
  perform lifeos._require(v, array['message_text']);
  perform lifeos._check_types(v, p_uuids => array['profile_id'], p_objects => array['metadata'],
                              p_ints => array['history_limit']);
  v := lifeos._strip_top_nulls(v);
  v_limit := lifeos._int_param(v, 'history_limit', 5);
  v_changes := coalesce(v -> 'rule_changes', '[]'::jsonb);
  if jsonb_typeof(v_changes) <> 'array' then
    raise exception 'invalid input' using detail = 'rule_changes must be an array';
  end if;
  if v ? 'profile_id' then
    perform lifeos._require_active('communication_profiles', (v ->> 'profile_id')::uuid);
  end if;

  v_id := lifeos._insert_row('communication_messages',
    (v - 'history_limit' - 'rule_changes') || jsonb_build_object('finalized_at', now()));

  for v_change in select value from jsonb_array_elements(v_changes) loop
    v_change := lifeos._obj(v_change);
    if v_change ->> 'action' = 'upsert' then
      v_applied := v_applied || jsonb_build_array(lifeos._rule_upsert(v_change - 'action'));
    elsif v_change ->> 'action' = 'delete' then
      perform lifeos._check_fields(v_change, array['action', 'id']);
      perform lifeos._require(v_change, array['id']);
      perform lifeos._check_types(v_change, p_uuids => array['id']);
      v_applied := v_applied || jsonb_build_array(
        jsonb_build_object('action', 'deleted') || lifeos._rule_delete((v_change ->> 'id')::uuid));
    else
      raise exception 'invalid input' using detail = 'a rule change action is upsert or delete';
    end if;
  end loop;

  select * into m from lifeos.communication_messages where id = v_id;
  return jsonb_build_object(
    'message', lifeos._message_json(m),
    'rule_changes_applied', v_applied,
    'runtime_context', lifeos._runtime_context(m.profile_id, m.language_mode, m.platform, v_limit));
end $$;

create or replace function lifeos.communication_message_history_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  m lifeos.communication_messages;
begin
  select * into m from lifeos.communication_messages where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._message_json(m);
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
      and (v_profile is null or m.profile_id = v_profile)
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

create or replace function lifeos.communication_message_history_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('communication_messages', p_id);
end $$;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
