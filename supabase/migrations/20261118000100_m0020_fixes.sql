-- =============================================================================
-- LifeOS V2, migration 12: fixes of M-0020 D1, D2, D4 and D7.
--
-- F1 and D2: every Remark has a remark_id. A Remark and a Reading Remark entry can be
--   changed or deleted without an edit.
-- F2: record_link_create rejects a link between a Reading and a Storyline.
-- C F-1: the expense_create_batch error ends with the 0-based item index.
-- S1: subject_records on a deleted Subject returns "record not found".
-- S2: subject_merge rejects an empty identity.
-- S5: a Refund cannot exceed the original amount or precede the original date.
-- S6: a Reading lists a Subject once, also in its Timeline subjects.
-- D4: reading_story_persons_set leaves the Reading's updated_at unchanged.
--
-- Changes functions and Remark data in schema lifeos. Creates three Contract functions:
-- record_update_remark, record_delete_remark and reading_remark_delete.
-- Grants of changed functions stay as they are.
-- =============================================================================

-- F1: a Remark given at create time gets a remark_id.
create or replace function lifeos._remarks_normalize(p jsonb)
returns jsonb language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_out jsonb := '[]'::jsonb;
  e jsonb;
  v_text text;
  v_ts timestamptz;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return v_out;
  end if;
  if jsonb_typeof(p) <> 'array' then
    raise exception 'invalid input' using detail = 'remarks must be an array';
  end if;
  for e in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(e) = 'string' then
      v_text := btrim(e #>> '{}');
      v_ts := now();
    elsif jsonb_typeof(e) = 'object' then
      perform lifeos._check_fields(e, array['text', 'timestamp']);
      v_text := btrim(e ->> 'text');
      if e ? 'timestamp' and jsonb_typeof(e -> 'timestamp') <> 'null' then
        v_ts := lifeos._parse_ts(e ->> 'timestamp', 'UTC');
      else
        v_ts := now();
      end if;
    else
      raise exception 'invalid input' using detail = 'a Remark is a string or an object with text';
    end if;
    if v_text is null or v_text = '' then
      raise exception 'invalid input' using detail = 'a Remark needs non-empty text';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('remark_id', gen_random_uuid(),
                                                           'timestamp', lifeos._ts(v_ts), 'text', v_text));
  end loop;
  return v_out;
end $$;

-- F1: record_add_remark appends a Remark with a new remark_id.
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
    using p_id, jsonb_build_object('remark_id', gen_random_uuid(), 'timestamp', lifeos._ts(now()), 'text', btrim(p_text));
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- F1: backfill a remark_id into every stored Remark of the five Record tables.
-- The update sets only remarks, so updated_at, edited_at and Expense versions stay unchanged.
do $$
declare
  v_table text;
begin
  foreach v_table in array array['schedules', 'events', 'observations', 'notes', 'expenses'] loop
    execute format(
      'update lifeos.%I t
          set remarks = (select jsonb_agg(case when x.e ? ''remark_id'' then x.e
                                               else x.e || jsonb_build_object(''remark_id'', gen_random_uuid()) end
                                          order by x.ord)
                         from jsonb_array_elements(t.remarks) with ordinality x(e, ord))
        where exists (select 1 from jsonb_array_elements(t.remarks) y(e) where not (y.e ? ''remark_id''))',
      v_table);
  end loop;
end $$;

-- F1 and D2: replace the text of one Remark. remark_id, timestamp and updated_at stay.
create or replace function lifeos.record_update_remark(p_record_type text, p_id uuid, p_remark_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text;
  v_remarks jsonb;
  v_index integer;
begin
  if p_record_type is null or p_record_type not in ('schedule', 'event', 'observation', 'note', 'expense') then
    raise exception 'invalid input' using detail = 'p_record_type is schedule, event, observation, note or expense';
  end if;
  if p_text is null or btrim(p_text) = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  v_table := lifeos._record_table(p_record_type);
  perform lifeos._require_active(v_table, p_id);
  execute format('select remarks from lifeos.%I where id = $1 for update', v_table) into v_remarks using p_id;
  select e.ord - 1 into v_index
  from jsonb_array_elements(v_remarks) with ordinality e(value, ord)
  where e.value ->> 'remark_id' = p_remark_id::text;
  if v_index is null then
    raise exception 'record not found' using detail = 'remark_id';
  end if;
  execute format('update lifeos.%I set remarks = jsonb_set(remarks, $2, $3) where id = $1', v_table)
    using p_id, array[v_index::text, 'text'], to_jsonb(btrim(p_text));
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- F1 and D2: remove one Remark. updated_at stays.
create or replace function lifeos.record_delete_remark(p_record_type text, p_id uuid, p_remark_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text;
  v_remarks jsonb;
  v_index integer;
begin
  if p_record_type is null or p_record_type not in ('schedule', 'event', 'observation', 'note', 'expense') then
    raise exception 'invalid input' using detail = 'p_record_type is schedule, event, observation, note or expense';
  end if;
  v_table := lifeos._record_table(p_record_type);
  perform lifeos._require_active(v_table, p_id);
  execute format('select remarks from lifeos.%I where id = $1 for update', v_table) into v_remarks using p_id;
  select e.ord - 1 into v_index
  from jsonb_array_elements(v_remarks) with ordinality e(value, ord)
  where e.value ->> 'remark_id' = p_remark_id::text;
  if v_index is null then
    raise exception 'record not found' using detail = 'remark_id';
  end if;
  execute format('update lifeos.%I set remarks = remarks - $2 where id = $1', v_table) using p_id, v_index;
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- F1 and D2: remove one Reading Remark entry. updated_at and the Analyses stay.
create or replace function lifeos.reading_remark_delete(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  r lifeos.readings;
  v_index integer;
begin
  perform lifeos._check_fields(v, array['entry_id']);
  perform lifeos._require(v, array['entry_id']);
  perform lifeos._check_types(v, p_uuids => array['entry_id']);
  select * into r from lifeos.readings where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  select e.ord - 1 into v_index
  from jsonb_array_elements(r.remark_entries) with ordinality e(value, ord)
  where e.value ->> 'entry_id' = v ->> 'entry_id';
  if v_index is null then
    raise exception 'record not found' using detail = 'entry_id';
  end if;
  update lifeos.readings set remark_entries = remark_entries - v_index where id = p_id;
  return (select lifeos._reading_json(x, false) from lifeos.readings x where x.id = p_id);
end $$;

-- F1 and D2: the three new functions are Contract functions (implementation note 15).
revoke execute on function lifeos.record_update_remark(text, uuid, uuid, text) from public, anon, authenticated;
revoke execute on function lifeos.record_delete_remark(text, uuid, uuid) from public, anon, authenticated;
revoke execute on function lifeos.reading_remark_delete(uuid, jsonb) from public, anon, authenticated;
grant execute on function lifeos.record_update_remark(text, uuid, uuid, text) to anon, authenticated;
grant execute on function lifeos.record_delete_remark(text, uuid, uuid) to anon, authenticated;
grant execute on function lifeos.reading_remark_delete(uuid, jsonb) to anon, authenticated;

-- F2: a Reading and a Storyline cannot be linked, in either order.
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

-- C F-1: the error text is the item's own error text followed by " at item <n>", with a 0-based n.
create or replace function lifeos.expense_create_batch(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_item jsonb;
  v_index integer := -1;
  v_ids uuid[] := '{}';
  v_state text;
  v_msg text;
  v_detail text;
begin
  perform lifeos._check_fields(v, array['expenses']);
  perform lifeos._require(v, array['expenses']);
  if jsonb_typeof(v -> 'expenses') <> 'array' or jsonb_array_length(v -> 'expenses') = 0 then
    raise exception 'invalid input' using detail = 'expenses needs at least one item';
  end if;
  for v_item in select value from jsonb_array_elements(v -> 'expenses') loop
    v_index := v_index + 1;
    begin
      if v_item ? 'expense_type' or v_item ? 'refund_of' then
        raise exception 'unsupported field' using detail = 'expense_type and refund_of are not accepted';
      end if;
      v_ids := v_ids || lifeos._expense_insert(v_item);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
      raise exception '% at item %', v_msg, v_index using errcode = v_state,
        detail = concat_ws('; ', format('expenses item index %s (0-based)', v_index), nullif(v_detail, ''));
    end;
  end loop;
  return jsonb_build_object(
    'results', (select jsonb_agg(lifeos._expense_json(x) order by t.ord)
                from unnest(v_ids) with ordinality t(id, ord) join lifeos.expenses x on x.id = t.id),
    'returned_count', cardinality(v_ids));
end $$;

-- S5: a Refund is at most the original total, together with the active Refunds of the same
-- original, and is dated on or after the original transaction date.
create or replace function lifeos.expense_refund_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  o lifeos.expenses;
  v_amount numeric;
  v_refunded numeric;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['refund_of', 'refund_amount', 'transaction_date', 'transaction_time',
    'item_description', 'item_subject_id', 'line_type', 'remarks', 'metadata']);
  perform lifeos._require(v, array['refund_of', 'refund_amount', 'transaction_date', 'line_type']);
  perform lifeos._check_types(v, p_dates => array['transaction_date'], p_times => array['transaction_time'],
                              p_uuids => array['refund_of', 'item_subject_id'], p_nums => array['refund_amount'],
                              p_objects => array['metadata']);
  select * into o from lifeos.expenses where id = (v ->> 'refund_of')::uuid for update;
  if not found then
    raise exception 'record not found' using detail = 'refund_of';
  end if;
  if o.deleted_at is not null then
    raise exception 'record deleted' using detail = 'refund_of';
  end if;
  if o.expense_type <> 'purchase' then
    raise exception 'invalid relationship' using detail = 'the original is a purchase Expense';
  end if;
  v_amount := (v ->> 'refund_amount')::numeric;
  if v_amount <= 0 then
    raise exception 'invalid input' using detail = 'refund_amount is positive';
  end if;
  if v ->> 'line_type' not in ('item', 'charge', 'adjustment') then
    raise exception 'invalid input' using detail = 'line_type is item, charge or adjustment';
  end if;
  if (v ->> 'transaction_date')::date < o.transaction_date then
    raise exception 'invalid input' using detail = 'transaction_date is on or after the original transaction_date';
  end if;
  select coalesce(sum(-r.expense_total), 0) into v_refunded
  from lifeos.expenses r
  where r.refund_of = o.id and r.expense_type = 'refund' and r.deleted_at is null;
  if v_refunded + v_amount > o.expense_total then
    raise exception 'invalid input' using detail = format('refund_amount with earlier Refunds (%s) is above the original total %s',
                                                         v_refunded, o.expense_total);
  end if;
  if v ? 'item_subject_id' and jsonb_typeof(v -> 'item_subject_id') <> 'null' then
    perform lifeos._require_active('subjects', (v ->> 'item_subject_id')::uuid);
  end if;

  v_id := lifeos._insert_row('expenses', lifeos._strip_top_nulls(jsonb_build_object(
    'expense_type', 'refund',
    'refund_of', o.id,
    'transaction_date', v -> 'transaction_date',
    'transaction_time', v -> 'transaction_time',
    'merchant_name', o.merchant_name,
    'branch', o.branch,
    'merchant_subject_id', o.merchant_subject_id,
    'seller_name', o.seller_name,
    'payment_method_subject_id', o.payment_method_subject_id,
    'expense_total', -v_amount,
    'currency', o.currency,
    'remarks', lifeos._remarks_normalize(v -> 'remarks'),
    'metadata', coalesce(v -> 'metadata', '{}'::jsonb))));

  perform lifeos._insert_row('expense_lines', lifeos._strip_top_nulls(jsonb_build_object(
    'expense_id', v_id,
    'line_no', 1,
    'line_type', v ->> 'line_type',
    'item_description', v -> 'item_description',
    'quantity', 1,
    'unit_price', -v_amount,
    'line_total', -v_amount,
    'category', null,
    'tags', '[]'::jsonb,
    'item_subject_id', v -> 'item_subject_id')));

  return (select lifeos._expense_json(x) from lifeos.expenses x where x.id = v_id)
         || jsonb_build_object('original', lifeos._expense_original(o.id));
end $$;

-- S2: an empty identity returns "invalid input".
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
  if v_identity = '{}'::jsonb then
    raise exception 'invalid input' using detail = 'identity needs at least one field';
  end if;
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

-- S1: a deleted Subject, merged Subjects included, returns "record not found".
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
  if not exists (select 1 from lifeos.subjects s where s.id = p_id and s.deleted_at is null) then
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

-- S6: a Reading lists a Subject once. A Record link to the Subject takes precedence over
-- the same Subject through a Story Person. The Timeline subjects of a Reading follow.
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
    -- Reading and Storyline -> Subjects of their Story Persons.
    -- S6: a Reading skips a Story Person Subject that a Record link already lists.
    union all
    select distinct 'story_person_subject', 'subject', sp.subject_id
    from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
    where p_type = 'reading' and rsp.reading_id = p_id and sp.deleted_at is null and sp.subject_id is not null
      and not exists (select 1 from lifeos.record_links rl
                      where (rl.record_type_a = 'reading' and rl.record_id_a = p_id
                             and rl.record_type_b = 'subject' and rl.record_id_b = sp.subject_id)
                         or (rl.record_type_b = 'reading' and rl.record_id_b = p_id
                             and rl.record_type_a = 'subject' and rl.record_id_a = sp.subject_id))
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

-- D4: reading_story_persons_set changes only the association. updated_at stays.
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
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = p_id);
end $$;
