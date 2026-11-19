---
name: divination-reflection
description: Runs LifeOS Divination & Reflection. Covers Story intake, the Storybook, question preparation, Tarot and I Ching interpretation, Reading saving and retrieval, and Reading follow-up Remarks. Use when the user tells a Story for divination, asks for a Tarot or I Ching Reading, or asks about a past Reading.
compatibility: Requires the LifeOS Supabase functions in the lifeos schema and the LifeOS Config file from Google Drive. The entry Skill lifeos explains both.
---

# Divination & Reflection

## 1. Purpose and when to use

Divination & Reflection initially focuses on I Ching and Tarot.
It also owns the Storybook: Story Persons and Storylines.

Use this Skill when the user:

1. Tells a Story about people for reflection or divination.
2. Asks a question for a Tarot or I Ching Reading.
3. Supplies a card draw or a casting result.
4. Asks about a past Reading or a later development of one.
5. Adds a later Analysis from another AI, person or application.

Flow: Story intake → question preparation → user draws or casts → interpretation → save on approval → later follow-up Remarks.

The entry Skill [lifeos](../lifeos/SKILL.md) holds what every Module shares. Read it for these topics:

- Subject: [Section 6 Subject Discovery](../lifeos/SKILL.md#6-subject-discovery), [Section 7 Subject maintenance](../lifeos/SKILL.md#7-subject-maintenance) and [Section 9 Subject deletion](../lifeos/SKILL.md#9-subject-deletion).
- Record links: [Section 10 Record links](../lifeos/SKILL.md#10-record-links).
- Remarks: [Section 11 Remarks](../lifeos/SKILL.md#11-remarks).
- Timeline: [Section 12 Timeline](../lifeos/SKILL.md#12-timeline) and [Section 13 Timeline presentation](../lifeos/SKILL.md#13-timeline-presentation).
- Subject questions and shared retrieval: [Section 14 Subject questions](../lifeos/SKILL.md#14-subject-questions).
- LifeOS Memory: [Section 15 LifeOS Memory](../lifeos/SKILL.md#15-lifeos-memory).
- Notebook: [Section 16 Notebook](../lifeos/SKILL.md#16-notebook).

## 2. Contract files to read

1. Read [../../contract/divination-reflection.md](../../contract/divination-reflection.md) for every function of this Module.
2. Read [../../contract/shared.md](../../contract/shared.md) for common rules, Record links, Subject and Timeline.
3. Take exact function names, fields, defaults and errors from the Contract. This Skill names functions in flow order only.

## 3. Rules for every flow of this Module

1. Preserve the user's account. Do not invent motives, causes, private facts or divination results.
2. The user supplies the actual card draw or casting. The Agent never draws or casts for the user.
3. Reading Record, original Result, sourced Analysis and Reading Remark keep distinct business meanings.
4. A saved Reading or Analysis is never edited. It may be deleted and added again.
5. Story Persons are internal to this Module. Association with a LifeOS Subject is optional and needs user approval.
6. Divination stays usable without any Subject.
7. A user-reported third-party story is Storybook context. It is not automatically a Personal Event.
8. A Divination Record or Reading never links to a Storyline. A relation between them goes in a Reading Remark.
9. Make a link directly when the user expresses it clearly. Ask the user when a link is ambiguous.
10. Every save in this Module happens only after the user's approval.
11. Adapt language, headings, length and format to the user. Do not freeze one output template.
12. Catalog identifiers such as TS-005 are for reference only. Never show them to the user.

## 4. Story intake and Story Persons

Purpose: understand the user's Story and identify the people in it.

### Input

- The user's reported Story, in the user's own order.
- Names, gender and other identifying clues of each person.
- Known occurrence dates, periods or relative order.

### Steps

1. Listen to the Story. Follow the natural conversational order when events are narrated out of sequence.
2. Clarify relevant Story Persons, original statements, uncertainty and known occurrence timing.
3. For each person, call `story_person_search` with names, aliases or identifying clues.
4. Call `storyline_search` with the candidate Story Persons to find relevant earlier Storylines.
5. When a candidate may be the same person, ask the user to confirm before reusing that identity.
6. When no match exists, prepare a new Story Person for the later approved save (Section 6).
7. When several persons are involved, call `storyline_search` with all their `story_person_ids`.
8. Use `matched_person_ids` to tell shared, subgroup and individual Storylines apart.
9. Distinguish directly shared developments from indirect personal background.
10. Call `divination_search` with the confirmed `story_person_id` to recognize relevant earlier Readings.

### Choices and approvals

- The user confirms whether a candidate Story Person is the person in the Story.
- An optional Subject association follows the entry Skill [Section 6 Subject Discovery](../lifeos/SKILL.md#6-subject-discovery). The user approves it.

### Outcome

The Agent knows the confirmed Story Persons, the relevant Storylines and the relevant earlier Readings. Nothing is saved yet.

## 5. Storyline identity and timing

Purpose: decide whether new information belongs to an existing Storyline or a new one.

### Input

- The new information from the Story.
- The relevant existing Storylines from Section 4.

### Steps

1. Compare the temporal identity of the actual occurrence with each relevant Storyline.
2. Compare the involved persons, activity, location and other context.
3. Clarify with the user whether two descriptions are the same occasion, a corrected account or a different occasion.
4. Resolve conflicting information through the user.
5. Keep actual occurrence dates or periods when known.
6. Keep relative order when the user gives before, after, during or separate-occasion context. Use `time_text` for that wording.
7. Keep an unknown date, time or relative order unknown.
8. A Storyline end date is never before its start date. The same day is allowed.

### Choices and approvals

- The user decides whether the information is the same occasion, a correction or a different occasion.

### Outcome

Each planned change is one of three kinds:

1. Added details for a confirmed existing Storyline.
2. Corrected content that replaces incorrect content in a confirmed Storyline.
3. A new Storyline for a different occurrence.

Recorded Time is distinct from occurrence time. It does not establish the real-world chronology.

## 6. Storybook save at the Story Context Cutoff

Purpose: save Storybook updates at the right moment and only with approval.

### Input

- The planned Story Person and Storyline changes from Sections 4 and 5.

### Steps

1. Recognize a Story Context Cutoff. A cutoff is any of these:
   - The user changes focus or story.
   - The user returns to another Story.
   - The conversation moves to divination question preparation.
   - The conversation moves to another destination or activity.
   - The user signals the end of the conversation, such as with thanks or "that is all for now".
2. When the conversation stops without an end signal, no cutoff occurs. Save nothing from that segment.
3. Present the relevant Story segment and the planned Storybook updates in friendly language.
4. Ask the user's permission to save.
5. On approval, call `story_person_create` for each new Story Person.
6. Supply `subject_id` only when the user approved that Subject association.
7. Call `story_person_update` for an approved change to an existing Story Person, including a new Subject association.
8. Call `storyline_create` for each new Storyline, with its `story_person_ids` and known dates.
9. Call `storyline_update` to add details or replace incorrect content in a confirmed Storyline.
10. Keep distinct developments as distinct Storylines.
11. When a Storyline and a Personal Event describe the same matter, keep both and link them with `record_link_create`.
12. After the save, continue with Section 14 to offer a Reading Remark.

### Choices and approvals

- The user approves or declines the Storybook save.
- When the user declines, save nothing from that segment.
- An end signal leads to the same save question. The save still needs the user's approval.

### Outcome

The approved Storylines and Story Persons are saved. A Storyline keeps only its latest correct content, without correction history.

## 7. Question preparation and method selection

Purpose: turn the user's concern into clear, copyable questions and a fitting method.

### Input

- The user's underlying concern and Story.
- The desired focus: past, present, future, practical or comparative.
- For an Objective-Driven question: the objective, the time horizon and the user's options.

### Steps

1. Identify the user's underlying concern and desired focus.
2. Refine the question naturally into neutral first-person wording.
3. For career and finance, use the Objective-Driven approach by default.
4. Use the Objective-Driven approach for other subjects when appropriate.
5. In the Objective-Driven approach, understand the objective, the time horizon and the user-supplied options.
6. Prepare a separate question for each option.
7. Recommend a fitting method for each question.
8. Let the user select I Ching or Tarot for each question.
9. For I Ching, direct the user to the user-designated interface: https://i-ching-pro.vercel.app/app.html.
10. For Tarot, continue with Section 8.
11. Give each question as one independently copyable block where possible.
12. Otherwise separate the complete questions vertically.

### Choices and approvals

- The user selects the method for each question.
- The user may add or revise options later. Each later option becomes its own question and Reading (Section 11).

### Outcome

Each question has neutral first-person wording, a selected method and a copyable block.

## 8. Tarot Spread selection and template

Purpose: give the user a fitting Spread and a copy-ready template for the draw.

### Input

- The prepared Tarot question.
- The Spreads in the Canonical Tarot Spread Catalog (Section 15).

### Steps

1. Recommend a suitable Spread from the user's question and each Spread's original purpose.
2. You may show the Spread's visual layout when guiding the user. Use its 原图布局.
3. Provide a separate copy-ready template for each Tarot question, in the user's first-person wording.
4. Show the Spread name without its catalog identifier.
5. Keep the numbered card Positions and their meanings.
6. Add a question-specific subtitle and 观察重点 for each Position.
7. Leave 抽到的牌： blank for the user's numbered results and card orientation.
8. Ask the user to draw cards in ascending Position number order.
9. The user may use physical cards or any online source.

### Choices and approvals

- The user accepts the recommended Spread or chooses another Spread from the Library.
- The user draws the cards independently.

### Outcome

The user returns the filled template. The Agent associates each reported card with its numbered Position meaning.

## 9. Tarot interpretation

Purpose: interpret the user's draw against the question, the Spread and the Story.

### Input

- The user's card results and orientations by Position.
- The question, the Spread and the user's Story.

### Steps

1. For each card, explain its traditional meaning.
2. Explain its relevance to the question domain and its Spread Position.
3. Explain meaningful actual pictured symbols and their domain and Position relevance.
4. Give concise, nonduplicate Attributes and Keywords.
5. Follow with a coherent unlabeled connection to the user's supplied Story.
6. After all cards, present a natural integrated Spread summary.
7. Select applicable element, suit, number, rank, archetype and established astrological correspondence.
8. Do not invent absent attributes.
9. Respect the user's Tarot deck and tradition.

### Choices and approvals

- None. The user may ask follow-up questions about the interpretation.

### Outcome

A complete Tarot interpretation. Continue with Section 11 to offer the save.

## 10. I Ching interpretation and optional 梅花易数

Purpose: interpret the user's casting, then offer a deeper second round when useful.

### Input

- The user's supplied 本卦, 动爻 or 静爻 and 变卦.
- 互卦, 综卦 and 错卦 when the user supplies them.
- The original Question and, for comparisons, the user's Objective.

### Steps

1. Interpret the 本卦 and its 卦辞.
2. Interpret the selected 动爻 or 静爻 with their original 爻辞.
3. Interpret the 变卦 and 体/用.
4. Interpret the supplied 互卦, 综卦 and 错卦 when useful.
5. Explain relevant trigrams, elements, traditional correspondences and plain-language meanings.
6. Connect each component to the original Question.
7. Select changing lines with Zhu Xi's 易学启蒙 as the default reference.
8. For four moving lines, consult the two unchanged transformed lines, lower first.
9. For five moving lines, consult the sole unchanged transformed line.
10. Explain every selected line in the actual Question's context.
11. For exploration, offer a coherent full interpretation.
12. For comparative choices, assess the independent Readings against the user's Objective.
13. Rank the options by relative alignment.
14. Explain key favourable factors and obstacles, and the reasons between neighbouring options.
15. Present rankings as relative comparisons, not guaranteed outcomes.
16. Complete the standard analysis before considering a second round.
17. Offer an optional 梅花易数 interpretation when it is useful for the Question and first result.
18. Useful areas are timing/应期, obstacles, future stages, opportunities or similar dynamics.
19. Give the 梅花易数 interpretation as a second round of the same Reading.
20. Keep it distinct from the standard I Ching interpretation. It becomes a second, separate Analysis of that Reading (Section 11).

### Choices and approvals

- The user chooses whether to proceed with 梅花易数.
- When the user chooses it, keep the original Reading context.

### Outcome

A complete I Ching interpretation, with an optional 梅花易数 round for the same Reading. Continue with Section 11 to offer the save.

## 11. Reading save

Purpose: save a completed divination session as one Divination Record.

### Input

- Each Question with its full original user-provided Result text, method and relevant time.
- For Tarot, the Spread name.
- The interpretation of each Reading and any combined interpretation.
- The confirmed Story Persons of each Reading.

### Steps

1. Complete the divination and its interpretation first.
2. Ask the user whether to save.
3. On approval, extract and organize each original Question and Result.
4. Keep the original Result text whole. Do not split hexagrams, lines, cards or Positions into separate items.
5. Write each Analysis with `source`, Overall Outcome and Key Reasoning. A Reading may have one or more Analyses.
   - For your own interpretation, set `source` to the name of your AI system.
   - After a 梅花易数 round, put two Analyses in that Reading's `analyses`.
   - One Analysis holds the standard I Ching interpretation. A second, separate Analysis holds the 梅花易数 interpretation.
6. Key Reasoning explains how the interpretation of symbols relates to the Question and user context.
7. Add Story Context only when the source actually discusses useful Story details.
8. Put an Analysis shared by several Questions once in `record_analyses`. Do not repeat it under each Reading.
9. Set each Reading's `story_person_ids` to its confirmed Story Persons.
10. Call `divination_record_save` once for the session.
11. A Reading's Subject is the Subject of its approved Story Persons.
    The Story Person's `subject_id` makes this connection. No separate Subject link call is needed.
12. When the Reading corresponds to a Personal Event, link them with `record_link_create`.
13. For a later additional or revised option, call `reading_create` on the existing Divination Record.
14. Earlier distinct Readings stay unchanged.

### Choices and approvals

- The user approves or declines the save.
- When the user declines, finish the conversation without creating a Divination Record.

### Outcome

One Divination Record holds every Reading of the session, each with its original Result and sourced Analyses.

## 12. Later Analyses, deletion and re-adding

Purpose: keep Readings as the user gave them while allowing later sources and corrections.

### Input

- The saved Reading or Divination Record.
- A later Analysis and its author, or the user's correction request.

### Steps

1. Find the Reading with Section 13.
2. Call `analysis_add` for a later Analysis from an outside AI, person or application.
3. Record its authorship in `source`.
4. Use `reading_id` for one Reading. Use `divination_record_id` alone for a combined Analysis.
5. A 梅花易数 round for an already saved Reading is also a second, separate Analysis. Call `analysis_add` with that `reading_id`.
6. For a wrong saved Reading, call `reading_delete`, then `reading_create` with the correct content.
7. For a wrong saved Analysis, call `analysis_delete`, then `analysis_add` with the correct content.
8. To delete a whole session, call `divination_record_delete`.
9. `divination_record_update` changes only the title, topic, session date or metadata.

### Choices and approvals

- The user decides each deletion and re-adding.

### Outcome

The original Reading and earlier Analyses stay unchanged. Timeline shows later Analyses under the original Reading Date.

## 13. Past Reading retrieval

Purpose: let the user recognize a past Reading quickly.

### Input

- A Subject, Story Person, topic or date from the user.

### Steps

1. Call `divination_search` with `subject_id`, `story_person_id`, `keyword` or dates.
2. Show each Question, its original Result and the Overall Outcome of each Analysis.
3. When the user asks for more, call `divination_record_read`.
4. Show Key Reasoning, Story Context and Remarks only when the user asks.

### Choices and approvals

- The user chooses which Reading to open and what detail to see.

### Outcome

The user sees the short view first and the full view on request.

## 14. Reading Story Persons and follow-up Remarks

Purpose: connect real-world developments to earlier Readings.

### Input

- A new development from the user's Story.
- The relevant earlier Readings found in Section 4.

### Steps

1. Recognize a possible correspondence between the new development and a previous Reading.
2. Use the relevant persons, the original question or focus, and the timing.
3. When several Readings fit, clarify with the user which Reading is intended.
4. After the user-approved Storyline save at the cutoff (Section 6), separately offer a Reading Remark.
5. When the user agrees, call `reading_remark_add` on the Reading.
6. Supply the saved Storyline as `storyline_id`.
7. Write in `text` a short description of the real-world development and its correspondence with the Reading.
8. Later approved follow-ups add entries to the same Reading Remark with `reading_remark_add`.
9. Corrections and additions follow the same cutoff and approval flow.
10. Call `reading_remark_update` to correct an entry. It replaces the whole entry.
11. Call `reading_remark_delete` to remove an entry.
12. To change a saved Reading's Story Persons, ask for approval, then call `reading_story_persons_set`.

### Choices and approvals

- The user approves the Storyline save first.
- The user then separately agrees to the Reading Remark.
- The user approves every change of a Reading's Story Persons.

### Outcome

The Reading Remark explains the correspondence. The original Reading and sourced Analysis stay unchanged. A Remark change and a Story Person change are not edits. They leave the Reading's updated time unchanged.

## 15. Canonical Tarot Spread Catalog

The Tarot Spread Library is authoritative for Spread selection. Source: Approved Tarot Spread Library, https://docs.google.com/document/d/1WFS08q80T2fQuh1f9PFmyGWET8K-hFqYhskyhTRLU8Y/edit.
The catalog holds seven Spreads and 30 numbered Positions. Repeated source meanings stay as separate numbered Positions.
The identifiers TS-001 to TS-007 are for reference only. Show the Spread name without them.

### 15.1 TS-001 — 大十字阵占卜

看清阻碍 · 找到方向 · 走向答案
五张牌 · 五个角度
帮你看清问题的关键与下一步
原图布局：上3；中左1；中间5；中右2；下4。

1. 外在因素 — 可能的阻碍或帮助，影响事情发展的外在原因
2. 外在因素 — 可能的阻碍或帮助，影响事情发展的外在原因
3. 远因 — 问题发生的深层原因
4. 解决方法 — 针对这个问题最适合的行动与建议
5. 最终结果 — 这件事可能的走向与结局

备注：1号与2号原文相同。用户确认它们可分别代表两个外在因素，保留原文。

### 15.2 TS-002 — 友谊阵占卜

看清彼此 · 理解关系 · 走向未来
六张牌 · 六个角度
从不同面向了解你们的关系
原图布局：自己（上排）1、3、5；对方（下排）2、4、6。

1. 你对对方的看法 — 你目前对这段友谊的想法与感受。
2. 对方对你的看法 — 对方目前对你的想法与感受。
3. 你认为的关系现状 — 你眼中目前的相处状态。
4. 对方认为的关系现状 — 对方眼中目前的相处状态。
5. 你期望的未来发展 — 你希望这段友谊走向哪里。
6. 对方期望的未来发展 — 对方希望这段友谊走向哪里。

### 15.3 TS-003 — 事情进展阵占卜

看清现状 · 预见发展 · 做好准备
四张牌 · 四个角度
帮你看清事情的进展与未来走向
原图布局：上2；中左1；中右3；下4。

1. 持续发展 — 这件事情会如何持续发展下去。
2. 现状 — 目前的情况，正在发生什么。
3. 未来四周 — 接下来四周内可能出现的情况与发展。
4. 结果 — 最终的走向，可能的结果。

### 15.4 TS-004 — 今日工作阵占卜

看清状态 · 掌握节奏 · 更好应对今天
两张牌 · 两个角度
帮你看清今天的工作能量与状态。
原图布局：横排1、2。

1. 今日的身心状态 — 你今天的精神、情绪与整体状态。
2. 今日的工作状况 — 今天在工作上可能出现的情况与节奏。

### 15.5 TS-005 — 关键阵占卜

抓住关键 · 看清重点 · 预见下一步
三张牌 · 三个角度
帮你快速抓住问题的核心与接下来的发展。
原图布局：横排1、2、3。

1. 关键 — 这件事最核心的问题在哪里。
2. 重点 — 你现在最需要看见与把握的重点。
3. 前方 — 接下来你将面对的情况与发展。

### 15.6 TS-006 — 安妮金关键展开法

聚焦核心 · 看清重点 · 做出行动
通过三张牌，帮你找到问题的关键，看清眼前的能量，明确下一步的方向。
原图布局：横排1、2、3。

1. 问题的关键 — 当前问题的核心，你需要关注的重点。
2. 关键的重点 — 影响此问题的关键因素，可能的阻碍或帮助。
3. 面对的方向 — 在你面前的选择，你需要面对的能量，以及建议的行动方向。

### 15.7 TS-007 — 六芒星阵占卜

看清过去 · 理解现在 · 指引未来
七张牌 · 七个角度
从不同层面解析你的问题，看见更完整的答案。
原图布局：上1；左上5；右上6；左下3；右下2；下4；中心7。

1. 过去状况 — 事情的起源，过去发生了什么。
2. 现在状况 — 目前的实际情况，现在的状态。
3. 未来状况 — 接下来会如何发展，未来的趋势。
4. 应对策略 — 针对这个问题，你可以采取的行动与建议。
5. 周遭状况 — 外在环境、他人影响或潜在的助力/阻力。
6. 本人态度 — 你对这件事的想法、情绪与内在心态（希望或恐惧）。
7. 最后结果 — 事情可能的最终走向与发展。
