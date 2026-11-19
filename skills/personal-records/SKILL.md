---
name: personal-records
description: Runs the LifeOS Personal Records flows. Records and changes Schedules, repeating series, Events with Schedule actualisation, Observations and Notes, and amends or deletes them. Use when the user reports a plan, an occurrence, a measurement or state, a thought or feeling, or asks what happens today.
compatibility: Requires the LifeOS Supabase functions in the schema lifeos and the LifeOS Config file in Google Drive. Load the lifeos entry Skill first.
---

# Personal Records

## 1. Purpose and when to use

Personal Records classify personal information by business meaning (KB 6.1):

1. Schedule: an intended matter.
2. Event: an actual occurrence.
3. Observation: a Subject's state or measurement.
4. Note: independent narrative information.

Use this Skill after the [lifeos](../lifeos/SKILL.md) entry Skill routes a Personal Records request.

The entry Skill holds Subject Discovery, Record links, Remarks, Timeline, Memory and Notebook. This Skill names them where a flow uses them.

## 2. Contract files to read

1. [personal-records.md](../../contract/personal-records.md): Schedule, Event, Observation and Note functions.
2. [shared.md](../../contract/shared.md): common rules, Record links, Remarks, Subject and Timeline.

## 3. Rules that apply to every flow

1. Choose the Record Type by business meaning. A timestamp alone does not decide it (KB 6.1).
2. Classify a reported thought as Note, an actual occurrence as Event and an intended matter as Schedule.
3. Schedule, Event and Observation always have a date. A matter without a date is a Note (KB 6.6).
4. Resolve relative dates in Asia/Kuala_Lumpur. Never invent a precise date or time (KB 6.9).
5. Keep the user's imprecise timing wording in `time_text`. An unknown time stays unknown.
6. A Subject supplies identity without changing a Record's type. Identify it under the entry Skill Section 6.
7. Before you decide on a new Record, an amendment or a Remark, retrieve matching prior Records (KB 6.9).
8. An edit changes the Record directly and keeps only its latest content (KB 6.9).

## 4. Record a Schedule

Purpose: record a matter that is planned, arranged, expected, intended or required (KB 6.2).

Input:

1. The matter, as the title.
2. Its planned date, and its planned time when known.
3. Optional: description, end, location and the user's timing wording.
4. Optional business case: Appointment, Planned Activity, Deadline or Expected Activity.

Steps:

1. Retrieve matching prior Schedules with `schedule_search`. This avoids a duplicate.
2. Create the Schedule with `schedule_create`. Its Status starts as Planned.
3. Link it to its Subjects and related Records under the entry Skill Section 10.

Outcome: one Planned Schedule. A Schedule that nobody handles stays Planned and has no further business effect (KB 6.2).

## 5. Record a repeating series

Purpose: record a repeating matter as individual Schedules, one per occurrence (KB 6.2).

Input:

1. The matter and its repeat pattern.
2. How long it repeats, such as three months or one year.

Steps:

1. Confirm with the user how long the matter repeats. A series is never unlimited.
2. Build one Schedule item per occurrence within that duration.
3. Write a one-sentence Series description of the period and repeat pattern.
4. Create the series with `schedule_create_series`. Every Schedule receives one shared Series ID.

Choices and approvals: the user confirms the duration.

Outcome: a finite series. Each Schedule has its own Status, Event link and overdue check. After the last Schedule, create no new Schedules unless the user asks.

Open-ended annual matters, such as birthdays, are outside the current product scope (KB 6.2).

## 6. Add a Schedule to an existing series

Purpose: let a later Schedule join a series (KB 6.2).

Input: the series and the new occurrence.

Steps:

1. Find the series with `schedule_search`. Read its Series ID.
2. Create the Schedule with `schedule_create` and that Series ID. The function copies the Series description.
3. For several new occurrences, call `schedule_create_series` with the existing Series ID.

Outcome: the new Schedule shares the Series ID of the series.

## 7. Change one Schedule

Purpose: reschedule, change the content of, cancel or mark missed one Schedule (KB 6.2).

Input: the user's change, such as "move the dentist to 3 pm" or "cancel Friday's dentist".

Steps:

1. Find the intended Schedule with `schedule_search`.
2. When it is unclear which Schedule is meant, ask the user.
3. For a series Schedule with an unclear scope, ask "this one" or "from now on".
4. Apply the change with `schedule_update`:
   - A reschedule changes the planned date or time. It needs no separate Status.
   - A cancellation sets Status Cancelled.
   - A missed matter sets Status Missed.
   - A Status correction on a Schedule without a linked Event may set Planned again.
5. "Change this one" edits only that Schedule.

Outcome: the Schedule holds its latest content and Status.

## 8. Change a series from now on

Purpose: change the later Planned Schedules of one series (KB 6.2).

Input: the change and the point from which it applies.

Steps:

1. Find the series with `schedule_search`. Read its Series ID.
2. Turn "from now on" into one date. That date is included.
3. Amend the Series description. State the date from which the change applies.
4. Call `schedule_update_series` with the Series ID, the date and the changes.
5. Apply a date change per Schedule with `schedule_update`.

Outcome: later Planned Schedules carry the change. Earlier Schedules keep their content and Series description.

## 9. Stop a series

Purpose: end a repeating matter (KB 6.2).

Input: the series and the date from which it stops.

Steps:

1. Find the series with `schedule_search`. Read its Series ID.
2. When the stop date is unclear, ask the user.
3. Call `schedule_stop_series` with the Series ID and the date.

Outcome: the later Planned Schedules become Cancelled. Past Schedules and Events stay unchanged.

## 10. Record an Event

Purpose: record an actual action or occurrence, regardless of who initiated it (KB 6.3 and 6.4).

Event recording is the base flow. Schedule linkage is a conditional branch inside it.

Input:

1. What happened.
2. Its actual date, and its actual time when known.
3. Optional: description, end, location and the user's timing wording.

Steps:

1. Search for a matching Schedule yourself with `schedule_search`, before you create the Event.
2. When you find a candidate, propose the match. Example: "Is this the matter you planned for that date and time?"
3. When the user confirms, call `event_create` with the Schedule ID. Run this once.
   - The Event copies the Schedule content as far as it still applies.
   - It keeps the Schedule's planned date and time as its planned date and time.
   - The actual date, time and changed details come from the user's information.
   - The Schedule becomes Occurred. This holds for a Cancelled or Missed Schedule too.
4. When no candidate exists or the user does not confirm, call `event_create` without a Schedule ID.
5. Link the Event to its Subjects and related Records under the entry Skill Section 10.
6. Record Observations reported in the same statement under Section 13.

Choices and approvals: the user confirms the Schedule match. The user's latest confirmation decides.

Outcome: one Event, linked to its Schedule when the user confirmed the match.

## 11. Link an existing Event to a Schedule

Purpose: connect a recorded Event to the Schedule it actualises (KB 6.4 and 6.9).

Input: an Event without a Schedule link, such as an Event whose Schedule was deleted.

Steps:

1. Find the Event with `event_search` and the candidate Schedule with `schedule_search`.
2. Propose the match to the user.
3. After the user confirms, call `event_link_schedule`.

Choices and approvals: the user confirms the match.

Outcome: the Event carries the Schedule's planned date and time, and the Schedule becomes Occurred.

## 12. Overdue check

Purpose: settle the Planned Schedules whose time passed without an Event (KB 6.2 and 6.4).

Input: the user asks what happens today, or asks a similar question.

Steps:

1. Run the Timeline for today under the entry Skill Section 12.
2. Call `schedule_overdue_check`. It returns Planned Schedules from yesterday or today whose time has passed.
3. For each one, ask whether it was missed, cancelled or something else.
4. Act on the user's answer:
   - Missed or cancelled: set the Status with `schedule_update`.
   - It happened: record the Event under Section 10 with the confirmed Schedule.
   - Another answer: follow the user's information.
5. Ask nothing about Schedules already handled.

Choices and approvals: the user's answer decides each Schedule.

Outcome: each answered Schedule holds the Status the user confirmed. An unanswered one stays Planned.

## 13. Record an Observation

Purpose: record a Subject's numeric Measurement or descriptive or categorical State (KB 6.5).

Input:

1. The observed Subject.
2. What is measured or described, such as weight or membership points.
3. The value with its unit, or the state.
4. The observation date, and the time when known.
5. Optional: location and the Event reported together with it.

Steps:

1. Identify the Subject under the entry Skill Section 6. A statement about the user needs no proposal.
2. When the Observation comes with an Event in the same statement, record the Event first under Section 10.
3. Call `observation_create` with the Subject. Add the Event ID when the Event came in the same statement.
4. Link an Observation to its Event without a proposal when one statement reports both.
5. Propose an unclear Subject, such as "my mentor", even inside that automatic link.
6. Record an Observation without an Event as an Observation of its Subject only. Create no Event.

Example: blood pressure and weight measured at a doctor visit link to that visit's Event. One Event may hold many Observations.

Membership-point values on a Receipt may be recorded as Observations.

Outcome: one Observation of its Subject at the observation time. It does not imply that the value stays valid.

## 14. Correct an Observation or record a change

Purpose: keep Observations true to their observation time (KB 6.5).

Input: a corrected value, or a later real-world change.

Steps:

1. Find the Observation with `observation_search`.
2. For a correction, call `observation_update`. The original observation time stays.
3. For a later real-world change, create a new Observation under Section 13.

Outcome: Observations of the same Subject relate only through that Subject.

## 15. Record a Note

Purpose: preserve ideas, thoughts, feelings, experiences, explanations or other narrative information (KB 6.6).

Input: the narrative. A matter without a date is also a Note.

Steps:

1. Read the Note Types with `notebook_read` and the key `note_types`.
2. Choose the Note Type by meaning. The defaults are Idea, Feeling, Experience, Explanation and General.
3. Add a new Note Type under the entry Skill Section 16 when none fits.
4. Call `note_create`. The Note takes the date the user records it.
5. Link the Note to a Subject or Event the user refers to, under the entry Skill Section 10.

Experience holds what the user took from a happening. The happening itself is an Event.

A Note has no Tags. A Note keeps its own narrative meaning, distinct from a Remark.

Outcome: one Note dated on its record date. A link does not change its type.

## 16. Record a feeling about an earlier day

Purpose: keep what happened apart from the feeling about it (KB 6.6).

Input: a feeling about an earlier day, such as last Tuesday.

Steps:

1. Find that day's Event with `event_search` and the day as date filter.
2. When no Event exists for that day, create one under Section 10.
3. Create a Note dated today under Section 15.
4. Link the Note to the Event with `record_link_create`. Ask the user when the link is ambiguous.

Outcome: the Event holds what happened on the earlier day. The Note holds today's feeling.

## 17. Amend a Record

Purpose: update a prior Record instead of creating a duplicate (KB 6.9).

Input: new information about a matter that may already be recorded.

Steps:

1. Retrieve matching prior Records with `schedule_search`, `event_search`, `observation_search` or `note_search`.
2. Decide whether the user intends a new Record, an amendment or a Remark.
3. Confirm the intended Record and action together with the user when needed.
4. For a simple additive detail, add a Remark under the entry Skill Section 11.
5. For structured state, use the update function:
   - Schedule: `schedule_update`.
   - Event: `event_update`.
   - Observation: `observation_update`.
   - Note: `note_update`. The Note's date moves to the edit date.

Choices and approvals: the user confirms the intended Record and action when they are unclear.

Outcome: the Record holds its latest content, and no duplicate exists.

## 18. Delete a Record

Purpose: remove a Personal Record that the user no longer wants (KB 6.9).

Input: the Record to delete.

Steps:

1. Find the Record with the Module search function.
2. When it is unclear which Record is meant, ask the user.
3. Delete it:
   - Schedule: `schedule_delete`.
   - Event: `event_delete`. A linked active Schedule returns to Planned.
   - Observation: `observation_delete`.
   - Note: `note_delete`.
4. Leave the other links stored. Other Records ignore a link to a deleted Record.

Outcome: the Record is deleted. A deleted Schedule keeps its Status. Its Event may later link to another Schedule (Section 11).
