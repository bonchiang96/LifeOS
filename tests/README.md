# LifeOS Database Tests

## Purpose

These tests prove that each LifeOS Knowledge Base flow works through the Contract functions on the dev project. Each file covers one Module of the Contract. Each test is one business flow, written as a plpgsql `DO` block.

The tests call only functions of the schema `lifeos`. Error tests compare the exact error text of the Contract, such as `invalid input` or `invalid relationship`.

## Files

| File | Module | Contract chapter | Tests |
|---|---|---|---|
| `02_memory.sql` | LifeOS Memory | 2 | 5 |
| `03_notebook.sql` | Notebook | 3 | 8 |
| `04_personal_records.sql` | Personal Records | 4 | 16 |
| `05_subject.sql` | Subject | 5 | 7 |
| `06_financial_records.sql` | Financial Records | 6 | 13 |
| `07_divination_reflection.sql` | Divination & Reflection | 7 | 12 |
| `08_communication_assistant.sql` | Communication Assistant | 8 | 12 |
| `09_timeline_shared_retrieval.sql` | Timeline and Shared Retrieval | 9 | 8 |

## How each file works

1. Each file is one transaction: `begin;`, the tests, a final `select` of the results, then `rollback;`. A run leaves nothing on the project.
2. A test raises an exception that names the failed assertion. The test block catches it, records `FAIL` with the cause and raises a NOTICE. The next test then runs.
3. A passing test records `PASS` and raises `NOTICE 'PASS <test name>'`.
4. The Supabase CLI returns only the last result set. The final `select` therefore returns every test with its status and detail. Read that table, not the NOTICE lines.
5. Helper functions live in `pg_temp` and disappear with the session.

## How to run

Run one file at a time from the home folder:

```
cd ~ && npx -y supabase@3.2.0 db query --remote=vhdqadpeoyztrdpjkgvw --yes -f "<path to repo>/tests/04_personal_records.sql" --output-format json
```

The result is a JSON object. Its `rows` array holds one row per test with `test`, `status` and `detail`. A file passes when every row has `status = PASS`.

## Direct table access

Some setups use a direct `update` or `delete` because the Contract has no function for them. Each change stays inside the transaction, so the rollback removes it.

1. `04_personal_records.sql`, test 13, moves `created_at` of one Note 10 days back. A transaction has one clock value, so this is the only way to tell the Note date from today.
2. `04_personal_records.sql`, test 15, moves `updated_at` of one Schedule 5 days back. This shows that a Remark leaves `updated_at` unchanged.
3. `07_divination_reflection.sql`, test 12, moves `updated_at` of one Reading 5 days back. This shows that a Reading Remark leaves `updated_at` unchanged.
4. `03_notebook.sql`, test 8, deletes the seeded `note_types` row, so the first read creates it with the five default Note Types.
5. `02_memory.sql` test 4 and `08_communication_assistant.sql` tests 10 and 11 spread `updated_at` and `finalized_at` to prove the newest-first ordering.

## Coverage

| Knowledge Base flow | Test | File |
|---|---|---|
| Memory save, with defaults | `memory_create_defaults_and_read` | `02_memory.sql` |
| Memory input validation | `memory_create_rejects_bad_input` | `02_memory.sql` |
| Memory search by keyword, categories and tags | `memory_search_keyword_categories_tags` | `02_memory.sql` |
| Memory search order, paging and deleted Memory | `memory_search_order_paging_and_deleted` | `02_memory.sql` |
| Memory update and delete | `memory_update_partial_and_delete` | `02_memory.sql` |
| Notebook initialise on read, empty catalog Notebooks | `notebook_initialise_on_read_catalog_names` | `03_notebook.sql` |
| The defaults Notebook holds `currency: MYR` | `notebook_defaults_holds_currency_myr` | `03_notebook.sql` |
| Notebook with a free key or a supplied name | `notebook_custom_key_and_name` | `03_notebook.sql` |
| Notebook key format | `notebook_key_format_rejected` | `03_notebook.sql` |
| Notebook update replaces content | `notebook_update_replaces_and_initialises` | `03_notebook.sql` |
| Notebook catalog list | `notebook_list_keyword_and_order` | `03_notebook.sql` |
| Seeded `note_types` Notebook holds five Note Types | `notebook_note_types_seed_holds_five_default_note_types` | `03_notebook.sql` |
| New `note_types` Notebook starts with five Note Types | `notebook_note_types_created_on_read_starts_with_five_default_note_types` | `03_notebook.sql` |
| Schedule create | `schedule_create_defaults_and_validation` | `04_personal_records.sql` |
| Schedule series, create and extend | `schedule_series_create_and_extend` | `04_personal_records.sql` |
| Schedule "this one" | `schedule_update_this_one_only` | `04_personal_records.sql` |
| Schedule "from now on", inclusive `from_date` | `schedule_update_series_from_date_inclusive` | `04_personal_records.sql` |
| Stop a series | `schedule_stop_series_from_date_inclusive` | `04_personal_records.sql` |
| Event actualises a Schedule, copied planned date and time | `event_actualises_schedule_copies_planned_date_and_time` | `04_personal_records.sql` |
| Link an existing Event to a Schedule | `event_link_schedule_existing_event` | `04_personal_records.sql` |
| Status lock while an Event is linked | `schedule_status_locked_while_event_linked` | `04_personal_records.sql` |
| Overdue check | `schedule_overdue_check` | `04_personal_records.sql` |
| Event delete returns the Schedule to Planned | `event_delete_returns_schedule_to_planned` | `04_personal_records.sql` |
| Observation linked to an Event | `observation_linked_to_event` | `04_personal_records.sql` |
| Observation correction keeps its time | `observation_update_keeps_observed_time` | `04_personal_records.sql` |
| Note date and updated_at after an edit, unchanged after a Remark | `note_date_after_edit_unchanged_after_remark` | `04_personal_records.sql` |
| Record links ignore deleted targets | `record_links_ignore_deleted_targets` | `04_personal_records.sql` |
| Remark on a Record, updated_at unchanged | `record_add_remark_rules` | `04_personal_records.sql` |
| Soft delete, read and search of deleted Records | `soft_delete_read_and_search_deleted` | `04_personal_records.sql` |
| Subject create and single user Subject | `subject_create_defaults_and_single_user` | `05_subject.sql` |
| Subject Discovery search | `subject_search_compact_and_exact_first` | `05_subject.sql` |
| Subject Alias and existence check | `subject_alias_and_check` | `05_subject.sql` |
| Subject merge with the supplied identity | `subject_merge_moves_references_and_applies_identity` | `05_subject.sql` |
| Merge of the user Subject and duplicate links | `subject_merge_user_flag_and_duplicate_links` | `05_subject.sql` |
| Merge rejections | `subject_merge_rejections` | `05_subject.sql` |
| Subject update, read and delete | `subject_update_read_and_delete` | `05_subject.sql` |
| Expense with Lines and Adjustments | `expense_create_with_lines_and_adjustments` | `06_financial_records.sql` |
| Discrepancies as comparison flags | `expense_create_discrepancies_are_flags_only` | `06_financial_records.sql` |
| Rejection of an Expense without Lines | `expense_without_lines_and_other_invalid_input_rejected` | `06_financial_records.sql` |
| Several approved Receipts in one batch | `expense_create_batch_all_or_nothing` | `06_financial_records.sql` |
| Refund Expense with a required `line_type` | `expense_refund_requires_line_type_and_keeps_shape` | `06_financial_records.sql` |
| Expense correction with a required reason and history | `expense_update_requires_reason_and_keeps_history` | `06_financial_records.sql` |
| Refund correction | `expense_refund_update_keeps_refund_shape` | `06_financial_records.sql` |
| Expense deletion with a required reason and history | `expense_delete_requires_reason_and_keeps_history` | `06_financial_records.sql` |
| Expense search | `expense_search_filters_and_order` | `06_financial_records.sql` |
| The 17 Categories | `expense_category_list_has_17_in_order` | `06_financial_records.sql` |
| Spending report order and per-currency totals | `expense_spending_report_order_and_per_currency_totals` | `06_financial_records.sql` |
| Adjustment Lines stay out of by_category and by_tag | `expense_spending_report_leaves_adjustment_lines_out_of_category_and_tag` | `06_financial_records.sql` |
| Credit purchase and repayment | `credit_purchase_is_one_expense_and_repayment_is_not_in_report` | `06_financial_records.sql` |
| Divination save with Readings and Analyses | `divination_save_readings_and_analyses` | `07_divination_reflection.sql` |
| Divination save validation | `divination_save_rejects_invalid_input` | `07_divination_reflection.sql` |
| Divination search, short view | `divination_search_short_view` | `07_divination_reflection.sql` |
| Divination search by Subject and Story Person | `divination_search_by_subject_and_story_person` | `07_divination_reflection.sql` |
| Divination Record full read | `divination_record_read_full_view` | `07_divination_reflection.sql` |
| Reading Remark | `reading_remark_add_and_update` | `07_divination_reflection.sql` |
| Reading Remark leaves updated_at unchanged | `reading_remark_add_and_update_leave_reading_updated_at_unchanged` | `07_divination_reflection.sql` |
| Later Reading, later Analysis, Story Person set | `reading_create_analysis_add_and_story_persons_set` | `07_divination_reflection.sql` |
| Divination and Reading delete | `divination_delete_cascades_reading_delete_keeps_combined` | `07_divination_reflection.sql` |
| Story Person | `story_person_create_search_read_delete` | `07_divination_reflection.sql` |
| Storyline search by Story Persons | `storyline_search_by_story_persons` | `07_divination_reflection.sql` |
| Storyline update, delete and links | `storyline_update_delete_and_links` | `07_divination_reflection.sql` |
| Communication Profiles | `profile_create_person_group_audience_rules` | `08_communication_assistant.sql` |
| Profile search, update and Person Subject link | `profile_search_update_and_person_link` | `08_communication_assistant.sql` |
| Audience inheritance | `membership_set_remove_and_rejections` | `08_communication_assistant.sql` |
| Rule create, update and delete | `rule_upsert_create_update_delete` | `08_communication_assistant.sql` |
| Rule resolution precedence | `communication_resolve_precedence` | `08_communication_assistant.sql` |
| Rule resolution by Language Mode | `communication_resolve_language_mode` | `08_communication_assistant.sql` |
| Raw Rule state | `rule_state_lists_scopes` | `08_communication_assistant.sql` |
| Message finalize with Rule changes | `message_finalize_saves_message_and_rule_changes` | `08_communication_assistant.sql` |
| Message finalize is atomic | `message_finalize_is_all_or_nothing` | `08_communication_assistant.sql` |
| Runtime context before drafting | `runtime_context_recent_messages_and_platform` | `08_communication_assistant.sql` |
| Message history | `message_history_search_read_delete` | `08_communication_assistant.sql` |
| Profile delete | `profile_delete_stops_rules_keeps_history` | `08_communication_assistant.sql` |
| Timeline, every Record Type | `timeline_includes_every_record_type_with_module` | `09_timeline_shared_retrieval.sql` |
| Timeline with Subjects on items | `timeline_items_carry_connected_subjects` | `09_timeline_shared_retrieval.sql` |
| Timeline without Storylines and deleted Records | `timeline_excludes_storylines_deleted_and_reference_data` | `09_timeline_shared_retrieval.sql` |
| Timeline order, date basis, recorded earlier | `timeline_order_date_basis_and_recorded_earlier` | `09_timeline_shared_retrieval.sql` |
| Timeline item contents | `timeline_item_contents_schedule_status_event_observations_expense_reading` | `09_timeline_shared_retrieval.sql` |
| Timeline period input | `timeline_requires_a_period` | `09_timeline_shared_retrieval.sql` |
| Subject questions across Modules | `subject_records_cross_module_retrieval` | `09_timeline_shared_retrieval.sql` |
| Subject records filters, order and paging | `subject_records_filters_order_paging_and_deleted` | `09_timeline_shared_retrieval.sql` |
