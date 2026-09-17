# 0.9.0 code review — disposition record

Independent review (GPT-5.6 Sol, high) on `main` at `c077690` produced 17
findings (12 P1, 5 P2). All were dispositioned across two waves; both waves are
merged on `main`. This record is the durable summary (the per-wave detail lives
in `docs/tome-mcp-0.9.0-wave1-execution-safety.md` and
`docs/tome-mcp-0.9.0-wave2-interface-contract.md`).

## Maintainer decisions (binding)

| # | Decision |
| --- | --- |
| D1 | **Any** talent may be declared `emergency:true` (no talent-category whitelist). Safety comes from the pre-execution adapter guard over the real bound target (range / `canProject` / geometry / self-hit / ally friendly-fire) plus `max_selffire_risk`. |
| D2 | `max_selffire_risk==0` = hard gate (reject + record); `>0` = pause threshold. Candidate selection filters by the same guard. |
| D3 | "Instant" uses the **existing native signal**: talent `no_energy` (bool/function) consumed by `ActorTalents:useTalent`/`forceUseTalent`, corroborated by the observed energy delta. No new marker. |
| D4 | `start` **re-acquires the auto-combat lease** for an already-active policy (`start` = ensure lease + run). `active` = a policy exists; arbiter = current control. |
| D5 | `change_level` is **removed from the auto-combat schema/catalogue/capability** (the remote `tome.act` command is untouched); auto-level-change is a future phase. |
| D6 | `sustain.min_resource_pct` gates sustain activation; `flee_below_hp_pct` is a distinct **pause** reason (no auto-retreat). Fields that cannot be made honest are removed, never left inert. |
| D7 | Mixed: request ops/args and the **error contract** are normative and checked against the live registry; result shapes are documented per op with representative-field validation and a declared-gap mechanism (currently 0 gaps) — a full result JSON Schema is not required. |
| D8 | `approve` CASes the **draft**, `activate` CASes the **approved** version (code as-is; docs/server/UI/tests corrected). |
| D9 | Remote `auto_explore` is advertised in `capabilities.actions` / `action_support` / `native_tasks`. |
| D10 | Add `get` (three versions) and `clear` (draft only); §11 formally adopts the existing names `policy_log` / `replay` / `invalid_policy` (no rename of merged tools). |
| D11 | Computed getters are audited via `NativeCompatibility` (source digest + identity + declaration + dependency closure) and resolved only through that registry. |
| D12 | Wave 2 runs serially after Wave 1 (both touch `Runtime.lua`). |

## Findings disposition

| Finding | Severity | Status |
| --- | --- | --- |
| AC-01 `native_pending` destroyed by the live adapter; `resume` ignores settlement | P1 | Fixed (mapping before success branch; live auto root in `nativePhase`; `resume` refuses unsettled) |
| AC-02 Resource predicates read the wrong shape; `positive` returned HP | P1 | Fixed (scalar projection `p[name]` + `min_`/`max_` + unlocked-pool filtering) |
| AC-03 Safety adapter was not an execution guard; emergency too broad | P1 | Fixed (per D1/D2: real-target adapter guard + selffire/friendly-fire + gate) |
| AC-04 Sustains ran before the critical layer and the no-enemy end | P1 | Fixed (order: no-enemy end → critical layer → sustain, normal layer only) |
| AC-05 Unknown HP failed open | P1 | Fixed (unknown threshold ⇒ `unknown_safety` pause) |
| AC-06 Instant budget not implemented | P1 | Fixed (per D3; per-opportunity count, capped, not reset by frames/snapshot) |
| AC-07 Standalone auto-combat did not suppress `automaticTalents` | P1 | Fixed (`hasControl` includes the auto-combat lease / owned activity) |
| AC-08 Policy replacement kept the old controller generation | P1 | Fixed (activation invalidates/rebinds at a safe boundary) |
| AC-09 Restart after stop/no-enemies/manual was broken | P1 | Fixed (per D4) |
| AC-10 `change_level` advertised but not executable | P1 | Resolved by removal (per D5); recorded as a future phase |
| INT-01 v4 schemas did not describe the live interface | P1 | Fixed (requests: 14 live ops + args; generator derives from Runtime.dispatch + MCP names; 14 ops documented, 0 gaps) |
| INT-02 Error contract not exhaustive/emitted | P1 | Fixed (75-code registry is the single source; Lua+Python build the full envelope; CI fails on unregistered emitted codes; 64 emitted all registered) |
| INT-03 Policy validator not strict | P2 | Fixed (logging / tie_break / composite union / action `then` + negative tests) |
| INT-04 approve/activate CAS object vs docs | P2 | Fixed (per D8) |
| INT-05 Remote `auto_explore` missing from capabilities | P2 | Fixed (per D9) |
| INT-06 §11 policy surface incomplete / misnamed | P2 | Fixed (per D10: `get`/`clear`, §11 wording revised) |
| SAFE-01 Computed getters audited by source suffix only | P2 | Fixed (per D11) |

## Verification (independent, maintainer re-run)

- **Wave 1**: `test_auto_combat_execution` 10 (real `Actions.execute` → production
  mapping `mapAutoCombatOutcome`, real pending root), controller 76, service 71,
  policy 68, Runtime 156; Python 33; native probe 35/35 from **source** and
  **`dist/*.teaa`**.
- **Wave 2**: native_compatibility 16, actor combat 22, policy 78, service 79,
  Runtime 163; Python 34; `generate_protocol.py --check` = 14 live ops / 75 valid
  codes / 64 emitted registered / 75 envelopes validated; native probe 35/35 from
  **source** and **`dist/*.teaa`**.

## Explicitly retained / deferred (with reasons)

1. **AC-01 use_talent-level pending** is covered by a production-mapping unit
   test with a real pending root; the native probe does not construct a real
   yielding talent (rest/auto_explore activities and production-reads stand in).
2. **Auto level-change** (`change_level` for auto-combat): declared out of P1b
   and removed from the claims; future phase.
3. **Full result JSON Schema**: not required (D7); representative fields +
   declared-gap mechanism.
4. **Informative pure-tooltip description reads**: still excluded (no
   RNG/state tripwire facility yet) — a P2.5 decision, unchanged.
