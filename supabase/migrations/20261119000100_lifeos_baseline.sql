-- =============================================================================
-- LifeOS V2 baseline (M-0022 D6)
--
-- One file that builds schema lifeos on a fresh project. It holds the final state of
-- migrations 1 to 14 (20261117000100 to 20261118000300) and M-0022 D4.
--
-- Sections, in dependency order:
--   1. Schema, tables, indexes and Row Level Security.
--   2. Shared helpers.
--   3. LifeOS Memory.          (Chapter 2)
--   4. Notebook, with seed rows. (Chapter 3)
--   5. Personal Records.       (Chapter 4)
--   6. Subject.                (Chapter 5)
--   7. Financial Records.      (Chapter 6)
--   8. Divination & Reflection. (Chapter 7)
--   9. Communication Assistant. (Chapter 8)
--   10. Timeline and Shared Retrieval. (Chapter 9)
--   11. Grants.
--
-- Steps that only fixed stored data are left out: a fresh database has no data.
-- Changes no object outside schema lifeos. Run once on a project without schema lifeos.
-- New migrations start only after LifeOS goes live.
-- Source: LifeOS Database Contract V2 and supabase/IMPLEMENTATION-NOTES.md.
-- =============================================================================

-- =============================================================================
-- 1. Schema, tables, indexes and Row Level Security
-- =============================================================================

create schema if not exists lifeos;

-- -----------------------------------------------------------------------------
-- 1.1 Tables
-- -----------------------------------------------------------------------------

-- Chapter 2: LifeOS Memory
create table if not exists lifeos.memories (
  id          uuid primary key default gen_random_uuid(),
  title       text,
  content     text not null,
  categories  text[] not null default '{}',
  tags        text[] not null default '{}',
  metadata    jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

-- Chapter 3: Notebook
create table if not exists lifeos.notebooks (
  key         text primary key check (key ~ '^[a-z][a-z0-9_]*$'),
  name        text not null,
  content     text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Chapter 5: Subject (created before Personal Records, which reference it)
create table if not exists lifeos.subjects (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  subject_type    text,
  description     text,
  aliases         text[] not null default '{}',
  tags            text[] not null default '{}',
  is_user         boolean not null default false,
  merged_into_id  uuid references lifeos.subjects (id),
  metadata        jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);

create unique index if not exists subjects_one_active_user
  on lifeos.subjects (is_user) where is_user and deleted_at is null;

-- Chapter 4.1: Schedule
create table if not exists lifeos.schedules (
  id                  uuid primary key default gen_random_uuid(),
  title               text not null,
  description         text,
  schedule_case       text check (schedule_case in ('appointment', 'planned_activity', 'deadline', 'expected_activity')),
  planned_date        date not null,
  planned_time        time,
  end_date            date,
  end_time            time,
  time_text           text,
  location            text,
  status              text not null default 'planned' check (status in ('planned', 'occurred', 'missed', 'cancelled')),
  series_id           uuid,
  series_description  text,
  remarks             jsonb not null default '[]'::jsonb check (jsonb_typeof(remarks) = 'array'),
  metadata            jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  constraint schedules_series_description_required check (series_id is null or series_description is not null)
);

create index if not exists schedules_planned_date on lifeos.schedules (planned_date);

create index if not exists schedules_series_id on lifeos.schedules (series_id);

-- Chapter 4.2: Event
create table if not exists lifeos.events (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  description    text,
  occurred_date  date not null,
  occurred_time  time,
  end_date       date,
  end_time       time,
  time_text      text,
  location       text,
  schedule_id    uuid references lifeos.schedules (id),
  planned_date   date,
  planned_time   time,
  remarks        jsonb not null default '[]'::jsonb check (jsonb_typeof(remarks) = 'array'),
  metadata       jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);

create unique index if not exists events_one_active_per_schedule
  on lifeos.events (schedule_id) where schedule_id is not null and deleted_at is null;

create index if not exists events_occurred_date on lifeos.events (occurred_date);

-- Chapter 4.3: Observation
create table if not exists lifeos.observations (
  id                uuid primary key default gen_random_uuid(),
  subject_id        uuid not null references lifeos.subjects (id),
  observation_name  text not null,
  value_numeric     numeric,
  unit              text,
  value_text        text,
  observed_date     date not null,
  observed_time     time,
  time_text         text,
  location          text,
  event_id          uuid references lifeos.events (id),
  remarks           jsonb not null default '[]'::jsonb check (jsonb_typeof(remarks) = 'array'),
  metadata          jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  constraint observations_value_present check (value_numeric is not null or value_text is not null)
);

create index if not exists observations_subject_id on lifeos.observations (subject_id);

create index if not exists observations_event_id on lifeos.observations (event_id);

-- Chapter 4.4: Note
create table if not exists lifeos.notes (
  id          uuid primary key default gen_random_uuid(),
  note_type   text not null,
  title       text,
  content     text not null,
  edited_at   timestamptz,
  remarks     jsonb not null default '[]'::jsonb check (jsonb_typeof(remarks) = 'array'),
  metadata    jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

-- Chapter 4.5: Record links. The pair is stored in a fixed order, so one pair has one row.
create table if not exists lifeos.record_links (
  id             uuid primary key default gen_random_uuid(),
  record_type_a  text not null,
  record_id_a    uuid not null,
  record_type_b  text not null,
  record_id_b    uuid not null,
  created_at     timestamptz not null default now(),
  constraint record_links_pair_unique unique (record_type_a, record_id_a, record_type_b, record_id_b),
  constraint record_links_pair_ordered check ((record_type_a, record_id_a::text) < (record_type_b, record_id_b::text))
);

create index if not exists record_links_b on lifeos.record_links (record_type_b, record_id_b);

-- Chapter 6: Financial Records
create table if not exists lifeos.expenses (
  id                         uuid primary key default gen_random_uuid(),
  expense_type               text not null default 'purchase' check (expense_type in ('purchase', 'refund')),
  transaction_date           date not null,
  transaction_time           time,
  merchant_name              text,
  branch                     text,
  merchant_subject_id        uuid references lifeos.subjects (id),
  seller_name                text,
  payment_method_subject_id  uuid not null references lifeos.subjects (id),
  expense_total              numeric not null,
  currency                   text not null check (currency ~ '^[A-Z]{3}$'),
  refund_of                  uuid references lifeos.expenses (id),
  remarks                    jsonb not null default '[]'::jsonb check (jsonb_typeof(remarks) = 'array'),
  metadata                   jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  deleted_at                 timestamptz,
  constraint expenses_type_shape check (
    (expense_type = 'purchase' and refund_of is null and expense_total >= 0)
    or (expense_type = 'refund' and refund_of is not null and expense_total < 0))
);

create index if not exists expenses_transaction_date on lifeos.expenses (transaction_date);

create index if not exists expenses_refund_of on lifeos.expenses (refund_of);

create table if not exists lifeos.expense_lines (
  id                uuid primary key default gen_random_uuid(),
  expense_id        uuid not null references lifeos.expenses (id) on delete cascade,
  line_no           integer not null check (line_no >= 1),
  line_type         text not null check (line_type in ('item', 'charge', 'adjustment')),
  item_description  text,
  source_item_text  text,
  quantity          numeric not null default 1,
  unit_price        numeric not null,
  line_total        numeric not null,
  category          text check (category in ('food', 'drink', 'transport', 'clothing', 'beauty', 'electronics',
                      'household', 'entertainment', 'medical', 'education', 'travel', 'gift', 'fees', 'rental',
                      'loans', 'discount', 'other')),
  tags              text[] not null default '{}' check (cardinality(tags) <= 10),
  item_subject_id   uuid references lifeos.subjects (id),
  metadata          jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint expense_lines_line_no_unique unique (expense_id, line_no)
);

-- Correction history: each row is the snapshot of one superseded version.
create table if not exists lifeos.expense_versions (
  id                 uuid primary key default gen_random_uuid(),
  expense_id         uuid not null references lifeos.expenses (id),
  version_no         integer not null check (version_no >= 1),
  snapshot           jsonb not null,
  correction_reason  text not null,
  corrected_at       timestamptz not null default now(),
  constraint expense_versions_unique unique (expense_id, version_no)
);

-- Chapter 7: Divination & Reflection
create table if not exists lifeos.divination_records (
  id            uuid primary key default gen_random_uuid(),
  session_date  date not null,
  title         text,
  topic         text,
  metadata      jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);

create table if not exists lifeos.readings (
  id                    uuid primary key default gen_random_uuid(),
  divination_record_id  uuid not null references lifeos.divination_records (id),
  question              text not null,
  method                text not null check (method in ('i_ching', 'tarot')),
  spread_name           text,
  result_text           text not null,
  reading_date          date not null,
  reading_time          time,
  remark_entries        jsonb not null default '[]'::jsonb check (jsonb_typeof(remark_entries) = 'array'),
  metadata              jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);

create index if not exists readings_record on lifeos.readings (divination_record_id);

create table if not exists lifeos.analyses (
  id                    uuid primary key default gen_random_uuid(),
  divination_record_id  uuid not null references lifeos.divination_records (id),
  reading_id            uuid references lifeos.readings (id),
  source                text not null,
  overall_outcome       text not null,
  key_reasoning         text not null,
  story_context         text,
  analysis_date         date not null,
  metadata              jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);

create index if not exists analyses_record on lifeos.analyses (divination_record_id);

create index if not exists analyses_reading on lifeos.analyses (reading_id);

create table if not exists lifeos.story_persons (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  gender       text,
  description  text,
  aliases      text[] not null default '{}',
  subject_id   uuid references lifeos.subjects (id),
  metadata     jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);

create table if not exists lifeos.storylines (
  id                   uuid primary key default gen_random_uuid(),
  title                text,
  content              text not null,
  occurrence_date      date,
  occurrence_end_date  date,
  time_text            text,
  metadata             jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz
);

-- story_person_ids of Readings and Storylines (implementation note 9)
create table if not exists lifeos.reading_story_persons (
  reading_id       uuid not null references lifeos.readings (id),
  story_person_id  uuid not null references lifeos.story_persons (id),
  created_at       timestamptz not null default now(),
  primary key (reading_id, story_person_id)
);

create table if not exists lifeos.storyline_story_persons (
  storyline_id     uuid not null references lifeos.storylines (id),
  story_person_id  uuid not null references lifeos.story_persons (id),
  created_at       timestamptz not null default now(),
  primary key (storyline_id, story_person_id)
);

-- Chapter 8: Communication Assistant
create table if not exists lifeos.communication_profiles (
  id                 uuid primary key default gen_random_uuid(),
  profile_key        text not null,
  profile_type       text not null check (profile_type in ('person', 'group', 'audience')),
  name               text not null,
  description        text,
  aliases            text[] not null default '{}',
  person_subject_id  uuid references lifeos.subjects (id),
  metadata           jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  constraint communication_profiles_person_subject check (
    (profile_type = 'person' and person_subject_id is not null)
    or (profile_type <> 'person' and person_subject_id is null))
);

create unique index if not exists communication_profiles_key_active
  on lifeos.communication_profiles (profile_key) where deleted_at is null;

create unique index if not exists communication_profiles_one_person_profile
  on lifeos.communication_profiles (person_subject_id) where person_subject_id is not null and deleted_at is null;

create table if not exists lifeos.communication_profile_memberships (
  child_profile_id   uuid not null references lifeos.communication_profiles (id),
  parent_profile_id  uuid not null references lifeos.communication_profiles (id),
  priority           integer not null default 0,
  metadata           jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  primary key (child_profile_id, parent_profile_id),
  constraint communication_profile_memberships_no_self check (child_profile_id <> parent_profile_id)
);

create table if not exists lifeos.communication_rules (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid references lifeos.communication_profiles (id),
  language_mode  text,
  dimension      text not null,
  rule_key       text not null,
  rule_text      text not null,
  metadata       jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint communication_rules_one_current unique nulls not distinct (profile_id, language_mode, dimension, rule_key)
);

create table if not exists lifeos.communication_messages (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid references lifeos.communication_profiles (id),
  message_text   text not null,
  language_mode  text,
  platform       text,
  intent         text,
  message_mode   text,
  metadata       jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  finalized_at   timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);

create index if not exists communication_messages_profile on lifeos.communication_messages (profile_id, finalized_at desc);

-- Row Level Security on every table, with no policies (implementation note 8).
alter table lifeos.memories                          enable row level security;

alter table lifeos.notebooks                         enable row level security;

alter table lifeos.subjects                          enable row level security;

alter table lifeos.schedules                         enable row level security;

alter table lifeos.events                            enable row level security;

alter table lifeos.observations                      enable row level security;

alter table lifeos.notes                             enable row level security;

alter table lifeos.record_links                      enable row level security;

alter table lifeos.expenses                          enable row level security;

alter table lifeos.expense_lines                     enable row level security;

alter table lifeos.expense_versions                  enable row level security;

alter table lifeos.divination_records                enable row level security;

alter table lifeos.readings                          enable row level security;

alter table lifeos.analyses                          enable row level security;

alter table lifeos.story_persons                     enable row level security;

alter table lifeos.storylines                        enable row level security;

alter table lifeos.reading_story_persons             enable row level security;

alter table lifeos.storyline_story_persons           enable row level security;

alter table lifeos.communication_profiles            enable row level security;

alter table lifeos.communication_profile_memberships enable row level security;

alter table lifeos.communication_rules               enable row level security;

alter table lifeos.communication_messages            enable row level security;

-- =============================================================================
-- 2. Shared helpers
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 Time
-- -----------------------------------------------------------------------------

-- UTC ISO 8601 text of a timestamptz (Contract 1.7 item 2).
create or replace function lifeos._ts(p timestamptz)
returns text language sql stable set search_path = lifeos, pg_temp
as $$ select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') $$;

-- "Today": the current Asia/Kuala_Lumpur date (Contract 1.7 item 4).
create or replace function lifeos._kl_today()
returns date language sql stable set search_path = lifeos, pg_temp
as $$ select (now() at time zone 'Asia/Kuala_Lumpur')::date $$;

-- Asia/Kuala_Lumpur date and time of a timestamptz (record date, Contract 1.7 item 5).
create or replace function lifeos._kl_date(p timestamptz)
returns date language sql stable set search_path = lifeos, pg_temp
as $$ select (p at time zone 'Asia/Kuala_Lumpur')::date $$;

create or replace function lifeos._kl_time(p timestamptz)
returns time language sql stable set search_path = lifeos, pg_temp
as $$ select (p at time zone 'Asia/Kuala_Lumpur')::time $$;

-- Parses a timestamp text. A value without a UTC offset is read as wall-clock time in p_zone.
create or replace function lifeos._parse_ts(p text, p_zone text)
returns timestamptz language plpgsql stable set search_path = lifeos, pg_temp
as $$
begin
  if p is null then
    return null;
  end if;
  if p ~ '\d{2}:\d{2}(:\d{2}(\.\d+)?)?\s*([Zz]|[+-]\d{2}(:?\d{2})?)$' then
    return p::timestamptz;
  end if;
  return (p::timestamp) at time zone p_zone;
exception when others then
  raise exception 'invalid date' using detail = format('value: %s', p);
end $$;

-- Filter value for a date field: a date, or a timestamp converted to its KL date (Contract 1.7 item 7).
create or replace function lifeos._filter_date(p text)
returns date language plpgsql stable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or btrim(p) = '' then
    return null;
  end if;
  if btrim(p) ~ '^\d{4}-\d{2}-\d{2}$' then
    return btrim(p)::date;
  end if;
  return (lifeos._parse_ts(btrim(p), 'Asia/Kuala_Lumpur') at time zone 'Asia/Kuala_Lumpur')::date;
exception when others then
  raise exception 'invalid date' using detail = format('value: %s', p);
end $$;

-- Lower and upper filter boundaries on a timestamptz field (Contract 1.7 item 6).
create or replace function lifeos._filter_ts_from(p text)
returns timestamptz language plpgsql stable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or btrim(p) = '' then
    return null;
  end if;
  if btrim(p) ~ '^\d{4}-\d{2}-\d{2}$' then
    return (btrim(p)::date)::timestamp at time zone 'Asia/Kuala_Lumpur';
  end if;
  return lifeos._parse_ts(btrim(p), 'Asia/Kuala_Lumpur');
exception when others then
  raise exception 'invalid date' using detail = format('value: %s', p);
end $$;

create or replace function lifeos._filter_ts_to(p text)
returns timestamptz language plpgsql stable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or btrim(p) = '' then
    return null;
  end if;
  if btrim(p) ~ '^\d{4}-\d{2}-\d{2}$' then
    return ((btrim(p)::date)::timestamp + interval '23:59:59.999') at time zone 'Asia/Kuala_Lumpur';
  end if;
  return lifeos._parse_ts(btrim(p), 'Asia/Kuala_Lumpur');
exception when others then
  raise exception 'invalid date' using detail = format('value: %s', p);
end $$;

-- -----------------------------------------------------------------------------
-- 2.2 JSON input validation
-- -----------------------------------------------------------------------------

-- Returns the input as a JSON object. null becomes {}. Any other non-object is "invalid input".
create or replace function lifeos._obj(p jsonb)
returns jsonb language plpgsql immutable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return '{}'::jsonb;
  end if;
  if jsonb_typeof(p) <> 'object' then
    raise exception 'invalid input' using detail = 'a JSON object is required';
  end if;
  return p;
end $$;

-- Raises "unsupported field" when the object holds a key outside p_allowed (Contract 1.5 item 5).
create or replace function lifeos._check_fields(p jsonb, p_allowed text[])
returns void language plpgsql immutable set search_path = lifeos, pg_temp
as $$
declare
  v_key text;
begin
  select k into v_key from jsonb_object_keys(p) k where k <> all (p_allowed) limit 1;
  if v_key is not null then
    raise exception 'unsupported field' using detail = format('field: %s', v_key);
  end if;
end $$;

-- Raises "invalid input" when a required key is missing, null or a blank string.
create or replace function lifeos._require(p jsonb, p_keys text[])
returns void language plpgsql immutable set search_path = lifeos, pg_temp
as $$
declare
  v_key text;
begin
  foreach v_key in array p_keys loop
    if not (p ? v_key)
       or jsonb_typeof(p -> v_key) = 'null'
       or (jsonb_typeof(p -> v_key) = 'string' and btrim(p ->> v_key) = '') then
      raise exception 'invalid input' using detail = format('missing required field: %s', v_key);
    end if;
  end loop;
end $$;

-- Validates p_changes for an update (Contract 1.5 item 6): a non-empty object with supported keys only.
create or replace function lifeos._check_changes(p jsonb, p_allowed text[])
returns jsonb language plpgsql immutable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or jsonb_typeof(p) <> 'object' or p = '{}'::jsonb then
    raise exception 'invalid input' using detail = 'at least one change field is required';
  end if;
  perform lifeos._check_fields(p, p_allowed);
  return p;
end $$;

-- Checks the JSON types of present, non-null keys.
-- Dates and times return "invalid date". Other type errors return "invalid input".
create or replace function lifeos._check_types(
  p          jsonb,
  p_dates    text[] default '{}',
  p_times    text[] default '{}',
  p_nums     text[] default '{}',
  p_uuids    text[] default '{}',
  p_arrays   text[] default '{}',
  p_objects  text[] default '{}',
  p_bools    text[] default '{}',
  p_ints     text[] default '{}')
returns void language plpgsql immutable set search_path = lifeos, pg_temp
as $$
declare
  v_key text;
  v_dummy text;
begin
  foreach v_key in array p_dates loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' then
      begin
        if jsonb_typeof(p -> v_key) <> 'string' then
          raise exception 'x';
        end if;
        v_dummy := ((p ->> v_key)::date)::text;
      exception when others then
        raise exception 'invalid date' using detail = format('field: %s', v_key);
      end;
    end if;
  end loop;
  foreach v_key in array p_times loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' then
      begin
        if jsonb_typeof(p -> v_key) <> 'string' then
          raise exception 'x';
        end if;
        v_dummy := ((p ->> v_key)::time)::text;
      exception when others then
        raise exception 'invalid date' using detail = format('field: %s', v_key);
      end;
    end if;
  end loop;
  foreach v_key in array p_nums loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' then
      begin
        if jsonb_typeof(p -> v_key) not in ('number', 'string') then
          raise exception 'x';
        end if;
        v_dummy := ((p ->> v_key)::numeric)::text;
      exception when others then
        raise exception 'invalid input' using detail = format('field %s must be a number', v_key);
      end;
    end if;
  end loop;
  foreach v_key in array p_ints loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' then
      begin
        v_dummy := ((p ->> v_key)::integer)::text;
      exception when others then
        raise exception 'invalid input' using detail = format('field %s must be an integer', v_key);
      end;
    end if;
  end loop;
  foreach v_key in array p_uuids loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' then
      begin
        if jsonb_typeof(p -> v_key) <> 'string' then
          raise exception 'x';
        end if;
        v_dummy := ((p ->> v_key)::uuid)::text;
      exception when others then
        raise exception 'invalid input' using detail = format('field %s must be a uuid', v_key);
      end;
    end if;
  end loop;
  foreach v_key in array p_arrays loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' then
      if jsonb_typeof(p -> v_key) <> 'array'
         or exists (select 1 from jsonb_array_elements(p -> v_key) e where jsonb_typeof(e) <> 'string') then
        raise exception 'invalid input' using detail = format('field %s must be an array of text', v_key);
      end if;
    end if;
  end loop;
  foreach v_key in array p_objects loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' and jsonb_typeof(p -> v_key) <> 'object' then
      raise exception 'invalid input' using detail = format('field %s must be a JSON object', v_key);
    end if;
  end loop;
  foreach v_key in array p_bools loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'null' and jsonb_typeof(p -> v_key) <> 'boolean' then
      raise exception 'invalid input' using detail = format('field %s must be true or false', v_key);
    end if;
  end loop;
end $$;

-- Prepares update changes: required fields cannot be cleared, cleared arrays become [] and cleared objects {}.
create or replace function lifeos._prep_changes(
  p           jsonb,
  p_required  text[] default '{}',
  p_arrays    text[] default '{}',
  p_objects   text[] default '{}')
returns jsonb language plpgsql immutable set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := p;
  v_key text;
begin
  foreach v_key in array p_required loop
    if v ? v_key and (jsonb_typeof(v -> v_key) = 'null'
                      or (jsonb_typeof(v -> v_key) = 'string' and btrim(v ->> v_key) = '')) then
      raise exception 'invalid input' using detail = format('field %s cannot be cleared', v_key);
    end if;
  end loop;
  foreach v_key in array p_arrays loop
    if v ? v_key and jsonb_typeof(v -> v_key) = 'null' then
      v := jsonb_set(v, array[v_key], '[]'::jsonb);
    end if;
  end loop;
  foreach v_key in array p_objects loop
    if v ? v_key and jsonb_typeof(v -> v_key) = 'null' then
      v := jsonb_set(v, array[v_key], '{}'::jsonb);
    end if;
  end loop;
  return v;
end $$;

-- Removes top-level null values, so column defaults apply on insert.
create or replace function lifeos._strip_top_nulls(p jsonb)
returns jsonb language sql immutable set search_path = lifeos, pg_temp
as $$
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
  from jsonb_each(coalesce(p, '{}'::jsonb)) e
  where jsonb_typeof(e.value) <> 'null'
$$;

-- Text list from a JSON string or array of strings. null stays null.
create or replace function lifeos._text_list(p jsonb)
returns text[] language plpgsql immutable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p) = 'string' then
    return array[p #>> '{}'];
  end if;
  if jsonb_typeof(p) = 'array'
     and not exists (select 1 from jsonb_array_elements(p) e where jsonb_typeof(e) <> 'string') then
    return array(select jsonb_array_elements_text(p));
  end if;
  raise exception 'invalid input' using detail = 'a text or an array of text is required';
end $$;

-- uuid list from a JSON array of uuid strings.
create or replace function lifeos._uuid_list(p jsonb)
returns uuid[] language plpgsql immutable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return '{}'::uuid[];
  end if;
  if jsonb_typeof(p) <> 'array' then
    raise exception 'invalid input' using detail = 'an array of uuid is required';
  end if;
  return array(select distinct e::uuid from jsonb_array_elements_text(p) e);
exception when invalid_text_representation then
  raise exception 'invalid input' using detail = 'an array of uuid is required';
end $$;

-- -----------------------------------------------------------------------------
-- 2.3 Search paging (Contract 1.5 item 4)
-- -----------------------------------------------------------------------------

create or replace function lifeos._int_param(p jsonb, p_key text, p_default integer)
returns integer language plpgsql immutable set search_path = lifeos, pg_temp
as $$
declare
  v integer;
begin
  if p is null or not (p ? p_key) or jsonb_typeof(p -> p_key) = 'null' then
    return p_default;
  end if;
  begin
    v := (p ->> p_key)::integer;
  exception when others then
    raise exception 'invalid input' using detail = format('field %s must be an integer', p_key);
  end;
  if v < 0 then
    raise exception 'invalid input' using detail = format('field %s cannot be negative', p_key);
  end if;
  return v;
end $$;

create or replace function lifeos._bool_param(p jsonb, p_key text, p_default boolean)
returns boolean language plpgsql immutable set search_path = lifeos, pg_temp
as $$
begin
  if p is null or not (p ? p_key) or jsonb_typeof(p -> p_key) = 'null' then
    return p_default;
  end if;
  if jsonb_typeof(p -> p_key) = 'boolean' then
    return (p -> p_key)::boolean;
  end if;
  raise exception 'invalid input' using detail = format('field %s must be true or false', p_key);
end $$;

-- ILIKE pattern for keyword (or its alias query). null when no keyword is supplied.
create or replace function lifeos._kw(p jsonb)
returns text language sql immutable set search_path = lifeos, pg_temp
as $$
  select case
    when k is null then null
    else '%' || replace(replace(replace(k, '\', '\\'), '%', '\%'), '_', '\_') || '%'
  end
  from (select coalesce(nullif(btrim(p ->> 'keyword'), ''), nullif(btrim(p ->> 'query'), '')) as k) s
$$;

create or replace function lifeos._search_shape(p_results jsonb, p_limit integer, p_offset integer,
                                                p_include_deleted boolean default null)
returns jsonb language sql immutable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object(
           'results', coalesce(p_results, '[]'::jsonb),
           'returned_count', jsonb_array_length(coalesce(p_results, '[]'::jsonb)),
           'limit', p_limit,
           'offset', p_offset)
         || case when p_include_deleted is null then '{}'::jsonb
                 else jsonb_build_object('include_deleted', p_include_deleted) end
$$;

-- True when any Remark text matches the pattern.
create or replace function lifeos._remarks_match(p_remarks jsonb, p_pattern text)
returns boolean language sql immutable set search_path = lifeos, pg_temp
as $$
  select exists (select 1 from jsonb_array_elements(coalesce(p_remarks, '[]'::jsonb)) e
                 where e ->> 'text' ilike p_pattern)
$$;

-- True when any array value matches the pattern.
create or replace function lifeos._array_match(p_values text[], p_pattern text)
returns boolean language sql immutable set search_path = lifeos, pg_temp
as $$ select exists (select 1 from unnest(coalesce(p_values, '{}'::text[])) x where x ilike p_pattern) $$;

-- -----------------------------------------------------------------------------
-- 2.4 Records
-- -----------------------------------------------------------------------------

-- JSON of a table row, with every system timestamp in UTC ISO 8601.
create or replace function lifeos._row_json(p anyelement)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  j jsonb := to_jsonb(p);
  v_key text;
begin
  foreach v_key in array array['created_at', 'updated_at', 'deleted_at', 'edited_at', 'finalized_at', 'corrected_at'] loop
    if j ? v_key and jsonb_typeof(j -> v_key) <> 'null' then
      j := jsonb_set(j, array[v_key], to_jsonb(lifeos._ts((j ->> v_key)::timestamptz)));
    end if;
  end loop;
  return j;
end $$;

-- Normalises Remarks input (Contract 1.5 item 10).
-- Each Remark gets a remark_id (M-0020 F1).
create or replace function lifeos._remarks_normalize(p jsonb)
returns jsonb language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_out jsonb := '[]'::jsonb;
  e jsonb;
  v_text text;
  v_ts timestamptz;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return v_out;
  end if;
  if jsonb_typeof(p) <> 'array' then
    raise exception 'invalid input' using detail = 'remarks must be an array';
  end if;
  for e in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(e) = 'string' then
      v_text := btrim(e #>> '{}');
      v_ts := now();
    elsif jsonb_typeof(e) = 'object' then
      perform lifeos._check_fields(e, array['text', 'timestamp']);
      v_text := btrim(e ->> 'text');
      if e ? 'timestamp' and jsonb_typeof(e -> 'timestamp') <> 'null' then
        v_ts := lifeos._parse_ts(e ->> 'timestamp', 'UTC');
      else
        v_ts := now();
      end if;
    else
      raise exception 'invalid input' using detail = 'a Remark is a string or an object with text';
    end if;
    if v_text is null or v_text = '' then
      raise exception 'invalid input' using detail = 'a Remark needs non-empty text';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('remark_id', gen_random_uuid(),
                                                           'timestamp', lifeos._ts(v_ts), 'text', v_text));
  end loop;
  return v_out;
end $$;

-- Inserts one row from JSON. Keys that are not columns are ignored. Missing columns take their defaults.
create or replace function lifeos._insert_row(p_table text, p_values jsonb)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_cols text;
  v_sel text;
  v_id uuid;
begin
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
         string_agg('x.' || quote_ident(a.attname), ', ' order by a.attnum)
    into v_cols, v_sel
  from pg_attribute a
  where a.attrelid = format('lifeos.%I', p_table)::regclass
    and a.attnum > 0 and not a.attisdropped
    and p_values ? a.attname;
  execute format('insert into lifeos.%I (%s) select %s from jsonb_populate_record(null::lifeos.%I, $1) x returning id',
                 p_table, v_cols, v_sel, p_table)
    into v_id using p_values;
  return v_id;
end $$;

-- Updates the supplied columns of one row and sets updated_at. id and created_at never change.
create or replace function lifeos._update_row(p_table text, p_id uuid, p_values jsonb)
returns void language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_set text;
begin
  select string_agg(format('%1$I = x.%1$I', a.attname), ', ' order by a.attnum)
    into v_set
  from pg_attribute a
  where a.attrelid = format('lifeos.%I', p_table)::regclass
    and a.attnum > 0 and not a.attisdropped
    and a.attname not in ('id', 'created_at', 'updated_at')
    and p_values ? a.attname;
  if v_set is null then
    execute format('update lifeos.%I set updated_at = now() where id = $1', p_table) using p_id;
  else
    execute format('update lifeos.%I t set updated_at = now(), %s from jsonb_populate_record(null::lifeos.%I, $1) x where t.id = $2',
                   p_table, v_set, p_table)
      using p_values, p_id;
  end if;
end $$;

-- Raises "record not found" or "record deleted" unless the row exists and is active.
create or replace function lifeos._require_active(p_table text, p_id uuid)
returns void language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_found boolean;
  v_deleted timestamptz;
begin
  execute format('select true, deleted_at from lifeos.%I where id = $1', p_table)
    into v_found, v_deleted using p_id;
  if v_found is null then
    raise exception 'record not found' using detail = format('%s %s', p_table, p_id);
  end if;
  if v_deleted is not null then
    raise exception 'record deleted' using detail = format('%s %s', p_table, p_id);
  end if;
end $$;

-- Soft delete (Contract 1.5 item 8). A repeated delete returns the existing deleted_at.
create or replace function lifeos._soft_delete(p_table text, p_id uuid)
returns jsonb language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_deleted timestamptz;
begin
  execute format('update lifeos.%I set updated_at = case when deleted_at is null then now() else updated_at end, '
                 'deleted_at = coalesce(deleted_at, now()) where id = $1 returning deleted_at', p_table)
    into v_deleted using p_id;
  if v_deleted is null then
    raise exception 'record not found';
  end if;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_deleted));
end $$;

-- Table of a shared Record Type name (Contract 1.5 item 2). Unknown names return "invalid input".
create or replace function lifeos._record_table(p_record_type text)
returns text language plpgsql immutable set search_path = lifeos, pg_temp
as $$
begin
  return case p_record_type
    when 'schedule' then 'schedules'
    when 'event' then 'events'
    when 'observation' then 'observations'
    when 'note' then 'notes'
    when 'expense' then 'expenses'
    when 'subject' then 'subjects'
    when 'divination_record' then 'divination_records'
    when 'reading' then 'readings'
    when 'storyline' then 'storylines'
    else null
  end;
end $$;

-- The 17 adopted Expense Categories, in Contract order (6.10).
create or replace function lifeos._expense_categories()
returns text[] language sql immutable set search_path = lifeos, pg_temp
as $$
  select array['food', 'drink', 'transport', 'clothing', 'beauty', 'electronics', 'household', 'entertainment',
               'medical', 'education', 'travel', 'gift', 'fees', 'rental', 'loans', 'discount', 'other']
$$;

-- =============================================================================
-- 3. LifeOS Memory (Contract Chapter 2)
-- =============================================================================

create or replace function lifeos.memory_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
  r lifeos.memories;
begin
  perform lifeos._check_fields(v, array['title', 'content', 'categories', 'tags', 'metadata']);
  perform lifeos._require(v, array['content']);
  perform lifeos._check_types(v, p_arrays => array['categories', 'tags'], p_objects => array['metadata']);
  v_id := lifeos._insert_row('memories', lifeos._strip_top_nulls(v));
  select * into r from lifeos.memories where id = v_id;
  return lifeos._row_json(r);
end $$;

create or replace function lifeos.memory_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  r lifeos.memories;
begin
  select * into r from lifeos.memories where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._row_json(r);
end $$;

create or replace function lifeos.memory_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_cats text[];
  v_tags text[];
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'categories', 'tags', 'include_deleted', 'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_cats := lifeos._text_list(f -> 'categories');
  v_tags := lifeos._text_list(f -> 'tags');

  select coalesce(jsonb_agg(lifeos._row_json(m) order by m.updated_at desc, m.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.memories m
    where (v_inc or m.deleted_at is null)
      and (v_pat is null or m.title ilike v_pat or m.content ilike v_pat)
      and (v_cats is null or m.categories && v_cats)
      and (v_tags is null or m.tags && v_tags)
    order by m.updated_at desc, m.id
    limit v_limit offset v_offset
  ) m;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.memory_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  r lifeos.memories;
begin
  select * into r from lifeos.memories where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'content', 'categories', 'tags', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['categories', 'tags'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['content'], p_arrays => array['categories', 'tags'],
                            p_objects => array['metadata']);
  perform lifeos._update_row('memories', p_id, v);
  select * into r from lifeos.memories where id = p_id;
  return lifeos._row_json(r);
end $$;

create or replace function lifeos.memory_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('memories', p_id);
end $$;

-- =============================================================================
-- 4. Notebook (Contract Chapter 3)
-- =============================================================================

create or replace function lifeos._notebook_json(n lifeos.notebooks)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('key', n.key, 'name', n.name, 'content', n.content,
                            'created_at', lifeos._ts(n.created_at), 'updated_at', lifeos._ts(n.updated_at))
$$;

-- Creates the Notebook when absent (Contract 3.1 items 2 to 4). Returns true when this call created it.
-- A new note_types Notebook starts with the five default Note Types, one per line (M-0018 D4).
-- language_modes and platforms are catalog Notebooks that start empty (M-0023 D12).
create or replace function lifeos._notebook_init(p_key text, p_name text)
returns boolean language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_name text;
  v_rows integer;
begin
  if p_key is null or p_key !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'invalid input' using detail = 'a Notebook key matches ^[a-z][a-z0-9_]*$';
  end if;
  v_name := coalesce(nullif(btrim(p_name), ''),
    case p_key
      when 'subject_types' then 'Subject Types'
      when 'subject_tags' then 'Subject Tags'
      when 'expense_tags' then 'Expense Tags'
      when 'note_types' then 'Note Types'
      when 'defaults' then 'Defaults'
      when 'language_modes' then 'Language Modes'
      when 'platforms' then 'Platforms'
      else p_key
    end);
  insert into lifeos.notebooks (key, name, content)
  values (p_key, v_name, case p_key
                           when 'defaults' then 'currency: MYR'
                           when 'note_types' then E'Idea\nFeeling\nExperience\nExplanation\nGeneral'
                           else '' end)
  on conflict (key) do nothing;
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end $$;

create or replace function lifeos.notebook_read(p_key text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_created boolean;
  n lifeos.notebooks;
begin
  v_created := lifeos._notebook_init(p_key, p_name);
  select * into n from lifeos.notebooks where key = p_key;
  return lifeos._notebook_json(n) || jsonb_build_object('initialised', v_created);
end $$;

create or replace function lifeos.notebook_list(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_pat text;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_pat := lifeos._kw(f);

  select coalesce(jsonb_agg(jsonb_build_object('key', n.key, 'name', n.name,
                                               'content_length', char_length(n.content),
                                               'updated_at', lifeos._ts(n.updated_at)) order by n.key), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.notebooks n
    where v_pat is null or n.key ilike v_pat or n.name ilike v_pat or n.content ilike v_pat
    order by n.key
    limit v_limit offset v_offset
  ) n;

  return lifeos._search_shape(v_res, v_limit, v_offset);
end $$;

create or replace function lifeos.notebook_update(p_key text, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  n lifeos.notebooks;
begin
  v := lifeos._check_changes(p_changes, array['name', 'content']);
  if v ? 'name' and (jsonb_typeof(v -> 'name') <> 'string' or btrim(v ->> 'name') = '') then
    raise exception 'invalid input' using detail = 'name must be non-empty text';
  end if;
  if v ? 'content' and jsonb_typeof(v -> 'content') <> 'string' then
    raise exception 'invalid input' using detail = 'content must be text';
  end if;
  perform lifeos._notebook_init(p_key, null);
  update lifeos.notebooks
     set name = case when v ? 'name' then v ->> 'name' else name end,
         content = case when v ? 'content' then v ->> 'content' else content end,
         updated_at = now()
   where key = p_key
  returning * into n;
  return lifeos._notebook_json(n);
end $$;

-- The defaults Notebook (implementation note 12).
insert into lifeos.notebooks (key, name, content)
values ('defaults', 'Defaults', 'currency: MYR')
on conflict (key) do nothing;

-- The note_types Notebook with the five default Note Types (M-0018 D4, implementation note 12).
insert into lifeos.notebooks (key, name, content)
values ('note_types', 'Note Types', E'Idea\nFeeling\nExperience\nExplanation\nGeneral')
on conflict (key) do nothing;

-- =============================================================================
-- 5. Personal Records (Contract Chapter 4)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Record builders
-- -----------------------------------------------------------------------------

create or replace function lifeos._schedule_json(s lifeos.schedules)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s) || jsonb_build_object('linked_event_id',
    (select e.id from lifeos.events e where e.schedule_id = s.id and e.deleted_at is null limit 1))
$$;

create or replace function lifeos._observation_json(o lifeos.observations)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(o)
    || jsonb_build_object(
         'subject_id', (select x.id from lifeos.subjects x where x.id = o.subject_id and x.deleted_at is null),
         'event_id', (select x.id from lifeos.events x where x.id = o.event_id and x.deleted_at is null))
$$;

create or replace function lifeos._event_json(e lifeos.events)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(e)
    || jsonb_build_object(
         'schedule_id', (select s.id from lifeos.schedules s where s.id = e.schedule_id and s.deleted_at is null),
         'observations', coalesce((
            select jsonb_agg(lifeos._observation_json(o) order by o.observed_date, o.observed_time nulls last, o.created_at)
            from lifeos.observations o where o.event_id = e.id and o.deleted_at is null), '[]'::jsonb))
$$;

create or replace function lifeos._note_json(n lifeos.notes)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(n) || jsonb_build_object('note_date', lifeos._kl_date(coalesce(n.edited_at, n.created_at)))
$$;

-- -----------------------------------------------------------------------------
-- Link helpers (Contract 4.5.3)
-- -----------------------------------------------------------------------------

-- Summary and occurrence date of an active link target. null when the target is missing or deleted.
create or replace function lifeos._target_info(p_type text, p_id uuid)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_summary text;
  v_date date;
  v_found boolean;
begin
  case p_type
    when 'schedule' then
      select true, s.title, s.planned_date into v_found, v_summary, v_date
      from lifeos.schedules s where s.id = p_id and s.deleted_at is null;
    when 'event' then
      select true, e.title, e.occurred_date into v_found, v_summary, v_date
      from lifeos.events e where e.id = p_id and e.deleted_at is null;
    when 'observation' then
      select true,
             o.observation_name || ': ' || coalesce(o.value_numeric::text || coalesce(' ' || o.unit, ''), o.value_text),
             o.observed_date
        into v_found, v_summary, v_date
      from lifeos.observations o where o.id = p_id and o.deleted_at is null;
    when 'note' then
      select true, coalesce(n.title, left(n.content, 200)), lifeos._kl_date(coalesce(n.edited_at, n.created_at))
        into v_found, v_summary, v_date
      from lifeos.notes n where n.id = p_id and n.deleted_at is null;
    when 'expense' then
      select true,
             concat_ws(' ', coalesce(x.merchant_name, case when x.expense_type = 'refund' then 'Refund' else 'Expense' end),
                       x.currency, x.expense_total::text),
             x.transaction_date
        into v_found, v_summary, v_date
      from lifeos.expenses x where x.id = p_id and x.deleted_at is null;
    when 'subject' then
      select true, s.name, null::date into v_found, v_summary, v_date
      from lifeos.subjects s where s.id = p_id and s.deleted_at is null;
    when 'divination_record' then
      select true, coalesce(d.title, d.topic, 'Divination Record'), d.session_date into v_found, v_summary, v_date
      from lifeos.divination_records d where d.id = p_id and d.deleted_at is null;
    when 'reading' then
      select true, left(r.question, 200), r.reading_date into v_found, v_summary, v_date
      from lifeos.readings r join lifeos.divination_records d on d.id = r.divination_record_id
      where r.id = p_id and r.deleted_at is null and d.deleted_at is null;
    when 'storyline' then
      select true, coalesce(s.title, left(s.content, 200)), s.occurrence_date into v_found, v_summary, v_date
      from lifeos.storylines s where s.id = p_id and s.deleted_at is null;
    when 'story_person' then
      select true, s.name, null::date into v_found, v_summary, v_date
      from lifeos.story_persons s where s.id = p_id and s.deleted_at is null;
    when 'communication_profile' then
      select true, p.name, null::date into v_found, v_summary, v_date
      from lifeos.communication_profiles p where p.id = p_id and p.deleted_at is null;
    when 'communication_message' then
      select true, left(m.message_text, 200), lifeos._kl_date(m.finalized_at) into v_found, v_summary, v_date
      from lifeos.communication_messages m where m.id = p_id and m.deleted_at is null;
    else
      return null;
  end case;
  if v_found is null then
    return null;
  end if;
  return jsonb_build_object('summary', v_summary, 'occurrence_date', v_date);
end $$;

-- Every active Record linked to one Record: Record links in both directions and typed reference fields.
-- Each connected Subject appears once, keyed by Subject id. via names the first path in the
-- fixed order of Contract 1.5 item 15 (M-0021 D6).
create or replace function lifeos._links(p_type text, p_id uuid)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  with c(via, record_type, id) as (
    -- Record links, both directions
    select 'record_link',
           case when l.record_type_a = p_type and l.record_id_a = p_id then l.record_type_b else l.record_type_a end,
           case when l.record_type_a = p_type and l.record_id_a = p_id then l.record_id_b else l.record_id_a end
    from lifeos.record_links l
    where (l.record_type_a = p_type and l.record_id_a = p_id) or (l.record_type_b = p_type and l.record_id_b = p_id)
    -- Schedule -> its Event
    union all
    select 'event', 'event', e.id from lifeos.events e where p_type = 'schedule' and e.schedule_id = p_id
    -- Event -> its Schedule and Observations
    union all
    select 'schedule', 'schedule', e.schedule_id from lifeos.events e
    where p_type = 'event' and e.id = p_id and e.schedule_id is not null
    union all
    select 'observation_event', 'observation', o.id from lifeos.observations o where p_type = 'event' and o.event_id = p_id
    -- Observation -> Subject and Event
    union all
    select 'observation_subject', 'subject', o.subject_id from lifeos.observations o where p_type = 'observation' and o.id = p_id
    union all
    select 'observation_event', 'event', o.event_id from lifeos.observations o
    where p_type = 'observation' and o.id = p_id and o.event_id is not null
    -- Expense -> Subjects, original and Refunds
    union all
    select 'payment_method', 'subject', x.payment_method_subject_id from lifeos.expenses x where p_type = 'expense' and x.id = p_id
    union all
    select 'merchant', 'subject', x.merchant_subject_id from lifeos.expenses x
    where p_type = 'expense' and x.id = p_id and x.merchant_subject_id is not null
    union all
    select distinct 'line_item', 'subject', l.item_subject_id from lifeos.expense_lines l
    where p_type = 'expense' and l.expense_id = p_id and l.item_subject_id is not null
    union all
    select 'refund_of', 'expense', x.refund_of from lifeos.expenses x where p_type = 'expense' and x.id = p_id and x.refund_of is not null
    union all
    select 'refund_of', 'expense', x.id from lifeos.expenses x where p_type = 'expense' and x.refund_of = p_id
    -- Subject -> referring Records
    union all
    select 'observation_subject', 'observation', o.id from lifeos.observations o where p_type = 'subject' and o.subject_id = p_id
    union all
    select 'payment_method', 'expense', x.id from lifeos.expenses x where p_type = 'subject' and x.payment_method_subject_id = p_id
    union all
    select 'merchant', 'expense', x.id from lifeos.expenses x where p_type = 'subject' and x.merchant_subject_id = p_id
    union all
    select distinct 'line_item', 'expense', l.expense_id from lifeos.expense_lines l where p_type = 'subject' and l.item_subject_id = p_id
    union all
    select 'story_person_subject', 'story_person', s.id from lifeos.story_persons s where p_type = 'subject' and s.subject_id = p_id
    union all
    select 'person_profile_subject', 'communication_profile', p.id from lifeos.communication_profiles p
    where p_type = 'subject' and p.person_subject_id = p_id
    -- Reading and Storyline -> Subjects of their Story Persons
    union all
    select distinct 'story_person_subject', 'subject', sp.subject_id
    from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
    where p_type = 'reading' and rsp.reading_id = p_id and sp.deleted_at is null and sp.subject_id is not null
    union all
    select distinct 'story_person_subject', 'subject', sp.subject_id
    from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
    where p_type = 'storyline' and ssp.storyline_id = p_id and sp.deleted_at is null and sp.subject_id is not null
    -- Communication Message -> Subject of its Person Profile (used by timeline)
    union all
    select 'person_profile_subject', 'subject', p.person_subject_id
    from lifeos.communication_messages m join lifeos.communication_profiles p on p.id = m.profile_id
    where p_type = 'communication_message' and m.id = p_id and p.deleted_at is null and p.person_subject_id is not null
  ), d(via, record_type, id) as (
    -- Every target that is not a Subject stays as it is.
    select c.via, c.record_type, c.id from c where c.record_type <> 'subject'
    union all
    -- D6: one row per Subject id, with the first path in the fixed order.
    (select distinct on (c.id) c.via, c.record_type, c.id
    from c where c.record_type = 'subject'
    order by c.id, case c.via
                     when 'record_link' then 1
                     when 'observation_subject' then 2
                     when 'payment_method' then 3
                     when 'merchant' then 4
                     when 'line_item' then 5
                     when 'story_person_subject' then 6
                     when 'person_profile_subject' then 7
                     else 8 end)
  )
  select coalesce(jsonb_agg(jsonb_build_object('via', d.via, 'record_type', d.record_type, 'id', d.id,
                                               'summary', t.info ->> 'summary',
                                               'occurrence_date', t.info -> 'occurrence_date')
                            order by d.via, d.record_type, t.info ->> 'occurrence_date' desc nulls last, d.id), '[]'::jsonb)
  from d cross join lateral (select lifeos._target_info(d.record_type, d.id) as info) t
  where t.info is not null
$$;

-- Complete Record of any Record Type, or null when the ID is unknown.
create or replace function lifeos._record_json(p_type text, p_id uuid)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
begin
  case p_type
    when 'schedule' then select lifeos._schedule_json(s) into v from lifeos.schedules s where s.id = p_id;
    when 'event' then select lifeos._event_json(e) into v from lifeos.events e where e.id = p_id;
    when 'observation' then select lifeos._observation_json(o) into v from lifeos.observations o where o.id = p_id;
    when 'note' then select lifeos._note_json(n) into v from lifeos.notes n where n.id = p_id;
    when 'expense' then select lifeos._expense_json(x) into v from lifeos.expenses x where x.id = p_id;
    when 'subject' then select lifeos._subject_json(s) into v from lifeos.subjects s where s.id = p_id;
    when 'divination_record' then
      select lifeos._divination_json(d, false) into v from lifeos.divination_records d where d.id = p_id;
    when 'reading' then select lifeos._reading_json(r, false) into v from lifeos.readings r where r.id = p_id;
    when 'storyline' then select lifeos._storyline_json(s) into v from lifeos.storylines s where s.id = p_id;
    when 'communication_message' then
      select lifeos._message_json(m) into v from lifeos.communication_messages m where m.id = p_id;
    else
      v := null;
  end case;
  return v;
end $$;

-- -----------------------------------------------------------------------------
-- 4.1 Schedule
-- -----------------------------------------------------------------------------

-- Validates and inserts one Schedule (Contract 4.1.1). Returns the new ID.
create or replace function lifeos._schedule_insert(p_input jsonb)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_desc text;
begin
  perform lifeos._check_fields(v, array['title', 'description', 'schedule_case', 'planned_date', 'planned_time',
    'end_date', 'end_time', 'time_text', 'location', 'series_id', 'series_description', 'remarks', 'metadata']);
  perform lifeos._require(v, array['title', 'planned_date']);
  perform lifeos._check_types(v, p_dates => array['planned_date', 'end_date'], p_times => array['planned_time', 'end_time'],
                              p_uuids => array['series_id'], p_objects => array['metadata']);
  if v ? 'schedule_case' and jsonb_typeof(v -> 'schedule_case') <> 'null'
     and v ->> 'schedule_case' not in ('appointment', 'planned_activity', 'deadline', 'expected_activity') then
    raise exception 'invalid input' using detail = 'schedule_case is appointment, planned_activity, deadline or expected_activity';
  end if;
  v := lifeos._strip_top_nulls(v);
  if v ? 'series_description' and btrim(v ->> 'series_description') = '' then
    v := v - 'series_description';
  end if;
  if v ? 'series_id' and not (v ? 'series_description') then
    select s.series_description into v_desc
    from lifeos.schedules s
    where s.series_id = (v ->> 'series_id')::uuid
    order by (s.deleted_at is null) desc, s.planned_date desc, s.created_at desc
    limit 1;
    if v_desc is null then
      raise exception 'invalid input' using detail = 'series_description is required for a new series';
    end if;
    v := v || jsonb_build_object('series_description', v_desc);
  end if;
  v := v || jsonb_build_object('status', 'planned', 'remarks', lifeos._remarks_normalize(v -> 'remarks'));
  return lifeos._insert_row('schedules', v);
end $$;

create or replace function lifeos.schedule_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_input ? 'status' then
    raise exception 'unsupported field' using detail = 'field: status';
  end if;
  v_id := lifeos._schedule_insert(p_input);
  return (select lifeos._schedule_json(s) from lifeos.schedules s where s.id = v_id);
end $$;

create or replace function lifeos.schedule_create_series(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_series uuid;
  v_desc text;
  v_item jsonb;
  v_ids uuid[] := '{}';
begin
  perform lifeos._check_fields(v, array['series_id', 'series_description', 'schedules']);
  perform lifeos._require(v, array['schedules']);
  perform lifeos._check_types(v, p_uuids => array['series_id']);
  if jsonb_typeof(v -> 'schedules') <> 'array' or jsonb_array_length(v -> 'schedules') = 0 then
    raise exception 'invalid input' using detail = 'schedules needs at least one item';
  end if;

  v_series := coalesce(nullif(v ->> 'series_id', '')::uuid, gen_random_uuid());
  v_desc := nullif(btrim(v ->> 'series_description'), '');
  if v_desc is null then
    select s.series_description into v_desc
    from lifeos.schedules s
    where s.series_id = v_series
    order by (s.deleted_at is null) desc, s.planned_date desc, s.created_at desc
    limit 1;
  end if;
  if v_desc is null then
    raise exception 'invalid input' using detail = 'series_description is required for a new series';
  end if;

  for v_item in select value from jsonb_array_elements(v -> 'schedules') loop
    v_item := lifeos._obj(v_item);
    perform lifeos._check_fields(v_item, array['title', 'description', 'schedule_case', 'planned_date', 'planned_time',
      'end_date', 'end_time', 'time_text', 'location', 'remarks', 'metadata']);
    v_ids := v_ids || lifeos._schedule_insert(v_item || jsonb_build_object('series_id', v_series, 'series_description', v_desc));
  end loop;

  return jsonb_build_object(
    'series_id', v_series,
    'series_description', v_desc,
    'schedules', (select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
                  from lifeos.schedules s where s.id = any (v_ids)));
end $$;

create or replace function lifeos.schedule_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.schedules;
begin
  select * into s from lifeos.schedules where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._schedule_json(s) || jsonb_build_object('links', lifeos._links('schedule', p_id));
end $$;

create or replace function lifeos.schedule_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_status text[];
  v_case text;
  v_series uuid;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'status', 'schedule_case', 'series_id', 'from_date', 'to_date',
                                        'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['series_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_status := lifeos._text_list(f -> 'status');
  v_case := nullif(f ->> 'schedule_case', '');
  v_series := (f ->> 'series_id')::uuid;
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at, s.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.schedules s
    where (v_inc or s.deleted_at is null)
      and (v_status is null or s.status = any (v_status))
      and (v_case is null or s.schedule_case = v_case)
      and (v_series is null or s.series_id = v_series)
      and (v_from is null or s.planned_date >= v_from)
      and (v_to is null or s.planned_date <= v_to)
      and (v_pat is null or s.title ilike v_pat or s.description ilike v_pat or s.location ilike v_pat
           or s.series_description ilike v_pat or s.time_text ilike v_pat or lifeos._remarks_match(s.remarks, v_pat))
    order by s.planned_date, s.planned_time nulls last, s.created_at, s.id
    limit v_limit offset v_offset
  ) s;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.schedule_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  s lifeos.schedules;
begin
  select * into s from lifeos.schedules where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'description', 'schedule_case', 'planned_date', 'planned_time',
    'end_date', 'end_time', 'time_text', 'location', 'status', 'series_description', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['planned_date', 'end_date'], p_times => array['planned_time', 'end_time'],
                              p_objects => array['metadata']);
  if v ? 'schedule_case' and jsonb_typeof(v -> 'schedule_case') <> 'null'
     and v ->> 'schedule_case' not in ('appointment', 'planned_activity', 'deadline', 'expected_activity') then
    raise exception 'invalid input' using detail = 'schedule_case is appointment, planned_activity, deadline or expected_activity';
  end if;
  if v ? 'status' then
    if v ->> 'status' is null or v ->> 'status' not in ('planned', 'missed', 'cancelled') then
      raise exception 'invalid input' using detail = 'status accepts planned, missed and cancelled';
    end if;
    if exists (select 1 from lifeos.events e where e.schedule_id = p_id and e.deleted_at is null) then
      raise exception 'invalid relationship' using detail = 'the Schedule has an active linked Event';
    end if;
  end if;
  v := lifeos._prep_changes(v, p_required => array['title', 'planned_date', 'status'], p_objects => array['metadata']);
  perform lifeos._update_row('schedules', p_id, v);
  return (select lifeos._schedule_json(x) from lifeos.schedules x where x.id = p_id);
end $$;

create or replace function lifeos.schedule_update_series(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_changes jsonb;
  v_series uuid;
  v_from date;
  v_ids uuid[];
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['series_id', 'from_date', 'changes']);
  perform lifeos._require(v, array['series_id', 'from_date', 'changes']);
  perform lifeos._check_types(v, p_uuids => array['series_id']);
  v_series := (v ->> 'series_id')::uuid;
  v_from := lifeos._filter_date(v ->> 'from_date');
  v_changes := lifeos._check_changes(v -> 'changes', array['title', 'description', 'schedule_case', 'planned_time',
    'end_time', 'time_text', 'location', 'series_description', 'metadata']);
  perform lifeos._check_types(v_changes, p_times => array['planned_time', 'end_time'], p_objects => array['metadata']);
  if v_changes ? 'schedule_case' and jsonb_typeof(v_changes -> 'schedule_case') <> 'null'
     and v_changes ->> 'schedule_case' not in ('appointment', 'planned_activity', 'deadline', 'expected_activity') then
    raise exception 'invalid input' using detail = 'schedule_case is appointment, planned_activity, deadline or expected_activity';
  end if;
  v_changes := lifeos._prep_changes(v_changes, p_required => array['title', 'series_description'], p_objects => array['metadata']);

  if not exists (select 1 from lifeos.schedules s where s.series_id = v_series) then
    raise exception 'record not found' using detail = 'no Schedule has this series_id';
  end if;

  select coalesce(array_agg(s.id), '{}') into v_ids
  from lifeos.schedules s
  where s.series_id = v_series and s.deleted_at is null and s.status = 'planned' and s.planned_date >= v_from;

  foreach v_id in array v_ids loop
    perform lifeos._update_row('schedules', v_id, v_changes);
  end loop;

  return jsonb_build_object(
    'series_id', v_series,
    'updated_count', cardinality(v_ids),
    'schedules', (select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
                  from lifeos.schedules s where s.id = any (v_ids)));
end $$;

create or replace function lifeos.schedule_stop_series(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_series uuid;
  v_from date;
  v_ids uuid[];
begin
  perform lifeos._check_fields(v, array['series_id', 'from_date']);
  perform lifeos._require(v, array['series_id', 'from_date']);
  perform lifeos._check_types(v, p_uuids => array['series_id']);
  v_series := (v ->> 'series_id')::uuid;
  v_from := lifeos._filter_date(v ->> 'from_date');

  if not exists (select 1 from lifeos.schedules s where s.series_id = v_series) then
    raise exception 'record not found' using detail = 'no Schedule has this series_id';
  end if;

  with u as (
    update lifeos.schedules s set status = 'cancelled', updated_at = now()
    where s.series_id = v_series and s.deleted_at is null and s.status = 'planned' and s.planned_date >= v_from
    returning s.id
  )
  select coalesce(array_agg(u.id), '{}') into v_ids from u;

  return jsonb_build_object(
    'series_id', v_series,
    'cancelled_count', cardinality(v_ids),
    'schedules', (select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
                  from lifeos.schedules s where s.id = any (v_ids)));
end $$;

create or replace function lifeos.schedule_overdue_check(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_today date := lifeos._kl_today();
  v_now timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_res jsonb;
begin
  perform lifeos._check_fields(lifeos._obj(p_filter), '{}'::text[]);
  select coalesce(jsonb_agg(lifeos._schedule_json(s) order by s.planned_date, s.planned_time nulls last, s.created_at), '[]'::jsonb)
    into v_res
  from lifeos.schedules s
  where s.deleted_at is null
    and s.status = 'planned'
    and s.planned_date between v_today - 1 and v_today
    and not exists (select 1 from lifeos.events e where e.schedule_id = s.id and e.deleted_at is null)
    and ((s.planned_time is not null and (s.planned_date + s.planned_time) < v_now)
         or (s.planned_time is null and s.planned_date < v_today));
  return jsonb_build_object('results', v_res, 'returned_count', jsonb_array_length(v_res));
end $$;

create or replace function lifeos.schedule_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('schedules', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 4.2 Event
-- -----------------------------------------------------------------------------

create or replace function lifeos.event_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  s lifeos.schedules;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['title', 'description', 'occurred_date', 'occurred_time', 'end_date', 'end_time',
                                        'time_text', 'location', 'schedule_id', 'remarks', 'metadata']);
  perform lifeos._require(v, array['occurred_date']);
  perform lifeos._check_types(v, p_dates => array['occurred_date', 'end_date'], p_times => array['occurred_time', 'end_time'],
                              p_uuids => array['schedule_id'], p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);

  if v ? 'schedule_id' then
    select * into s from lifeos.schedules where id = (v ->> 'schedule_id')::uuid for update;
    if not found then
      raise exception 'record not found' using detail = 'schedule_id';
    end if;
    if s.deleted_at is not null then
      raise exception 'record deleted' using detail = 'schedule_id';
    end if;
    if exists (select 1 from lifeos.events e where e.schedule_id = s.id and e.deleted_at is null) then
      raise exception 'invalid relationship' using detail = 'the Schedule already has an active linked Event';
    end if;
    v := lifeos._strip_top_nulls(jsonb_build_object('title', s.title, 'description', s.description, 'location', s.location))
         || v
         || jsonb_build_object('planned_date', s.planned_date, 'planned_time', s.planned_time);
  else
    perform lifeos._require(v, array['title']);
  end if;

  v := v || jsonb_build_object('remarks', lifeos._remarks_normalize(v -> 'remarks'));
  v_id := lifeos._insert_row('events', v);

  if s.id is not null then
    update lifeos.schedules set status = 'occurred', updated_at = now() where id = s.id;
    return (select lifeos._event_json(e) from lifeos.events e where e.id = v_id)
           || jsonb_build_object('schedule', (select lifeos._schedule_json(x) from lifeos.schedules x where x.id = s.id));
  end if;
  return (select lifeos._event_json(e) from lifeos.events e where e.id = v_id);
end $$;

create or replace function lifeos.event_link_schedule(p_id uuid, p_schedule_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  e lifeos.events;
  s lifeos.schedules;
begin
  select * into e from lifeos.events where id = p_id for update;
  if not found then
    raise exception 'record not found' using detail = 'event';
  end if;
  if e.deleted_at is not null then
    raise exception 'record deleted' using detail = 'event';
  end if;
  select * into s from lifeos.schedules where id = p_schedule_id for update;
  if not found then
    raise exception 'record not found' using detail = 'schedule';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted' using detail = 'schedule';
  end if;
  if e.schedule_id is not null
     and exists (select 1 from lifeos.schedules x where x.id = e.schedule_id and x.deleted_at is null) then
    raise exception 'invalid relationship' using detail = 'the Event already has a Schedule link';
  end if;
  if exists (select 1 from lifeos.events x where x.schedule_id = s.id and x.deleted_at is null and x.id <> e.id) then
    raise exception 'invalid relationship' using detail = 'the Schedule already has an active linked Event';
  end if;

  update lifeos.events
     set schedule_id = s.id, planned_date = s.planned_date, planned_time = s.planned_time, updated_at = now()
   where id = e.id;
  update lifeos.schedules set status = 'occurred', updated_at = now() where id = s.id;

  return (select lifeos._event_json(x) from lifeos.events x where x.id = p_id)
         || jsonb_build_object('schedule', (select lifeos._schedule_json(x) from lifeos.schedules x where x.id = s.id));
end $$;

create or replace function lifeos.event_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  e lifeos.events;
begin
  select * into e from lifeos.events where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._event_json(e) || jsonb_build_object('links', lifeos._links('event', p_id));
end $$;

-- A schedule_id filter of a deleted Schedule matches nothing (M-0021 D10).
create or replace function lifeos.event_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_from date;
  v_to date;
  v_schedule uuid;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'from_date', 'to_date', 'schedule_id', 'include_deleted',
                                        'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['schedule_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  v_schedule := (f ->> 'schedule_id')::uuid;

  select coalesce(jsonb_agg(lifeos._event_json(e) order by e.occurred_date desc, e.occurred_time desc nulls last, e.created_at desc, e.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.events e
    where (v_inc or e.deleted_at is null)
      and (v_schedule is null
           or (e.schedule_id = v_schedule
               and exists (select 1 from lifeos.schedules x where x.id = v_schedule and x.deleted_at is null)))
      and (v_from is null or e.occurred_date >= v_from)
      and (v_to is null or e.occurred_date <= v_to)
      and (v_pat is null or e.title ilike v_pat or e.description ilike v_pat or e.location ilike v_pat
           or e.time_text ilike v_pat or lifeos._remarks_match(e.remarks, v_pat))
    order by e.occurred_date desc, e.occurred_time desc nulls last, e.created_at desc, e.id
    limit v_limit offset v_offset
  ) e;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.event_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  e lifeos.events;
begin
  select * into e from lifeos.events where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if e.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'description', 'occurred_date', 'occurred_time', 'end_date',
                                               'end_time', 'time_text', 'location', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['occurred_date', 'end_date'], p_times => array['occurred_time', 'end_time'],
                              p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['title', 'occurred_date'], p_objects => array['metadata']);
  perform lifeos._update_row('events', p_id, v);
  return (select lifeos._event_json(x) from lifeos.events x where x.id = p_id);
end $$;

-- Only an active Schedule returns to Planned. The schedule link is removed in both cases (M-0021 D9).
create or replace function lifeos.event_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  e lifeos.events;
  v_now timestamptz := now();
  v_returned uuid;
begin
  select * into e from lifeos.events where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if e.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(e.deleted_at), 'schedule_returned_to_planned', null);
  end if;
  update lifeos.events set deleted_at = v_now, updated_at = v_now, schedule_id = null where id = p_id;
  if e.schedule_id is not null then
    update lifeos.schedules set status = 'planned', updated_at = v_now
     where id = e.schedule_id and deleted_at is null
    returning id into v_returned;
  end if;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_now), 'schedule_returned_to_planned', v_returned);
end $$;

-- -----------------------------------------------------------------------------
-- 4.3 Observation
-- -----------------------------------------------------------------------------

create or replace function lifeos.observation_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['subject_id', 'observation_name', 'value_numeric', 'unit', 'value_text',
    'observed_date', 'observed_time', 'time_text', 'location', 'event_id', 'remarks', 'metadata']);
  perform lifeos._require(v, array['subject_id', 'observation_name', 'observed_date']);
  perform lifeos._check_types(v, p_dates => array['observed_date'], p_times => array['observed_time'],
                              p_nums => array['value_numeric'], p_uuids => array['subject_id', 'event_id'],
                              p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);
  if not (v ? 'value_numeric') and coalesce(btrim(v ->> 'value_text'), '') = '' then
    raise exception 'invalid input' using detail = 'value_numeric or value_text is required';
  end if;
  perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  if v ? 'event_id' then
    perform lifeos._require_active('events', (v ->> 'event_id')::uuid);
  end if;
  v := v || jsonb_build_object('remarks', lifeos._remarks_normalize(v -> 'remarks'));
  v_id := lifeos._insert_row('observations', v);
  return (select lifeos._observation_json(o) from lifeos.observations o where o.id = v_id);
end $$;

create or replace function lifeos.observation_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  o lifeos.observations;
begin
  select * into o from lifeos.observations where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._observation_json(o) || jsonb_build_object('links', lifeos._links('observation', p_id));
end $$;

-- A subject_id or event_id filter of a deleted Record matches nothing (M-0021 D10).
create or replace function lifeos.observation_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_subject uuid;
  v_event uuid;
  v_name text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'subject_id', 'observation_name', 'event_id', 'from_date',
                                        'to_date', 'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['subject_id', 'event_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_subject := (f ->> 'subject_id')::uuid;
  v_event := (f ->> 'event_id')::uuid;
  v_name := nullif(btrim(f ->> 'observation_name'), '');
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._observation_json(o) order by o.observed_date desc, o.observed_time desc nulls last, o.created_at desc, o.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.observations o
    where (v_inc or o.deleted_at is null)
      and (v_subject is null
           or (o.subject_id = v_subject
               and exists (select 1 from lifeos.subjects x where x.id = v_subject and x.deleted_at is null)))
      and (v_event is null
           or (o.event_id = v_event
               and exists (select 1 from lifeos.events x where x.id = v_event and x.deleted_at is null)))
      and (v_name is null or lower(o.observation_name) = lower(v_name))
      and (v_from is null or o.observed_date >= v_from)
      and (v_to is null or o.observed_date <= v_to)
      and (v_pat is null or o.observation_name ilike v_pat or o.value_text ilike v_pat or o.unit ilike v_pat
           or o.location ilike v_pat or lifeos._remarks_match(o.remarks, v_pat))
    order by o.observed_date desc, o.observed_time desc nulls last, o.created_at desc, o.id
    limit v_limit offset v_offset
  ) o;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.observation_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  o lifeos.observations;
  v_num_present boolean;
  v_text_present boolean;
begin
  select * into o from lifeos.observations where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if o.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['subject_id', 'observation_name', 'value_numeric', 'unit', 'value_text',
                                               'location', 'event_id', 'metadata']);
  perform lifeos._check_types(v, p_nums => array['value_numeric'], p_uuids => array['subject_id', 'event_id'],
                              p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['subject_id', 'observation_name'], p_objects => array['metadata']);

  v_num_present := case when v ? 'value_numeric' then jsonb_typeof(v -> 'value_numeric') <> 'null'
                        else o.value_numeric is not null end;
  v_text_present := case when v ? 'value_text' then coalesce(btrim(v ->> 'value_text'), '') <> ''
                         else o.value_text is not null end;
  if not (v_num_present or v_text_present) then
    raise exception 'invalid input' using detail = 'value_numeric or value_text is required';
  end if;
  if v ? 'subject_id' then
    perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  end if;
  if v ? 'event_id' and jsonb_typeof(v -> 'event_id') <> 'null' then
    perform lifeos._require_active('events', (v ->> 'event_id')::uuid);
  end if;
  perform lifeos._update_row('observations', p_id, v);
  return (select lifeos._observation_json(x) from lifeos.observations x where x.id = p_id);
end $$;

create or replace function lifeos.observation_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('observations', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 4.4 Note
-- -----------------------------------------------------------------------------

create or replace function lifeos.note_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['note_type', 'title', 'content', 'remarks', 'metadata']);
  perform lifeos._require(v, array['note_type', 'content']);
  perform lifeos._check_types(v, p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v) || jsonb_build_object('remarks', lifeos._remarks_normalize(v -> 'remarks'));
  v_id := lifeos._insert_row('notes', v);
  return (select lifeos._note_json(n) from lifeos.notes n where n.id = v_id);
end $$;

create or replace function lifeos.note_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  n lifeos.notes;
begin
  select * into n from lifeos.notes where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._note_json(n) || jsonb_build_object('links', lifeos._links('note', p_id));
end $$;

create or replace function lifeos.note_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_type text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'note_type', 'from_date', 'to_date', 'include_deleted',
                                        'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_type := nullif(btrim(f ->> 'note_type'), '');
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._note_json(n) order by s.note_date desc, s.created_at desc, s.id), '[]'::jsonb)
    into v_res
  from (
    select n.id, n.created_at, lifeos._kl_date(coalesce(n.edited_at, n.created_at)) as note_date
    from lifeos.notes n
    where (v_inc or n.deleted_at is null)
      and (v_type is null or lower(n.note_type) = lower(v_type))
      and (v_from is null or lifeos._kl_date(coalesce(n.edited_at, n.created_at)) >= v_from)
      and (v_to is null or lifeos._kl_date(coalesce(n.edited_at, n.created_at)) <= v_to)
      and (v_pat is null or n.title ilike v_pat or n.content ilike v_pat or lifeos._remarks_match(n.remarks, v_pat))
    order by note_date desc, n.created_at desc, n.id
    limit v_limit offset v_offset
  ) s
  cross join lateral (select x.* from lifeos.notes x where x.id = s.id) n;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.note_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  n lifeos.notes;
begin
  select * into n from lifeos.notes where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if n.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['note_type', 'title', 'content', 'metadata']);
  perform lifeos._check_types(v, p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['note_type', 'content'], p_objects => array['metadata']);
  perform lifeos._update_row('notes', p_id, v || jsonb_build_object('edited_at', now()));
  return (select lifeos._note_json(x) from lifeos.notes x where x.id = p_id);
end $$;

create or replace function lifeos.note_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('notes', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 4.5 Record links
-- -----------------------------------------------------------------------------

-- record_link_create is the only function that inserts into lifeos.record_links.
-- A Reading or a Divination Record never links to a Storyline (M-0020 F2, M-0021 D5).
create or replace function lifeos.record_link_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_from_type text;
  v_to_type text;
  v_from_id uuid;
  v_to_id uuid;
  v_a_type text;
  v_a_id uuid;
  v_b_type text;
  v_b_id uuid;
  l lifeos.record_links;
begin
  perform lifeos._check_fields(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._require(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._check_types(v, p_uuids => array['from_id', 'to_id']);
  v_from_type := v ->> 'from_type';
  v_to_type := v ->> 'to_type';
  v_from_id := (v ->> 'from_id')::uuid;
  v_to_id := (v ->> 'to_id')::uuid;
  if lifeos._record_table(v_from_type) is null or lifeos._record_table(v_to_type) is null then
    raise exception 'invalid input' using detail = 'from_type and to_type are Record Type names';
  end if;
  if v_from_type = v_to_type and v_from_id = v_to_id then
    raise exception 'invalid relationship' using detail = 'a Record cannot link to itself';
  end if;
  if v_from_type = 'subject' and v_to_type = 'subject' then
    raise exception 'invalid relationship' using detail = 'a Subject cannot link to another Subject';
  end if;
  if (v_from_type = 'reading' and v_to_type = 'storyline') or (v_from_type = 'storyline' and v_to_type = 'reading') then
    raise exception 'invalid relationship' using detail = 'a Reading has no structured link to a Storyline';
  end if;
  if (v_from_type = 'divination_record' and v_to_type = 'storyline')
     or (v_from_type = 'storyline' and v_to_type = 'divination_record') then
    raise exception 'invalid relationship' using detail = 'a Divination Record has no structured link to a Storyline';
  end if;
  perform lifeos._require_active(lifeos._record_table(v_from_type), v_from_id);
  perform lifeos._require_active(lifeos._record_table(v_to_type), v_to_id);

  if (v_from_type, v_from_id::text) < (v_to_type, v_to_id::text) then
    v_a_type := v_from_type; v_a_id := v_from_id; v_b_type := v_to_type; v_b_id := v_to_id;
  else
    v_a_type := v_to_type; v_a_id := v_to_id; v_b_type := v_from_type; v_b_id := v_from_id;
  end if;

  insert into lifeos.record_links (record_type_a, record_id_a, record_type_b, record_id_b)
  values (v_a_type, v_a_id, v_b_type, v_b_id)
  on conflict on constraint record_links_pair_unique do nothing;

  select * into l from lifeos.record_links
  where record_type_a = v_a_type and record_id_a = v_a_id and record_type_b = v_b_type and record_id_b = v_b_id;

  return jsonb_build_object('link_id', l.id, 'from_type', v_from_type, 'from_id', v_from_id,
                            'to_type', v_to_type, 'to_id', v_to_id, 'created_at', lifeos._ts(l.created_at));
end $$;

create or replace function lifeos.record_link_delete(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_from_type text;
  v_to_type text;
  v_from_id uuid;
  v_to_id uuid;
  v_rows integer;
begin
  perform lifeos._check_fields(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._require(v, array['from_type', 'from_id', 'to_type', 'to_id']);
  perform lifeos._check_types(v, p_uuids => array['from_id', 'to_id']);
  v_from_type := v ->> 'from_type';
  v_to_type := v ->> 'to_type';
  v_from_id := (v ->> 'from_id')::uuid;
  v_to_id := (v ->> 'to_id')::uuid;
  delete from lifeos.record_links l
  where (l.record_type_a = v_from_type and l.record_id_a = v_from_id and l.record_type_b = v_to_type and l.record_id_b = v_to_id)
     or (l.record_type_a = v_to_type and l.record_id_a = v_to_id and l.record_type_b = v_from_type and l.record_id_b = v_from_id);
  get diagnostics v_rows = row_count;
  return jsonb_build_object('removed', v_rows > 0);
end $$;

-- Links of one Record (Contract 4.5.3). On a Subject, each connected Record appears once
-- and carries every path in via_list (M-0022 D4). A Record lists each Subject once through _links.
create or replace function lifeos.record_links_read(p_record_type text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text := lifeos._record_table(p_record_type);
  v_found boolean;
  v_links jsonb;
begin
  if v_table is null then
    raise exception 'invalid input' using detail = 'p_record_type is a Record Type name';
  end if;
  execute format('select true from lifeos.%I where id = $1', v_table) into v_found using p_id;
  if v_found is null then
    raise exception 'record not found';
  end if;
  v_links := lifeos._links(p_record_type, p_id);
  if p_record_type = 'subject' then
    -- M-0022 D4: one entry per connected Record. via_list holds every path in the fixed order.
    -- via is the first path, as on a Record (Contract 1.5 item 15).
    with e as (
      select x.l, x.l ->> 'record_type' as record_type, x.l ->> 'id' as id,
             coalesce(array_position(array['record_link', 'observation_subject', 'payment_method', 'merchant',
                                            'line_item', 'story_person_subject', 'person_profile_subject'],
                                      x.l ->> 'via'), 8) as path_rank
      from jsonb_array_elements(v_links) x(l)
    ), g as (
      select e.record_type, e.id,
             (array_agg(e.l order by e.path_rank, e.l ->> 'via'))[1] as lead_link,
             jsonb_agg(e.l -> 'via' order by e.path_rank, e.l ->> 'via') as via_list
      from e group by e.record_type, e.id
    )
    select coalesce(jsonb_agg(g.lead_link || jsonb_build_object('via_list', g.via_list)
                              order by g.lead_link ->> 'via', g.record_type, g.lead_link ->> 'occurrence_date' desc nulls last,
                                       g.id::uuid), '[]'::jsonb)
      into v_links
    from g;
  end if;
  return jsonb_build_object('record_type', p_record_type, 'id', p_id, 'links', v_links);
end $$;

-- -----------------------------------------------------------------------------
-- 4.6 Remarks
-- -----------------------------------------------------------------------------

-- Appends a Remark with a new remark_id. updated_at stays (M-0018 D5, M-0020 F1).
create or replace function lifeos.record_add_remark(p_record_type text, p_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text;
begin
  if p_record_type is null or p_record_type not in ('schedule', 'event', 'observation', 'note', 'expense') then
    raise exception 'invalid input' using detail = 'p_record_type is schedule, event, observation, note or expense';
  end if;
  if p_text is null or btrim(p_text) = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  v_table := lifeos._record_table(p_record_type);
  perform lifeos._require_active(v_table, p_id);
  execute format('update lifeos.%I set remarks = remarks || jsonb_build_array($2) where id = $1', v_table)
    using p_id, jsonb_build_object('remark_id', gen_random_uuid(), 'timestamp', lifeos._ts(now()), 'text', btrim(p_text));
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- Replaces the text of one Remark. remark_id, timestamp and updated_at stay (M-0020 F1, D2).
create or replace function lifeos.record_update_remark(p_record_type text, p_id uuid, p_remark_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text;
  v_remarks jsonb;
  v_index integer;
begin
  if p_record_type is null or p_record_type not in ('schedule', 'event', 'observation', 'note', 'expense') then
    raise exception 'invalid input' using detail = 'p_record_type is schedule, event, observation, note or expense';
  end if;
  if p_text is null or btrim(p_text) = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  v_table := lifeos._record_table(p_record_type);
  perform lifeos._require_active(v_table, p_id);
  execute format('select remarks from lifeos.%I where id = $1 for update', v_table) into v_remarks using p_id;
  select e.ord - 1 into v_index
  from jsonb_array_elements(v_remarks) with ordinality e(value, ord)
  where e.value ->> 'remark_id' = p_remark_id::text;
  if v_index is null then
    raise exception 'record not found' using detail = 'remark_id';
  end if;
  execute format('update lifeos.%I set remarks = jsonb_set(remarks, $2, $3) where id = $1', v_table)
    using p_id, array[v_index::text, 'text'], to_jsonb(btrim(p_text));
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- Removes one Remark. updated_at stays (M-0020 F1, D2).
create or replace function lifeos.record_delete_remark(p_record_type text, p_id uuid, p_remark_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_table text;
  v_remarks jsonb;
  v_index integer;
begin
  if p_record_type is null or p_record_type not in ('schedule', 'event', 'observation', 'note', 'expense') then
    raise exception 'invalid input' using detail = 'p_record_type is schedule, event, observation, note or expense';
  end if;
  v_table := lifeos._record_table(p_record_type);
  perform lifeos._require_active(v_table, p_id);
  execute format('select remarks from lifeos.%I where id = $1 for update', v_table) into v_remarks using p_id;
  select e.ord - 1 into v_index
  from jsonb_array_elements(v_remarks) with ordinality e(value, ord)
  where e.value ->> 'remark_id' = p_remark_id::text;
  if v_index is null then
    raise exception 'record not found' using detail = 'remark_id';
  end if;
  execute format('update lifeos.%I set remarks = remarks - $2 where id = $1', v_table) using p_id, v_index;
  return lifeos._record_json(p_record_type, p_id);
end $$;

-- =============================================================================
-- 6. Subject (Contract Chapter 5)
-- =============================================================================

create or replace function lifeos._subject_json(s lifeos.subjects)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$ select lifeos._row_json(s) $$;

-- Subject plus the derived fields person_profile_id and story_person_ids (Contract 5.2).
create or replace function lifeos._subject_read_json(s lifeos.subjects)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s) || jsonb_build_object(
    'person_profile_id', (select p.id from lifeos.communication_profiles p
                          where p.person_subject_id = s.id and p.profile_type = 'person' and p.deleted_at is null limit 1),
    'story_person_ids', coalesce((select jsonb_agg(sp.id order by sp.created_at) from lifeos.story_persons sp
                                  where sp.subject_id = s.id and sp.deleted_at is null), '[]'::jsonb))
$$;

create or replace function lifeos.subject_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['name', 'subject_type', 'description', 'aliases', 'tags', 'is_user', 'metadata']);
  perform lifeos._require(v, array['name']);
  perform lifeos._check_types(v, p_arrays => array['aliases', 'tags'], p_objects => array['metadata'],
                              p_bools => array['is_user']);
  v := lifeos._strip_top_nulls(v);
  if coalesce((v ->> 'is_user')::boolean, false)
     and exists (select 1 from lifeos.subjects s where s.is_user and s.deleted_at is null) then
    raise exception 'invalid input' using detail = 'another active Subject is the user';
  end if;
  v_id := lifeos._insert_row('subjects', v);
  return (select lifeos._subject_json(s) from lifeos.subjects s where s.id = v_id);
end $$;

create or replace function lifeos.subject_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.subjects;
begin
  select * into s from lifeos.subjects where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._subject_read_json(s);
end $$;

create or replace function lifeos.subject_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_exact text;
  v_type text;
  v_tags text[];
  v_is_user boolean;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'subject_type', 'tags', 'is_user', 'include_deleted',
                                        'limit', 'offset']);
  perform lifeos._check_types(f, p_bools => array['is_user']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_exact := lower(coalesce(nullif(btrim(f ->> 'keyword'), ''), nullif(btrim(f ->> 'query'), '')));
  v_type := nullif(btrim(f ->> 'subject_type'), '');
  v_tags := lifeos._text_list(f -> 'tags');
  v_is_user := (f ->> 'is_user')::boolean;

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'subject_type', s.subject_type,
                                               'aliases', to_jsonb(s.aliases), 'tags', to_jsonb(s.tags),
                                               'is_user', s.is_user, 'description', s.description)
                            order by s.exact_rank, s.updated_at desc, s.id), '[]'::jsonb)
    into v_res
  from (
    select x.*,
           case when v_exact is not null
                     and (lower(x.name) = v_exact or exists (select 1 from unnest(x.aliases) a where lower(a) = v_exact))
                then 0 else 1 end as exact_rank
    from lifeos.subjects x
    where (v_inc or x.deleted_at is null)
      and (v_type is null or lower(x.subject_type) = lower(v_type))
      and (v_tags is null or x.tags && v_tags)
      and (v_is_user is null or x.is_user = v_is_user)
      and (v_pat is null or x.name ilike v_pat or x.description ilike v_pat or x.subject_type ilike v_pat
           or lifeos._array_match(x.aliases, v_pat) or lifeos._array_match(x.tags, v_pat))
    order by exact_rank, x.updated_at desc, x.id
    limit v_limit offset v_offset
  ) s;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.subject_check(p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_text text := lower(btrim(p_text));
  v_matches jsonb;
begin
  if v_text is null or v_text = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'subject_type', m.subject_type,
                                               'matched_on', m.matched_on) order by m.matched_on desc, m.name, m.id), '[]'::jsonb)
    into v_matches
  from (
    select s.id, s.name, s.subject_type,
           case when lower(btrim(s.name)) = v_text then 'name' else 'alias' end as matched_on
    from lifeos.subjects s
    where s.deleted_at is null
      and (lower(btrim(s.name)) = v_text
           or exists (select 1 from unnest(s.aliases) a where lower(btrim(a)) = v_text))
  ) m;
  return jsonb_build_object('exists', jsonb_array_length(v_matches) > 0, 'matches', v_matches);
end $$;

create or replace function lifeos.subject_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb;
  s lifeos.subjects;
begin
  select * into s from lifeos.subjects where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['name', 'subject_type', 'description', 'aliases', 'tags', 'is_user', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['aliases', 'tags'], p_objects => array['metadata'],
                              p_bools => array['is_user']);
  v := lifeos._prep_changes(v, p_required => array['name'], p_arrays => array['aliases', 'tags'],
                            p_objects => array['metadata']);
  if v ? 'is_user' and jsonb_typeof(v -> 'is_user') = 'null' then
    v := jsonb_set(v, '{is_user}', 'false'::jsonb);
  end if;
  if coalesce((v ->> 'is_user')::boolean, false)
     and exists (select 1 from lifeos.subjects x where x.is_user and x.deleted_at is null and x.id <> p_id) then
    raise exception 'invalid input' using detail = 'another active Subject is the user';
  end if;
  perform lifeos._update_row('subjects', p_id, v);
  return (select lifeos._subject_json(x) from lifeos.subjects x where x.id = p_id);
end $$;

create or replace function lifeos.subject_add_alias(p_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.subjects;
  v_alias text := btrim(p_text);
begin
  if v_alias is null or v_alias = '' then
    raise exception 'invalid input' using detail = 'p_text is required';
  end if;
  select * into s from lifeos.subjects where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  if not exists (select 1 from unnest(s.aliases) a where lower(a) = lower(v_alias)) then
    update lifeos.subjects set aliases = aliases || v_alias, updated_at = now() where id = p_id;
  end if;
  return (select lifeos._subject_json(x) from lifeos.subjects x where x.id = p_id);
end $$;

-- An empty identity returns "invalid input" (M-0020 S2).
create or replace function lifeos.subject_merge(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_identity jsonb;
  v_keep uuid;
  v_merge uuid;
  k lifeos.subjects;
  m lifeos.subjects;
  l lifeos.record_links;
  v_other_type text;
  v_other_id uuid;
  v_a_type text;
  v_a_id uuid;
  v_b_type text;
  v_b_id uuid;
  n_links integer := 0;
  n_obs integer := 0;
  n_pay integer := 0;
  n_merchant integer := 0;
  n_line integer := 0;
  n_story integer := 0;
  n_profile integer := 0;
begin
  perform lifeos._check_fields(v, array['keep_id', 'merge_id', 'identity']);
  perform lifeos._require(v, array['keep_id', 'merge_id', 'identity']);
  perform lifeos._check_types(v, p_uuids => array['keep_id', 'merge_id'], p_objects => array['identity']);
  v_identity := v -> 'identity';
  if v_identity = '{}'::jsonb then
    raise exception 'invalid input' using detail = 'identity needs at least one field';
  end if;
  perform lifeos._check_fields(v_identity, array['name', 'subject_type', 'description', 'aliases', 'tags']);
  perform lifeos._check_types(v_identity, p_arrays => array['aliases', 'tags']);
  v_identity := lifeos._prep_changes(v_identity, p_required => array['name'], p_arrays => array['aliases', 'tags']);
  v_keep := (v ->> 'keep_id')::uuid;
  v_merge := (v ->> 'merge_id')::uuid;
  if v_keep = v_merge then
    raise exception 'invalid relationship' using detail = 'keep_id and merge_id are the same Subject';
  end if;

  select * into k from lifeos.subjects where id = v_keep for update;
  if not found then
    raise exception 'record not found' using detail = 'keep_id';
  end if;
  if k.deleted_at is not null then
    raise exception 'record deleted' using detail = 'keep_id';
  end if;
  select * into m from lifeos.subjects where id = v_merge for update;
  if not found then
    raise exception 'record not found' using detail = 'merge_id';
  end if;
  if m.deleted_at is not null then
    raise exception 'record deleted' using detail = 'merge_id';
  end if;

  if exists (select 1 from lifeos.communication_profiles p where p.person_subject_id = v_keep and p.deleted_at is null)
     and exists (select 1 from lifeos.communication_profiles p where p.person_subject_id = v_merge and p.deleted_at is null) then
    raise exception 'invalid relationship' using detail = 'both Subjects have an active Person Profile';
  end if;

  -- Record links: move each link to the kept Subject. A link that becomes a duplicate pair is removed.
  for l in select * from lifeos.record_links x
           where (x.record_type_a = 'subject' and x.record_id_a = v_merge)
              or (x.record_type_b = 'subject' and x.record_id_b = v_merge) loop
    if l.record_type_a = 'subject' and l.record_id_a = v_merge then
      v_other_type := l.record_type_b; v_other_id := l.record_id_b;
    else
      v_other_type := l.record_type_a; v_other_id := l.record_id_a;
    end if;
    if ('subject', v_keep::text) < (v_other_type, v_other_id::text) then
      v_a_type := 'subject'; v_a_id := v_keep; v_b_type := v_other_type; v_b_id := v_other_id;
    else
      v_a_type := v_other_type; v_a_id := v_other_id; v_b_type := 'subject'; v_b_id := v_keep;
    end if;
    if exists (select 1 from lifeos.record_links x
               where x.record_type_a = v_a_type and x.record_id_a = v_a_id
                 and x.record_type_b = v_b_type and x.record_id_b = v_b_id) then
      delete from lifeos.record_links where id = l.id;
    else
      update lifeos.record_links
         set record_type_a = v_a_type, record_id_a = v_a_id, record_type_b = v_b_type, record_id_b = v_b_id
       where id = l.id;
    end if;
    n_links := n_links + 1;
  end loop;

  -- Typed reference fields. Source Records stay unchanged except for their Subject references.
  update lifeos.observations set subject_id = v_keep where subject_id = v_merge;
  get diagnostics n_obs = row_count;
  update lifeos.expenses set payment_method_subject_id = v_keep where payment_method_subject_id = v_merge;
  get diagnostics n_pay = row_count;
  update lifeos.expenses set merchant_subject_id = v_keep where merchant_subject_id = v_merge;
  get diagnostics n_merchant = row_count;
  update lifeos.expense_lines set item_subject_id = v_keep where item_subject_id = v_merge;
  get diagnostics n_line = row_count;
  update lifeos.story_persons set subject_id = v_keep where subject_id = v_merge;
  get diagnostics n_story = row_count;
  update lifeos.communication_profiles set person_subject_id = v_keep where person_subject_id = v_merge;
  get diagnostics n_profile = row_count;

  -- Close the merged Subject. Its own fields stay stored.
  update lifeos.subjects set merged_into_id = v_keep, deleted_at = now(), updated_at = now() where id = v_merge;

  -- The kept Subject takes the merged identity, and the user flag when the merged Subject was the user.
  if m.is_user then
    v_identity := v_identity || jsonb_build_object('is_user', true);
  end if;
  perform lifeos._update_row('subjects', v_keep, v_identity);

  return jsonb_build_object(
    'subject', (select lifeos._subject_read_json(x) from lifeos.subjects x where x.id = v_keep),
    'merged_id', v_merge,
    'moved_references', jsonb_build_object(
      'record_link', n_links,
      'observation_subject', n_obs,
      'payment_method', n_pay,
      'merchant', n_merchant,
      'line_item', n_line,
      'story_person_subject', n_story,
      'person_profile_subject', n_profile));
end $$;

-- A Person Subject that still has an active Profile is not deleted (M-0021 D4).
create or replace function lifeos.subject_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.subjects;
begin
  select * into s from lifeos.subjects where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(s.deleted_at));
  end if;
  if exists (select 1 from lifeos.communication_profiles p
             where p.person_subject_id = p_id and p.deleted_at is null) then
    raise exception 'invalid relationship' using detail = 'the Person Subject still has a Profile';
  end if;
  return lifeos._soft_delete('subjects', p_id);
end $$;

-- =============================================================================
-- 7. Financial Records (Contract Chapter 6)
-- =============================================================================

-- Stored Expense with its Lines, as kept in a history snapshot.
create or replace function lifeos._expense_core(x lifeos.expenses)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(x) || jsonb_build_object('lines', coalesce(
    (select jsonb_agg(lifeos._row_json(l) order by l.line_no) from lifeos.expense_lines l where l.expense_id = x.id),
    '[]'::jsonb))
$$;

-- Complete Expense Record with lines, discrepancies, refunds and version (Contract 6, derived fields).
create or replace function lifeos._expense_json(x lifeos.expenses)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  j jsonb := lifeos._row_json(x);
  v_lines jsonb;
  v_sum numeric;
  v_count integer;
  v_disc jsonb := '[]'::jsonb;
begin
  -- Scalar references to deleted targets are returned as null (Contract 1.5 item 9).
  if x.merchant_subject_id is not null
     and not exists (select 1 from lifeos.subjects s where s.id = x.merchant_subject_id and s.deleted_at is null) then
    j := jsonb_set(j, '{merchant_subject_id}', 'null'::jsonb);
  end if;
  if not exists (select 1 from lifeos.subjects s where s.id = x.payment_method_subject_id and s.deleted_at is null) then
    j := jsonb_set(j, '{payment_method_subject_id}', 'null'::jsonb);
  end if;
  if x.refund_of is not null
     and not exists (select 1 from lifeos.expenses o where o.id = x.refund_of and o.deleted_at is null) then
    j := jsonb_set(j, '{refund_of}', 'null'::jsonb);
  end if;

  select coalesce(jsonb_agg(lifeos._row_json(l)
                            || case when l.item_subject_id is not null
                                         and not exists (select 1 from lifeos.subjects s
                                                         where s.id = l.item_subject_id and s.deleted_at is null)
                                    then jsonb_build_object('item_subject_id', null) else '{}'::jsonb end
                            order by l.line_no), '[]'::jsonb),
         sum(l.line_total), count(*)
    into v_lines, v_sum, v_count
  from lifeos.expense_lines l where l.expense_id = x.id;

  if v_count > 0 and v_sum <> x.expense_total then
    v_disc := v_disc || jsonb_build_array(jsonb_build_object('check', 'lines_sum', 'expense_total', x.expense_total,
                                                             'lines_sum', v_sum));
  end if;
  v_disc := v_disc || coalesce((
    select jsonb_agg(jsonb_build_object('check', 'quantity_x_unit_price', 'line_id', l.id, 'line_total', l.line_total,
                                        'computed', l.quantity * l.unit_price) order by l.line_no)
    from lifeos.expense_lines l
    where l.expense_id = x.id and l.quantity * l.unit_price <> l.line_total), '[]'::jsonb);

  return j || jsonb_build_object(
    'lines', v_lines,
    'discrepancies', v_disc,
    'refunds', case when x.expense_type = 'purchase' then coalesce((
        select jsonb_agg(jsonb_build_object('id', r.id, 'transaction_date', r.transaction_date,
                                            'transaction_time', r.transaction_time, 'expense_total', r.expense_total,
                                            'currency', r.currency) order by r.transaction_date, r.created_at)
        from lifeos.expenses r where r.refund_of = x.id and r.deleted_at is null), '[]'::jsonb)
      else '[]'::jsonb end,
    'version', (select count(*) + 1 from lifeos.expense_versions h where h.expense_id = x.id));
end $$;

-- Compact original Expense of a Refund (Contract 6.3). null when the original is deleted.
create or replace function lifeos._expense_original(p_id uuid)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('id', o.id, 'transaction_date', o.transaction_date, 'merchant_name', o.merchant_name,
                            'expense_total', o.expense_total)
  from lifeos.expenses o where o.id = p_id and o.deleted_at is null
$$;

-- Validates and inserts the Lines of one Expense (Contract 6, Line validation).
create or replace function lifeos._expense_lines_insert(p_expense_id uuid, p_lines jsonb, p_purchase boolean)
returns void language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_item jsonb;
  v_no integer := 0;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'invalid input' using detail = 'lines needs at least one item';
  end if;
  for v_item in select value from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_item := lifeos._obj(v_item);
    perform lifeos._check_fields(v_item, array['line_type', 'item_description', 'source_item_text', 'quantity',
      'unit_price', 'line_total', 'category', 'tags', 'item_subject_id', 'metadata']);
    perform lifeos._require(v_item, case when p_purchase then array['unit_price', 'line_total', 'line_type', 'category']
                                         else array['unit_price', 'line_total', 'line_type'] end);
    perform lifeos._check_types(v_item, p_nums => array['quantity', 'unit_price', 'line_total'],
                                p_uuids => array['item_subject_id'], p_arrays => array['tags'],
                                p_objects => array['metadata']);
    if v_item ->> 'line_type' not in ('item', 'charge', 'adjustment') then
      raise exception 'invalid input' using detail = format('line %s: line_type is item, charge or adjustment', v_no);
    end if;
    if v_item ? 'category' and jsonb_typeof(v_item -> 'category') <> 'null'
       and v_item ->> 'category' <> all (lifeos._expense_categories()) then
      raise exception 'invalid input' using detail = format('line %s: category is one of the 17 Categories', v_no);
    end if;
    if v_item ? 'tags' and jsonb_typeof(v_item -> 'tags') = 'array' and jsonb_array_length(v_item -> 'tags') > 10 then
      raise exception 'invalid input' using detail = format('line %s: at most ten Tags', v_no);
    end if;
    if v_item ? 'item_subject_id' and jsonb_typeof(v_item -> 'item_subject_id') <> 'null' then
      perform lifeos._require_active('subjects', (v_item ->> 'item_subject_id')::uuid);
    end if;
    perform lifeos._insert_row('expense_lines',
      lifeos._strip_top_nulls(v_item) || jsonb_build_object('expense_id', p_expense_id, 'line_no', v_no));
  end loop;
end $$;

-- Validates and inserts one purchase Expense with its Lines (Contract 6.1). Returns the new ID.
create or replace function lifeos._expense_insert(p_input jsonb)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
  v_currency text;
begin
  perform lifeos._check_fields(v, array['transaction_date', 'transaction_time', 'merchant_name', 'branch',
    'merchant_subject_id', 'seller_name', 'payment_method_subject_id', 'expense_total', 'currency', 'remarks',
    'metadata', 'lines']);
  perform lifeos._require(v, array['transaction_date', 'payment_method_subject_id', 'expense_total', 'currency', 'lines']);
  perform lifeos._check_types(v, p_dates => array['transaction_date'], p_times => array['transaction_time'],
                              p_uuids => array['merchant_subject_id', 'payment_method_subject_id'],
                              p_nums => array['expense_total'], p_objects => array['metadata']);
  if (v ->> 'expense_total')::numeric < 0 then
    raise exception 'invalid input' using detail = 'expense_total is zero or positive';
  end if;
  v_currency := upper(btrim(v ->> 'currency'));
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'invalid input' using detail = 'currency is an ISO 4217 code';
  end if;
  if jsonb_typeof(v -> 'lines') <> 'array' or jsonb_array_length(v -> 'lines') = 0 then
    raise exception 'invalid input' using detail = 'lines needs at least one item';
  end if;
  perform lifeos._require_active('subjects', (v ->> 'payment_method_subject_id')::uuid);
  if v ? 'merchant_subject_id' and jsonb_typeof(v -> 'merchant_subject_id') <> 'null' then
    perform lifeos._require_active('subjects', (v ->> 'merchant_subject_id')::uuid);
  end if;

  v_id := lifeos._insert_row('expenses',
    lifeos._strip_top_nulls(v - 'lines' - 'remarks')
    || jsonb_build_object('expense_type', 'purchase', 'currency', v_currency,
                          'remarks', lifeos._remarks_normalize(v -> 'remarks')));
  perform lifeos._expense_lines_insert(v_id, v -> 'lines', true);
  return v_id;
end $$;

-- Saves the current Expense as one history version (Contract 6.5 item 1, 6.7 item 1).
create or replace function lifeos._expense_snapshot(x lifeos.expenses, p_reason text)
returns void language sql volatile set search_path = lifeos, pg_temp
as $$
  insert into lifeos.expense_versions (expense_id, version_no, snapshot, correction_reason, corrected_at)
  select x.id, count(*) + 1, lifeos._expense_core(x), p_reason, now()
  from lifeos.expense_versions h where h.expense_id = x.id
$$;

create or replace function lifeos.expense_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_input ? 'expense_type' or p_input ? 'refund_of' then
    raise exception 'unsupported field' using detail = 'expense_type and refund_of are not accepted; a Refund uses expense_refund_create';
  end if;
  v_id := lifeos._expense_insert(p_input);
  return (select lifeos._expense_json(x) from lifeos.expenses x where x.id = v_id);
end $$;

-- The error text is the item's own error text followed by " at item <n>", with a 0-based n.
create or replace function lifeos.expense_create_batch(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_item jsonb;
  v_index integer := -1;
  v_ids uuid[] := '{}';
  v_state text;
  v_msg text;
  v_detail text;
begin
  perform lifeos._check_fields(v, array['expenses']);
  perform lifeos._require(v, array['expenses']);
  if jsonb_typeof(v -> 'expenses') <> 'array' or jsonb_array_length(v -> 'expenses') = 0 then
    raise exception 'invalid input' using detail = 'expenses needs at least one item';
  end if;
  for v_item in select value from jsonb_array_elements(v -> 'expenses') loop
    v_index := v_index + 1;
    begin
      if v_item ? 'expense_type' or v_item ? 'refund_of' then
        raise exception 'unsupported field' using detail = 'expense_type and refund_of are not accepted';
      end if;
      v_ids := v_ids || lifeos._expense_insert(v_item);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
      raise exception '% at item %', v_msg, v_index using errcode = v_state,
        detail = concat_ws('; ', format('expenses item index %s (0-based)', v_index), nullif(v_detail, ''));
    end;
  end loop;
  return jsonb_build_object(
    'results', (select jsonb_agg(lifeos._expense_json(x) order by t.ord)
                from unnest(v_ids) with ordinality t(id, ord) join lifeos.expenses x on x.id = t.id),
    'returned_count', cardinality(v_ids));
end $$;

create or replace function lifeos.expense_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  j jsonb;
begin
  select * into x from lifeos.expenses where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  j := lifeos._expense_json(x) || jsonb_build_object('links', lifeos._links('expense', p_id));
  if x.expense_type = 'refund' then
    j := j || jsonb_build_object('original', lifeos._expense_original(x.refund_of));
  end if;
  return j;
end $$;

-- A Subject or refund_of filter of a deleted Record matches nothing (M-0021 D10).
create or replace function lifeos.expense_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_from date;
  v_to date;
  v_type text;
  v_pay uuid;
  v_merchant uuid;
  v_item uuid;
  v_category text;
  v_tag text;
  v_refund_of uuid;
  v_currency text;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'from_date', 'to_date', 'expense_type',
    'payment_method_subject_id', 'merchant_subject_id', 'item_subject_id', 'category', 'tag', 'refund_of', 'currency',
    'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['payment_method_subject_id', 'merchant_subject_id', 'item_subject_id',
                                                  'refund_of']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  v_type := nullif(btrim(f ->> 'expense_type'), '');
  v_pay := (f ->> 'payment_method_subject_id')::uuid;
  v_merchant := (f ->> 'merchant_subject_id')::uuid;
  v_item := (f ->> 'item_subject_id')::uuid;
  v_category := nullif(btrim(f ->> 'category'), '');
  v_tag := nullif(btrim(f ->> 'tag'), '');
  v_refund_of := (f ->> 'refund_of')::uuid;
  v_currency := upper(nullif(btrim(f ->> 'currency'), ''));

  select coalesce(jsonb_agg(lifeos._expense_json(x) order by x.transaction_date desc, x.transaction_time desc nulls last, x.created_at desc, x.id), '[]'::jsonb)
    into v_res
  from (
    select * from lifeos.expenses x
    where (v_inc or x.deleted_at is null)
      and (v_from is null or x.transaction_date >= v_from)
      and (v_to is null or x.transaction_date <= v_to)
      and (v_type is null or x.expense_type = v_type)
      and (v_pay is null
           or (x.payment_method_subject_id = v_pay
               and exists (select 1 from lifeos.subjects s where s.id = v_pay and s.deleted_at is null)))
      and (v_merchant is null
           or (x.merchant_subject_id = v_merchant
               and exists (select 1 from lifeos.subjects s where s.id = v_merchant and s.deleted_at is null)))
      and (v_refund_of is null
           or (x.refund_of = v_refund_of
               and exists (select 1 from lifeos.expenses o where o.id = v_refund_of and o.deleted_at is null)))
      and (v_currency is null or x.currency = v_currency)
      and (v_item is null
           or (exists (select 1 from lifeos.expense_lines l where l.expense_id = x.id and l.item_subject_id = v_item)
               and exists (select 1 from lifeos.subjects s where s.id = v_item and s.deleted_at is null)))
      and (v_category is null or exists (select 1 from lifeos.expense_lines l where l.expense_id = x.id and l.category = v_category))
      and (v_tag is null or exists (select 1 from lifeos.expense_lines l where l.expense_id = x.id and v_tag = any (l.tags)))
      and (v_pat is null or x.merchant_name ilike v_pat or x.branch ilike v_pat or x.seller_name ilike v_pat
           or lifeos._remarks_match(x.remarks, v_pat)
           or exists (select 1 from lifeos.expense_lines l
                      where l.expense_id = x.id and (l.item_description ilike v_pat or l.source_item_text ilike v_pat)))
    order by x.transaction_date desc, x.transaction_time desc nulls last, x.created_at desc, x.id
    limit v_limit offset v_offset
  ) x;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

-- A correction keeps the Refund limits from both the Refund and the purchase side.
-- The check reads the state after the correction (J-0018 F2 and F-Q1).
create or replace function lifeos.expense_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  y lifeos.expenses;
  o lifeos.expenses;
  v jsonb;
  c jsonb;
  v_reason text;
  v_amount numeric;
  v_line jsonb := '{}'::jsonb;
  v_refunded numeric;
  v_first_refund date;
begin
  select * into x from lifeos.expenses where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if x.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  -- A Refund correction locks its purchase, as expense_refund_create does.
  if x.expense_type = 'refund' then
    select * into o from lifeos.expenses where id = x.refund_of for update;
  end if;

  if x.expense_type = 'purchase' then
    v := lifeos._check_changes(p_changes, array['transaction_date', 'transaction_time', 'merchant_name', 'branch',
      'merchant_subject_id', 'seller_name', 'payment_method_subject_id', 'expense_total', 'currency', 'metadata', 'lines',
      'correction_reason']);
  else
    v := lifeos._check_changes(p_changes, array['transaction_date', 'transaction_time', 'refund_amount',
      'item_description', 'item_subject_id', 'line_type', 'metadata', 'correction_reason']);
  end if;
  perform lifeos._require(v, array['correction_reason']);
  v_reason := btrim(v ->> 'correction_reason');
  c := v - 'correction_reason';
  if c = '{}'::jsonb then
    raise exception 'invalid input' using detail = 'at least one change field is required besides correction_reason';
  end if;
  perform lifeos._check_types(c, p_dates => array['transaction_date'], p_times => array['transaction_time'],
                              p_uuids => array['merchant_subject_id', 'payment_method_subject_id', 'item_subject_id'],
                              p_nums => array['expense_total', 'refund_amount'], p_objects => array['metadata']);

  -- Snapshot of the current version before the change (Contract 6.5 item 1).
  perform lifeos._expense_snapshot(x, v_reason);

  if x.expense_type = 'purchase' then
    c := lifeos._prep_changes(c, p_required => array['transaction_date', 'payment_method_subject_id', 'expense_total',
                                                     'currency', 'lines'], p_objects => array['metadata']);
    if c ? 'expense_total' and (c ->> 'expense_total')::numeric < 0 then
      raise exception 'invalid input' using detail = 'expense_total is zero or positive';
    end if;
    if c ? 'currency' then
      if upper(btrim(c ->> 'currency')) !~ '^[A-Z]{3}$' then
        raise exception 'invalid input' using detail = 'currency is an ISO 4217 code';
      end if;
      c := jsonb_set(c, '{currency}', to_jsonb(upper(btrim(c ->> 'currency'))));
    end if;
    if c ? 'payment_method_subject_id' then
      perform lifeos._require_active('subjects', (c ->> 'payment_method_subject_id')::uuid);
    end if;
    if c ? 'merchant_subject_id' and jsonb_typeof(c -> 'merchant_subject_id') <> 'null' then
      perform lifeos._require_active('subjects', (c ->> 'merchant_subject_id')::uuid);
    end if;
    if c ? 'lines' then
      delete from lifeos.expense_lines where expense_id = p_id;
      perform lifeos._expense_lines_insert(p_id, c -> 'lines', true);
    end if;
    perform lifeos._update_row('expenses', p_id, c - 'lines');
  else
    c := lifeos._prep_changes(c, p_required => array['transaction_date', 'refund_amount', 'line_type'],
                              p_objects => array['metadata']);
    if c ? 'refund_amount' then
      v_amount := (c ->> 'refund_amount')::numeric;
      if v_amount <= 0 then
        raise exception 'invalid input' using detail = 'refund_amount is positive';
      end if;
      c := c || jsonb_build_object('expense_total', -v_amount);
      v_line := v_line || jsonb_build_object('unit_price', -v_amount, 'line_total', -v_amount);
    end if;
    if c ? 'line_type' then
      if c ->> 'line_type' not in ('item', 'charge', 'adjustment') then
        raise exception 'invalid input' using detail = 'line_type is item, charge or adjustment';
      end if;
      v_line := v_line || jsonb_build_object('line_type', c -> 'line_type');
    end if;
    if c ? 'item_description' then
      v_line := v_line || jsonb_build_object('item_description', c -> 'item_description');
    end if;
    if c ? 'item_subject_id' then
      if jsonb_typeof(c -> 'item_subject_id') <> 'null' then
        perform lifeos._require_active('subjects', (c ->> 'item_subject_id')::uuid);
      end if;
      v_line := v_line || jsonb_build_object('item_subject_id', c -> 'item_subject_id');
    end if;
    if v_line <> '{}'::jsonb then
      perform lifeos._update_row('expense_lines', l.id, v_line)
      from lifeos.expense_lines l where l.expense_id = p_id;
    end if;
    perform lifeos._update_row('expenses', p_id,
      c - 'refund_amount' - 'item_description' - 'item_subject_id' - 'line_type');
  end if;

  -- F2 and F-Q1: the Refund limits apply to the state after the correction.
  -- A violation raises an exception, so the change and its snapshot are rolled back.
  select * into y from lifeos.expenses where id = p_id;
  if y.expense_type = 'refund' then
    -- A Refund of a deleted purchase has no limit (Contract 6.7 item 3).
    if o.id is not null and o.deleted_at is null then
      if y.transaction_date < o.transaction_date then
        raise exception 'invalid input' using detail = 'transaction_date is on or after the original transaction_date';
      end if;
      select coalesce(sum(-r.expense_total), 0) into v_refunded
      from lifeos.expenses r
      where r.refund_of = o.id and r.expense_type = 'refund' and r.deleted_at is null and r.id <> y.id;
      if v_refunded - y.expense_total > o.expense_total then
        raise exception 'invalid input' using detail = format('refund_amount with other Refunds (%s) is above the original total %s',
                                                             v_refunded, o.expense_total);
      end if;
    end if;
  else
    select coalesce(sum(-r.expense_total), 0), min(r.transaction_date) into v_refunded, v_first_refund
    from lifeos.expenses r
    where r.refund_of = y.id and r.expense_type = 'refund' and r.deleted_at is null;
    if y.expense_total < v_refunded then
      raise exception 'invalid input' using detail = format('expense_total is at least the active Refunds total %s', v_refunded);
    end if;
    if y.transaction_date > v_first_refund then
      raise exception 'invalid input' using detail = format('transaction_date is on or before the earliest active Refund date %s',
                                                           v_first_refund);
    end if;
  end if;

  return (select lifeos._expense_json(z) from lifeos.expenses z where z.id = p_id);
end $$;

create or replace function lifeos.expense_history(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  v_history jsonb;
begin
  select * into x from lifeos.expenses where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  -- Each stored row is the snapshot of version n and the reason for the change to version n + 1.
  with v as (
    select h.version_no, h.snapshot, h.correction_reason, h.corrected_at
    from lifeos.expense_versions h where h.expense_id = p_id
    union all
    select (select count(*) + 1 from lifeos.expense_versions h where h.expense_id = p_id)::integer,
           lifeos._expense_core(x), null, null
  ), w as (
    select v.version_no, v.snapshot,
           lag(v.correction_reason) over (order by v.version_no) as correction_reason,
           lag(v.corrected_at) over (order by v.version_no) as corrected_at
    from v
  )
  select jsonb_agg(jsonb_build_object('version', w.version_no, 'snapshot', w.snapshot,
                                      'correction_reason', w.correction_reason,
                                      'corrected_at', lifeos._ts(w.corrected_at)) order by w.version_no)
    into v_history
  from w;
  return jsonb_build_object('id', p_id, 'history', v_history);
end $$;

-- Deleting a purchase also deletes its active Refunds, each with its own snapshot (M-0021 D7).
create or replace function lifeos.expense_delete(p_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  x lifeos.expenses;
  r lifeos.expenses;
  v_reason text;
  v_result jsonb;
  v_refunds jsonb := '[]'::jsonb;
begin
  if p_text is null or btrim(p_text) = '' then
    raise exception 'invalid input' using detail = 'p_text is the required deletion reason';
  end if;
  v_reason := btrim(p_text);
  select * into x from lifeos.expenses where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if x.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(x.deleted_at), 'deleted_refund_ids', '[]'::jsonb);
  end if;
  perform lifeos._expense_snapshot(x, v_reason);
  v_result := lifeos._soft_delete('expenses', p_id);
  if x.expense_type = 'purchase' then
    for r in select * from lifeos.expenses e
             where e.refund_of = p_id and e.deleted_at is null
             order by e.transaction_date, e.created_at, e.id
             for update loop
      perform lifeos._expense_snapshot(r, v_reason);
      perform lifeos._soft_delete('expenses', r.id);
      v_refunds := v_refunds || jsonb_build_array(r.id);
    end loop;
  end if;
  return v_result || jsonb_build_object('deleted_refund_ids', v_refunds);
end $$;

-- A Refund is at most the original total, together with the active Refunds of the same
-- original, and is dated on or after the original transaction date (M-0020 S5).
create or replace function lifeos.expense_refund_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  o lifeos.expenses;
  v_amount numeric;
  v_refunded numeric;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['refund_of', 'refund_amount', 'transaction_date', 'transaction_time',
    'item_description', 'item_subject_id', 'line_type', 'remarks', 'metadata']);
  perform lifeos._require(v, array['refund_of', 'refund_amount', 'transaction_date', 'line_type']);
  perform lifeos._check_types(v, p_dates => array['transaction_date'], p_times => array['transaction_time'],
                              p_uuids => array['refund_of', 'item_subject_id'], p_nums => array['refund_amount'],
                              p_objects => array['metadata']);
  select * into o from lifeos.expenses where id = (v ->> 'refund_of')::uuid for update;
  if not found then
    raise exception 'record not found' using detail = 'refund_of';
  end if;
  if o.deleted_at is not null then
    raise exception 'record deleted' using detail = 'refund_of';
  end if;
  if o.expense_type <> 'purchase' then
    raise exception 'invalid relationship' using detail = 'the original is a purchase Expense';
  end if;
  v_amount := (v ->> 'refund_amount')::numeric;
  if v_amount <= 0 then
    raise exception 'invalid input' using detail = 'refund_amount is positive';
  end if;
  if v ->> 'line_type' not in ('item', 'charge', 'adjustment') then
    raise exception 'invalid input' using detail = 'line_type is item, charge or adjustment';
  end if;
  if (v ->> 'transaction_date')::date < o.transaction_date then
    raise exception 'invalid input' using detail = 'transaction_date is on or after the original transaction_date';
  end if;
  select coalesce(sum(-r.expense_total), 0) into v_refunded
  from lifeos.expenses r
  where r.refund_of = o.id and r.expense_type = 'refund' and r.deleted_at is null;
  if v_refunded + v_amount > o.expense_total then
    raise exception 'invalid input' using detail = format('refund_amount with earlier Refunds (%s) is above the original total %s',
                                                         v_refunded, o.expense_total);
  end if;
  if v ? 'item_subject_id' and jsonb_typeof(v -> 'item_subject_id') <> 'null' then
    perform lifeos._require_active('subjects', (v ->> 'item_subject_id')::uuid);
  end if;

  v_id := lifeos._insert_row('expenses', lifeos._strip_top_nulls(jsonb_build_object(
    'expense_type', 'refund',
    'refund_of', o.id,
    'transaction_date', v -> 'transaction_date',
    'transaction_time', v -> 'transaction_time',
    'merchant_name', o.merchant_name,
    'branch', o.branch,
    'merchant_subject_id', o.merchant_subject_id,
    'seller_name', o.seller_name,
    'payment_method_subject_id', o.payment_method_subject_id,
    'expense_total', -v_amount,
    'currency', o.currency,
    'remarks', lifeos._remarks_normalize(v -> 'remarks'),
    'metadata', coalesce(v -> 'metadata', '{}'::jsonb))));

  perform lifeos._insert_row('expense_lines', lifeos._strip_top_nulls(jsonb_build_object(
    'expense_id', v_id,
    'line_no', 1,
    'line_type', v ->> 'line_type',
    'item_description', v -> 'item_description',
    'quantity', 1,
    'unit_price', -v_amount,
    'line_total', -v_amount,
    'category', null,
    'tags', '[]'::jsonb,
    'item_subject_id', v -> 'item_subject_id')));

  return (select lifeos._expense_json(x) from lifeos.expenses x where x.id = v_id)
         || jsonb_build_object('original', lifeos._expense_original(o.id));
end $$;

-- by_category and by_tag skip Lines with line_type = 'adjustment' (M-0018 D2).
create or replace function lifeos.expense_spending_report(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_from date;
  v_to date;
  v_currency text;
  v_cur text;
  v_out jsonb := '[]'::jsonb;
  v_total numeric;
  v_count integer;
  v_adj numeric;
begin
  perform lifeos._check_fields(f, array['from_date', 'to_date', 'currency']);
  perform lifeos._require(f, array['from_date', 'to_date']);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  if v_from > v_to then
    raise exception 'invalid input' using detail = 'from_date is after to_date';
  end if;
  v_currency := upper(nullif(btrim(f ->> 'currency'), ''));

  for v_cur in
    select c from (
      select x.currency as c from lifeos.expenses x
      where x.deleted_at is null and x.transaction_date between v_from and v_to
      union
      select r.currency from lifeos.expenses r join lifeos.expenses o on o.id = r.refund_of
      where r.deleted_at is null and r.expense_type = 'refund' and r.transaction_date > v_to
        and o.deleted_at is null and o.transaction_date between v_from and v_to
      union
      select v_currency where v_currency is not null
    ) s
    where v_currency is null or c = v_currency
    order by c
  loop
    select coalesce(sum(x.expense_total), 0), count(*) into v_total, v_count
    from lifeos.expenses x
    where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to;

    select coalesce(sum(l.line_total), 0) into v_adj
    from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
    where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
      and x.expense_type = 'purchase' and l.line_type = 'adjustment';

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'currency', v_cur,
      'parts', jsonb_build_array(
        jsonb_build_object('part', 1, 'name', 'total_spent', 'total', v_total, 'expense_count', v_count),
        jsonb_build_object('part', 2, 'name', 'by_payment_method', 'items', coalesce((
          select jsonb_agg(jsonb_build_object('payment_method_subject_id', g.pm, 'payment_method_name', g.name,
                                              'total', g.total) order by g.total desc, g.name)
          from (select x.payment_method_subject_id as pm, s.name, sum(x.expense_total) as total
                from lifeos.expenses x left join lifeos.subjects s on s.id = x.payment_method_subject_id
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                group by x.payment_method_subject_id, s.name) g), '[]'::jsonb)),
        jsonb_build_object('part', 3, 'name', 'by_category', 'items', coalesce((
          select jsonb_agg(jsonb_build_object('category', g.category, 'total', g.total) order by g.total desc, g.category)
          from (select l.category, sum(l.line_total) as total
                from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                  and x.expense_type = 'purchase' and l.line_type <> 'adjustment'
                group by l.category) g), '[]'::jsonb)),
        jsonb_build_object('part', 4, 'name', 'by_tag', 'items', coalesce((
          select jsonb_agg(jsonb_build_object('tag', g.tag, 'total', g.total) order by g.total desc, g.tag)
          from (select t.tag, sum(l.line_total) as total
                from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
                cross join lateral unnest(l.tags) as t(tag)
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                  and x.expense_type = 'purchase' and l.line_type <> 'adjustment'
                group by t.tag) g), '[]'::jsonb)),
        jsonb_build_object('part', 5, 'name', 'adjustments', 'total', v_adj, 'items', coalesce((
          select jsonb_agg(jsonb_build_object('merchant_name', g.merchant_name, 'merchant_subject_id', g.merchant_subject_id,
                                              'total', g.total) order by g.total asc, g.merchant_name)
          from (select x.merchant_name, x.merchant_subject_id, sum(l.line_total) as total
                from lifeos.expense_lines l join lifeos.expenses x on x.id = l.expense_id
                where x.deleted_at is null and x.currency = v_cur and x.transaction_date between v_from and v_to
                  and x.expense_type = 'purchase' and l.line_type = 'adjustment'
                group by x.merchant_name, x.merchant_subject_id) g), '[]'::jsonb))),
      'refunds_in_period', coalesce((
        select jsonb_agg(jsonb_build_object('id', r.id, 'refund_of', o.id, 'transaction_date', r.transaction_date,
                                            'expense_total', r.expense_total,
                                            'original_transaction_date', o.transaction_date,
                                            'original_total', o.expense_total) order by r.transaction_date, r.created_at)
        from lifeos.expenses r
        left join lifeos.expenses o on o.id = r.refund_of and o.deleted_at is null
        where r.deleted_at is null and r.expense_type = 'refund' and r.currency = v_cur
          and r.transaction_date between v_from and v_to), '[]'::jsonb),
      'later_refunds', coalesce((
        select jsonb_agg(jsonb_build_object('id', r.id, 'refund_of', o.id, 'transaction_date', r.transaction_date,
                                            'expense_total', r.expense_total,
                                            'original_transaction_date', o.transaction_date) order by r.transaction_date, r.created_at)
        from lifeos.expenses r join lifeos.expenses o on o.id = r.refund_of
        where r.deleted_at is null and r.expense_type = 'refund' and r.currency = v_cur and r.transaction_date > v_to
          and o.deleted_at is null and o.transaction_date between v_from and v_to), '[]'::jsonb)));
  end loop;

  return jsonb_build_object('from_date', v_from, 'to_date', v_to, 'currencies', v_out);
end $$;

create or replace function lifeos.expense_category_list()
returns jsonb language sql security definer set search_path = lifeos, pg_temp
as $$ select jsonb_build_object('categories', to_jsonb(lifeos._expense_categories())) $$;

-- =============================================================================
-- 8. Divination & Reflection (Contract Chapter 7)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Builders
-- -----------------------------------------------------------------------------

create or replace function lifeos._analysis_json(a lifeos.analyses)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$ select lifeos._row_json(a) $$;

-- Complete Reading with story_person_ids and analyses. Analyses deleted together with the Reading stay visible on its read.
create or replace function lifeos._reading_json(r lifeos.readings, p_with_links boolean default false)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(r)
    || jsonb_build_object(
         'story_person_ids', coalesce((
            select jsonb_agg(sp.id order by rsp.created_at, sp.id)
            from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
            where rsp.reading_id = r.id and sp.deleted_at is null), '[]'::jsonb),
         'analyses', coalesce((
            select jsonb_agg(lifeos._analysis_json(a) order by a.analysis_date, a.created_at)
            from lifeos.analyses a
            where a.reading_id = r.id and (a.deleted_at is null or a.deleted_at = r.deleted_at)), '[]'::jsonb))
    || case when p_with_links then jsonb_build_object('links', lifeos._links('reading', r.id)) else '{}'::jsonb end
$$;

-- Complete Divination Record with readings and record_analyses (combined Analyses).
create or replace function lifeos._divination_json(d lifeos.divination_records, p_with_links boolean default false)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(d)
    || jsonb_build_object(
         'readings', coalesce((
            select jsonb_agg(lifeos._reading_json(r, p_with_links) order by r.reading_date, r.reading_time nulls last, r.created_at)
            from lifeos.readings r
            where r.divination_record_id = d.id and (r.deleted_at is null or r.deleted_at = d.deleted_at)), '[]'::jsonb),
         'record_analyses', coalesce((
            select jsonb_agg(lifeos._analysis_json(a) order by a.analysis_date, a.created_at)
            from lifeos.analyses a
            where a.divination_record_id = d.id and a.reading_id is null
              and (a.deleted_at is null or a.deleted_at = d.deleted_at)), '[]'::jsonb))
$$;

create or replace function lifeos._story_person_json(s lifeos.story_persons)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s)
    || jsonb_build_object('subject_id', (select x.id from lifeos.subjects x where x.id = s.subject_id and x.deleted_at is null))
$$;

create or replace function lifeos._storyline_json(s lifeos.storylines)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(s)
    || jsonb_build_object('story_person_ids', coalesce((
         select jsonb_agg(sp.id order by ssp.created_at, sp.id)
         from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
         where ssp.storyline_id = s.id and sp.deleted_at is null), '[]'::jsonb))
$$;

-- -----------------------------------------------------------------------------
-- Insert helpers
-- -----------------------------------------------------------------------------

-- Validates a story_person_ids array: each value is an active Story Person.
create or replace function lifeos._story_person_ids(p jsonb)
returns uuid[] language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_ids uuid[] := lifeos._uuid_list(p);
  v_id uuid;
begin
  foreach v_id in array v_ids loop
    perform lifeos._require_active('story_persons', v_id);
  end loop;
  return v_ids;
end $$;

create or replace function lifeos._analysis_insert(p_record_id uuid, p_reading_id uuid, p_input jsonb, p_default_date date)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
begin
  perform lifeos._check_fields(v, array['source', 'overall_outcome', 'key_reasoning', 'story_context', 'analysis_date',
                                        'metadata']);
  perform lifeos._require(v, array['source', 'overall_outcome', 'key_reasoning']);
  perform lifeos._check_types(v, p_dates => array['analysis_date'], p_objects => array['metadata']);
  return lifeos._insert_row('analyses',
    jsonb_build_object('analysis_date', p_default_date)
    || lifeos._strip_top_nulls(v)
    || jsonb_build_object('divination_record_id', p_record_id, 'reading_id', p_reading_id));
end $$;

-- Validates and inserts one Reading with its story persons and Analyses. Returns the new ID.
create or replace function lifeos._reading_insert(p_record_id uuid, p_input jsonb, p_default_date date,
                                                  p_analysis_default_date date)
returns uuid language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
  v_persons uuid[];
  v_analysis jsonb;
begin
  perform lifeos._check_fields(v, array['question', 'method', 'spread_name', 'result_text', 'reading_date', 'reading_time',
                                        'story_person_ids', 'analyses', 'metadata']);
  perform lifeos._require(v, array['question', 'method', 'result_text']);
  perform lifeos._check_types(v, p_dates => array['reading_date'], p_times => array['reading_time'],
                              p_objects => array['metadata']);
  if v ->> 'method' not in ('i_ching', 'tarot') then
    raise exception 'invalid input' using detail = 'method is i_ching or tarot';
  end if;
  if v ? 'analyses' and jsonb_typeof(v -> 'analyses') not in ('array', 'null') then
    raise exception 'invalid input' using detail = 'analyses must be an array';
  end if;
  v_persons := lifeos._story_person_ids(v -> 'story_person_ids');

  v_id := lifeos._insert_row('readings',
    jsonb_build_object('reading_date', p_default_date)
    || lifeos._strip_top_nulls(v - 'story_person_ids' - 'analyses')
    || jsonb_build_object('divination_record_id', p_record_id));

  insert into lifeos.reading_story_persons (reading_id, story_person_id)
  select v_id, u from unnest(v_persons) u;

  for v_analysis in select value from jsonb_array_elements(coalesce(nullif(v -> 'analyses', 'null'::jsonb), '[]'::jsonb)) loop
    perform lifeos._analysis_insert(p_record_id, v_id, v_analysis, p_analysis_default_date);
  end loop;
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- 7.1 Divination Record and Reading
-- -----------------------------------------------------------------------------

create or replace function lifeos.divination_record_save(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_session date;
  v_id uuid;
  v_item jsonb;
begin
  perform lifeos._check_fields(v, array['session_date', 'title', 'topic', 'metadata', 'readings', 'record_analyses']);
  perform lifeos._require(v, array['readings']);
  perform lifeos._check_types(v, p_dates => array['session_date'], p_objects => array['metadata']);
  if jsonb_typeof(v -> 'readings') <> 'array' or jsonb_array_length(v -> 'readings') = 0 then
    raise exception 'invalid input' using detail = 'readings needs at least one item';
  end if;
  if v ? 'record_analyses' and jsonb_typeof(v -> 'record_analyses') not in ('array', 'null') then
    raise exception 'invalid input' using detail = 'record_analyses must be an array';
  end if;
  v_session := coalesce((nullif(v ->> 'session_date', ''))::date, lifeos._kl_today());

  v_id := lifeos._insert_row('divination_records',
    lifeos._strip_top_nulls(v - 'readings' - 'record_analyses') || jsonb_build_object('session_date', v_session));

  for v_item in select value from jsonb_array_elements(v -> 'readings') loop
    perform lifeos._reading_insert(v_id, v_item, v_session, v_session);
  end loop;
  for v_item in select value from jsonb_array_elements(coalesce(nullif(v -> 'record_analyses', 'null'::jsonb), '[]'::jsonb)) loop
    perform lifeos._analysis_insert(v_id, null, v_item, v_session);
  end loop;

  return (select lifeos._divination_json(d, false) from lifeos.divination_records d where d.id = v_id);
end $$;

create or replace function lifeos.divination_record_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  d lifeos.divination_records;
begin
  select * into d from lifeos.divination_records where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._divination_json(d, true);
end $$;

-- A subject_id or story_person_id filter of a deleted Record matches nothing (M-0021 D10).
create or replace function lifeos.divination_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_subject uuid;
  v_person uuid;
  v_method text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'subject_id', 'story_person_id', 'method', 'from_date',
                                        'to_date', 'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['subject_id', 'story_person_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_subject := (f ->> 'subject_id')::uuid;
  v_person := (f ->> 'story_person_id')::uuid;
  v_method := nullif(btrim(f ->> 'method'), '');
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  with rd as (
    select r.*
    from lifeos.readings r join lifeos.divination_records d on d.id = r.divination_record_id
    where (v_inc or (r.deleted_at is null and d.deleted_at is null))
      and (v_method is null or r.method = v_method)
      and (v_from is null or r.reading_date >= v_from)
      and (v_to is null or r.reading_date <= v_to)
      and (v_pat is null or d.title ilike v_pat or d.topic ilike v_pat or r.question ilike v_pat or r.result_text ilike v_pat)
      and (v_person is null
           or (exists (select 1 from lifeos.reading_story_persons rsp
                       where rsp.reading_id = r.id and rsp.story_person_id = v_person)
               and exists (select 1 from lifeos.story_persons sp where sp.id = v_person and sp.deleted_at is null)))
      and (v_subject is null
           or (exists (select 1 from lifeos.subjects s where s.id = v_subject and s.deleted_at is null)
               and (exists (select 1 from lifeos.record_links l
                            where (l.record_type_a = 'reading' and l.record_id_a = r.id and l.record_type_b = 'subject' and l.record_id_b = v_subject)
                               or (l.record_type_b = 'reading' and l.record_id_b = r.id and l.record_type_a = 'subject' and l.record_id_a = v_subject))
                    or exists (select 1 from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
                               where rsp.reading_id = r.id and sp.subject_id = v_subject and sp.deleted_at is null))))
  ), g as (
    select rd.divination_record_id as id, max(rd.reading_date) as latest
    from rd group by rd.divination_record_id
    order by latest desc, rd.divination_record_id
    limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'session_date', d.session_date,
           'title', d.title,
           'topic', d.topic,
           'deleted_at', lifeos._ts(d.deleted_at),
           'readings', (
             select jsonb_agg(jsonb_build_object(
                      'id', rd.id, 'question', rd.question, 'method', rd.method, 'result_text', rd.result_text,
                      'reading_date', rd.reading_date,
                      'analyses', coalesce((
                        select jsonb_agg(jsonb_build_object('overall_outcome', a.overall_outcome, 'source', a.source)
                                         order by a.analysis_date, a.created_at)
                        from lifeos.analyses a
                        where a.reading_id = rd.id and (v_inc or a.deleted_at is null)), '[]'::jsonb))
                    order by rd.reading_date desc, rd.reading_time desc nulls last, rd.created_at)
             from rd where rd.divination_record_id = d.id),
           'record_analyses', coalesce((
             select jsonb_agg(jsonb_build_object('overall_outcome', a.overall_outcome, 'source', a.source)
                              order by a.analysis_date, a.created_at)
             from lifeos.analyses a
             where a.divination_record_id = d.id and a.reading_id is null and (v_inc or a.deleted_at is null)), '[]'::jsonb))
         order by g.latest desc, g.id), '[]'::jsonb)
    into v_res
  from g join lifeos.divination_records d on d.id = g.id;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.divination_record_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  d lifeos.divination_records;
  v jsonb;
begin
  select * into d from lifeos.divination_records where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if d.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'topic', 'session_date', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['session_date'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['session_date'], p_objects => array['metadata']);
  perform lifeos._update_row('divination_records', p_id, v);
  return (select lifeos._divination_json(x, false) from lifeos.divination_records x where x.id = p_id);
end $$;

create or replace function lifeos.divination_record_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  d lifeos.divination_records;
  v_now timestamptz := now();
begin
  select * into d from lifeos.divination_records where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if d.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(d.deleted_at));
  end if;
  update lifeos.divination_records set deleted_at = v_now, updated_at = v_now where id = p_id;
  update lifeos.readings set deleted_at = v_now, updated_at = v_now
   where divination_record_id = p_id and deleted_at is null;
  update lifeos.analyses set deleted_at = v_now, updated_at = v_now
   where divination_record_id = p_id and deleted_at is null;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_now));
end $$;

create or replace function lifeos.reading_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_record uuid;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['divination_record_id', 'question', 'method', 'spread_name', 'result_text',
                                        'reading_date', 'reading_time', 'story_person_ids', 'analyses', 'metadata']);
  perform lifeos._require(v, array['divination_record_id', 'question', 'method', 'result_text']);
  perform lifeos._check_types(v, p_uuids => array['divination_record_id']);
  v_record := (v ->> 'divination_record_id')::uuid;
  perform lifeos._require_active('divination_records', v_record);
  v_id := lifeos._reading_insert(v_record, v - 'divination_record_id', lifeos._kl_today(), lifeos._kl_today());
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = v_id);
end $$;

-- Changes only the association. updated_at stays (M-0020 D4).
create or replace function lifeos.reading_story_persons_set(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_persons uuid[];
begin
  perform lifeos._check_fields(v, array['story_person_ids']);
  if not (v ? 'story_person_ids') or jsonb_typeof(v -> 'story_person_ids') <> 'array' then
    raise exception 'invalid input' using detail = 'story_person_ids is a required array';
  end if;
  perform lifeos._require_active('readings', p_id);
  v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
  delete from lifeos.reading_story_persons where reading_id = p_id;
  insert into lifeos.reading_story_persons (reading_id, story_person_id) select p_id, u from unnest(v_persons) u;
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = p_id);
end $$;

create or replace function lifeos.reading_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  r lifeos.readings;
  v_now timestamptz := now();
begin
  select * into r from lifeos.readings where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(r.deleted_at));
  end if;
  update lifeos.readings set deleted_at = v_now, updated_at = v_now where id = p_id;
  update lifeos.analyses set deleted_at = v_now, updated_at = v_now where reading_id = p_id and deleted_at is null;
  return jsonb_build_object('id', p_id, 'deleted_at', lifeos._ts(v_now));
end $$;

-- -----------------------------------------------------------------------------
-- 7.2 Analysis
-- -----------------------------------------------------------------------------

create or replace function lifeos.analysis_add(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  r lifeos.readings;
  v_record uuid;
  v_reading uuid;
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['reading_id', 'divination_record_id', 'source', 'overall_outcome', 'key_reasoning',
                                        'story_context', 'analysis_date', 'metadata']);
  perform lifeos._check_types(v, p_uuids => array['reading_id', 'divination_record_id']);
  v := lifeos._strip_top_nulls(v);
  if not (v ? 'reading_id') and not (v ? 'divination_record_id') then
    raise exception 'invalid input' using detail = 'reading_id or divination_record_id is required';
  end if;
  if v ? 'reading_id' then
    v_reading := (v ->> 'reading_id')::uuid;
    select * into r from lifeos.readings where id = v_reading;
    if not found then
      raise exception 'record not found' using detail = 'reading_id';
    end if;
    if r.deleted_at is not null then
      raise exception 'record deleted' using detail = 'reading_id';
    end if;
    if v ? 'divination_record_id' and (v ->> 'divination_record_id')::uuid <> r.divination_record_id then
      raise exception 'invalid relationship' using detail = 'the Reading belongs to another Divination Record';
    end if;
    v_record := r.divination_record_id;
  else
    v_record := (v ->> 'divination_record_id')::uuid;
  end if;
  perform lifeos._require_active('divination_records', v_record);
  v_id := lifeos._analysis_insert(v_record, v_reading, v - 'reading_id' - 'divination_record_id', lifeos._kl_today());
  return (select lifeos._analysis_json(a) from lifeos.analyses a where a.id = v_id);
end $$;

create or replace function lifeos.analysis_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('analyses', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 7.3 Reading Remark
-- -----------------------------------------------------------------------------

-- updated_at stays (M-0018 D5).
create or replace function lifeos.reading_remark_add(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
begin
  perform lifeos._check_fields(v, array['text', 'storyline_id']);
  perform lifeos._require(v, array['text']);
  perform lifeos._check_types(v, p_uuids => array['storyline_id']);
  perform lifeos._require_active('readings', p_id);
  update lifeos.readings
     set remark_entries = remark_entries || jsonb_build_array(jsonb_build_object(
           'entry_id', gen_random_uuid(),
           'timestamp', lifeos._ts(now()),
           'storyline_id', nullif(v ->> 'storyline_id', '')::uuid,
           'text', btrim(v ->> 'text')))
   where id = p_id;
  return (select lifeos._reading_json(r, false) from lifeos.readings r where r.id = p_id);
end $$;

-- The entry gets the supplied text and storyline_id. entry_id, timestamp and updated_at
-- stay (J-0018 F1).
create or replace function lifeos.reading_remark_update(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  r lifeos.readings;
  v_index integer;
  v_entry jsonb;
begin
  perform lifeos._check_fields(v, array['entry_id', 'text', 'storyline_id']);
  perform lifeos._require(v, array['entry_id', 'text']);
  perform lifeos._check_types(v, p_uuids => array['entry_id', 'storyline_id']);
  select * into r from lifeos.readings where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  select e.ord - 1, e.value into v_index, v_entry
  from jsonb_array_elements(r.remark_entries) with ordinality e(value, ord)
  where e.value ->> 'entry_id' = v ->> 'entry_id';
  if v_index is null then
    raise exception 'record not found' using detail = 'entry_id';
  end if;
  v_entry := jsonb_build_object(
    'entry_id', v_entry -> 'entry_id',
    'timestamp', v_entry -> 'timestamp',
    'storyline_id', nullif(v ->> 'storyline_id', '')::uuid,
    'text', btrim(v ->> 'text'));
  update lifeos.readings
     set remark_entries = jsonb_set(remark_entries, array[v_index::text], v_entry)
   where id = p_id;
  return (select lifeos._reading_json(x, false) from lifeos.readings x where x.id = p_id);
end $$;

-- Removes one Reading Remark entry. updated_at and the Analyses stay (M-0020 F1, D2).
create or replace function lifeos.reading_remark_delete(p_id uuid, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  r lifeos.readings;
  v_index integer;
begin
  perform lifeos._check_fields(v, array['entry_id']);
  perform lifeos._require(v, array['entry_id']);
  perform lifeos._check_types(v, p_uuids => array['entry_id']);
  select * into r from lifeos.readings where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if r.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  select e.ord - 1 into v_index
  from jsonb_array_elements(r.remark_entries) with ordinality e(value, ord)
  where e.value ->> 'entry_id' = v ->> 'entry_id';
  if v_index is null then
    raise exception 'record not found' using detail = 'entry_id';
  end if;
  update lifeos.readings set remark_entries = remark_entries - v_index where id = p_id;
  return (select lifeos._reading_json(x, false) from lifeos.readings x where x.id = p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 7.4 Story Person
-- -----------------------------------------------------------------------------

create or replace function lifeos.story_person_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['name', 'gender', 'description', 'aliases', 'subject_id', 'metadata']);
  perform lifeos._require(v, array['name']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['subject_id'], p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);
  if v ? 'subject_id' then
    perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  end if;
  v_id := lifeos._insert_row('story_persons', v);
  return (select lifeos._story_person_json(s) from lifeos.story_persons s where s.id = v_id);
end $$;

create or replace function lifeos.story_person_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.story_persons;
begin
  select * into s from lifeos.story_persons where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._story_person_json(s) || jsonb_build_object(
    'storyline_ids', coalesce((
      select jsonb_agg(sl.id order by sl.occurrence_date desc nulls last, sl.created_at desc)
      from lifeos.storyline_story_persons ssp join lifeos.storylines sl on sl.id = ssp.storyline_id
      where ssp.story_person_id = p_id and sl.deleted_at is null), '[]'::jsonb),
    'reading_ids', coalesce((
      select jsonb_agg(r.id order by r.reading_date desc, r.created_at desc)
      from lifeos.reading_story_persons rsp join lifeos.readings r on r.id = rsp.reading_id
      where rsp.story_person_id = p_id and r.deleted_at is null), '[]'::jsonb));
end $$;

-- A subject_id filter of a deleted Subject matches nothing (M-0021 D10).
create or replace function lifeos.story_person_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_gender text;
  v_subject uuid;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'gender', 'subject_id', 'include_deleted', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['subject_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_gender := nullif(btrim(f ->> 'gender'), '');
  v_subject := (f ->> 'subject_id')::uuid;

  select coalesce(jsonb_agg(lifeos._story_person_json(s) order by s.updated_at desc, s.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.story_persons s
    where (v_inc or s.deleted_at is null)
      and (v_gender is null or lower(s.gender) = lower(v_gender))
      and (v_subject is null
           or (s.subject_id = v_subject
               and exists (select 1 from lifeos.subjects x where x.id = v_subject and x.deleted_at is null)))
      and (v_pat is null or s.name ilike v_pat or s.description ilike v_pat or lifeos._array_match(s.aliases, v_pat))
    order by s.updated_at desc, s.id
    limit v_limit offset v_offset
  ) s;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.story_person_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.story_persons;
  v jsonb;
begin
  select * into s from lifeos.story_persons where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['name', 'gender', 'description', 'aliases', 'subject_id', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['subject_id'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['name'], p_arrays => array['aliases'], p_objects => array['metadata']);
  if v ? 'subject_id' and jsonb_typeof(v -> 'subject_id') <> 'null' then
    perform lifeos._require_active('subjects', (v ->> 'subject_id')::uuid);
  end if;
  perform lifeos._update_row('story_persons', p_id, v);
  return (select lifeos._story_person_json(x) from lifeos.story_persons x where x.id = p_id);
end $$;

create or replace function lifeos.story_person_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('story_persons', p_id);
end $$;

-- -----------------------------------------------------------------------------
-- 7.5 Storyline
-- -----------------------------------------------------------------------------

-- An end date is never before the start date. The same day passes (M-0021 D8).
create or replace function lifeos.storyline_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_persons uuid[];
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['title', 'content', 'occurrence_date', 'occurrence_end_date', 'time_text',
                                        'story_person_ids', 'metadata']);
  perform lifeos._require(v, array['content']);
  perform lifeos._check_types(v, p_dates => array['occurrence_date', 'occurrence_end_date'], p_objects => array['metadata']);
  if (v ->> 'occurrence_end_date')::date < (v ->> 'occurrence_date')::date then
    raise exception 'invalid input' using detail = 'occurrence_end_date is before occurrence_date';
  end if;
  v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
  v_id := lifeos._insert_row('storylines', lifeos._strip_top_nulls(v - 'story_person_ids'));
  insert into lifeos.storyline_story_persons (storyline_id, story_person_id) select v_id, u from unnest(v_persons) u;
  return (select lifeos._storyline_json(s) from lifeos.storylines s where s.id = v_id);
end $$;

create or replace function lifeos.storyline_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.storylines;
begin
  select * into s from lifeos.storylines where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._storyline_json(s) || jsonb_build_object('links', lifeos._links('storyline', p_id));
end $$;

create or replace function lifeos.storyline_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_persons uuid[];
  v_match text;
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['story_person_ids', 'person_match', 'keyword', 'query', 'from_date', 'to_date',
                                        'include_deleted', 'limit', 'offset']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_persons := case when f ? 'story_person_ids' and jsonb_typeof(f -> 'story_person_ids') <> 'null'
                    then lifeos._uuid_list(f -> 'story_person_ids') end;
  if cardinality(v_persons) = 0 then
    v_persons := null;
  end if;
  v_match := coalesce(nullif(btrim(f ->> 'person_match'), ''), 'any');
  if v_match not in ('any', 'all') then
    raise exception 'invalid input' using detail = 'person_match is any or all';
  end if;
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._storyline_json(x) || jsonb_build_object('matched_person_ids', to_jsonb(s.matched))
                            order by s.occurrence_date desc nulls last, s.created_at desc, s.id), '[]'::jsonb)
    into v_res
  from (
    select sl.id, sl.occurrence_date, sl.created_at, m.matched
    from lifeos.storylines sl
    cross join lateral (
      select coalesce(array_agg(ssp.story_person_id order by ssp.story_person_id), '{}'::uuid[]) as matched
      from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
      where ssp.storyline_id = sl.id and sp.deleted_at is null
        and v_persons is not null and ssp.story_person_id = any (v_persons)
    ) m
    where (v_inc or sl.deleted_at is null)
      and (v_persons is null
           or (v_match = 'any' and cardinality(m.matched) > 0)
           or (v_match = 'all' and cardinality(m.matched) = cardinality(v_persons)))
      and (v_pat is null or sl.title ilike v_pat or sl.content ilike v_pat or sl.time_text ilike v_pat)
      and ((v_from is null and v_to is null)
           or (sl.occurrence_date is not null
               and (v_from is null or sl.occurrence_date >= v_from)
               and (v_to is null or sl.occurrence_date <= v_to)))
    order by sl.occurrence_date desc nulls last, sl.created_at desc, sl.id
    limit v_limit offset v_offset
  ) s
  join lifeos.storylines x on x.id = s.id;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

-- The end date check reads the dates after the change (M-0021 D8).
create or replace function lifeos.storyline_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  s lifeos.storylines;
  v jsonb;
  v_persons uuid[];
  v_start date;
  v_end date;
begin
  select * into s from lifeos.storylines where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if s.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['title', 'content', 'occurrence_date', 'occurrence_end_date', 'time_text',
                                               'story_person_ids', 'metadata']);
  perform lifeos._check_types(v, p_dates => array['occurrence_date', 'occurrence_end_date'], p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['content'], p_objects => array['metadata']);
  -- D8: the dates after the change. An omitted field keeps its stored value; null clears it.
  v_start := case when v ? 'occurrence_date' then (v ->> 'occurrence_date')::date else s.occurrence_date end;
  v_end := case when v ? 'occurrence_end_date' then (v ->> 'occurrence_end_date')::date else s.occurrence_end_date end;
  if v_end < v_start then
    raise exception 'invalid input' using detail = 'occurrence_end_date is before occurrence_date';
  end if;
  if v ? 'story_person_ids' then
    v_persons := lifeos._story_person_ids(v -> 'story_person_ids');
    delete from lifeos.storyline_story_persons where storyline_id = p_id;
    insert into lifeos.storyline_story_persons (storyline_id, story_person_id) select p_id, u from unnest(v_persons) u;
  end if;
  perform lifeos._update_row('storylines', p_id, v - 'story_person_ids');
  return (select lifeos._storyline_json(x) from lifeos.storylines x where x.id = p_id);
end $$;

create or replace function lifeos.storyline_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('storylines', p_id);
end $$;

-- =============================================================================
-- 9. Communication Assistant (Contract Chapter 8)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Builders
-- -----------------------------------------------------------------------------

create or replace function lifeos._profile_json(p lifeos.communication_profiles)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(p)
    || jsonb_build_object('person_subject_id',
         (select s.id from lifeos.subjects s where s.id = p.person_subject_id and s.deleted_at is null))
$$;

create or replace function lifeos._profile_compact(p_id uuid)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('id', p.id, 'profile_key', p.profile_key, 'profile_type', p.profile_type, 'name', p.name)
  from lifeos.communication_profiles p where p.id = p_id
$$;

create or replace function lifeos._rule_json(r lifeos.communication_rules)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$ select lifeos._row_json(r) $$;

create or replace function lifeos._message_json(m lifeos.communication_messages)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select lifeos._row_json(m)
    || jsonb_build_object('profile_id',
         (select p.id from lifeos.communication_profiles p where p.id = m.profile_id and p.deleted_at is null))
$$;

create or replace function lifeos._membership_json(m lifeos.communication_profile_memberships)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  select jsonb_build_object('child_profile_id', m.child_profile_id, 'parent_profile_id', m.parent_profile_id,
                            'priority', m.priority, 'metadata', m.metadata,
                            'created_at', lifeos._ts(m.created_at), 'updated_at', lifeos._ts(m.updated_at))
$$;

-- -----------------------------------------------------------------------------
-- Rule resolution helpers (Contract 8.2.3, 8.2.4)
-- -----------------------------------------------------------------------------

-- Checks the Profile used for Rule resolution. null means Global Rules only.
create or replace function lifeos._profile_for_rules(p_profile_id uuid)
returns void language plpgsql stable set search_path = lifeos, pg_temp
as $$
begin
  if p_profile_id is not null then
    perform lifeos._require_active('communication_profiles', p_profile_id);
  end if;
end $$;

-- Every current Rule that applies to a Profile and Language Mode, with its scope, depth and priority.
create or replace function lifeos._rule_candidates(p_profile_id uuid, p_language_mode text)
returns table (id uuid, dimension text, rule_key text, rule_text text, language_mode text, scope text,
               scope_rank integer, source_profile_id uuid, depth integer, priority integer, updated_at timestamptz)
language sql stable set search_path = lifeos, pg_temp
as $$
  with recursive anc (profile_id, depth, priority, path) as (
    select m.parent_profile_id, 1, m.priority, array[m.child_profile_id, m.parent_profile_id]
    from lifeos.communication_profile_memberships m
    join lifeos.communication_profiles pp on pp.id = m.parent_profile_id
    where p_profile_id is not null and m.child_profile_id = p_profile_id
      and pp.deleted_at is null and pp.profile_type = 'audience'
    union all
    select m.parent_profile_id, a.depth + 1, m.priority, a.path || m.parent_profile_id
    from anc a
    join lifeos.communication_profile_memberships m on m.child_profile_id = a.profile_id
    join lifeos.communication_profiles pp on pp.id = m.parent_profile_id
    where pp.deleted_at is null and pp.profile_type = 'audience' and not (m.parent_profile_id = any (a.path))
  ), best as (
    select distinct on (anc.profile_id) anc.profile_id, anc.depth, anc.priority
    from anc order by anc.profile_id, anc.depth, anc.priority desc
  ), lang as (
    select r.* from lifeos.communication_rules r
    where r.language_mode is null or (p_language_mode is not null and r.language_mode = p_language_mode)
  )
  select r.id, r.dimension, r.rule_key, r.rule_text, r.language_mode, 'profile', 0, r.profile_id, 0, null::integer, r.updated_at
  from lang r where p_profile_id is not null and r.profile_id = p_profile_id
  union all
  select r.id, r.dimension, r.rule_key, r.rule_text, r.language_mode, 'inherited', 1, b.profile_id, b.depth, b.priority, r.updated_at
  from lang r join best b on b.profile_id = r.profile_id
  union all
  select r.id, r.dimension, r.rule_key, r.rule_text, r.language_mode, 'global', 2, null::uuid, null::integer, null::integer, r.updated_at
  from lang r where r.profile_id is null
$$;

-- Effective Rules: one winning Rule per dimension and rule_key (Contract 8.2.4).
create or replace function lifeos._resolve(p_profile_id uuid, p_language_mode text)
returns jsonb language sql stable set search_path = lifeos, pg_temp
as $$
  with w as (
    select distinct on (c.dimension, c.rule_key) c.*
    from lifeos._rule_candidates(p_profile_id, p_language_mode) c
    order by c.dimension, c.rule_key, c.scope_rank, c.depth nulls last, c.priority desc nulls last,
             (c.language_mode is not null) desc, c.updated_at desc, c.id
  ), d as (
    select w.dimension,
           jsonb_agg(jsonb_build_object('id', w.id, 'rule_key', w.rule_key, 'rule_text', w.rule_text,
                                        'scope', w.scope, 'source_profile_id', w.source_profile_id) order by w.rule_key) as rules
    from w group by w.dimension
  )
  select jsonb_build_object(
    'profile', case when p_profile_id is null then null else lifeos._profile_compact(p_profile_id) end,
    'language_mode', p_language_mode,
    'effective_rules', coalesce((select jsonb_object_agg(d.dimension, d.rules) from d), '{}'::jsonb))
$$;

-- Creates or updates one current Rule (Contract 8.2.1). Returns the Rule plus action.
create or replace function lifeos._rule_upsert(p_input jsonb)
returns jsonb language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  c jsonb;
  v_id uuid;
  v_action text;
begin
  perform lifeos._check_fields(v, array['id', 'profile_id', 'language_mode', 'dimension', 'rule_key', 'rule_text', 'metadata']);
  perform lifeos._check_types(v, p_uuids => array['id', 'profile_id'], p_objects => array['metadata']);

  if v ? 'id' and jsonb_typeof(v -> 'id') <> 'null' then
    v_id := (v ->> 'id')::uuid;
    perform 1 from lifeos.communication_rules r where r.id = v_id for update;
    if not found then
      raise exception 'record not found';
    end if;
    c := lifeos._check_changes(v - 'id', array['profile_id', 'language_mode', 'dimension', 'rule_key', 'rule_text', 'metadata']);
    c := lifeos._prep_changes(c, p_required => array['dimension', 'rule_key', 'rule_text'], p_objects => array['metadata']);
    if c ? 'profile_id' and jsonb_typeof(c -> 'profile_id') <> 'null' then
      perform lifeos._require_active('communication_profiles', (c ->> 'profile_id')::uuid);
    end if;
    perform lifeos._update_row('communication_rules', v_id, c);
    v_action := 'updated';
  else
    v := lifeos._strip_top_nulls(v - 'id');
    perform lifeos._require(v, array['dimension', 'rule_key', 'rule_text']);
    if v ? 'profile_id' then
      perform lifeos._require_active('communication_profiles', (v ->> 'profile_id')::uuid);
    end if;
    select r.id into v_id
    from lifeos.communication_rules r
    where r.profile_id is not distinct from (v ->> 'profile_id')::uuid
      and r.language_mode is not distinct from (v ->> 'language_mode')
      and r.dimension = v ->> 'dimension'
      and r.rule_key = v ->> 'rule_key'
    for update;
    if v_id is not null then
      perform lifeos._update_row('communication_rules', v_id,
        jsonb_build_object('rule_text', v -> 'rule_text')
        || case when v ? 'metadata' then jsonb_build_object('metadata', v -> 'metadata') else '{}'::jsonb end);
      v_action := 'updated';
    else
      v_id := lifeos._insert_row('communication_rules', v);
      v_action := 'created';
    end if;
  end if;

  return (select lifeos._rule_json(r) from lifeos.communication_rules r where r.id = v_id)
         || jsonb_build_object('action', v_action);
end $$;

-- Physically removes one Rule (Contract 8.2.2).
create or replace function lifeos._rule_delete(p_id uuid)
returns jsonb language plpgsql volatile set search_path = lifeos, pg_temp
as $$
declare
  v_rows integer;
begin
  delete from lifeos.communication_rules where id = p_id;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('id', p_id, 'removed', v_rows > 0);
end $$;

-- Effective Rules plus recent finalized messages (Contract 8.3.1).
create or replace function lifeos._runtime_context(p_profile_id uuid, p_language_mode text, p_platform text,
                                                   p_history_limit integer)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_resolved jsonb;
begin
  if p_history_limit is null or p_history_limit < 0 then
    raise exception 'invalid input' using detail = 'history limit is zero or positive';
  end if;
  perform lifeos._profile_for_rules(p_profile_id);
  v_resolved := lifeos._resolve(p_profile_id, p_language_mode);
  return jsonb_build_object(
    'profile', v_resolved -> 'profile',
    'language_mode', p_language_mode,
    'platform', p_platform,
    'effective_rules', v_resolved -> 'effective_rules',
    'recent_messages', coalesce((
      select jsonb_agg(lifeos._message_json(y) order by s.platform_rank, s.finalized_at desc, s.id)
      from (
        select x.id, x.finalized_at,
               case when p_platform is not null and x.platform = p_platform then 0 else 1 end as platform_rank
        from lifeos.communication_messages x
        where x.deleted_at is null
          and x.profile_id is not distinct from p_profile_id
          and x.language_mode is not distinct from p_language_mode
        order by platform_rank, x.finalized_at desc, x.id
        limit p_history_limit
      ) s
      join lifeos.communication_messages y on y.id = s.id), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- 8.1 Profiles
-- -----------------------------------------------------------------------------

create or replace function lifeos.communication_profile_create(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_id uuid;
begin
  perform lifeos._check_fields(v, array['profile_key', 'profile_type', 'name', 'description', 'aliases', 'person_subject_id',
                                        'metadata']);
  perform lifeos._require(v, array['profile_key', 'profile_type', 'name']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['person_subject_id'],
                              p_objects => array['metadata']);
  v := lifeos._strip_top_nulls(v);
  if v ->> 'profile_type' not in ('person', 'group', 'audience') then
    raise exception 'invalid input' using detail = 'profile_type is person, group or audience';
  end if;
  if v ->> 'profile_type' = 'person' then
    perform lifeos._require(v, array['person_subject_id']);
    perform lifeos._require_active('subjects', (v ->> 'person_subject_id')::uuid);
    if exists (select 1 from lifeos.communication_profiles p
               where p.person_subject_id = (v ->> 'person_subject_id')::uuid and p.deleted_at is null) then
      raise exception 'invalid relationship' using detail = 'the Subject already has an active Person Profile';
    end if;
  elsif v ? 'person_subject_id' then
    raise exception 'invalid input' using detail = 'a Group or Audience Profile has no person_subject_id';
  end if;
  v_id := lifeos._insert_row('communication_profiles', v);
  return (select lifeos._profile_json(p) from lifeos.communication_profiles p where p.id = v_id);
end $$;

create or replace function lifeos.communication_profile_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  p lifeos.communication_profiles;
begin
  select * into p from lifeos.communication_profiles where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._profile_json(p) || jsonb_build_object('parent_profiles', coalesce((
    select jsonb_agg(jsonb_build_object('profile_id', pp.id, 'name', pp.name, 'priority', m.priority)
                     order by m.priority desc, pp.name)
    from lifeos.communication_profile_memberships m
    join lifeos.communication_profiles pp on pp.id = m.parent_profile_id
    where m.child_profile_id = p_id and pp.deleted_at is null), '[]'::jsonb));
end $$;

-- A person_subject_id filter of a deleted Subject matches nothing (M-0021 D10).
create or replace function lifeos.communication_profile_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_inc boolean;
  v_pat text;
  v_type text;
  v_subject uuid;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['keyword', 'query', 'profile_type', 'person_subject_id', 'include_deleted',
                                        'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['person_subject_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_inc := lifeos._bool_param(f, 'include_deleted', false);
  v_pat := lifeos._kw(f);
  v_type := nullif(btrim(f ->> 'profile_type'), '');
  v_subject := (f ->> 'person_subject_id')::uuid;

  select coalesce(jsonb_agg(lifeos._profile_json(p) order by p.name, p.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.communication_profiles p
    where (v_inc or p.deleted_at is null)
      and (v_type is null or p.profile_type = v_type)
      and (v_subject is null
           or (p.person_subject_id = v_subject
               and exists (select 1 from lifeos.subjects x where x.id = v_subject and x.deleted_at is null)))
      and (v_pat is null or p.name ilike v_pat or p.profile_key ilike v_pat or p.description ilike v_pat
           or lifeos._array_match(p.aliases, v_pat))
    order by p.name, p.id
    limit v_limit offset v_offset
  ) p;

  return lifeos._search_shape(v_res, v_limit, v_offset, v_inc);
end $$;

create or replace function lifeos.communication_profile_update(p_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  p lifeos.communication_profiles;
  v jsonb;
begin
  select * into p from lifeos.communication_profiles where id = p_id for update;
  if not found then
    raise exception 'record not found';
  end if;
  if p.deleted_at is not null then
    raise exception 'record deleted';
  end if;
  v := lifeos._check_changes(p_changes, array['profile_key', 'name', 'description', 'aliases', 'person_subject_id', 'metadata']);
  perform lifeos._check_types(v, p_arrays => array['aliases'], p_uuids => array['person_subject_id'],
                              p_objects => array['metadata']);
  v := lifeos._prep_changes(v, p_required => array['profile_key', 'name'], p_arrays => array['aliases'],
                            p_objects => array['metadata']);
  if v ? 'person_subject_id' then
    if p.profile_type = 'person' then
      if jsonb_typeof(v -> 'person_subject_id') = 'null' then
        raise exception 'invalid input' using detail = 'a Person Profile keeps exactly one person_subject_id';
      end if;
      perform lifeos._require_active('subjects', (v ->> 'person_subject_id')::uuid);
      if exists (select 1 from lifeos.communication_profiles x
                 where x.person_subject_id = (v ->> 'person_subject_id')::uuid and x.deleted_at is null and x.id <> p_id) then
        raise exception 'invalid relationship' using detail = 'the Subject already has an active Person Profile';
      end if;
    elsif jsonb_typeof(v -> 'person_subject_id') <> 'null' then
      raise exception 'invalid input' using detail = 'a Group or Audience Profile has no person_subject_id';
    end if;
  end if;
  perform lifeos._update_row('communication_profiles', p_id, v);
  return (select lifeos._profile_json(x) from lifeos.communication_profiles x where x.id = p_id);
end $$;

create or replace function lifeos.communication_profile_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('communication_profiles', p_id);
end $$;

create or replace function lifeos.communication_profile_membership_set(p_child_profile_id uuid, p_parent_profile_id uuid,
                                                                       p_priority integer default 0,
                                                                       p_metadata jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  parent lifeos.communication_profiles;
  m lifeos.communication_profile_memberships;
  v_metadata jsonb := lifeos._obj(p_metadata);
begin
  perform lifeos._require_active('communication_profiles', p_child_profile_id);
  select * into parent from lifeos.communication_profiles where id = p_parent_profile_id;
  if not found then
    raise exception 'record not found' using detail = 'parent profile';
  end if;
  if parent.deleted_at is not null then
    raise exception 'record deleted' using detail = 'parent profile';
  end if;
  if parent.profile_type <> 'audience' then
    raise exception 'invalid relationship' using detail = 'the parent is an Audience Profile';
  end if;
  if p_child_profile_id = p_parent_profile_id then
    raise exception 'invalid relationship' using detail = 'a Profile cannot inherit from itself';
  end if;
  -- A cycle forms when the child is already an ancestor of the parent.
  if exists (
    with recursive up (profile_id, path) as (
      select m2.parent_profile_id, array[m2.parent_profile_id]
      from lifeos.communication_profile_memberships m2 where m2.child_profile_id = p_parent_profile_id
      union all
      select m2.parent_profile_id, up.path || m2.parent_profile_id
      from up join lifeos.communication_profile_memberships m2 on m2.child_profile_id = up.profile_id
      where not (m2.parent_profile_id = any (up.path))
    )
    select 1 from up where up.profile_id = p_child_profile_id) then
    raise exception 'invalid relationship' using detail = 'the membership would create an inheritance cycle';
  end if;

  insert into lifeos.communication_profile_memberships (child_profile_id, parent_profile_id, priority, metadata)
  values (p_child_profile_id, p_parent_profile_id, coalesce(p_priority, 0), v_metadata)
  on conflict (child_profile_id, parent_profile_id)
  do update set priority = excluded.priority, metadata = excluded.metadata, updated_at = now()
  returning * into m;
  return lifeos._membership_json(m);
end $$;

create or replace function lifeos.communication_profile_membership_remove(p_child_profile_id uuid, p_parent_profile_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v_rows integer;
begin
  delete from lifeos.communication_profile_memberships
  where child_profile_id = p_child_profile_id and parent_profile_id = p_parent_profile_id;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('removed', v_rows > 0);
end $$;

-- Moves the Rules and the Message History of one Person Profile to the kept Person Profile,
-- then deletes the emptied Profile (Contract 8.1.8, M-0023 D5). A Rule conflict moves nothing.
-- Deleted Message History items move too and keep their deleted_at.
create or replace function lifeos.communication_profile_merge(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_keep uuid;
  v_merge uuid;
  k lifeos.communication_profiles;
  m lifeos.communication_profiles;
  v_conflicts text;
  v_deleted jsonb;
  n_rules integer := 0;
  n_messages integer := 0;
begin
  perform lifeos._check_fields(v, array['keep_id', 'merge_id']);
  perform lifeos._require(v, array['keep_id', 'merge_id']);
  perform lifeos._check_types(v, p_uuids => array['keep_id', 'merge_id']);
  v_keep := (v ->> 'keep_id')::uuid;
  v_merge := (v ->> 'merge_id')::uuid;
  if v_keep = v_merge then
    raise exception 'invalid relationship' using detail = 'keep_id and merge_id are the same Profile';
  end if;

  select * into k from lifeos.communication_profiles where id = v_keep for update;
  if not found then
    raise exception 'record not found' using detail = 'keep_id';
  end if;
  if k.deleted_at is not null then
    raise exception 'record deleted' using detail = 'keep_id';
  end if;
  select * into m from lifeos.communication_profiles where id = v_merge for update;
  if not found then
    raise exception 'record not found' using detail = 'merge_id';
  end if;
  if m.deleted_at is not null then
    raise exception 'record deleted' using detail = 'merge_id';
  end if;
  if k.profile_type <> 'person' then
    raise exception 'invalid relationship' using detail = 'keep_id is not a Person Profile';
  end if;
  if m.profile_type <> 'person' then
    raise exception 'invalid relationship' using detail = 'merge_id is not a Person Profile';
  end if;

  -- A Rule of merge_id with the same language_mode, dimension and rule_key as a Rule of keep_id is a conflict.
  select string_agg(format('%s/%s/%s', coalesce(r.language_mode, 'neutral'), r.dimension, r.rule_key), ', '
                    order by r.dimension, r.rule_key, r.language_mode nulls first)
    into v_conflicts
  from lifeos.communication_rules r
  join lifeos.communication_rules x
    on x.profile_id = v_keep
   and x.language_mode is not distinct from r.language_mode
   and x.dimension = r.dimension
   and x.rule_key = r.rule_key
  where r.profile_id = v_merge;
  if v_conflicts is not null then
    raise exception 'invalid relationship' using detail = format('both Profiles have the Rule: %s', v_conflicts);
  end if;

  -- Moved Rules and messages keep every other field, as in subject_merge (shared.md 5.7 item 7).
  update lifeos.communication_rules set profile_id = v_keep where profile_id = v_merge;
  get diagnostics n_rules = row_count;
  update lifeos.communication_messages set profile_id = v_keep where profile_id = v_merge;
  get diagnostics n_messages = row_count;

  v_deleted := lifeos._soft_delete('communication_profiles', v_merge);

  return jsonb_build_object(
    'profile', (select lifeos._profile_json(x) from lifeos.communication_profiles x where x.id = v_keep),
    'merged_id', v_merge,
    'deleted_at', v_deleted -> 'deleted_at',
    'moved', jsonb_build_object('rules', n_rules, 'messages', n_messages));
end $$;

-- -----------------------------------------------------------------------------
-- 8.2 Rules
-- -----------------------------------------------------------------------------

create or replace function lifeos.communication_rule_upsert(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._rule_upsert(p_input);
end $$;

create or replace function lifeos.communication_rule_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._rule_delete(p_id);
end $$;

create or replace function lifeos.communication_rule_state(p_profile_id uuid default null, p_language_mode text default null)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  perform lifeos._profile_for_rules(p_profile_id);
  return jsonb_build_object(
    'profile_id', p_profile_id,
    'language_mode', p_language_mode,
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'dimension', c.dimension, 'rule_key', c.rule_key,
                                          'rule_text', c.rule_text, 'language_mode', c.language_mode, 'scope', c.scope,
                                          'source_profile_id', c.source_profile_id, 'depth', c.depth,
                                          'priority', c.priority)
                       order by c.scope_rank, c.depth nulls last, c.priority desc nulls last, c.dimension, c.rule_key,
                                (c.language_mode is not null) desc)
      from lifeos._rule_candidates(p_profile_id, p_language_mode) c), '[]'::jsonb));
end $$;

create or replace function lifeos.communication_resolve(p_profile_id uuid default null, p_language_mode text default null)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  perform lifeos._profile_for_rules(p_profile_id);
  return lifeos._resolve(p_profile_id, p_language_mode);
end $$;

-- -----------------------------------------------------------------------------
-- 8.3 Messages
-- -----------------------------------------------------------------------------

create or replace function lifeos.communication_runtime_context(p_profile_id uuid default null,
                                                                p_language_mode text default null,
                                                                p_platform text default null,
                                                                p_history_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._runtime_context(p_profile_id, p_language_mode, p_platform, p_history_limit);
end $$;

create or replace function lifeos.communication_message_finalize(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  v jsonb := lifeos._obj(p_input);
  v_changes jsonb;
  v_change jsonb;
  v_applied jsonb := '[]'::jsonb;
  v_limit integer;
  v_id uuid;
  m lifeos.communication_messages;
begin
  perform lifeos._check_fields(v, array['profile_id', 'message_text', 'language_mode', 'platform', 'intent', 'message_mode',
                                        'metadata', 'history_limit', 'rule_changes']);
  perform lifeos._require(v, array['message_text']);
  perform lifeos._check_types(v, p_uuids => array['profile_id'], p_objects => array['metadata'],
                              p_ints => array['history_limit']);
  v := lifeos._strip_top_nulls(v);
  v_limit := lifeos._int_param(v, 'history_limit', 5);
  v_changes := coalesce(v -> 'rule_changes', '[]'::jsonb);
  if jsonb_typeof(v_changes) <> 'array' then
    raise exception 'invalid input' using detail = 'rule_changes must be an array';
  end if;
  if v ? 'profile_id' then
    perform lifeos._require_active('communication_profiles', (v ->> 'profile_id')::uuid);
  end if;

  v_id := lifeos._insert_row('communication_messages',
    (v - 'history_limit' - 'rule_changes') || jsonb_build_object('finalized_at', now()));

  for v_change in select value from jsonb_array_elements(v_changes) loop
    v_change := lifeos._obj(v_change);
    if v_change ->> 'action' = 'upsert' then
      v_applied := v_applied || jsonb_build_array(lifeos._rule_upsert(v_change - 'action'));
    elsif v_change ->> 'action' = 'delete' then
      perform lifeos._check_fields(v_change, array['action', 'id']);
      perform lifeos._require(v_change, array['id']);
      perform lifeos._check_types(v_change, p_uuids => array['id']);
      v_applied := v_applied || jsonb_build_array(
        jsonb_build_object('action', 'deleted') || lifeos._rule_delete((v_change ->> 'id')::uuid));
    else
      raise exception 'invalid input' using detail = 'a rule change action is upsert or delete';
    end if;
  end loop;

  select * into m from lifeos.communication_messages where id = v_id;
  return jsonb_build_object(
    'message', lifeos._message_json(m),
    'rule_changes_applied', v_applied,
    'runtime_context', lifeos._runtime_context(m.profile_id, m.language_mode, m.platform, v_limit));
end $$;

create or replace function lifeos.communication_message_history_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  m lifeos.communication_messages;
begin
  select * into m from lifeos.communication_messages where id = p_id;
  if not found then
    raise exception 'record not found';
  end if;
  return lifeos._message_json(m);
end $$;

-- A profile_id filter of a deleted Profile matches nothing (M-0021 D10).
create or replace function lifeos.communication_message_history_search(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_limit integer;
  v_offset integer;
  v_pat text;
  v_profile uuid;
  v_lang text;
  v_platform text;
  v_intent text;
  v_mode text;
  v_from timestamptz;
  v_to timestamptz;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['profile_id', 'language_mode', 'platform', 'intent', 'message_mode', 'keyword',
                                        'query', 'from_date', 'to_date', 'limit', 'offset']);
  perform lifeos._check_types(f, p_uuids => array['profile_id']);
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);
  v_pat := lifeos._kw(f);
  v_profile := (f ->> 'profile_id')::uuid;
  v_lang := f ->> 'language_mode';
  v_platform := f ->> 'platform';
  v_intent := f ->> 'intent';
  v_mode := f ->> 'message_mode';
  v_from := lifeos._filter_ts_from(f ->> 'from_date');
  v_to := lifeos._filter_ts_to(f ->> 'to_date');

  select coalesce(jsonb_agg(lifeos._message_json(m) order by m.finalized_at desc, m.id), '[]'::jsonb) into v_res
  from (
    select * from lifeos.communication_messages m
    where m.deleted_at is null
      and (v_profile is null
           or (m.profile_id = v_profile
               and exists (select 1 from lifeos.communication_profiles p where p.id = v_profile and p.deleted_at is null)))
      and (v_lang is null or m.language_mode = v_lang)
      and (v_platform is null or m.platform = v_platform)
      and (v_intent is null or m.intent = v_intent)
      and (v_mode is null or m.message_mode = v_mode)
      and (v_from is null or m.finalized_at >= v_from)
      and (v_to is null or m.finalized_at <= v_to)
      and (v_pat is null or m.message_text ilike v_pat or m.intent ilike v_pat)
    order by m.finalized_at desc, m.id
    limit v_limit offset v_offset
  ) m;

  return lifeos._search_shape(v_res, v_limit, v_offset);
end $$;

create or replace function lifeos.communication_message_history_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
begin
  return lifeos._soft_delete('communication_messages', p_id);
end $$;

-- =============================================================================
-- 10. Timeline and Shared Retrieval (Contract Chapter 9)
-- =============================================================================

-- Every active Timeline Record with its occurrence date, occurrence time and record date (Contract 9.1, 9.3).
create or replace function lifeos._timeline_candidates()
returns table (record_type text, id uuid, occurrence_date date, occurrence_time time, record_date date,
               created_at timestamptz)
language sql stable set search_path = lifeos, pg_temp
as $$
  select 'schedule', s.id, s.planned_date, s.planned_time, lifeos._kl_date(s.created_at), s.created_at
  from lifeos.schedules s where s.deleted_at is null
  union all
  select 'event', e.id, e.occurred_date, e.occurred_time, lifeos._kl_date(e.created_at), e.created_at
  from lifeos.events e where e.deleted_at is null
  union all
  select 'observation', o.id, o.observed_date, o.observed_time, lifeos._kl_date(o.created_at), o.created_at
  from lifeos.observations o where o.deleted_at is null
  union all
  select 'note', n.id, lifeos._kl_date(coalesce(n.edited_at, n.created_at)), null::time, lifeos._kl_date(n.created_at), n.created_at
  from lifeos.notes n where n.deleted_at is null
  union all
  select 'expense', x.id, x.transaction_date, x.transaction_time, lifeos._kl_date(x.created_at), x.created_at
  from lifeos.expenses x where x.deleted_at is null
  union all
  select 'reading', r.id, r.reading_date, r.reading_time, lifeos._kl_date(r.created_at), r.created_at
  from lifeos.readings r join lifeos.divination_records d on d.id = r.divination_record_id
  where r.deleted_at is null and d.deleted_at is null
  union all
  select 'communication_message', m.id, lifeos._kl_date(m.finalized_at), lifeos._kl_time(m.finalized_at),
         lifeos._kl_date(m.finalized_at), m.created_at
  from lifeos.communication_messages m where m.deleted_at is null
$$;

-- One Timeline item (Contract 9.1 return shape).
create or replace function lifeos._timeline_item(p_type text, p_id uuid, p_occurrence_date date, p_occurrence_time time,
                                                 p_record_date date)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
as $$
declare
  v_record jsonb;
  v_links jsonb;
  v_subject_links jsonb;
  v_subjects jsonb;
begin
  v_record := lifeos._record_json(p_type, p_id);
  if p_type = 'reading' then
    -- A Reading item carries its own Analyses and the combined Analyses of its Divination Record.
    v_record := v_record || jsonb_build_object('record_analyses', coalesce((
      select jsonb_agg(lifeos._analysis_json(a) order by a.analysis_date, a.created_at)
      from lifeos.analyses a join lifeos.readings r on r.divination_record_id = a.divination_record_id
      where r.id = p_id and a.reading_id is null and a.deleted_at is null), '[]'::jsonb));
  end if;

  if p_type = 'communication_message' then
    v_links := '[]'::jsonb;
    v_subject_links := lifeos._links('communication_message', p_id);
  else
    v_links := lifeos._links(p_type, p_id);
    v_subject_links := v_links;
  end if;

  select coalesce(jsonb_agg(distinct jsonb_build_object('id', s.id, 'name', s.name, 'subject_type', s.subject_type,
                                                        'via', l ->> 'via')), '[]'::jsonb)
    into v_subjects
  from jsonb_array_elements(v_subject_links) l
  join lifeos.subjects s on s.id = (l ->> 'id')::uuid and s.deleted_at is null
  where l ->> 'record_type' = 'subject';

  return jsonb_build_object(
    'record_type', p_type,
    'module', case p_type
                when 'expense' then 'financial_records'
                when 'reading' then 'divination_reflection'
                when 'communication_message' then 'communication_assistant'
                else 'personal_records' end,
    'id', p_id,
    'occurrence_date', p_occurrence_date,
    'occurrence_time', p_occurrence_time,
    'record_date', p_record_date,
    'record', v_record,
    'subjects', v_subjects,
    'links', v_links);
end $$;

create or replace function lifeos.timeline(p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_from date;
  v_to date;
  v_basis text;
  v_items jsonb;
  v_earlier jsonb := '[]'::jsonb;
begin
  perform lifeos._check_fields(f, array['from_date', 'to_date', 'date_basis']);
  perform lifeos._require(f, array['from_date', 'to_date']);
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  if v_from > v_to then
    raise exception 'invalid input' using detail = 'from_date is after to_date';
  end if;
  v_basis := coalesce(nullif(btrim(f ->> 'date_basis'), ''), 'occurrence');
  if v_basis not in ('occurrence', 'record') then
    raise exception 'invalid input' using detail = 'date_basis is occurrence or record';
  end if;

  select coalesce(jsonb_agg(lifeos._timeline_item(c.record_type, c.id, c.occurrence_date, c.occurrence_time, c.record_date)
                            order by c.occurrence_date, c.occurrence_time nulls last, c.created_at, c.id), '[]'::jsonb)
    into v_items
  from lifeos._timeline_candidates() c
  where (v_basis = 'occurrence' and c.occurrence_date between v_from and v_to)
     or (v_basis = 'record' and c.record_date between v_from and v_to);

  if v_basis = 'occurrence' then
    select coalesce(jsonb_agg(lifeos._timeline_item(c.record_type, c.id, c.occurrence_date, c.occurrence_time, c.record_date)
                              order by c.occurrence_date, c.occurrence_time nulls last, c.created_at, c.id), '[]'::jsonb)
      into v_earlier
    from lifeos._timeline_candidates() c
    where c.record_date between v_from and v_to and c.occurrence_date < v_from;
  end if;

  return jsonb_build_object(
    'from_date', v_from,
    'to_date', v_to,
    'date_basis', v_basis,
    'items', v_items,
    'recorded_earlier', v_earlier,
    'returned_count', jsonb_array_length(v_items));
end $$;

-- A deleted Subject, merged Subjects included, returns "record not found" (M-0020 S1).
create or replace function lifeos.subject_records(p_id uuid, p_filter jsonb)
returns jsonb language plpgsql security definer set search_path = lifeos, pg_temp
as $$
declare
  f jsonb := lifeos._obj(p_filter);
  v_all text[] := array['schedule', 'event', 'observation', 'note', 'expense', 'reading', 'storyline', 'communication_message'];
  v_types text[];
  v_from date;
  v_to date;
  v_limit integer;
  v_offset integer;
  v_res jsonb;
begin
  perform lifeos._check_fields(f, array['record_types', 'from_date', 'to_date', 'limit', 'offset']);
  if not exists (select 1 from lifeos.subjects s where s.id = p_id and s.deleted_at is null) then
    raise exception 'record not found';
  end if;
  v_types := coalesce(lifeos._text_list(f -> 'record_types'), v_all);
  if cardinality(v_types) = 0 then
    v_types := v_all;
  end if;
  if exists (select 1 from unnest(v_types) t where t <> all (v_all)) then
    raise exception 'invalid input' using detail = 'record_types accepts schedule, event, observation, note, expense, reading, storyline and communication_message';
  end if;
  v_from := lifeos._filter_date(f ->> 'from_date');
  v_to := lifeos._filter_date(f ->> 'to_date');
  v_limit := lifeos._int_param(f, 'limit', 20);
  v_offset := lifeos._int_param(f, 'offset', 0);

  with c (record_type, id, via, rank) as (
    select case when l.record_type_a = 'subject' and l.record_id_a = p_id then l.record_type_b else l.record_type_a end,
           case when l.record_type_a = 'subject' and l.record_id_a = p_id then l.record_id_b else l.record_id_a end,
           'record_link', 1
    from lifeos.record_links l
    where (l.record_type_a = 'subject' and l.record_id_a = p_id) or (l.record_type_b = 'subject' and l.record_id_b = p_id)
    union all
    select 'observation', o.id, 'observation_subject', 2 from lifeos.observations o where o.subject_id = p_id
    union all
    select 'expense', x.id, 'payment_method', 3 from lifeos.expenses x where x.payment_method_subject_id = p_id
    union all
    select 'expense', x.id, 'merchant', 4 from lifeos.expenses x where x.merchant_subject_id = p_id
    union all
    select 'expense', l.expense_id, 'line_item', 5 from lifeos.expense_lines l where l.item_subject_id = p_id
    union all
    select 'reading', rsp.reading_id, 'story_person_subject', 6
    from lifeos.reading_story_persons rsp join lifeos.story_persons sp on sp.id = rsp.story_person_id
    where sp.subject_id = p_id and sp.deleted_at is null
    union all
    select 'storyline', ssp.storyline_id, 'story_person_subject', 6
    from lifeos.storyline_story_persons ssp join lifeos.story_persons sp on sp.id = ssp.story_person_id
    where sp.subject_id = p_id and sp.deleted_at is null
    union all
    select 'communication_message', m.id, 'person_profile_subject', 7
    from lifeos.communication_messages m join lifeos.communication_profiles p on p.id = m.profile_id
    where p.person_subject_id = p_id and p.profile_type = 'person' and p.deleted_at is null
  ), d as (
    select distinct on (c.record_type, c.id) c.record_type, c.id, c.via
    from c where c.record_type = any (v_types)
    order by c.record_type, c.id, c.rank
  ), dated as (
    select d.*, (t.info ->> 'occurrence_date')::date as occurrence_date
    from d cross join lateral (select lifeos._target_info(d.record_type, d.id) as info) t
    where t.info is not null
  ), paged as (
    select dated.* from dated
    where (v_from is null and v_to is null)
       or (dated.occurrence_date is not null
           and (v_from is null or dated.occurrence_date >= v_from)
           and (v_to is null or dated.occurrence_date <= v_to))
    order by dated.occurrence_date desc nulls last, dated.record_type, dated.id
    limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(jsonb_build_object('record_type', pg.record_type, 'id', pg.id, 'via', pg.via,
                                               'occurrence_date', pg.occurrence_date,
                                               'record', lifeos._record_json(pg.record_type, pg.id))
                            order by pg.occurrence_date desc nulls last, pg.record_type, pg.id), '[]'::jsonb)
    into v_res
  from paged pg;

  return lifeos._search_shape(v_res, v_limit, v_offset);
end $$;

-- =============================================================================
-- 11. Grants
-- =============================================================================
--
-- The access model of implementation notes 5 to 8:
--   1. Revokes EXECUTE on every lifeos function from PUBLIC, anon and authenticated.
--   2. Grants USAGE on schema lifeos to anon and authenticated.
--   3. Grants EXECUTE on the 99 Contract functions to anon and authenticated.
--      Internal helpers (names starting with an underscore) stay revoked.
--   4. Revokes every table privilege from PUBLIC, anon and authenticated.
--   5. Checks that the schema holds exactly the 99 Contract functions plus helpers,
--      each with one signature, SECURITY DEFINER and search_path = lifeos, pg_temp.
-- -----------------------------------------------------------------------------
revoke all on all functions in schema lifeos from public, anon, authenticated;
revoke all on all tables in schema lifeos from public, anon, authenticated;
revoke all on all sequences in schema lifeos from public, anon, authenticated;

grant usage on schema lifeos to anon, authenticated;

do $$
declare
  v_contract text[] := array[
    -- Chapter 2: LifeOS Memory
    'memory_create', 'memory_read', 'memory_search', 'memory_update', 'memory_delete',
    -- Chapter 3: Notebook
    'notebook_read', 'notebook_list', 'notebook_update',
    -- Chapter 4: Personal Records
    'schedule_create', 'schedule_create_series', 'schedule_read', 'schedule_search', 'schedule_update',
    'schedule_update_series', 'schedule_stop_series', 'schedule_overdue_check', 'schedule_delete',
    'event_create', 'event_link_schedule', 'event_read', 'event_search', 'event_update', 'event_delete',
    'observation_create', 'observation_read', 'observation_search', 'observation_update', 'observation_delete',
    'note_create', 'note_read', 'note_search', 'note_update', 'note_delete',
    'record_link_create', 'record_link_delete', 'record_links_read', 'record_add_remark',
    'record_update_remark', 'record_delete_remark',
    -- Chapter 5: Subject
    'subject_create', 'subject_read', 'subject_search', 'subject_check', 'subject_update', 'subject_add_alias',
    'subject_merge', 'subject_delete',
    -- Chapter 6: Financial Records
    'expense_create', 'expense_create_batch', 'expense_read', 'expense_search', 'expense_update', 'expense_history',
    'expense_delete', 'expense_refund_create', 'expense_spending_report', 'expense_category_list',
    -- Chapter 7: Divination & Reflection
    'divination_record_save', 'divination_record_read', 'divination_search', 'divination_record_update',
    'divination_record_delete', 'reading_create', 'reading_story_persons_set', 'reading_delete',
    'analysis_add', 'analysis_delete', 'reading_remark_add', 'reading_remark_update', 'reading_remark_delete',
    'story_person_create', 'story_person_read', 'story_person_search', 'story_person_update', 'story_person_delete',
    'storyline_create', 'storyline_read', 'storyline_search', 'storyline_update', 'storyline_delete',
    -- Chapter 8: Communication Assistant
    'communication_profile_create', 'communication_profile_read', 'communication_profile_search',
    'communication_profile_update', 'communication_profile_delete', 'communication_profile_membership_set',
    'communication_profile_membership_remove', 'communication_profile_merge', 'communication_rule_upsert',
    'communication_rule_delete',
    'communication_rule_state', 'communication_resolve', 'communication_runtime_context',
    'communication_message_finalize', 'communication_message_history_read', 'communication_message_history_search',
    'communication_message_history_delete',
    -- Chapter 9: Timeline and Shared Retrieval
    'timeline', 'subject_records'];
  v_name text;
  v_bad text;
begin
  if cardinality(v_contract) <> 99 then
    raise exception 'grants: the Contract list holds % names, expected 99', cardinality(v_contract);
  end if;

  -- Every Contract function exists with exactly one signature.
  select string_agg(n, ', ') into v_bad
  from unnest(v_contract) n
  where (select count(*) from pg_proc p where p.pronamespace = 'lifeos'::regnamespace and p.proname = n) <> 1;
  if v_bad is not null then
    raise exception 'grants: missing or overloaded Contract functions: %', v_bad;
  end if;

  -- No Agent-facing function outside the Contract: every other function is an underscore helper.
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'lifeos'::regnamespace and p.proname <> all (v_contract) and p.proname !~ '^_';
  if v_bad is not null then
    raise exception 'grants: functions outside the Contract without an underscore prefix: %', v_bad;
  end if;

  -- Contract functions are SECURITY DEFINER with search_path = lifeos, pg_temp.
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'lifeos'::regnamespace and p.proname = any (v_contract)
    and (not p.prosecdef or not coalesce(p.proconfig, '{}') @> array['search_path=lifeos, pg_temp']);
  if v_bad is not null then
    raise exception 'grants: Contract functions without SECURITY DEFINER and search_path: %', v_bad;
  end if;

  foreach v_name in array v_contract loop
    execute format('grant execute on function lifeos.%I to anon, authenticated', v_name);
  end loop;
end $$;
