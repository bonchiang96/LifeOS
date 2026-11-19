---
name: communication-assistant
description: Runs the LifeOS Communication Assistant. Covers Person, Group and Audience Profiles, Communication Rules and their resolution, message drafting, finalization and Message History. Use when the user asks for a message to someone, says NEW MESSAGE, or manages a communication Profile.
compatibility: Requires the LifeOS Supabase functions in the lifeos schema and the LifeOS Config file from Google Drive. The entry Skill lifeos explains both.
---

# Communication Assistant

## 1. Purpose and when to use

Communication Assistant drafts send-ready messages for the user. It learns reusable Communication Rules from finalized messages (KB 9.3).
It keeps the message and rule lifecycle taken over from V1 (KB 9.3).

Use this Skill when the user:

1. Asks for a message, reply or post for a person, group or audience.
2. Gives feedback on a draft message.
3. Says NEW MESSAGE.
4. Creates, changes or deletes a communication Profile.
5. Asks about earlier finalized messages or the Rules that apply.

Flow: select Profile → load Effective Rules and examples → draft and revise → final check → finalize and consolidate Rules.

The entry Skill [lifeos](../lifeos/SKILL.md) holds what every Module shares. Read it for these topics:

- Subject: [Section 6 Subject Discovery](../lifeos/SKILL.md#6-subject-discovery), [Section 7 Subject maintenance](../lifeos/SKILL.md#7-subject-maintenance) and [Section 9 Subject deletion](../lifeos/SKILL.md#9-subject-deletion).
- Record links: [Section 10 Record links](../lifeos/SKILL.md#10-record-links).
- Remarks: [Section 11 Remarks](../lifeos/SKILL.md#11-remarks).
- Timeline: [Section 12 Timeline](../lifeos/SKILL.md#12-timeline) and [Section 13 Timeline presentation](../lifeos/SKILL.md#13-timeline-presentation).
- Subject questions and shared retrieval: [Section 14 Subject questions](../lifeos/SKILL.md#14-subject-questions).
- LifeOS Memory: [Section 15 LifeOS Memory](../lifeos/SKILL.md#15-lifeos-memory).
- Notebook: [Section 16 Notebook](../lifeos/SKILL.md#16-notebook).

## 2. Contract files to read

1. Read [../../contract/communication-assistant.md](../../contract/communication-assistant.md) for every function of this Module.
2. Read [../../contract/shared.md](../../contract/shared.md) for common rules, Subject and Timeline.
3. Take exact function names, fields, defaults and errors from the Contract. This Skill names functions in flow order only.

## 3. Rules for every flow of this Module

1. A Communication Profile is a Person, a Group or an Audience (KB 9.1).
   - Person identifies an individual.
   - Group identifies a specific shared target.
   - Audience is a reusable classification.
2. A Person or Group may inherit Communication Rules from multiple Audiences (KB 9.1).
3. Audience membership and Group Rules do not establish actual Group participants or Subject identity (KB 9.1).
4. Every persistent Person Profile identifies exactly one user-approved Person Subject (KB 9.1).
5. Each Person Subject has at most one current Person Profile. A Person Subject may exist without one (KB 9.1).
6. Communication-specific Rules and Message History stay owned by Communication Assistant (KB 9.1).
7. Do not invent Group membership, personal attributes, facts or commitments (KB 9.1, 9.3).
8. Reuse the active Profile until the user selects another (KB 9.3).
9. Save no intermediate draft, transient correction, abandoned message or its temporary feedback as persistent Learning (KB 9.3).
10. Distinguish a one-off drafting instruction from a reusable preference (KB 9.3).

## 4. Profile selection and Person Profile setup

Purpose: find the right Profile for the message, or establish one (KB 9.1).

### Input

- The person, group or audience the message is for.
- Supported relationship and language context from the conversation.

### Steps

1. Call `communication_profile_search` with the name or other wording the user used.
2. When the recipient is a known Subject, search with its `person_subject_id`.
3. When a matching Profile exists, make it the active Profile.
4. For a person without a Profile, run Person Subject Discovery under the entry Skill [Section 6 Subject Discovery](../lifeos/SKILL.md#6-subject-discovery) (KB 6.8.1).
5. Present a relevant existing Subject, or propose a new Subject, and request the user's decision.
6. After approval, create the approved new Subject with `subject_create` when needed.
7. Reuse the Subject's single Person Profile when it has one.
8. Otherwise call `communication_profile_create` with its required fields: `profile_key`, `profile_type` person, `name` and the approved `person_subject_id`.
9. When the user declines new Subject creation, continue without a persistent Person Profile.
10. Draft that message with `profile_id` empty, which uses Global Rules only.
11. For a new reusable Profile, infer only supported relationship and language context.
12. Ask only for missing details that materially affect communication.
13. For a Group or an Audience, call `communication_profile_create` with `profile_key`, `name` and `profile_type` group or audience.
14. Call `communication_profile_membership_set` to let a Profile inherit from an Audience.
15. Set `p_priority` to order several Audiences of one Profile.
16. Call `communication_profile_membership_remove` to end an inheritance.

### Choices and approvals

- The user decides the Person Subject of a new Person Profile.
- The user decides whether a new Subject is created.

### Outcome

The message has an active Profile, or proceeds without a persistent Person Profile.

## 5. Profile identity changes and deletion

Purpose: keep each Profile attached to its correct person (KB 9.1, 6.8.2).

### Input

- The user's statement that a Profile belongs to another person, or that a Profile is no longer wanted.

### Steps

1. When the user says a Profile belongs to another person, confirm the correct Subject with the user.
2. Find that Subject under the entry Skill [Section 6 Subject Discovery](../lifeos/SKILL.md#6-subject-discovery).
3. After approval, call `communication_profile_update` with the new `person_subject_id`.
4. The Profile keeps its Rules and Message History.
5. The earlier Subject and its Records stay unchanged.
6. When the user no longer wants a Profile, call `communication_profile_delete`.
7. The Subject stays. The Profile's Rules stop applying. Its Message History stays stored.
8. Before a Person Subject with a Profile is deleted, the user decides the Profile's outcome first.
9. The outcome is one of two:
   - The Profile links to its correct Subject with `communication_profile_update`.
   - The Agent deletes the Profile with `communication_profile_delete`.
10. Then delete the Subject with `subject_delete` under the entry Skill [Section 9 Subject deletion](../lifeos/SKILL.md#9-subject-deletion).

### Choices and approvals

- The user confirms every change of a Profile's Person Subject.
- The user decides the Profile's outcome before its Person Subject is deleted.

### Outcome

Each Profile keeps exactly one correct Person Subject. Source-owned Records and established identities stay unchanged (KB 9.1).

## 6. Rule scope and resolution

Purpose: apply the right Rules to each message (KB 9.2).

### Input

- The active Profile, or no Profile.
- The Language Mode of the message.
- The Platform of the message.

### Steps

1. Set the Language Mode: the language setting of the message, such as one language or a mix.
2. A Rule without a Language Mode is language-neutral. A Rule without a Profile has Global scope.
3. Set the Platform as delivery and formatting context. Platform is not a Rule inheritance layer.
4. Get the Effective Rules from `communication_runtime_context` in Section 7.
5. Effective Rules are the Rules for the active Profile and Language Mode, grouped by dimension.
6. For the same dimension and rule_key, the resolution order is:
   - Active Profile Rules outrank inherited Rules. Inherited Rules outrank Global Rules.
   - Nearer inheritance and membership priority resolve remaining ties.
   - Language-specific Rules outrank neutral Rules within the same scope.
7. Reconcile cross-key semantic conflicts yourself. The function leaves them to the Agent.
8. To inspect every raw Rule that applies, call `communication_rule_state`.
9. Call `communication_resolve` to see the Effective Rules without drafting.

### Choices and approvals

- None. Resolution follows the order above.

### Outcome

The Agent knows the Effective Rules for the active Profile and Language Mode.

## 7. Message drafting

Purpose: produce a complete send-ready message (KB 9.3).

### Input

- The intended meaning of the message.
- The active Profile, Language Mode and Platform.

### Steps

1. Call `communication_runtime_context` with the active Profile, Language Mode and Platform.
2. Apply the returned Effective Rules.
3. Use the relevant recent finalized messages as examples.
4. Do not let examples override Rules.
5. Call `communication_message_history_search` when more relevant recent finalized messages are needed as examples.
6. Draft a complete send-ready message.
7. Present only the message, without heading, explanation, preamble or postscript.
8. Keep the target Platform's supported formatting.
9. Match the intended meaning. Avoid invented facts or commitments.
10. Revise the complete message after each piece of conversational user feedback.
11. Before the final message, check its meaning, active Profile and Effective Rules.
12. Also check its Language Mode, Platform, applicable Global Writing Rules and appropriate recent examples.

### Choices and approvals

- The user gives feedback until the message is ready.
- The user may select another Profile. The new Profile becomes the active Profile.

### Outcome

One complete send-ready message, revised to the user's feedback.

## 8. Message finalization and Rule consolidation

Purpose: save the adopted message and keep the Rules current (KB 9.3).

### Input

- The latest send-ready message.
- The user's feedback during drafting.

### Steps

1. NEW MESSAGE ordinarily finalizes the preceding send-ready message, unless the user abandoned it.
   Natural completion, such as the user's approval, may also finalize it.
2. Do not finalize an abandoned message.
3. Decide the reusable Rule changes from the latest correct preference.
4. For each change, choose to keep, update, merge, remove or create a Rule.
5. Assign each learned Rule to the narrowest justified scope: Global, Audience, Group or Person (KB 9.2).
6. Keep narrower exceptions scoped.
7. Give each Rule a dimension and a rule_key. The same dimension and rule_key decide one matter.
8. Make a Rule language-specific only when the preference belongs to one Language Mode.
9. Call `communication_message_finalize` with the adopted message and its `rule_changes`.
10. Use `upsert` items to create, update or merge Rules. Use `delete` items to remove Rules.
11. Save the finalized message even when no Rule changes.
12. After NEW MESSAGE, start the next message with the same active Profile.

### Choices and approvals

- The user's NEW MESSAGE ordinarily finalizes the preceding message, unless the user abandoned it.
- Natural completion, such as the user's approval, may also finalize it.

### Outcome

The finalized message is in Message History. The Rules hold the latest correct preferences. The return includes the refreshed runtime context for the next message.

## 9. Message History retrieval and deletion

Purpose: find or remove finalized messages (KB 9.3, 6.9).

### Input

- The Profile, wording, Platform or dates the user gives.

### Steps

1. Call `communication_message_history_search` with the user's criteria.
2. Call `communication_message_history_read` for one full message.
3. To delete a message, find it and ask when it is unclear which one is meant.
4. Call `communication_message_history_delete`.

### Choices and approvals

- The user chooses which message to open or delete.

### Outcome

The user sees the requested messages. A deleted message no longer serves as an example.

## 10. Cross-module retrieval

Purpose: give the message relevant context from other Modules (KB 9.4).

### Input

- The active Person Profile and its Person Subject.

### Steps

1. Follow approved identity associations only, such as the Profile's `person_subject_id`.
2. Query source-owned Records with `subject_records` for that Subject.
3. Preserve identity, provenance and each Module's business meaning.
4. For a requested full overview, retrieve broader source-based context.
5. Keep distinct Subject identities, provenance and Record ownership in the overview.
6. Follow the entry Skill [Section 14 Subject questions](../lifeos/SKILL.md#14-subject-questions) for priority and range.

### Choices and approvals

- The user asks for a full overview when broader context is wanted.

### Outcome

The message uses relevant context. Each Record keeps its own Module ownership (KB 10.4).
