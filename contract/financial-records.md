# LifeOS Database Contract: Financial Records

This file covers the Financial Records Module: Expense, Expense Line, Refund, corrections and the spending report. The runtime Agent reads it together with [shared.md](shared.md), which holds the configuration, the common rules, Record links, Remarks, Subject and Timeline. Vocabularies and default values come from [notebook.md](notebook.md).

Contents:

- [6. Financial Records](#6-financial-records)
  - [6.1 expense_create](#61-expense_create)
  - [6.2 expense_create_batch](#62-expense_create_batch)
  - [6.3 expense_read](#63-expense_read)
  - [6.4 expense_search](#64-expense_search)
  - [6.5 expense_update](#65-expense_update)
  - [6.6 expense_history](#66-expense_history)
  - [6.7 expense_delete](#67-expense_delete)
  - [6.8 expense_refund_create](#68-expense_refund_create)
  - [6.9 expense_spending_report](#69-expense_spending_report)
  - [6.10 expense_category_list](#610-expense_category_list)

# 6. Financial Records

Financial Records record Expenses only. Income is recorded as an Observation or an Event. A repayment between Payment Methods, such as paying a PayLater balance by credit card, is an Event linked to both Payment Method Subjects. No uploaded Receipt or Invoice file is stored. The Expense, its Lines and each Line's Source Item Text remain.

Expense Record fields:

| Field | Type | Meaning |
|---|---|---|
| `expense_type` | text | `purchase` or `refund`. |
| `transaction_date` | date, required | Transaction Date. For a Refund, the date the money came back. |
| `transaction_time` | time | Transaction time when known. |
| `merchant_name` | text | Readable Merchant or Platform name. |
| `branch` | text | Known Branch. |
| `merchant_subject_id` | uuid | Merchant Subject when that identity is available. |
| `seller_name` | text | Seller on an e-commerce Platform. |
| `payment_method_subject_id` | uuid, required | The one Payment Method Subject. |
| `expense_total` | numeric, required | Expense Total. Exact precision is kept. A Refund total is negative. |
| `currency` | text, required | ISO 4217 code. The Agent supplies it. The default currency is in the `defaults` Notebook ([notebook.md Chapter 3](notebook.md#3-notebook)). |
| `refund_of` | uuid | For a Refund, the original Expense. |
| `remarks` | jsonb array | [shared.md 1.5 item 10](shared.md#15-common-interface-semantics). |
| `metadata` | jsonb | Transaction identifiers and fuel context: `transaction_ids`, `fuel_type`, `vehicle_plate`, `station`, `odometer`. |
| `lines` | array | The Expense Lines. |

Expense Line fields:

| Field | Type | Meaning |
|---|---|---|
| `id` | uuid | Line ID. |
| `expense_id` | uuid | The Expense that holds the Line. |
| `line_no` | integer | Order within the Expense, from 1. |
| `line_type` | text | `item`, `charge` or `adjustment`. |
| `item_description` | text | Item or service identity confirmed by the user. |
| `source_item_text` | text | Receipt wording, when available. |
| `quantity` | numeric | Quantity. |
| `unit_price` | numeric, required | Unit Price. |
| `line_total` | numeric, required | Signed Line Total. Charges are positive. Discounts and subsidies are negative. Rounding keeps its signed effect. |
| `category` | text | One of the 17 Categories (6.10). `null` only on a Refund line. |
| `tags` | text array | Zero to ten Tags. |
| `item_subject_id` | uuid | The purchased item's Subject. |
| `metadata` | jsonb | [shared.md 1.5 item 11](shared.md#15-common-interface-semantics). |
| `created_at`, `updated_at` | timestamptz | System timestamps of the Line ([shared.md 1.7 item 2](shared.md#17-date-and-time-rules)). |

Derived fields on every Expense return:
1. `discrepancies` — comparison checks only. Stored values never change because of them.
   - `{ "check": "lines_sum", "expense_total", "lines_sum" }` when the Expense has Lines and their sum differs from `expense_total`.
   - `{ "check": "quantity_x_unit_price", "line_id", "line_total", "computed" }` for each Line whose `quantity × unit_price` differs from `line_total`.
2. `refunds` — on a purchase, the active Refund Expenses with `refund_of` equal to its ID. Each item is `{ "id", "transaction_date", "transaction_time", "expense_total", "currency" }`. Items are ordered by `transaction_date`, then by creation time. A Refund returns `[]`.
3. `version` — the current correction version number, from 1.

Line validation:
1. `quantity` defaults to 1. `unit_price` and `line_total` are required.
2. On a purchase, every Line has a `line_type` and a `category`.
3. `tags` holds at most ten values.
4. A purchase has at least one Line. An Expense without Lines returns "invalid input". A simple purchase, such as a lunch, has one Line for that lunch.

## 6.1 expense_create

**Signature:** `expense_create(p_input jsonb)`

**Purpose:** Save one purchase Expense with its Lines.

**Required p_input fields:** `transaction_date`, `payment_method_subject_id`, `expense_total`, `currency`, `lines` (at least one item).

**Supported p_input fields:** `transaction_date`, `transaction_time`, `merchant_name`, `branch`, `merchant_subject_id`, `seller_name`, `payment_method_subject_id`, `expense_total`, `currency`, `remarks`, `metadata`, `lines`.

**Supported `lines` item fields:** `line_type`, `item_description`, `source_item_text`, `quantity`, `unit_price`, `line_total`, `category`, `tags`, `item_subject_id`, `metadata`.

**Defaults:** `expense_type = "purchase"`, `remarks = []`, `metadata = {}`, Line `quantity = 1`, Line `tags = []`.

**Behavior:**
1. `expense_type` and `refund_of` are not accepted. A Refund uses 6.8.
2. `expense_total` is zero or positive. For a zero total, the Agent supplies the Cash Payment Method Subject.
3. Supplied Subject IDs are active Subjects ([shared.md 1.5 item 14](shared.md#15-common-interface-semantics)). A missing Merchant or Item Subject does not prevent the save.
4. `line_no` follows the order of `lines`.
5. A purchase on credit, such as PayLater or a credit card, is one Expense on its original Transaction Date. Its Payment Method Subject shows the credit.

**Returns:** The complete Expense Record with `lines`, `discrepancies`, `refunds` and `version`.

## 6.2 expense_create_batch

**Signature:** `expense_create_batch(p_input jsonb)`

**Purpose:** Save any number of user-approved purchase Expenses together, such as several reviewed Receipts.

**Required p_input fields:** `expenses` (array with at least one item).

**Supported p_input fields:** `expenses`. Each item accepts the 6.1 input.

**Defaults:** The 6.1 defaults apply to each item.

**Behavior:**
1. Each item follows 6.1.
2. The batch has no size limit.
3. One invalid item rejects the whole batch. The error text is the item's own error text followed by ` at item <n>`.
4. `<n>` is the 0-based index of the item in `expenses`. Example: "invalid input at item 2".

**Returns:** `{ "results": [complete Expense Records in input order], "returned_count": number }`.

## 6.3 expense_read

**Signature:** `expense_read(p_id uuid)`

**Purpose:** Read one Expense by exact ID.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics). A Refund also returns `"original": <compact original Expense>` with `id`, `transaction_date`, `merchant_name` and `expense_total`.

**Returns:** The complete Expense Record with `lines`, `discrepancies`, `refunds`, `version` and `"links": [...]` ([shared.md 4.5.3](shared.md#453-record_links_read)).

## 6.4 expense_search

**Signature:** `expense_search(p_filter jsonb)`

**Purpose:** Find Expenses, such as the original Expense of a Refund.

**Supported p_filter fields:** `keyword`, `from_date`, `to_date`, `expense_type`, `payment_method_subject_id`, `merchant_subject_id`, `item_subject_id`, `category`, `tag`, `refund_of`, `currency`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches `merchant_name`, `branch`, `seller_name`, Line `item_description`, Line `source_item_text` and Remark text.
2. `from_date` and `to_date` filter `transaction_date` inclusively.
3. `category`, `tag` and `item_subject_id` match when at least one Line matches.
4. Results are ordered by `transaction_date` descending, then `transaction_time` descending. An unknown `transaction_time` comes after the known times of the same date.

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Expense Records.

## 6.5 expense_update

**Signature:** `expense_update(p_id uuid, p_changes jsonb)`

**Purpose:** Correct one Expense and keep its correction history.

**Supported p_changes fields on a purchase:** `transaction_date`, `transaction_time`, `merchant_name`, `branch`, `merchant_subject_id`, `seller_name`, `payment_method_subject_id`, `expense_total`, `currency`, `metadata`, `lines`, `correction_reason`.

**Supported p_changes fields on a Refund:** `transaction_date`, `transaction_time`, `refund_amount`, `item_description`, `item_subject_id`, `line_type`, `metadata`, `correction_reason`.

**Required p_changes fields:** `correction_reason`.

**Defaults:** None.

**Behavior:**
1. Before the change, the function saves a snapshot of the current Expense and its Lines as one history version.
2. The function then changes the Expense in place. Its ID stays the same, so every link stays valid.
3. A supplied `lines` replaces the whole Line set with new Lines and follows the Line validation. A purchase correction without `lines` leaves every Line unchanged, including its `updated_at`.
4. `correction_reason` is required and non-empty. It is stored as the `correction_reason` of the version that the correction produces (6.6). It is not a stored Expense field.
5. `expense_type`, `refund_of` and `remarks` are not change fields. Remarks use [shared.md 4.6](shared.md#46-remarks).
6. A Refund change keeps the 6.8 shape. The Payment Method and Currency stay those of the original Expense. The Refund Line changes only when the correction supplies `refund_amount`, `item_description`, `item_subject_id` or `line_type`.
7. On a purchase, `expense_total` stays zero or positive (6.1 item 2).
8. The Refund limits hold on the state after the correction. On a Refund, the function checks the purchase that `refund_of` names:
   - The `refund_amount` after the correction plus the amounts of the other active Refunds of that purchase is at most the purchase `expense_total`.
   - The `transaction_date` after the correction is on or after the purchase `transaction_date`. The same day is allowed.
9. On a purchase, the function checks its active Refunds:
   - The `expense_total` after the correction is at least the sum of the amounts of its active Refunds. The check also applies to a correction that supplies `lines`.
   - The `transaction_date` after the correction is on or before the `transaction_date` of every active Refund.
10. A violation of item 8 or 9 returns "invalid input". The function rejects the whole correction and saves no history version.

**Returns:** The complete Expense Record after the correction.

## 6.6 expense_history

**Signature:** `expense_history(p_id uuid)`

**Purpose:** Return the correction history of one Expense.

**Defaults:** None.

**Behavior:** Versions are ordered oldest to newest. The last item is the current Expense. Each version after the first carries the `correction_reason` and `corrected_at` of the correction or deletion that produced it.

**Returns:** `{ "id": uuid, "history": [ { "version": number, "snapshot": <Expense with lines>, "correction_reason": text or null, "corrected_at": timestamp or null } ] }`. The first version has `corrected_at = null`.

## 6.7 expense_delete

**Signature:** `expense_delete(p_id uuid, p_text text)`

**Purpose:** Delete one Expense.

**Defaults:** None. `p_text` is the required deletion reason.

**Behavior:**
1. An empty `p_text` returns "invalid input". Before the deletion, the function saves a snapshot of the current Expense and its Lines as one history version. `p_text` is stored as the `correction_reason` of the version that the deletion produces (6.6).
2. It then follows [shared.md 1.5 items 8 and 9](shared.md#15-common-interface-semantics). Deleting an already deleted Expense saves no history version. It returns the existing `deleted_at`.
3. Deleting a purchase also soft-deletes each of its active Refunds in the same transaction. Each Refund gets the `deleted_at` of the purchase.
4. Each such Refund gets its own history snapshot. `p_text` is the `correction_reason` of that version too.
5. Deleting a Refund deletes only that Refund.
6. Before deleting a purchase with active Refunds, the Agent asks the user about each Refund in its `refunds` field:
   - The Agent asks whether the Refund money was really received.
   - The Agent states that deleting the purchase also deletes the Refund.
   - The Agent calls the function after the user confirms.

**Returns:** `{ "id": uuid, "deleted_at": timestamp, "deleted_refund_ids": [uuid] }`.
- `deleted_refund_ids` lists the Refunds this call deleted, in the order of the `refunds` field. It is `[]` when the call deleted no Refund.

## 6.8 expense_refund_create

**Signature:** `expense_refund_create(p_input jsonb)`

**Purpose:** Record money that came back from a Refund, Return or Reversal as a new Refund Expense linked to the original.

**Required p_input fields:** `refund_of`, `refund_amount`, `transaction_date`, `line_type`.

**Supported p_input fields:** `refund_of`, `refund_amount`, `transaction_date`, `transaction_time`, `item_description`, `item_subject_id`, `line_type`, `remarks`, `metadata`.

**Defaults:** `item_description = null`, `item_subject_id = null`, `remarks = []`, `metadata = {}`.

**Behavior:**
1. The original is an active purchase Expense. An original that is a Refund returns "invalid relationship". A deleted original returns "record deleted".
2. `refund_amount` is positive. It is the actual refunded amount, so a partial Refund uses its partial amount.
3. `refund_amount` plus the amounts of the active Refunds already recorded for that original is at most the original `expense_total`. A larger sum returns "invalid input".
4. `transaction_date` is on or after the original's `transaction_date`. An earlier date returns "invalid input".
5. The function creates a new Expense with:
   - `expense_type = "refund"` and `refund_of` = the original ID;
   - `payment_method_subject_id`, `currency`, `merchant_name`, `branch`, `merchant_subject_id` and `seller_name` copied from the original;
   - `expense_total = −refund_amount`.
6. The Refund has exactly one Line: `quantity = 1`, `unit_price = −refund_amount`, `line_total = −refund_amount`, `category = null`, `tags = []`.
7. The Line holds `item_description` when the credit note names the item. Otherwise it holds no description, and the amount alone states the Refund.
8. The Line's `line_type` is the supplied `item`, `charge` or `adjustment`. The Agent supplies the Line Type of the refunded original line:
   - `item` for goods.
   - `charge` for a fee, such as delivery.
   - `adjustment` when the refunded item is unknown.
9. The original Expense stays unchanged. Several Refunds may refer to one original.

**Returns:** The complete Refund Expense Record with `lines` and `original`.

## 6.9 expense_spending_report

**Signature:** `expense_spending_report(p_filter jsonb)`

**Purpose:** Return the spending report for a period, in a fixed order of five parts.

**Required p_filter fields:** `from_date`, `to_date`.

**Supported p_filter fields:** `from_date`, `to_date`, `currency`.

**Defaults:** `currency` omitted means every currency, each reported separately.

**Behavior:**
1. The report uses active Expenses whose `transaction_date` is in the period.
2. A purchase counts in the period of its `transaction_date`. A Refund counts as its negative total in the period the money came back.
3. Part 1, `total_spent`: the sum of `expense_total` over purchases and Refunds.
4. Part 2, `by_payment_method`: the same sum per `payment_method_subject_id`, with the Subject name. Ordered by total descending.
5. Part 3, `by_category`: the sum of `line_total` per `category` over purchase Lines. Refund Lines and Adjustment Lines are excluded. Ordered by total descending.
6. Part 4, `by_tag`: the sum of `line_total` per Tag over purchase Lines. A Line with several Tags counts under each Tag. Refund Lines and Adjustment Lines are excluded. Ordered by total descending.
7. Part 5, `adjustments`: the signed sum of purchase Lines with `line_type = "adjustment"`, and that sum per Merchant. Ordered with the most negative total first, so the first entry is the source that gave the most. Parts 3 and 4 leave out Adjustment Lines, so their totals may not add up to Part 1, `total_spent`. An Adjustment Line still stores its Category.
8. The report also returns two Refund lists for the Agent's explanation:
   - `refunds_in_period`: each Refund in the period with its original's `transaction_date` and total.
   - `later_refunds`: each active Refund after `to_date` whose original is in the period.
9. A repayment between Payment Methods is not an Expense and never appears in the report.

**Returns:**
```
{
  "from_date": date,
  "to_date": date,
  "currencies": [
    {
      "currency": text,
      "parts": [
        { "part": 1, "name": "total_spent", "total": numeric, "expense_count": number },
        { "part": 2, "name": "by_payment_method", "items": [ { "payment_method_subject_id", "payment_method_name", "total" } ] },
        { "part": 3, "name": "by_category", "items": [ { "category", "total" } ] },
        { "part": 4, "name": "by_tag", "items": [ { "tag", "total" } ] },
        { "part": 5, "name": "adjustments", "total": numeric, "items": [ { "merchant_name", "merchant_subject_id", "total" } ] }
      ],
      "refunds_in_period": [ { "id", "refund_of", "transaction_date", "expense_total", "original_transaction_date", "original_total" } ],
      "later_refunds": [ { "id", "refund_of", "transaction_date", "expense_total", "original_transaction_date" } ]
    }
  ]
}
```
`parts` is an array so the five parts keep their order.

## 6.10 expense_category_list

**Signature:** `expense_category_list()`

**Purpose:** Return the 17 adopted Categories.

**Defaults:** None.

**Behavior:** The list is fixed: food, drink, transport, clothing, beauty, electronics, household, entertainment, medical, education, travel, gift, fees, rental, loans, discount, other. Expense Tags have no fixed list. The `expense_tags` Notebook ([notebook.md 3.1](notebook.md#31-notebook_read)) holds their vocabulary.

**Returns:** `{ "categories": [17 text values in the order above] }`.
