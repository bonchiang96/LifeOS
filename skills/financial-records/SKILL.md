---
name: financial-records
description: Runs the LifeOS Financial Records flows. Records Expenses from conversation or Receipts, classifies Expense Lines, records Refunds, corrects and deletes Expenses, and presents spending reports. Use when the user reports a purchase, uploads a Receipt or Invoice, reports money that came back, or asks how much was spent.
compatibility: Requires the LifeOS Supabase functions in the schema lifeos and the LifeOS Config file in Google Drive. Load the lifeos entry Skill first.
---

# Financial Records

## 1. Purpose and when to use

Financial Records record Expenses only. Each Expense is one spending transaction. A Refund Expense records money that came back.

Use this Skill after the [lifeos](../lifeos/SKILL.md) entry Skill routes a Financial Records request.

The entry Skill holds Subject Discovery, Record links, Remarks, Timeline, Memory and Notebook. This Skill names them where a flow uses them.

## 2. Contract files to read

1. [financial-records.md](../../contract/financial-records.md): Expense, Refund, correction and spending report functions.
2. [shared.md](../../contract/shared.md): common rules, Record links, Remarks, Subject and Timeline.
3. [personal-records.md](../../contract/personal-records.md): only for the repayment and income flows (Sections 8 and 14), which record Events and Observations.

## 3. Rules that apply to every flow

1. Each Expense keeps Transaction Date, Merchant, Payment Method, Expense Total, Currency and relevant Metadata.
2. Always supply the Currency. Read the default from the `defaults` Notebook with `notebook_read`. It holds MYR.
3. Each Expense uses one Payment Method Subject. Identify it under the entry Skill Section 6.
4. An Expense with zero payable Total uses Cash as its Payment Method.
5. Normalise familiar Payment Methods consistently. Never invent a missing value.
6. Every Expense has at least one Expense Line. A simple purchase, such as a lunch, has one Line.
7. Each Line has one Line Type: Item for goods and services, Charge for fees, Adjustment for receipt-level value changes.
8. Each Line has a Unit Price and a Line Total. Quantity is 1 when unspecified.
9. Charges have positive Line Totals. Discounts and subsidies have negative totals. Rounding keeps its signed effect.
10. An item-specific discount reduces that item's verified final price.
11. A bill-wide discount, voucher, subsidy or rounding is a separate Adjustment Line.
12. Verified Receipt or user-confirmed amounts are authoritative. Keep their confirmed precision.
13. The sum of Lines and each Quantity × Unit Price are comparison checks only.
    - During review, run both checks yourself and show each discrepancy to the user.
    - After a save, the `discrepancies` field of the return repeats these checks.
    - Never replace a confirmed value.
14. A missing Merchant or Item Subject does not prevent recording.
15. Every Expense correction and deletion carries a reason.

## 4. Record an Expense from conversation

Purpose: save an ordinary completed purchase from reliable conversational information.

Input:

1. Transaction Date, and the time when known.
2. Merchant name and known Branch.
3. Payment Method.
4. Expense Total and Currency.
5. The items or services, with their prices.

Steps:

1. Ask only for required unknown information, such as the Payment Method.
2. Identify the Payment Method Subject. Identify a Merchant Subject when that identity is available.
3. Build the Lines. Classify each Item under Section 6.
4. Call `expense_create`. Save it without a redundant confirmation.
5. Link related Records and Subjects under the entry Skill Section 10.

Example: "I had dinner with Nicholas today and paid RM80" gives an RM80 Expense and a dinner Event. Both link to each other and to Nicholas.

Outcome: one purchase Expense with its Lines.

## 5. Record Expenses from Receipts

Purpose: turn uploaded Receipts or Invoices into reviewed Expenses.

Input: one or more uploaded Receipts or Invoices.

Steps:

1. Parse each Receipt:
   - Merchant or Platform, Date and Total.
   - Item lines, discounts and charges.
   - Payment Method and available transaction identifiers.
2. For an e-commerce Receipt, the Platform may be the Merchant. Keep the Seller separately.
3. For a physical purchase, use the actual receipt merchant.
4. Keep fuel context in metadata when provided: fuel type, vehicle plate, station and odometer.
5. Keep each Line's Receipt wording as Source Item Text.
6. Present the parsed Receipt for review:
   - Merchant, Date, Total and the actual Payment Method.
   - The interpreted item-level details.
   - Each discrepancy from your own checks of the Line sum and each Quantity × Unit Price.
7. Correct the details the user requests. Present the review again until the user confirms.
8. Obtain confirmation of the Receipt and of each Item's meaning and price.
9. Store the confirmed item identity as Item Description.
10. Classify each confirmed Item under Section 6.
11. Review several Receipts one after another, each on its own.
12. Save one approved Receipt with `expense_create`, or several with `expense_create_batch`. A batch has no size limit.

Choices and approvals:

1. The user confirms each Receipt before recording.
2. The user confirms each Item's meaning and price.

Outcome: one Expense per approved Receipt. The uploaded file is not kept. The Expense, its Lines and their Source Item Text remain.

## 6. Classify Expense Lines

Purpose: give each confirmed Item a Category and Tags.

Input: Expense Lines whose Item identity the user confirmed.

Steps:

1. Read the 17 Categories with `expense_category_list`.
2. Give each Line one Category. A Refund Line has no Category (Section 9).
3. Read the Tag vocabulary with `notebook_read` and the key `expense_tags`.
4. Give each Line zero to ten independent English Tags.
5. Reuse an existing Tag, or add a suitable new Tag under the entry Skill Section 16.
6. Write a new Tag in lowercase hyphenated English words, unless an existing convention applies.
7. Keep distinctive identifiers, such as vehicle plate numbers.
8. Link a Line to its Item Subject when the user tracks that kind of thing, such as vitamins.

Choices and approvals: classify after the user confirms the Item identity. Classification itself needs no approval.

Outcome: each purchase Line has one Category and its Tags.

## 7. Record a credit purchase

Purpose: record a purchase on credit, including PayLater and a credit card.

Input: the purchase and its credit Payment Method.

Steps:

1. Record it under Section 4 or 5 on its original Transaction Date.
2. Use the credit Payment Method Subject. LifeOS has no separate PayLater marker.

Outcome: one ordinary Expense.

## 8. Record a repayment or debt transfer

Purpose: record a later repayment between Payment Methods, such as paying a PayLater balance by credit card.

Input: the repayment, its date and both Payment Methods.

Steps:

1. Identify both Payment Method Subjects under the entry Skill Section 6.
2. Record an Event with `event_create`. It is not an Expense.
3. Link the Event to both Payment Method Subjects with `record_link_create`.

Outcome: one Event linked to both Payment Methods. The original Expense already holds the spending.

## 9. Record a Refund, Return or Reversal

Purpose: record money that came back.

Return concerns goods sent back. Refund concerns money returned. Reversal concerns cancellation of an original transaction. All three follow this flow.

Input:

1. The original purchase.
2. The actual refunded amount.
3. The date the money came back.
4. The refunded item, when the credit note names it.

Steps:

1. Identify the original Expense with `expense_search`. Ask the user when several purchases fit.
2. Keep the Refund within the limits:
   - The active Refunds of one purchase never exceed the purchase amount.
   - A Refund is never dated before the purchase. The same day is allowed.
3. Choose the Line Type of the refunded original line:
   - `item` for goods.
   - `charge` for a fee, such as delivery.
   - `adjustment` when the refunded item is unknown.
4. Write the Item Description when the credit note names the item, such as "refund for the shoes".
5. Otherwise state the refund amount only.
6. Call `expense_refund_create` with the original, the amount, the date and the Line Type.

A partial refund follows the same flow with its actual amount.

Choices: examine item detail only when the user asks which item was refunded.

Outcome: a new Refund Expense linked to the original. It keeps the original Payment Method. Its one Line holds the negative amount and no Category. The original Expense stays unchanged.

## 10. Correct an Expense

Purpose: fix a wrong detail of a purchase or a Refund and keep the correction history.

Input: the Expense, the corrected details and the reason.

Steps:

1. Find the Expense with `expense_search` or `expense_read`.
2. Take the correction reason from the user's statement. Ask the user when it is unknown.
3. Keep the Refund limits of Section 9 from both sides:
   - A purchase total stays at least the sum of its active Refunds.
   - A purchase date stays on or before every active Refund date.
4. Call `expense_update` with the changes and the correction reason.
5. Show the correction history with `expense_history` when the user asks.

A Remark on an Expense is no correction. It follows the entry Skill Section 11.

Outcome: the Expense holds the corrected details. Its earlier version and the reason stay in its history.

## 11. Delete an Expense

Purpose: remove a purchase or a Refund that the user wants deleted.

Input: the Expense and the deletion reason.

Steps:

1. Find the Expense with `expense_search` or `expense_read`. Ask the user when it is unclear which one is meant.
2. Take the deletion reason from the user's statement. Ask the user when it is unknown.
3. For a Refund, call `expense_delete` with the reason. Only that Refund is deleted.
4. For a purchase without active Refunds, call `expense_delete` with the reason.
5. For a purchase with active Refunds, follow Section 12.

Outcome: the Expense is deleted with its reason in its history.

## 12. Delete a purchase that has Refunds

Purpose: decide the deletion of a purchase that has one or more active Refunds.

Input: the purchase and its active Refunds from the `refunds` field.

Steps:

1. Ask about each Refund whether its money was really received.
2. State that deleting the purchase also deletes all its Refunds.
3. When no Refund money was received, delete the purchase with `expense_delete` after the user confirms. All its Refunds go with it.
4. When at least one Refund's money was received, the purchase really happened. Ask the user why the purchase should be deleted.
5. When a purchase detail is wrong, such as the amount, date or merchant, correct the purchase:
   1. Keep each Refund whose money was received.
   2. Delete each Refund without received money with `expense_delete`. Give the reason that its money was never received.
   3. Correct the purchase under Section 10. The kept Refunds stay within its limits.
6. When the user still wants deletion, delete the purchase with `expense_delete` after the user confirms. All its Refunds go with it.

A Refund without received money never happened. Keeping it would make totals wrong.

Choices and approvals:

1. The user answers about each Refund whether its money was received.
2. When some Refund money was received, the user chooses a correction or a deletion.
3. The user confirms the deletion of the purchase.

Outcome: one of two results:

1. A corrected purchase that keeps each received Refund. Each Refund without received money is deleted with its reason.
2. A deleted purchase with all its Refunds deleted too.

## 13. Present a spending report

Purpose: show how much was spent over a period.

Input: the period, and optionally one currency.

Steps:

1. Call `expense_spending_report` with the period.
2. Present the parts in this order:
   1. The total spent, from the total paid amount.
   2. A breakdown by Payment Method, from the total paid amount.
   3. A breakdown by Category, from Expense Line amounts.
   4. A breakdown by Tag, from Expense Line amounts. Tags may overlap.
   5. Optionally, the vouchers, discounts and other Adjustments, with the source that gave the most.
3. Report each currency separately, without conversion.
4. Explain that the Category and Tag breakdowns may not add up to the total paid. Adjustments stand on their own.
5. A refund reduces the total and the Payment Method breakdown. The Category and Tag breakdowns ignore refunds.
6. Explain refunds with `refunds_in_period` and `later_refunds`:
   - A purchase counts in its own month. A refund counts as a negative amount in the month the money came back.
   - Within one month, give the net amount and explain how it arose.
   - For an earlier month, give that month's spending and mention the later refund.

A repayment between Payment Methods is no Expense and never appears in the report.

Outcome: one spending report in the fixed order.

## 14. Record money coming in

Purpose: record income without Financial Records.

Input: money the user received.

Steps:

1. When a tracked bank-account Subject exists, record an Observation of it under the [personal-records](../personal-records/SKILL.md) Skill.
2. Otherwise record an Event, such as "I received RM X", under the personal-records Skill.

Outcome: the money is recorded as an Observation or an Event. Financial Records hold no income.
