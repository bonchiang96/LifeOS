# LifeOS Database Contract: LifeOS Memory

This file covers the LifeOS Memory Module. The runtime Agent reads it together with [shared.md](shared.md), which holds the configuration and the common rules.

Contents:

- [2. LifeOS Memory](#2-lifeos-memory)
  - [2.1 memory_create](#21-memory_create)
  - [2.2 memory_read](#22-memory_read)
  - [2.3 memory_search](#23-memory_search)
  - [2.4 memory_update](#24-memory_update)
  - [2.5 memory_delete](#25-memory_delete)

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

**Behavior:** Follows [shared.md 1.5 item 3](shared.md#15-common-interface-semantics).

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)) with complete Memory Records.

## 2.4 memory_update

**Signature:** `memory_update(p_id uuid, p_changes jsonb)`

**Purpose:** Improve or correct existing Learning, or consolidate overlapping Memories into one.

**Supported p_changes fields:** `title`, `content`, `categories`, `tags`, `metadata`.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 6](shared.md#15-common-interface-semantics). The Memory keeps only its latest content.

**Returns:** The complete Memory Record after the update.

## 2.5 memory_delete

**Signature:** `memory_delete(p_id uuid)`

**Purpose:** Remove a wrong Memory or a Memory merged into another during consolidation.

**Defaults:** None.

**Behavior:** Follows [shared.md 1.5 item 8](shared.md#15-common-interface-semantics).

**Returns:** `{ "id": uuid, "deleted_at": timestamp }`.
