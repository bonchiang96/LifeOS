-- =============================================================================
-- LifeOS V2, Build Stage 1 — migration 1 of 10: schema, tables and shared helpers
--
-- Creates:
--   1. The schema lifeos.
--   2. Every LifeOS table, with Row Level Security enabled and no policies.
--   3. The shared internal helpers (names start with an underscore) that the
--      Contract functions in migrations 2 to 9 use: UTC timestamp output,
--      Asia/Kuala_Lumpur dates, input validation, generic insert, update and
--      soft delete, Remarks normalisation and search paging.
--
-- Changes no object outside schema lifeos. Safe to run once on a fresh project.
-- Source: LifeOS Database Contract V2 and the SQL implementation notes (J-0002).
-- =============================================================================

create schema if not exists lifeos;

-- -----------------------------------------------------------------------------
-- 1. Tables
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

-- -----------------------------------------------------------------------------
-- 2. Shared helpers: time
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
-- 3. Shared helpers: JSON input validation
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
-- 4. Shared helpers: search paging (Contract 1.5 item 4)
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
-- 5. Shared helpers: Records
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
create or replace function lifeos._remarks_normalize(p jsonb)
returns jsonb language plpgsql stable set search_path = lifeos, pg_temp
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
    v_out := v_out || jsonb_build_array(jsonb_build_object('timestamp', lifeos._ts(v_ts), 'text', v_text));
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

-- Lock every function in lifeos until migration 10 grants the Contract functions.
revoke execute on all functions in schema lifeos from public, anon, authenticated;
