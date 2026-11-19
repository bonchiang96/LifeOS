---
name: communication-assistant
description: Runs the LifeOS Communication Assistant. Covers Person, Group and Audience Profiles, Communication Rules and their resolution, message drafting, finalization and Message History. Use when the user asks for a message to someone, says NEW MESSAGE, or manages a communication Profile.
compatibility: Requires the LifeOS Supabase functions in the lifeos schema and the LifeOS Config file from Google Drive. The entry Skill lifeos explains both.
---

# Communication Assistant

## 1. Purpose and when to use

Communication Assistant drafts send-ready messages for the user. It learns reusable Communication Rules from finalized messages.
It also saves the Rule changes that the user asks for outside a message.
It keeps the message and rule lifecycle taken over from V1.

Use this Skill when the user:

1. Asks for a message, reply or post for a person, group or audience.
2. Gives feedback on a draft message.
3. Says NEW MESSAGE.
4. Creates, changes or deletes a communication Profile.
5. Asks about earlier finalized messages or the Rules that apply.
6. Asks to add, change or remove a Communication Rule outside a message.

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

1. A Communication Profile is a Person, a Group or an Audience.
   - Person identifies an individual.
   - Group identifies a specific shared target.
   - Audience is a reusable classification.
2. A Person or Group may inherit Communication Rules from multiple Audiences.
3. Audience membership and Group Rules do not establish actual Group participants or Subject identity.
4. Every persistent Person Profile identifies exactly one user-approved Person Subject.
5. Each Person Subject has at most one current Person Profile. A Person Subject may exist without one.
6. Communication-specific Rules and Message History stay owned by Communication Assistant.
7. Do not invent Group membership, personal attributes, facts or commitments.
8. Reuse the active Profile until the user selects another.
9. Save no intermediate draft, transient correction, abandoned message or its temporary feedback as persistent Learning.
10. Distinguish a one-off drafting instruction from a reusable preference.

## 4. Profile selection and Person Profile setup

Purpose: find the right Profile for the message, or establish one.

### Input

- The person, group or audience the message is for.
- Supported relationship and language context from the conversation.

### Steps

1. Call `communication_profile_search` with the name or other wording the user used.
2. When the recipient is a known Subject, search with its `person_subject_id`.
3. When a matching Profile exists, make it the active Profile.
4. For a person without a Profile, run Person Subject Discovery under the entry Skill [Section 6 Subject Discovery](../lifeos/SKILL.md#6-subject-discovery).
5. Present a relevant existing Subject, or propose a new Subject, and request the user's decision.
6. After approval, create the approved new Subject with `subject_create` when needed.
7. Reuse the Subject's single Person Profile when it has one.
8. Otherwise call `communication_profile_create` with its required fields: `profile_key`, `profile_type` person, `name` and the approved `person_subject_id`.
9. When the user declines new Subject creation, continue without a persistent Person Profile.
10. Draft that message with `profile_id` empty, which uses Global Rules only.
11. For a new reusable Profile, infer only supported relationship and language context.
12. Ask only for missing details that materially affect communication.
13. Decide yourself when a Group Profile, an Audience Profile or an Audience membership is useful.
14. Create, change or remove each of them without the user's approval.
    - Change a Profile with `communication_profile_update` and remove it with `communication_profile_delete`. Steps 15 to 18 hold the create and membership calls.
15. For a Group or an Audience, call `communication_profile_create` with `profile_key`, `name` and `profile_type` group or audience.
16. Call `communication_profile_membership_set` to let a Profile inherit from an Audience.
17. Set `p_priority` to order several Audiences of one Profile.
18. Call `communication_profile_membership_remove` to end an inheritance.

### Choices and approvals

- The user decides the Person Subject of a new Person Profile.
- The user decides whether a new Subject is created.
- The Agent decides Group Profiles, Audience Profiles and Audience memberships by itself. They need no approval.

### Outcome

The message has an active Profile, or proceeds without a persistent Person Profile.

## 5. Profile identity changes and deletion

Purpose: keep each Profile attached to its correct person, and keep one Person Profile when two Profiles describe one person.

### Input

- The user's statement that a Profile belongs to another person, or that a Profile is no longer wanted.
- Two Subjects that both have a Person Profile, from the entry Skill [Section 8 Duplicate Subject merge](../lifeos/SKILL.md#8-duplicate-subject-merge). The user has approved the Subject merge.

### Steps for a Profile change or deletion

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

### Steps for two Person Profiles of one person

1. Take each Subject's Person Profile from the `person_profile_id` that `subject_read` returns.
2. Read each Profile with `communication_profile_read`. Its `parent_profiles` lists its Audience memberships.
3. Read the `language_modes` Notebook with `notebook_read`.
4. Read each Profile's Rules with `communication_rule_state`. Call it once without a Language Mode and once per value in that Notebook.
5. Keep the returned Rules with `scope` profile, once per `id`. They are the Profile's own Rules.
6. Find each Profile's recent finalized messages with `communication_message_history_search` and its `profile_id`.
7. Show both Profiles to the user with their Rules and recent messages.
8. Ask the user to choose the Profile that stays. The other Profile is the merged Profile.
9. Find each Rule conflict between the two Profiles.
   - A conflict is two Rules with the same Language Mode, dimension and rule_key.
   - A Rule without a Language Mode conflicts only with another Rule without a Language Mode.
10. For each conflict, show both Rules and ask the user to choose the Rule that stays.
11. Delete the other Rule of each conflict with `communication_rule_delete`.
    - The Rule that the user chose stays.
    - When the chosen Rule belongs to the merged Profile, the merge moves it to the kept Profile.
12. Keep the useful identity details of the merged Profile on the kept Profile with `communication_profile_update`.
    - The merge combines no name, aliases or description.
    - For example, add the merged Profile's name to the kept Profile's `aliases`.
    - Supply the whole new `aliases` array. A supplied array replaces the stored array.
13. Keep each Audience membership of the merged Profile that still applies.
    - Call `communication_profile_membership_set` with the kept Profile as child and that Audience as parent.
    - The merge moves no membership.
14. Call `communication_profile_merge` with the kept Profile as `keep_id` and the merged Profile as `merge_id`.
15. The function moves every Rule and every Message History item of the merged Profile to the kept Profile.
16. The function then deletes the emptied merged Profile.
17. When the call returns "invalid relationship" for a remaining Rule conflict, resolve it with steps 10 and 11. Then call again.
18. Return to the entry Skill [Section 8 Duplicate Subject merge](../lifeos/SKILL.md#8-duplicate-subject-merge). It runs `subject_merge`.

### Choices and approvals

- The user confirms every change of a Profile's Person Subject.
- The user decides the Profile's outcome before its Person Subject is deleted.
- For two Person Profiles of one person, the user chooses the Profile that stays.
- The user chooses the Rule that stays in each Rule conflict.
- The Agent keeps identity details and Audience memberships on the kept Profile by itself.

### Outcome

Each Profile keeps exactly one correct Person Subject. Source-owned Records and established identities stay unchanged.

After a Profile merge, one Person Profile holds the Rules and Message History of both. The merged Profile is deleted, and the Subject merge continues.

## 6. Rule scope and resolution

Purpose: apply the right Rules to each message.

### Input

- The active Profile, or no Profile.
- The Language Mode of the message.
- The Platform of the message.

### Steps

1. Language Mode is the language setting of the message, such as one language or a mix.
2. Read the `language_modes` Notebook with `notebook_read` before you set the Language Mode.
3. Reuse the existing value that fits the message.
4. When no existing value fits, add a new value with `notebook_update`. Write the full new content.
5. A Rule without a Language Mode is language-neutral. A Rule without a Profile has Global scope.
6. Platform is delivery and formatting context. Platform is not a Rule inheritance layer.
7. Read the `platforms` Notebook with `notebook_read` before you set the Platform.
8. Reuse the existing value that fits the message.
9. When no existing value fits, add a new value with `notebook_update`. Write the full new content.
10. Get the Effective Rules from `communication_runtime_context` in Section 7.
11. Effective Rules are the Rules for the active Profile and Language Mode, grouped by dimension.
12. For the same dimension and rule_key, the resolution order is:
    - Active Profile Rules outrank inherited Rules. Inherited Rules outrank Global Rules.
    - Nearer inheritance and membership priority resolve remaining ties.
    - Language-specific Rules outrank neutral Rules within the same scope.
13. Reconcile cross-key semantic conflicts yourself. The function leaves them to the Agent.
14. To inspect every raw Rule that applies, call `communication_rule_state`.
15. Call `communication_resolve` to see the Effective Rules without drafting.

### Choices and approvals

- None. Resolution follows the order above.
- Notebook values need no approval. The entry Skill [Section 16 Notebook](../lifeos/SKILL.md#16-notebook) holds the Notebook flow.

### Outcome

The Agent knows the Effective Rules for the active Profile and Language Mode.

## 7. Message drafting

Purpose: produce a complete send-ready message.

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
12. Also check its Language Mode, Platform and appropriate recent examples.
13. Check it against the Global scope Communication Rules. These are the Rules without a Profile.
14. Read them with `communication_rule_state` with no Profile and the message's Language Mode.
15. A Profile Rule or an inherited Rule with the same dimension and rule_key still outranks a Global Rule.

### Choices and approvals

- The user gives feedback until the message is ready.
- The user may select another Profile. The new Profile becomes the active Profile.

### Outcome

One complete send-ready message, revised to the user's feedback.

## 8. Message finalization and Rule consolidation

Purpose: save the adopted message and keep the Rules current.

### Input

- The latest send-ready message.
- The user's feedback during drafting.

### Steps

1. NEW MESSAGE ordinarily finalizes the preceding send-ready message, unless the user abandoned it.
   Natural completion, such as the user's approval, may also finalize it.
2. Do not finalize an abandoned message.
3. When the conversation ends without NEW MESSAGE or approval, the send-ready message stays unfinalized. Save nothing for it.
4. Decide the reusable Rule changes from the latest correct preference.
5. For each change, choose to keep, update, merge, remove or create a Rule.
6. Assign each learned Rule to the narrowest justified scope: Global, Audience, Group or Person.
7. Keep narrower exceptions scoped.
8. Give each Rule a dimension and a rule_key. The same dimension and rule_key decide one matter.
9. Make a Rule language-specific only when the preference belongs to one Language Mode.
10. Use the Language Mode and Platform values from Section 6.
11. Call `communication_message_finalize` with the adopted message and its `rule_changes`.
12. Use `upsert` items to create, update or merge Rules. Use `delete` items to remove Rules.
13. Save the finalized message even when no Rule changes.
14. After NEW MESSAGE, start the next message with the same active Profile.

### Choices and approvals

- The user's NEW MESSAGE ordinarily finalizes the preceding message, unless the user abandoned it.
- Natural completion, such as the user's approval, may also finalize it.
- Without NEW MESSAGE or approval before the conversation ends, the message stays unfinalized.

### Outcome

The finalized message is in Message History. The Rules hold the latest correct preferences. The return includes the refreshed runtime context for the next message.

## 9. Message History retrieval and deletion

Purpose: find or remove finalized messages.

### Input

- The Profile, wording, Platform or dates the user gives.

### Steps

1. Call `communication_message_history_search` with the user's criteria.
   - For a Language Mode or Platform, use its value from the `language_modes` or `platforms` Notebook.
2. Call `communication_message_history_read` for one full message.
3. To delete a message, find it and ask when it is unclear which one is meant.
4. Call `communication_message_history_delete`.

### Choices and approvals

- The user chooses which message to open or delete.

### Outcome

The user sees the requested messages. A deleted message no longer serves as an example.

## 10. Cross-module retrieval

Purpose: give the message relevant context from other Modules.

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

The message uses relevant context. Each Record keeps its own Module ownership.

## 11. Rule changes outside a message

Purpose: save a Rule change that the user asks for outside a message.

### Input

- The user's request to add, change or remove a Communication Rule.
- The person, group, audience or language that the request names.

### Steps

1. Decide the scope of the Rule yourself: Global, Audience, Group or Person.
2. Assign the narrowest justified scope. Keep narrower exceptions scoped.
3. For an Audience, Group or Person scope, find or establish its Profile under Section 4.
4. Make the Rule language-specific only when the preference belongs to one Language Mode.
5. Take a Language Mode value from the `language_modes` Notebook under Section 6.
6. Read the current Rules with `communication_rule_state` for that Profile and Language Mode.
7. Give the Rule a dimension and a rule_key. Reuse those of an existing Rule that decides the same matter.
8. To add or change a Rule, call `communication_rule_upsert`.
9. Leave `profile_id` empty for a Global Rule.
10. To remove a Rule, call `communication_rule_delete` with its `id`.
11. Save the change without asking for the user's confirmation.

### Choices and approvals

- The Agent decides the scope and saves the change by itself.
- A new Person Profile still needs the user's decision on its Person Subject (Section 4).

### Outcome

The Rules hold the user's requested change. Later messages apply it through Rule resolution (Section 6).
