# Proposal: agent briefs as bounded, verifiable work contracts

Date: 2026-09-17. Status: proposal only; no policy or implementation changed.
Repository inspected: `/workspace/t-engine4/game/addons/tome-mcp-bridge`, HEAD `c4777ebfac517c7ee5f8b772e64543c65bc61939`. The checkout already contained product/test/dist modifications belonging to other work; this analysis did not alter them. Historical results below are documentary evidence, not tests independently rerun by this analyst.

## Recommendation

Keep the existing task/context/files/acceptance structure. Add a small mandatory contract header, one exclusive role module, a requirement-to-evidence table, and a complete feedback ledger. Render each dispatch as one self-contained brief. Do not make a longer chronological narrative the enforcement mechanism.

The five highest-value changes are:

1. **Bind an exclusive role to agent identity and permissions.** Separate the dispatcher’s lifecycle work from Dev, Test, Review and Investigation; record who independently accepts the result.
2. **Require evidence for each requirement through the actual production boundary.** Name allowed doubles, observable effects, independent verification, and exact source/package identities; test counts and SHA values alone are insufficient.
3. **Make completion a gated ledger, not a narrative claim.** Every feedback ID needs a verified fix or an explicit disposition; deferral does not silently waive mandatory acceptance criteria. Dev reports ready for review, never accepted/merged.
4. **Publish one resolved, versioned contract.** Inline binding decisions and supersession, explicitly exclude the next phase, and resolve conflicting instructions before dispatch.
5. **Freeze metric definitions before observation.** Include population, numerator, denominator, time window, expected categories, exclusions, and missing-data treatment; later discoveries create a new metric version, never rewrite the old round.

## Evidence and limitations

Paths in the following table are rooted at `REPO=/workspace/t-engine4/game/addons/tome-mcp-bridge` or `SUPPORT=/workspace/t-engine4/tmp/mcp-play-support`. These roots must be explicit in future briefs: `tmp/mcp-play-support` does not exist relative to the repository cwd used for this task.

| Ref | Source and precise locator | What it establishes |
| --- | --- | --- |
| E1 | `REPO/AGENTS.md:54–77` | Test agents play/report only; development owns lifecycle; all feedback must be fixed/tested/committed or documented as TODO before rebuild/restart; old test agent is archived. |
| E2 | `REPO/AGENTS.md:29`, `REPO/docs/tome-mcp-auto-combat-plugin-design.md:399–418` | Actual policy conflict: AGENTS forbids read RNG/state changes; design v1.4 explicitly supersedes purity assumptions and permits audited dynamic reads within action/information boundaries. |
| E3 | `SUPPORT/wave1-execution-safety-handoff.md:7–27`; `REPO/docs/tome-mcp-0.9.0-wave1-execution-safety.md:6–8,81–109` | Fake host outcomes hid production mapping failures, including native pending. Later briefs explicitly require production tests and source/dist probes. |
| E4 | `SUPPORT/wave1-execution-safety-handoff.md:80–92,123–160`; `SUPPORT/wave2-interface-contract-handoff.md:33–60,91–114` | Open choices and obsolete directions remain above binding D-rulings. Example: talent-category certification versus D1 allowing any talent subject to the guard; SAFE-01 narrow-or-audit versus D11 requiring audit. |
| E5 | `SUPPORT/playtest-metric-round-handoff.md:1–10,18–34,36–84` | This is a dispatcher/coordinator brief despite its playtest label: launch, delegate play, fix, package, PR. Repackage-before-start also sits beside a fixed package hash. |
| E6 | `SUPPORT/review-gpt56sol-prompt.md:3–5,8–9,45–77` | Good issue schema and uncertainty reporting; target is a mutable main/post-PR description, no recipient ID, and “read-only” tests lack an explicit scratch-output exception. |
| E7 | `SUPPORT/selffire-investigation-handoff.md:61–66,94–108`; `SUPPORT/selffire-drift-fix-handoff.md:2–21,61–83` | Investigation’s strict purity premise was later superseded; correction usefully states the new rule and excludes full v2 work. |
| E8 | `REPO/docs/tome-mcp-0.9.0-auto-combat-round3-feedback.md:23–49,66–93`; `REPO/docs/tome-mcp-0.9.0-auto-combat-round3-followup.md:46–63` | Round 3 preserves unexpected categories and unobserved codes; restart counts differ between transcript and curated report; later metric categories and unit-only coverage need version/layer separation. The tick probe is documented as failing before the fix. |
| E9 | `REPO/VALIDATION.md`, sections “Wave 1”, “Wave 2”, “P2.5” | Useful source/dist and hash evidence, but cumulative historical acceptance includes older purity rules. It is evidence history, not automatically the current normative policy. |
| E10 | `SUPPORT/p1a-integration-handoff.md:35–45` | “What was tried” states native_pending is unnecessary because execute is synchronous; later E3 contradicts that. Historical reasoning needs an evidence-status label. |
| E11 | `SUPPORT/followup-45A-46-47-handoff.md:22–26,39–48,50–70`; `SUPPORT/class-adapters-handoff.md:7–18,34–59` | Strong bounded scope and useful deliverable lists; optional probes and fallback pilot count need explicit acceptance applicability. |

The local AGENTS.md ends at line 78 and **does not contain** the requested “代理派发原则（独立上下文，必须遵守）” section. This proposal treats the independence rule explicitly supplied in this task as the intended requirement; it cannot claim that missing text was verified. Before using the template, the dispatcher should reconcile the actual AGENTS file and the read-policy conflict. No gameplay/read experiments were needed for this process analysis.

Other P1a/P1b/P2/P2.5/P3 briefs and relevant 0.9.0 design/status/TODO material were consulted for scope and evidence conventions. This is a process review, not validation of all historical product claims or every 0.9.0 document.

## Canonical template: shared core plus exactly one role module

The following is a proposed format, not an implemented schema or validator. Angle-bracket fields must be filled before sending; an explicit `not_applicable: <reason>` is preferable to an empty field.

```markdown
# [<Dev|Test|Review|Investigation>] <bounded outcome>

## Dispatch contract
- Brief: <task-id> revision <n>; issued <UTC>; replaces <brief-id/revision or none>.
- Role: <one role only>. Dispatcher/return-to: <exact Paseo agent ID>.
- Recipient: <agent ID, or recorded by dispatcher immediately after creation>.
- Independence: <fresh context | recheck of review-id and exact finding IDs>.
  Implementer IDs: <...>; tester IDs: <...>; reviewer ID: <...>.
- Roots: repo=<absolute>; support=<absolute>; evidence=<absolute per-task tmp>.
- Baseline: branch=<name>; source=<full commit>; dirty overlay=<none or manifest>.
- Target artifact: <path+sha256 or not applicable>; engine/harness/config=<pins>.
- Permissions: read=<...>; write=<exact paths>; git=<none|branch/commit/push/PR>;
  processes=<none|named isolated probes>; merge=no; shared game lifecycle=no.
- Ownership/dependencies: <named writer + paths; prerequisite result/commit>.
- Stop/report on: wrong baseline/artifact/session, unresolved contract conflict,
  inability to gather required evidence, or a requested action outside this role.
  Continue unrelated authorized work; never silently relax a gate.

## Task and boundary
Outcome: <one imperative plus observable result>.
Required IDs: <requirements/findings>; deliverables: <exact paths and PR if applicable>.
Out of scope: <next phase, adjacent fixes, unchanged interfaces/defaults>.
Allowed implementation choices: <explicit freedom>; contract changes require
an amended brief from <dispatcher/maintainer>, not an implementer's inference.

## Binding contract (read first)
- <decision ID @ revision>: <current rule>; supersedes <specific older text>.
- <critical invariant/default>: <observable meaning, not “keep safe”>.
- Must-read: <absolute doc, pinned revision/hash, section, why it is needed>.
- Historical only: <old reports/attempts>; do not promote these to requirements.
Conflicts not explicitly resolved by the authorized brief are reported before
work dependent on them. Document recency alone does not override instructions.

## Current state and relevant files
- Verified fact: <claim + source/evidence + revision>.
- Reported/unverified hypothesis: <claim + how to check>.
- Known failed approach: <only if useful; failure evidence and applicability>.
- <file/symbol>: <purpose for this task>. List only files needed to begin.

## Work and acceptance table
| ID | Setup/input + production entry | Expected observable | Method + doubles | Layer/artifact | Independent owner |
| --- | --- | --- | --- | --- | --- |
| <ID> | <setup/entry> | <exact result> | <command/doubles> | <layer/pin> | <ID> |
One row per requirement; no “works correctly” rows.
Result vocabulary: PASS / FAIL / BLOCKED / NOT_OBSERVED / N/A(reason+authority).
Tests use exact commands, cwd, prerequisites, expected signals and output paths.

## Feedback ledger and exit condition
| Feedback ID | Required? | Disposition | Commit or TODO+reason+owner | Evidence IDs | Independent verdict | Blocks next step? |
| --- | --- | --- | --- | --- | --- | --- |
<Include every input finding and every newly discovered finding.>
My completion state: <role-specific status below>.
Next-stage owner: <agent/person>; unresolved mandatory rows block acceptance.

## Report via Paseo
Write <absolute report path>, then send <return-to ID> the fixed report envelope
below. Keep raw output in <evidence root>; do not commit large artifacts.
```

An exclusive role is a behavioral contract plus dispatcher verification, not just a title. A prompt cannot prove its own fresh context. The dispatcher records new-agent creation and role history. Dev, Test and Review must have distinct agent identities for the task; do not send a reviewer implementation work then reuse it as “independent.” Reuse a reviewer only to recheck its immediately previous review’s listed fixes and associated regressions; unrelated scope needs a fresh reviewer. Do not inherit the implementer’s conversation into a fresh review. The review can receive neutral specs, the diff and issue evidence; the implementer’s conclusions are claims to test.

### Dev module

```markdown
## Dev authority and exit
Implement only <IDs> on <branch/worktree based on exact commit>.
Allowed edits: <product/tests/docs/generators>; generated outputs come only from
<generator commands>. Single-writer owner: <ID, paths, release condition>.
Do not conduct the independent acceptance review or long-form playtest.
Do not merge, stop the shared game, or restart the next feedback round.

Evidence profile: <addon-runtime | server-only | docs/tooling>, assigned here.
For each behavioral fix, test the real changed production boundary; enumerate
all doubles and explain why none supplies the result that the test claims to prove.
For shipped addon changes: production-path regression + source native probe +
packaged native probe + package sha256 + invariant matrix + raw evidence manifest.
Test the exact submitted source; no later untested relevant edits.

Stage gates: implementation/tests and complete feedback disposition first;
then authorized packaging/probes; independent review/acceptance belongs to
<owner>. Packaging/probe ownership and commands: <explicit assignment>.
If a gate belongs to dispatcher, report awaiting that gate; do not claim PASS.

Exit: ready_for_review, blocked, or incomplete.
Report commit/PR and all requirement results, plus outstanding acceptance steps.
```

Dev may run engineering tests/probes without becoming the independent Test agent. A new “Dev” run is not permission to own the live play session. Where AGENTS reserves packaging/restart to the development dispatcher, the brief assigns those gates to that dispatcher. Diagnostic probes must identify their isolated resources and never replace/kill the current feedback session. Any uncertainty about permitted diagnostic builds is resolved in the dispatch, not by quietly bypassing the round gate.

### Test module

```markdown
## Test authority and setup
Play and report only. No product/harness edits, commits, PRs, packaging,
process restart/kill/quit, or delegation to a fixer.
Write only report/raw evidence under <absolute per-session tmp directory>.
Use only <absolute session-specific wrappers>; session=<ID>; required env=<...>.
Dispatcher has launched/verified <package sha, engine, fixture, preset hash,
birth talents, difficulty, execution flag>. Verify via <player-visible query>.

Before first scored action: write metrics v<n> to <path>, hash it, and send
that hash/path to <dispatcher>. Record UTC and first scored event boundary.
For each metric specify population, numerator, denominator, units, window,
expected categories, exclusions, missing/truncated-log handling and threshold.
Exploration/setup events are separately labeled and excluded by the frozen rule.

Stop conditions: death, completion, <time/action budget>, or <stall definition>.
On stall: preserve raw replies and notify dispatcher; do not repair/restart.
Save/quit/reload checks are dispatcher-owned: capture pre-state, notify, wait
for its lifecycle action, then capture post-state. Resume only after confirmed.

Exit: completed_observations or blocked (never product_accepted).
Report measured values, raw numerators/denominators, interventions, every anomaly,
and NOT_OBSERVED codes. No occurrence is not evidence a code works.
```

Remove branch/PR and committed VALIDATION deliverables from Test. The dispatcher converts its raw report into repository summaries. E5 should become a dispatcher round plan plus separate Test and Dev briefs; adding “only this role” above its existing mixed task would remain contradictory.

### Review module

```markdown
## Independent review authority
Fresh agent/context; exception only recheck=<prior review ID, finding IDs>.
Review <base SHA>..<candidate SHA>; artifact=<exact sha256>; known overlay=<none>.
No product/test/spec edits, commits, fixes, packaging, shared-session restarts.
Allow report/log writes only under <tmp path>; run checks with scratch/cache
outputs there. Commands requiring shared mutable resources are dispatcher-owned.

Review contract, actual call chain and test oracle before reading claimed PASSes.
Independently reproduce <critical requirement IDs> on the pinned source/artifact
using <commands/scenarios>; verify runtime load provenance and raw evidence hashes.
Identify mocks that bypass the changed boundary and uncovered invariants.
If native execution unavailable, report incomplete evidence, not accepted.

For each issue: ID, P0–P3, category, file:line+revision/symbol, triggering input,
expected/actual behavior, consequence, raw evidence, confidence, suggested direction.
P0=blocks release; P1=major correctness; P2=bounded defect; P3=minor factual issue.
No style-only findings. Separate defect, contract ambiguity and coverage gap.
Also report checked-correct scope, unreviewed scope, and uncertainty.

Exit: review_complete with recommendation accept/changes_required/incomplete.
This recommendation does not authorize merge. Recheck names prior findings,
fix commits, reproduced evidence and regressions; do not merely repeat Dev's summary.
```

### Investigation module

```markdown
## Investigation authority and exit
Answer <numbered questions>; propose <bounded scheme>; do not implement it.
Allowed writes: <tmp report and optionally specified docs-only file>.
Optional prototype: <explicitly authorized isolated tmp scope, or none>.
No product changes, live-session mutations, packaging, merging or policy adoption.

For each question: verified fact (file:line+revision or raw experiment), competing
hypothesis, uncertainty, and implication. Starting “facts” are claims to verify.
Compare feasible alternatives against explicit criteria; name one recommendation,
its assumptions, unsupported cases, verification plan and decisions still needed.
Read policy for proposed production reads: <exact currently authorized rule>.
An investigation may challenge that policy but must label the alternative a proposal.

Exit: proposal_complete or blocked. Separate proposed contract changes from facts.
Reply with report path/optional docs PR, conclusions, uncertainties and decision requests.
```

## Evidence contract and objective acceptance

**Require every Dev brief to answer every evidence category; do not require every task to run every category.** For packaged addon behavior, the proposed default is all five requested elements: a production-path test, both source and `.teaa` native probes, package SHA-256, explicit invariant checks, and raw-evidence hashes. Assign applicability before work:

| Change profile | Required proof | Legitimate N/A |
| --- | --- | --- |
| Addon/runtime/generation/packaging affecting shipped Lua | Actual production boundary, source + dist native probes, load provenance, relevant invariant regression, archive SHA, raw manifest, independent critical-path rerun | Only a dispatcher-authorized exception; missing engine is BLOCKED, not N/A |
| Python-only protocol/server behavior | Real server/transport path, representative bridge replies, schema/error/capability checks, relevant Lua integration if affected | Addon rebuild/native pair if no addon/package behavior changes, with explicit impact rationale |
| Docs-only or non-runtime tooling | References/contract/diff checks or actual tool path tests appropriate to change | Native probes and dist rebuild unless packaging/runtime claims are changed |

Existing task-specific full-suite requirements remain binding; this proposal does not retrospectively waive them. Test counts summarize scope but are never acceptance predicates. Pure-function fixture tests remain valuable; prohibit faking the result under proof, not all mocks.

Example objective row for the historical native-pending defect:

> R-PENDING: In an isolated fixture invoke the actual host executor and `Actions.execute` so an actual Tracker root suspends. Observe `native_pending` mapped to `waiting_native`; pump three times before releasing that root; native submission count remains exactly 1. Release it and observe settlement. Do not replace execute/host mapping with `{status='native_pending'}`. Record calls, root identity, states and fixture/build identity. Confirm this oracle fails on the defective baseline (or an isolated reintroduction of that branch ordering). Reviewer independently runs this scenario on the candidate package.

Baseline failure/mutation checks are appropriate for high-risk regressions like this; they need not become a blanket demand for every edit. A source unit test proves only its layer. A native process that still injects the outcome under test is also insufficient. Likewise a valid package hash proves bytes, not that those bytes loaded or behaved correctly.

The evidence manifest should contain: task/revision, requirement/scenario ID, producer agent, timestamp, exact cwd/command/config, source commit plus any overlay hash, engine and harness identity, mode (`source`/`dist`), package path/SHA and verified load origin, metric revision where relevant, exit status, observed signals, raw paths/sha256 and limitations. Probe summaries point to exact JSONL event/sequence ranges. Record a manifest SHA in the report. Keep raw data until acceptance/recheck is complete; a hash without retrievable data is not independently auditable.

Source and package runs need separate addon-load roots or equivalent proof that one cannot shadow the other. Record duplicate-addon checks/load origin. A build must map to the pinned source and dirty overlay; HEAD alone cannot identify uncommitted code. Changes to relevant code, config, harness, or archive invalidate affected results. Unrelated editorial changes need not trigger an indiscriminate rerun; record why results remain applicable.

An invariant row must name an observable: e.g. manual input revokes the lease; pending native work causes no second submission; execution default remains false; runtime handles are absent from saves; player-unknown fields are absent. Under the revised read policy, do **not** substitute “zero RNG calls/state changes” for “no committed actions/no unknown information.” Pure evaluator determinism can still be a separate scoped requirement; dynamic-read permission does not abolish all determinism requirements.

Example metric definition:

> M-PAUSE v1: count unique `(run generation, sequence)` paused/stopped events in scored UTC window [start,end), divide unexpected events by all paused/stopped events. Classify using the frozen expected set. Denominator zero => N/A, not 0%. Sequence gaps => incomplete, not pass. Retain operator-induced events with a separate tagged breakdown; exclude only if specified before the run. A new reason remains unexpected for v1 even if approved for v2.

For manual restart friction, explicitly decide whether initial start, retry, resume, and repeated no-op commands count. Define encounter boundaries and both wall-clock and active-play time treatment. E8's 24/25 discrepancy is evidence this matters. Keep exploratory observations separate from scored runs. Record post-hoc analyses as exploratory, never substitute them for the original result. A threshold is unnecessary for a purely descriptive metric; label it descriptive instead of claiming success without a predefined threshold.

## Completion and feedback gates

Use a ledger with stable IDs, including all imported feedback plus new findings. Proposed dispositions: `fixed_verified`, `deferred`, `not_a_defect`, `blocked`, `open`. Fixed requires commit + test/evidence + independent verdict before final acceptance. Deferred requires TODO locator, reason, owner, and next condition; rejection as not-a-defect requires evidence. The dispatcher decides whether a disposition permits the next stage.

This refines rather than replaces AGENTS: “all feedback handled” is **not** “every backlog item implemented.” Explicit documented deferrals are permitted. But merely creating a TODO cannot waive a mandatory acceptance row: that needs an authorized revised contract. Optional future work can be deferred without a new approval ceremony.

Proposed sequence:

1. Dev implements/tests assigned fixes and records every feedback disposition; commits submitted changes.
2. Dispatcher verifies ledger completeness, required implementation/unit evidence and TODO rationale. Only then authorizes the round’s rebuild and new-session transition, per AGENTS. Independent review can already assess source evidence before this point.
3. Named build/probe owner produces and verifies the candidate source/package evidence. Existing session lifecycle remains dispatcher-owned; no test agent restarts it.
4. Independent reviewer/tester supplies the required candidate verdicts. Unverified mandatory criteria remain blocking. Dispatcher separately authorizes acceptance/merge according to the actual workflow; none of the four agent templates grants merge.
5. Next round uses the accepted candidate identity; dispatcher archives the previous test conversation after preserving its report/evidence and starting the next test conversation as AGENTS prescribes.

For any intermediate PR, distinguish “this slice ready” from “feedback round closed.” A partial PR must not be presented as complete feedback closure. Unrelated new findings get a ledger entry rather than an unbounded repair. Do not require native packaged evidence before the very packaging gate needed to obtain it: implementation closure and final release acceptance are different stages.

## Fixed report-via-Paseo envelope

Use fixed common fields with role-specific results, not an ever-growing prose request. Suggested machine-readable shape (proposal only):

```yaml
schema: agent-result/v1
task: <id>
brief_revision: <n>
role: <Dev|Test|Review|Investigation>
agent_id: <id>
status: <role exit status>
report: <absolute path>
source_commit: <full sha or not_applicable>
source_overlay: <none or manifest sha>
artifact: {path: <path or null>, sha256: <sha or null>, reason: <if N/A>}
branch_pr: <branch + URL or not_applicable>
results: <requirement-ID -> verdict and evidence-ID, in report>
evidence_manifest: {path: <path>, sha256: <sha>}
feedback: <all IDs and dispositions, including unresolved, in report>
independent_verification: <agent + report + scope, or pending/not_applicable>
deviations_and_limits: <explicit, including unread/missing evidence>
next_owner_and_action: <who does what>
```

Role extensions: Dev changed behavior/tests/invariants; Test session/metric spec hash/raw counts/interventions; Review target diff/findings/coverage/recheck identity; Investigation answers/recommendation/uncertainties/decisions requested. Nullable fields require reasons. A concise Paseo message can link the complete envelope in the report; raw logs belong in the manifest, not the message. If delivery fails, retain the report and report the delivery failure; never claim it was sent.

## Change list and failure-mode coverage

| Current weakness / existing protection | Proposed wording or field | Concrete failure prevented |
| --- | --- | --- |
| Role heading only; E5 owns fixes and lifecycle | “Exactly one role; Test plays/reports; dispatcher owns launch/fix dispatch/restart”; identity/permissions record | Test-to-Dev drift and self-acceptance |
| Freshness stated but not auditable | Dispatcher records fresh agent ID/history; recheck binds previous review and findings | Same implementer masquerading as independent reviewer |
| Task-relative paths, mutable main | Absolute roots, full baseline, overlay, package and harness pins | Reading wrong brief tree or verifying wrong candidate |
| Work plan mixes old and binding decisions (E4) | Replace obsolete instruction in rendered brief; decision ID/revision/supersedes | Implementing the original option despite the maintainer ruling |
| Historical “facts” can be false (E10) | Label verified/reported/hypothesis; cite evidence and revision | Inheriting incorrect synchronous-execution assumption |
| Fake outcomes: later Wave 1 brief partially prevents this | Requirement row names actual entry, forbidden substitution, observable state, regression sensitivity | Green fake mapping/controller tests while real adapter fails |
| Done before backlog closure: AGENTS protects restart but briefs omit ledger | All IDs/dispositions, separate ready/review/accepted states, mandatory criteria cannot self-defer | Dropped findings or premature closure/merge |
| Frozen scope mostly explicit, choices sometimes open | In/out/allowed choices + contract amendment path; add adjacent findings to TODO | Implementing next phase or altering policy to satisfy a test |
| Purity policy drifts across AGENTS/history/spec (E2/E7/E9) | Inline exact authorized read rule and superseded assumptions; resolve AGENTS conflict | Rejecting audited dynamic getters solely for RNG; silently ignoring instructions |
| Expected categories declared, definitions incomplete (E8) | Hash and send metric spec before scored events; denominator/window/exclusions; prospective revisions only | Post-hoc expected categories or favorable rate denominators |
| Implementer reports source/dist pass + hash | Raw manifest, runtime load provenance, independent critical-path rerun | Accepting a summary, stale package, source-shadowed archive or tautological probe |
| Every Dev gets same expensive evidence recipe | Up-front applicability matrix; explicit N/A authority | Ritual native checks for docs-only work or silent skips for runtime changes |
| “Read-only/no file edits” conflicts with logs/report | Exact tmp-write exception and allowed scratch checks | Reviewer unable to report or accidentally mutating shared resources |
| Generic invariant checklist | ID/setup/expected observable/evidence/owner | “All invariants preserved” without inspecting the changed behavior |
| Single-writer sentence without allocation | Named owner, writable paths, prerequisite and release condition | Concurrent edits/builds invalidating each other's results |
| Test deliverable asks for PR/committed validation | Test writes tmp; dispatcher owns repo summary/PR | Role violation hidden in deliverables |
| Missing return address | Exact dispatcher ID and fixed result envelope | Finished work never reaches the coordinator |

## Token efficiency and references

Maintain the shared contract and four role modules once as template sources; **expand the selected core and module into each dispatch**. This avoids authoring duplication without requiring the recipient to inherit a prior conversation. Aim for a short first screen containing role, outcome, scope, pins and binding rules; spend remaining tokens on the task-specific evidence table. Omit empty “what was tried” sections, unrelated product history and exhaustive module inventories.

Self-contained does not mean copying the entire spec. Inline rules whose omission could cause irreversible or wrong work: role permissions, out-of-scope/defaults, binding D-rulings, read boundary, completion gates, metric freeze and return route. Reference detailed algorithms/background via absolute path + pinned commit/hash + section + why to read it. Required references must be available at dispatch. For uncommitted docs, pin a file hash; do not pretend a version label pins file content.

Preflight can report “read §8.3, applying rule X; baseline/permissions verified.” Do not require summaries of every document: that wastes tokens and does not prove comprehension. Acceptance rows should depend on the cited rules so a skipped reference becomes observable. Retain evidence/history links without treating historical acceptance or abandoned approaches as normative. Any late `paseo send` changing scope/policy must identify the revised brief and superseded clauses; minor informational updates need no contract rewrite.

## Dispatcher pre-send checklist

- [ ] One role; distinct Dev/Test/Review identities; fresh review or narrowly identified prior-round recheck.
- [ ] Exact return-to agent ID, absolute repo/support/report paths, references accessible.
- [ ] Full baseline and dirty-overlay status; correct package/hash and intended load mode; no hidden “repackage current main” drift.
- [ ] AGENTS/spec/brief consistent; binding decisions resolved inline; missing independence section and read-policy conflict addressed before adoption.
- [ ] Required IDs, out-of-scope items, defaults, permitted decisions and exact write/process permissions are explicit.
- [ ] Named single writer/dependencies; probe/game lifecycle ownership; no Test fix/PR/restart requirement.
- [ ] Every acceptance row has input, observable outcome, evidence layer/command and independent owner; no fake outcome under proof.
- [ ] Evidence applicability assigned; source/dist provenance and raw retrieval/hash plan where required.
- [ ] Metric spec freezes before scored events; denominator, stop conditions and uncertainty handling defined.
- [ ] Feedback ledger covers all supplied findings; deferred mandatory criteria cannot silently pass; exit state and next-stage owner named.

## Disagreements with the current proposal

“Role & independence” alone cannot enforce independence; agent selection and permissions must match the text. The current Test skeleton is actually a coordinator workflow and should be split. Mandatory native source+dist probes are appropriate for shipped addon behavior, not every possible Dev task. A SHA is an identity check, not an independent behavioral oracle. “All feedback handled” permits explicit deferrals under AGENTS, but not self-waiver of required acceptance. Finally, do not copy generic “purity/read-only” language into all future briefs: the intended read policy changed, and the local instruction conflict must be resolved explicitly rather than left for recipients to guess.
