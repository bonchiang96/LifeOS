# LifeOS Database Contract: Shared

This file holds the configuration and common semantics for every Module. It also holds Record links, Remarks, Subject, and Timeline and Shared Retrieval, which several Modules use. The runtime Agent reads it together with the Contract file of the Module in use. 1.3 names the file of each Module.

Contents:

- [1. Configuration](#1-configuration)
- [4. Personal Records: shared parts](#4-personal-records-shared-parts)
  - [4.5 Record links](#45-record-links)
  - [4.6 Remarks](#46-remarks)
- [5. Subject](#5-subject)
- [9. Timeline and Shared Retrieval](#9-timeline-and-shared-retrieval)

Version: V2, Build Stage 1.

# 1. Configuration

## 1.1 Purpose

This Contract tells a LifeOS AI Agent how to read and write LifeOS data. The Agent reads it to choose which function to call, what to send and what comes back.

1. The functions in this Contract are the only way into LifeOS data. Call no other function. Read or write no table directly.
2. Every function stores and returns data only. The Agent does the thinking before the call: it understands the user, asks the user when the rules say so, chooses the Record Type and classifies. A Behavior item names an Agent step only when the function supports that step.
3. 1.8 lists which function fits each common user request.

## 1.2 Schema and identifiers

1. Every function lives in the schema `lifeos`.
2. The LifeOS runtime configuration supplies the Supabase project ID, and a publishable key where one is needed. The Contract names no project and no key.
3. Every Record ID is a `uuid`. Use the exact ID that a function returned. Never invent an ID.

## 1.3 Modules

| Chapter | Module or function area | Contract file |
|---|---|---|
| 2 | LifeOS Memory | [lifeos-memory.md](lifeos-memory.md) |
| 3 | Notebook | [notebook.md](notebook.md) |
| 4 | Personal Records: Schedule, Event, Observation, Note, Record links, Remarks, deletion | [personal-records.md](personal-records.md) for 4.1 to 4.4, shared.md (this file) for 4.5 and 4.6 |
| 5 | Subject: discovery, Alias, duplicate merge | shared.md (this file) |
| 6 | Financial Records: Expense, Expense Line, Categories, Tags, credit purchases and repayments, Refund, corrections, spending report | [financial-records.md](financial-records.md) |
| 7 | Divination & Reflection: Divination Record, Reading, Analysis, Reading Remark, Story Person, Storyline | [divination-reflection.md](divination-reflection.md) |
| 8 | Communication Assistant | [communication-assistant.md](communication-assistant.md) |
| 9 | Timeline and Shared Retrieval | shared.md (this file) |

## 1.4 How to call a function

1. The Agent chooses how to connect to the Supabase project, such as an AI platform's Supabase connector. A connector normally needs no key. The Agent uses a key from the runtime configuration only when its connection method needs one.
2. Every function is an RPC function in the schema `lifeos`. Call it by its name with named parameters.
3. Every function returns one `jsonb` value.
4. Each function has one signature.
5. Common parameter names:
   - `p_input` — structured JSON input for a create or save.
   - `p_id` — exact Record ID.
   - `p_filter` — structured search or filter input.
   - `p_changes` — structured fields to change.
   - `p_text` — text input, such as a Remark or an Alias.
   - `p_key` — the stable key of a Notebook.
   - `p_record_type` — a Record Type name from 1.5 item 2.

## 1.5 Common Interface Semantics

1. **Record fields.** Every stored Record has `id`, `created_at`, `updated_at` and `deleted_at`. Each Chapter lists the further fields of its Record Types. A function that "returns the complete Record" returns all listed fields plus the derived fields named for that Record Type. Subject derived fields are returned only where Chapter 5 names them.

2. **Record Type names.** Shared functions use these names: `schedule`, `event`, `observation`, `note`, `expense`, `subject`, `divination_record`, `reading`, `storyline`.

3. **Exact read.** A `_read` function returns the Record even when it is deleted. `deleted_at` shows the deletion. An unknown ID returns the error "record not found".

4. **Search.** A `_search` function accepts `limit` and `offset` in `p_filter`.
   - `limit` defaults to 20. `offset` defaults to 0.
   - `keyword` is a case-insensitive substring match. `query` is a compatibility alias for `keyword`.
   - `include_deleted` defaults to false where a function supports it.
   - The return shape is `{ "results": [...], "returned_count": number, "limit": number, "offset": number }`. A function that supports `include_deleted` also returns `"include_deleted": boolean`.

5. **Input fields.** These rules apply to `p_input`, `p_filter` and every nested input object:
   - A missing required field returns "invalid input".
   - A required field with the value `null` returns "invalid input". So does a required text field that is empty or holds only spaces.
   - A field outside the supported list returns "unsupported field". This includes an unknown `p_filter` key.
   - Every function that supports `keyword` also accepts its alias `query` (item 4).

6. **Update.** `p_changes` is partial.
   - An omitted field stays unchanged.
   - `null` clears an optional field.
   - A supplied array replaces the whole stored array.
   - At least one change field is required.
   - `null`, empty text or spaces-only text on a required field returns "invalid input".
   - An unsupported field returns "unsupported field".
   - A deleted Record cannot be updated. The function returns "record deleted".

7. **Edit history.** An edit changes the Record directly and keeps only its latest content. Expense is the only Record Type with correction history ([financial-records.md Chapter 6](financial-records.md#6-financial-records)).

8. **Deletion.** Every `_delete` function is a soft delete. It sets `deleted_at` and returns `{ "id": uuid, "deleted_at": timestamp }`. Deleting an already deleted Record returns its existing `deleted_at`. No restore function exists. [personal-records.md 4.2.6](personal-records.md#426-event_delete) and [financial-records.md 6.7](financial-records.md#67-expense_delete) add fields to this return.

9. **Links to deleted Records.** Other Records keep their stored links to a deleted Record. Every read, search and Timeline result ignores them:
   - Lists of linked Records omit deleted targets.
   - A scalar reference field, such as `schedule_id`, is returned as `null` when its target is deleted. The stored value stays.
   - The only adjusted link is the Event–Schedule link ([personal-records.md 4.2.6](personal-records.md#426-event_delete)).
   - In every search function, a `p_filter` ID of a deleted Record matches nothing through these links. The filter returns no error. This also holds with `include_deleted = true`.
   - The Records that link to a deleted Record stay findable by other filters, such as dates.

10. **Remarks.** `remarks` is a JSON array of `{ "remark_id": uuid, "timestamp": "<UTC ISO 8601>", "text": "<trimmed text>" }`.
    - The function assigns a new `remark_id` to every stored Remark. Input never supplies it.
    - Create input may supply strings or objects with `text` and an optional `timestamp`.
    - A string becomes an object with the current timestamp.
    - An object needs non-empty `text`. A supplied `timestamp` must be valid and is normalised to UTC.
    - `record_add_remark` (4.6.1) appends one Remark. `record_update_remark` (4.6.2) replaces the text of one Remark. `record_delete_remark` (4.6.3) removes one Remark.

11. **Metadata.** `metadata` is a JSON object. It defaults to `{}`. It holds supporting detail without business rules of its own.

12. **Transactions.** Each function call runs in one transaction. A batch either saves fully or saves nothing.

13. **Errors.** Database constraints may return native PostgreSQL errors. Function validation returns errors such as "record not found", "record deleted", "invalid input", "invalid date", "unsupported field" and "invalid relationship".
    - An error may carry a PostgreSQL `detail` text that names the cause, such as 5.8.

14. **Referenced Records.** A supplied reference ID, such as a Subject, Story Person, Schedule, Event or Profile ID, names an active Record. A function may state another rule, such as 9.2 item 4.
    - An unknown ID returns "record not found".
    - An ID of a deleted Record returns "record deleted".
    - An ID in `p_filter` only narrows the results. An unknown ID in `p_filter` returns no error. A deleted ID follows item 9.

15. **Connected Subjects.** Every return that lists the Subjects connected to a Record lists each Subject once, keyed by Subject `id`.
    - This covers `links` (4.5.3) and the Timeline `subjects` (9.1), in every read, search and Timeline result.
    - Several paths may lead to one Subject. `via` then names the first path in this order: `record_link`, `observation_subject`, `payment_method`, `merchant`, `line_item`, `story_person_subject`, `person_profile_subject`.
    - On a Subject, `record_links_read` lists each connected Record once (4.5.3 item 6).

## 1.6 Access

1. Every function is open to the connection the runtime configuration supplies.
2. One user owns all data. No function takes a user ID.

## 1.7 Date and time rules

1. **Time zone.** The business time zone is Asia/Kuala_Lumpur, +08:00.
2. **System timestamps.** `created_at`, `updated_at`, `deleted_at` and every Remark `timestamp` are `timestamptz`. Returns give them in UTC ISO 8601.
3. **Business dates and times.** Occurrence fields, such as `planned_date`, `occurred_time` and `transaction_date`, are Asia/Kuala_Lumpur wall-clock values stored as `date` and `time`. A `null` time means the clock time is unknown.
4. **Today.** "Today" is the current date in Asia/Kuala_Lumpur.
5. **Record date.** The record date of a Record is the Asia/Kuala_Lumpur date of its `created_at`.
6. **Date-only filter boundaries.** On a `timestamptz` field, a date-only `from_date` (YYYY-MM-DD) means 00:00:00.000 +08:00. A date-only `to_date` means 23:59:59.999 +08:00. Timezone-aware timestamps may be supplied directly.
7. **Date fields.** On a `date` field, `from_date` and `to_date` compare inclusively. A supplied timestamp is converted to its Asia/Kuala_Lumpur date.
8. **Imprecise timing.** `time_text` holds the user's own timing wording when the time is imprecise, such as "in the evening". The database never derives a date or time from it.

## 1.8 Which function to call

| The user wants to… | Call | Contract file |
|---|---|---|
| Record something planned, arranged or due | `schedule_create`; a repeating matter: `schedule_create_series` | [personal-records.md](personal-records.md) |
| Report something that happened | `schedule_search` for a matching Schedule, then `event_create` (with `schedule_id` after the user confirms the match) | [personal-records.md](personal-records.md) |
| Record a measurement or state of a Subject | `observation_create` | [personal-records.md](personal-records.md) |
| Record a thought, feeling, idea or a matter without a date | `note_create` | [personal-records.md](personal-records.md) |
| Change, reschedule, cancel or mark a Schedule missed | `schedule_update`; "from now on": `schedule_update_series`; stop a series: `schedule_stop_series` | [personal-records.md](personal-records.md) |
| Ask what happens today | `timeline` for today, then `schedule_overdue_check` | shared.md (this file) for `timeline`, [personal-records.md](personal-records.md) for `schedule_overdue_check` |
| Ask about a day, a week or a month | `timeline` | shared.md (this file) |
| Add a small detail to an existing Record | `record_add_remark` | shared.md (this file) |
| Change or remove a Remark | `record_update_remark`, `record_delete_remark` | shared.md (this file) |
| Change or remove a Reading Remark entry | `reading_remark_update`, `reading_remark_delete` | [divination-reflection.md](divination-reflection.md) |
| Connect two Records, or a Record and a Subject | `record_link_create` | shared.md (this file) |
| Find or check a person, place or thing | `subject_search`, `subject_check`, `subject_read` | shared.md (this file) |
| Ask about a person or thing | `subject_records` | shared.md (this file) |
| Record a purchase or a Receipt | `expense_create`; several approved Receipts: `expense_create_batch` | [financial-records.md](financial-records.md) |
| Record money that came back | `expense_search` for the original, then `expense_refund_create` | [financial-records.md](financial-records.md) |
| Correct or delete an Expense | `expense_update` or `expense_delete`, always with a reason | [financial-records.md](financial-records.md) |
| Ask how much was spent | `expense_spending_report` | [financial-records.md](financial-records.md) |
| Save a divination session | `divination_record_save` | [divination-reflection.md](divination-reflection.md) |
| Find a past Reading | `divination_search`, then `divination_record_read` | [divination-reflection.md](divination-reflection.md) |
| Save a Storyline or a Story Person | `storyline_create`, `story_person_create` | [divination-reflection.md](divination-reflection.md) |
| Draft a message for someone | `communication_profile_search`, then `communication_runtime_context` | [communication-assistant.md](communication-assistant.md) |
| Finish a message | `communication_message_finalize` | [communication-assistant.md](communication-assistant.md) |
| Remember a learned rule or habit | `memory_create`; recall: `memory_search` | [lifeos-memory.md](lifeos-memory.md) |
| Use a vocabulary or default value | `notebook_read` | [notebook.md](notebook.md) |

# 4. Personal Records: shared parts

## 4.5 Record links

A Record link connects two Records that describe the same matter, or a Record and a Subject. Records of different Modules link directly to each other and to the shared Subject.

Typed reference fields hold the structured links: `event.schedule_id`, `observation.subject_id`, `observation.event_id`, the Expense Subject fields ([financial-records.md Chapter 6](financial-records.md#6-financial-records)), `story_person.subject_id` and `communication_profile.person_subject_id`. Record links hold every other link.

Record link fields: `id`, `record_type_a`, `record_id_a`, `record_type_b`, `record_id_b`, `created_at`. A link has no direction. A pair of Records has at most one link.

A `divination_record` or a `reading` never links to a `storyline`, in either direction. Every function that would create such a link returns "invalid relationship". A relation between them goes in a Reading Remark entry ([divination-reflection.md 7.3](divination-reflection.md#73-reading-remark)).

### 4.5.1 record_link_create

**Signature:** `record_link_create(p_input jsonb)`

**Purpose:** Link two Records, or a Record and a Subject.

**Required p_input fields:** `from_type`, `from_id`, `to_type`, `to_id`.

**Supported p_input fields:** `from_type`, `from_id`, `to_type`, `to_id`.

**Defaults:** None.

**Behavior:**
1. Both types are Record Type names (1.5 item 2). Both Records exist and are active.
2. A Record cannot link to itself. A Subject cannot link to another Subject. A Divination Record or a Reading cannot link to a Storyline (4.5). Each case returns "invalid relationship".
3. An existing link for the same pair is returned unchanged.
4. The Agent makes the call only after the link is clear or confirmed by the user.

**Returns:** `{ "link_id": uuid, "from_type", "from_id", "to_type", "to_id", "created_at" }`.

### 4.5.2 record_link_delete

**Signature:** `record_link_delete(p_input jsonb)`

**Purpose:** Remove a Record link that the user corrected as wrong.

**Required p_input fields:** `from_type`, `from_id`, `to_type`, `to_id`.

**Defaults:** None.

**Behavior:** The function physically removes the link for that pair in either direction. A missing link returns `"removed": false`.

**Returns:** `{ "removed": boolean }`.

### 4.5.3 record_links_read

**Signature:** `record_links_read(p_record_type text, p_id uuid)`

**Purpose:** Return every Record linked to one Record, so retrieval can start from any Record.

**Defaults:** None.

**Behavior:**
1. The function returns Record links in both directions.
2. It also returns the typed reference fields that point to or from the Record. The `via` value names each one.
3. Deleted targets are omitted (1.5 item 9).
4. A deleted Record returns its links to active targets, as an exact read does (1.5 item 3).
5. Each connected Subject appears once (1.5 item 15).
6. On a Subject, each connected Record appears once. `via_list` holds every path that leads to it, in the order of 1.5 item 15. `via` is the first path in `via_list`.

**Returns:** `{ "record_type": text, "id": uuid, "links": [ { "via": text, "record_type": text, "id": uuid, "summary": text, "occurrence_date": date or null } ] }`.
- `via` is `record_link`, `schedule`, `event`, `observation_subject`, `observation_event`, `payment_method`, `merchant`, `line_item`, `refund_of`, `story_person_subject` or `person_profile_subject`.
- On a Subject, each entry also has `"via_list": [text]`. A return for any other Record Type has no `via_list`.
- `summary` depends on the target's Record Type:
  - Schedule and Event: `title`.
  - Observation: `observation_name`, a colon, then `value_numeric` with its `unit`, or `value_text` when no numeric value exists. Example: "weight: 70.5 kg".
  - Note and Storyline: `title`, or the first 200 characters of `content` when no title exists.
  - Expense: `merchant_name`, `currency` and `expense_total`, separated by spaces. Example: "Kopitiam MYR 12.50". A Refund shows its negative total. Without `merchant_name`, the first word is "Expense", or "Refund" for a Refund.
  - Subject, Story Person and Communication Profile: `name`.
  - Divination Record: `title`, otherwise `topic`, otherwise "Divination Record".
  - Reading: the first 200 characters of `question`.
  - Communication Message: the first 200 characters of `message_text`.
- `occurrence_date` follows the Timeline field table (9.3).

## 4.6 Remarks

A Remark adds a simple detail to a prior Record without a structured update. Adding, changing and removing a Remark are not edits.

### 4.6.1 record_add_remark

**Signature:** `record_add_remark(p_record_type text, p_id uuid, p_text text)`

**Purpose:** Append one timestamped Remark to an active Record.

**Defaults:** None.

**Behavior:**
1. `p_record_type` is `schedule`, `event`, `observation`, `note` or `expense`.
2. The function appends `{ "remark_id": "<new uuid>", "timestamp": "<current UTC timestamp>", "text": "<trimmed p_text>" }` to `remarks`.
3. An empty `p_text` returns "invalid input". A deleted Record returns "record deleted".
4. A Remark on an Expense creates no correction version.
5. A Remark does not change `updated_at`. On a Note it leaves `edited_at` and the Note's date unchanged.

**Returns:** The complete Record after the Remark is appended.

### 4.6.2 record_update_remark

**Signature:** `record_update_remark(p_record_type text, p_id uuid, p_remark_id uuid, p_text text)`

**Purpose:** Replace the content of one Remark on an active Record.

**Defaults:** None.

**Behavior:**
1. `p_record_type` is `schedule`, `event`, `observation`, `note` or `expense`. Any other value returns "invalid input".
2. The function replaces the `text` of the Remark with `p_remark_id` by the trimmed `p_text`. Its `remark_id` and `timestamp` stay.
3. An empty `p_text` returns "invalid input". A deleted Record returns "record deleted". An unknown `p_remark_id` returns "record not found".
4. A Remark change on an Expense creates no correction version.
5. A Remark change does not change `updated_at`. On a Note it leaves `edited_at` and the Note's date unchanged.

**Returns:** The complete Record after the Remark is changed.

### 4.6.3 record_delete_remark

**Signature:** `record_delete_remark(p_record_type text, p_id uuid, p_remark_id uuid)`

**Purpose:** Remove one Remark from an active Record.

**Defaults:** None.

**Behavior:**
1. `p_record_type` is `schedule`, `event`, `observation`, `note` or `expense`. Any other value returns "invalid input".
2. The function removes the Remark with `p_remark_id` from `remarks`. Other Remarks keep their order and content.
3. A deleted Record returns "record deleted". An unknown `p_remark_id` returns "record not found".
4. A Remark removal on an Expense creates no correction version.
5. A Remark removal does not change `updated_at`. On a Note it leaves `edited_at` and the Note's date unchanged.

**Returns:** The complete Record after the Remark is removed.

# 5. Subject

A Subject preserves the identity of a continuing entity across Records and times. The Agent decides when a Subject is needed and how detailed it is. The user is one Subject.

Subject Record fields:

| Field | Type | Meaning |
|---|---|---|
| `name` | text, required | Primary name. |
| `subject_type` | text | Type from the `subject_types` Notebook ([notebook.md 3.1](notebook.md#31-notebook_read)), such as person, residence, vehicle, product, brand, membership, payment method or bank account. |
| `description` | text | Authoritative identity information and differentiating Relevant Information. |
| `aliases` | text array | Other names. |
| `tags` | text array | Tags from the `subject_tags` Notebook ([notebook.md 3.1](notebook.md#31-notebook_read)). |
| `is_user` | boolean | True only for the Subject that is the user. At most one active Subject is true. |
| `merged_into_id` | uuid | Set when a duplicate merge consolidated this Subject into another. |
| `metadata` | jsonb | 1.5 item 11. |

Derived fields: `person_profile_id` ([communication-assistant.md 8.1](communication-assistant.md#81-profiles)) and `story_person_ids` ([divination-reflection.md 7.4](divination-reflection.md#74-story-person)). Only `subject_read` and the `subject` of `subject_merge` return them. The other Subject functions return the stored fields without derived fields.

## 5.1 subject_create

**Signature:** `subject_create(p_input jsonb)`

**Purpose:** Create one Subject after the user decides it, or create the user Subject.

**Required p_input fields:** `name`.

**Supported p_input fields:** `name`, `subject_type`, `description`, `aliases`, `tags`, `is_user`, `metadata`.

**Defaults:** `aliases = []`, `tags = []`, `is_user = false`, `metadata = {}`.

**Behavior:** `is_user = true` returns "invalid input" when another active Subject is the user.

**Returns:** The complete Subject Record, without derived fields.

## 5.2 subject_read

**Signature:** `subject_read(p_id uuid)`

**Purpose:** Exact Read of one Subject during Subject Discovery.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3. A merged Subject returns its `merged_into_id`.

**Returns:** The complete Subject Record plus `person_profile_id` and `story_person_ids`. Linked Records come from `subject_records` (9.2).

## 5.3 subject_search

**Signature:** `subject_search(p_filter jsonb)`

**Purpose:** Compact Search of Subjects by name, description, type, Alias and Tags.

**Supported p_filter fields:** `keyword`, `subject_type`, `tags`, `is_user`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches `name`, `aliases`, `description`, `subject_type` and `tags`.
2. `tags` is an array. A Subject matches when it holds at least one supplied Tag.
3. Each result is compact: `id`, `name`, `subject_type`, `aliases`, `tags`, `is_user`, `description`.
4. Exact `name` or Alias matches come first. Other results follow by `updated_at` descending.

**Returns:** The search return shape (1.5 item 4).

## 5.4 subject_check

**Signature:** `subject_check(p_text text)`

**Purpose:** Existence Check for a name.

**Defaults:** None.

**Behavior:** The function compares `p_text` with the `name` and `aliases` of active Subjects. The comparison is case-insensitive and exact after trimming. A match is a candidate only. The Agent decides the identity.

**Returns:** `{ "exists": boolean, "matches": [ { "id": uuid, "name": text, "subject_type": text, "matched_on": "name" or "alias" } ] }`.

## 5.5 subject_update

**Signature:** `subject_update(p_id uuid, p_changes jsonb)`

**Purpose:** Make an evidence-supported correction to a Subject, or a correction the user confirmed.

**Supported p_changes fields:** `name`, `subject_type`, `description`, `aliases`, `tags`, `is_user`, `metadata`.

**Defaults:** None.

**Behavior:** Follows 1.5 item 6. `is_user = true` follows the 5.1 rule.

**Returns:** The complete Subject Record after the update, without derived fields.

## 5.6 subject_add_alias

**Signature:** `subject_add_alias(p_id uuid, p_text text)`

**Purpose:** Add one Alias to a Subject.

**Defaults:** None.

**Behavior:** The function appends the trimmed `p_text` to `aliases`. An Alias already present, compared case-insensitively, is not added twice.

**Returns:** The complete Subject Record, without derived fields.

## 5.7 subject_merge

**Signature:** `subject_merge(p_input jsonb)`

**Purpose:** Consolidate a duplicate Subject into the kept Subject after the user's explicit approval.

**Required p_input fields:** `keep_id`, `merge_id`, `identity`.

**Supported p_input fields:** `keep_id`, `merge_id`, `identity`.

**Supported `identity` fields:** `name`, `subject_type`, `description`, `aliases`, `tags`. The Agent merges the identity data of both Subjects before the call.

**Defaults:** None.

**Behavior:**
1. Both Subjects are active and different.
2. The function moves every reference from `merge_id` to `keep_id`: Record links, `observation.subject_id`, the Expense Subject fields, `story_person.subject_id` and `communication_profile.person_subject_id`.
3. A Record link that becomes a duplicate pair is removed.
4. When both Subjects have an active Person Profile, the function returns "invalid relationship". The user resolves the two Profiles first.
5. When `merge_id` has `is_user = true`, `keep_id` becomes the user Subject.
6. The function sets `merged_into_id = keep_id` and `deleted_at` on the merged Subject. Its own fields stay stored.
7. Source Records stay unchanged except for their Subject references.
8. The supplied `identity` fields replace those fields on the kept Subject.
9. `identity` holds at least one field. An empty `identity` `{}` returns "invalid input".

**Returns:** `{ "subject": <complete kept Subject Record with person_profile_id and story_person_ids>, "merged_id": uuid, "moved_references": { "<via>": number } }`.
- `moved_references` always holds seven keys: `record_link`, `observation_subject`, `payment_method`, `merchant`, `line_item`, `story_person_subject` and `person_profile_subject`. A key with no moved reference holds 0.
- `record_link` counts every Record link of `merge_id`, including a link removed as a duplicate pair.
- Every other key counts the rows whose reference field changed to `keep_id`. `line_item` counts Expense Lines.
- The counts include references held by deleted Records.

## 5.8 subject_delete

**Signature:** `subject_delete(p_id uuid)`

**Purpose:** Delete one Subject.

**Defaults:** None.

**Behavior:**
1. Follows 1.5 items 8 and 9. References to the Subject stay stored and are ignored.
2. When an active Person Profile has this Subject as `person_subject_id`, the function returns "invalid relationship". Its detail is "the Person Subject still has a Profile". The Subject stays active.
3. A Subject without an active Person Profile is deleted under item 1.
4. Before deleting a Person Subject with a Profile, the Agent asks the user how to handle the Profile:
   - When the Profile belongs to another person, the Agent links it to the correct Subject with [communication-assistant.md 8.1.4](communication-assistant.md#814-communication_profile_update).
   - When the user no longer wants the Profile, the Agent deletes it with [communication-assistant.md 8.1.5](communication-assistant.md#815-communication_profile_delete).
   - The Agent then deletes the Subject.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

# 9. Timeline and Shared Retrieval

Timeline is the data layer of the LifeOS Timeline function. The Agent layer decides what to say.

## 9.1 timeline

**Signature:** `timeline(p_filter jsonb)`

**Purpose:** Return every Record that the user does or that happens to the user over a period, past or future, each with its occurrence date.

**Required p_filter fields:** `from_date`, `to_date`.

**Supported p_filter fields:** `from_date`, `to_date`, `date_basis`.

**Defaults:** `date_basis = "occurrence"`.

**Behavior:**
1. The included Record Types are Schedule, Event, Observation, Note, Expense (purchase and Refund), Reading and Communication Message. 9.3 names their date fields. An item's `record_type` is the Record Type name (1.5 item 2), or `communication_message` for a Communication Message.
2. Excluded are Storylines, System Activity and deleted Records. Memory, Notebook, Subject, Story Person, Profile and Rule have no occurrence date and are not items.
3. Each item carries `subjects`: every active Subject connected to the Record. Subject connects the Records of all Modules. The connection paths are:
   - A Record link.
   - A typed reference field.
   - For a Reading, a Story Person whose `subject_id` is the Subject.
   - For a Communication Message, the Person Profile of the Subject.

   Each Subject appears once (1.5 item 15).
4. The function applies no further filter and no limit.
5. With `date_basis = "occurrence"`, a Record is included when its occurrence date is in the period. With `date_basis = "record"`, it is included when its record date is in the period. Another `date_basis` value returns "invalid input". A `from_date` after `to_date` returns "invalid input".
6. Schedules of every Status are included. An Occurred Schedule carries `linked_event_id`.
7. Each Event carries its `observations`. Observations are also returned as their own items with `event_id`.
8. Each Reading item carries its own Analyses and the combined Analyses of its Divination Record. Analyses are not separate items.
9. Expense items carry their `lines`. A Refund is an item on its own `transaction_date`.
10. Items are ordered by occurrence date, then occurrence time, with unknown times last within a date.
11. `recorded_earlier` lists items with record date in the period and occurrence date before `from_date`, when `date_basis = "occurrence"`. It supports the Agent's closing note.

**Returns:**
```
{
  "from_date": date,
  "to_date": date,
  "date_basis": "occurrence" | "record",
  "items": [
    {
      "record_type": text,
      "module": "personal_records" | "financial_records" | "divination_reflection" | "communication_assistant",
      "id": uuid,
      "occurrence_date": date,
      "occurrence_time": time or null,
      "record_date": date,
      "record": <complete Record>,
      "subjects": [ { "id": uuid, "name": text, "subject_type": text, "via": text } ],
      "links": [ 4.5.3 link items ]
    }
  ],
  "recorded_earlier": [ item ],
  "returned_count": number
}
```

## 9.2 subject_records

**Signature:** `subject_records(p_id uuid, p_filter jsonb)`

**Purpose:** Return the user's Records connected to one Subject, for Subject questions and cross-module retrieval.

**Supported p_filter fields:** `record_types`, `from_date`, `to_date`, `limit`, `offset`.

**Defaults:** `record_types` = every type below, `limit = 20`, `offset = 0`.

**Behavior:**
1. A Record is connected when one of these holds:
   - a Record link joins it to the Subject;
   - it is an Observation of the Subject;
   - it is an Expense whose Payment Method or Merchant is the Subject, or with a Line whose Item is the Subject;
   - it is a Reading or Storyline with a Story Person whose `subject_id` is the Subject;
   - it is a Message of the Subject's Person Profile.
2. `record_types` accepts `schedule`, `event`, `observation`, `note`, `expense`, `reading`, `storyline` and `communication_message`.
3. `from_date` and `to_date` filter the occurrence date (9.3). Storyline uses `occurrence_date`.
4. Deleted Records are omitted. A deleted Subject returns "record not found".
5. Results are ordered by occurrence date descending. The order of Records within one date is not fixed.
6. The function returns stored Records only. The Agent decides priority and range.

**Returns:** The search return shape (1.5 item 4). Each result is `{ "record_type", "id", "via", "occurrence_date", "record" }`. `via` uses the 4.5.3 values.

## 9.3 Timeline date fields

Every business date and time is an Asia/Kuala_Lumpur wall-clock value (1.7).

| Record Type | Occurrence date field | Record date field | System date fields |
|---|---|---|---|
| Schedule | `planned_date`, with `planned_time` (current planned date) | `created_at` (KL date) | `created_at`, `updated_at`, `deleted_at` |
| Event | `occurred_date`, with `occurred_time` | `created_at` (KL date) | `created_at`, `updated_at`, `deleted_at` |
| Observation | `observed_date`, with `observed_time` | `created_at` (KL date) | `created_at`, `updated_at`, `deleted_at` |
| Note | `note_date` = KL date of `edited_at` when set, otherwise of `created_at` | `created_at` (KL date) | `created_at`, `updated_at`, `deleted_at` |
| Expense (purchase and Refund) | `transaction_date`, with `transaction_time` | `created_at` (KL date) | `created_at`, `updated_at`, `deleted_at`, history `corrected_at` |
| Reading, with its Analyses | `reading_date`, with `reading_time` (original Reading Date) | `created_at` (KL date) | `created_at`, `updated_at`, `deleted_at`, Analysis `created_at` |
| Communication Message | `finalized_at` (KL date and time). It alone does not establish delivery. | `finalized_at` (KL date) | `created_at`, `updated_at`, `deleted_at` |
| Storyline (excluded from Timeline) | `occurrence_date` | `created_at` (KL date) | `created_at`, `updated_at`, `deleted_at` |
