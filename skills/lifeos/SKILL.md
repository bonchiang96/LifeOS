---
name: lifeos
description: Starts every LifeOS request. Connects to the LifeOS Supabase functions through the LifeOS Config file and routes the request to its Module Skill. Also runs Subject, Record links, Remarks, Timeline, Subject questions, LifeOS Memory and Notebook. Use whenever the user records, finds or asks about anything in LifeOS.
compatibility: Requires the LifeOS Supabase functions in the schema lifeos and the LifeOS Config file in Google Drive, read through the host's Google Drive connector.
---

# LifeOS

## 1. Purpose and when to use

LifeOS is the user's personal operating system. It runs on ChatGPT, Claude and other compatible AI platforms (KB 3.1).

The four User-Facing Modules each have their own Skill:

| Module | Skill | Contract file |
|---|---|---|
| Personal Records: Schedule, Event, Observation, Note | [personal-records](../personal-records/SKILL.md) | [personal-records.md](../../contract/personal-records.md) |
| Financial Records: Expense, Refund, spending report | [financial-records](../financial-records/SKILL.md) | [financial-records.md](../../contract/financial-records.md) |
| Communication Assistant: Profiles, Rules, Messages | [communication-assistant](../communication-assistant/SKILL.md) | [communication-assistant.md](../../contract/communication-assistant.md) |
| Divination & Reflection: Readings, Storybook | [divination-reflection](../divination-reflection/SKILL.md) | [divination-reflection.md](../../contract/divination-reflection.md) |

This Skill owns the parts that every Module shares:

1. Connection through the LifeOS Config file (Section 4).
2. Request routing (Section 5).
3. Subject, the shared continuing identity (Sections 6 to 9).
4. Record links and Remarks (Sections 10 and 11).
5. Timeline and Subject questions (Sections 12 to 14).
6. The internal Modules LifeOS Memory and Notebook (Sections 15 and 16).

Use this Skill at the start of every LifeOS request. Then load the Module Skill that Section 5 names.

## 2. Contract files to read

1. [shared.md](../../contract/shared.md): configuration, common rules, Record links, Remarks, Subject and Timeline.
2. [lifeos-memory.md](../../contract/lifeos-memory.md): LifeOS Memory functions.
3. [notebook.md](../../contract/notebook.md): Notebook functions.

Read the Contract for exact function names, fields, defaults and errors. Read the Module Contract file only for the Module in use.

## 3. Rules that apply to every flow

1. Call only the Contract functions. Read or write no table directly (shared.md 1.1).
2. You do the thinking before each call. You interpret the user, select the operation, present approvals and apply the rules (KB 3.2).
3. Preserve the user's stated facts and uncertainty. Classify the user's input directly into Records (KB 3.2).
4. Never invent business facts, stored Records, divination results, identity relationships, transaction amounts or timestamps (KB 3.2).
5. Use the exact ID that a function returned. Never invent an ID (shared.md 1.2).
6. Resolve relative dates in Asia/Kuala_Lumpur. Never invent a precise date or time from ambiguous wording (KB 6.9).
7. Retrieve the source Record before you claim that a historical fact is saved (KB 6.9).
8. A link that the user expresses clearly is made directly. Ask the user when a link is ambiguous (KB 6.7).
9. A business flow describes the normal path. You handle runtime problems and exceptions yourself (KB 3.3).
10. A user review loop may return to an earlier step until the user confirms (KB 3.3).

## 4. Connect to LifeOS

Purpose: reach the LifeOS functions on the user's Supabase project.

Input: the LifeOS Config file in the user's Google Drive.

Steps:

1. Find the Google Drive file named "LifeOS Config" through the host's Google Drive connector.
2. Read the Supabase project ID from it. Read a publishable key only when your connection method needs one (shared.md 1.2).
3. Choose a connection method, such as the platform's Supabase connector (shared.md 1.4).
4. Call each function as an RPC function in the schema `lifeos`, with named parameters.
5. Expect one `jsonb` value from every call.

Outcome: every later flow calls the functions on the configured project.

## 5. Route the request

Purpose: send each request to the Skill and Contract file that own it.

Input: the user's request.

Steps:

1. Retrieve relevant LifeOS Memory for the request (Section 15).
2. Find the request in the shared.md 1.8 table. It names the function and the Contract file.
3. Load the Module Skill that owns that Contract file (Section 1 table).
4. Keep shared requests in this Skill: Subject, Record links, Remarks, Timeline, Memory and Notebook.
5. One statement may touch several Modules. Run each Module's flow, then link the Records (Section 10).

Outcome: each part of the request runs in its owning Module, and every Record keeps its Module ownership (KB 10.4).

## 6. Subject Discovery

Purpose: identify the continuing entity that a Record relates to (KB 6.8.1).

A Subject keeps one continuing identity across Records and times. Confirmed kinds include people, residences, vehicles, household items, memberships, payment methods and bank accounts (KB 6.8).

Input:

1. A meaningful continuing identity that the conversation establishes.
2. A relevant Record relationship for it.

Steps:

1. Decide whether a Subject is needed. Create no Subject for an incidental or generic mention (KB 6.8).
2. Apply the granularity of KB 6.8:
   - Restaurant or shop: one Subject per brand. The branch stays in the Expense.
   - Vehicle: one Subject per plate number.
   - Product: one Subject per kind of thing the user tracks, such as shampoo.
   - Group, such as colleagues: no Subject. Record it as stated.
3. Read the catalog Notebooks `subject_types` and `subject_tags` with `notebook_read` (Section 16). Read no other key in this step.
4. Search the Subject Records with `subject_search`, `subject_check` and `subject_read`.
5. Treat each match only as a candidate. Current Subject Records establish identity (KB 5.2).
6. Find the user Subject with `subject_search` and `is_user` true. A statement about the user never needs confirmation.
7. Count the evidence for any other candidate. A single matching name is not enough.
8. With at least two pieces of evidence, link the Subject directly.
9. Otherwise propose the candidate and say why it may match the user's statement.
   - Give differentiating information, such as current or previous location, appearance, brand, model, attributes and related Records.
   - Describe it through its LifeOS information, never through an ID or number.
10. Use shared Events, Schedules, earlier Messages and other linked Records for the description. Read them with `subject_records`.
11. When several Subjects are plausible, use their differences to clarify with the user.
12. When no suitable match exists and the user wants a continuing Subject, propose its creation.
13. Create it with `subject_create` only after the user decides.

Choices and approvals:

1. The user confirms a proposed candidate.
2. The user decides whether a new Subject is created.

Outcome: the Record links to the confirmed Subject, or proceeds without a Subject link.

## 7. Subject maintenance

Purpose: keep Subject identity correct (KB 6.8.2).

Input: new evidence about a Subject, such as another name.

Steps:

1. Add a clear Alias directly with `subject_add_alias`.
2. Make an ordinary evidence-supported correction directly with `subject_update`.
3. Propose an uncertain Alias or an identity correction to the user.
4. Apply it with `subject_add_alias` or `subject_update` after the user confirms.
5. Keep the Subject's own Type and Tags from the `subject_types` and `subject_tags` Notebooks (Section 16).

Choices and approvals: the user confirms an uncertain Alias or identity correction.

Outcome: the Subject holds its current authoritative identity.

## 8. Duplicate Subject merge

Purpose: consolidate two Subjects that are one entity (KB 6.8.2).

Input: two Subjects that the user or the evidence shows to be the same entity.

Steps:

1. Read both Subjects with `subject_read`.
2. Present both and ask for the user's explicit approval to merge.
3. Check both Subjects for a Person Profile. `subject_read` returns it.
4. When both Subjects have a Person Profile, the user resolves the two Profiles first. Use the [communication-assistant](../communication-assistant/SKILL.md) Skill.
5. Combine the identity information of both Subjects into one identity.
6. Call `subject_merge` with the kept Subject, the merged Subject and the combined identity.

Choices and approvals: the merge needs the user's explicit approval.

Outcome: the kept Subject takes the combined identity. Source Records stay unchanged apart from their Subject references.

## 9. Subject deletion

Purpose: remove a Subject that the user no longer wants.

Input: the Subject to delete.

Steps:

1. Find the Subject. Ask the user when it is unclear which one is meant (KB 6.9).
2. Check for its Person Profile with `subject_read`.
3. When it has a Person Profile, the user decides the Profile's outcome first (KB 9.1):
   - The Profile belongs to another person: link it to the correct Subject.
   - The user no longer wants the Profile: delete it.
   - Both use the [communication-assistant](../communication-assistant/SKILL.md) Skill.
4. Delete the Subject with `subject_delete`.

Choices and approvals: the user decides the Profile's outcome.

Outcome: the Subject is deleted. Other Records keep their links to it and ignore them (KB 6.9).

## 10. Record links

Purpose: connect Records that describe the same matter, and connect a Record to its Subject (KB 6.7).

Input: Records that the user describes as one matter, and their Subjects.

Steps:

1. Link Records of different Modules directly to each other with `record_link_create`.
2. Link each of those Records to the shared Subject. The Subject link matters most.
3. Use the typed reference fields where the Module Skill sets them, such as `observation.subject_id`.
4. Make a clear link directly. For a Subject, clear means the Section 6 evidence test.
5. Ask the user when a link is ambiguous. This applies to Subject, Event, Expense, Reading and Storyline links.
6. Remove a link that the user corrects as wrong with `record_link_delete`.
7. Read every connection of one Record with `record_links_read`.

Example: "I had dinner with Nicholas today and paid RM80" gives a dinner Event and an RM80 Expense. Both link to each other and to the Subject Nicholas.

Listing rule: every listing shows each connected item once (KB 6.7).

1. A Record lists each connected Subject once.
2. A Subject lists each connected Record once.
3. Several paths may lead to one item. Their order is fixed: `record_link`, `observation_subject`, `payment_method`, `merchant`, `line_item`, `story_person_subject`, `person_profile_subject` (M-0022 D2).
4. On a Subject, `via_list` keeps every path in that order. `via` is the first path.
5. Count each listed item once. Never rank a matter or a person higher because several paths reach it.

Outcome: retrieval can start from any Record and reach the related Records and Subjects.

## 11. Remarks

Purpose: add a simple detail to a prior Record without a structured update (KB 6.9).

Input: a small additive detail about an existing Record.

Steps:

1. Retrieve the matching prior Record with the Module's search function.
2. Confirm the intended Record and action with the user when needed.
3. Add the detail with `record_add_remark`.
4. Replace the whole content of one Remark with `record_update_remark`.
5. Remove one Remark with `record_delete_remark`.
6. Use a structured update for a change to planned time, status or other structured state. The Module Skill holds it.

Example: a reminder to bring a camera is a Remark on the chosen visit. A changed visit time updates the Schedule.

A Remark change is not an edit. It changes neither the Record's updated time nor a Note's date.

Reading Remarks follow the [divination-reflection](../divination-reflection/SKILL.md) Skill.

Outcome: the Record holds the detail, and no duplicate Record exists.

## 12. Timeline

Purpose: present what the user does or what happens to the user over a period (KB 10.1).

Input: a period question, such as "what did I do last week" or "what is on this week".

Steps:

1. Turn the question into a period: a day, several days, a week or a month.
2. Let the question decide the direction, past or future.
3. Call `timeline` with `from_date` and `to_date`. Keep the default `date_basis` "occurrence".
4. When the question is "what happens today", run the overdue check of the [personal-records](../personal-records/SKILL.md) Skill.
5. Present the result under Section 13.

Choices: when the user asks what they recorded, call `timeline` with `date_basis` "record" (KB 10.2).

Outcome: one complete answer for the period.

## 13. Timeline presentation

Purpose: turn the Timeline data into one natural answer (KB 10.1 and 10.3).

Input: the `timeline` result.

Steps:

1. Consolidate the period into one answer in chronological order.
2. List entries with known clock times first, in order.
3. List date-only entries after them under '时间未注明 (Time not specified)'.
4. Show an Occurred Schedule through its Event.
5. Show Observations with the Event they belong to.
6. Show an upcoming Planned Schedule as a plan.
7. Summarise a series naturally, such as "your normal weekly schedule".
8. Include plans that did not happen. State a Missed or Cancelled Status as fact.
9. Present a past Schedule that is still Planned as a plan with an unknown outcome. Never call it missed.
10. Count an Expense once, on its Transaction Date. Count a Refund as a negative amount on its own date.
11. Show a Reading on its original Reading Date. Show its later Analyses under it (KB 10.2).
12. Show a Message on its Message History date. That date alone does not show that the message was delivered.
13. Keep each Record's Business Type, source identity and Module ownership.
14. When `recorded_earlier` holds items, add a short closing note about them.

Outcome: the user sees what really happened or will happen in the period.

## 14. Subject questions

Purpose: answer a question about a person or thing from the user's records (KB 10.5).

Input: a question about one Subject.

Steps:

1. Identify the Subject with `subject_check` or `subject_search`.
2. When the Subject is unclear, propose the candidate through its nearest linked Record. Example: "Is it the Nicholas you had dinner with on that date?"
3. Retrieve the connected Records with `subject_records`.
4. Read the needed Records with the Module read functions.
5. Answer only from the user's records, not from knowledge of the real world.
6. Let the question set the priority:
   - A clear, specific question gets a direct answer. A money question gets the amounts.
   - A question about one dinner leads with the amount and the dishes. The people present follow in one short line.
   - A general question about a person gives high priority to places, food, activities and conversations, up to one year.
   - In a general question, money has low priority and covers one to three months at most.
   - Give no total of spending with that person. An Expense may show the place without the amount.
7. End an overview with what you did not cover, such as older Records or plans that have not happened.
8. For a requested full overview, follow wider approved Subject and Person Profile relationships (KB 10.4).
9. Never present uncertain timing or a third-party story as a real Event on an inferred date.

Choices: when the user says how to present these answers, save it to LifeOS Memory (Section 15).

Outcome: an answer that keeps each Subject's identity, provenance and Record ownership.

## 15. LifeOS Memory

Purpose: keep reusable learned information across Agents, Conversations and AI platforms (KB 4.1).

LifeOS Memory is independent from other Records. It may hold context about entities without Subjects.

Input: the current request, user directions, corrections and repeated patterns.

Steps for retrieval:

1. Search with `memory_search` for Memory relevant to the current Input and Action.
2. Reuse it through the operation.
3. Search again when a new task or gap needs it.

Steps for learning:

1. Save an explicit user direction or a reusable correction with continuing value. Use `memory_create`. No advance approval is needed.
2. Learn a useful repeated pattern without per-instance approval.
3. Assign Categories and Tags yourself. Known Categories are User Operating Rules, Vocabulary, Processing Conventions and Behavioural Patterns.
4. Store Learning at Module, functional-area or workflow level. Avoid isolated single-record Memories.
5. Use qualitative wording for certainty, conditions and applicability.
6. Improve existing Learning with `memory_update` when new evidence changes or strengthens it.
7. Consolidate overlapping Memories into one with `memory_update`. Remove the merged one with `memory_delete`.
8. Keep useful outcome and feedback evidence. Never copy entire transcripts into Memory.

Choices and approvals:

1. Learning permission never covers a change to another Module's classification, Payment Method, Record or decision.
2. Propose such an application and obtain the user's confirmation.
3. When an uncertain remembered habit would decide a current fact, ask the user.
4. Use the user's acceptance or rejection to improve the Learning.

Steps for negative feedback:

1. Decide whether the error lies in stored Memory, a one-off inference or a wrong Module application.
2. Correct the affected Learning with `memory_update` or `memory_delete`.
3. Keep the valid Memory.

Outcome: later operations reuse the improved Learning.

## 16. Notebook

Purpose: keep fixed-purpose reference vocabularies (KB 5.1).

Notebook is separate from LifeOS Memory. It holds no Agent learning and no canonical Subject Records.

The catalog keys are `subject_types`, `subject_tags`, `expense_tags`, `note_types` and `defaults`. The `defaults` Notebook holds the default Currency, MYR.

Input: a vocabulary or default value that a Module flow needs.

Steps:

1. Read the Notebook by its stable key with `notebook_read`. The function initialises a missing Notebook with its default values.
2. List the catalog with `notebook_list` when you need another relevant Notebook.
3. Compare a candidate's semantic meaning with the current entries.
4. Reuse equivalent vocabulary, or create a justified entry.
5. Write the full new content with `notebook_update`. Add, revise, consolidate, reorganise and remove entries yourself.
6. You may keep other justified reusable vocabulary in a new Notebook key.

Choices and approvals: Notebook maintenance needs no approval. It never replaces the user confirmation that a Subject or other Record operation needs (KB 5.2).

Outcome: Module flows reuse one consistent vocabulary.
