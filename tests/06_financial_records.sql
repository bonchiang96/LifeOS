-- =============================================================================
-- tests/06_financial_records.sql -- Module: Financial Records (Contract Chapter 6)
-- Expense, Expense Lines, Refund, correction history, deletion, spending report.
--
-- Tests in this file:
--   1.  expense_create_with_lines_and_adjustments
--   2.  expense_create_discrepancies_are_flags_only
--   3.  expense_without_lines_and_other_invalid_input_rejected
--   4.  expense_create_batch_all_or_nothing
--   5.  expense_refund_requires_line_type_and_keeps_shape
--   6.  expense_update_requires_reason_and_keeps_history
--   7.  expense_refund_update_keeps_refund_shape
--   8.  expense_delete_requires_reason_and_keeps_history
--   9.  expense_search_filters_and_order
--   10. expense_category_list_has_17_in_order
--   11. expense_spending_report_order_and_per_currency_totals
--   12. credit_purchase_is_one_expense_and_repayment_is_not_in_report
--
-- Single transaction: begin; tests; select results; rollback.
-- =============================================================================
begin;

-- Test harness. Everything below lives in the session and disappears at rollback.
create temp table t_results (seq serial, test text, status text, detail text);

create function pg_temp.pass(p_test text) returns void language plpgsql as $f$
begin
  insert into t_results (test, status) values (p_test, 'PASS');
  raise notice 'PASS %', p_test;
end $f$;

create function pg_temp.fail(p_test text, p_detail text) returns void language plpgsql as $f$
begin
  insert into t_results (test, status, detail) values (p_test, 'FAIL', p_detail);
  raise notice 'FAIL % -- %', p_test, p_detail;
end $f$;

-- Raises an exception when the condition is not true.
create function pg_temp.chk(p_cond boolean, p_msg text) returns void language plpgsql as $f$
begin
  if p_cond is not true then raise exception 'assertion failed: %', p_msg; end if;
end $f$;

-- Runs a statement and returns its error text, or null when it succeeds.
-- The statement runs in a sub-transaction, so a failure leaves no change behind.
create function pg_temp.err_of(p_sql text) returns text language plpgsql as $f$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end $f$;

-- Raises an exception unless the statement fails with exactly the Contract error text.
create function pg_temp.expect_err(p_sql text, p_expected text) returns void language plpgsql as $f$
declare v text := pg_temp.err_of(p_sql);
begin
  if v is distinct from p_expected then
    raise exception 'expected error "%" but got "%" for: %', p_expected, coalesce(v, '<no error>'), left(p_sql, 160);
  end if;
end $f$;

-- Today in Asia/Kuala_Lumpur (Contract 1.7 item 4).
create function pg_temp.today() returns date language sql as
$f$ select (now() at time zone 'Asia/Kuala_Lumpur')::date $f$;

-- Fixture ids shared between the tests of one file.
create temp table t_ids (k text primary key, v uuid);
create function pg_temp.id(p_k text) returns uuid language sql as
$f$ select v from t_ids where k = p_k $f$;
create function pg_temp.keep(p_k text, p_v uuid) returns uuid language plpgsql as $f$
begin insert into t_ids values (p_k, p_v) on conflict (k) do update set v = excluded.v; return p_v; end $f$;

-- Quote helper for building statements that contain a uuid.
create function pg_temp.q(p uuid) returns text language sql as $f$ select quote_literal(p::text) || '::uuid' $f$;

create function pg_temp.mk_subject(p_name text, p_type text default null) returns uuid language sql as
$f$ select ((lifeos.subject_create(jsonb_build_object('name', p_name, 'subject_type', p_type)))->>'id')::uuid $f$;

-- 1. Expense with item, charge and adjustment Lines ------------------------------
do $t$
declare t constant text := 'expense_create_with_lines_and_adjustments';
  pm uuid := pg_temp.mk_subject('Card A', 'payment method'); mer uuid := pg_temp.mk_subject('Kopitiam K', 'brand'); item uuid := pg_temp.mk_subject('Vitamin C', 'product');
  x jsonb; r jsonb;
begin
  x := lifeos.expense_create(jsonb_build_object('transaction_date','2032-05-02','transaction_time','13:05','merchant_name','Kopitiam K','branch','Bangsar',
        'merchant_subject_id', mer, 'payment_method_subject_id', pm,'expense_total', 22,'currency','MYR',
        'metadata', jsonb_build_object('transaction_ids', jsonb_build_array('T-1')),
        'lines', jsonb_build_array(
          jsonb_build_object('line_type','item','item_description','Vitamin C','source_item_text','VIT C 1000MG','quantity',2,'unit_price',10,'line_total',20,'category','medical','tags',jsonb_build_array('vitamin'),'item_subject_id', item),
          jsonb_build_object('line_type','charge','item_description','Service charge','unit_price',5,'line_total',5,'category','fees'),
          jsonb_build_object('line_type','adjustment','item_description','Voucher','unit_price',-3,'line_total',-3,'category','discount'))));
  perform pg_temp.chk(x->>'expense_type' = 'purchase', 'expense_type is purchase');
  perform pg_temp.chk((x->>'expense_total')::numeric = 22 and x->>'currency' = 'MYR', 'total and currency stored');
  perform pg_temp.chk(jsonb_array_length(x->'lines') = 3, 'three Lines stored');
  perform pg_temp.chk((select array_agg((l->>'line_no')::int order by (l->>'line_no')::int) from jsonb_array_elements(x->'lines') l) = array[1,2,3], 'line_no follows the order of lines');
  perform pg_temp.chk(x->'lines'->0->>'line_type' = 'item' and x->'lines'->1->>'line_type' = 'charge' and x->'lines'->2->>'line_type' = 'adjustment', 'line order and types kept');
  perform pg_temp.chk((x->'lines'->2->>'line_total')::numeric = -3, 'an adjustment Line keeps its negative sign');
  perform pg_temp.chk((x->'lines'->1->>'quantity')::numeric = 1 and x->'lines'->1->'tags' = '[]'::jsonb, 'Line quantity defaults to 1 and tags to []');
  perform pg_temp.chk(x->'lines'->0->>'source_item_text' = 'VIT C 1000MG' and x->'lines'->0->>'item_subject_id' = item::text, 'source_item_text and item_subject_id kept');
  perform pg_temp.chk(jsonb_array_length(x->'discrepancies') = 0, 'a consistent Expense has no discrepancies, got ' || (x->'discrepancies')::text);
  perform pg_temp.chk(x->'refunds' = '[]'::jsonb and (x->>'version')::int = 1, 'refunds [] and version 1');
  perform pg_temp.chk(x->>'merchant_name' = 'Kopitiam K' and x->>'branch' = 'Bangsar' and x->>'transaction_time' = '13:05:00', 'merchant, branch and time stored');
  perform pg_temp.chk(x->'metadata'->'transaction_ids' = '["T-1"]'::jsonb, 'metadata stored');
  r := lifeos.expense_read((x->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(r->'lines') = 3 and r ? 'links', 'expense_read returns Lines and links');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(r->'links') l where l->>'via' = 'payment_method' and l->>'id' = pm::text), 'links include the Payment Method');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(r->'links') l where l->>'via' = 'merchant' and l->>'id' = mer::text), 'links include the Merchant');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(r->'links') l where l->>'via' = 'line_item' and l->>'id' = item::text), 'links include the Line Item');
  -- a zero total with the Cash Payment Method
  x := lifeos.expense_create(jsonb_build_object('transaction_date','2032-05-03','payment_method_subject_id', pg_temp.mk_subject('Cash','payment method'),'expense_total', 0,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Free sample','unit_price',0,'line_total',0,'category','food'))));
  perform pg_temp.chk((x->>'expense_total')::numeric = 0, 'a zero total is accepted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Discrepancies are comparison flags; stored values never change ---------------
do $t$
declare t constant text := 'expense_create_discrepancies_are_flags_only';
  pm uuid := pg_temp.mk_subject('Card B', 'payment method'); x jsonb; d jsonb;
begin
  x := lifeos.expense_create(jsonb_build_object('transaction_date','2032-05-04','payment_method_subject_id', pm,'expense_total', 30,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Pens','quantity',3,'unit_price',2,'line_total',7,'category','household'))));
  d := x->'discrepancies';
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(d) e where e->>'check' = 'lines_sum' and (e->>'expense_total')::numeric = 30 and (e->>'lines_sum')::numeric = 7), 'lines_sum discrepancy reported, got ' || d::text);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(d) e where e->>'check' = 'quantity_x_unit_price' and (e->>'line_total')::numeric = 7 and (e->>'computed')::numeric = 6
                              and e->>'line_id' = x->'lines'->0->>'id'), 'quantity_x_unit_price discrepancy reported with the Line id');
  perform pg_temp.chk((x->>'expense_total')::numeric = 30 and (x->'lines'->0->>'line_total')::numeric = 7 and (x->'lines'->0->>'unit_price')::numeric = 2, 'stored values stay as supplied');
  perform pg_temp.chk((lifeos.expense_read((x->>'id')::uuid)->'discrepancies') = d, 'expense_read reports the same discrepancies');
  -- exact precision
  x := lifeos.expense_create(jsonb_build_object('transaction_date','2032-05-04','payment_method_subject_id', pm,'expense_total', 12.345,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',12.345,'line_total',12.345,'category','fees'))));
  perform pg_temp.chk((x->>'expense_total')::numeric = 12.345 and (x->'lines'->0->>'line_total')::numeric = 12.345, 'exact precision is kept');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Expense without Lines, and other invalid input ------------------------------
do $t$
declare t constant text := 'expense_without_lines_and_other_invalid_input_rejected';
  pm uuid := pg_temp.mk_subject('Card C', 'payment method'); base jsonb; ln jsonb; e text;
begin
  ln := jsonb_build_object('line_type','item','unit_price',5,'line_total',5,'category','food');
  base := jsonb_build_object('transaction_date','2032-05-05','payment_method_subject_id', pm,'expense_total', 5,'currency','MYR','lines', jsonb_build_array(ln));
  -- the valid base works
  perform lifeos.expense_create(base);
  -- Lines are required, at least one
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base - 'lines'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || '{"lines":[]}'), 'invalid input');
  -- required fields
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base - 'currency'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base - 'transaction_date'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base - 'payment_method_subject_id'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base - 'expense_total'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || '{"expense_total":-5}'), 'invalid input');
  -- not accepted input
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || '{"expense_type":"refund"}'), 'unsupported field');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('refund_of', gen_random_uuid())), 'unsupported field');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || '{"is_paylater":true}'), 'unsupported field');
  -- Line validation on a purchase
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('lines', jsonb_build_array(ln - 'line_type'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('lines', jsonb_build_array(ln - 'category'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('lines', jsonb_build_array(ln - 'unit_price'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('lines', jsonb_build_array(ln - 'line_total'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('lines', jsonb_build_array(ln || '{"category":"snacks"}'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('lines', jsonb_build_array(ln || '{"line_type":"gift"}'))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('lines', jsonb_build_array(ln || '{"tags":["1","2","3","4","5","6","7","8","9","10","11"]}'))), 'invalid input');
  perform lifeos.expense_create(base || jsonb_build_object('lines', jsonb_build_array(ln || '{"tags":["1","2","3","4","5","6","7","8","9","10"]}')));
  -- Subject ids must be active Subjects
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', base || jsonb_build_object('payment_method_subject_id', gen_random_uuid())), 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Batch: results in input order; one invalid item rejects the whole batch -------
do $t$
declare t constant text := 'expense_create_batch_all_or_nothing';
  pm uuid := pg_temp.mk_subject('Card D', 'payment method'); ok1 jsonb; ok2 jsonb; bad jsonb; r jsonb; e text; n int;
begin
  ok1 := jsonb_build_object('transaction_date','2032-06-01','merchant_name','BatchShopOne','payment_method_subject_id', pm,'expense_total', 5,'currency','MYR',
          'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',5,'line_total',5,'category','food')));
  ok2 := jsonb_build_object('transaction_date','2032-06-02','merchant_name','BatchShopTwo','payment_method_subject_id', pm,'expense_total', 8,'currency','MYR',
          'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',8,'line_total',8,'category','drink')));
  r := lifeos.expense_create_batch(jsonb_build_object('expenses', jsonb_build_array(ok1, ok2)));
  perform pg_temp.chk((r->>'returned_count')::int = 2 and r->'results'->0->>'merchant_name' = 'BatchShopOne' and r->'results'->1->>'merchant_name' = 'BatchShopTwo', 'two Expenses returned in input order');
  perform pg_temp.chk(jsonb_array_length(r->'results'->0->'lines') = 1, 'each result carries its Lines');

  bad := ok2 - 'lines';
  bad := bad || '{"merchant_name":"BatchShopBad"}';
  ok1 := ok1 || '{"merchant_name":"BatchShopThree"}';
  e := pg_temp.err_of(format('select lifeos.expense_create_batch(%L::jsonb)', jsonb_build_object('expenses', jsonb_build_array(ok1, bad))));
  perform pg_temp.chk(e is not null and e like 'invalid input%', 'one invalid item rejects the batch with invalid input, got ' || coalesce(e,'<no error>'));
  r := lifeos.expense_search('{"keyword":"BatchShopThree"}');
  perform pg_temp.chk((r->>'returned_count')::int = 0, 'the valid item of a rejected batch is not saved');
  perform pg_temp.expect_err($$select lifeos.expense_create_batch('{"expenses":[]}')$$, 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Refund: line_type required, shape copied from the original -------------------
do $t$
declare t constant text := 'expense_refund_requires_line_type_and_keeps_shape';
  pm uuid := pg_temp.mk_subject('Card E', 'payment method'); mer uuid := pg_temp.mk_subject('Shoe Shop', 'brand'); item uuid := pg_temp.mk_subject('Shoes', 'product');
  o jsonb; r jsonb; r2 jsonb; orig jsonb; base jsonb;
begin
  o := lifeos.expense_create(jsonb_build_object('transaction_date','2032-07-01','merchant_name','Shoe Shop','branch','KLCC','merchant_subject_id', mer,'seller_name','Seller Z',
        'payment_method_subject_id', pm,'expense_total', 200,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Shoes','unit_price',200,'line_total',200,'category','clothing','tags',jsonb_build_array('shoes')))));
  base := jsonb_build_object('refund_of', o->>'id','refund_amount', 60,'transaction_date','2032-07-10');
  -- line_type is required, and so are the other required fields
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', base), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', (base || '{"line_type":"item"}') - 'refund_amount'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', (base || '{"line_type":"item"}') - 'transaction_date'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', (base || '{"line_type":"item"}') - 'refund_of'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', base || '{"line_type":"refund"}'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', base || '{"line_type":"item","refund_amount":0}'), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', base || '{"line_type":"item","refund_amount":-5}'), 'invalid input');

  r := lifeos.expense_refund_create(base || '{"line_type":"item","item_description":"refund for the shoes"}');
  perform pg_temp.chk(r->>'expense_type' = 'refund' and r->>'refund_of' = o->>'id', 'Refund Expense linked to the original');
  perform pg_temp.chk((r->>'expense_total')::numeric = -60, 'a partial Refund total is the negative of the actual amount');
  perform pg_temp.chk(r->>'payment_method_subject_id' = pm::text and r->>'currency' = 'MYR', 'Payment Method and Currency copied from the original');
  perform pg_temp.chk(r->>'merchant_name' = 'Shoe Shop' and r->>'branch' = 'KLCC' and r->>'merchant_subject_id' = mer::text and r->>'seller_name' = 'Seller Z', 'merchant, branch and seller copied');
  perform pg_temp.chk(r->>'transaction_date' = '2032-07-10', 'transaction_date is the date the money came back');
  perform pg_temp.chk(jsonb_array_length(r->'lines') = 1, 'exactly one Line');
  perform pg_temp.chk((r->'lines'->0->>'quantity')::numeric = 1 and (r->'lines'->0->>'unit_price')::numeric = -60 and (r->'lines'->0->>'line_total')::numeric = -60, 'Line quantity 1, unit_price and line_total negative');
  perform pg_temp.chk(r->'lines'->0->>'category' is null and r->'lines'->0->'tags' = '[]'::jsonb, 'a Refund Line has no category and no tags');
  perform pg_temp.chk(r->'lines'->0->>'line_type' = 'item' and r->'lines'->0->>'item_description' = 'refund for the shoes', 'supplied line_type and item_description stored');
  perform pg_temp.chk(r->'original'->>'id' = o->>'id' and (r->'original'->>'expense_total')::numeric = 200 and r->'original'->>'transaction_date' = '2032-07-01', 'the return carries the compact original');
  perform pg_temp.chk(jsonb_array_length(r->'discrepancies') = 0, 'the Refund has no discrepancies');

  -- without an item description the Line has none; several Refunds for one original
  r2 := lifeos.expense_refund_create(base || '{"line_type":"charge","refund_amount":20,"transaction_date":"2032-07-12"}');
  perform pg_temp.chk(r2->'lines'->0->>'item_description' is null and r2->'lines'->0->>'line_type' = 'charge', 'no item description when none is supplied');
  orig := lifeos.expense_read((o->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(orig->'refunds') = 2, 'the original lists both Refunds');
  perform pg_temp.chk((orig->>'expense_total')::numeric = 200 and (orig->>'version')::int = 1 and jsonb_array_length(orig->'lines') = 1, 'the original stays unchanged');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(lifeos.expense_read((r->>'id')::uuid)->'links') l where l->>'via' = 'refund_of' and l->>'id' = o->>'id'), 'the Refund links back with via refund_of');
  perform pg_temp.chk(lifeos.expense_read((r->>'id')::uuid)->'original'->>'id' = o->>'id', 'expense_read of a Refund returns the original');
  -- a Refund cannot be refunded; the original must exist
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', jsonb_build_object('refund_of', r->>'id','refund_amount',5,'transaction_date','2032-07-11','line_type','item')), 'invalid relationship');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', jsonb_build_object('refund_of', gen_random_uuid(),'refund_amount',5,'transaction_date','2032-07-11','line_type','item')), 'record not found');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Expense correction: reason required, history kept ----------------------------
do $t$
declare t constant text := 'expense_update_requires_reason_and_keeps_history';
  pm uuid := pg_temp.mk_subject('Card F', 'payment method'); pm2 uuid := pg_temp.mk_subject('Card G', 'payment method');
  o jsonb; u jsonb; h jsonb; id uuid; links_before int;
begin
  o := lifeos.expense_create(jsonb_build_object('transaction_date','2032-08-01','merchant_name','Wrong Name','payment_method_subject_id', pm,'expense_total', 10,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Lunch','unit_price',10,'line_total',10,'category','food'))));
  id := (o->>'id')::uuid;
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"merchant_name":"Right Name"}')$$, id), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"merchant_name":"Right Name","correction_reason":"  "}')$$, id), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"correction_reason":"x","expense_type":"refund"}')$$, id), 'unsupported field');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"correction_reason":"x","remarks":["a"]}')$$, id), 'unsupported field');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"correction_reason":"x","refund_amount":5}')$$, id), 'unsupported field');

  u := lifeos.expense_update(id, jsonb_build_object('merchant_name','Right Name','payment_method_subject_id', pm2,'expense_total', 12,'correction_reason','Wrong merchant and amount on the receipt',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Lunch set','unit_price',12,'line_total',12,'category','food'))));
  perform pg_temp.chk(u->>'id' = id::text, 'the ID stays the same');
  perform pg_temp.chk(u->>'merchant_name' = 'Right Name' and (u->>'expense_total')::numeric = 12 and u->>'payment_method_subject_id' = pm2::text, 'fields changed in place');
  perform pg_temp.chk(jsonb_array_length(u->'lines') = 1 and u->'lines'->0->>'item_description' = 'Lunch set', 'Lines replaced as a whole set');
  perform pg_temp.chk((u->>'version')::int = 2, 'version is 2 after one correction');
  perform pg_temp.chk(not (u ? 'correction_reason'), 'correction_reason is not a stored Expense field');

  h := lifeos.expense_history(id);
  perform pg_temp.chk(h->>'id' = id::text and jsonb_array_length(h->'history') = 2, 'history holds two versions');
  perform pg_temp.chk((h->'history'->0->>'version')::int = 1 and (h->'history'->1->>'version')::int = 2, 'versions ordered oldest to newest');
  perform pg_temp.chk(h->'history'->0->>'corrected_at' is null, 'the first version has corrected_at null');
  perform pg_temp.chk(h->'history'->0->'snapshot'->>'merchant_name' = 'Wrong Name' and (h->'history'->0->'snapshot'->>'expense_total')::numeric = 10
                      and h->'history'->0->'snapshot'->'lines'->0->>'item_description' = 'Lunch', 'the first version is the snapshot before the change, with its Lines');
  perform pg_temp.chk(h->'history'->1->'snapshot'->>'merchant_name' = 'Right Name', 'the last version is the current Expense');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(h->'history') v where v->>'correction_reason' = 'Wrong merchant and amount on the receipt') = 1, 'the correction_reason is stored on one history version');
  perform pg_temp.chk(h->'history'->1->>'corrected_at' is not null, 'the corrected version has corrected_at');

  -- a Remark creates no correction version
  perform lifeos.record_add_remark('expense', id, 'receipt photo checked');
  h := lifeos.expense_history(id);
  perform pg_temp.chk(jsonb_array_length(h->'history') = 2 and (lifeos.expense_read(id)->>'version')::int = 2, 'a Remark creates no correction version');
  -- a second correction
  u := lifeos.expense_update(id, '{"branch":"Mid Valley","correction_reason":"Branch added"}');
  perform pg_temp.chk((u->>'version')::int = 3 and jsonb_array_length(lifeos.expense_history(id)->'history') = 3, 'a second correction makes version 3');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Refund correction keeps the Refund shape ---------------------------------------
do $t$
declare t constant text := 'expense_refund_update_keeps_refund_shape';
  pm uuid := pg_temp.mk_subject('Card H', 'payment method'); o jsonb; r jsonb; u jsonb;
begin
  o := lifeos.expense_create(jsonb_build_object('transaction_date','2032-08-05','payment_method_subject_id', pm,'expense_total', 100,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',100,'line_total',100,'category','electronics'))));
  r := lifeos.expense_refund_create(jsonb_build_object('refund_of', o->>'id','refund_amount',30,'transaction_date','2032-08-09','line_type','item'));
  u := lifeos.expense_update((r->>'id')::uuid, '{"refund_amount":25,"item_description":"cable returned","line_type":"charge","correction_reason":"Credit note said 25"}');
  perform pg_temp.chk((u->>'expense_total')::numeric = -25 and (u->'lines'->0->>'line_total')::numeric = -25 and (u->'lines'->0->>'unit_price')::numeric = -25, 'refund_amount 25 gives a negative total and Line');
  perform pg_temp.chk(jsonb_array_length(u->'lines') = 1 and u->'lines'->0->>'category' is null, 'one Line and no category');
  perform pg_temp.chk(u->'lines'->0->>'item_description' = 'cable returned' and u->'lines'->0->>'line_type' = 'charge', 'item_description and line_type changed');
  perform pg_temp.chk(u->>'refund_of' = o->>'id' and u->>'payment_method_subject_id' = pm::text and u->>'currency' = 'MYR', 'refund_of, Payment Method and Currency stay');
  perform pg_temp.chk((u->>'version')::int = 2, 'version 2 after the correction');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"currency":"SGD","correction_reason":"x"}')$$, r->>'id'), 'unsupported field');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"lines":[],"correction_reason":"x"}')$$, r->>'id'), 'unsupported field');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Expense delete: reason required, snapshot kept, Refunds stay ---------------------
do $t$
declare t constant text := 'expense_delete_requires_reason_and_keeps_history';
  pm uuid := pg_temp.mk_subject('Card I', 'payment method'); o jsonb; r jsonb; d jsonb; d2 jsonb; h jsonb; id uuid;
begin
  o := lifeos.expense_create(jsonb_build_object('transaction_date','2032-09-01','merchant_name','DeleteMeShopxq','payment_method_subject_id', pm,'expense_total', 40,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','unit_price',40,'line_total',40,'category','other'))));
  id := (o->>'id')::uuid;
  r := lifeos.expense_refund_create(jsonb_build_object('refund_of', o->>'id','refund_amount',10,'transaction_date','2032-09-03','line_type','item'));
  perform pg_temp.expect_err(format($$select lifeos.expense_delete(%L::uuid, '')$$, id), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.expense_delete(%L::uuid, '   ')$$, id), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.expense_delete(%L::uuid, null)$$, id), 'invalid input');
  perform pg_temp.chk(lifeos.expense_read(id)->>'deleted_at' is null, 'a rejected delete leaves the Expense active');

  d := lifeos.expense_delete(id, 'Duplicate of an earlier receipt');
  perform pg_temp.chk(d->>'id' = id::text and d->>'deleted_at' is not null, 'delete returns id and deleted_at');
  h := lifeos.expense_history(id);
  perform pg_temp.chk((select count(*) from jsonb_array_elements(h->'history') v where v->>'correction_reason' = 'Duplicate of an earlier receipt') = 1, 'the deletion reason is stored on a history version');
  perform pg_temp.chk(jsonb_array_length(h->'history') >= 2, 'the deletion adds a history version');
  d2 := lifeos.expense_delete(id, 'again');
  perform pg_temp.chk(d2->>'deleted_at' = d->>'deleted_at', 'a second delete returns the existing deleted_at');
  perform pg_temp.chk(lifeos.expense_read(id)->>'deleted_at' is not null, 'expense_read still returns the deleted Expense');
  perform pg_temp.chk((lifeos.expense_search('{"keyword":"DeleteMeShopxq"}')->>'returned_count')::int = 1, 'search hides the deleted Expense (only its Refund remains)');
  perform pg_temp.chk((lifeos.expense_search('{"keyword":"DeleteMeShopxq","include_deleted":true}')->>'returned_count')::int = 2, 'include_deleted shows it');
  -- the Refund stays and reports refund_of as null
  r := lifeos.expense_read((r->>'id')::uuid);
  perform pg_temp.chk(r->>'deleted_at' is null and r->>'refund_of' is null, 'the Refund stays active and refund_of reads null');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%L::uuid, '{"branch":"x","correction_reason":"x"}')$$, id), 'record deleted');
  perform pg_temp.expect_err(format($$select lifeos.expense_refund_create(%L::jsonb)$$, jsonb_build_object('refund_of', id,'refund_amount',1,'transaction_date','2032-09-04','line_type','item')), 'record deleted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Expense search filters and order ---------------------------------------------------
do $t$
declare t constant text := 'expense_search_filters_and_order';
  pm uuid := pg_temp.mk_subject('Card J', 'payment method'); pm2 uuid := pg_temp.mk_subject('Card K', 'payment method');
  item uuid := pg_temp.mk_subject('Latte', 'product'); mer uuid := pg_temp.mk_subject('Brew Bar', 'brand');
  a jsonb; b jsonb; c jsonb; rf jsonb; r jsonb;
begin
  a := lifeos.expense_create(jsonb_build_object('transaction_date','2034-01-10','transaction_time','09:00','merchant_name','Brew Bar','merchant_subject_id', mer,'payment_method_subject_id', pm,'expense_total', 9,'currency','MYR',
        'remarks', jsonb_build_array('morning coffee remarkzz'),
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Latte','source_item_text','LATTE REG','unit_price',9,'line_total',9,'category','drink','tags',jsonb_build_array('coffee'),'item_subject_id', item))));
  b := lifeos.expense_create(jsonb_build_object('transaction_date','2034-01-10','transaction_time','18:00','merchant_name','Night Mart','payment_method_subject_id', pm2,'expense_total', 20,'currency','SGD',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Soap','unit_price',20,'line_total',20,'category','household','tags',jsonb_build_array('bath')))));
  c := lifeos.expense_create(jsonb_build_object('transaction_date','2034-01-15','merchant_name','Brew Bar','payment_method_subject_id', pm,'expense_total', 11,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Cake','unit_price',11,'line_total',11,'category','food'))));
  rf := lifeos.expense_refund_create(jsonb_build_object('refund_of', a->>'id','refund_amount',9,'transaction_date','2034-01-16','line_type','item'));

  r := lifeos.expense_search('{"from_date":"2034-01-10","to_date":"2034-01-16"}');
  perform pg_temp.chk((r->>'returned_count')::int = 4, 'date range is inclusive, got ' || (r->>'returned_count'));
  perform pg_temp.chk(r->'results'->0->>'id' = rf->>'id' and r->'results'->1->>'id' = c->>'id' and r->'results'->2->>'id' = b->>'id' and r->'results'->3->>'id' = a->>'id',
    'ordered by transaction_date then transaction_time, newest first');
  perform pg_temp.chk((lifeos.expense_search('{"from_date":"2034-01-10","to_date":"2034-01-10"}')->>'returned_count')::int = 2, 'one-day range');
  perform pg_temp.chk((lifeos.expense_search('{"from_date":"2034-01-01","to_date":"2034-01-31","expense_type":"refund"}')->>'returned_count')::int = 1, 'expense_type filter');
  perform pg_temp.chk((lifeos.expense_search(jsonb_build_object('from_date','2034-01-01','to_date','2034-01-31','payment_method_subject_id', pm2))->>'returned_count')::int = 1, 'payment_method_subject_id filter');
  perform pg_temp.chk((lifeos.expense_search(jsonb_build_object('from_date','2034-01-01','to_date','2034-01-31','merchant_subject_id', mer))->>'returned_count')::int = 2, 'merchant_subject_id filter (purchase and its Refund)');
  perform pg_temp.chk((lifeos.expense_search(jsonb_build_object('item_subject_id', item))->>'returned_count')::int = 1, 'item_subject_id matches a Line');
  perform pg_temp.chk((lifeos.expense_search('{"from_date":"2034-01-01","to_date":"2034-01-31","category":"drink"}')->>'returned_count')::int = 1, 'category matches a Line');
  perform pg_temp.chk((lifeos.expense_search('{"from_date":"2034-01-01","to_date":"2034-01-31","tag":"bath"}')->>'returned_count')::int = 1, 'tag matches a Line');
  perform pg_temp.chk((lifeos.expense_search('{"from_date":"2034-01-01","to_date":"2034-01-31","currency":"SGD"}')->>'returned_count')::int = 1, 'currency filter');
  perform pg_temp.chk((lifeos.expense_search(jsonb_build_object('refund_of', a->>'id'))->>'returned_count')::int = 1, 'refund_of filter finds the original''s Refund');
  perform pg_temp.chk((lifeos.expense_search('{"keyword":"latte reg"}')->>'returned_count')::int = 1, 'keyword matches source_item_text');
  perform pg_temp.chk((lifeos.expense_search('{"keyword":"CAKE"}')->>'returned_count')::int = 1, 'keyword matches item_description');
  perform pg_temp.chk((lifeos.expense_search('{"keyword":"remarkzz"}')->>'returned_count')::int = 1, 'keyword matches Remark text');
  perform pg_temp.chk((lifeos.expense_search('{"keyword":"night mart"}')->>'returned_count')::int = 1, 'keyword matches merchant_name');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Category list ---------------------------------------------------------------------
do $t$
declare t constant text := 'expense_category_list_has_17_in_order';
  r jsonb;
begin
  r := lifeos.expense_category_list();
  perform pg_temp.chk(r->'categories' = '["food","drink","transport","clothing","beauty","electronics","household","entertainment","medical","education","travel","gift","fees","rental","loans","discount","other"]'::jsonb,
    'the 17 Categories in the Contract order, got ' || (r->'categories')::text);
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Spending report: five parts in order, per-currency totals -------------------------
do $t$
declare t constant text := 'expense_spending_report_order_and_per_currency_totals';
  card uuid := pg_temp.mk_subject('Report Card', 'payment method'); pl uuid := pg_temp.mk_subject('Report PayLater', 'payment method'); cash uuid := pg_temp.mk_subject('Report Cash', 'payment method');
  shopee uuid := pg_temp.mk_subject('Report Shopee', 'brand');
  e1 jsonb; e2 jsonb; e3 jsonb; e4 jsonb; r1 jsonb; r2 jsonb; rep jsonb; myr jsonb; sgd jsonb; p jsonb; repm jsonb; i int;
begin
  e1 := lifeos.expense_create(jsonb_build_object('transaction_date','2033-01-05','merchant_name','Shopee','merchant_subject_id', shopee,'payment_method_subject_id', card,'expense_total',125,'currency','MYR',
        'lines', jsonb_build_array(
          jsonb_build_object('line_type','item','item_description','Snack box','unit_price',40,'line_total',40,'category','food','tags',jsonb_build_array('snack','weekend')),
          jsonb_build_object('line_type','item','item_description','Pot','unit_price',100,'line_total',100,'category','household','tags',jsonb_build_array('weekend')),
          jsonb_build_object('line_type','adjustment','item_description','Voucher','unit_price',-15,'line_total',-15,'category','discount','tags',jsonb_build_array('voucher')))));
  e2 := lifeos.expense_create(jsonb_build_object('transaction_date','2033-01-10','merchant_name','Shopee','merchant_subject_id', shopee,'payment_method_subject_id', pl,'expense_total',175,'currency','MYR',
        'lines', jsonb_build_array(
          jsonb_build_object('line_type','item','item_description','Earbuds','unit_price',200,'line_total',200,'category','electronics'),
          jsonb_build_object('line_type','adjustment','item_description','Shipping subsidy','unit_price',-25,'line_total',-25,'category','discount'))));
  e3 := lifeos.expense_create(jsonb_build_object('transaction_date','2033-01-12','merchant_name','Mamak','payment_method_subject_id', cash,'expense_total',12,'currency','MYR',
        'lines', jsonb_build_array(
          jsonb_build_object('line_type','item','item_description','Roti','unit_price',12.02,'line_total',12.02,'category','food','tags',jsonb_build_array('snack')),
          jsonb_build_object('line_type','adjustment','item_description','Rounding','unit_price',-0.02,'line_total',-0.02,'category','other'))));
  e4 := lifeos.expense_create(jsonb_build_object('transaction_date','2033-01-15','merchant_name','SG Shop','payment_method_subject_id', card,'expense_total',10,'currency','SGD',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Gadget','unit_price',10,'line_total',10,'category','other'))));
  r1 := lifeos.expense_refund_create(jsonb_build_object('refund_of', e1->>'id','refund_amount',30,'transaction_date','2033-01-20','line_type','item'));
  r2 := lifeos.expense_refund_create(jsonb_build_object('refund_of', e2->>'id','refund_amount',50,'transaction_date','2033-02-03','line_type','item'));

  rep := lifeos.expense_spending_report('{"from_date":"2033-01-01","to_date":"2033-01-31"}');
  perform pg_temp.chk(rep->>'from_date' = '2033-01-01' and rep->>'to_date' = '2033-01-31', 'period echoed');
  perform pg_temp.chk(jsonb_array_length(rep->'currencies') = 2, 'one entry per currency, got ' || jsonb_array_length(rep->'currencies'));
  select c into myr from jsonb_array_elements(rep->'currencies') c where c->>'currency' = 'MYR';
  select c into sgd from jsonb_array_elements(rep->'currencies') c where c->>'currency' = 'SGD';
  perform pg_temp.chk(myr is not null and sgd is not null, 'MYR and SGD both reported');

  -- five parts in fixed order
  perform pg_temp.chk(jsonb_array_length(myr->'parts') = 5, 'five parts');
  for i in 0..4 loop
    perform pg_temp.chk((myr->'parts'->i->>'part')::int = i + 1, 'part ' || (i + 1) || ' is at position ' || (i + 1));
  end loop;
  perform pg_temp.chk(myr->'parts'->0->>'name' = 'total_spent' and myr->'parts'->1->>'name' = 'by_payment_method' and myr->'parts'->2->>'name' = 'by_category'
                      and myr->'parts'->3->>'name' = 'by_tag' and myr->'parts'->4->>'name' = 'adjustments', 'part names in Contract order');

  -- part 1: purchases plus the Refund as a negative total, the later Refund excluded
  perform pg_temp.chk((myr->'parts'->0->>'total')::numeric = 282, 'MYR total_spent 125+175+12-30 = 282, got ' || (myr->'parts'->0->>'total'));
  perform pg_temp.chk((myr->'parts'->0->>'expense_count')::int between 3 and 4, 'expense_count counts the active Expenses of the period');
  perform pg_temp.chk((sgd->'parts'->0->>'total')::numeric = 10, 'SGD is totalled separately: 10');

  -- part 2: payment methods, total descending, Refund reduces its Payment Method
  p := myr->'parts'->1->'items';
  perform pg_temp.chk(jsonb_array_length(p) = 3, 'three Payment Methods');
  perform pg_temp.chk(p->0->>'payment_method_subject_id' = pl::text and (p->0->>'total')::numeric = 175 and p->0->>'payment_method_name' = 'Report PayLater', 'first: PayLater 175');
  perform pg_temp.chk(p->1->>'payment_method_subject_id' = card::text and (p->1->>'total')::numeric = 95, 'second: Card 125 - 30 = 95');
  perform pg_temp.chk(p->2->>'payment_method_subject_id' = cash::text and (p->2->>'total')::numeric = 12, 'third: Cash 12');

  -- part 3: categories over purchase Lines, Refund Lines excluded, total descending
  p := myr->'parts'->2->'items';
  perform pg_temp.chk((select array_agg(x->>'category' order by ord) from jsonb_array_elements(p) with ordinality as q(x, ord)) = array['electronics','household','food','other','discount'],
    'categories in descending order of total, got ' || (select string_agg(x->>'category', ',' order by ord) from jsonb_array_elements(p) with ordinality as q(x, ord)));
  perform pg_temp.chk((select (x->>'total')::numeric from jsonb_array_elements(p) x where x->>'category' = 'food') = 52.02, 'food 40 + 12.02 = 52.02');
  perform pg_temp.chk((select (x->>'total')::numeric from jsonb_array_elements(p) x where x->>'category' = 'discount') = -40, 'adjustment Lines count under their stored Category: discount -40');
  perform pg_temp.chk((select (x->>'total')::numeric from jsonb_array_elements(p) x where x->>'category' = 'other') = -0.02, 'other -0.02');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(p) x where x->>'category' is null), 'Refund Lines are excluded from categories');

  -- part 4: tags, overlapping, total descending, Refund Lines excluded
  p := myr->'parts'->3->'items';
  perform pg_temp.chk((select array_agg(x->>'tag' order by ord) from jsonb_array_elements(p) with ordinality as q(x, ord)) = array['weekend','snack','voucher'], 'tags in descending order of total');
  perform pg_temp.chk((select (x->>'total')::numeric from jsonb_array_elements(p) x where x->>'tag' = 'weekend') = 140, 'weekend 40 + 100 = 140');
  perform pg_temp.chk((select (x->>'total')::numeric from jsonb_array_elements(p) x where x->>'tag' = 'snack') = 52.02, 'a Line with several Tags counts under each Tag: snack 52.02');

  -- part 5: adjustments, most negative first
  p := myr->'parts'->4;
  perform pg_temp.chk((p->>'total')::numeric = -40.02, 'adjustments total -40.02, got ' || (p->>'total'));
  perform pg_temp.chk(p->'items'->0->>'merchant_name' = 'Shopee' and p->'items'->0->>'merchant_subject_id' = shopee::text and (p->'items'->0->>'total')::numeric = -40, 'the first adjustment source is Shopee (-40)');
  perform pg_temp.chk(p->'items'->1->>'merchant_name' = 'Mamak' and (p->'items'->1->>'total')::numeric = -0.02, 'then Mamak (-0.02)');

  -- Refund lists
  perform pg_temp.chk(jsonb_array_length(myr->'refunds_in_period') = 1 and myr->'refunds_in_period'->0->>'id' = r1->>'id'
                      and myr->'refunds_in_period'->0->>'original_transaction_date' = '2033-01-05' and (myr->'refunds_in_period'->0->>'original_total')::numeric = 125
                      and (myr->'refunds_in_period'->0->>'expense_total')::numeric = -30, 'refunds_in_period lists the Refund with its original date and total');
  perform pg_temp.chk(jsonb_array_length(myr->'later_refunds') = 1 and myr->'later_refunds'->0->>'id' = r2->>'id'
                      and myr->'later_refunds'->0->>'original_transaction_date' = '2033-01-10', 'later_refunds lists the Refund after to_date whose original is in the period');
  -- an earlier-month purchase with a later refund: the next month counts the refund as negative
  rep := lifeos.expense_spending_report('{"from_date":"2033-02-01","to_date":"2033-02-28"}');
  select c into repm from jsonb_array_elements(rep->'currencies') c where c->>'currency' = 'MYR';
  perform pg_temp.chk((repm->'parts'->0->>'total')::numeric = -50, 'the Refund counts as -50 in the month the money came back');
  -- currency filter
  rep := lifeos.expense_spending_report('{"from_date":"2033-01-01","to_date":"2033-01-31","currency":"SGD"}');
  perform pg_temp.chk(jsonb_array_length(rep->'currencies') = 1 and rep->'currencies'->0->>'currency' = 'SGD', 'the currency filter keeps one currency');
  perform pg_temp.expect_err($$select lifeos.expense_spending_report('{"from_date":"2033-01-01"}')$$, 'invalid input');
  perform pg_temp.expect_err($$select lifeos.expense_spending_report('{"from_date":"2033-02-01","to_date":"2033-01-01"}')$$, 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. A credit purchase is one Expense; a repayment is an Event, not an Expense -----------
do $t$
declare t constant text := 'credit_purchase_is_one_expense_and_repayment_is_not_in_report';
  pl uuid := pg_temp.mk_subject('Credit PayLater', 'payment method'); cc uuid := pg_temp.mk_subject('Credit Card', 'payment method');
  x jsonb; ev jsonb; rep jsonb; myr jsonb; rl jsonb;
begin
  x := lifeos.expense_create(jsonb_build_object('transaction_date','2033-03-05','payment_method_subject_id', pl,'expense_total', 60,'currency','MYR',
        'lines', jsonb_build_array(jsonb_build_object('line_type','item','item_description','Headphones','unit_price',60,'line_total',60,'category','electronics'))));
  -- repayment on a later date: an Event linked to both Payment Method Subjects
  ev := lifeos.event_create('{"title":"Repaid PayLater with credit card RM60","occurred_date":"2033-03-25"}');
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', ev->>'id','to_type','subject','to_id', pl));
  perform lifeos.record_link_create(jsonb_build_object('from_type','event','from_id', ev->>'id','to_type','subject','to_id', cc));
  rl := lifeos.record_links_read('event', (ev->>'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rl->'links') = 2, 'the repayment Event links to both Payment Method Subjects');
  rep := lifeos.expense_spending_report('{"from_date":"2033-03-01","to_date":"2033-03-31"}');
  select c into myr from jsonb_array_elements(rep->'currencies') c where c->>'currency' = 'MYR';
  perform pg_temp.chk((myr->'parts'->0->>'total')::numeric = 60, 'the credit purchase counts once (60) and the repayment adds nothing, got ' || (myr->'parts'->0->>'total'));
  perform pg_temp.chk(jsonb_array_length(myr->'parts'->1->'items') = 1 and myr->'parts'->1->'items'->0->>'payment_method_subject_id' = pl::text, 'only the PayLater Payment Method appears');
  perform pg_temp.chk(x->>'transaction_date' = '2033-03-05', 'the purchase keeps its original Transaction Date');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
