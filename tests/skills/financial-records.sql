-- =============================================================================
-- tests/skills/financial-records.sql -- Skill flow tests: skills/financial-records/SKILL.md
-- Financial Records: Expense, Receipts, classification, credit, repayment, Refund, correction, deletion, spending report, income. Contract: financial-records.md, shared.md.
-- Each test follows the database steps of one Skill flow, in the Skill's order, through the Contract
-- functions, and asserts the outcome that the Skill and the Knowledge Base state.
--
-- Tests in this file:
--    1. expense_from_conversation_saved_with_default_currency_and_links
--    2. expenses_from_reviewed_receipts_saved_in_one_batch
--    3. expense_lines_classified_with_category_tags_and_item_subject
--    4. credit_purchase_is_one_expense_with_its_credit_payment_method
--    5. repayment_is_event_linked_to_both_payment_methods_not_an_expense
--    6. refund_recorded_as_linked_refund_expense_within_limits
--    7. expense_correction_with_reason_keeps_history_and_refund_limits
--    8. expense_delete_refund_only_or_purchase_without_refunds_with_reason
--    9. purchase_with_refunds_money_not_received_deleted_with_refunds
--   10. purchase_with_received_refund_wrong_detail_corrected_keeps_refund
--   11. purchase_with_received_refund_user_still_deletes_with_refunds
--   12. spending_report_fixed_order_per_currency_with_refund_explanation
--   13. money_coming_in_is_observation_or_event_not_expense
--   14. purchase_several_refunds_none_received_deleted_with_all_refunds
--   15. purchase_several_refunds_wrong_detail_keeps_received_deletes_not_received
--   16. purchase_several_refunds_some_received_user_still_deletes_all
--
-- Single transaction: begin; tests; select results; rollback.
-- Fixture text starts with SKT_ and business dates lie in 2032, unless a flow needs today
-- (Note date, Message finalized_at, overdue check, recorded_earlier). Those tests filter by their own IDs.
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

-- Today in Asia/Kuala_Lumpur (Contract shared.md 1.7 item 4).
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

-- JSON array helpers. A non-array value counts as an empty array.
create function pg_temp.arr(p jsonb) returns jsonb language sql as
$f$ select case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end $f$;
-- The first element whose "id" is p_id, or null.
create function pg_temp.find(p_arr jsonb, p_id uuid) returns jsonb language sql as
$f$ select e from jsonb_array_elements(pg_temp.arr(p_arr)) with ordinality x(e, o) where e ->> 'id' = p_id::text order by o limit 1 $f$;
-- How many elements have "id" p_id.
create function pg_temp.cnt(p_arr jsonb, p_id uuid) returns integer language sql as
$f$ select count(*)::integer from jsonb_array_elements(pg_temp.arr(p_arr)) e where e ->> 'id' = p_id::text $f$;
-- 1-based position of the first element with "id" p_id, or null.
create function pg_temp.pos(p_arr jsonb, p_id uuid) returns integer language sql as
$f$ select min(o)::integer from jsonb_array_elements(pg_temp.arr(p_arr)) with ordinality x(e, o) where e ->> 'id' = p_id::text $f$;
-- True when a text array in JSON holds p_val.
create function pg_temp.has_text(p_arr jsonb, p_val text) returns boolean language sql as
$f$ select exists (select 1 from jsonb_array_elements_text(pg_temp.arr(p_arr)) v where v = p_val) $f$;

-- Subject fixture through the Contract (shared.md 5.1).
create function pg_temp.mk_subject(p_name text, p_type text default null) returns uuid language sql as
$f$ select ((lifeos.subject_create(jsonb_build_object('name', p_name, 'subject_type', p_type)))->>'id')::uuid $f$;

-- The user Subject, found as the entry Skill Section 6 step 6 says (subject_search with is_user true).
-- When the project has none, the test creates it.
create function pg_temp.user_subject() returns uuid language plpgsql as $f$
declare r jsonb := lifeos.subject_search('{"is_user": true}'::jsonb);
begin
  if (r ->> 'returned_count')::integer > 0 then
    return (r -> 'results' -> 0 ->> 'id')::uuid;
  end if;
  return (lifeos.subject_create('{"name": "SKT_User", "subject_type": "person", "is_user": true}'::jsonb) ->> 'id')::uuid;
end $f$;

-- The default Currency, read from the defaults Notebook as the Skill Section 3 rule 2 says.
create function pg_temp.cur() returns text language sql as
$f$ select substring(lifeos.notebook_read('defaults') ->> 'content' from 'currency:\s*([A-Z]{3})') $f$;

-- A one-Line purchase Expense in the default Currency.
create function pg_temp.mk_expense(p_date date, p_pm uuid, p_total numeric, p_merchant text default null, p_category text default 'food')
returns jsonb language sql as
$f$ select lifeos.expense_create(jsonb_build_object('transaction_date', p_date, 'payment_method_subject_id', p_pm,
     'merchant_name', p_merchant, 'expense_total', p_total, 'currency', pg_temp.cur(),
     'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', coalesce(p_merchant, 'SKT_item'),
       'unit_price', p_total, 'line_total', p_total, 'category', p_category)))) $f$;

-- One part of a spending report currency block, by part name.
create function pg_temp.part(p_cur jsonb, p_name text) returns jsonb language sql as
$f$ select p from jsonb_array_elements(p_cur -> 'parts') p where p ->> 'name' = p_name $f$;
-- The currency block of a spending report.
create function pg_temp.cblock(p_rep jsonb, p_currency text) returns jsonb language sql as
$f$ select c from jsonb_array_elements(p_rep -> 'currencies') c where c ->> 'currency' = p_currency $f$;
-- The total of one item of a part, matched on one key.
create function pg_temp.item_total(p_part jsonb, p_key text, p_val text) returns numeric language sql as
$f$ select (i ->> 'total')::numeric from jsonb_array_elements(p_part -> 'items') i where i ->> p_key = p_val $f$;

-- 1. Section 4 Expense from conversation, with the dinner example links -----------------------------
do $t$
declare t constant text := 'expense_from_conversation_saved_with_default_currency_and_links';
  pm uuid; mer uuid := pg_temp.mk_subject('SKT_F1 Nandos', 'brand'); n uuid := pg_temp.mk_subject('SKT_F1 Nicholas', 'person');
  cash uuid := pg_temp.mk_subject('SKT_F1 Cash', 'payment method'); x jsonb; e jsonb; r jsonb; z jsonb;
begin
  perform pg_temp.chk(pg_temp.cur() = 'MYR', 'rule 2: the default Currency is MYR');
  -- step 1 and 2: the Payment Method was unknown; the user names it, and the Subject is identified
  perform pg_temp.chk(not (lifeos.subject_check('SKT_F1 Maybank Visa') ->> 'exists')::boolean, 'no Payment Method Subject yet');
  pm := pg_temp.mk_subject('SKT_F1 Maybank Visa', 'payment method');
  -- steps 3 and 4: one Line for a simple purchase, saved without a redundant confirmation
  x := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-01-15', 'transaction_time', '19:30', 'merchant_name', 'SKT_F1 Nandos',
         'branch', 'Mid Valley', 'merchant_subject_id', mer, 'payment_method_subject_id', pm, 'expense_total', 80, 'currency', pg_temp.cur(),
         'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'SKT_F1 dinner', 'unit_price', 80, 'line_total', 80, 'category', 'food'))));
  perform pg_temp.chk(x ->> 'expense_type' = 'purchase' and x ->> 'currency' = 'MYR' and (x ->> 'expense_total')::numeric = 80 and x ->> 'branch' = 'Mid Valley', 'one purchase Expense with Merchant, Branch, Total and Currency');
  perform pg_temp.chk(jsonb_array_length(x -> 'lines') = 1 and (x -> 'lines' -> 0 ->> 'quantity')::numeric = 1 and x -> 'discrepancies' = '[]'::jsonb, 'one Line, quantity 1, no discrepancy');
  -- step 5: the dinner Event and Nicholas
  e := lifeos.event_create('{"title": "SKT_F1 dinner with Nicholas", "occurred_date": "2032-01-15"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'expense', 'from_id', x ->> 'id', 'to_type', 'event', 'to_id', e ->> 'id'));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'expense', 'from_id', x ->> 'id', 'to_type', 'subject', 'to_id', n));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', n));
  r := lifeos.expense_read((x ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(r -> 'links', (e ->> 'id')::uuid) = 1 and pg_temp.cnt(r -> 'links', n) = 1, 'the Expense links to the Event and to Nicholas');
  perform pg_temp.chk(pg_temp.find(r -> 'links', pm) ->> 'via' = 'payment_method' and pg_temp.find(r -> 'links', mer) ->> 'via' = 'merchant', 'the Payment Method and Merchant Subjects are connected');
  -- rule 4: a zero payable Total uses Cash
  z := pg_temp.mk_expense('2032-01-16', cash, 0, 'SKT_F1 free sample');
  perform pg_temp.chk((z ->> 'expense_total')::numeric = 0 and z ->> 'payment_method_subject_id' = cash::text, 'a zero total is saved with Cash');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 2. Section 5 Expenses from Receipts: reviewed, then saved together -------------------------------
do $t$
declare t constant text := 'expenses_from_reviewed_receipts_saved_in_one_batch';
  card uuid := pg_temp.mk_subject('SKT_F2 Card', 'payment method'); spay uuid := pg_temp.mk_subject('SKT_F2 ShopeePay', 'payment method');
  b jsonb; fuel jsonb; shop jsonb; d jsonb;
begin
  -- step 12: two approved Receipts in one batch
  b := lifeos.expense_create_batch(jsonb_build_object('expenses', jsonb_build_array(
         jsonb_build_object('transaction_date', '2032-02-03', 'merchant_name', 'SKT_F2 Petronas', 'payment_method_subject_id', card, 'expense_total', 61.50, 'currency', pg_temp.cur(),
           'metadata', jsonb_build_object('fuel_type', 'RON95', 'vehicle_plate', 'WXY1234', 'station', 'SKT_F2 Petronas Damansara', 'odometer', 45210, 'transaction_ids', jsonb_build_array('SKT_F2-R1')),
           'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'RON95 petrol', 'source_item_text', 'RON95 30.00L @2.05',
                    'quantity', 30, 'unit_price', 2.05, 'line_total', 61.50, 'category', 'transport', 'tags', jsonb_build_array('fuel', 'wxy1234')))),
         jsonb_build_object('transaction_date', '2032-02-04', 'merchant_name', 'SKT_F2 Shopee', 'seller_name', 'SKT_F2 GadgetStore', 'payment_method_subject_id', spay,
           'expense_total', 24.90, 'currency', pg_temp.cur(),
           'lines', jsonb_build_array(
             jsonb_build_object('line_type', 'item', 'item_description', 'phone case', 'source_item_text', 'Case iPh 15 Clr', 'unit_price', 25, 'line_total', 25, 'category', 'electronics'),
             jsonb_build_object('line_type', 'charge', 'item_description', 'delivery', 'source_item_text', 'Shipping Fee', 'unit_price', 4.90, 'line_total', 4.90, 'category', 'fees'),
             jsonb_build_object('line_type', 'adjustment', 'item_description', 'shop voucher', 'source_item_text', 'Voucher', 'unit_price', -5, 'line_total', -5, 'category', 'discount'))))));
  perform pg_temp.chk((b ->> 'returned_count')::integer = 2, 'one Expense per approved Receipt');
  fuel := b -> 'results' -> 0; shop := b -> 'results' -> 1;
  perform pg_temp.chk(fuel -> 'metadata' ->> 'vehicle_plate' = 'WXY1234' and (fuel -> 'metadata' ->> 'odometer')::integer = 45210 and fuel -> 'metadata' ->> 'station' = 'SKT_F2 Petronas Damansara', 'step 4: fuel context kept in metadata');
  perform pg_temp.chk(fuel -> 'lines' -> 0 ->> 'source_item_text' = 'RON95 30.00L @2.05' and fuel -> 'lines' -> 0 ->> 'item_description' = 'RON95 petrol', 'steps 5 and 9: Source Item Text and the confirmed Item Description');
  perform pg_temp.chk(shop ->> 'merchant_name' = 'SKT_F2 Shopee' and shop ->> 'seller_name' = 'SKT_F2 GadgetStore', 'step 2: the Platform is the Merchant, the Seller kept separately');
  perform pg_temp.chk((shop -> 'lines' -> 2 ->> 'line_total')::numeric = -5 and shop -> 'lines' -> 2 ->> 'line_type' = 'adjustment' and shop -> 'discrepancies' = '[]'::jsonb, 'the voucher is a negative Adjustment Line');
  -- rule 13 and step 6: during review the Agent runs the Line-sum and Quantity x Unit Price checks itself (Agent step,
  -- no function call). After the save, the discrepancies field repeats both checks; confirmed values stay.
  perform pg_temp.chk(fuel -> 'discrepancies' = '[]'::jsonb, 'a consistent Receipt has no discrepancies after the save');
  d := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-02-05', 'merchant_name', 'SKT_F2 Kedai', 'payment_method_subject_id', card, 'expense_total', 13.05, 'currency', pg_temp.cur(),
         'lines', jsonb_build_array(
           jsonb_build_object('line_type', 'item', 'item_description', 'bread', 'quantity', 2, 'unit_price', 5, 'line_total', 10, 'category', 'food'),
           jsonb_build_object('line_type', 'item', 'item_description', 'eggs', 'quantity', 3, 'unit_price', 1.10, 'line_total', 3.00, 'category', 'food'))));
  perform pg_temp.chk((d ->> 'expense_total')::numeric = 13.05 and (d -> 'lines' -> 1 ->> 'line_total')::numeric = 3.00, 'the confirmed total and Line Total stay as confirmed');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(d -> 'discrepancies') x where x ->> 'check' = 'lines_sum' and (x ->> 'expense_total')::numeric = 13.05 and (x ->> 'lines_sum')::numeric = 13),
                      'discrepancies repeats the Line-sum check, got ' || (d -> 'discrepancies')::text);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(d -> 'discrepancies') x where x ->> 'check' = 'quantity_x_unit_price' and x ->> 'line_id' = d -> 'lines' -> 1 ->> 'id'
                      and (x ->> 'line_total')::numeric = 3.00 and (x ->> 'computed')::numeric = 3.30), 'discrepancies repeats the Quantity x Unit Price check');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(d -> 'discrepancies') x where x ->> 'check' = 'quantity_x_unit_price' and x ->> 'line_id' = d -> 'lines' -> 0 ->> 'id'), 'a consistent Line has no flag');
  -- the batch is all or nothing
  perform pg_temp.expect_err(format('select lifeos.expense_create_batch(%L::jsonb)', jsonb_build_object('expenses', jsonb_build_array(
            jsonb_build_object('transaction_date', '2032-02-06', 'merchant_name', 'SKT_F2 Tesco', 'payment_method_subject_id', card, 'expense_total', 5, 'currency', 'MYR',
              'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'unit_price', 5, 'line_total', 5, 'category', 'food'))),
            jsonb_build_object('transaction_date', '2032-02-06', 'merchant_name', 'SKT_F2 Tesco', 'payment_method_subject_id', card, 'expense_total', 5, 'currency', 'MYR', 'lines', '[]'::jsonb)))),
         'invalid input at item 1');
  perform pg_temp.chk((lifeos.expense_search('{"keyword": "SKT_F2 Tesco"}'::jsonb) ->> 'returned_count')::integer = 0, 'a rejected batch saves nothing');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 3. Section 6 Classify Expense Lines --------------------------------------------------------------
do $t$
declare t constant text := 'expense_lines_classified_with_category_tags_and_item_subject';
  pm uuid := pg_temp.mk_subject('SKT_F3 Card', 'payment method'); vit uuid := pg_temp.mk_subject('SKT_F3 vitamins', 'product');
  cats jsonb; tags jsonb; x jsonb; lk jsonb;
begin
  -- step 1
  cats := lifeos.expense_category_list();
  perform pg_temp.chk(jsonb_array_length(cats -> 'categories') = 17 and pg_temp.has_text(cats -> 'categories', 'medical'), 'the 17 Categories');
  -- steps 3, 5 and 6: reuse the vocabulary or add a lowercase hyphenated Tag
  tags := lifeos.notebook_read('expense_tags');
  perform lifeos.notebook_update('expense_tags', jsonb_build_object('content', concat_ws(E'\n', nullif(tags ->> 'content', ''), 'skt-f3-vitamin-c')));
  perform pg_temp.chk(lifeos.notebook_read('expense_tags') ->> 'content' like '%skt-f3-vitamin-c%', 'the new Tag is in the expense_tags Notebook');
  -- steps 2, 4 and 8
  x := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-03-08', 'merchant_name', 'SKT_F3 Guardian', 'payment_method_subject_id', pm, 'expense_total', 60, 'currency', pg_temp.cur(),
         'lines', jsonb_build_array(
           jsonb_build_object('line_type', 'item', 'item_description', 'Vitamin C 1000mg', 'unit_price', 45, 'line_total', 45, 'category', 'medical',
                              'tags', jsonb_build_array('skt-f3-vitamin-c', 'supplement'), 'item_subject_id', vit),
           jsonb_build_object('line_type', 'item', 'item_description', 'shampoo', 'unit_price', 15, 'line_total', 15, 'category', 'household'))));
  perform pg_temp.chk(x -> 'lines' -> 0 ->> 'category' = 'medical' and x -> 'lines' -> 0 -> 'tags' = '["skt-f3-vitamin-c", "supplement"]'::jsonb and x -> 'lines' -> 1 -> 'tags' = '[]'::jsonb, 'one Category per Line, zero to ten Tags');
  perform pg_temp.chk(pg_temp.cnt(lifeos.expense_search('{"tag": "skt-f3-vitamin-c"}'::jsonb) -> 'results', (x ->> 'id')::uuid) = 1
                      and pg_temp.cnt(lifeos.expense_search('{"category": "medical", "from_date": "2032-03-01", "to_date": "2032-03-31"}'::jsonb) -> 'results', (x ->> 'id')::uuid) = 1, 'the Expense is found by Tag and Category');
  lk := lifeos.record_links_read('subject', vit);
  perform pg_temp.chk(pg_temp.find(lk -> 'links', (x ->> 'id')::uuid) ->> 'via' = 'line_item', 'the Line links to its Item Subject');
  -- limits: more than ten Tags, or a purchase Line without a Category
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', jsonb_build_object('transaction_date', '2032-03-09', 'payment_method_subject_id', pm, 'expense_total', 1, 'currency', 'MYR',
            'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'unit_price', 1, 'line_total', 1, 'category', 'other',
              'tags', jsonb_build_array('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k'))))), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_create(%L::jsonb)', jsonb_build_object('transaction_date', '2032-03-09', 'payment_method_subject_id', pm, 'expense_total', 1, 'currency', 'MYR',
            'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'unit_price', 1, 'line_total', 1)))), 'invalid input');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 4. Section 7 Credit purchase ---------------------------------------------------------------------
do $t$
declare t constant text := 'credit_purchase_is_one_expense_with_its_credit_payment_method';
  pl uuid := pg_temp.mk_subject('SKT_F4 Shopee PayLater', 'payment method'); x jsonb; rep jsonb; mc jsonb;
begin
  x := pg_temp.mk_expense('2032-04-03', pl, 120, 'SKT_F4 Shopee', 'electronics');
  perform pg_temp.chk(x ->> 'transaction_date' = '2032-04-03' and x ->> 'payment_method_subject_id' = pl::text and x ->> 'expense_type' = 'purchase', 'an ordinary Expense on its original date with the credit Payment Method');
  perform pg_temp.chk((lifeos.expense_search(jsonb_build_object('payment_method_subject_id', pl)) ->> 'returned_count')::integer = 1, 'one Expense for the credit purchase');
  rep := lifeos.expense_spending_report('{"from_date": "2032-04-01", "to_date": "2032-04-30"}'::jsonb);
  mc := pg_temp.cblock(rep, 'MYR');
  perform pg_temp.chk(pg_temp.item_total(pg_temp.part(mc, 'by_payment_method'), 'payment_method_subject_id', pl::text) = 120
                      and pg_temp.part(mc, 'by_payment_method') -> 'items' -> 0 ->> 'payment_method_name' = 'SKT_F4 Shopee PayLater', 'the report shows the PayLater Payment Method');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 5. Section 8 Repayment or debt transfer: an Event linked to both Payment Methods ----------------------
do $t$
declare t constant text := 'repayment_is_event_linked_to_both_payment_methods_not_an_expense';
  pl uuid := pg_temp.mk_subject('SKT_F5 PayLater', 'payment method'); cc uuid := pg_temp.mk_subject('SKT_F5 Visa', 'payment method');
  x jsonb; e jsonb; lk jsonb; rep jsonb;
begin
  x := pg_temp.mk_expense('2032-05-02', pl, 200, 'SKT_F5 Lazada', 'electronics');
  -- steps 2 and 3
  e := lifeos.event_create('{"title": "SKT_F5 paid the PayLater balance RM200 by Visa", "occurred_date": "2032-05-25"}'::jsonb);
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', pl));
  perform lifeos.record_link_create(jsonb_build_object('from_type', 'event', 'from_id', e ->> 'id', 'to_type', 'subject', 'to_id', cc));
  lk := lifeos.record_links_read('event', (e ->> 'id')::uuid);
  perform pg_temp.chk(pg_temp.cnt(lk -> 'links', pl) = 1 and pg_temp.cnt(lk -> 'links', cc) = 1, 'the Event links to both Payment Methods');
  perform pg_temp.chk(pg_temp.cnt(lifeos.subject_records(cc, '{}'::jsonb) -> 'results', (e ->> 'id')::uuid) = 1, 'the repayment is found from the card');
  -- outcome: the report counts only the original purchase
  perform pg_temp.chk((lifeos.expense_search('{"from_date": "2032-05-01", "to_date": "2032-05-31"}'::jsonb) ->> 'returned_count')::integer = 1, 'no Expense for the repayment');
  rep := lifeos.expense_spending_report('{"from_date": "2032-05-01", "to_date": "2032-05-31"}'::jsonb);
  perform pg_temp.chk((pg_temp.part(pg_temp.cblock(rep, 'MYR'), 'total_spent') ->> 'total')::numeric = 200, 'the report holds only the purchase');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 6. Section 9 Refund, Return or Reversal ----------------------------------------------------------
do $t$
declare t constant text := 'refund_recorded_as_linked_refund_expense_within_limits';
  pm uuid := pg_temp.mk_subject('SKT_F6 Card', 'payment method'); o jsonb; found jsonb; r1 jsonb; r2 jsonb; r3 jsonb; ro jsonb;
begin
  o := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-06-05', 'merchant_name', 'SKT_F6 Zalora', 'payment_method_subject_id', pm, 'expense_total', 150, 'currency', pg_temp.cur(),
         'lines', jsonb_build_array(
           jsonb_build_object('line_type', 'item', 'item_description', 'shoes', 'unit_price', 120, 'line_total', 120, 'category', 'clothing'),
           jsonb_build_object('line_type', 'charge', 'item_description', 'delivery', 'unit_price', 10, 'line_total', 10, 'category', 'fees'),
           jsonb_build_object('line_type', 'item', 'item_description', 'bag', 'unit_price', 20, 'line_total', 20, 'category', 'clothing'))));
  -- step 1
  found := lifeos.expense_search('{"keyword": "SKT_F6 Zalora", "expense_type": "purchase"}'::jsonb);
  perform pg_temp.chk((found ->> 'returned_count')::integer = 1 and found -> 'results' -> 0 ->> 'id' = o ->> 'id', 'the original Expense is identified');
  -- steps 3, 4 and 6: the credit note names the shoes
  r1 := lifeos.expense_refund_create(jsonb_build_object('refund_of', o ->> 'id', 'refund_amount', 120, 'transaction_date', '2032-06-10', 'line_type', 'item', 'item_description', 'refund for the shoes'));
  perform pg_temp.chk(r1 ->> 'expense_type' = 'refund' and r1 ->> 'refund_of' = o ->> 'id' and (r1 ->> 'expense_total')::numeric = -120, 'a new Refund Expense linked to the original with a negative total');
  perform pg_temp.chk(r1 ->> 'payment_method_subject_id' = pm::text and r1 ->> 'currency' = 'MYR' and r1 ->> 'merchant_name' = 'SKT_F6 Zalora', 'it keeps the original Payment Method, Currency and Merchant');
  perform pg_temp.chk(jsonb_array_length(r1 -> 'lines') = 1 and (r1 -> 'lines' -> 0 ->> 'line_total')::numeric = -120 and r1 -> 'lines' -> 0 ->> 'category' is null
                      and r1 -> 'lines' -> 0 ->> 'item_description' = 'refund for the shoes' and r1 -> 'lines' -> 0 ->> 'line_type' = 'item', 'one negative Line, no Category, the named item');
  perform pg_temp.chk(r1 -> 'original' ->> 'id' = o ->> 'id', 'the Refund names its original');
  -- a delivery-fee Refund on the purchase day is allowed
  r2 := lifeos.expense_refund_create(jsonb_build_object('refund_of', o ->> 'id', 'refund_amount', 10, 'transaction_date', '2032-06-05', 'line_type', 'charge'));
  perform pg_temp.chk(r2 -> 'lines' -> 0 ->> 'line_type' = 'charge' and r2 -> 'lines' -> 0 ->> 'item_description' is null, 'step 5: the amount alone states a Refund without a named item');
  -- step 2: the limits
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', jsonb_build_object('refund_of', o ->> 'id', 'refund_amount', 30, 'transaction_date', '2032-06-12', 'line_type', 'adjustment')), 'invalid input');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', jsonb_build_object('refund_of', o ->> 'id', 'refund_amount', 5, 'transaction_date', '2032-06-04', 'line_type', 'adjustment')), 'invalid input');
  -- a partial Refund with an unknown item
  r3 := lifeos.expense_refund_create(jsonb_build_object('refund_of', o ->> 'id', 'refund_amount', 15, 'transaction_date', '2032-06-20', 'line_type', 'adjustment'));
  perform pg_temp.chk((r3 ->> 'expense_total')::numeric = -15 and r3 -> 'lines' -> 0 ->> 'line_type' = 'adjustment', 'a partial Refund uses its actual amount');
  -- outcome: the original stays unchanged and lists its Refunds
  ro := lifeos.expense_read((o ->> 'id')::uuid);
  perform pg_temp.chk((ro ->> 'expense_total')::numeric = 150 and jsonb_array_length(ro -> 'lines') = 3 and (ro ->> 'version')::integer = 1, 'the original Expense is unchanged');
  perform pg_temp.chk(jsonb_array_length(ro -> 'refunds') = 3 and ro -> 'refunds' -> 0 ->> 'id' = r2 ->> 'id', 'the original lists its Refunds by date');
  perform pg_temp.expect_err(format('select lifeos.expense_refund_create(%L::jsonb)', jsonb_build_object('refund_of', r1 ->> 'id', 'refund_amount', 1, 'transaction_date', '2032-06-21', 'line_type', 'item')), 'invalid relationship');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 7. Section 10 Correct an Expense with a reason ---------------------------------------------------
do $t$
declare t constant text := 'expense_correction_with_reason_keeps_history_and_refund_limits';
  pm uuid := pg_temp.mk_subject('SKT_F7 Card', 'payment method'); p jsonb; r jsonb; c jsonb; h jsonb; rc jsonb; rm jsonb;
begin
  p := pg_temp.mk_expense('2032-07-05', pm, 100, 'SKT_F7 Mydin', 'household');
  r := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 40, 'transaction_date', '2032-07-10', 'line_type', 'adjustment'));
  -- step 2: a correction always carries its reason
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%s, '{"merchant_name": "SKT_F7 Mydin Subang"}'::jsonb)$$, pg_temp.q((p ->> 'id')::uuid)), 'invalid input');
  -- step 4
  c := lifeos.expense_update((p ->> 'id')::uuid, jsonb_build_object('merchant_name', 'SKT_F7 Mydin Subang', 'expense_total', 90, 'correction_reason', 'SKT_F7 the receipt shows RM90',
         'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'groceries', 'unit_price', 90, 'line_total', 90, 'category', 'household'))));
  perform pg_temp.chk((c ->> 'expense_total')::numeric = 90 and c ->> 'merchant_name' = 'SKT_F7 Mydin Subang' and (c ->> 'version')::integer = 2 and c ->> 'id' = p ->> 'id', 'corrected in place, version 2');
  -- step 3: limits from the purchase side
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%s, '{"expense_total": 30, "correction_reason": "SKT_F7 x"}'::jsonb)$$, pg_temp.q((p ->> 'id')::uuid)), 'invalid input');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%s, '{"transaction_date": "2032-07-11", "correction_reason": "SKT_F7 x"}'::jsonb)$$, pg_temp.q((p ->> 'id')::uuid)), 'invalid input');
  -- a Refund correction keeps its limits from its side
  rc := lifeos.expense_update((r ->> 'id')::uuid, '{"refund_amount": 50, "correction_reason": "SKT_F7 the bank credited RM50"}'::jsonb);
  perform pg_temp.chk((rc ->> 'expense_total')::numeric = -50 and rc ->> 'expense_type' = 'refund' and rc ->> 'payment_method_subject_id' = pm::text, 'the Refund is corrected and keeps its shape');
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%s, '{"refund_amount": 95, "correction_reason": "SKT_F7 x"}'::jsonb)$$, pg_temp.q((r ->> 'id')::uuid)), 'invalid input');
  -- a Remark is no correction
  rm := lifeos.record_add_remark('expense', (p ->> 'id')::uuid, 'SKT_F7 paid at the self-checkout');
  perform pg_temp.chk((rm ->> 'version')::integer = 2, 'a Remark creates no version');
  -- step 5: the history
  h := lifeos.expense_history((p ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(h -> 'history') = 2, 'two versions, got ' || jsonb_array_length(h -> 'history'));
  perform pg_temp.chk((h -> 'history' -> 0 -> 'snapshot' ->> 'expense_total')::numeric = 100 and h -> 'history' -> 0 ->> 'corrected_at' is null, 'the earlier version is kept');
  perform pg_temp.chk(h -> 'history' -> 1 ->> 'correction_reason' = 'SKT_F7 the receipt shows RM90' and h -> 'history' -> 1 ->> 'corrected_at' is not null, 'the reason stays with the correction');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 8. Section 11 Delete a Refund, or a purchase without active Refunds ---------------------------------
do $t$
declare t constant text := 'expense_delete_refund_only_or_purchase_without_refunds_with_reason';
  pm uuid := pg_temp.mk_subject('SKT_F8 Card', 'payment method'); a jsonb; r jsonb; b jsonb; d jsonb; h jsonb;
begin
  a := pg_temp.mk_expense('2032-08-03', pm, 100, 'SKT_F8 Uniqlo', 'clothing');
  r := lifeos.expense_refund_create(jsonb_build_object('refund_of', a ->> 'id', 'refund_amount', 30, 'transaction_date', '2032-08-05', 'line_type', 'item'));
  -- step 2: a deletion always carries its reason
  perform pg_temp.expect_err(format($$select lifeos.expense_delete(%s, '  ')$$, pg_temp.q((r ->> 'id')::uuid)), 'invalid input');
  -- step 3: a Refund alone
  d := lifeos.expense_delete((r ->> 'id')::uuid, 'SKT_F8 recorded twice by mistake');
  perform pg_temp.chk(d ->> 'deleted_at' is not null and d -> 'deleted_refund_ids' = '[]'::jsonb, 'only the Refund is deleted');
  perform pg_temp.chk(lifeos.expense_read((a ->> 'id')::uuid) ->> 'deleted_at' is null and lifeos.expense_read((a ->> 'id')::uuid) -> 'refunds' = '[]'::jsonb, 'the purchase stays and has no active Refund');
  -- step 4: a purchase without active Refunds
  b := pg_temp.mk_expense('2032-08-10', pm, 45, 'SKT_F8 Popular', 'education');
  d := lifeos.expense_delete((b ->> 'id')::uuid, 'SKT_F8 this was the friend''s purchase');
  perform pg_temp.chk(d ->> 'deleted_at' is not null, 'the purchase is deleted');
  h := lifeos.expense_history((b ->> 'id')::uuid);
  perform pg_temp.chk(h -> 'history' -> (jsonb_array_length(h -> 'history') - 1) ->> 'correction_reason' = 'SKT_F8 this was the friend''s purchase', 'the reason is in its history');
  perform pg_temp.chk((lifeos.expense_search('{"keyword": "SKT_F8 Popular"}'::jsonb) ->> 'returned_count')::integer = 0, 'the deleted Expense is out of the search');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 9. Section 12 (M-0022 D5) branch: the Refund money was not received; the purchase goes with its Refunds -
do $t$
declare t constant text := 'purchase_with_refunds_money_not_received_deleted_with_refunds';
  pm uuid := pg_temp.mk_subject('SKT_F9 Card', 'payment method'); p jsonb; r1 jsonb; r2 jsonb; rd jsonb; d jsonb;
begin
  p := pg_temp.mk_expense('2032-09-02', pm, 200, 'SKT_F9 Courts', 'electronics');
  r1 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 50, 'transaction_date', '2032-09-04', 'line_type', 'adjustment'));
  r2 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 30, 'transaction_date', '2032-09-05', 'line_type', 'adjustment'));
  -- input: the active Refunds from the refunds field, asked about one by one
  rd := lifeos.expense_read((p ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rd -> 'refunds') = 2 and rd -> 'refunds' -> 0 ->> 'id' = r1 ->> 'id', 'the refunds field lists both Refunds');
  -- step 3: not received; after the user confirms
  d := lifeos.expense_delete((p ->> 'id')::uuid, 'SKT_F9 the order never happened and no money came back');
  perform pg_temp.chk(d -> 'deleted_refund_ids' = jsonb_build_array(r1 ->> 'id', r2 ->> 'id'), 'both Refunds go with the purchase, in refunds order');
  perform pg_temp.chk(lifeos.expense_read((r1 ->> 'id')::uuid) ->> 'deleted_at' = d ->> 'deleted_at' and lifeos.expense_read((r2 ->> 'id')::uuid) ->> 'deleted_at' = d ->> 'deleted_at', 'the Refunds share the deletion time');
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(lifeos.expense_history((r1 ->> 'id')::uuid) -> 'history') v where v ->> 'correction_reason' = 'SKT_F9 the order never happened and no money came back'), 'each Refund keeps the reason in its history');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 10. Section 12 branch: money received, a purchase detail was wrong; correction, the Refund stays ---------
do $t$
declare t constant text := 'purchase_with_received_refund_wrong_detail_corrected_keeps_refund';
  pm uuid := pg_temp.mk_subject('SKT_F10 Card', 'payment method'); p jsonb; r jsonb; c jsonb; rd jsonb;
begin
  p := pg_temp.mk_expense('2032-09-12', pm, 300, 'SKT_F10 Harvey Norman', 'electronics');
  r := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 100, 'transaction_date', '2032-09-15', 'line_type', 'item'));
  -- step 5: the amount was wrong; the correction keeps the Refund within its limits
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%s, '{"expense_total": 80, "correction_reason": "SKT_F10 x"}'::jsonb)$$, pg_temp.q((p ->> 'id')::uuid)), 'invalid input');
  c := lifeos.expense_update((p ->> 'id')::uuid, jsonb_build_object('expense_total', 250, 'correction_reason', 'SKT_F10 the price was RM250, not RM300',
         'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'SKT_F10 air fryer', 'unit_price', 250, 'line_total', 250, 'category', 'electronics'))));
  perform pg_temp.chk((c ->> 'expense_total')::numeric = 250 and c ->> 'deleted_at' is null, 'the purchase is corrected, not deleted');
  rd := lifeos.expense_read((p ->> 'id')::uuid);
  perform pg_temp.chk(jsonb_array_length(rd -> 'refunds') = 1 and rd -> 'refunds' -> 0 ->> 'id' = r ->> 'id', 'the purchase keeps its Refund');
  perform pg_temp.chk(lifeos.expense_read((r ->> 'id')::uuid) ->> 'deleted_at' is null, 'the Refund stays active');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 11. Section 12 branch: money received, the user still wants deletion; the Refunds go with it -------------
do $t$
declare t constant text := 'purchase_with_received_refund_user_still_deletes_with_refunds';
  pm uuid := pg_temp.mk_subject('SKT_F11 Card', 'payment method'); p jsonb; r jsonb; d jsonb; rep jsonb;
begin
  p := pg_temp.mk_expense('2032-09-22', pm, 60, 'SKT_F11 Watsons', 'beauty');
  r := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 60, 'transaction_date', '2032-09-23', 'line_type', 'item'));
  -- step 6: after the user confirms
  d := lifeos.expense_delete((p ->> 'id')::uuid, 'SKT_F11 the user does not want this returned purchase in the records');
  perform pg_temp.chk(d -> 'deleted_refund_ids' = jsonb_build_array(r ->> 'id'), 'the Refund goes with the purchase');
  rep := lifeos.expense_spending_report('{"from_date": "2032-09-21", "to_date": "2032-09-30"}'::jsonb);
  perform pg_temp.chk(rep -> 'currencies' = '[]'::jsonb, 'neither the purchase nor the Refund is counted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 12. Section 13 Spending report: fixed order, per currency, refunds explained ---------------------------
do $t$
declare t constant text := 'spending_report_fixed_order_per_currency_with_refund_explanation';
  visa uuid := pg_temp.mk_subject('SKT_F12 Visa', 'payment method'); grab uuid := pg_temp.mk_subject('SKT_F12 GrabPay', 'payment method');
  e1 jsonb; e2 jsonb; e3 jsonb; e4 jsonb; r1 jsonb; r2 jsonb; rep jsonb; my jsonb; sg jsonb; nov jsonb;
begin
  e1 := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-10-03', 'merchant_name', 'SKT_F12 Shopee', 'payment_method_subject_id', visa, 'expense_total', 100, 'currency', 'MYR',
         'lines', jsonb_build_array(
           jsonb_build_object('line_type', 'item', 'item_description', 'SKT_F12 meal kit', 'unit_price', 60, 'line_total', 60, 'category', 'food', 'tags', jsonb_build_array('skt-f12-dinner')),
           jsonb_build_object('line_type', 'item', 'item_description', 'SKT_F12 coffee beans', 'unit_price', 45, 'line_total', 45, 'category', 'drink', 'tags', jsonb_build_array('skt-f12-dinner', 'skt-f12-coffee')),
           jsonb_build_object('line_type', 'adjustment', 'item_description', 'SKT_F12 voucher', 'unit_price', -5, 'line_total', -5, 'category', 'discount'))));
  e2 := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-10-10', 'merchant_name', 'SKT_F12 Grab', 'payment_method_subject_id', grab, 'expense_total', 30, 'currency', 'MYR',
         'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'SKT_F12 ride', 'unit_price', 30, 'line_total', 30, 'category', 'transport', 'tags', jsonb_build_array('skt-f12-grab')))));
  e3 := lifeos.expense_create(jsonb_build_object('transaction_date', '2032-10-15', 'merchant_name', 'SKT_F12 Hawker SG', 'payment_method_subject_id', visa, 'expense_total', 20, 'currency', 'SGD',
         'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'SKT_F12 chicken rice', 'unit_price', 20, 'line_total', 20, 'category', 'food'))));
  e4 := pg_temp.mk_expense('2032-10-25', visa, 50, 'SKT_F12 Aeon', 'food');
  r1 := lifeos.expense_refund_create(jsonb_build_object('refund_of', e1 ->> 'id', 'refund_amount', 10, 'transaction_date', '2032-10-20', 'line_type', 'item'));
  r2 := lifeos.expense_refund_create(jsonb_build_object('refund_of', e4 ->> 'id', 'refund_amount', 15, 'transaction_date', '2032-11-05', 'line_type', 'item'));
  -- step 1
  rep := lifeos.expense_spending_report('{"from_date": "2032-10-01", "to_date": "2032-10-31"}'::jsonb);
  -- step 3: each currency separately
  my := pg_temp.cblock(rep, 'MYR'); sg := pg_temp.cblock(rep, 'SGD');
  perform pg_temp.chk(my is not null and sg is not null, 'MYR and SGD are reported separately');
  -- step 2: the five parts in order
  perform pg_temp.chk((select array_agg(p ->> 'name' order by o) from jsonb_array_elements(my -> 'parts') with ordinality x(p, o))
                      = array['total_spent', 'by_payment_method', 'by_category', 'by_tag', 'adjustments'], 'the parts keep the fixed order');
  -- step 5: a Refund in the period reduces the total and the Payment Method breakdown
  perform pg_temp.chk((pg_temp.part(my, 'total_spent') ->> 'total')::numeric = 170, 'MYR total 100 + 30 + 50 - 10, got ' || (pg_temp.part(my, 'total_spent') ->> 'total'));
  perform pg_temp.chk(pg_temp.item_total(pg_temp.part(my, 'by_payment_method'), 'payment_method_subject_id', visa::text) = 140
                      and pg_temp.part(my, 'by_payment_method') -> 'items' -> 0 ->> 'payment_method_subject_id' = visa::text, 'Payment Methods by total, the Refund reduces Visa');
  -- step 4: Category and Tag from Line amounts, Adjustments and Refunds left out
  perform pg_temp.chk(pg_temp.item_total(pg_temp.part(my, 'by_category'), 'category', 'food') = 110 and pg_temp.item_total(pg_temp.part(my, 'by_category'), 'category', 'drink') = 45
                      and pg_temp.item_total(pg_temp.part(my, 'by_category'), 'category', 'discount') is null, 'Categories ignore Adjustments and Refunds');
  perform pg_temp.chk(pg_temp.item_total(pg_temp.part(my, 'by_tag'), 'tag', 'skt-f12-dinner') = 105 and pg_temp.item_total(pg_temp.part(my, 'by_tag'), 'tag', 'skt-f12-coffee') = 45, 'Tags overlap');
  perform pg_temp.chk((pg_temp.part(my, 'adjustments') ->> 'total')::numeric = -5 and pg_temp.part(my, 'adjustments') -> 'items' -> 0 ->> 'merchant_name' = 'SKT_F12 Shopee', 'the Adjustments stand on their own, with their source');
  perform pg_temp.chk((pg_temp.part(sg, 'total_spent') ->> 'total')::numeric = 20, 'SGD has its own total without conversion');
  -- step 6: refunds explained
  perform pg_temp.chk(pg_temp.find(my -> 'refunds_in_period', (r1 ->> 'id')::uuid) ->> 'original_transaction_date' = '2032-10-03'
                      and (pg_temp.find(my -> 'refunds_in_period', (r1 ->> 'id')::uuid) ->> 'original_total')::numeric = 100, 'a Refund in the month, with its original');
  perform pg_temp.chk(pg_temp.find(my -> 'later_refunds', (r2 ->> 'id')::uuid) ->> 'transaction_date' = '2032-11-05', 'a later Refund of an October purchase is listed for mention');
  nov := pg_temp.cblock(lifeos.expense_spending_report('{"from_date": "2032-11-01", "to_date": "2032-11-30"}'::jsonb), 'MYR');
  perform pg_temp.chk((pg_temp.part(nov, 'total_spent') ->> 'total')::numeric = -15 and pg_temp.find(nov -> 'refunds_in_period', (r2 ->> 'id')::uuid) ->> 'original_transaction_date' = '2032-10-25', 'the Refund counts in the month the money came back');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 13. Section 14 Money coming in: an Observation of a bank account, or an Event --------------------------
do $t$
declare t constant text := 'money_coming_in_is_observation_or_event_not_expense';
  bank uuid := pg_temp.mk_subject('SKT_F13 Maybank savings', 'bank account'); o jsonb; e jsonb;
begin
  -- step 1: a tracked bank-account Subject exists
  o := lifeos.observation_create(jsonb_build_object('subject_id', bank, 'observation_name', 'SKT_F13 balance', 'value_numeric', 5200, 'unit', 'MYR', 'observed_date', '2032-12-01'));
  perform pg_temp.chk(o ->> 'subject_id' = bank::text and (o ->> 'value_numeric')::numeric = 5200, 'an Observation of the bank account');
  -- step 2: otherwise an Event
  e := lifeos.event_create('{"title": "SKT_F13 I received RM300 from Ah Seng", "occurred_date": "2032-12-02"}'::jsonb);
  perform pg_temp.chk(e ->> 'title' like '%received RM300%', 'an Event for the money received');
  -- outcome: Financial Records hold no income
  perform pg_temp.chk((lifeos.expense_search('{"from_date": "2032-12-01", "to_date": "2032-12-31"}'::jsonb) ->> 'returned_count')::integer = 0, 'no Expense for income');
  perform pg_temp.chk(lifeos.expense_spending_report('{"from_date": "2032-12-01", "to_date": "2032-12-31"}'::jsonb) -> 'currencies' = '[]'::jsonb, 'the report is empty for the month');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 14. Section 12 branch with several Refunds: no Refund money was received; the purchase goes with all its Refunds ---
do $t$
declare t constant text := 'purchase_several_refunds_none_received_deleted_with_all_refunds';
  pm uuid := pg_temp.mk_subject('SKT_F14 Card', 'payment method'); p jsonb; r1 jsonb; r2 jsonb; r3 jsonb; rd jsonb; d jsonb;
begin
  p := pg_temp.mk_expense('2032-08-15', pm, 300, 'SKT_F14 Lazada', 'household');
  r1 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 40, 'transaction_date', '2032-08-16', 'line_type', 'item'));
  r2 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 10, 'transaction_date', '2032-08-17', 'line_type', 'charge'));
  r3 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 50, 'transaction_date', '2032-08-18', 'line_type', 'adjustment'));
  -- input: the active Refunds from the refunds field
  rd := lifeos.expense_read((p ->> 'id')::uuid);
  perform pg_temp.chk((select array_agg(x ->> 'id' order by o) from jsonb_array_elements(rd -> 'refunds') with ordinality y(x, o)) = array[r1 ->> 'id', r2 ->> 'id', r3 ->> 'id'], 'the refunds field lists the three Refunds in date order');
  -- step 1: for each of the three Refunds the user answers that its money was not received (Agent step)
  -- step 2: the Agent states that deleting the purchase deletes all its Refunds (Agent step)
  -- step 3: after the user confirms
  d := lifeos.expense_delete((p ->> 'id')::uuid, 'SKT_F14 the order was cancelled and none of the three refunds came back');
  perform pg_temp.chk(d -> 'deleted_refund_ids' = jsonb_build_array(r1 ->> 'id', r2 ->> 'id', r3 ->> 'id'), 'all three Refunds go with the purchase');
  perform pg_temp.chk(lifeos.expense_read((r1 ->> 'id')::uuid) ->> 'deleted_at' = d ->> 'deleted_at' and lifeos.expense_read((r2 ->> 'id')::uuid) ->> 'deleted_at' = d ->> 'deleted_at'
                      and lifeos.expense_read((r3 ->> 'id')::uuid) ->> 'deleted_at' = d ->> 'deleted_at', 'each Refund has the deletion time of the purchase');
  perform pg_temp.chk((lifeos.expense_search(jsonb_build_object('refund_of', p ->> 'id')) ->> 'returned_count')::integer = 0, 'no active Refund of the purchase is left');
  perform pg_temp.chk(lifeos.expense_spending_report('{"from_date": "2032-08-14", "to_date": "2032-08-20"}'::jsonb) -> 'currencies' = '[]'::jsonb, 'neither the purchase nor a Refund is counted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 15. Section 12 branch with several Refunds: some money received, a purchase detail was wrong ----------------
-- Step 5: keep each received Refund, delete each Refund without received money with its reason, then correct.
do $t$
declare t constant text := 'purchase_several_refunds_wrong_detail_keeps_received_deletes_not_received';
  pm uuid := pg_temp.mk_subject('SKT_F15 Card', 'payment method'); p jsonb; r1 jsonb; r2 jsonb; r3 jsonb; d3 jsonb; c jsonb; rd jsonb; h jsonb; rep jsonb;
begin
  p := pg_temp.mk_expense('2032-08-22', pm, 300, 'SKT_F15 Courts', 'electronics');
  r1 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 100, 'transaction_date', '2032-08-23', 'line_type', 'item'));
  r2 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 50, 'transaction_date', '2032-08-24', 'line_type', 'item'));
  r3 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 120, 'transaction_date', '2032-08-25', 'line_type', 'adjustment'));
  perform pg_temp.chk(jsonb_array_length(lifeos.expense_read((p ->> 'id')::uuid) -> 'refunds') = 3, 'input: three active Refunds');
  -- step 1: the money of r1 and r2 was received, the money of r3 never came (Agent step)
  -- step 4: the purchase really happened; the user says the price was RM200, not RM300 (Agent step)
  -- Contract guard (financial-records.md 6.5 item 9), not a Skill step: with r3 still active the correction breaks the Refund limit
  perform pg_temp.expect_err(format($$select lifeos.expense_update(%s, '{"expense_total": 200, "correction_reason": "SKT_F15 x"}'::jsonb)$$, pg_temp.q((p ->> 'id')::uuid)), 'invalid input');
  -- step 5.2: delete the Refund without received money, with the reason
  d3 := lifeos.expense_delete((r3 ->> 'id')::uuid, 'SKT_F15 this refund money was never received');
  perform pg_temp.chk(d3 ->> 'deleted_at' is not null and d3 -> 'deleted_refund_ids' = '[]'::jsonb, 'only that Refund is deleted');
  h := lifeos.expense_history((r3 ->> 'id')::uuid);
  perform pg_temp.chk(h -> 'history' -> (jsonb_array_length(h -> 'history') - 1) ->> 'correction_reason' = 'SKT_F15 this refund money was never received', 'the reason is in the Refund history');
  -- step 5.3: correct the purchase under Section 10; the kept Refunds stay within its limits
  c := lifeos.expense_update((p ->> 'id')::uuid, jsonb_build_object('expense_total', 200, 'correction_reason', 'SKT_F15 the price was RM200, not RM300',
         'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'item_description', 'SKT_F15 rice cooker', 'unit_price', 200, 'line_total', 200, 'category', 'electronics'))));
  perform pg_temp.chk((c ->> 'expense_total')::numeric = 200 and c ->> 'deleted_at' is null, 'the purchase is corrected, not deleted');
  -- outcome
  rd := lifeos.expense_read((p ->> 'id')::uuid);
  perform pg_temp.chk((select array_agg(x ->> 'id' order by o) from jsonb_array_elements(rd -> 'refunds') with ordinality y(x, o)) = array[r1 ->> 'id', r2 ->> 'id'], 'the purchase keeps both received Refunds, got ' || (rd -> 'refunds')::text);
  perform pg_temp.chk(lifeos.expense_read((r1 ->> 'id')::uuid) ->> 'deleted_at' is null and lifeos.expense_read((r2 ->> 'id')::uuid) ->> 'deleted_at' is null
                      and lifeos.expense_read((r3 ->> 'id')::uuid) ->> 'deleted_at' is not null, 'received Refunds stay active, the other is deleted');
  h := lifeos.expense_history((p ->> 'id')::uuid);
  perform pg_temp.chk(h -> 'history' -> (jsonb_array_length(h -> 'history') - 1) ->> 'correction_reason' = 'SKT_F15 the price was RM200, not RM300', 'the correction reason is in the purchase history');
  rep := pg_temp.cblock(lifeos.expense_spending_report('{"from_date": "2032-08-21", "to_date": "2032-08-31"}'::jsonb), pg_temp.cur());
  perform pg_temp.chk((pg_temp.part(rep, 'total_spent') ->> 'total')::numeric = 50, 'the total is 200 - 100 - 50, got ' || coalesce(pg_temp.part(rep, 'total_spent') ->> 'total', '<none>'));
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- 16. Section 12 branch with several Refunds: some money received, the user still wants deletion ---------------
do $t$
declare t constant text := 'purchase_several_refunds_some_received_user_still_deletes_all';
  pm uuid := pg_temp.mk_subject('SKT_F16 Card', 'payment method'); p jsonb; r1 jsonb; r2 jsonb; d jsonb;
begin
  p := pg_temp.mk_expense('2032-07-20', pm, 150, 'SKT_F16 Shopee', 'clothing');
  r1 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 30, 'transaction_date', '2032-07-21', 'line_type', 'item'));
  r2 := lifeos.expense_refund_create(jsonb_build_object('refund_of', p ->> 'id', 'refund_amount', 20, 'transaction_date', '2032-07-22', 'line_type', 'item'));
  perform pg_temp.chk(jsonb_array_length(lifeos.expense_read((p ->> 'id')::uuid) -> 'refunds') = 2, 'input: two active Refunds');
  -- step 1: the money of r1 was received, the money of r2 was not (Agent step)
  -- step 4: the purchase really happened; the Agent asks why; the user still wants it deleted (Agent step)
  -- step 6: after the user confirms, the purchase and all its Refunds are deleted
  d := lifeos.expense_delete((p ->> 'id')::uuid, 'SKT_F16 the user does not want this purchase in the records');
  perform pg_temp.chk(d -> 'deleted_refund_ids' = jsonb_build_array(r1 ->> 'id', r2 ->> 'id'), 'the received and the not received Refund go with the purchase');
  perform pg_temp.chk((lifeos.expense_search('{"keyword": "SKT_F16 Shopee"}'::jsonb) ->> 'returned_count')::integer = 0, 'no active Expense of the purchase is left');
  perform pg_temp.chk(lifeos.expense_spending_report('{"from_date": "2032-07-18", "to_date": "2032-07-31"}'::jsonb) -> 'currencies' = '[]'::jsonb, 'neither the purchase nor a Refund is counted');
  perform pg_temp.pass(t);
exception when others then perform pg_temp.fail(t, sqlerrm);
end $t$;

-- Result table, selected before the rollback.
select test, status, detail from t_results order by seq;

rollback;
