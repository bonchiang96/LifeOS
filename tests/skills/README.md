# LifeOS Skill Flow Tests

## Purpose

These tests prove that a runtime Agent that follows a Skill reaches the outcome of each business flow (M-0022 D9 item 5). Each test takes one flow of one Skill, runs its database steps in the Skill's order through the Contract functions, and then checks the outcome that the Skill and the Knowledge Base state. The outcome covers stored values, returns, links and Status changes.

User choices and approvals are Agent steps. Where a Skill names branches, such as the M-0022 D5 Refund deletion, each branch has its own database result to check.

The tests call only functions of the schema `lifeos`. They read or write no table directly.

## Files

| File | Skill | Tests |
|---|---|---|
| `lifeos.sql` | [lifeos](../../skills/lifeos/SKILL.md) | 19 |
| `personal-records.sql` | [personal-records](../../skills/personal-records/SKILL.md) | 16 |
| `financial-records.sql` | [financial-records](../../skills/financial-records/SKILL.md) | 16 |
| `divination-reflection.sql` | [divination-reflection](../../skills/divination-reflection/SKILL.md) | 14 |
| `communication-assistant.sql` | [communication-assistant](../../skills/communication-assistant/SKILL.md) | 16 |

Total: 81 tests in 5 files.

## How each file works

Each file works like the files in `tests/` ([tests/README.md](../README.md)):

1. One transaction: `begin;`, the tests, a final `select` of every result, then `rollback;`.
2. Each test is a plpgsql `DO` block. A failed check raises an exception. The block records `FAIL` with the cause, and the next test runs. A passing test records `PASS`.
3. The helpers live in `pg_temp` and disappear with the session.
4. Fixture text starts with `SKT_`, and business dates lie in 2032. Each test that reads a period or a report uses its own month or week in its file.
5. Some flows work only on today's date: the overdue check (yesterday and today), the Note date, the Message `finalized_at` and `recorded_earlier`. These tests use today and check only their own Record IDs.
6. When the project has no user Subject, the helper `pg_temp.user_subject()` creates one inside the transaction, as `subject_create` with `is_user` true. In `lifeos.sql`, test 2 runs before every call of the helper: it starts without a user Subject, creates it, and then finds it. Test 2 needs a project without an active user Subject, as on the dev project.
7. A "nothing saved" outcome is checked on stored values through a Contract read or search, such as the Message History count of a Profile or the Storylines of a Story Person, next to Records that the test did save.

Run one file at a time, as in `tests/README.md`. The final result set has one row per test with `test`, `status` and `detail`.

## Coverage

One row per business flow of every Skill. The flow lists come from the Skill authors (J-0023 Job Record 4.12). The rows for the M-0023 Decisions D3 to D13 were added in J-0025.

| Skill | Skill section | KB section | Test |
|---|---|---|---|
| lifeos | 4 Connect to LifeOS | 3.1 | `connect_named_parameter_calls_return_one_jsonb` (steps 8 and 9; reading LifeOS Config from Google Drive, steps 1 to 6, is an Agent step) |
| lifeos | 4 Steps for the user Subject (M-0023 D3) | 6.8.2 | `user_subject_created_when_missing_then_reused_at_start` (missing: created with `is_user` true and no approval; exists: found and reused; asking the name is an Agent step) |
| lifeos | 5 Route the request | 3.1, 4.3, 10.4 | `route_reads_memory_then_runs_each_module_and_links` |
| lifeos | 6 Subject Discovery | 6.8, 6.8.1, 5.2 | `subject_discovery_candidate_confirmed_then_linked` (step 3 reads `subject_types` and `subject_tags` on first use, as notebook.md 3.1 returns them), `subject_discovery_no_match_creates_only_after_user_decides`, `subject_discovery_guidance_from_subject_types_and_subject_tags` (M-0023 D4: the guidance is the content of both Notebooks; its category and Tag narrow two same-name candidates) |
| lifeos | 7 Subject maintenance | 6.8.2 | `subject_maintenance_alias_correction_and_tags` |
| lifeos | 8 Duplicate Subject merge | 6.8.2, 9.1 | `subject_merge_after_approval_combines_identity_and_moves_references`, `subject_merge_two_person_profiles_profile_merge_then_subject_merge` (M-0023 D5: step 4 hands over to communication-assistant Section 5, `communication_profile_merge` runs before `subject_merge`; the case without a Rule conflict) |
| lifeos | 9 Subject deletion | 6.9, 9.1 | `subject_delete_without_profile_links_kept_and_ignored`, `subject_delete_with_profile_after_profile_outcome_both_branches` |
| lifeos | 10 Record links | 6.7 | `record_links_dinner_example_each_item_once_with_via_order` |
| lifeos | 11 Remarks | 6.9 | `remarks_add_change_remove_and_structured_update_for_time` |
| lifeos | 12 Timeline | 10.1, 10.2 | `timeline_period_by_occurrence_and_by_record_date` |
| lifeos | 13 Timeline presentation | 10.1, 10.3 | `timeline_data_supports_presentation_steps` (the data each presentation step uses, including step 11, a Reading on its Reading Date with a later Analysis under it, and step 12, a Message on its Message History date, which uses today because `finalized_at` is the current time; the wording, including that the date does not show delivery, is an Agent step) |
| lifeos | 14 Subject questions | 10.4, 10.5 | `subject_questions_retrieve_across_modules_by_priority` |
| lifeos | 15 LifeOS Memory | 4.1, 4.2, 4.3 | `memory_retrieve_learn_improve_consolidate_and_correct` |
| lifeos | 16 Notebook | 5.1, 5.2 | `notebook_read_reuse_maintain_and_new_key`, `notebook_language_modes_and_platforms_reuse_or_add_value` (M-0023 D12: step 4, reuse an existing value, add one only when none fits) |
| personal-records | 4 Record a Schedule | 6.2 | `schedule_recorded_after_duplicate_search_starts_planned` |
| personal-records | 5 Record a repeating series | 6.2 | `schedule_series_finite_with_one_series_id` |
| personal-records | 6 Add a Schedule to an existing series | 6.2 | `schedule_added_to_existing_series_shares_series_id` |
| personal-records | 7 Change one Schedule | 6.2 | `schedule_change_one_reschedule_cancel_missed_and_correction` |
| personal-records | 8 Change a series from now on | 6.2 | `schedule_series_change_from_now_on_inclusive_date` |
| personal-records | 9 Stop a series | 6.2 | `schedule_series_stop_cancels_later_planned_only` |
| personal-records | 10 Record an Event | 6.3, 6.4 | `event_recorded_with_confirmed_schedule_match_or_without`, `event_confirmed_for_cancelled_or_missed_schedule_sets_occurred` |
| personal-records | 11 Link an existing Event to a Schedule | 6.4, 6.9 | `event_linked_to_schedule_after_its_schedule_was_deleted` |
| personal-records | 12 Overdue check | 6.2, 6.4 | `overdue_check_answers_missed_happened_and_unanswered` |
| personal-records | 13 Record an Observation | 6.5 | `observation_with_event_of_same_statement_and_without_event` |
| personal-records | 14 Correct an Observation or record a change | 6.5 | `observation_correction_keeps_time_and_later_change_is_new` |
| personal-records | 15 Record a Note | 6.6 | `note_type_from_notebook_dated_on_record_day_and_linked` |
| personal-records | 16 Record a feeling about an earlier day | 6.6, 6.7 | `feeling_about_earlier_day_event_and_note_linked_both_branches` |
| personal-records | 17 Amend a Record | 6.9 | `amend_record_by_remark_or_structured_update_without_duplicate` |
| personal-records | 18 Delete a Record | 6.9 | `delete_records_event_delete_returns_schedule_to_planned` |
| financial-records | 4 Record an Expense from conversation | 7.1, 7.2, 6.7 | `expense_from_conversation_saved_with_default_currency_and_links` |
| financial-records | 5 Record Expenses from Receipts | 7.1, 7.2 | `expenses_from_reviewed_receipts_saved_in_one_batch` (the Line-sum and Quantity × Unit Price checks during review are an Agent step; the test checks that `discrepancies` repeats both after the save) |
| financial-records | 6 Classify Expense Lines | 7.3 | `expense_lines_classified_with_category_tags_and_item_subject` |
| financial-records | 7 Record a credit purchase | 7.4 | `credit_purchase_is_one_expense_with_its_credit_payment_method` |
| financial-records | 8 Record a repayment or debt transfer | 7.4 | `repayment_is_event_linked_to_both_payment_methods_not_an_expense` |
| financial-records | 9 Record a Refund, Return or Reversal | 7.5 | `refund_recorded_as_linked_refund_expense_within_limits` |
| financial-records | 10 Correct an Expense | 7.5 | `expense_correction_with_reason_keeps_history_and_refund_limits` |
| financial-records | 11 Delete an Expense | 7.5 | `expense_delete_refund_only_or_purchase_without_refunds_with_reason` |
| financial-records | 12 Delete a purchase that has Refunds (M-0022 D5, M-0023 D6) | 7.5 | `purchase_with_refunds_money_not_received_deleted_with_refunds`, `purchase_with_received_refund_wrong_detail_corrected_keeps_refund`, `purchase_with_received_refund_user_still_deletes_with_refunds`; with several Refunds, one test per branch: `purchase_several_refunds_none_received_deleted_with_all_refunds`, `purchase_several_refunds_wrong_detail_keeps_received_deletes_not_received` (step 5: the Refund without received money is deleted with its reason before the correction), `purchase_several_refunds_some_received_user_still_deletes_all` |
| financial-records | 13 Present a spending report | 7.5, 7.6 | `spending_report_fixed_order_per_currency_with_refund_explanation` |
| financial-records | 14 Record money coming in | 7.6, 6.5 | `money_coming_in_is_observation_or_event_not_expense` |
| divination-reflection | 4 Story intake and Story Persons | 8.4, 8.8 | `story_intake_finds_story_persons_storylines_and_earlier_readings` |
| divination-reflection | 4 steps 7 to 9, multi-person Storyline retrieval | 8.8 | `multi_person_storylines_shared_subgroup_and_individual` |
| divination-reflection | 5 Storyline identity and timing | 8.8.1 | `storyline_timing_known_dates_relative_order_and_unknown` |
| divination-reflection | 6 Storybook save at the Story Context Cutoff | 8.8, 8.8.2, 6.7 | `storybook_saved_on_approval` (decline: no call, Agent step), `end_signal_cutoff_saved_on_approval_silent_stop_saves_nothing` (M-0023 D8: an end signal leads to the save; a stop without a signal leaves the stored Storybook unchanged) |
| divination-reflection | 7 Question preparation and method selection | 8.4, 8.2 | Agent-only, no database step: question wording, the method choice, the I Ching interface link and the copyable blocks call no function. |
| divination-reflection | 8 Tarot Spread selection and template | 8.2 | Agent-only, no database step: the Spreads come from Section 15 of the Skill, and the template goes to the user. |
| divination-reflection | 9 Tarot interpretation | 8.5 | Agent-only, no database step: interpretation of the user's draw. The save follows Section 11. |
| divination-reflection | 10 I Ching interpretation | 8.6 | Agent-only, no database step: interpretation of the user's casting. The save follows Section 11. |
| divination-reflection | 10 steps 16 to 20 and 11 step 5, optional 梅花易数 saved with the Reading (M-0023 D7) | 8.6, 8.7 | `meihua_round_saved_as_second_separate_analysis_at_save_time` (the interpretation round is an Agent step; the save holds two separate Analyses of one Reading) |
| divination-reflection | 12 step 5, 梅花易数 round for a saved Reading (M-0023 D7) | 8.6, 8.7, 10.2 | `meihua_round_for_saved_reading_added_later_with_analysis_add` |
| divination-reflection | 11 Reading save | 8.7, 8.9 | `reading_saved_once_per_session_with_analyses_story_persons_and_links` (decline: no call, Agent step) |
| divination-reflection | 11 step 13, later additional or revised option | 8.4 | `later_option_added_as_new_reading_earlier_reading_unchanged` |
| divination-reflection | 12 steps 2 to 4, later outside Analysis | 8.7, 10.2 | `later_outside_analysis_added_with_source_under_reading_date` |
| divination-reflection | 12 steps 5 to 8, correction by delete and re-add | 8.7, 6.9 | `wrong_reading_or_analysis_deleted_and_added_again` |
| divination-reflection | 13 Past Reading retrieval | 8.7 | `past_reading_short_view_first_full_view_on_request` |
| divination-reflection | 14 steps 1 to 11, Reading follow-up Remarks | 8.9, 6.9 | `reading_remark_after_storyline_save_add_correct_and_remove` |
| divination-reflection | 14 step 12, change a saved Reading's Story Persons | 8.9 | `reading_story_persons_changed_after_approval_not_an_edit` |
| divination-reflection | 15 Canonical Tarot Spread Catalog | 8.2, 8.3 | Agent-only, no database step: reference data held in the Skill. The Contract has no Spread function. |
| communication-assistant | 4 steps 1 to 3, Profile selection | 9.1, 9.3 | `profile_selected_by_name_or_person_subject` |
| communication-assistant | 4 steps 4 to 12, Person Profile setup | 9.1, 6.8.1 | `person_profile_set_up_after_subject_decision_or_global_rules_without` |
| communication-assistant | 4 steps 13 to 18, Group and Audience Profiles and inheritance | 9.1, 9.2 | `group_and_audience_profiles_inherit_by_priority_and_removal`, `group_and_audience_profiles_set_up_changed_and_removed_without_approval` (M-0023 D9: no approval step) |
| communication-assistant | 5 steps 1 to 5, Profile belongs to another person | 9.1 | `profile_relinked_to_correct_person_keeps_rules_and_history` |
| communication-assistant | 5 steps 6 and 7, Profile deletion | 9.1 | `profile_deleted_subject_stays_rules_stop_history_stays` |
| communication-assistant | 5 steps 8 to 10, deleting a Person Subject that has a Profile | 9.1 | `person_subject_with_profile_deleted_after_profile_outcome` |
| communication-assistant | 5 Steps for two Person Profiles of one person (M-0023 D5) | 9.1, 6.8.2 | `two_person_profiles_merged_after_rule_conflict_with_aliases_and_memberships` (show, choose the Profile, resolve the Rule conflict with `communication_rule_delete`, keep aliases and the membership, `communication_profile_merge`, then `subject_merge`) |
| communication-assistant | 6 Rule scope and resolution | 9.2 | `rule_resolution_profile_inherited_global_and_language_mode` |
| communication-assistant | 6 steps 2 to 4 and 7 to 9, 8 step 10, 9 step 1: Language Mode and Platform values (M-0023 D12) | 5.1, 9.2 | `language_mode_and_platform_values_reused_from_notebooks` |
| communication-assistant | 7 Message drafting | 9.3 | `message_drafting_context_with_rules_examples_and_platform` |
| communication-assistant | 7 steps 13 to 15, final check with the Global scope Communication Rules (M-0023 D13) | 9.3 | `send_ready_message_unfinalized_at_conversation_end_saves_nothing` (reads only the Global scope Rules) |
| communication-assistant | 8 Message finalization and Rule consolidation | 9.3, 9.2 | `message_finalized_with_rule_changes_or_none` |
| communication-assistant | 8 step 3, send-ready message unfinalized at the conversation end (M-0023 D11) | 9.3 | `send_ready_message_unfinalized_at_conversation_end_saves_nothing` (the Message History count and the Rules of the Profile stay as before the draft) |
| communication-assistant | 9 Message History retrieval and deletion | 9.3, 6.9 | `message_history_search_read_and_delete` |
| communication-assistant | 10 Cross-module retrieval | 9.4, 10.4 | `cross_module_retrieval_follows_profile_person_subject` |
| communication-assistant | 11 Rule changes outside a message (M-0023 D10) | 9.2 | `rule_added_changed_and_removed_outside_a_message_without_confirmation` |

Summary: 73 flows. 68 flows have tests. 5 flows are Agent-only, all in divination-reflection.

## Skill steps that do not match the Contract

Both points that the first test version reported were fixed in the Skill retries (J-0023 4.14 and round 2): lifeos Section 6 step 3 now reads only the catalog Notebooks `subject_types` and `subject_tags`, and lifeos Section 8 checks and resolves the Person Profiles (steps 3 and 4) before `subject_merge` (step 6).

J-0025 (M-0023 D3 to D13): every Skill step of the new and changed flows runs through the Contract. No mismatch was found. `subject_merge_two_person_profiles_profile_merge_then_subject_merge` replaces `subject_merge_two_person_profiles_resolved_first`, which still deleted one Profile as the merge outcome from before M-0023 D5.
