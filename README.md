# LifeOS

LifeOS V2 database. One baseline SQL file builds the `lifeos` schema. The dev project holds no real data and is rebuilt from the baseline until LifeOS goes live.

## Contents

| Path | What it holds |
|---|---|
| `contract/` | The Database Contract, split by Module (M-0022 D8). AI Agents read it to choose which function to call, what to send and what comes back. [`shared.md`](contract/shared.md) holds the configuration, the common rules, Record links, Remarks, Subject and Timeline. Each Module has its own file: [`lifeos-memory.md`](contract/lifeos-memory.md), [`notebook.md`](contract/notebook.md), [`personal-records.md`](contract/personal-records.md), [`financial-records.md`](contract/financial-records.md), [`divination-reflection.md`](contract/divination-reflection.md) and [`communication-assistant.md`](contract/communication-assistant.md). An Agent reads the file of the Module in use together with `shared.md`. |
| `supabase/migrations/` | One baseline file, `20261119000100_lifeos_baseline.sql`. It creates the `lifeos` schema, its tables, the seed Notebooks, every Contract function and the grants. It runs on any Supabase project and changes nothing outside `lifeos`. New migrations start only after LifeOS goes live (M-0022 D6). |
| [`supabase/IMPLEMENTATION-NOTES.md`](supabase/IMPLEMENTATION-NOTES.md) | The SQL implementation notes. AI Agents read them before they change the baseline or write a migration. |
| `tests/` | One SQL test file per Module. Each file runs in one transaction that ends in `rollback`. `tests/README.md` lists the coverage. |

## Apply the baseline

Run the baseline once on a project without the `lifeos` schema. With the Supabase CLI:

```bash
npx supabase db query --remote=<project-ref> --yes -f supabase/migrations/20261119000100_lifeos_baseline.sql
```

To call the functions through the Supabase API, add `lifeos` to the project's Exposed schemas in the API settings.

## Run the tests

```bash
for f in tests/*.sql; do npx supabase db query --remote=<project-ref> --yes -f "$f"; done
```

Each file returns one result row per test with PASS or FAIL.
