# LifeOS

LifeOS V2 database, Build Stage 1.

## Contents

| Path | What it holds |
|---|---|
| `contract/lifeos-database-contract.md` | The Database Contract. AI Agents read it to choose which function to call, what to send and what comes back. |
| `supabase/migrations/` | The migration SQL. It creates the `lifeos` schema, its tables and every Contract function. It runs on any Supabase project and changes nothing outside `lifeos`. |
| [`supabase/IMPLEMENTATION-NOTES.md`](supabase/IMPLEMENTATION-NOTES.md) | The SQL implementation notes. AI Agents read them before they write or change a migration. |
| `tests/` | One SQL test file per Module. Each file runs in one transaction that ends in `rollback`. `tests/README.md` lists the coverage. |

## Apply the migrations

Run the files in `supabase/migrations/` in name order. With the Supabase CLI:

```bash
for f in supabase/migrations/*.sql; do npx supabase db query --remote=<project-ref> --yes -f "$f"; done
```

To call the functions through the Supabase API, add `lifeos` to the project's Exposed schemas in the API settings.

## Run the tests

```bash
for f in tests/*.sql; do npx supabase db query --remote=<project-ref> --yes -f "$f"; done
```

Each file returns one result row per test with PASS or FAIL.
