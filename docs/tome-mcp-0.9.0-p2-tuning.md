# P2 — tuning (predicates, decision replay, A/B, second class) design/status

Date: 2026-09-17 · branch `feat/p2-tuning` · design
[tome-mcp-auto-combat-plugin-design.md](tome-mcp-auto-combat-plugin-design.md) v1.3
§15 row 3 / §16.

P2 is deliberately **bounded and evidence-driven**, data-only, and keeps the
executor behind `settings.tome_mcp_bridge.allow_auto_combat_execution`
(default **off**) and `change_level` opt-in (default **off**). No arbitrary
Lua/functions/regex.

## 1. Predicates / selectors (audited reads only)

Added (schema + catalogue + evaluator + `PolicySnapshot`):

| id | kind | read | notes |
| --- | --- | --- | --- |
| `enemy_rank` | predicate (cmp) | `actor.rank` (already in the observed actor capture) | ToME bands: normal 2, elite 3/3.2, unique/boss ≥3.5, boss 4+ |
| `enemy_level` | predicate (cmp) | `actor.level` (hidden-level tooltips stay unknown) | |
| `enemy_type` | predicate (string eq) | `actor.type` | `{"enemy_type":{"eq":"undead"}}` |
| `enemy_is_elite` | predicate (bool) | derived `rank >= 3` | no-arg (`{}`) |
| `enemy_is_boss` | predicate (bool) | derived `rank >= 4` | no-arg (`{}`) |
| `enemy_distance` | predicate (cmp) | bound target's grid distance | complements `nearest_enemy_distance` |
| `highest_rank_hostile` | selector | rank, tie-break nearest | |
| `most_dangerous_hostile` | selector | rank, then lowest hp, then nearest | **audited heuristic**, not `computed` |

Every target-related condition is now evaluated against the selector the
action will bind (`PolicyEvaluator` gained an optional
`opts.context_for(selector)`, supplied by the controller and the dry run). This
makes a rule such as `{when:{enemy_is_boss:{}},then:{...,target:"most_dangerous_hostile"}}`
work against the highest-rank hostile instead of the default binding, and keeps
the §5.3 "condition and action bind the same target" contract.

**Explicitly excluded (with reasons):**

- `has_effect` / `computed` remain in the schema but the auto-combat host answers
  them `unknown` (`nil`). A real answer needs a dynamic getter the bridge does
  not audit yet; exposing one would break the §8 fail-closed read audit.
- `most_dangerous`-by-`computed`: replaced by the audited rank/hp/distance
  heuristic above.
- `cluster_center` / AoE selffire placement: needs target geometry and
  `canProject` proof, out of P2.
- `ally_count`, `map_frontier`, `turn_parity`: the auto-combat host does not
  assemble friendly/map/turn reads; adding them is a separate audited-read task.

`capabilities.auto_combat` now lists the supported `predicates` and `selectors`.

## 2. Decision replay

The §10 log was already tagged with `tick`/`revision`/`policy_hash`/
`level_instance_id`/`rule_results`/`rejections`/`resources_before|after`/
`native_result`. P2 makes it paged and replay-inspectable:

- `PolicyLog.slice(log, after_seq, limit)` returns entries with `seq > after_seq`
  **oldest first** (bounded), so a client can walk a whole run without holding
  it all.
- New read-only `tome.policy` op **`replay`** (`after_seq`, `limit`) returns a
  `header` (`schema`, running `policy_hash`, session revision, control owner,
  run state/generation, log limit), the page, the `next_seq` cursor and the log
  status. It is allowed in observe mode and never changes state
  (`executed=false`, `side_effects=none`).
- The log stays a bounded in-memory ring (default 256) and is **not** written
  into the character save — it is runtime state (§6.3). It is a *decision
  trace*, not deterministic re-execution: raw inputs and adapter versions are
  not stored, and the docs say so rather than overclaiming "replay".
- `observe` is unchanged and stays bounded; `tome.policy_log` keeps its
  newest-first shortcut.

## 3. A/B tuning harness

`tests/auto_combat_ab.lua` is a deterministic, engine-free harness: it runs
fixed scripted snapshots through `PolicyEvaluator` for N policies and reports
per-scenario rows plus the diverging scenarios.

`tests/test_auto_combat_ab.lua` uses it on four fixed scenarios (low HP,
boss visible, no enemy, ray cooldown) with two policies:

- **baseline**: the frozen `anorithil_p1a` preset.
- **tuned**: the same policy plus one data-only boss rule
  (`enemy_is_boss` + `most_dangerous_hostile`).

Recorded result (`validation/2026-09-17-auto-combat-p2/ab-report.json`): exactly
one scenario diverges — `boss-visible` picks `ray`/`nearest_hostile` under the
baseline and `boss`/`most_dangerous_hostile` under the tuned policy. Low HP,
no-enemy and cooldown recovery are unchanged, so the tuning does not regress the
safety paths.

## 4. Second class adapter — Sun Paladin

Chosen pilot: **Halfling / Sun Paladin** (`celestial/sun-paladin`). It shares
the celestial/positive pool with the Anorithil but adds a ranged
single-target smite and a melee weapon sustain, so it fits the existing action
set without a `move` action.

Talent whitelist (all catalogue entries + adapters):

| talent | kind | target | resource |
| --- | --- | --- | --- |
| `T_CHANT_OF_FORTRESS` | sustain | self | positive |
| `T_WEAPON_OF_LIGHT` | sustain | self | positive |
| `T_HEALING_LIGHT` | heal | self | positive |
| `T_BARRIER` | buff | self | positive |
| `T_SUN_BEAM` | attack (hit, range 7) | hostile | positive |
| `T_ATTACK` | attack (melee) | hostile | — |

Preset `sun_paladin_p2` (sustains + emergency heal + shield + rank-aware
`smite-boss` + `sun-beam` + melee + declared cooldown `recover`). The native
probe gains `sun-paladin-preset`: schema validation, catalogue compatibility,
and a production `dry_run` against the real engine snapshot.

## 5. Validation

- Lua: 31 suites, **101,849 checks** — policy 52, catalogue 33, snapshot 21,
  service 61 (incl. replay paging/validation), controller 57, A/B 10.
- Native probe: **21/21** on source and `dist/*.teaa`
  (`validation/2026-09-17-auto-combat-p2/native-fixture-summary.json`).
- Python: 33 tests (incl. the `replay` literal/forwarding).
- `generate_protocol.py --check` and `generate_native_seams.py --check` green.
- `dist/tome-mcp-bridge.teaa`: 58 files, SHA-256
  `76b2ea636dcc0c5dbfee990bb35584eb019826a165eaef02f6f3c9a241559fd0`.
- Execution default and `change_level` default unchanged; P1a/P1b invariants
  (emergency-only critical layer, budget before layer, no rejected-as-is retry,
  `native_pending` never resubmits, manual input revokes the lease, player-only
  reads, read-only `dry_run`) intact.
