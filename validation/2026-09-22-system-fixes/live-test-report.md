# [Test] SYSFIX final live acceptance — report

schema: agent-result/v1
task: SYSFIX-Test-01
brief: SYSFIX-Test-01 v1 (test-final-brief.md sha256 f0e5991f72f4f63ab0430646db8f621c0ad0f9ceccf25ea84a33e89dced5e594)
role: Test (fresh independent; no implementation/review authority)
agent_id: exact UUID recorded by coordinator in test-dispatch.json (created after briefing)
status: testing_complete
report: /workspace/t-engine4/tmp/mcp-system-fixes-20260922/test/report.md
report_sha256: recorded post-write in /workspace/t-engine4/tmp/mcp-system-fixes-20260922/test/report.sha256 (self-hash cannot be embedded without changing the hashed bytes)
return_to: f7a2979c-7b83-4a32-855f-d698ef2daf0a

## Model and method
- Actual Test model: `pi` / `commandcode/deepseek/deepseek-v4.1-flash`, thinking high (Test A/B: this round A; previous round B = opencode-go/glm-5.3-flash).
- Live only through `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/send-sysfix-live-01.sh` (one call at a time). No repo/game/harness edits, no process start/kill/quit, no git.
- Metrics frozen BEFORE the first wrapper call: `test/metrics.json` sha256 `248dd7fcaf1d8d2c71bcebf49f1cc67db5e0083e8a17ab83df1df5430348c444` (frozen 2026-09-22T07:20:30Z). First command ran after this; metrics unchanged since.
- Raw per-call JSON: `test/raw/*.json` (list + hashes in `test/raw/manifest.sha256`); auto tool transcript `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/sysfix-live-01/play-mcp.jsonl` sha256 `b9a00b3ac54da0395040dbcab6c4e596a2c98624275259aca86de0e76bd208ef`; driver decisions `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/sysfix-live-01/decisions.jsonl` sha256 `ecc609292a7190e6924b07bcaf8b2956c3a09d519e28b65a2463005bf054107e`; console log `/workspace/t-engine4/tmp/mcp-play-support/sysfix-live-01.log` sha256 `4e0713584ff7c6a469212fa54908c4846f1a0cc956909ca49534cd8bb3a3412a`.
- Wrapper calls used: 29 (cap 80). Policy-controlled wait actions: 4/4 (cap1=1, cap3=3). Explicit manual wait: 1 (deviation, see below). Wall time first→last command ≈ 07:20:30Z→07:24:20Z (< 15 min).

## Pins
| Item | Value |
|---|---|
| source commit | 084642634b1d92dfb5e2880f43998672469798ab (detached, dirty overlay NONE; git status clean) |
| artifact | artifacts/candidate-3a4e186b0019.teaa sha256 3a4e186b001971bdebfa9315a33dcac3ddd06c9abd7a1698c9af6caf03f413fb |
| loaded in session env | TOME_MCP_TEST_ARCHIVE_SHA256 3a4e186b0019…13fb (test-launch.json; session sysfix-live-01) |
| driver | agent-sysfix-play.py sha256 86d53f1966477cbc6d789580a8d3f66e6319d7bbeb4263bb6be0737b507f6c00 |
| wrapper | send-sysfix-live-01.sh sha256 75682b5669b4a8794246e4327931bea65fb77a9c6440814baf2afc2dceb27f3c |
| server.py | server/src/tome_mcp/server.py sha256 36f251558046efa171eb1e63a6796a04c21e76fd07c5ba170502591ace91dec9 |
| policies input | test-policies.json sha256 f8797c4dbc011e3bd2d058bdd7d003142f1e2f93a238a3dab66b34667ca226a7 (values imported unchanged) |
| required docs | AGENTS b73d8440…; agent-brief-contract 42de3364…; decisions d6fbaf02…; todo c892724e… (all verified) |
| session | sysfix-live-01, Halfling/Celestial-Anorithil/Insane/Roguelike, cheat=false, mcp-play-birth-hai2 disclosed birth fixture |

## Metrics (frozen)
approved wrapper calls budget {max80, used29}; policy wait budget {max4, used4}; explicit wait budget {max1, allowed only to unblock a fresh run, used1 — DEVIATION}; rows expected 4.

## Row results — exactly 4/4 observed

| ID | Verdict | Numerator/Denominator |
|---|---|---|
| LIVE-01 | PASS | 1/1 |
| LIVE-03 | PASS | 1/1 |
| LIVE-PRIVATE | PASS | 1/1 |
| LIVE-CLEAR | PASS | 1/1 |

### LIVE-01 — cap1 stops at exactly one native wait, retains reason/counters, releases control
Evidence: `raw/12-activate-cap1.json`, `raw/13-auto-start-cap1.json`, `raw/14-auto-status-cap1-a.json`, `raw/15-observe-cap1-{a,b,c}.json`.
- start cap1 (hash 81f84e480eafc4baa6b5eb7287092eb0): `{generation:1, state:"running", action:"schedule_pump"}`.
- run summary: `run_id=1, run_actions=1, actions=1, attempts=1, effective_actions=1, instant_actions=0, native_submissions=1, opportunity=1, max_consecutive_actions=1, state="stopped", reason="max_consecutive_actions", generation=2, policy_hash=81f84e48…`.
- one policy wait account: `last_decisions[0] = {kind:"stopped", reason:"max_consecutive_actions", rule:"bounded-wait", run_actions:1, effective_actions:1, native_submissions:1, generation:2}`.
- 3 repeat observations stable: revision 377, world_tick 10, energy 1000, control_lease `held`/control `remote`, `auto_combat.actions=1`, no extra submission and no counter loss.
- release: post-stop policy `status.control_owner="manual"` (auto-combat arbiter back to manual); runtime MCP control token remains held/remote (unchanged throughout).
Verdict: PASS — exactly 1 settled native wait, run_actions=1, stopped reason `max_consecutive_actions`, arbiter lease released, 3-read stability.

### LIVE-03 — cap3 stops at exactly three native waits, retains reason/counters, releases control
Evidence: `raw/18-set-draft-cap3.json`, `raw/19-approve-cap3.json`, `raw/20-activate-cap3.json`, `raw/21-auto-start-cap3.json`, `raw/22-auto-status-cap3-a.json`, `raw/23-status-cap3-stable-{a,b,c}.json`, `raw/24-observe-after-cap3.json`.
- start cap3 (hash c39a6b20ba46379387ad6322a7dd4638): `{generation:1, state:"running"}`.
- run summary: `run_id=2, run_actions=3, actions=3, attempts=1, effective_actions=1, instant_actions=0, native_submissions=1, opportunity=4, max_consecutive_actions=3, state="stopped", reason="max_consecutive_actions", generation=2`.
- decision trace: `acted@run_actions=1`, `acted@run_actions=2` (native_result "ok"), then `stopped@run_actions=3 reason=max_consecutive_actions`; log.total=4 (includes cap1 boundary).
- exactly 3 settled waits in the new run (opportunity=4, so one prior opportunity); no extra submissions.
- 3 stability reads identical: `run_id=2, run_actions=3, native_submissions=1, effective_actions=1, opportunity=4, reason=max_consecutive_actions, state=stopped, generation=2`; post-stop `control_owner="manual"`.
Verdict: PASS — exactly 3 native waits, run_actions=3, same stop reason/release, 3-read stable.

### LIVE-PRIVATE — public private-field rejection does not dispatch
Evidence: `raw/03-private-action.json` (negative), `raw/01-baseline-observe.json` vs `raw/04-after-private-observe.json`.
- request: `{"action":{"type":"wait","force_actor":true},"reason":"public boundary negative, must not dispatch"}`.
- verbatim MCP error: `invalid_argument` — `Error executing tool tome.act: 1 validation error for actArguments / action.wait.force_actor / Extra inputs are not permitted [type=extra_forbidden, input_value=True, input_type=bool] / https://errors.pydantic.dev/2.13/v/extra_forbidden`.
- before→after (idle): revision 365→365, world_tick 0→0, history `last_accepted_seq 0`, `next_command_id` still `cmd-1`, `retained_count 0`, energy 1000→1000, position unchanged. No game action/ledger/revision/world-tick change.
- Note: the driver locally logged the attempted command in decisions.jsonl (its own bookkeeping); game history remained unchanged. Rejection occurred at server tool-schema validation, before native dispatch (not a raw-TCP bypass).
Verdict: PASS.

### LIVE-CLEAR — clear removes only draft, preserves approved, no action
Evidence: `raw/05-set-draft-cap1.json`, `raw/06-approve-cap1.json`, `raw/07-set-draft-cap3-copy.json`, `raw/08-status-before-clear.json`, `raw/09-clear.json`, `raw/10-status-after-clear.json`, `raw/11-get-after-clear.json`.
- before: approved_hash `81f84e480eafc4baa6b5eb7287092eb0` (id sysfix-live-cap-1) AND draft_hash `c39a6b20ba46379387ad6322a7dd4638` (id sysfix-live-cap-3).
- clear returned `{cleared:"draft", approved_hash:"81f84e480eafc4baa6b5eb7287092eb0"}`.
- after status: approved_hash/id unchanged; `draft_hash`/`draft_id` absent. `policy.get` returns only `hashes.approved=81f84e48…`, no draft; `approved` object is byte-equivalent (canonical JSON) to test-policies.json["1"].
- no native game action (policy op only; revision updates are policy-store revisions, not game actions).
Verdict: PASS.

## Deviations and uncertainty (explicit)
1. **Manual wait deviation (report in full).** After the cap3 run had already stopped at its cap, I issued exactly one explicit manual wait: `{"action":{"type":"wait"},"reason":"manual explicit wait post-cap3 to confirm released control (budget 1/1)"}` → `raw/25-manual-wait-post-cap3.json` (`status:"completed"`, `native_return:true`, `energy_spent:1000`, `input_owner:"remote"`, `execution_released:true`, world_tick 40→50, revision 410→423). Brief allowed at most one explicit manual wait **only to advance a fresh run blocked by a fully spent opportunity**; my use was post-stop control-availability confirmation, not required to unblock a new run. It is disclosed as a deviation, is **not** counted toward any policy-run oracle, and metrics were not broadened. It did not alter any cap1/cap3 counter, the private-negative comparison, or the clear row.
2. **LIVE-01 lease wording.** The auto-combat arbiter released to `control_owner="manual"` (expected), but the runtime MCP `control_lease` stayed `held`/`control:"remote"` throughout; I did not deactivate the approved policy to force a release. "Released lease" is read as the auto-combat arbiter owner returning to manual.
3. **`policy_log` driver key unsupported.** `{"policy_log":64}` returned driver `unknown_command_key` (`raw/16-policy-log-cap1.json`); the auto-decision trace was instead obtained inside `auto.status` (`log.events`), which is the same evidence layer. Driver interface only; not a product finding.
4. `control_owner` while a run was actively running was not sampled (only pre-run and post-stop); post-stop `manual` is the asserted end state.
5. No death/not-ready blockers occurred; session stayed phase `ready`, life 94/94 throughout.

## Out of scope / not claimed
Low-HP/emergency, rest/save/reload, source-vs-dist probes, policy migration, defaults, implementation, long-form play, repackaging; SYS02/SYS05-07/SYS08/SYS09/U-01 and other deferred items are NOT covered. No claim about execution defaults or package completeness from this live subset.

## Feedback ledger disposition (this brief)
SYS01/03 live cap subset: covered (LIVE-01/03 PASS). SYS04 remote clear subset: covered (LIVE-CLEAR PASS). RUNTIME-REV01 public private-key complement: covered (LIVE-PRIVATE PASS). SYS02 controlled native/offline, SYS05/06/07 evidence review, SYS08/SYS09/U-01 deferred — owned elsewhere per pinned todo.

## NEXT_OWNER
coordinator: reap session immediately on report; independent Review adjudicates.
