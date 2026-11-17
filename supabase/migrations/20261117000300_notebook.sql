-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 3 of 10: Notebook (Contract Chapter 3)
--
-- Creates:
--   1. The internal helpers _notebook_json and _notebook_init.
--   2. The Contract functions notebook_read, notebook_list and notebook_update.
--   3. The defaults Notebook with the content "currency: MYR" (implementation note 11).
--
-- Uses the table lifeos.notebooks and the helpers of migration 1.
-- =============================================================================

create or replace function lifeos._notebook_json(n lifeos.notebooks)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('key', n.key, 'name', n.name, 'content', n.content,
                            'created_at', lifeos._ts(n.created_at), 'updated_at', lifeos._ts(n.updated_at))
$$;

-- Creates the Notebook when absent (Contract 3.1 items 2 to 4). Returns true when this call created it.
create or replace function lifeos._notebook_init(p_key text, p_name text)
returns boolean language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_name text;
  v_rows integer;
begin
  if p_key is null or p_key !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'invalid input' using detail = 'a Notebook key matches ^[a-z][a-z0-9_]*$';
  end if;
  v_name := coalesce(nullif(btrim(p_name), ''),
    case p_key
      when 'subject_types' then 'Subject Types'
      when 'subject_tags' then 'Subject Tags'
      when 'expense_tags' then 'Expense Tags'
      when 'note_types' then 'Note Types'
      when 'defaults' then 'Defaults'
      else p_key
    end);
  insert into lifeos.notebooks (key, name, content)
  values (p_key, v_name, case when p_key = 'defaults' then 'currency: MYR' else '' end)
  on conflict (key) do nothing;
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end $$;

create or replace function lifeos.notebook_read(p_key text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_created boolean;
  n lifeos.notebooks;
begin
  v_created := lifeos._notebook_init(p_key, p_name);
  select * into n from lifeos.notebooks where key = p_key;
  return lifeos._notebook_json(n) || jsonb_build_object('initialised', v_created);
end $$;

create or replace function lifeos.notebook_list(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_pat text;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_pat := lifeos._kw(f);

  select coalesce(jsonb_agg(jsonb_build_object('key', n.key, 'name', n.name,
                                               'content_length', char_length(n.content),
                                               'updated_at', lifeos._ts(n.updated_at)) order by n.key), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.notebooks n
    where v_pat is null or n.key ilike v_pat or n.name ilike v_pat or n.content ilike v_pat
    order by n.key
    limit v_limit offset v_offset
  ) n;

  return lifeos._search_shape(v_res, v_limit, v_offset);
end $$;

create or replace function lifeos.notebook_update(p_key text, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  n lifeos.notebooks;
begin
  v := lifeos._check_changes(p_changes, array['name', 'content']);
  if v ? 'name' and (jsonb_typeof(v -> 'name') <> 'string' or btrim(v ->> 'name') = '') then
    raise exception 'invalid input' using detail = 'name must be non-empty text';
  end if;
  if v ? 'content' and jsonb_typeof(v -> 'content') <> 'string' then
    raise exception 'invalid input' using detail = 'content must be text';
  end if;
  perform lifeos._notebook_init(p_key, null);
  update lifeos.notebooks
     set name = case when v ? 'name' then v ->> 'name' else name end,
         content = case when v ? 'content' then v ->> 'content' else content end,
         updated_at = now()
   where key = p_key
  returning * into n;
  return lifeos._notebook_json(n);
end $$;

-- The defaults Notebook (implementation note 11).
insert into lifeos.notebooks (key, name, content)
values ('defaults', 'Defaults', 'currency: MYR')
on conflict (key) do nothing;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
