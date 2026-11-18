# LifeOS Database Contract

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

| Chapter | Module or function area |
|---|---|
| 2 | LifeOS Memory |
| 3 | Notebook |
| 4 | Personal Records: Schedule, Event, Observation, Note, Record links, Remarks, deletion |
| 5 | Subject: discovery, Alias, duplicate merge |
| 6 | Financial Records: Expense, Expense Line, Categories, Tags, credit purchases and repayments, Refund, corrections, spending report |
| 7 | Divination & Reflection: Divination Record, Reading, Analysis, Reading Remark, Story Person, Storyline |
| 8 | Communication Assistant |
| 9 | Timeline and Shared Retrieval |

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

7. **Edit history.** An edit changes the Record directly and keeps only its latest content. Expense is the only Record Type with correction history (Chapter 6).

8. **Deletion.** Every `_delete` function is a soft delete. It sets `deleted_at` and returns `{ "id": uuid, "deleted_at": timestamp }`. Deleting an already deleted Record returns its existing `deleted_at`. No restore function exists.

9. **Links to deleted Records.** Other Records keep their stored links to a deleted Record. Every read, search and Timeline result ignores them:
   - Lists of linked Records omit deleted targets.
   - A scalar reference field, such as `schedule_id`, is returned as `null` when its target is deleted. The stored value stays.
   - The only adjusted link is the Event–Schedule link (4.2.6).

10. **Remarks.** `remarks` is a JSON array of `{ "remark_id": uuid, "timestamp": "<UTC ISO 8601>", "text": "<trimmed text>" }`.
    - The function assigns a new `remark_id` to every stored Remark. Input never supplies it.
    - Create input may supply strings or objects with `text` and an optional `timestamp`.
    - A string becomes an object with the current timestamp.
    - An object needs non-empty `text`. A supplied `timestamp` must be valid and is normalised to UTC.
    - `record_add_remark` (4.6.1) appends one Remark. `record_update_remark` (4.6.2) replaces the text of one Remark. `record_delete_remark` (4.6.3) removes one Remark.

11. **Metadata.** `metadata` is a JSON object. It defaults to `{}`. It holds supporting detail without business rules of its own.

12. **Transactions.** Each function call runs in one transaction. A batch either saves fully or saves nothing.

13. **Errors.** Database constraints may return native PostgreSQL errors. Function validation returns errors such as "record not found", "record deleted", "invalid input", "invalid date", "unsupported field" and "invalid relationship".

14. **Referenced Records.** A supplied reference ID, such as a Subject, Story Person, Schedule, Event or Profile ID, names an active Record. A function may state another rule, such as 9.2 item 4.
    - An unknown ID returns "record not found".
    - An ID of a deleted Record returns "record deleted".
    - An ID in `p_filter` only narrows the results. An unknown or deleted ID in `p_filter` returns no error.

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

| The user wants to… | Call |
|---|---|
| Record something planned, arranged or due | `schedule_create`; a repeating matter: `schedule_create_series` |
| Report something that happened | `schedule_search` for a matching Schedule, then `event_create` (with `schedule_id` after the user confirms the match) |
| Record a measurement or state of a Subject | `observation_create` |
| Record a thought, feeling, idea or a matter without a date | `note_create` |
| Change, reschedule, cancel or mark a Schedule missed | `schedule_update`; "from now on": `schedule_update_series`; stop a series: `schedule_stop_series` |
| Ask what happens today | `timeline` for today, then `schedule_overdue_check` |
| Ask about a day, a week or a month | `timeline` |
| Add a small detail to an existing Record | `record_add_remark` |
| Change or remove a Remark | `record_update_remark`, `record_delete_remark` |
| Change or remove a Reading Remark entry | `reading_remark_update`, `reading_remark_delete` |
| Connect two Records, or a Record and a Subject | `record_link_create` |
| Find or check a person, place or thing | `subject_search`, `subject_check`, `subject_read` |
| Ask about a person or thing | `subject_records` |
| Record a purchase or a Receipt | `expense_create`; several approved Receipts: `expense_create_batch` |
| Record money that came back | `expense_search` for the original, then `expense_refund_create` |
| Correct or delete an Expense | `expense_update` or `expense_delete`, always with a reason |
| Ask how much was spent | `expense_spending_report` |
| Save a divination session | `divination_record_save` |
| Find a past Reading | `divination_search`, then `divination_record_read` |
| Save a Storyline or a Story Person | `storyline_create`, `story_person_create` |
| Draft a message for someone | `communication_profile_search`, then `communication_runtime_context` |
| Finish a message | `communication_message_finalize` |
| Remember a learned rule or habit | `memory_create`; recall: `memory_search` |
| Use a vocabulary or default value | `notebook_read` |

# 2. LifeOS Memory

LifeOS Memory stores reusable learned information. It is independent from other Records and has no Subject or source-Record link.

Memory Record fields: `id`, `title`, `content`, `categories` (text array), `tags` (text array), `metadata`, `created_at`, `updated_at`, `deleted_at`.

## 2.1 memory_create

**Signature:** `memory_create(p_input jsonb)`

**Purpose:** Save one learned Memory.

**Required p_input fields:** `content`.

**Supported p_input fields:** `title`, `content`, `categories`, `tags`, `metadata`.

**Defaults:** `title = null`, `categories = []`, `tags = []`, `metadata = {}`.

**Behavior:**
1. `categories` and `tags` are free text arrays. Several values may apply to one Memory. The known Categories are User Operating Rules, Vocabulary, Processing Conventions and Behavioural Patterns.
2. The function stores no conversation transcript link and requires no source Record.

**Returns:** The complete Memory Record.

## 2.2 memory_read

**Signature:** `memory_read(p_id uuid)`

**Purpose:** Read one Memory by exact ID.

**Required p_input fields:** None.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3.

**Returns:** The complete Memory Record.

## 2.3 memory_search

**Signature:** `memory_search(p_filter jsonb)`

**Purpose:** Retrieve Memory relevant to the current Input and Action.

**Supported p_filter fields:** `keyword`, `categories`, `tags`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches `title` and `content`.
2. `categories` and `tags` are arrays. A Memory matches when it holds at least one supplied value of each supplied array.
3. Results are ordered by `updated_at` descending.

**Returns:** The search return shape (1.5 item 4) with complete Memory Records.

## 2.4 memory_update

**Signature:** `memory_update(p_id uuid, p_changes jsonb)`

**Purpose:** Improve or correct existing Learning, or consolidate overlapping Memories into one.

**Supported p_changes fields:** `title`, `content`, `categories`, `tags`, `metadata`.

**Defaults:** None.

**Behavior:** Follows 1.5 item 6. The Memory keeps only its latest content.

**Returns:** The complete Memory Record after the update.

## 2.5 memory_delete

**Signature:** `memory_delete(p_id uuid)`

**Purpose:** Remove a wrong Memory or a Memory merged into another during consolidation.

**Defaults:** None.

**Behavior:** Follows 1.5 item 8.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

# 3. Notebook

A Notebook holds one fixed-purpose reference vocabulary. The catalog keys are `subject_types`, `subject_tags`, `expense_tags`, `note_types` and `defaults`. The `defaults` Notebook holds default values that the Agent applies, such as the default currency. The Agent may add other keys.

Notebook fields: `key`, `name`, `content`, `created_at`, `updated_at`.

A key matches `^[a-z][a-z0-9_]*$` and is unique. `content` is plain text.

## 3.1 notebook_read

**Signature:** `notebook_read(p_key text, p_name text default null)`

**Purpose:** Read a Notebook by its stable key, and initialise it when none exists.

**Defaults:** `p_name = null`.

**Behavior:**
1. When a Notebook with `p_key` exists, the function returns it unchanged.
2. When none exists, the function creates one Notebook with the starting `content` from item 4 and returns it.
3. The name of a new Notebook is `p_name` when supplied. Otherwise the catalog keys take these names: `subject_types` = "Subject Types", `subject_tags` = "Subject Tags", `expense_tags` = "Expense Tags", `note_types` = "Note Types", `defaults` = "Defaults". Any other key takes the key as its name.
4. A new `note_types` Notebook starts with the content `Idea`, `Feeling`, `Experience`, `Explanation`, `General`, one per line. A new `defaults` Notebook starts with the content `currency: MYR`. Every other new Notebook starts empty.

**Returns:** The complete Notebook, plus `"initialised": boolean`, which is true when this call created it.

## 3.2 notebook_list

**Signature:** `notebook_list(p_filter jsonb)`

**Purpose:** List the Notebook Catalog.

**Supported p_filter fields:** `keyword`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`.

**Behavior:** `keyword` matches `key`, `name` and `content`. Results are ordered by `key`. Each result holds `key`, `name`, `content_length` and `updated_at`.

**Returns:** The search return shape (1.5 item 4).

## 3.3 notebook_update

**Signature:** `notebook_update(p_key text, p_changes jsonb)`

**Purpose:** Replace the content or name of a Notebook during ordinary Module use.

**Supported p_changes fields:** `name`, `content`.

**Defaults:** None.

**Behavior:**
1. A supplied `content` replaces the whole content. The Agent adds, revises, consolidates, reorganises and removes entries by writing the new full text.
2. When no Notebook has `p_key`, the function initialises it as in 3.1 and then applies the changes.

**Returns:** The complete Notebook after the update.

# 4. Personal Records

Personal Records hold Schedule, Event, Observation and Note. A Subject link supplies identity without changing a Record's type. The Agent chooses the Record Type before the call. Schedule, Event and Observation always have a date. A matter without a known date is recorded as a Note.

## 4.1 Schedule

A Schedule records a matter that is planned, arranged, expected, intended or required.

Schedule Record fields:

| Field | Type | Meaning |
|---|---|---|
| `title` | text, required | The planned matter. |
| `description` | text | Further detail. |
| `schedule_case` | text | One of `appointment`, `planned_activity`, `deadline`, `expected_activity`. Optional. It is not a separate Record Type. |
| `planned_date` | date, required | Current planned date. |
| `planned_time` | time | Planned start time. `null` when no clock time applies. |
| `end_date`, `end_time` | date, time | Optional planned end. |
| `time_text` | text | User's timing wording when imprecise (1.7 item 8). |
| `location` | text | Planned place. |
| `status` | text | One of `planned`, `occurred`, `missed`, `cancelled`. |
| `series_id` | uuid | Shared Series ID of a repeating matter. `null` for a single Schedule. |
| `series_description` | text | One sentence on how the series occurs. Required when `series_id` is set. |
| `remarks` | jsonb array | 1.5 item 10. |
| `metadata` | jsonb | 1.5 item 11. |

Derived field on every Schedule return: `linked_event_id`, the ID of its active linked Event, or `null`.

Status rules:
1. `planned` is the default.
2. `occurred` is set only by a confirmed Event link (4.2.1, 4.2.2).
3. `missed` and `cancelled` are set by `schedule_update` or `schedule_stop_series`. `schedule_update` also sets `planned` again on a Schedule without an active linked Event, such as when the user corrects its Status.
4. A Schedule with an active linked Event keeps `occurred`. Its status cannot change while the link exists.
5. A Schedule has at most one active linked Event.

### 4.1.1 schedule_create

**Signature:** `schedule_create(p_input jsonb)`

**Purpose:** Create one Schedule, or add one Schedule to an existing series.

**Required p_input fields:** `title`, `planned_date`.

**Supported p_input fields:** `title`, `description`, `schedule_case`, `planned_date`, `planned_time`, `end_date`, `end_time`, `time_text`, `location`, `series_id`, `series_description`, `remarks`, `metadata`.

**Defaults:** `status = "planned"`, `remarks = []`, `metadata = {}`.

**Behavior:**
1. `status` is not accepted in input. Every new Schedule is `planned`.
2. When `series_id` belongs to an existing series and `series_description` is omitted, the function copies the series description of that series.
3. When `series_id` has no existing Schedule, `series_description` is required.
4. A `series_description` without `series_id` is stored as supplied. The Schedule stays a single Schedule.

**Returns:** The complete Schedule Record.

### 4.1.2 schedule_create_series

**Signature:** `schedule_create_series(p_input jsonb)`

**Purpose:** Create a finite repeating matter as individual Schedules that share one Series ID, or extend an existing series.

**Required p_input fields:** `schedules` (array with at least one item). `series_description` when the series is new.

**Supported p_input fields:** `series_id`, `series_description`, `schedules`.

**Defaults:** `series_id` = one new UUID generated before the first insert.

**Behavior:**
1. Each `schedules` item accepts the fields of 4.1.1 except `series_id` and `series_description`. Each item requires `title` and `planned_date`.
2. Every created Schedule receives the same `series_id` and `series_description`.
3. When `series_id` names an existing series, the new Schedules join it. An omitted `series_description` is copied from that series.
4. The series is finite because it holds only the supplied items. The Agent confirms the duration with the user before the call.
5. Every Schedule is created in one transaction.

**Returns:** `{ "series_id": uuid, "series_description": text, "schedules": [complete Schedule Records ordered by planned_date, planned_time] }`.

### 4.1.3 schedule_read

**Signature:** `schedule_read(p_id uuid)`

**Purpose:** Read one Schedule by exact ID.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3. The return includes `linked_event_id` and the linked Records of 4.5.3.

**Returns:** The complete Schedule Record plus `"links": [...]` in the 4.5.3 item shape.

### 4.1.4 schedule_search

**Signature:** `schedule_search(p_filter jsonb)`

**Purpose:** Find Schedules, such as the intended Schedule before an amendment or the candidate Schedule for a reported Event.

**Supported p_filter fields:** `keyword`, `status` (text or array), `schedule_case`, `series_id`, `from_date`, `to_date`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches `title`, `description`, `location`, `series_description`, `time_text` and Remark text.
2. `from_date` and `to_date` filter `planned_date` inclusively.
3. `series_id` returns every Schedule of that series.
4. Results are ordered by `planned_date`, then `planned_time`, with `null` values last.

**Returns:** The search return shape (1.5 item 4) with complete Schedule Records.

### 4.1.5 schedule_update

**Signature:** `schedule_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change one Schedule: a reschedule, a content change, "change this one", or a Missed or Cancelled Status.

**Supported p_changes fields:** `title`, `description`, `schedule_case`, `planned_date`, `planned_time`, `end_date`, `end_time`, `time_text`, `location`, `status`, `series_description`, `metadata`.

**Defaults:** None.

**Behavior:**
1. A reschedule changes `planned_date` or `planned_time` directly. No separate Status value records it.
2. `status` accepts `planned`, `missed` and `cancelled`. The value `occurred` returns "invalid input".
3. A Schedule with an active linked Event rejects any `status` change with "invalid relationship".
4. The change applies to this Schedule only. Other Schedules of the series stay unchanged.

**Returns:** The complete Schedule Record after the update.

### 4.1.6 schedule_update_series

**Signature:** `schedule_update_series(p_input jsonb)`

**Purpose:** Apply "change from now on" to the later Planned Schedules of one series.

**Required p_input fields:** `series_id`, `from_date`, `changes`.

**Supported p_input fields:** `series_id`, `from_date`, `changes`.

**Supported `changes` fields:** `title`, `description`, `schedule_case`, `planned_time`, `end_time`, `time_text`, `location`, `series_description`, `metadata`.

**Defaults:** None.

**Behavior:**
1. Target Schedules are the active Schedules of the series with `status = "planned"`.
2. A target has `planned_date` on or after `from_date`. `from_date` itself counts. The caller converts "from now on" into a date.
3. Schedules before `from_date`, Schedules with another Status and their Events stay unchanged.
4. A changed `series_description` applies to the target Schedules only. The Agent writes the amended description, such as the date from which the change applies. Earlier Schedules keep their description.
5. Date changes are made per Schedule with `schedule_update`.
6. A `series_id` that no Schedule holds returns "record not found".

**Returns:** `{ "series_id": uuid, "updated_count": number, "schedules": [complete updated Schedule Records] }`.

### 4.1.7 schedule_stop_series

**Signature:** `schedule_stop_series(p_input jsonb)`

**Purpose:** Stop a repeating matter.

**Required p_input fields:** `series_id`, `from_date`.

**Supported p_input fields:** `series_id`, `from_date`.

**Defaults:** None.

**Behavior:**
1. The target Schedules of 4.1.6 items 1–2 become `cancelled`.
2. Schedules before `from_date`, Schedules with another Status and Events stay unchanged.
3. A `series_id` that no Schedule holds returns "record not found".

**Returns:** `{ "series_id": uuid, "cancelled_count": number, "schedules": [complete cancelled Schedule Records] }`.

### 4.1.8 schedule_overdue_check

**Signature:** `schedule_overdue_check(p_filter jsonb)`

**Purpose:** Return the Planned Schedules from yesterday or today whose time has passed without a linked Event. It supports the overdue question the Agent asks when the user asks what happens today.

**Supported p_filter fields:** None. `p_filter` may be `{}` or `null`.

**Defaults:** The window is yesterday and today.

**Behavior:**
1. A result is active, has `status = "planned"`, has no active linked Event and has `planned_date` yesterday or today.
2. A timed Schedule has passed when its `planned_date` and `planned_time` are before now.
3. A date-only Schedule has passed when its whole date has passed, that is, when its `planned_date` is before today.
4. Schedules with Status `occurred`, `missed` or `cancelled` are handled and never returned.
5. The Agent records the user's answer with `schedule_update` or `event_create`.

**Returns:** `{ "results": [complete Schedule Records], "returned_count": number }`, ordered by `planned_date`, then `planned_time`, with date-only Schedules last within a date.

### 4.1.9 schedule_delete

**Signature:** `schedule_delete(p_id uuid)`

**Purpose:** Delete one Schedule.

**Defaults:** None.

**Behavior:** Follows 1.5 items 8 and 9. A linked Event keeps its stored `schedule_id`. Its returns show `schedule_id = null`. The deleted Schedule keeps its `status` until the Event that stores its ID is deleted. 4.2.6 item 2 then sets its `status` to `planned`. After the Event links to another Schedule (4.2.2 item 3), the Event no longer stores that ID. The deleted Schedule then keeps its `status`.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 4.2 Event

An Event records an actual action or occurrence with temporal context.

Event Record fields:

| Field | Type | Meaning |
|---|---|---|
| `title` | text, required | What happened. |
| `description` | text | Further detail. |
| `occurred_date` | date, required | Actual date. |
| `occurred_time` | time | Actual time. `null` when unknown. |
| `end_date`, `end_time` | date, time | Optional actual end. |
| `time_text` | text | User's timing wording when imprecise. |
| `location` | text | Place. |
| `schedule_id` | uuid | The confirmed Schedule this Event actualises. Unique among active Events. |
| `planned_date`, `planned_time` | date, time | The Schedule's planned date and time, copied when the Event is linked to the Schedule. They are not the actual date and time. |
| `remarks` | jsonb array | 1.5 item 10. |
| `metadata` | jsonb | 1.5 item 11. |

Derived field on every Event return: `observations`, the active Observations whose `event_id` is this Event.

### 4.2.1 event_create

**Signature:** `event_create(p_input jsonb)`

**Purpose:** Record an actual occurrence, with or without a confirmed Schedule.

**Required p_input fields:** `occurred_date`, and `title` unless `schedule_id` is supplied.

**Supported p_input fields:** `title`, `description`, `occurred_date`, `occurred_time`, `end_date`, `end_time`, `time_text`, `location`, `schedule_id`, `remarks`, `metadata`.

**Defaults:** `remarks = []`, `metadata = {}`.

**Behavior:**
1. Without `schedule_id`, the function records an ordinary Event.
2. With `schedule_id`, the Agent has the user's confirmation of the match. The function then:
   1. checks that the Schedule is active and has no active linked Event;
   2. copies the Schedule's `title`, `description` and `location` into each of those fields that the input omits;
   3. copies the Schedule's `planned_date` and `planned_time` into the Event's `planned_date` and `planned_time`. The actual `occurred_date` and `occurred_time` come only from the input;
   4. creates the Event with the link;
   5. sets the Schedule `status` to `occurred`.
3. A Schedule with an active linked Event returns "invalid relationship".
4. A Planned, Cancelled or Missed Schedule becomes `occurred`, because the user's latest confirmation decides.

**Returns:** The complete Event Record. With a Schedule link, it also returns `"schedule": <complete Schedule Record>`.

### 4.2.2 event_link_schedule

**Signature:** `event_link_schedule(p_id uuid, p_schedule_id uuid)`

**Purpose:** Link an existing Event to the Schedule the user confirmed.

**Defaults:** None.

**Behavior:**
1. The Event and the Schedule are active.
2. The Event has no Schedule link, and the Schedule has no active linked Event. Otherwise the function returns "invalid relationship".
3. An Event whose linked Schedule is deleted has no Schedule link under item 2. It may link to a new Schedule.
4. The function sets `schedule_id` on the Event and sets the Schedule `status` to `occurred`.
5. A Planned, Cancelled or Missed Schedule becomes `occurred`, because the user's latest confirmation decides.
6. The function copies the Schedule's `planned_date` and `planned_time` into the Event. Other Event content stays unchanged.

**Returns:** The complete Event Record plus `"schedule": <complete Schedule Record>`.

### 4.2.3 event_read

**Signature:** `event_read(p_id uuid)`

**Purpose:** Read one Event by exact ID.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3. The return includes `observations` and the linked Records of 4.5.3.

**Returns:** The complete Event Record plus `"links": [...]`.

### 4.2.4 event_search

**Signature:** `event_search(p_filter jsonb)`

**Purpose:** Find Events, such as a prior Event before an amendment, or the Event of an earlier day for a Note.

**Supported p_filter fields:** `keyword`, `from_date`, `to_date`, `schedule_id`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches `title`, `description`, `location`, `time_text` and Remark text.
2. `from_date` and `to_date` filter `occurred_date` inclusively.
3. Results are ordered by `occurred_date` descending, then `occurred_time` descending, with `null` values last.

**Returns:** The search return shape (1.5 item 4) with complete Event Records.

### 4.2.5 event_update

**Signature:** `event_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change one Event.

**Supported p_changes fields:** `title`, `description`, `occurred_date`, `occurred_time`, `end_date`, `end_time`, `time_text`, `location`, `metadata`.

**Defaults:** None.

**Behavior:** Follows 1.5 item 6. `schedule_id` changes only through 4.2.2 and 4.2.6.

**Returns:** The complete Event Record after the update.

### 4.2.6 event_delete

**Signature:** `event_delete(p_id uuid)`

**Purpose:** Delete one Event.

**Defaults:** None.

**Behavior:**
1. The function sets `deleted_at` on the Event.
2. When the Event has `schedule_id`, the function clears `schedule_id` and sets that Schedule's `status` to `planned`.
3. Every other link to the Event stays stored and is ignored (1.5 item 9). This includes Observations with this `event_id` and Notes linked through 4.5.

**Returns:** `{ "id": uuid, "deleted_at": timestamp, "schedule_returned_to_planned": uuid or null }`.

## 4.3 Observation

An Observation records a Subject's numeric Measurement or descriptive or categorical State at the observation time.

Observation Record fields:

| Field | Type | Meaning |
|---|---|---|
| `subject_id` | uuid, required | The observed Subject. |
| `observation_name` | text, required | What is measured or described, such as "weight" or "membership points". |
| `value_numeric` | numeric | Measurement value. Exact precision is kept. |
| `unit` | text | Unit of `value_numeric`. |
| `value_text` | text | Descriptive or categorical State, or a compound reading such as "120/80". |
| `observed_date` | date, required | Observation date. |
| `observed_time` | time | Observation time. `null` when unknown. |
| `time_text` | text | User's timing wording when imprecise. |
| `location` | text | Contextual location. |
| `event_id` | uuid | The Event reported together with this Observation. |
| `remarks` | jsonb array | 1.5 item 10. |
| `metadata` | jsonb | 1.5 item 11. |

At least one of `value_numeric` and `value_text` is present.

### 4.3.1 observation_create

**Signature:** `observation_create(p_input jsonb)`

**Purpose:** Record one Observation, linked to its Subject and optionally to its Event.

**Required p_input fields:** `subject_id`, `observation_name`, `observed_date`, and `value_numeric` or `value_text`.

**Supported p_input fields:** `subject_id`, `observation_name`, `value_numeric`, `unit`, `value_text`, `observed_date`, `observed_time`, `time_text`, `location`, `event_id`, `remarks`, `metadata`.

**Defaults:** `remarks = []`, `metadata = {}`.

**Behavior:**
1. The Subject and any supplied Event are active.
2. One Event may have many Observations.
3. Without `event_id`, the Observation links only to its Subject. The function creates no Event.
4. A later real-world change is a new Observation. The function records no relationship between Observations of the same Subject.

**Returns:** The complete Observation Record.

### 4.3.2 observation_read

**Signature:** `observation_read(p_id uuid)`

**Purpose:** Read one Observation by exact ID.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3.

**Returns:** The complete Observation Record plus `"links": [...]` (4.5.3).

### 4.3.3 observation_search

**Signature:** `observation_search(p_filter jsonb)`

**Purpose:** Find Observations of a Subject or a measure.

**Supported p_filter fields:** `keyword`, `subject_id`, `observation_name`, `event_id`, `from_date`, `to_date`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches `observation_name`, `value_text`, `unit`, `location` and Remark text.
2. `observation_name` is a case-insensitive exact match.
3. `from_date` and `to_date` filter `observed_date` inclusively.
4. Results are ordered by `observed_date` descending, then `observed_time` descending, with `null` values last within a date.

**Returns:** The search return shape (1.5 item 4) with complete Observation Records.

### 4.3.4 observation_update

**Signature:** `observation_update(p_id uuid, p_changes jsonb)`

**Purpose:** Correct one Observation.

**Supported p_changes fields:** `subject_id`, `observation_name`, `value_numeric`, `unit`, `value_text`, `location`, `event_id`, `metadata`.

**Defaults:** None.

**Behavior:**
1. A corrected Observation keeps its original observation time. `observed_date`, `observed_time` and `time_text` are not change fields.
2. The result still holds `value_numeric` or `value_text`.

**Returns:** The complete Observation Record after the update.

### 4.3.5 observation_delete

**Signature:** `observation_delete(p_id uuid)`

**Purpose:** Delete one Observation.

**Defaults:** None.

**Behavior:** Follows 1.5 items 8 and 9.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 4.4 Note

A Note preserves independent narrative information.

Note Record fields:

| Field | Type | Meaning |
|---|---|---|
| `note_type` | text, required | A Note Type from the `note_types` Notebook, such as Idea, Feeling, Experience, Explanation or General. |
| `title` | text | Optional heading. |
| `content` | text, required | The narrative. |
| `edited_at` | timestamptz | Time of the latest `note_update`. `null` before any edit. |
| `remarks` | jsonb array | 1.5 item 10. |
| `metadata` | jsonb | 1.5 item 11. |

A Note has no Tags. Derived field on every Note return: `note_date`, the Asia/Kuala_Lumpur date of `edited_at` when set, otherwise of `created_at`.

### 4.4.1 note_create

**Signature:** `note_create(p_input jsonb)`

**Purpose:** Record one Note dated on the day the user records it.

**Required p_input fields:** `note_type`, `content`.

**Supported p_input fields:** `note_type`, `title`, `content`, `remarks`, `metadata`.

**Defaults:** `edited_at = null`, `remarks = []`, `metadata = {}`.

**Behavior:**
1. The input accepts no date. The Note's date is its record date.
2. `note_type` is free text. The `note_types` Notebook holds the vocabulary.
3. A feeling about an earlier day is a Note linked to that day's Event with `record_link_create` (4.5.1). The Agent creates the Event first with `event_create` when none exists.

**Returns:** The complete Note Record.

### 4.4.2 note_read

**Signature:** `note_read(p_id uuid)`

**Purpose:** Read one Note by exact ID.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3.

**Returns:** The complete Note Record plus `"links": [...]` (4.5.3).

### 4.4.3 note_search

**Signature:** `note_search(p_filter jsonb)`

**Purpose:** Find Notes.

**Supported p_filter fields:** `keyword`, `note_type`, `from_date`, `to_date`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches `title`, `content` and Remark text.
2. `note_type` is a case-insensitive exact match.
3. `from_date` and `to_date` filter `note_date` inclusively.
4. Results are ordered by `note_date` descending.

**Returns:** The search return shape (1.5 item 4) with complete Note Records.

### 4.4.4 note_update

**Signature:** `note_update(p_id uuid, p_changes jsonb)`

**Purpose:** Edit one Note.

**Supported p_changes fields:** `note_type`, `title`, `content`, `metadata`.

**Defaults:** None.

**Behavior:** The function sets `edited_at` to the current time. The Note's date therefore moves to the edit date.

**Returns:** The complete Note Record after the update.

### 4.4.5 note_delete

**Signature:** `note_delete(p_id uuid)`

**Purpose:** Delete one Note.

**Defaults:** None.

**Behavior:** Follows 1.5 items 8 and 9.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 4.5 Record links

A Record link connects two Records that describe the same matter, or a Record and a Subject. Records of different Modules link directly to each other and to the shared Subject.

Typed reference fields hold the structured links: `event.schedule_id`, `observation.subject_id`, `observation.event_id`, the Expense Subject fields (Chapter 6), `story_person.subject_id` and `communication_profile.person_subject_id`. Record links hold every other link.

Record link fields: `id`, `record_type_a`, `record_id_a`, `record_type_b`, `record_id_b`, `created_at`. A link has no direction. A pair of Records has at most one link.

### 4.5.1 record_link_create

**Signature:** `record_link_create(p_input jsonb)`

**Purpose:** Link two Records, or a Record and a Subject.

**Required p_input fields:** `from_type`, `from_id`, `to_type`, `to_id`.

**Supported p_input fields:** `from_type`, `from_id`, `to_type`, `to_id`.

**Defaults:** None.

**Behavior:**
1. Both types are Record Type names (1.5 item 2). Both Records exist and are active.
2. A Record cannot link to itself. A Subject cannot link to another Subject. A `reading` and a `storyline` cannot link to each other. Each case returns "invalid relationship".
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
5. A Subject appears once in a Reading's links. When a Record link and a Story Person both lead to it, its `via` is `record_link`.

**Returns:** `{ "record_type": text, "id": uuid, "links": [ { "via": text, "record_type": text, "id": uuid, "summary": text, "occurrence_date": date or null } ] }`.
- `via` is `record_link`, `schedule`, `event`, `observation_subject`, `observation_event`, `payment_method`, `merchant`, `line_item`, `refund_of`, `story_person_subject` or `person_profile_subject`.
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
| `subject_type` | text | Type from the `subject_types` Notebook, such as person, residence, vehicle, product, brand, membership, payment method or bank account. |
| `description` | text | Authoritative identity information and differentiating Relevant Information. |
| `aliases` | text array | Other names. |
| `tags` | text array | Tags from the `subject_tags` Notebook. |
| `is_user` | boolean | True only for the Subject that is the user. At most one active Subject is true. |
| `merged_into_id` | uuid | Set when a duplicate merge consolidated this Subject into another. |
| `metadata` | jsonb | 1.5 item 11. |

Derived fields: `person_profile_id` (8.1) and `story_person_ids` (7.4). Only `subject_read` and the `subject` of `subject_merge` return them. The other Subject functions return the stored fields without derived fields.

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

**Behavior:** Follows 1.5 items 8 and 9. References to the Subject stay stored and are ignored.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

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
| `currency` | text, required | ISO 4217 code. The Agent supplies it. The default currency is in the `defaults` Notebook (Chapter 3). |
| `refund_of` | uuid | For a Refund, the original Expense. |
| `remarks` | jsonb array | 1.5 item 10. |
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
| `metadata` | jsonb | 1.5 item 11. |
| `created_at`, `updated_at` | timestamptz | System timestamps of the Line (1.7 item 2). |

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
3. Supplied Subject IDs are active Subjects (1.5 item 14). A missing Merchant or Item Subject does not prevent the save.
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

**Behavior:** Follows 1.5 item 3. A Refund also returns `"original": <compact original Expense>` with `id`, `transaction_date`, `merchant_name` and `expense_total`.

**Returns:** The complete Expense Record with `lines`, `discrepancies`, `refunds`, `version` and `"links": [...]` (4.5.3).

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

**Returns:** The search return shape (1.5 item 4) with complete Expense Records.

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
5. `expense_type`, `refund_of` and `remarks` are not change fields. Remarks use 4.6.
6. A Refund change keeps the 6.8 shape. The Payment Method and Currency stay those of the original Expense. The Refund Line changes only when the correction supplies `refund_amount`, `item_description`, `item_subject_id` or `line_type`.
7. On a purchase, `expense_total` stays zero or positive (6.1 item 2).
8. The Refund limits hold on the state after the correction. On a Refund, the function checks the purchase that `refund_of` names:
   - The `refund_amount` after the correction plus the amounts of the other active Refunds of that purchase is at most the purchase `expense_total`.
   - The `transaction_date` after the correction is on or after the purchase `transaction_date`. The same day is allowed.
9. On a purchase, the function checks its active Refunds:
   - The `expense_total` after the correction is at least the sum of the amounts of its active Refunds. The check also applies to a correction that supplies `lines`.
   - The `transaction_date` after the correction is on or before the `transaction_date` of every active Refund.
10. A violation of item 8 or 9 returns "invalid input". The function rejects the whole correction and saves no history version.
11. A Refund whose purchase is deleted has no limit from that purchase.

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
2. It then follows 1.5 items 8 and 9. Deleting an already deleted Expense saves no history version. It returns the existing `deleted_at`.
3. Refunds of a deleted original stay. Their `refund_of` is returned as `null`. Each Refund counts by its own amount and date (6.9 item 2). Its corrections have no limit from the deleted original (6.5 item 11).

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

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
2. A purchase counts in the period of its `transaction_date`. A Refund counts as its negative total in the period the money came back. A Refund whose original Expense is deleted counts the same way, by its own `expense_total` and `transaction_date`.
3. Part 1, `total_spent`: the sum of `expense_total` over purchases and Refunds.
4. Part 2, `by_payment_method`: the same sum per `payment_method_subject_id`, with the Subject name. Ordered by total descending.
5. Part 3, `by_category`: the sum of `line_total` per `category` over purchase Lines. Refund Lines and Adjustment Lines are excluded. Ordered by total descending.
6. Part 4, `by_tag`: the sum of `line_total` per Tag over purchase Lines. A Line with several Tags counts under each Tag. Refund Lines and Adjustment Lines are excluded. Ordered by total descending.
7. Part 5, `adjustments`: the signed sum of purchase Lines with `line_type = "adjustment"`, and that sum per Merchant. Ordered with the most negative total first, so the first entry is the source that gave the most. Parts 3 and 4 leave out Adjustment Lines, so their totals may not add up to Part 1, `total_spent`. An Adjustment Line still stores its Category.
8. The report also returns two Refund lists for the Agent's explanation:
   - `refunds_in_period`: each Refund in the period with its original's `transaction_date` and total. When the original is deleted, `refund_of`, `original_transaction_date` and `original_total` are `null`.
   - `later_refunds`: each active Refund after `to_date` whose active original is in the period.
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

**Behavior:** The list is fixed: food, drink, transport, clothing, beauty, electronics, household, entertainment, medical, education, travel, gift, fees, rental, loans, discount, other. Expense Tags have no fixed list. The `expense_tags` Notebook holds their vocabulary.

**Returns:** `{ "categories": [17 text values in the order above] }`.

# 7. Divination & Reflection

One divination session is one Divination Record. Each Question with its original Result is one Reading inside it. Analyses are source-attributed. Story Persons and Storylines form the Storybook.

Divination Record fields: `session_date` (date), `title`, `topic`, `metadata`, `readings`, `record_analyses`.

Reading fields:

| Field | Type | Meaning |
|---|---|---|
| `divination_record_id` | uuid | Parent Divination Record. |
| `question` | text, required | The user's Question. |
| `method` | text, required | `i_ching` or `tarot`. |
| `spread_name` | text | Tarot Spread name. |
| `result_text` | text, required | Full original user-provided Result text, kept unfragmented. |
| `reading_date` | date | Original Reading Date. |
| `reading_time` | time | Reading time when known. |
| `story_person_ids` | uuid array | Associated Story Persons. |
| `remark_entries` | jsonb array | The Reading Remark (7.3). |
| `metadata` | jsonb | 1.5 item 11. |

Analysis fields: `divination_record_id`, `reading_id` (`null` for a combined Analysis of the Divination Record), `source` (required: the AI system, person, application or channel), `overall_outcome` (required), `key_reasoning` (required), `story_context` (optional), `analysis_date` (date), `metadata`. `analysis_date` is the date of the Analysis itself. Timeline shows every Analysis under the `reading_date` of its Reading (9.1 item 8).

## 7.1 Divination Record and Reading

### 7.1.1 divination_record_save

**Signature:** `divination_record_save(p_input jsonb)`

**Purpose:** Save a completed divination session after the user approves the save.

**Required p_input fields:** `readings` (array with at least one item).

**Supported p_input fields:** `session_date`, `title`, `topic`, `metadata`, `readings`, `record_analyses`.

**Supported `readings` item fields:** `question`, `method`, `spread_name`, `result_text`, `reading_date`, `reading_time`, `story_person_ids`, `analyses`, `metadata`.

**Supported analysis item fields:** `source`, `overall_outcome`, `key_reasoning`, `story_context`, `analysis_date`, `metadata`.

**Defaults:** `session_date` = today. Reading `reading_date = session_date`. `analysis_date = session_date`. Arrays default to `[]`.

**Behavior:**
1. The function creates the Divination Record, its Readings, the Reading Analyses and the combined `record_analyses` in one transaction.
2. `result_text` is stored as supplied.
3. A combined Analysis is stored once on the Divination Record with `reading_id = null`.
4. Every `story_person_ids` value is an active Story Person (1.5 item 14).
5. No call happens when the user declines the save.

**Returns:** The complete Divination Record with `readings`, each Reading's `analyses`, and `record_analyses`.

### 7.1.2 divination_record_read

**Signature:** `divination_record_read(p_id uuid)`

**Purpose:** Read one complete Divination Record.

**Defaults:** None.

**Behavior:**
1. Follows 1.5 item 3. The return holds Key Reasoning, Story Context and Reading Remarks for the Agent to show when the user asks.
2. An active Divination Record returns its active Readings and Analyses.
3. A deleted Divination Record returns the Readings and Analyses deleted together with it, each with its `deleted_at`.

**Returns:** The complete Divination Record with `readings`, `analyses`, `record_analyses`, `remark_entries` and each Reading's `"links": [...]` (4.5.3).

### 7.1.3 divination_search

**Signature:** `divination_search(p_filter jsonb)`

**Purpose:** Find past Readings by Subject, topic or date, in the short view.

**Supported p_filter fields:** `keyword`, `subject_id`, `story_person_id`, `method`, `from_date`, `to_date`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `keyword` matches the Divination Record `title` and `topic`, and the Reading `question` and `result_text`.
2. `subject_id` matches Readings linked to that Subject by a Record link, and Readings whose Story Persons have that `subject_id`.
3. `from_date` and `to_date` filter `reading_date` inclusively.
4. Each result is one Divination Record with only its matching Readings. When `keyword` matches the Divination Record `title` or `topic`, every Reading of that Record matches the keyword.
5. Each result holds `id`, `session_date`, `title`, `topic`, `deleted_at`, `readings` and `record_analyses`. The short view of each Reading holds `id`, `question`, `method`, `result_text`, `reading_date` and the `overall_outcome` and `source` of each Analysis. Combined Analyses appear the same way on the Divination Record.
6. Results are ordered by the latest `reading_date` descending.

**Returns:** The search return shape (1.5 item 4).

### 7.1.4 divination_record_update

**Signature:** `divination_record_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change the descriptive fields of a Divination Record.

**Supported p_changes fields:** `title`, `topic`, `session_date`, `metadata`.

**Defaults:** None.

**Behavior:** Follows 1.5 item 6. `session_date` is required, so `null` returns "invalid input". Readings and Analyses stay unchanged. Their Question, Result and Analysis content have no update function.

**Returns:** The complete Divination Record after the update.

### 7.1.5 divination_record_delete

**Signature:** `divination_record_delete(p_id uuid)`

**Purpose:** Delete one Divination Record with its Readings and Analyses.

**Defaults:** None.

**Behavior:** The function sets the same `deleted_at` on the Divination Record, its Readings and its Analyses. Links follow 1.5 item 9.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

### 7.1.6 reading_create

**Signature:** `reading_create(p_input jsonb)`

**Purpose:** Add a Reading to an existing Divination Record, such as a later additional or revised option.

**Required p_input fields:** `divination_record_id`, `question`, `method`, `result_text`.

**Supported p_input fields:** The 7.1.1 `readings` item fields plus `divination_record_id`.

**Defaults:** `reading_date` = today. Analysis `analysis_date` = today. Arrays default to `[]`.

**Behavior:** Earlier Readings stay unchanged.

**Returns:** The complete Reading with `analyses`.

### 7.1.7 reading_story_persons_set

**Signature:** `reading_story_persons_set(p_id uuid, p_input jsonb)`

**Purpose:** Set the Story Persons associated with one Reading.

**Required p_input fields:** `story_person_ids`.

**Defaults:** None.

**Behavior:**
1. The supplied array replaces the Reading's Story Person set. Every value is an active Story Person (1.5 item 14). A repeated ID is stored once.
2. The change touches only the association. It is not an edit. The Reading's `updated_at`, Question, Result and Analyses stay unchanged.
3. A Reading has no structured link to a Storyline.

**Returns:** The complete Reading.

### 7.1.8 reading_delete

**Signature:** `reading_delete(p_id uuid)`

**Purpose:** Delete one Reading and its Reading Analyses.

**Defaults:** None.

**Behavior:** Combined Analyses of the Divination Record stay. Links follow 1.5 item 9.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 7.2 Analysis

### 7.2.1 analysis_add

**Signature:** `analysis_add(p_input jsonb)`

**Purpose:** Add a later source-attributed Analysis to a Reading or, as a combined Analysis, to a Divination Record.

**Required p_input fields:** `source`, `overall_outcome`, `key_reasoning`, and `reading_id` or `divination_record_id`.

**Supported p_input fields:** `reading_id`, `divination_record_id`, `source`, `overall_outcome`, `key_reasoning`, `story_context`, `analysis_date`, `metadata`.

**Defaults:** `analysis_date` = today. `story_context = null`.

**Behavior:**
1. With `reading_id`, the Analysis belongs to that Reading. Its `divination_record_id` is the Reading's parent.
2. With only `divination_record_id`, the Analysis is combined.
3. The original Reading and earlier Analyses stay unchanged.

**Returns:** The complete Analysis.

### 7.2.2 analysis_delete

**Signature:** `analysis_delete(p_id uuid)`

**Purpose:** Delete one Analysis.

**Defaults:** None.

**Behavior:** Follows 1.5 item 8.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 7.3 Reading Remark

A Reading has one Reading Remark made of entries. Entry fields: `entry_id` (uuid), `timestamp` (UTC), `storyline_id` (uuid or `null`), `text` (trimmed text). The `storyline_id` is an explanatory reference without a foreign key or Record link. Adding, changing and removing an entry leave the `updated_at` of the Divination Record unchanged.

### 7.3.1 reading_remark_add

**Signature:** `reading_remark_add(p_id uuid, p_input jsonb)`

**Purpose:** Add one entry to a Reading Remark after the user agrees, following a saved Storyline.

**Required p_input fields:** `text`.

**Supported p_input fields:** `text`, `storyline_id`.

**Defaults:** `storyline_id = null`. `timestamp` = current time.

**Behavior:** The function appends one entry with a new `entry_id` and the trimmed `text`. A deleted Reading returns "record deleted". The Reading's `updated_at` and its Analyses stay unchanged.

**Returns:** The complete Reading with `remark_entries`.

### 7.3.2 reading_remark_update

**Signature:** `reading_remark_update(p_id uuid, p_input jsonb)`

**Purpose:** Correct one Reading Remark entry under the approved cutoff flow.

**Required p_input fields:** `entry_id`, `text`.

**Supported p_input fields:** `entry_id`, `text`, `storyline_id`.

**Defaults:** `storyline_id = null`.

**Behavior:**
1. The function replaces the whole content of the entry with `entry_id`. `text` becomes the trimmed supplied text. `storyline_id` becomes the supplied value, or `null` when it is omitted.
2. The entry keeps its `entry_id` and `timestamp`. Other entries keep their order and content.
3. A missing or blank `text` returns "invalid input". An unknown `entry_id` returns "record not found". A deleted Reading returns "record deleted".
4. The Reading's `updated_at` and its Analyses stay unchanged, because the function changes only a Remark entry.

**Returns:** The complete Reading with `remark_entries`.

### 7.3.3 reading_remark_delete

**Signature:** `reading_remark_delete(p_id uuid, p_input jsonb)`

**Purpose:** Remove one Reading Remark entry under the approved cutoff flow.

**Required p_input fields:** `entry_id`.

**Supported p_input fields:** `entry_id`.

**Defaults:** None.

**Behavior:**
1. The function removes the entry with `entry_id`. Other entries keep their order and content.
2. An unknown `entry_id` returns "record not found". A deleted Reading returns "record deleted".
3. The Reading's `updated_at` and its Analyses stay unchanged, because the function changes only a Remark entry.

**Returns:** The complete Reading with `remark_entries`.

## 7.4 Story Person

Story Person fields: `name` (required), `gender`, `description` (identifying clues), `aliases` (text array), `subject_id` (optional LifeOS Subject association), `metadata`. A Story Person belongs to Divination & Reflection only.

### 7.4.1 story_person_create

**Signature:** `story_person_create(p_input jsonb)`

**Purpose:** Create a Story Person at an approved Storybook save.

**Required p_input fields:** `name`.

**Supported p_input fields:** `name`, `gender`, `description`, `aliases`, `subject_id`, `metadata`.

**Defaults:** `aliases = []`, `subject_id = null`, `metadata = {}`.

**Behavior:** A supplied `subject_id` is an active Subject (1.5 item 14). The Agent supplies it only after the user approves the association.

**Returns:** The complete Story Person.

### 7.4.2 story_person_read

**Signature:** `story_person_read(p_id uuid)`

**Purpose:** Read one Story Person.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3.

**Returns:** The complete Story Person plus `storyline_ids` and `reading_ids` of active associated Records.

### 7.4.3 story_person_search

**Signature:** `story_person_search(p_filter jsonb)`

**Purpose:** Find existing Story Persons while the user tells a Story.

**Supported p_filter fields:** `keyword`, `gender`, `subject_id`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:** `keyword` matches `name`, `aliases` and `description`. Results are ordered by `updated_at` descending.

**Returns:** The search return shape (1.5 item 4) with complete Story Persons.

### 7.4.4 story_person_update

**Signature:** `story_person_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change a Story Person, including its approved Subject association.

**Supported p_changes fields:** `name`, `gender`, `description`, `aliases`, `subject_id`, `metadata`.

**Defaults:** None.

**Behavior:** Follows 1.5 item 6.

**Returns:** The complete Story Person after the update.

### 7.4.5 story_person_delete

**Signature:** `story_person_delete(p_id uuid)`

**Purpose:** Delete one Story Person.

**Defaults:** None.

**Behavior:** Follows 1.5 items 8 and 9.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 7.5 Storyline

Storyline fields: `title`, `content` (required), `occurrence_date`, `occurrence_end_date`, `time_text` (period or relative order wording, such as "before the wedding"), `story_person_ids`, `metadata`. Recorded Time is `created_at` and is distinct from occurrence time.

### 7.5.1 storyline_create

**Signature:** `storyline_create(p_input jsonb)`

**Purpose:** Save one narrative happening, development or relationship statement at an approved Story Context Cutoff.

**Required p_input fields:** `content`.

**Supported p_input fields:** `title`, `content`, `occurrence_date`, `occurrence_end_date`, `time_text`, `story_person_ids`, `metadata`.

**Defaults:** `story_person_ids = []`, `metadata = {}`. Unknown dates stay `null`.

**Behavior:**
1. Every `story_person_ids` value is an active Story Person (1.5 item 14).
2. A Storyline that describes the same matter as a Personal Event links to it with 4.5.1.
3. `occurrence_date` and `occurrence_end_date` are stored as supplied. The function does not compare them.

**Returns:** The complete Storyline.

### 7.5.2 storyline_read

**Signature:** `storyline_read(p_id uuid)`

**Purpose:** Read one Storyline.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3.

**Returns:** The complete Storyline plus `"links": [...]` (4.5.3).

### 7.5.3 storyline_search

**Signature:** `storyline_search(p_filter jsonb)`

**Purpose:** Retrieve Storylines through confirmed Story Persons.

**Supported p_filter fields:** `story_person_ids`, `person_match`, `keyword`, `from_date`, `to_date`, `include_deleted`, `limit`, `offset`.

**Defaults:** `person_match = "any"`, `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:**
1. `person_match = "any"` returns Storylines with at least one supplied Story Person. `person_match = "all"` returns Storylines with every supplied Story Person. Any other value returns "invalid input".
2. Each result holds `matched_person_ids`. The Agent uses it to tell shared, subgroup and individual Storylines apart. Without `story_person_ids`, `matched_person_ids` is `[]`.
3. `keyword` matches `title`, `content` and `time_text`.
4. `from_date` and `to_date` filter `occurrence_date` inclusively. Storylines with unknown `occurrence_date` match only when no date filter is supplied.
5. Results are ordered by `occurrence_date` descending with `null` last, then `created_at` descending, then `id` ascending.

**Returns:** The search return shape (1.5 item 4) with complete Storylines and `matched_person_ids`.

### 7.5.4 storyline_update

**Signature:** `storyline_update(p_id uuid, p_changes jsonb)`

**Purpose:** Add details to a confirmed Storyline or replace incorrect content with the user's corrected information.

**Supported p_changes fields:** `title`, `content`, `occurrence_date`, `occurrence_end_date`, `time_text`, `story_person_ids`, `metadata`.

**Defaults:** None.

**Behavior:** The Storyline keeps only its latest content, with no correction history.

**Returns:** The complete Storyline after the update.

### 7.5.5 storyline_delete

**Signature:** `storyline_delete(p_id uuid)`

**Purpose:** Delete one Storyline.

**Defaults:** None.

**Behavior:** Follows 1.5 items 8 and 9. Reading Remark entries keep their `storyline_id` text reference.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

# 8. Communication Assistant

Communication Assistant keeps Profiles, Audience inheritance, current Communication Rules and finalized Message History. It keeps the message and rule lifecycle taken over from V1.

Communication Profile fields: `profile_key` (required, unique), `profile_type` (`person`, `group` or `audience`), `name` (required), `description`, `aliases` (text array), `person_subject_id`, `metadata`.

Communication Rule fields: `profile_id` (`null` = Global scope), `language_mode` (`null` = language-neutral), `dimension`, `rule_key`, `rule_text`, `metadata`. One current Rule exists per `profile_id`, `language_mode`, `dimension` and `rule_key`.

Message History fields: `profile_id`, `message_text`, `language_mode`, `platform`, `intent`, `message_mode`, `metadata`, `finalized_at`.

`profile_key` is the stable Agent-facing key of a Profile. `aliases` holds other names of the Profile. `intent` and `message_mode` are optional free text that the Agent sets to describe a message. Apart from the uniqueness of `profile_key`, the functions store these four fields as supplied without further rules.

## 8.1 Profiles

### 8.1.1 communication_profile_create

**Signature:** `communication_profile_create(p_input jsonb)`

**Purpose:** Create a Person, Group or Audience Profile.

**Required p_input fields:** `profile_key`, `profile_type`, `name`. `person_subject_id` when `profile_type = "person"`.

**Supported p_input fields:** `profile_key`, `profile_type`, `name`, `description`, `aliases`, `person_subject_id`, `metadata`.

**Defaults:** `aliases = []`, `metadata = {}`.

**Behavior:**
1. A Person Profile identifies exactly one active Subject, approved by the user.
2. A Subject has at most one active Person Profile. A second one returns "invalid relationship".
3. A Group or Audience Profile has no `person_subject_id`. A supplied `person_subject_id` on a Group or Audience returns "invalid input".

**Returns:** The complete Profile.

### 8.1.2 communication_profile_read

**Signature:** `communication_profile_read(p_id uuid)`

**Purpose:** Read one Profile by exact ID.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3.

**Returns:** The complete Profile plus `parent_profiles`: `[ { "profile_id", "name", "priority" } ]`.

### 8.1.3 communication_profile_search

**Signature:** `communication_profile_search(p_filter jsonb)`

**Purpose:** Find Profiles, including the Person Profile of a Subject.

**Supported p_filter fields:** `keyword`, `profile_type`, `person_subject_id`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:** `keyword` matches `name`, `profile_key`, `description` and `aliases`.

**Returns:** The search return shape (1.5 item 4) with complete Profiles.

### 8.1.4 communication_profile_update

**Signature:** `communication_profile_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change a Profile, including a user-confirmed change of its Person Subject.

**Supported p_changes fields:** `profile_key`, `name`, `description`, `aliases`, `person_subject_id`, `metadata`.

**Defaults:** None.

**Behavior:**
1. `profile_type` is not a change field.
2. A Person Profile keeps exactly one `person_subject_id`. `null` returns "invalid input".
3. The 8.1.1 uniqueness rule applies.
4. Rules and Message History stay with the Profile.

**Returns:** The complete Profile after the update.

### 8.1.5 communication_profile_delete

**Signature:** `communication_profile_delete(p_id uuid)`

**Purpose:** Delete one Profile, which also ends its Person Subject link.

**Defaults:** None.

**Behavior:** Follows 1.5 items 8 and 9. Its Rules stop applying. Its Message History stays stored.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

### 8.1.6 communication_profile_membership_set

**Signature:** `communication_profile_membership_set(p_child_profile_id uuid, p_parent_profile_id uuid, p_priority integer default 0, p_metadata jsonb default '{}')`

**Purpose:** Create or update an inheritance from a Profile to an Audience.

**Defaults:** `p_priority = 0`, `p_metadata = {}`.

**Behavior:**
1. The child is an active Person, Group or Audience Profile. The parent is an active Audience Profile (1.5 item 14). A parent of another Profile type returns "invalid relationship".
2. Self-membership and inheritance cycles return "invalid relationship".
3. Membership does not establish Group participants or Subject identity.
4. An Audience that inherits from another Audience adds one inheritance level. The nearer level wins in Rule resolution (8.2.4 item 2).

**Returns:** `{ "child_profile_id", "parent_profile_id", "priority", "metadata", "created_at", "updated_at" }`.

### 8.1.7 communication_profile_membership_remove

**Signature:** `communication_profile_membership_remove(p_child_profile_id uuid, p_parent_profile_id uuid)`

**Purpose:** Remove one inheritance.

**Defaults:** None.

**Behavior:** The function physically removes the membership.

**Returns:** `{ "removed": boolean }`.

## 8.2 Rules

### 8.2.1 communication_rule_upsert

**Signature:** `communication_rule_upsert(p_input jsonb)`

**Purpose:** Create a current Rule or update an existing current Rule.

**Required p_input fields:** For create: `dimension`, `rule_key`, `rule_text`. For update: `id`.

**Supported p_input fields:** `id`, `profile_id`, `language_mode`, `dimension`, `rule_key`, `rule_text`, `metadata`.

**Defaults:** `profile_id = null` (Global), `language_mode = null` (neutral), `metadata = {}`.

**Behavior:**
1. Without `id`, an existing Rule with the same `profile_id`, `language_mode`, `dimension` and `rule_key` is updated. Otherwise a new Rule is created.
2. With `id`, the supplied fields replace that Rule's values.
3. A Rule keeps only its latest text.

**Returns:** The complete Rule plus `"action": "created"` or `"updated"`.

### 8.2.2 communication_rule_delete

**Signature:** `communication_rule_delete(p_id uuid)`

**Purpose:** Remove a Rule that is no longer part of the latest Rule set.

**Defaults:** None.

**Behavior:** The function physically removes the Rule. No Rule history is kept.

**Returns:** `{ "id": uuid, "removed": boolean }`.

### 8.2.3 communication_rule_state

**Signature:** `communication_rule_state(p_profile_id uuid default null, p_language_mode text default null)`

**Purpose:** Return the raw current Rules that apply to a Profile and Language Mode, for inspection and reconciliation.

**Defaults:** `p_profile_id = null` returns Global Rules only. `p_language_mode = null` returns neutral Rules only.

**Behavior:**
1. The function returns Profile Rules, Rules inherited through every Audience ancestor and Global Rules. With `p_language_mode`, it returns the matching language-specific Rules and the neutral Rules.
2. `depth` and `priority` depend on `scope`:
   - `profile`: `depth = 0` and `priority = null`.
   - `inherited`: `depth` is the inheritance level of the source Audience, from 1. `priority` is its membership priority.
   - `global`: `depth = null` and `priority = null`.

**Returns:** `{ "profile_id", "language_mode", "rules": [ { "id", "dimension", "rule_key", "rule_text", "language_mode", "scope": "profile" | "inherited" | "global", "source_profile_id", "depth", "priority" } ] }`.

### 8.2.4 communication_resolve

**Signature:** `communication_resolve(p_profile_id uuid default null, p_language_mode text default null)`

**Purpose:** Return the Effective Rules for the active Profile and Language Mode.

**Defaults:** As in 8.2.3.

**Behavior:** For each `dimension` and `rule_key`, one Rule wins in this order:
1. The active Profile's own Rule outranks an inherited Rule. An inherited Rule outranks a Global Rule.
2. Among inherited Rules, the nearer inheritance depth wins. At the same depth, the higher membership priority wins.
3. Within the same scope, a Rule with the exact Language Mode outranks a neutral Rule.
4. Cross-key semantic conflicts are left to the Agent.

**Returns:** `{ "profile": <compact Profile or null>, "language_mode": text, "effective_rules": { "<dimension>": [ { "id", "rule_key", "rule_text", "scope", "source_profile_id" } ] } }`.

## 8.3 Messages

### 8.3.1 communication_runtime_context

**Signature:** `communication_runtime_context(p_profile_id uuid default null, p_language_mode text default null, p_platform text default null, p_history_limit integer default 5)`

**Purpose:** Return the Effective Rules and recent finalized messages needed before drafting.

**Defaults:** `p_history_limit = 5`.

**Behavior:**
1. Effective Rules follow 8.2.4.
2. Recent messages are active Message History of the Profile and Language Mode, newest first. With `p_profile_id = null`, they are messages saved without a Profile. With `p_language_mode = null`, they are messages saved without a Language Mode.
3. Messages on `p_platform` rank first when it is supplied. Platform is not a Rule inheritance layer.

**Returns:** `{ "profile", "language_mode", "platform", "effective_rules", "recent_messages": [...] }`.

### 8.3.2 communication_message_finalize

**Signature:** `communication_message_finalize(p_input jsonb)`

**Purpose:** Save one finalized outgoing message together with the consolidated Rule changes.

**Required p_input fields:** `message_text`.

**Supported p_input fields:** `profile_id`, `message_text`, `language_mode`, `platform`, `intent`, `message_mode`, `metadata`, `history_limit`, `rule_changes`.

**Supported `rule_changes` items:** `{ "action": "upsert", ...8.2.1 fields }` and `{ "action": "delete", "id": uuid }`.

**Defaults:** `profile_id = null`, `rule_changes = []`, `history_limit = 5`, `finalized_at` = current time.

**Behavior:**
1. The function saves the message and applies every Rule change in one transaction.
2. The message is saved even when `rule_changes` is empty.
3. The function decides nothing about learning. It applies only the supplied changes.
4. Drafts and abandoned messages are never sent to this function.
5. `rule_changes_applied` holds one item per Rule change, in input order:
   - An upsert returns the complete Rule plus `"action": "created"` or `"updated"`, as in 8.2.1.
   - A delete returns `{ "id": uuid, "action": "deleted", "removed": boolean }`. An unknown Rule ID returns `"removed": false`, and the finalize still saves.

**Returns:** `{ "message": <complete Message History item>, "rule_changes_applied": [...], "runtime_context": <8.3.1 return> }`.

### 8.3.3 communication_message_history_read

**Signature:** `communication_message_history_read(p_id uuid)`

**Purpose:** Read one finalized message.

**Defaults:** None.

**Behavior:** Follows 1.5 item 3.

**Returns:** The complete Message History item.

### 8.3.4 communication_message_history_search

**Signature:** `communication_message_history_search(p_filter jsonb)`

**Purpose:** Search finalized messages for examples or retrieval.

**Supported p_filter fields:** `profile_id`, `language_mode`, `platform`, `intent`, `message_mode`, `keyword`, `from_date`, `to_date`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`.

**Behavior:**
1. Only active messages are returned.
2. `keyword` matches `message_text` and `intent`.
3. `from_date` and `to_date` filter `finalized_at` with the 1.7 item 6 boundaries.
4. Results are ordered by `finalized_at` descending.

**Returns:** The search return shape (1.5 item 4).

### 8.3.5 communication_message_history_delete

**Signature:** `communication_message_history_delete(p_id uuid)`

**Purpose:** Delete one finalized message.

**Defaults:** None.

**Behavior:** Follows 1.5 item 8.

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

   For a Reading, a Subject reached by both a Record link and a Story Person appears once, with `via = record_link` (4.5.3 item 5).
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
