# LifeOS

LifeOS is a personal operating system. This repo is the LifeOS Plugin, D-0003. It uses the same structure as the AI with ME Plugin (M-0022 D7).

A runtime Agent, such as Claude or ChatGPT, loads the Plugin. It starts with the `lifeos` entry Skill, which connects to the LifeOS Supabase project through the Google Drive file LifeOS Config. The Module Skills then run Personal Records, Financial Records, Communication Assistant and Divination & Reflection through the Contract functions in the `lifeos` schema.

One baseline SQL file builds the `lifeos` schema. The dev project holds no real data and is rebuilt from the baseline until LifeOS goes live.

## Contents

| Path | What it holds |
|---|---|
| `plugin.json`, `.claude-plugin/plugin.json` | The Plugin manifest: name `lifeos`, version, author and repository. |
| `skills/` | One `SKILL.md` per Skill. [`lifeos`](skills/lifeos/SKILL.md) is the entry Skill: LifeOS Config, request routing, Subject, Record links, Remarks, Timeline, LifeOS Memory and Notebook. The Module Skills are [`personal-records`](skills/personal-records/SKILL.md), [`financial-records`](skills/financial-records/SKILL.md), [`communication-assistant`](skills/communication-assistant/SKILL.md) and [`divination-reflection`](skills/divination-reflection/SKILL.md). Each Skill describes the business flows of the LifeOS Knowledge Base and names its Contract file. |
| `contract/` | The Database Contract, split by Module (M-0022 D8). AI Agents read it to choose which function to call, what to send and what comes back. [`shared.md`](contract/shared.md) holds the configuration, the common rules, Record links, Remarks, Subject and Timeline. Each Module has its own file: [`lifeos-memory.md`](contract/lifeos-memory.md), [`notebook.md`](contract/notebook.md), [`personal-records.md`](contract/personal-records.md), [`financial-records.md`](contract/financial-records.md), [`divination-reflection.md`](contract/divination-reflection.md) and [`communication-assistant.md`](contract/communication-assistant.md). An Agent reads the file of the Module in use together with `shared.md`. |
| `supabase/migrations/` | One baseline file, `20261119000100_lifeos_baseline.sql`. It creates the `lifeos` schema, its tables, the seed Notebooks, every Contract function and the grants. It runs on any Supabase project and changes nothing outside `lifeos`. New migrations start only after LifeOS goes live (M-0022 D6). |
| [`supabase/IMPLEMENTATION-NOTES.md`](supabase/IMPLEMENTATION-NOTES.md) | The SQL implementation notes. AI Agents read them before they change the baseline or write a migration. |
| `tests/` | SQL tests that run on the dev project. Each file runs in one transaction that ends in `rollback`. `tests/README.md` lists the Module test coverage. `tests/skills/` holds the Skill flow tests, and `tests/skills/README.md` maps each Knowledge Base flow to its test. |

## Apply the baseline

Run the baseline once on a project without the `lifeos` schema. With the Supabase CLI:

```bash
npx supabase db query --remote=<project-ref> --yes -f supabase/migrations/20261119000100_lifeos_baseline.sql
```

To call the functions through the Supabase API, add `lifeos` to the project's Exposed schemas in the API settings.

## Run the tests

```bash
for f in tests/*.sql tests/skills/*.sql; do [ -e "$f" ] || continue; npx supabase db query --remote=<project-ref> --yes -f "$f"; done
```

Each file returns one result row per test with PASS or FAIL.
