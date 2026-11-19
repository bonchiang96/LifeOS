# LifeOS Database Contract: Communication Assistant

This file covers the Communication Assistant Module: Profiles, Rules and Messages. The runtime Agent reads it together with [shared.md](shared.md), which holds the configuration, the common rules, Subject and Timeline.

Contents:

- [8. Communication Assistant](#8-communication-assistant)
  - [8.1 Profiles](#81-profiles)
  - [8.2 Rules](#82-rules)
  - [8.3 Messages](#83-messages)

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

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics).

**Returns:** The complete Profile plus `parent_profiles`: `[ { "profile_id", "name", "priority" } ]`.

### 8.1.3 communication_profile_search

**Signature:** `communication_profile_search(p_filter jsonb)`

**Purpose:** Find Profiles, including the Person Profile of a Subject.

**Supported p_filter fields:** `keyword`, `profile_type`, `person_subject_id`, `include_deleted`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`, `include_deleted = false`.

**Behavior:** `keyword` matches `name`, `profile_key`, `description` and `aliases`.

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Profiles.

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

**Behavior:** Follows [shared.md 1.5 items 8 and 9](shared.md#15-common-interface-semantics). Its Rules stop applying. Its Message History stays stored.

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.

### 8.1.6 communication_profile_membership_set

**Signature:** `communication_profile_membership_set(p_child_profile_id uuid, p_parent_profile_id uuid, p_priority integer default 0, p_metadata jsonb default '{}')`

**Purpose:** Create or update an inheritance from a Profile to an Audience.

**Defaults:** `p_priority = 0`, `p_metadata = {}`.

**Behavior:**
1. The child is an active Person, Group or Audience Profile. The parent is an active Audience Profile ([shared.md 1.5 item 14](shared.md#15-common-interface-semantics)). A parent of another Profile type returns "invalid relationship".
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

### 8.1.8 communication_profile_merge

**Signature:** `communication_profile_merge(p_input jsonb)`

**Purpose:** Move the Rules and Message History of a duplicate Person Profile to the Person Profile that the user keeps.

**Required p_input fields:** `keep_id`, `merge_id`.

**Supported p_input fields:** `keep_id`, `merge_id`.

**Defaults:** None.

**Behavior:**
1. Both Profiles are active Person Profiles ([shared.md 1.5 item 14](shared.md#15-common-interface-semantics)). A Group or Audience Profile returns "invalid relationship".
2. The same ID in `keep_id` and `merge_id` returns "invalid relationship".
3. A Rule conflict exists when both Profiles have a Rule with the same `language_mode`, `dimension` and `rule_key`. A `null` `language_mode` matches only `null`.
4. Any Rule conflict returns "invalid relationship", and nothing moves. Its detail names each conflicting Rule.
5. The Agent resolves each Rule conflict with the user before the call. The user chooses the Rule that stays, and the Agent deletes the other Rule with 8.2.2.
6. The function moves every Rule and every Message History item of `merge_id` to `keep_id`. This includes deleted Message History items.
7. Moved Rules keep every other field. Moved messages keep every other field, including `deleted_at`.
8. The function then deletes `merge_id` under [shared.md 1.5 item 8](shared.md#15-common-interface-semantics). Its memberships and other fields stay stored.
9. All steps run in one transaction.
10. In a merge of two Person Subjects, the Agent calls this function before [shared.md 5.7](shared.md#57-subject_merge).

**Returns:** `{ "profile": <complete kept Profile>, "merged_id": uuid, "deleted_at": timestamp, "moved": { "rules": number, "messages": number } }`.
- `rules` counts the moved Rules.
- `messages` counts the moved Message History items, including deleted ones.

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

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics).

**Returns:** The complete Message History item.

### 8.3.4 communication_message_history_search

**Signature:** `communication_message_history_search(p_filter jsonb)`

**Purpose:** Search finalized messages for examples or retrieval.

**Supported p_filter fields:** `profile_id`, `language_mode`, `platform`, `intent`, `message_mode`, `keyword`, `from_date`, `to_date`, `limit`, `offset`.

**Defaults:** `limit = 20`, `offset = 0`.

**Behavior:**
1. Only active messages are returned.
2. `keyword` matches `message_text` and `intent`.
3. `from_date` and `to_date` filter `finalized_at` with the [shared.md 1.7 item 6](shared.md#17-date-and-time-rules) boundaries.
4. Results are ordered by `finalized_at` descending.

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)).

### 8.3.5 communication_message_history_delete

**Signature:** `communication_message_history_delete(p_id uuid)`

**Purpose:** Delete one finalized message.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 8](shared.md#15-common-interface-semantics).

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.
