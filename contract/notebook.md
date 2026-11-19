# LifeOS Database Contract: Notebook

This file covers the Notebook Module. The runtime Agent reads it together with [shared.md](shared.md), which holds the configuration and the common rules.

Contents:

- [3. Notebook](#3-notebook)
  - [3.1 notebook_read](#31-notebook_read)
  - [3.2 notebook_list](#32-notebook_list)
  - [3.3 notebook_update](#33-notebook_update)

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

**Returns:** The search return shape ([shared.md 1.5 item 4](shared.md#15-common-interface-semantics)).

## 3.3 notebook_update

**Signature:** `notebook_update(p_key text, p_changes jsonb)`

**Purpose:** Replace the content or name of a Notebook during ordinary Module use.

**Supported p_changes fields:** `name`, `content`.

**Defaults:** None.

**Behavior:**
1. A supplied `content` replaces the whole content. The Agent adds, revises, consolidates, reorganises and removes entries by writing the new full text.
2. When no Notebook has `p_key`, the function initialises it as in 3.1 and then applies the changes.

**Returns:** The complete Notebook after the update.
