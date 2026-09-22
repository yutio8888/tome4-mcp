# S3 Supplemental Test Report — actual Vault request capture (session s3-supplement-01)

- Role: **[Test]** (fresh independent identity; not Dev, not Review, not the archived original Test).
- Actual model/provider/thinking: `pi` provider `commandcode`, model `deepseek/deepseek-v4.1-flash`, `PI_REASONING_LEVEL=high` (explicit AGENTS "high" honored; profile "max" not used). This round = Test model **A**; prior Test in sequence was B (`opencode-go/glm-5.3-flash`); next Test = B.
- My Paseo/session id: `01a0c8dc-5829-724c-9816-c7698ee0dfce` (PI_SESSION_ID).
- Dispatcher / exact return-to: Paseo agent `f7a2979c-7b83-4a32-855f-d698ef2daf0a`.
- Start UTC (first wrapper call): **2026-09-22T11:25:25Z** (raw/001). End UTC (last wrapper call): **2026-09-22T11:29:40Z** (raw/021/022). Report composed 11:30Z.
- Exit state: **completed_observations** — both required IDs dispositioned; no product/game/fixture/server/driver/observer edits; no git mutation; no process management; no native restart/kill/quit; no private Lua console; no delegation. I do **not** claim product acceptance or merge.
- Scope note: this is **supplemental evidence for S3 only** (the two frozen rows S3-SUP-COMPACT, S3-SUP-VAULT). It is **not** S4, not campaign acceptance, and it does **not** rewrite the original S3-LIVE v1 six-row results (original Vault remains historically NOT_OBSERVED).

## Pins verified before first call (all matched exactly)
| Artifact | Path | SHA256 | Status |
|---|---|---|---|
| AGENTS.md | `…/tome-mcp-bridge/AGENTS.md` | `b73d8440667b544f0220b860d5f9641aa28fe9fe4f3837d6232cd6e8e89e15d0` | ✓ |
| Brief contract | `…/docs/tome-mcp-agent-brief-contract.md` | `42de33642183f311e10897b46cf0a7bb3d85dab66e1bfa67cf47870a0b5a7d19` | ✓ |
| Harness doc | `…/dev-root/…/docs/tome-mcp-0.9.0-s3-evidence-harness.md` | `45d83fd9417902fd87891eb7063e0e12f13498aa88188bb3d63427f512db3976` | ✓ |
| Frozen metrics | `…/supplement/metrics.json` | `35f27585d61f2866e2815e99cf39f4ef3e752bdd049976aac9686f51f574fc98` | ✓ |
| Product archive | `…/supplement/candidate.teaa` | `3a4e186b001971bdebfa9315a33dcac3ddd06c9abd7a1698c9af6caf03f413fb` | ✓ |
| pin.json | `…/supplement/pin.json` | `44f37db477a826d5b88efcc894e18974d7ab7004af6d2f7fe29a3ffe9375f447` | ✓ |
| runtime-pin.json | `…/supplement/runtime-pin.json` | `82d9589d38aec5fe611b4966d425ee274780496aab0845d527e58b77c90d589b` | ✓ |
| wrapper `tome-s3.sh` | `…/supplement/tome-s3.sh` | `1c3b28fe28311c076da1b1fbb6e38bf6138f1b10ac33e88de5204214707d5da3` | ✓ |
| driver `agent-play.py` | `…/supplement/agent-play.py` | `4ef747911ae9c1bb1ba43a95a5bd01da3ff6974b7625b5f6cc98cb7be0fcd3ec` | ✓ (pinned in pin.json/runtime-pin.json) |
| trace reader `trace-s3.py` | `…/supplement/trace-s3.py` | `ca760b33cabc2eb498ab00ab057b0a7184fee9e28678f04e7a63452da6e17963` | ✓ |
| Session game.log | `…/sessions/s3-supplement-01/game.log` | `e68e9207054b5112007fa0dd948a7c684fc4c2ee5437be93496a277cd6a727ca` | snapshot at report time |
| Session transcript | `…/sessions/s3-supplement-01/play-mcp.jsonl` | `4db2fd25791b7070596a964357fc9419b2d8277fd86a47bcbc124a60e2d88f77` (30 lines) | snapshot at report time |

Driver startup already had 1 `tome.connect` + 1 `tome.observe` transcript entry (lines 1–2) before my first call — these are the coordinator's startup entries, distinguished from my calls. My first wrapper call `raw/001` is transcript line 3; subsequent driver-internal reads (`map`, pre-action `observe`, `status`, `policy_log`) sit on later lines. Verified loaded mode = archived product only (`mcp-bridge` + `mcp-play-birth-s3` + `mcp-s3-observer`), no `MCPProbe` (driver removes `tome-mcp-probe` and sets `set_addons` explicitly, lines 155–156), observer installation record present at `game.log` line 399 and trace event 1.

## Budget / accounting
- **Wrapper calls: 22** (`raw/001`…`raw/022`), all `ok:true`, no stderr, no timeout, no schema failure. Cap was 100 game wrapper calls; elapsed ≈ 4 min 15 s (under 5-min-progress and 20-min bounds).
- **Scored Vault runs: 1** (`run_id=1`, `native_submissions=1`, `effective_actions=1`, `run_actions=1`, `attempts=1`, `instant_actions=0`; stopped `max_consecutive_actions`). No retry, no resubmission, no opportunity-paused attempt, no failed first attempt to substitute.
- **Native setup actions (separately counted, never scored): 3** — `move` dir 6 (world_tick 0→10), `move` dir 6 (10→21), `equip` shield (21→32). No native `wait`/`rest` was needed: the two setup moves themselves advanced the action opportunity to a fresh one before the scored start. Setup leaves player energy 1000 and a fresh opportunity (run `opportunity=1`).
- Read/setup call breakdown (all 22 wrapper calls accounted for): 4 compact `observe` (`raw/001,016,019,022`), 1 `map` (`raw/002`), 1 `inspect talent` (`raw/003`), 2 `inspect character` (`raw/004,008`), 1 `inspect actor` (`raw/010`), 2 `auto:status` (`raw/009,021`), 5 policy chain (`validate/set_draft/approve/activate` docs `raw/011,013,014,015` + `dry_run` `raw/012`), 1 `auto:start` (`raw/017`), and the 3 native setup actions (`raw/005,006,007`). No action was submitted by any read; `dry_run` reports `side_effects:"none"`.

## S3-SUP-COMPACT — PASS
Entry: wrapper `{"observe":true}` (compact), compared against the **actual raw `tome.observe` public payload** in this session's own `play-mcp.jsonl`.

- Initial read (pre-setup, pre-policy): wrapper `raw/001-observe-initial.json` ↔ transcript line 3. Compact `auto_combat` = `{"actions":0,"active":false,"enabled":true,"last_decisions":[],"state":"stopped"}`. Raw `auto_combat` = `{"actions":0,"active":false,"enabled":true,"generation":null,"last_decisions":[],"last_native_abort":null,"paused_reason":null,"policy_hash":null,"policy_id":null,"state":"stopped"}`.
- Post-policy/pre-start read: `raw/016-vault-prestart-observe.json` ↔ line 22 (active true, policy_id/hash present; nulls pruned).
- Post-scored read: `raw/019-vault-observe-post.json` ↔ line 26 (actions 1, generation 2, last_decisions 1-element).
- Final read: `raw/022-final-observe.json` ↔ line 30.
- Equal to raw after applying the driver's existing `_prune` (drop `None` recursively; empty dict → dropped; lists elementwise; scalars unchanged) for **all four** reads. `auto_combat` key **present** in the wrapper for all four (no invented defaults, no missing key).
- Retention checks where the raw value is actually the sentinel: `active:false` retained (line 3); `actions:0` retained (lines 3, 22); `last_decisions:[]` retained (lines 3, 22); nulls (`generation`, `last_native_abort`, `paused_reason`, and `policy_hash` at line 3) pruned out with **no null stub**, matching `_prune`. `enabled:true` is the real value in this fixture (so an `enabled:false` retention case did not occur to sample — not asserted as if it had).
- No compact key ever appeared that was absent from the raw object (`compact_minus_raw_invented_keys = []` for all four).
- Machine-check artifact: `raw/compact-compare.json` (script `scripts/compare-compact.py`), **anomalies: []**. Raw payloads saved verbatim: `raw/transcript-raw-observe-line003.json`, `…line022.json`, `…line026.json`, `…line030.json`.
- Verdict: **PASS** — compact `observe` forwards actual `auto_combat` and matches the actual public raw values (false/0/empty retained, preexisting `None` pruning only).

## S3-SUP-VAULT — PASS
Entry: real `set_draft`→`approve`→`activate`→`start` of policy `s3-sup-vault-01` (hash `4a8da58bc3bd74ab3dc689affe788ebe`), cap1, `T_VAULT` (agility Vault, **not** acrobatics `T_SKIRMISHER_VAULT`), with equipped shield, adjacent known actor and distinct known free landing grid.

Preconditions immediately before the scored start (`raw/016`): player `(7,5)`, dummy `(8,5)` distance **1** (adjacent, visible), shield `S3 training shield` equipped in equipment list (`raw/008`), T_VAULT cooldown **0**, stamina **300** (≥ current cost), energy 1000, fresh opportunity, dialogs `[]`, pending none. Destination grid `(7,4)` is visible/passable and distinct from both the actor `(8,5)` and the current player grid `(7,5)`.

Read-only `dry_run` (`raw/012`, `side_effects:"none"`): decision `act`, bound target ends `actor-15424` (the dummy), `target_distance 1`, annotation `requests ["actor","grid"]`, `sequence ["actor","grid"]`, landing `{kind:bounded, center (7,4), radius 1, min_radius 0}`, reasons include `ordered_prompt_sequence`, `native_random_landing`.

### Actual native request/answer trace (filtered passive observer)
`trace-s3.py` on the fixed session `game.log`; saved `raw/trace-post-vault.json` (`log_bytes 161710`, `log_sha256_at_read 716a610e…`, `parse_errors: []`). Locators are the native `game.log` line numbers:

| Line | Record | Content |
|---|---|---|
| 399 | installation | `{"installed":true,"kind":"installation","observer":"tome-s3-observer/v1"}` |
| **2750** | invocation_start | `invocation 1`, `talent T_VAULT`, actor `{uid 2394, x 7, y 5}`, `getter_present true`, `raw_field_present true` |
| **2751** | request 1 | `typ {present:true, type:"hit", range:1, nolock_present:false}` (nolock **absent**) |
| **2752** | answer 1 | `{arity:3, x:8, y:5, x_class:"number", y_class:"number", has_actor:true, uid:15424}` |
| **2753** | request 2 | `typ {present:true, type:"hit", range:3, nolock_present:true, nolock:true}` |
| **2754** | answer 2 | `{arity:3, x:7, y:4, x_class:"number", y_class:"number", has_actor:false, actor_class:"nil"}` |
| **2766** | invocation_finish | `{ok:true, requests:2, lifetime_requests:2, truncated:false, emit_failures:false}` |

Machine-check artifact: `raw/vault-correlate.json` (script `scripts/correlate-vault.py`). All of the following are **true**:
- `invocation_start_count 1`, `request_count 2`, `answer_count 2`, `invocation_finish_count 1`; requests and answers ordered `[1,2]`; `exactly_two_requests true`.
- request1 nolock absent (`nolock_present:false`, no `nolock` key); request2 `nolock_present:true` **and** `nolock:true`; ranges 1 then 3 (matches the two real `T_VAULT` target specs `{type="hit",range=1}` actor and `{type="hit",nolock=true,range=…}` landing).
- answer1 `(8,5)` + uid `15424` = the bound actor/dummy **public identity**; answer2 `(7,4)` = the selected declared grid, **distinct** from answer1 and with no actor (`has_actor:false`). `answers_differ true`.
- finish `ok:true` (no exception only), `requests 2`, `lifetime_requests 2` (single invocation), `truncated false`, `emit_failures false`, `parse_errors []` — no truncation/emission/parse error.
- No second invocation anywhere in the final trace (`raw/trace-final.json`: 7 events = installation + exactly 6 Vault records). So no unexpected_target_request / no resubmission at the trace layer.

### Public result / native effect evidence
- `auto:status` (`raw/018` → `raw/021` unchanged): run `native_submissions 1`, `effective_actions 1`, `run_actions 1`, `attempts 1`, `instant_actions 0`, `max_native_submissions 32`, stop reason `max_consecutive_actions`, log **1 event** (`seq 1`, `kind stopped`, `rejections {}`), stamina before/after `300 → 284.1` (native debit **15.9**, matching the dry-run `current_costs.stamina 15.9`). No rejection, no `unexpected_target_request`, no resubmission.
- Landing/effect: player `(7,5)` → **`(7,4)`** = the declared grid, inside the bounded envelope radius 1 centered `(7,4)`, distinct from the actor and from the start grid (`raw/019`, `raw/022`). Dummy life `10000 → 9982.883436931501` (damage **17.1166**), and dummy effects now include **`EFF_DAZED`** (plus `EFF_OFFBALANCE`) (`raw/020`; pre-state `raw/010` had no effects). Player-visible log entries (tick 43): `uses Vault.`, `S3 training dummy is dazed!`, `MCP_s3-supplement-01 hits S3 training dummy for 17 physical damage.` (`raw/019`, cursors 10–12). Vault cooldown set to 9/10 afterward. No dialogs, no pending command.
- Public MCP transcript start record at line 23: `tome.policy {policy_op:"start"}`; response `{generation:1, run:{state:"running"}, state:"running"}`.
- Verdict: **PASS** — exactly 2 ordered actual native target requests/answers in one invocation; second actual `typ` has `nolock_present=true`/`nolock=true`; actual answers distinct and matching actor (uid 15424 / (8,5)) then selected grid ((7,4)); one settled/effective/run action; native damage+daze; envelope-valid landing; no unexpected_target_request/resubmission/trace error.

## Findings / anomalies
- **No new S3 supplement finding.** Both rows PASS with zero anomalies; `compact-compare.json` and `vault-correlate.json` both report `[]`/`empty`.
- Verified repairs in live parity: **S3-LIVE-ISSUE-1** (compact console dropped `auto_combat`) is confirmed repaired live — `auto_combat` present and equal in all four compact reads. **S3-LIVE-ISSUE-3**: per the brief, `policy.op=log` is a valid public enum; I did **not** need it (used `auto:status`, which internally reads `policy_log`) and introduce no new mismatch.
- Note (not a product finding; test-layer observation): the pre-existing coordinator startup transcript lines 1–2 are present before my first call; they are ordinary `connect`/`observe` reads, not scored events.
- Note (not a defect): one compact-read sub-case (`enabled:false` retention) simply did not occur because the fixture has `enabled:true`; I did not fabricate it. The false/0/empty retention requirement is nonetheless directly demonstrated with `active:false`, `actions:0`, and `last_decisions:[]`.

## NOT_OBSERVED / limitations
- Nothing required for either row is NOT_OBSERVED. Both rows are fully established from actual public responses + the disclosed passive observer.
- The observer is disclosed test instrumentation that wraps the *current* `getTarget` at action time; per AGENTS.md it makes no runtime identity/digest/closure claim, and it does not itself prove the wrapped function is unmodified. The binding requirement here is actual request count/values, which is what was captured.
- `T_VAULT`'s landing is natively random within the bounded radius-1 envelope; one branch (landing on the requested grid) occurred and was all that was required. The exact landing within the envelope is not deterministic and was not assumed.
- The trace reader output is supplemental test telemetry, not shipped public protocol. I did not read general game.log for tactics or use any private console.
- I did not re-run the six original S3-LIVE rows; their historical results are untouched.

## Final state
- Character `MCP_s3-supplement-01` at `(7,4)`, life 104/104, stamina 284.4, energy 1000, alive; dummy `(8,5)` life 9982.88, dazed/off-balance, inert.
- Policy `s3-sup-vault-01` (`4a8da58bc3bd74ab3dc689affe788ebe`): approved + activated (active:true), run completed and stopped `max_consecutive_actions`, `control_owner manual`, log total 1 event. No further game commands were sent after the last evidence read; no state was saved/reloaded/killed.

## Counts and evidence index
- Wrapper calls: **22**; scored Vault runs: **1**; setup native actions: **3** (2 move + 1 equip); retries: **0**; failed calls: **0**; native errors/timeouts/aborts: **0**; unexpected_target_request/resubmission: **0**; trace parse errors: **0**.
- Raw replies: `raw/001`…`raw/022` (+ `raw/trace-before.json`, `trace-pre-vault.json`, `trace-post-vault.json`, `trace-final.json`, `raw/transcript-raw-observe-line*.json`, `raw/compact-compare.json`, `raw/vault-correlate.json`).
- Per-file SHA256 and sizes: `evidence-manifest.json`. Analysis scripts: `scripts/call.sh`, `scripts/compare-compact.py`, `scripts/correlate-vault.py`, `scripts/vault-policy.json`, `scripts/cmd-*.json`. Per-call UTC and request: `call-log.tsv`.
- Session transcript (permissible evidence): `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/s3-supplement-01/play-mcp.jsonl`, 30 lines, sha256 `4db2fd25791b7070596a964357fc9419b2d8277fd86a47bcbc124a60e2d88f77`.
- Trace reader `log_sha256_at_read`: before `f291508c…`; post-vault `716a610e4689cd65…`; final trace `raw/trace-final.json`.

## Metric reconciliation (frozen metrics.json)
- Denominator **2**; numerator **2** (S3-SUP-COMPACT PASS, S3-SUP-VAULT PASS) → **2/2**. Missing: none. First-attempt preserved (single scored start, no retry/substitution). Window: first wrapper call 11:25:25Z → report. Stop conditions: not triggered.

## Exit
- Exit state: **completed_observations**. Next owner: coordinator `f7a2979c-7b83-4a32-855f-d698ef2daf0a` (reap session, archive Test identity/workspace after retaining raw evidence), then the original independent Sol reviewer rechecks its own REV-S3-01 with these supplemental artifacts. S4 is out of scope and not adjudicated here. No claim of product acceptance/merge.
