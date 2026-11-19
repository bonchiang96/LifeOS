# LifeOS Database Contract: Divination & Reflection

This file covers the Divination & Reflection Module: Divination Record, Reading, Analysis, Reading Remark, Story Person and Storyline. The runtime Agent reads it together with [shared.md](shared.md), which holds the configuration, the common rules, Record links, Subject and Timeline.

Contents:

- [7. Divination & Reflection](#7-divination--reflection)
  - [7.1 Divination Record and Reading](#71-divination-record-and-reading)
  - [7.2 Analysis](#72-analysis)
  - [7.3 Reading Remark](#73-reading-remark)
  - [7.4 Story Person](#74-story-person)
  - [7.5 Storyline](#75-storyline)

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
| `metadata` | jsonb | [shared.md 1.5 item 11](shared.md#15-common-interface-semantics). |

Analysis fields: `divination_record_id`, `reading_id` (`null` for a combined Analysis of the Divination Record), `source` (required: the AI system, person, application or channel), `overall_outcome` (required), `key_reasoning` (required), `story_context` (optional), `analysis_date` (date), `metadata`. `analysis_date` is the date of the Analysis itself. Timeline shows every Analysis under the `reading_date` of its Reading ([shared.md 9.1 item 8](shared.md#91-timeline)).

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
4. Every `story_person_ids` value is an active Story Person ([shared.md 1.5 item 14](shared.md#15-common-interface-semantics)).
5. No call happens when the user declines the save.

**Returns:** The complete Divination Record with `readings`, each Reading's `analyses`, and `record_analyses`.

### 7.1.2 divination_record_read

**Signature:** `divination_record_read(p_id uuid)`

**Purpose:** Read one complete Divination Record.

**Defaults:** None.

**Behavior:**
1. Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics). The return holds Key Reasoning, Story Context and Reading Remarks for the Agent to show when the user asks.
2. An active Divination Record returns its active Readings and Analyses.
3. A deleted Divination Record returns the Readings and Analyses deleted together with it, each with its `deleted_at`.

**Returns:** The complete Divination Record with `readings`, `analyses`, `record_analyses`, `remark_entries` and each Reading's `"links": [...]` ([shared.md 4.5.3](shared.md#453-record_links_read)).

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)).

### 7.1.4 divination_record_update

**Signature:** `divination_record_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change the descriptive fields of a Divination Record.

**Supported p_changes fields:** `title`, `topic`, `session_date`, `metadata`.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 6](shared.md#15-common-interface-semantics). `session_date` is required, so `null` returns "invalid input". Readings and Analyses stay unchanged. Their Question, Result and Analysis content have no update function.

**Returns:** The complete Divination Record after the update.

### 7.1.5 divination_record_delete

**Signature:** `divination_record_delete(p_id uuid)`

**Purpose:** Delete one Divination Record with its Readings and Analyses.

**Defaults:** None.

**Behavior:** The function sets the same `deleted_at` on the Divination Record, its Readings and its Analyses. Links follow [shared.md 1.5 item 9](shared.md#15-common-interface-semantics).

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
1. The supplied array replaces the Reading's Story Person set. Every value is an active Story Person ([shared.md 1.5 item 14](shared.md#15-common-interface-semantics)). A repeated ID is stored once.
2. The change touches only the association. It is not an edit. The Reading's `updated_at`, Question, Result and Analyses stay unchanged.
3. A Reading has no structured link to a Storyline ([shared.md 4.5](shared.md#45-record-links)).

**Returns:** The complete Reading.

### 7.1.8 reading_delete

**Signature:** `reading_delete(p_id uuid)`

**Purpose:** Delete one Reading and its Reading Analyses.

**Defaults:** None.

**Behavior:** Combined Analyses of the Divination Record stay. Links follow [shared.md 1.5 item 9](shared.md#15-common-interface-semantics).

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

**Behavior:** Follows [shared.md 1.5 item 8](shared.md#15-common-interface-semantics).

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

**Behavior:** A supplied `subject_id` is an active Subject ([shared.md 1.5 item 14](shared.md#15-common-interface-semantics)). The Agent supplies it only after the user approves the association.

**Returns:** The complete Story Person.

### 7.4.2 story_person_read

**Signature:** `story_person_read(p_id uuid)`

**Purpose:** Read one Story Person.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics).

**Returns:** The complete Story Person plus `storyline_ids` and `reading_ids` of active associated Records.

### 7.4.3 story_person_search

**Signature:** `story_person_search(p_filter jsonb)`

**Purpose:** Find existing Story Persons while the user tells a Story.

**Supported p_filter fields:** `keyword`, `gender`, `subject_id`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:** `keyword` matches `name`, `aliases` and `description`. Results are ordered by `updated_at` descending.

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Story Persons.

### 7.4.4 story_person_update

**Signature:** `story_person_update(p_id uuid, p_changes jsonb)`

**Purpose:** Change a Story Person, including its approved Subject association.

**Supported p_changes fields:** `name`, `gender`, `description`, `aliases`, `subject_id`, `metadata`.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 6](shared.md#15-common-interface-semantics).

**Returns:** The complete Story Person after the update.

### 7.4.5 story_person_delete

**Signature:** `story_person_delete(p_id uuid)`

**Purpose:** Delete one Story Person.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 items 8 and 9](shared.md#15-common-interface-semantics).

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

## 7.5 Storyline

Storyline fields: `title`, `content` (required), `occurrence_date`, `occurrence_end_date`, `time_text` (period or relative order wording, such as "before the wedding"), `story_person_ids`, `metadata`. Recorded Time is `created_at` and is distinct from occurrence time.

Storyline date rule:
1. When both dates are present, `occurrence_end_date` is on or after `occurrence_date`. The same day is allowed.
2. An `occurrence_end_date` before `occurrence_date` returns "invalid input".
3. On this error, the Agent asks the user for the correct dates.

### 7.5.1 storyline_create

**Signature:** `storyline_create(p_input jsonb)`

**Purpose:** Save one narrative happening, development or relationship statement at an approved Story Context Cutoff.

**Required p_input fields:** `content`.

**Supported p_input fields:** `title`, `content`, `occurrence_date`, `occurrence_end_date`, `time_text`, `story_person_ids`, `metadata`.

**Defaults:** `story_person_ids = []`, `metadata = {}`. Unknown dates stay `null`.

**Behavior:**
1. Every `story_person_ids` value is an active Story Person ([shared.md 1.5 item 14](shared.md#15-common-interface-semantics)).
2. A Storyline that describes the same matter as a Personal Event links to it with [shared.md 4.5.1](shared.md#451-record_link_create).
3. The dates follow the Storyline date rule (7.5).

**Returns:** The complete Storyline.

### 7.5.2 storyline_read

**Signature:** `storyline_read(p_id uuid)`

**Purpose:** Read one Storyline.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics).

**Returns:** The complete Storyline plus `"links": [...]` ([shared.md 4.5.3](shared.md#453-record_links_read)).

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Storylines and `matched_person_ids`.

### 7.5.4 storyline_update

**Signature:** `storyline_update(p_id uuid, p_changes jsonb)`

**Purpose:** Add details to a confirmed Storyline or replace incorrect content with the user's corrected information.

**Supported p_changes fields:** `title`, `content`, `occurrence_date`, `occurrence_end_date`, `time_text`, `story_person_ids`, `metadata`.

**Defaults:** None.

**Behavior:**
1. The function checks the Storyline date rule (7.5) on the state after the change.
2. The Storyline keeps only its latest content, with no correction history.

**Returns:** The complete Storyline after the update.

### 7.5.5 storyline_delete

**Signature:** `storyline_delete(p_id uuid)`

**Purpose:** Delete one Storyline.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 items 8 and 9](shared.md#15-common-interface-semantics). Reading Remark entries keep their `storyline_id` text reference.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.
