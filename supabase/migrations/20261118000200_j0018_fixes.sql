-- =============================================================================
-- LifeOS V2, migration 13: fixes of the J-0018 re-QA FAIL results F1, F2 and F-Q1.
--
-- F2 and F-Q1: expense_update keeps the Refund limits of expense_refund_create (KB 7.5,
--   J-0018 4.8). The check reads the state after the correction:
--   - On a Refund: the active Refunds of the purchase together are at most the purchase
--     expense_total. The Refund is dated on or after the purchase transaction_date.
--   - On a purchase: expense_total is at least the sum of its active Refunds. The purchase
--     transaction_date is on or before the date of every active Refund.
--   - A violation returns "invalid input" and rejects the whole correction with its history
--     version. A Refund of a deleted purchase has no limit.
-- F1: reading_remark_update replaces the whole entry content (KB 6.9, M-0020 D2 item 4).
--   text is required. An omitted storyline_id becomes null.
--
-- Changes two Contract functions in schema lifeos with the same signatures.
-- Grants of changed functions stay as they are.
-- =============================================================================

-- F2 and F-Q1: a correction keeps the Refund limits from both the Refund and the purchase side.
create or replace function lifeos.expense_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  y lifeos.expenses;
  o lifeos.expenses;
  v jsonb;
  c jsonb;
  v_reason text;
  v_amount numeric;
  v_line jsonb := '{}'::jsonb;
  v_refunded numeric;
  v_first_refund date;
begin
  select * into x from lifeos.expenses where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if x.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  -- A Refund correction locks its purchase, as expense_refund_create does.
  if x.expense_type = 'refund' then
    select * into o from lifeos.expenses where id = x.refund_of for update;
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

  -- F2 and F-Q1: the Refund limits apply to the state after the correction.
  -- A violation raises an exception, so the change and its snapshot are rolled back.
  select * into y from lifeos.expenses where id = p_id;
  if y.expense_type = 'refund' then
    -- A Refund of a deleted purchase has no limit (Contract 6.7 item 3).
    if o.id is not null and o.deleted_at is null then
      if y.transaction_date < o.transaction_date then
        raise exception 'invalid input' using detail = 'transaction_date is on or after the original transaction_date';
      end if;
      select coalesce(sum(-r.expense_total), 0) into v_refunded
      from lifeos.expenses r
      where r.refund_of = o.id and r.expense_type = 'refund' and r.deleted_at is null and r.id <> y.id;
      if v_refunded - y.expense_total > o.expense_total then
        raise exception 'invalid input' using detail = format('refund_amount with other Refunds (%s) is above the original total %s',
                                                             v_refunded, o.expense_total);
      end if;
    end if;
  else
    select coalesce(sum(-r.expense_total), 0), min(r.transaction_date) into v_refunded, v_first_refund
    from lifeos.expenses r
    where r.refund_of = y.id and r.expense_type = 'refund' and r.deleted_at is null;
    if y.expense_total < v_refunded then
      raise exception 'invalid input' using detail = format('expense_total is at least the active Refunds total %s', v_refunded);
    end if;
    if y.transaction_date > v_first_refund then
      raise exception 'invalid input' using detail = format('transaction_date is on or before the earliest active Refund date %s',
                                                           v_first_refund);
    end if;
  end if;

  return (select lifeos._expense_json(z) from lifeos.expenses z where z.id = p_id);
end $$;

-- F1: the entry gets the supplied text and storyline_id. entry_id, timestamp and updated_at stay.
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
  perform lifeos._require(v, array['entry_id', 'text']);
  perform lifeos._check_types(v, p_uuids => array['entry_id', 'storyline_id']);
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
  v_entry := jsonb_build_object(
    'entry_id', v_entry -> 'entry_id',
    'timestamp', v_entry -> 'timestamp',
    'storyline_id', nullif(v ->> 'storyline_id', '')::uuid,
    'text', btrim(v ->> 'text'));
  update lifeos.readings
     set remark_entries = jsonb_set(remark_entries, array[v_index::text], v_entry)
   where id = p_id;
  return (select lifeos._reading_json(x, false) from lifeos.readings x where x.id = p_id);
end $$;
