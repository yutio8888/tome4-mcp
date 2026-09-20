# ToME MCP 0.9.0 — rebase-review fix round (union: `feat/s3-arm2` + `feat/r2-aprime`)

Dispositions of the independent rebase review (`tmp/mcp-play-support/review-rebase-admissions.md`,
sha256 `bc79698e…`); scope/attribution in
`tmp/mcp-play-support/rebase-admissions-fix-scope.md`. Branch-specific rows only:
RA-04 is the shared closeout row; RA-01/RA-02/RA-03/RA-05/RA-06 are the
`feat/r2-aprime` rows; the S3 row is the `feat/s3-arm2` row. Both sides are kept
below (union ledger, `feat/r2-aprime` × `feat/s3-arm2` merge).

## RA-01 (P2) — closed: the "single density validator" claim made TRUE

`overload/mod/mcp_bridge/Actions.lua` — `M.normalizeSequence` deleted its own
`pairs`/`maxKey`/`count` density loop and now delegates the density decision to
the shared `Json.denseArray(list,1)`, preserving the external contract: typed
`invalid_sequence`, never a shorter prefix, at most 8 entries, empty list
refused (`too_short` ⇒ same typed error).

Re-audit of every remaining ad-hoc density decision under `overload/`:

- The only density decisions are `Json.denseArray`/`Json.denseFault` themselves
  (`overload/mod/mcp_bridge/Json.lua`), plus the thin delegations
  (`MovementAdapterFactory.validateArray = Json.denseArray`,
  `AutoCombatGuard.denseCells`,
  `PolicySchema.denseList`/`denseCount`, `AssistantAdapter` and `OwnedImport`
  call sites, and now the `Actions.normalizeSequence` carrier) — no site runs
  its own `pairs` density verdict.
- (`densePolicyArray` was folded into `EffectManifest.verify`'s typed-cause
  validation in the union; see RA-02.)
- `PolicyCodec.classify` keeps its own key-scan loop, which is the frozen
  X-doubleprime codec internals (byte-identical to `main`, invariant): it runs
  on the codec's own decoded-document domain, and for array-marked tables it
  delegates to `Json.denseArray`/`denseFault` anyway. It is not a caller-array
  checklist-A ingress.
- Every other `pairs` loop under `overload/` is an object key-allowance /
  unexpected-field check (closed-field validation), not an array-density
  decision.

## RA-04 (P2, dispatcher sequencing) — closed by rebase

Both branches are rebased onto `main@97a69d8`, so the corrected TODO entry
(the withdrawn loop-39 "declared interchangeable group" **equivalence** claim,
NOT proposal A′) is what the union carries. The equivalence premise is not
restated anywhere; §8.1/§8.2 keep the arrival-order framing
(`arrival k ⇒ plan[k]`, index-preserving execution, per-projectile crit as an
annotation).

## RA-06 (P3) — wording corrected, X″ not weakened

The removed branch-local `MovementAdapterFactory.validateArray` was NOT "the
same function" as `Json.denseArray`: its ACCEPTANCE predicate is subsumed
(X″ is at least as strict — every input the old validator rejected is still
rejected), but the typed-cause precedence differs. The old validator checked
`minLength` before holes and treated `Json.null` as a table (it reported
`too_short`); X″ decides density first (`non_integer_key`/`hole`), only then
`too_short`, and reports `Json.null` as `not_array`. The stale "was the same
function" comment is replaced by this statement
(`PolicySchema.validateTargetPlan`).

## RA-05 (P3) — service-test guard bypass removed

`tests/test_auto_combat_service.lua` — the second `no_emergency_action`
scenario no longer mutates `controller.policy.rules` and clears
`policy_snapshot` to dodge the required `policy_mutated` guard; it is rebuilt
through the real store (`set_draft → approve → activate → start`) exactly like
the exact-delta adaptation, and additionally asserts the handoff runs on the
guard-validated activated policy.

## RA-02 (P2, R2-APR6-03) — CLOSED: one shared typed cause vocabulary

`overload/mod/mcp_bridge/Actions.lua` (`M.normalizeSequence`): the density
fault now also carries the shared X″ density cause as an additive THIRD return
value — the same cause `PolicySchema.validateTargetPlan` projects as `cause`
and `MovementPlanner.planSequence` projects as `detail` for the same sparse
shape. The vocabulary is exactly `Json.denseArray`'s:
`not_array|non_integer_key|hole|too_short`. A non-table or `Json.null` now
yields the shared `not_array` instead of the carrier's former bare error. The
typed `invalid_sequence` error itself and the two-value success/error contract
are unchanged (layer-specific limits such as the carrier's max 8 and
non-density entry faults keep the bare typed error with no cause). A
cross-layer regression drives the SAME shape through all three sinks and
asserts the causes are equal (`tests/test_auto_combat_sequence.lua`).

The union applies the SAME shared vocabulary to the catalogue boundary:
`EffectManifest.verify` now emits the typed
`invalid_rules`/`invalid_sustains` codes (with the shared X″ cause), replacing
the earlier local codes `rules_not_dense`/`sustains_not_dense` — the enforced
rule (dense+closed before any `#`/`ipairs`) is unchanged, and the density loop
still lives only in `Json.denseArray`.

## RA-03 (P2, NOT_OBSERVED → native evidence added)

`tests/native/tome-auto-combat-probe/overload/mod/AutoCombatProbe.lua` — new
`movement-earthen` scenario: the REAL `T_EARTHEN_MISSILES` and
`T_DWARVEN_HALF_EARTHEN_MISSILES` drive their whole stationary program through
the real raised signatures — both manifest tiers (TL4: 2 prompts, TL5: 3
prompts) and both variants — via the production host. `host.plan` lowers the
ordered plan with `outcome_uncertainty='per_projectile_random_crit'` published
as an annotation; `host.request` runs the real native bodies, which answer each
observed bolt prompt with `plan[k]` in ARRIVAL order (distinct destinations per
missile, so a remap/reorder would swap coordinates and fail), no handback. No
test-only talent is involved. Run source AND dist.

## RA-07 (P3) — stays OPEN

No committed `tools/check_boundary_rules.py` registration exists on the merged
tree; the AssistantAdapter registry rows remain scratch-only. Not claimed
closed. Formally DEFERRED to the scaffolding branch by the dispatcher
(`docs/tome-mcp-0.9.0-todo-xdoubleprime.md`): the checker is regression
scaffolding, not a gate, and lives off the product branches.
