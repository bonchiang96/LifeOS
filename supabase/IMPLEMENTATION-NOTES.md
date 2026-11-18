# LifeOS SQL Implementation Notes

An AI Agent reads this file before it writes or changes a migration in `supabase/migrations/`, to keep the database consistent.

## 1. Contract and schema

1. Implement every Contract function, parameter, default, behavior and return exactly as written.
2. Every Contract object lives in schema `lifeos`. The SQL creates the schema when absent and changes no object outside `lifeos`. The SQL is portable to any Supabase project.
3. The `id` column of each table is a `uuid` from `gen_random_uuid()`. Notebooks use their text `key` as primary key. Join tables use composite keys.
4. Each function name has exactly one signature, because PostgREST resolves functions by name and parameter names.

## 2. Functions and access

5. Contract functions are `SECURITY DEFINER` with `SET search_path = lifeos, pg_temp`.
6. Grant `USAGE` on schema `lifeos` and `EXECUTE` on every Contract function to `anon` and `authenticated`.
7. Revoke `EXECUTE` on internal helper functions from `PUBLIC`, `anon` and `authenticated`.
8. Grant no table to `anon` or `authenticated`. Enable Row Level Security on every table with no policies.

## 3. Tables and constraints

9. `story_person_ids` on Readings and Storylines are stored in join tables.
10. A check constraint on Expense Line `category` uses the 17 Categories.
11. Every stored Remark in a `remarks` array carries a `remark_id` from `gen_random_uuid()`. Every function that stores a Remark assigns it, including create input and `record_add_remark`. Input never supplies it. A migration gives each existing Remark a `remark_id`.

## 4. Seed data

12. The migrations create two Notebooks. The `defaults` Notebook holds the content `currency: MYR`. The `note_types` Notebook holds `Idea`, `Feeling`, `Experience`, `Explanation` and `General`, one per line.

## 5. Migration order

13. Files in `supabase/migrations/` run in name order, one file at a time.
14. A fix to an applied build is a new migration file. It uses `create or replace function` with the same signature.
15. The tests in `tests/` run after all migrations. Each test file ends with a rollback and leaves no data.
16. A migration that creates a new function revokes `EXECUTE` on it from `PUBLIC`, `anon` and `authenticated`. It then grants `EXECUTE` to `anon` and `authenticated` only when the function is a Contract function. `create or replace function` on an existing function keeps its grants.

## 6. Links and search filters

17. `_links` builds every `links` list and the Timeline `subjects`. It returns each Subject once, keyed by Subject `id`. Its fixed `via` order follows Contract 1.5 item 15.
18. Every search filter by a reference ID also checks that the target Record is active. This holds with `include_deleted = true` too. A new search function follows this rule.
19. `record_link_create` is the only function that inserts into `record_links`. It holds every rejected pair. A new function that inserts a Record link applies the same checks.
