-- =============================================================================
-- LifeOS V2, migration 11: fixes of M-0018 D2, D4 and D5.
--
-- D2: expense_spending_report leaves Adjustment Lines out of by_category and by_tag.
-- D4: the note_types Notebook starts with the five default Note Types.
-- D5: adding a Remark and updating a Reading Remark leave updated_at unchanged.
--
-- Changes only functions and one seed row in schema lifeos. Grants stay as they are.
-- =============================================================================

-- D2: by_category and by_tag skip Lines with line_type = 'adjustment'. Part 5 is unchanged.
create or replace function lifeos.expense_spending_report(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_from date;
  v_to date;
  v_currency text;
  v_cur text;
  v_out jsonb := '[]'::jsonb;
  v_total numeric;
  v_count integer;
  v_adj numeric;
begin
  perform lifeos._check_fields(f, array['from_date', 'to_date', 'currency']);
  perform lifeos._require(f, array['from_date', 'to_date']);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  if v_from > v_to then
    raise exception 'invalid input' using detail = 'from_date is after to_date';
  end if;
  v_currency := upper(nullif(btrim(f ->> 'currency'), ''));

  for v_cur in
    select c from (
      select x.currency as c from lifeos.expenses x
      where x.deleted_at is null and x.transaction_date between v_from and v_to
      union
      select r.currency from lifeos.expenses r join lifeos.expenses o on o.id = r.refund_of
      where r.deleted_at is null and r.expense_type = 'refund' and r.transaction_date > v_to
        and o.deleted_at is null and o.transaction_date between v_from and v_to
      union
      select v_currency where v_currency is not null
    ) s
    where v_currency is null or c = v_currency
    order by c
  loop
    select coalesce(sum(x.expense_total), 0), count(*) into v_total, v_count
    from lifeos.expenses x
    where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to;

    select coalesce(sum(l.line_total), 0) into v_adj
    from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
    where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
      and x.expense_type = 'purchase' and l.line_type = 'adjustment';

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'currency', v_cur,
      'parts', jsonb_build_array(
        jsonb_build_object('part', 1, 'name', 'total_spent', 'total', v_total, 'expense_count', v_count),
        jsonb_build_object('part', 2, 'name', 'by_payment_method', 'items', coalesce((
          select jsonb_agg(jsonb_build_object('payment_method_subject_id', g.pm, 'payment_method_name', g.name,
                                              'total', g.total) order by g.total desc, g.name)
          from (select x.payment_method_subject_id as pm, s.name, sum(x.expense_total) as total
                from lifeos.expenses x left join lifeos.subjects s on s.id = x.payment_method_subject_id
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                group by x.payment_method_subject_id, s.name) g), '[]'::jsonb)),
        jsonb_build_object('part', 3, 'name', 'by_category', 'items', coalesce((
          select jsonb_agg(jsonb_build_object('category', g.category, 'total', g.total) order by g.total desc, g.category)
          from (select l.category, sum(l.line_total) as total
                from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                  and x.expense_type = 'purchase' and l.line_type <> 'adjustment'
                group by l.category) g), '[]'::jsonb)),
        jsonb_build_object('part', 4, 'name', 'by_tag', 'items', coalesce((
          select jsonb_agg(jsonb_build_object('tag', g.tag, 'total', g.total) order by g.total desc, g.tag)
          from (select t.tag, sum(l.line_total) as total
                from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
                cross join lateral unnest(l.tags) as t(tag)
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                  and x.expense_type = 'purchase' and l.line_type <> 'adjustment'
                group by t.tag) g), '[]'::jsonb)),
        jsonb_build_object('part', 5, 'name', 'adjustments', 'total', v_adj, 'items', coalesce((
          select jsonb_agg(jsonb_build_object('merchant_name', g.merchant_name, 'merchant_subject_id', g.merchant_subject_id,
                                              'total', g.total) order by g.total asc, g.merchant_name)
          from (select x.merchant_name, x.merchant_subject_id, sum(l.line_total) as total
                from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                  and x.expense_type = 'purchase' and l.line_type = 'adjustment'
                group by x.merchant_name, x.merchant_subject_id) g), '[]'::jsonb))),
      'refunds_in_period', coalesce((
        select jsonb_agg(jsonb_build_object('id', r.id, 'refund_of', o.id, 'transaction_date', r.transaction_date,
                                            'expense_total', r.expense_total,
                                            'original_transaction_date', o.transaction_date,
                                            'original_total', o.expense_total) order by r.transaction_date, r.created_at)
        from lifeos.expenses r
        left join lifeos.expenses o on o.id = r.refund_of and o.deleted_at is null
        where r.deleted_at is null and r.expense_type = 'refund' and r.currency = v_cur
          and r.transaction_date between v_from and v_to), '[]'::jsonb),
      'later_refunds', coalesce((
        select jsonb_agg(jsonb_build_object('id', r.id, 'refund_of', o.id, 'transaction_date', r.transaction_date,
                                            'expense_total', r.expense_total,
                                            'original_transaction_date', o.transaction_date) order by r.transaction_date, r.created_at)
        from lifeos.expenses r join lifeos.expenses o on o.id = r.refund_of
        where r.deleted_at is null and r.expense_type = 'refund' and r.currency = v_cur and r.transaction_date > v_to
          and o.deleted_at is null and o.transaction_date between v_from and v_to), '[]'::jsonb)));
  end loop;

  return jsonb_build_object('from_date', v_from, 'to_date', v_to, 'currencies', v_out);
end $$;

-- D4: a new note_types Notebook starts with the five default Note Types, one per line.
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
  values (p_key, v_name, case p_key
                           when 'defaults' then 'currency: MYR'
                           when 'note_types' then E'Idea\nFeeling\nExperience\nExplanation\nGeneral'
                           else '' end)
  on conflict (key) do nothing;
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end $$;

-- D4: seed note_types on a fresh install. An existing Notebook with content keeps it.
insert into lifeos.notebooks (key, name, content)
values ('note_types', 'Note Types', E'Idea\nFeeling\nExperience\nExplanation\nGeneral')
on conflict (key) do update set content = excluded.content
  where btrim(lifeos.notebooks.content) = '';

-- D5: record_add_remark no longer sets updated_at.
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
  execute format('update lifeos.%I set remarks = remarks || jsonb_build_array($2) where id = $1', v_table)
    using p_id, jsonb_build_object('timestamp', lifeos._ts(now()), 'text', btrim(p_text));
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- D5: reading_remark_add no longer sets updated_at.
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
           'text', btrim(v ->> 'text')))
   where id = p_id;
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = p_id);
end $$;

-- D5: reading_remark_update no longer sets updated_at.
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
     set remark_entries = jsonb_set(remark_entries, array[v_index::text], v_entry)
   where id = p_id;
  return (select lifeos._reading_json(x, false) from lifeos.readings x where x.id = p_id);
end $$;
