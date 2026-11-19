# LifeOS Database Contract: Personal Records

This file covers the Personal Records Module: Schedule, Event, Observation and Note. The runtime Agent reads it together with [shared.md](shared.md), which holds the configuration, the common rules, Record links, Remarks, Subject and Timeline. Vocabularies come from [notebook.md](notebook.md).

Contents:

- [4. Personal Records](#4-personal-records)
  - [4.1 Schedule](#41-schedule)
  - [4.2 Event](#42-event)
  - [4.3 Observation](#43-observation)
  - [4.4 Note](#44-note)

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
| `time_text` | text | User's timing wording when imprecise ([shared.md 1.7 item 8](shared.md#17-date-and-time-rules)). |
| `location` | text | Planned place. |
| `status` | text | One of `planned`, `occurred`, `missed`, `cancelled`. |
| `series_id` | uuid | Shared Series ID of a repeating matter. `null` for a single Schedule. |
| `series_description` | text | One sentence on how the series occurs. Required when `series_id` is set. |
| `remarks` | jsonb array | [shared.md 1.5 item 10](shared.md#15-common-interface-semantics). |
| `metadata` | jsonb | [shared.md 1.5 item 11](shared.md#15-common-interface-semantics). |

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

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics). The return includes `linked_event_id` and the linked Records of [shared.md 4.5.3](shared.md#453-record_links_read).

**Returns:** The complete Schedule Record plus `"links": [...]` in the [shared.md 4.5.3](shared.md#453-record_links_read) item shape.

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Schedule Records.

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

**Behavior:** Follows [shared.md 1.5 items 8 and 9](shared.md#15-common-interface-semantics). A linked Event keeps its stored `schedule_id`. Its returns show `schedule_id = null`. The deleted Schedule keeps its `status`. While the linked Event is active, it may link to a new Schedule (4.2.2 item 3). When that Event is deleted, 4.2.6 item 2 clears the Event's `schedule_id`, and the deleted Schedule keeps its `status` (4.2.6 item 3).

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
| `remarks` | jsonb array | [shared.md 1.5 item 10](shared.md#15-common-interface-semantics). |
| `metadata` | jsonb | [shared.md 1.5 item 11](shared.md#15-common-interface-semantics). |

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

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics). The return includes `observations` and the linked Records of [shared.md 4.5.3](shared.md#453-record_links_read).

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Event Records.

### 4.2.5 event_update

**Signature:** `event_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change one Event.

**Supported p_changes fields:** `title`, `description`, `occurred_date`, `occurred_time`, `end_date`, `end_time`, `time_text`, `location`, `metadata`.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 6](shared.md#15-common-interface-semantics). `schedule_id` changes only through 4.2.2 and 4.2.6.

**Returns:** The complete Event Record after the update.

### 4.2.6 event_delete

**Signature:** `event_delete(p_id uuid)`

**Purpose:** Delete one Event.

**Defaults:** None.

**Behavior:**
1. The function sets `deleted_at` on the Event.
2. When the Event has `schedule_id`, the function clears `schedule_id`. This removes the link to an active or a deleted Schedule.
3. An active linked Schedule returns to `status = "planned"`. A deleted linked Schedule keeps its `status`.
4. Every other link to the Event stays stored and is ignored ([shared.md 1.5 item 9](shared.md#15-common-interface-semantics)). This includes Observations with this `event_id` and Notes linked through [shared.md 4.5](shared.md#45-record-links).

**Returns:** `{ "id": uuid, "deleted_at": timestamp, "schedule_returned_to_planned": uuid or null }`.
- `schedule_returned_to_planned` is the ID of the Schedule that returned to Planned.
- It is `null` when the Event had no Schedule link or its Schedule is deleted.

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
| `remarks` | jsonb array | [shared.md 1.5 item 10](shared.md#15-common-interface-semantics). |
| `metadata` | jsonb | [shared.md 1.5 item 11](shared.md#15-common-interface-semantics). |

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

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics).

**Returns:** The complete Observation Record plus `"links": [...]` ([shared.md 4.5.3](shared.md#453-record_links_read)).

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Observation Records.

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

**Behavior:** Follows [shared.md 1.5 items 8 and 9](shared.md#15-common-interface-semantics).

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 4.4 Note

A Note preserves independent narrative information.

Note Record fields:

| Field | Type | Meaning |
|---|---|---|
| `note_type` | text, required | A Note Type from the `note_types` Notebook ([notebook.md 3.1](notebook.md#31-notebook_read)), such as Idea, Feeling, Experience, Explanation or General. |
| `title` | text | Optional heading. |
| `content` | text, required | The narrative. |
| `edited_at` | timestamptz | Time of the latest `note_update`. `null` before any edit. |
| `remarks` | jsonb array | [shared.md 1.5 item 10](shared.md#15-common-interface-semantics). |
| `metadata` | jsonb | [shared.md 1.5 item 11](shared.md#15-common-interface-semantics). |

A Note has no Tags. Derived field on every Note return: `note_date`, the Asia/Kuala_Lumpur date of `edited_at` when set, otherwise of `created_at`.

### 4.4.1 note_create

**Signature:** `note_create(p_input jsonb)`

**Purpose:** Record one Note dated on the day the user records it.

**Required p_input fields:** `note_type`, `content`.

**Supported p_input fields:** `note_type`, `title`, `content`, `remarks`, `metadata`.

**Defaults:** `edited_at = null`, `remarks = []`, `metadata = {}`.

**Behavior:**
1. The input accepts no date. The Note's date is its record date.
2. `note_type` is free text. The `note_types` Notebook ([notebook.md 3.1](notebook.md#31-notebook_read)) holds the vocabulary.
3. A feeling about an earlier day is a Note linked to that day's Event with `record_link_create` ([shared.md 4.5.1](shared.md#451-record_link_create)). The Agent creates the Event first with `event_create` when none exists.

**Returns:** The complete Note Record.

### 4.4.2 note_read

**Signature:** `note_read(p_id uuid)`

**Purpose:** Read one Note by exact ID.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics).

**Returns:** The complete Note Record plus `"links": [...]` ([shared.md 4.5.3](shared.md#453-record_links_read)).

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Note Records.

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

**Behavior:** Follows [shared.md 1.5 items 8 and 9](shared.md#15-common-interface-semantics).

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.
