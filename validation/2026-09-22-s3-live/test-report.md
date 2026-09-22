# S3-LIVE-20260922 Test Report — session s3-live-02

- Role: [Test] (fresh identity), model B `pi` / `opencode-go/glm-5.3-flash`, thinking `high` (PI_REASONING_LEVEL=high; explicit AGENTS high honored). Previous Test in sequence was A (deepseek-v4.1-flash) per brief.
- Start UTC: 2026-09-22T10:01:13Z (first wrapper request 10:01:35Z, raw/001). End UTC: 2026-09-22T10:16Z.
- Dispatcher/return-to: Paseo agent f7a2979c-7b83-4a32-855f-d698ef2daf0a. My session id: 01a0c88f-e9ab-7d91-9012-8f3e39d14df7.
- Exit state: **completed_observations** (never accepted/merged; no product or lifecycle changes made).

## Pins (verified before first call)
- Brief S3-LIVE-20260922 v1, issued 2026-09-22T09:59:54Z. AGENTS.md sha256 b73d8440…89e15d0 ✓ (matched before read).
- Repo branch validation/s3-live-20260922, HEAD fdd741c1c47aa65be7ecc329a06a52a8d647482f ✓ (git log). Product baseline 8e3c21978a5040ac9ba97cd2175ee36901b91819 ✓. Dirty overlay: only preexisting untracked `docs/tome-mcp-token-usage-analysis.md` ✓ (git status).
- Wrapper `/workspace/t-engine4/tmp/mcp-s3-live-20260922/tome-s3.sh` sha256 87447b39…fbf26b ✓. Driver agent-play.py sha256 1f8034f2…a74e3 ✓. candidate.teaa sha256 3a4e186b…f413fb ✓. runtime-pin.json sha256 ba7f484e…4c2083e ✓; session s3-live-02 birth_verified ✓.
- Loaded mode archive-only; no MCPProbe/AutoCombatProbe driver; no source addon shadow observed.
- Documents read (hashes as pinned in brief): agent-brief-contract.md (Test module + shared core), roadmap.md (S3-only scope), auto-combat-plugin-design.md §4.1/§5.4/§8.3, system-fixes-2026-09-22-decisions.md (POLICY-01@1.1, POLICY-03@1, SETTLEMENT-01@1; EXEC-01/02 noted historical). Historical VALIDATION.md not treated as normative.

## Budget accounting (BUDGET@1 / POLICY-01@1.1)
- Wrapper calls total: **66** (65 saved raw files in `raw/` + 1 identical observe whose output was lost to a local parse error on my side and immediately re-issued as raw/010; that lost call is counted here). Well under the 220 cap; ~15 min elapsed, no stall.
- Native submissions by auto-combat runs (from `auto status`, each visible in raw):
  - run1 SHADOW: native_submissions=1, effective_actions=1, run_actions=1, instant 0 → stopped(max_consecutive_actions).
  - run2 LEAP: native_submissions=1, effective_actions=1, run_actions=1, instant_actions=1 → stopped(max_consecutive_actions).
  - run3 VAULT-no-shield attempt A: native_submissions=1, effective_actions=1, run_actions=0, instant_actions=1 → **paused(budget_exhausted)** — pre-budget opportunity (opportunity 2, already consumed by instant Giant Leap). Retained; NOT counted as proof of native shield refusal (per coordinator informational reminder).
  - run4 VAULT-no-shield attempt B (fresh opportunity 3 after recorded native wait): native_submissions=1, effective_actions=0, run_actions=0 → decision **denied(native_rejected)**, stopped(no_available_action).
  - run5 VAULT: native_submissions=1, effective_actions=1, run_actions=1, instant 0 → stopped(max_consecutive_actions).
- Setup native actions (separately counted, never scored): 1 native wait (`{"action":{"type":"wait"}}`, tick 10→21, energy 1000, raw/039); 1 native equip (`item_action_complete`, energy 1000, raw/045). No other manual moves/waits/rests. The HANDOFF row's native key move (1) is that row's required input, not setup.
- Pending: none at any point; no resubmission of any pending; each valid positive run stopped/released after exactly one effective action. `world_tick` never used as action count.

## Row results (denominator 6, no cross-layer aggregate)

### S3-LIVE-READ — PASS
- Input: `policy.dry_run` ×3 on valid Shadowstep policy `s3-live-read-shadowstep-01` (hash 11aa265451826cff20bc48408028efec) while idle. Raw: raw/006–009.
- Observable: three byte-identical plans (modulo __rid): decision=act, bound_target=`…actor-15094` (the visible dummy), target_distance=3, movement.plan=actor with landing annotation `kind=bounded, center (8,5), radius 5, min_radius 0`, confidence `source_bounded_alternatives`, reasons `actor_anchored_landing, landing_derived_by_native`, known_passable/known_hazard `unknown` — landing uncertainty visible, RNG not used as oracle (identical outputs; envelope remains bounded-unknown). `dry_run:true, executed:false, side_effects:"none"`.
- No advancement: world_tick 0→0, revision 7704→7704, player (5,5) life 104 unchanged, history retained_count 0 / next_command_id cmd-1 unchanged, auto log total 0, active false (raw/010, raw/011 vs raw/004/005).
- Layer/pin: actual MCP vs fixed dist (candidate.teaa 3a4e186b…). Owner: Test observed; fresh Sol adjudicates.

### S3-LIVE-SHADOW — PASS (first attempt; distance-1 hit branch)
- Input: set_draft/approve/activate/start of `s3-live-shadow-01` (hash 61e2a6c2…b3, cap1). Raw: raw/012–019. Exact target_sequence in policy: `target_plan=[{request:actor, selector:nearest_hostile}]`, destination `{selector:native_landing, anchor:bound_target, accept:{visible,native,any,allow_random}}`; native_result observed via run1 counters + observe (raw/017/018).
- One settled submission (native_submissions=1, effective_actions=1, run_id=1); plan actor target = visible dummy (dry-run binding raw/007; run used same policy).
- Actual endpoint (9,4): within declared envelope (bounded, center (8,5) radius 5; dist ≈1.41). Actual distance to dummy = 1 → dummy lost life 10000→9949.17 and gained daze: events cursor 10–12 "casts Shadowstep" / "is dazed!" / "51 total damage (33+16 darkness)"; inspect raw/019 shows `EFF_DAZED` detrimental. Stamina 300→278.8 (native debit 21.2).
- No target prompt; dialogs=[]; no fabricated deviation. Extra attempts used: 0 of ≤2 (adjacent-hit branch reached on first attempt, so the ≤2 cooldown-gated retries were unnecessary).

### S3-LIVE-LEAP — PASS
- Input: `s3-live-leap-01` (hash 9e368acd…f98, cap1), explicit player-known free landing grid (8,4) — visible floor, `block_status:passable, known:true, visible:true` (raw/020), exact distance 1 from dummy. Raw: raw/021–028.
- One settled submission (run_id=2, native_submissions=1, effective_actions=1, instant_actions=1 — instant counted once, separately). No resubmission.
- Grid matches request: player (9,4)→**exactly (8,4)**. Landing inside declared envelope (the requested grid itself; dry-run geometry for grid requests annotates `native_random_landing` bounded radius 1 — raw/037 shows the same annotation class; actual landing = center).
- Dummy (radius 1 recipient from actual landing) lost life 9949.17→9877.17 (−72.00; event "72 total damage (52+20 physical)") and re-dazed (cursor 15–17); inspect raw/028 confirms EFF_DAZED. Stamina unchanged (instant), cooldown set 19/20.

### S3-LIVE-VAULT-NO-SHIELD — PASS
- Input: `s3-live-vault-noshield-01` (hash 2fdce7e5…07c, cap1, when.always deliberate), T_VAULT cd 0, stamina 279.4 sufficient, player (8,4) adjacent to dummy, no shield equipped (equipment: 2 daggers/lantern/armour — raw/043).
- **Attempt A (retained, pre-budget, raw/033–035):** started on opportunity 2 already spent by instant Giant Leap → 1 native submission, then paused(budget_exhausted) with effective_actions=1/run_actions=0/instant_actions=1. Position unchanged (8,4), stamina unchanged, no dialogs, no events, Vault cd 0. **Not used as proof of native refusal** (per coordinator reminder); accounting semantics on a spent opportunity flagged as ISSUE-2 below.
- **Attempt B (scored, raw/040–042):** after `auto stop` + recorded native wait (raw/038/039, fresh opportunity 3) → run4: guard did NOT pre-refuse — dry_run decision=act with ordered sequence [actor, grid] (raw/037), and native_submissions=1 proves a real submission reached the native layer. Native refusal observed: decision `denied`, reason `native_rejected` (rejections `[{rule:case, reason:native_rejected}]`), effective/run_actions 0, no energy (stamina 279.4 before/after), position unchanged (8,4), no damage, no dialogs/prompt deviation, Vault cd 0, and player-visible native message at cursor 18, observed_world_tick 21: **"You require a shield to use this talent."**
- Layer: native (submission-level, not schema/guard). Cause: visible as code `native_rejected` + native message text above. Nothing blocked; no precise-layer flag needed.

### S3-LIVE-VAULT — PASS
- Setup: native equip of granted `S3 training shield` (`…object-15095`, identified, inventory slot 2) via `{"action":{"type":"equip","item_id":…}}` → item_action_complete, energy 1000; inspect confirms shield in OFFHAND, one dagger auto-moved to inventory (raw/044–046). First equip attempt with wrong field name (`item`) failed at schema validation (raw/044) — operator error, corrected from the returned schema error; NOT substituted for any refusal test.
- Input: `s3-live-vault-01` (hash 21775498…5e7, cap1), target_plan `[{request:actor, selector:nearest_hostile},{request:grid, destination:(7,6)}]`, destination same (7,6), distinct from current grid (8,4), free visible floor. Raw: raw/047–054.
- One settled native submission (run_id=5, native_submissions=1, effective_actions=1, run_actions=1); **no unexpected_target_request**; dialogs=[].
- Two ordered real target requests: dry-run annotation for this policy shape shows `requests:["actor","grid"]`, `sequence:["actor","grid"]`, reason `ordered_prompt_sequence` (raw/037; same plan executed in run5). Direct observation of the internal `nolock=true` flag is not exposed by the public API — NOT_OBSERVED as a literal value; the observable proxies are: ordered two-request plan annotation, successful settlement with distinct values (actor bound = dummy; landing = requested grid (7,6) ≠ actor), and zero unexpected_target_request.
- Effects: player (8,4)→**exactly (7,6)** (inside declared envelope; grid request bounded radius 1 centered (7,6)); original dummy lost life 9877.42→9858.38 (−19.04; event "19 physical damage", cursor 20–23 at tick 43) and is dazed again (inspect raw/054: EFF_DAZED + EFF_OFFBALANCE). Stamina 279.7→263.8 (−15.9 native debit).

### S3-LIVE-HANDOFF — PASS
- Input: `s3-live-handoff-01` (hash f284ad01…998) approve (raw/057) + activate **without start** (raw/058) → `auto status`: `active:true, control_owner:auto_combat, running_id:s3-live-handoff-01` (raw/059). Arbiter owner auto_combat observed.
- Native key once: `{"key":"Left"}` (raw/060) → player moved (7,6)→**(6,6)** (one real step; world_tick 43→54). The wrapper response carries a trailing `status:"stuck"/code:"no_progress"/moved_steps:0` — per brief this is the synthetic marker of its subsequent observation loop stabilizing, **not** failed movement; before/after coordinates prove the move. MCP control was re-held automatically in the same response (`control:"remote", control_lease:"held"`).
- After: `auto status` (raw/061) → `control_owner:manual` (native manual input revoked auto_combat ownership), `active:true` (policy stays activated), log total unchanged at 7 (last seq 7 = run5 stop) → **no policy action submitted, no old run replay**; run fields null (no new run created).
- Three reads (raw/062 observe, raw/063 map, raw/064 inspect T_SHADOWSTEP) all served normally; position stable (6,6); final status (raw/065) still manual with log total 7.
- Distinction per HANDOFF@1: `control:"remote"+lease held` is the MCP remote connection lease (reconnected by wrapper); `control_owner:"manual"` is the auto-combat arbiter owner. Both co-observed. No pending action existed, so this is scoped to manual revocation of ARMED ownership — **not** claimed as a pending-action takeover proof.

## Errors / unexpected categories
- No native_timeout, native_aborted, native_error, unexpected_target_request, or movement_postcondition_mismatch occurred in any scored or setup event. Expected native no-shield denial (run4) logged separately above. One schema validation error on my first equip call (wrong field name, raw/044) — operator-side, corrected immediately.

## Findings (new)
- **S3-LIVE-ISSUE-1 (low, product-vs-doc uncertainty):** `observe` returns `auto_combat: null` in this build; design §11.2 specifies observe includes an `auto_combat:{enabled,policy_id,…}` summary. Observed input: `{"observe":true}` at any phase. Raw: raw/001, raw/035 (key present but null). Expected: populated summary; Actual: null. Uncertainty: could be intended only in some phases (e.g., while running); did not affect any scored row.
- **S3-LIVE-ISSUE-2 (low, product accounting semantics, uncertainty flagged):** On a spent opportunity (opportunity 2), the Vault no-shield attempt produced 1 native submission then paused `budget_exhausted` with `effective_actions:1, run_actions:0, instant_actions:1` (raw/034). POLICY-01@1.1 says a settled reject without energy must not increase effective actions; either the native call was not a settled-reject on that path, or effective_actions counts something else on pre-budget opportunities. No wrong action, no resubmission, no state change resulted. Product-vs-harness-vs-operator uncertainty: cannot be resolved from public API; coordinator/Sol to adjudicate.
- **S3-LIVE-ISSUE-3 (low, operator-triggered surface question):** `{"policy":{"op":"log","limit":10}}` succeeded (`ok:true`, returned ring events) although `policy_op=log` is not a public MCP enum per coordinator. Raw: raw/036. This was my operator deviation (used before the reminder); retained for provenance. Expected: rejection of non-public op (or documented support); Actual: data returned. Product surface vs documentation mismatch — not independently verified beyond this single call.

## NOT_OBSERVED / limitations
- Internal `nolock=true` request flag (VAULT row): not directly observable through the public API; established indirectly (see row). All other required observables were established through public responses.
- Shadowstep landing remains natively random within the annotated envelope; only one branch (distance-1 hit) was required and observed; other envelope outcomes not sampled (legal, not required).
- Raw file raw/010 is the re-issued copy of an observe whose first issuance' output was discarded by a failed local parse (purely my local tooling; the game received two identical read-only observes).
- No death, no stall, no native error; no product/game/harness edits; no Lua console; no hidden-state reads; no kill/quit/save/reload; no polling of other agents.

## Metrics
- Denominator 6; numerator 6 (all mandatory rows established) → **6/6 PASS**, 0 FAIL, 0 BLOCKED, 0 N/A. First attempts preserved: SHADOW/LEAP/VAULT/HANDOFF/READ all single-attempt; VAULT-NO-SHIELD has attempt A (pre-budget, retained, not proof) + attempt B (fresh opportunity, proof).

## Evidence index
- Raw replies: `/workspace/t-engine4/tmp/mcp-s3-live-20260922/test/raw/001…065.json` with per-file request/purpose/class and SHA256 in `calls.jsonl` (sha256 5af6edec8fbfefae0552ee36cbb1ce3e16b0eaa94e7546789689582a96fecef3). Policies in `scripts/*.json`. Auto-logged complete MCP transcript (permissible evidence): `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/s3-live-02/play-mcp.jsonl` (90 lines at 10:15Z).
- S3-HARNESS-01 acknowledged as FIXED_VERIFIED pre-dispatch (startup-feedback.json); not a scored event; no re-verification attempted by Test.

## Exit
- Exit state: completed_observations. Next owner: coordinator f7a2979c-… (collect/dispose/reap), then fresh Sol Review. S4 waits for disposition; no claim made here about S4.
