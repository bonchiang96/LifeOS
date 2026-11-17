-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 5 of 10: Subject (Contract Chapter 5)
--
-- Creates:
--   1. The internal Record builders _subject_json and _subject_read_json.
--   2. The Contract functions subject_create, subject_read, subject_search, subject_check,
--      subject_update, subject_add_alias, subject_merge and subject_delete.
--
-- Uses the tables of migration 1 and the helpers of migrations 1 and 4.
-- =============================================================================

create or replace function lifeos._subject_json(s lifeos.subjects)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$ select lifeos._row_json(s) $$;

-- Subject plus the derived fields person_profile_id and story_person_ids (Contract 5.2).
create or replace function lifeos._subject_read_json(s lifeos.subjects)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s) || jsonb_build_object(
    'person_profile_id', (select p.id from lifeos.communication_profiles p
                          where p.person_subject_id = s.id and p.profile_type = 'person' and p.deleted_at is null limit 1),
    'story_person_ids', coalesce((select jsonb_agg(sp.id order by sp.created_at) from lifeos.story_persons sp
                                  where sp.subject_id = s.id and sp.deleted_at is null), '[]'::jsonb))
$$;

create or replace function lifeos.subject_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['name', 'subject_type', 'description', 'aliases', 'tags', 'is_user', 'metadata']);
  perform lifeos._require(v, array['name']);
  perform lifeos._check_types(v, p_arrays => array['aliases', 'tags'], p_objects => array['metadata'],
                              p_bools => array['is_user']);
  v := lifeos._strip_top_nulls(v);
  if coalesce((v ->> 'is_user')::boolean, false)
     and exists (select 1 from lifeos.subjects s where s.is_user and s.deleted_at is null) then
    raise exception 'invalid input' using detail = 'another active Subject is the user';
  end if;
  v_id := lifeos._insert_row('subjects', v);
  return (select lifeos._subject_json(s) from lifeos.subjects s where s.id = v_id);
end $$;

create or replace function lifeos.subject_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.subjects;
begin
  select * into s from lifeos.subjects where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._subject_read_json(s);
end $$;

create or replace function lifeos.subject_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_exact text;
  v_type text;
  v_tags text[];
  v_is_user boolean;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'subject_type', 'tags', 'is_user', 'include_deleted',
                                        'limit', 'offset']);
  perform lifeos._check_types(f, p_bools => array['is_user']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_exact := lower(coalesce(nullif(btrim(f ->> 'keyword'), ''), nullif(btrim(f ->> 'query'), '')));
  v_type := nullif(btrim(f ->> 'subject_type'), '');
  v_tags := lifeos._text_list(f -> 'tags');
  v_is_user := (f ->> 'is_user')::boolean;

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'subject_type', s.subject_type,
                                               'aliases', to_jsonb(s.aliases), 'tags', to_jsonb(s.tags),
                                               'is_user', s.is_user, 'description', s.description)
                            order by s.exact_rank, s.updated_at desc, s.id), '[]'::jsonb)
    into v_res
  from (
    select x.*,
           case when v_exact is not null
                     and (lower(x.name) = v_exact or exists (select 1 from unnest(x.aliases) a where lower(a) = v_exact))
                then 0 else 1 end as exact_rank
    from lifeos.subjects x
    where (v_inc or x.deleted_at is null)
      and (v_type is null or lower(x.subject_type) = lower(v_type))
      and (v_tags is null or x.tags && v_tags)
      and (v_is_user is null or x.is_user = v_is_user)
      and (v_pat is null or x.name ilike v_pat or x.description ilike v_pat or x.subject_type ilike v_pat
           or lifeos._array_match(x.aliases, v_pat) or lifeos._array_match(x.tags, v_pat))
    order by exact_rank, x.updated_at desc, x.id
    limit v_limit offset v_offset
  ) s;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.subject_check(p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_text text := lower(btrim(p_text));
  v_matches jsonb;
begin
  if v_text is null or v_text = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'subject_type', m.subject_type,
                                               'matched_on', m.matched_on) order by m.matched_on desc, m.name, m.id), '[]'::jsonb)
    into v_matches
  from (
    select s.id, s.name, s.subject_type,
           case when lower(btrim(s.name)) = v_text then 'name' else 'alias' end as matched_on
    from lifeos.subjects s
    where s.deleted_at is null
      and (lower(btrim(s.name)) = v_text
           or exists (select 1 from unnest(s.aliases) a where lower(btrim(a)) = v_text))
  ) m;
  return jsonb_build_object('exists', jsonb_array_length(v_matches) > 0, 'matches', v_matches);
end $$;

create or replace function lifeos.subject_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  s lifeos.subjects;
begin
  select * into s from lifeos.subjects where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['name', 'subject_type', 'description', 'aliases', 'tags', 'is_user', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['aliases', 'tags'], p_objects => array['metadata'],
                              p_bools => array['is_user']);
  v := lifeos._prep_changes(v, p_required => array['name'], p_arrays => array['aliases', 'tags'],
                            p_objects => array['metadata']);
  if v ? 'is_user' and jsonb_typeof(v -> 'is_user') = 'null' then
    v := jsonb_set(v, '{is_user}', 'false'::jsonb);
  end if;
  if coalesce((v ->> 'is_user')::boolean, false)
     and exists (select 1 from lifeos.subjects x where x.is_user and x.deleted_at is null and x.id <> p_id) then
    raise exception 'invalid input' using detail = 'another active Subject is the user';
  end if;
  perform lifeos._update_row('subjects', p_id, v);
  return (select lifeos._subject_json(x) from lifeos.subjects x where x.id = p_id);
end $$;

create or replace function lifeos.subject_add_alias(p_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.subjects;
  v_alias text := btrim(p_text);
begin
  if v_alias is null or v_alias = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  select * into s from lifeos.subjects where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  if not exists (select 1 from unnest(s.aliases) a where lower(a) = lower(v_alias)) then
    update lifeos.subjects set aliases = aliases || v_alias, updated_at = now() where id = p_id;
  end if;
  return (select lifeos._subject_json(x) from lifeos.subjects x where x.id = p_id);
end $$;

create or replace function lifeos.subject_merge(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_identity jsonb;
  v_keep uuid;
  v_merge uuid;
  k lifeos.subjects;
  m lifeos.subjects;
  l lifeos.record_links;
  v_other_type text;
  v_other_id uuid;
  v_a_type text;
  v_a_id uuid;
  v_b_type text;
  v_b_id uuid;
  n_links integer := 0;
  n_obs integer := 0;
  n_pay integer := 0;
  n_merchant integer := 0;
  n_line integer := 0;
  n_story integer := 0;
  n_profile integer := 0;
begin
  perform lifeos._check_fields(v, array['keep_id', 'merge_id', 'identity']);
  perform lifeos._require(v, array['keep_id', 'merge_id', 'identity']);
  perform lifeos._check_types(v, p_uuids => array['keep_id', 'merge_id'], p_objects => array['identity']);
  v_identity := v -> 'identity';
  perform lifeos._check_fields(v_identity, array['name', 'subject_type', 'description', 'aliases', 'tags']);
  perform lifeos._check_types(v_identity, p_arrays => array['aliases', 'tags']);
  v_identity := lifeos._prep_changes(v_identity, p_required => array['name'], p_arrays => array['aliases', 'tags']);
  v_keep := (v ->> 'keep_id')::uuid;
  v_merge := (v ->> 'merge_id')::uuid;
  if v_keep = v_merge then
    raise exception 'invalid relationship' using detail = 'keep_id and merge_id are the same Subject';
  end if;

  select * into k from lifeos.subjects where id = v_keep for update;
  if not found then
    raise exception 'record not found' using detail = 'keep_id';
  end if;
  if k.deleted_at is not null then
    raise exception 'record deleted' using detail = 'keep_id';
  end if;
  select * into m from lifeos.subjects where id = v_merge for update;
  if not found then
    raise exception 'record not found' using detail = 'merge_id';
  end if;
  if m.deleted_at is not null then
    raise exception 'record deleted' using detail = 'merge_id';
  end if;

  if exists (select 1 from lifeos.communication_profiles p where p.person_subject_id = v_keep and p.deleted_at is null)
     and exists (select 1 from lifeos.communication_profiles p where p.person_subject_id = v_merge and p.deleted_at is null) then
    raise exception 'invalid relationship' using detail = 'both Subjects have an active Person Profile';
  end if;

  -- Record links: move each link to the kept Subject. A link that becomes a duplicate pair is removed.
  for l in select * from lifeos.record_links x
           where (x.record_type_a = 'subject' and x.record_id_a = v_merge)
              or (x.record_type_b = 'subject' and x.record_id_b = v_merge) loop
    if l.record_type_a = 'subject' and l.record_id_a = v_merge then
      v_other_type := l.record_type_b; v_other_id := l.record_id_b;
    else
      v_other_type := l.record_type_a; v_other_id := l.record_id_a;
    end if;
    if ('subject', v_keep::text) < (v_other_type, v_other_id::text) then
      v_a_type := 'subject'; v_a_id := v_keep; v_b_type := v_other_type; v_b_id := v_other_id;
    else
      v_a_type := v_other_type; v_a_id := v_other_id; v_b_type := 'subject'; v_b_id := v_keep;
    end if;
    if exists (select 1 from lifeos.record_links x
               where x.record_type_a = v_a_type and x.record_id_a = v_a_id
                 and x.record_type_b = v_b_type and x.record_id_b = v_b_id) then
      delete from lifeos.record_links where id = l.id;
    else
      update lifeos.record_links
         set record_type_a = v_a_type, record_id_a = v_a_id, record_type_b = v_b_type, record_id_b = v_b_id
       where id = l.id;
    end if;
    n_links := n_links + 1;
  end loop;

  -- Typed reference fields. Source Records stay unchanged except for their Subject references.
  update lifeos.observations set subject_id = v_keep where subject_id = v_merge;
  get diagnostics n_obs = row_count;
  update lifeos.expenses set payment_method_subject_id = v_keep where payment_method_subject_id = v_merge;
  get diagnostics n_pay = row_count;
  update lifeos.expenses set merchant_subject_id = v_keep where merchant_subject_id = v_merge;
  get diagnostics n_merchant = row_count;
  update lifeos.expense_lines set item_subject_id = v_keep where item_subject_id = v_merge;
  get diagnostics n_line = row_count;
  update lifeos.story_persons set subject_id = v_keep where subject_id = v_merge;
  get diagnostics n_story = row_count;
  update lifeos.communication_profiles set person_subject_id = v_keep where person_subject_id = v_merge;
  get diagnostics n_profile = row_count;

  -- Close the merged Subject. Its own fields stay stored.
  update lifeos.subjects set merged_into_id = v_keep, deleted_at = now(), updated_at = now() where id = v_merge;

  -- The kept Subject takes the merged identity, and the user flag when the merged Subject was the user.
  if m.is_user then
    v_identity := v_identity || jsonb_build_object('is_user', true);
  end if;
  perform lifeos._update_row('subjects', v_keep, v_identity);

  return jsonb_build_object(
    'subject', (select lifeos._subject_read_json(x) from lifeos.subjects x where x.id = v_keep),
    'merged_id', v_merge,
    'moved_references', jsonb_build_object(
      'record_link', n_links,
      'observation_subject', n_obs,
      'payment_method', n_pay,
      'merchant', n_merchant,
      'line_item', n_line,
      'story_person_subject', n_story,
      'person_profile_subject', n_profile));
end $$;

create or replace function lifeos.subject_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('subjects', p_id);
end $$;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
