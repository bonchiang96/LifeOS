-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 6 of 10: Financial Records (Contract Chapter 6)
--
-- Creates:
--   1. The internal helpers _expense_core, _expense_json, _expense_original,
--      _expense_lines_insert, _expense_insert and _expense_snapshot.
--   2. The Contract functions expense_create, expense_create_batch, expense_read,
--      expense_search, expense_update, expense_history, expense_delete,
--      expense_refund_create, expense_spending_report and expense_category_list.
--
-- Uses the tables lifeos.expenses, lifeos.expense_lines and lifeos.expense_versions.
-- =============================================================================

-- Stored Expense with its Lines, as kept in a history snapshot.
create or replace function lifeos._expense_core(x lifeos.expenses)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(x) || jsonb_build_object('lines', coalesce(
    (select jsonb_agg(lifeos._row_json(l) order by l.line_no) from lifeos.expense_lines l where l.expense_id = x.id),
    '[]'::jsonb))
$$;

-- Complete Expense Record with lines, discrepancies, refunds and version (Contract 6, derived fields).
create or replace function lifeos._expense_json(x lifeos.expenses)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  j jsonb := lifeos._row_json(x);
  v_lines jsonb;
  v_sum numeric;
  v_count integer;
  v_disc jsonb := '[]'::jsonb;
begin
  -- Scalar references to deleted targets are returned as null (Contract 1.5 item 9).
  if x.merchant_subject_id is not null
     and not exists (select 1 from lifeos.subjects s where s.id = x.merchant_subject_id and s.deleted_at is null) then
    j := jsonb_set(j, '{merchant_subject_id}', 'null'::jsonb);
  end if;
  if not exists (select 1 from lifeos.subjects s where s.id = x.payment_method_subject_id and s.deleted_at is null) then
    j := jsonb_set(j, '{payment_method_subject_id}', 'null'::jsonb);
  end if;
  if x.refund_of is not null
     and not exists (select 1 from lifeos.expenses o where o.id = x.refund_of and o.deleted_at is null) then
    j := jsonb_set(j, '{refund_of}', 'null'::jsonb);
  end if;

  select coalesce(jsonb_agg(lifeos._row_json(l)
                            || case when l.item_subject_id is not null
                                         and not exists (select 1 from lifeos.subjects s
                                                         where s.id = l.item_subject_id and s.deleted_at is null)
                                    then jsonb_build_object('item_subject_id', null) else '{}'::jsonb end
                            order by l.line_no), '[]'::jsonb),
         sum(l.line_total), count(*)
    into v_lines, v_sum, v_count
  from lifeos.expense_lines l where l.expense_id = x.id;

  if v_count > 0 and v_sum <> x.expense_total then
    v_disc := v_disc || jsonb_build_array(jsonb_build_object('check', 'lines_sum', 'expense_total', x.expense_total,
                                                             'lines_sum', v_sum));
  end if;
  v_disc := v_disc || coalesce((
    select jsonb_agg(jsonb_build_object('check', 'quantity_x_unit_price', 'line_id', l.id, 'line_total', l.line_total,
                                        'computed', l.quantity * l.unit_price) order by l.line_no)
    from lifeos.expense_lines l
    where l.expense_id = x.id and l.quantity * l.unit_price <> l.line_total), '[]'::jsonb);

  return j || jsonb_build_object(
    'lines', v_lines,
    'discrepancies', v_disc,
    'refunds', case when x.expense_type = 'purchase' then coalesce((
        select jsonb_agg(jsonb_build_object('id', r.id, 'transaction_date', r.transaction_date,
                                            'transaction_time', r.transaction_time, 'expense_total', r.expense_total,
                                            'currency', r.currency) order by r.transaction_date, r.created_at)
        from lifeos.expenses r where r.refund_of = x.id and r.deleted_at is null), '[]'::jsonb)
      else '[]'::jsonb end,
    'version', (select count(*) + 1 from lifeos.expense_versions h where h.expense_id = x.id));
end $$;

-- Compact original Expense of a Refund (Contract 6.3). null when the original is deleted.
create or replace function lifeos._expense_original(p_id uuid)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('id', o.id, 'transaction_date', o.transaction_date, 'merchant_name', o.merchant_name,
                            'expense_total', o.expense_total)
  from lifeos.expenses o where o.id = p_id and o.deleted_at is null
$$;

-- Validates and inserts the Lines of one Expense (Contract 6, Line validation).
create or replace function lifeos._expense_lines_insert(p_expense_id uuid, p_lines jsonb, p_purchase boolean)
returns void language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_item jsonb;
  v_no integer := 0;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'invalid input' using detail = 'lines needs at least one item';
  end if;
  for v_item in select value from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_item := lifeos._obj(v_item);
    perform lifeos._check_fields(v_item, array['line_type', 'item_description', 'source_item_text', 'quantity',
      'unit_price', 'line_total', 'category', 'tags', 'item_subject_id', 'metadata']);
    perform lifeos._require(v_item, case when p_purchase then array['unit_price', 'line_total', 'line_type', 'category']
                                         else array['unit_price', 'line_total', 'line_type'] end);
    perform lifeos._check_types(v_item, p_nums => array['quantity', 'unit_price', 'line_total'],
                                p_uuids => array['item_subject_id'], p_arrays => array['tags'],
                                p_objects => array['metadata']);
    if v_item ->> 'line_type' not in ('item', 'charge', 'adjustment') then
      raise exception 'invalid input' using detail = format('line %s: line_type is item, charge or adjustment', v_no);
    end if;
    if v_item ? 'category' and jsonb_typeof(v_item -> 'category') <> 'null'
       and v_item ->> 'category' <> all (lifeos._expense_categories()) then
      raise exception 'invalid input' using detail = format('line %s: category is one of the 17 Categories', v_no);
    end if;
    if v_item ? 'tags' and jsonb_typeof(v_item -> 'tags') = 'array' and jsonb_array_length(v_item -> 'tags') > 10 then
      raise exception 'invalid input' using detail = format('line %s: at most ten Tags', v_no);
    end if;
    if v_item ? 'item_subject_id' and jsonb_typeof(v_item -> 'item_subject_id') <> 'null' then
      perform lifeos._require_active('subjects', (v_item ->> 'item_subject_id')::uuid);
    end if;
    perform lifeos._insert_row('expense_lines',
      lifeos._strip_top_nulls(v_item) || jsonb_build_object('expense_id', p_expense_id, 'line_no', v_no));
  end loop;
end $$;

-- Validates and inserts one purchase Expense with its Lines (Contract 6.1). Returns the new ID.
create or replace function lifeos._expense_insert(p_input jsonb)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
  v_currency text;
begin
  perform lifeos._check_fields(v, array['transaction_date', 'transaction_time', 'merchant_name', 'branch',
    'merchant_subject_id', 'seller_name', 'payment_method_subject_id', 'expense_total', 'currency', 'remarks',
    'metadata', 'lines']);
  perform lifeos._require(v, array['transaction_date', 'payment_method_subject_id', 'expense_total', 'currency', 'lines']);
  perform lifeos._check_types(v, p_dates => array['transaction_date'], p_times => array['transaction_time'],
                              p_uuids => array['merchant_subject_id', 'payment_method_subject_id'],
                              p_nums => array['expense_total'], p_objects => array['metadata']);
  if (v ->> 'expense_total')::numeric < 0 then
    raise exception 'invalid input' using detail = 'expense_total is zero or positive';
  end if;
  v_currency := upper(btrim(v ->> 'currency'));
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'invalid input' using detail = 'currency is an ISO 4217 code';
  end if;
  if jsonb_typeof(v -> 'lines') <> 'array' or jsonb_array_length(v -> 'lines') = 0 then
    raise exception 'invalid input' using detail = 'lines needs at least one item';
  end if;
  perform lifeos._require_active('subjects', (v ->> 'payment_method_subject_id')::uuid);
  if v ? 'merchant_subject_id' and jsonb_typeof(v -> 'merchant_subject_id') <> 'null' then
    perform lifeos._require_active('subjects', (v ->> 'merchant_subject_id')::uuid);
  end if;

  v_id := lifeos._insert_row('expenses',
    lifeos._strip_top_nulls(v - 'lines' - 'remarks')
    || jsonb_build_object('expense_type', 'purchase', 'currency', v_currency,
                          'remarks', lifeos._remarks_normalize(v -> 'remarks')));
  perform lifeos._expense_lines_insert(v_id, v -> 'lines', true);
  return v_id;
end $$;

-- Saves the current Expense as one history version (Contract 6.5 item 1, 6.7 item 1).
create or replace function lifeos._expense_snapshot(x lifeos.expenses, p_reason text)
returns void language sql volatile set search_path = lifeos, pg_temp
as $$
  insert into lifeos.expense_versions (expense_id, version_no, snapshot, correction_reason, corrected_at)
  select x.id, count(*) + 1, lifeos._expense_core(x), p_reason, now()
  from lifeos.expense_versions h where h.expense_id = x.id
$$;

create or replace function lifeos.expense_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_input ? 'expense_type' or p_input ? 'refund_of' then
    raise exception 'unsupported field' using detail = 'expense_type and refund_of are not accepted; a Refund uses expense_refund_create';
  end if;
  v_id := lifeos._expense_insert(p_input);
  return (select lifeos._expense_json(x) from lifeos.expenses x where x.id = v_id);
end $$;

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
      raise exception '%', v_msg using errcode = v_state,
        detail = concat_ws('; ', format('expenses item index %s (0-based)', v_index), nullif(v_detail, ''));
    end;
  end loop;
  return jsonb_build_object(
    'results', (select jsonb_agg(lifeos._expense_json(x) order by t.ord)
                from unnest(v_ids) with ordinality t(id, ord) join lifeos.expenses x on x.id = t.id),
    'returned_count', cardinality(v_ids));
end $$;

create or replace function lifeos.expense_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  j jsonb;
begin
  select * into x from lifeos.expenses where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  j := lifeos._expense_json(x) || jsonb_build_object('links', lifeos._links('expense', p_id));
  if x.expense_type = 'refund' then
    j := j || jsonb_build_object('original', lifeos._expense_original(x.refund_of));
  end if;
  return j;
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
      and (v_pay is null or x.payment_method_subject_id = v_pay)
      and (v_merchant is null or x.merchant_subject_id = v_merchant)
      and (v_refund_of is null or x.refund_of = v_refund_of)
      and (v_currency is null or x.currency = v_currency)
      and (v_item is null or exists (select 1 from lifeos.expense_lines l where l.expense_id = x.id and l.item_subject_id = v_item))
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

create or replace function lifeos.expense_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  v jsonb;
  c jsonb;
  v_reason text;
  v_amount numeric;
  v_line jsonb := '{}'::jsonb;
begin
  select * into x from lifeos.expenses where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if x.deleted_at is not null then
    raise exception 'record deleted';
  end if;

  if x.expense_type = 'purchase' then
    v := lifeos._check_changes(p_changes, array['transaction_date', 'transaction_time', 'merchant_name', 'branch',
      'merchant_subject_id', 'seller_name', 'payment_method_subject_id', 'expense_total', 'currency', 'metadata', 'lines',
      'correction_reason']);
  else
    v := lifeos._check_changes(p_changes, array['transaction_date', 'transaction_time', 'refund_amount',
      'item_description', 'item_subject_id', 'line_type', 'metadata', 'correction_reason']);
  end if;
  perform lifeos._require(v, array['correction_reason']);
  v_reason := btrim(v ->> 'correction_reason');
  c := v - 'correction_reason';
  if c = '{}'::jsonb then
    raise exception 'invalid input' using detail = 'at least one change field is required besides correction_reason';
  end if;
  perform lifeos._check_types(c, p_dates => array['transaction_date'], p_times => array['transaction_time'],
                              p_uuids => array['merchant_subject_id', 'payment_method_subject_id', 'item_subject_id'],
                              p_nums => array['expense_total', 'refund_amount'], p_objects => array['metadata']);

  -- Snapshot of the current version before the change (Contract 6.5 item 1).
  perform lifeos._expense_snapshot(x, v_reason);

  if x.expense_type = 'purchase' then
    c := lifeos._prep_changes(c, p_required => array['transaction_date', 'payment_method_subject_id', 'expense_total',
                                                     'currency', 'lines'], p_objects => array['metadata']);
    if c ? 'expense_total' and (c ->> 'expense_total')::numeric < 0 then
      raise exception 'invalid input' using detail = 'expense_total is zero or positive';
    end if;
    if c ? 'currency' then
      if upper(btrim(c ->> 'currency')) !~ '^[A-Z]{3}$' then
        raise exception 'invalid input' using detail = 'currency is an ISO 4217 code';
      end if;
      c := jsonb_set(c, '{currency}', to_jsonb(upper(btrim(c ->> 'currency'))));
    end if;
    if c ? 'payment_method_subject_id' then
      perform lifeos._require_active('subjects', (c ->> 'payment_method_subject_id')::uuid);
    end if;
    if c ? 'merchant_subject_id' and jsonb_typeof(c -> 'merchant_subject_id') <> 'null' then
      perform lifeos._require_active('subjects', (c ->> 'merchant_subject_id')::uuid);
    end if;
    if c ? 'lines' then
      delete from lifeos.expense_lines where expense_id = p_id;
      perform lifeos._expense_lines_insert(p_id, c -> 'lines', true);
    end if;
    perform lifeos._update_row('expenses', p_id, c - 'lines');
  else
    c := lifeos._prep_changes(c, p_required => array['transaction_date', 'refund_amount', 'line_type'],
                              p_objects => array['metadata']);
    if c ? 'refund_amount' then
      v_amount := (c ->> 'refund_amount')::numeric;
      if v_amount <= 0 then
        raise exception 'invalid input' using detail = 'refund_amount is positive';
      end if;
      c := c || jsonb_build_object('expense_total', -v_amount);
      v_line := v_line || jsonb_build_object('unit_price', -v_amount, 'line_total', -v_amount);
    end if;
    if c ? 'line_type' then
      if c ->> 'line_type' not in ('item', 'charge', 'adjustment') then
        raise exception 'invalid input' using detail = 'line_type is item, charge or adjustment';
      end if;
      v_line := v_line || jsonb_build_object('line_type', c -> 'line_type');
    end if;
    if c ? 'item_description' then
      v_line := v_line || jsonb_build_object('item_description', c -> 'item_description');
    end if;
    if c ? 'item_subject_id' then
      if jsonb_typeof(c -> 'item_subject_id') <> 'null' then
        perform lifeos._require_active('subjects', (c ->> 'item_subject_id')::uuid);
      end if;
      v_line := v_line || jsonb_build_object('item_subject_id', c -> 'item_subject_id');
    end if;
    if v_line <> '{}'::jsonb then
      perform lifeos._update_row('expense_lines', l.id, v_line)
      from lifeos.expense_lines l where l.expense_id = p_id;
    end if;
    perform lifeos._update_row('expenses', p_id,
      c - 'refund_amount' - 'item_description' - 'item_subject_id' - 'line_type');
  end if;

  return (select lifeos._expense_json(y) from lifeos.expenses y where y.id = p_id);
end $$;

create or replace function lifeos.expense_history(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  v_history jsonb;
begin
  select * into x from lifeos.expenses where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  -- Each stored row is the snapshot of version n and the reason for the change to version n + 1.
  with v as (
    select h.version_no, h.snapshot, h.correction_reason, h.corrected_at
    from lifeos.expense_versions h where h.expense_id = p_id
    union all
    select (select count(*) + 1 from lifeos.expense_versions h where h.expense_id = p_id)::integer,
           lifeos._expense_core(x), null, null
  ), w as (
    select v.version_no, v.snapshot,
           lag(v.correction_reason) over (order by v.version_no) as correction_reason,
           lag(v.corrected_at) over (order by v.version_no) as corrected_at
    from v
  )
  select jsonb_agg(jsonb_build_object('version', w.version_no, 'snapshot', w.snapshot,
                                      'correction_reason', w.correction_reason,
                                      'corrected_at', lifeos._ts(w.corrected_at)) order by w.version_no)
    into v_history
  from w;
  return jsonb_build_object('id', p_id, 'history', v_history);
end $$;

create or replace function lifeos.expense_delete(p_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
begin
  if p_text is null or btrim(p_text) = '' then
    raise exception 'invalid input' using detail = 'p_text is the required deletion reason';
  end if;
  select * into x from lifeos.expenses where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if x.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(x.deleted_at));
  end if;
  perform lifeos._expense_snapshot(x, btrim(p_text));
  return lifeos._soft_delete('expenses', p_id);
end $$;

create or replace function lifeos.expense_refund_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  o lifeos.expenses;
  v_amount numeric;
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
                  and x.expense_type = 'purchase'
                group by l.category) g), '[]'::jsonb)),
        jsonb_build_object('part', 4, 'name', 'by_tag', 'items', coalesce((
          select jsonb_agg(jsonb_build_object('tag', g.tag, 'total', g.total) order by g.total desc, g.tag)
          from (select t.tag, sum(l.line_total) as total
                from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
                cross join lateral unnest(l.tags) as t(tag)
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                  and x.expense_type = 'purchase'
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

create or replace function lifeos.expense_category_list()
returns jsonb language sql security definer set search_path = lifeos, pg_temp
as $$ select jsonb_build_object('categories', to_jsonb(lifeos._expense_categories())) $$;

-- Remove the default PUBLIC grant before migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
