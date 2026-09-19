# Boundary self-check rev2 — BND-REV fixes (blint round 2)

Source: `tmp/mcp-play-support/review-boundary-selfcheck.md` (independent review of
`112b0a51`, verdict DO_NOT_MERGE: 2×P1 + 3×P2 + 1×P3). Branch `feat/boundary-selfcheck`,
worktree `tome-mcp-bridge-blint`. Principle: **a lint that prints PASS while unsafe code
slips through is worse than no lint**, so the false-PASS holes are the fixes.

## BND-REV-01 (P1) — Rule A missed real caller arrays; sparse policies measured as complete

Production fixes (the real defect). Every schema/manifest/evaluator ingress array is now
dense+closed validated by `Json.denseArray` **before** any `#`/`ipairs`/index walk:

- `PolicySchema.validate`: `policy.rules` (typed `rules_required`/`cause=hole` instead of
  measuring `{[1]=valid,[3]=invalid}` as a one-rule policy), `policy.sustains`
  (`invalid_sustains`), `policy.targeting.tie_break` (`invalid_tie_break`).
- `PolicySchema.validateCondition`: `cond.all` / `cond.any` (`invalid_all`/`invalid_any`).
- `PolicyEvaluator.evaluate`: `policy.rules` — a malformed rule list fails closed to a
  typed hold (`decision='hold', reason='invalid_rules', cause=…`), never a truncated
  eligible set; `evalCondition`/`isSafety`: `cond.all`/`cond.any` — malformed group is
  UNKNOWN / conservatively safety-involving (checklist C), never a measured prefix.
- `EffectManifest.verify`: `policy.rules` / `policy.sustains` — typed
  `invalid_rules`/`invalid_sustains` at this ingress (the manifest used to start iterating
  the unguarded carrier).
- `AutoCombatService.findRule` and `PolicyEditorModel.fields`: dense-guarded reads.

Regressions (`tests/test_auto_combat_policy.lua`, `tests/test_effect_manifest.lua`): for
each ingress, sparse/hole/key-beyond-end/non-integer-key rejected typed at the ingress,
including the reviewer's production reproduction (valid rule at 1, invalid rule at 3 →
`rules_required`/`cause=hole`; same for sustains, cond.all/any, tie_break, and
`Manifest.verify`).

Detector provenance model. The spelling allowlist is retired. The tool now carries an
explicit **ingress registry** beside the validator (`INGRESS_PARAMS` = the caller-data
parameters per (file, function); `INGRESS_ARRAYS` = the caller-data arrays per ingress;
`INGRESS_FIELD_KINDS` = leaf fields classified array/scalar). The registry carries the
load three ways:

1. **Registry conformance** — every registered array must be dense-validated inside its
   registered function; reverting a guard to a weak `isArray`+`#`/`ipairs` fails the run
   (negative self-test `SELF_TEST_REGRESSION` reproduces exactly the reviewer's
   sparse-`policy.rules` shape and the lint rejects it).
2. **Generic sweep** — any `#`/`ipairs` rooted at a registered ingress parameter (direct,
   aliased, multi-hop, field/index chained) is a site that must be guarded; a chain whose
   leaf field is unclassified is **UNCATALOGUED** and fails the run until it is classified
   (so a NEW measured array field cannot pass silently).
3. **Registry rot** — a registered function/array that no longer exists or is unmentioned
   fails the run (the registry is updated in the same change).

Stated limits (kept in the tool docstring and printed on `--list`): an array field that is
neither registered nor measured with `#`/`ipairs` inside a registered function is invisible
(harmless to rule A, which bites on measurement); provenance is per (file, function), so a
curated internal parameter that merely shares a name is not flagged (BND-REV-03 shape 5);
`pairs()` walks are out of scope (key-agnostic, no truncation).

## BND-REV-02 (P1) — Rule B PASSed a no-op forwarder

`check_rule_b` is now **semantic** (`analyse_forwarder`), on comment-stripped code
(commented-out `type()` lines never count):

- the list must be **consumed** by a forwarder loop that copies each flag into the spec —
  a list that exists but nothing reads it is a FAIL (the reviewer's synthetic no-op file
  now fails `--check` with typed findings; negative self-test added);
- the copy must be direct: a truthiness guard (`if src[flag] then`) is flagged because it
  would drop an explicit `false`, which the engine honours;
- the copied table must reach **both** footprint backends (`M.model` and `M.native`, or
  `M.expand` which dispatches to both);
- `block_path`/`block_radius`/`filter` must be type-checked on the real data path with a
  typed fail-closed outcome following the malformed branch.

On a tree with no forwarder yet (current state), the rule stays REVIEW — it bites once
proposal A' lands.

## BND-REV-03 (P2) — guard semantics

A dense call counts as a guard only when its result is bound and consumed with the invalid
path exiting (`if not ok then return/error`) or the use is dominated by the validated
branch (inside `if ok then` / the `else` of `if not ok`). The look-back stops at ANY
function boundary (named or anonymous `local inner=function() ... end`), one-hop field
aliases are followed (`a=plan; b=a.values; #b` → `plan.values`), and curated parameters
that merely share an ingress name are not flagged. All five reviewer shapes are `--self-test`
cases (ignored result, non-exiting guard, anonymous nested closure, field alias,
curated-name collision). Residual limits are stated in the module docstring.

## BND-REV-04 (P2) — engine drift check made two-way and the false claim removed

`engine_drift_notes` now **derives** the engine-consulted field set from the audited engine
sources (`Target.lua`, `interface/ActorProject.lua`, `interface/GameTargeting.lua`,
comments/strings stripped) and compares **both directions**: a declared field the engine no
longer consults, and a derived field that is neither declared nor classified, are both
reported for manual review. The fields outside the supplemental list are explicitly
classified as shape/geometry plumbing (`KNOWN_NON_SUPPLEMENTAL`) and targeting-UI/scan
plumbing (`KNOWN_UI_PLUMBING`). The old "cannot silently drift" comment is gone; the
honest claim is in the tool docstring and printed with the notes.

## BND-REV-05 (P2) — the mandatory gate cannot silently no-op

`tests/run.sh` now **fails the suite (rc=2)** when `python3` is absent. Skipping requires
the explicit opt-out `TOME_MCP_ALLOW_NO_PYTHON=1`, which prints a loud warning line. We
chose explicit opt-out over a hard requirement so minimal environments stay usable while
the gate can never turn itself off silently.

## Not retained

- BND-REV-06 (P3): the "27 A-sites" figure in the rev1 commit message was not reproducible
  (the review measured 25). Not carried forward as evidence; the registry conformance view
  (`--list`) is the count of record now.

## Invariants

Unchanged: no identity/digest/closure gate; no plugin-level strategy restriction; read
policy; budget; `native_pending`; lease; dry-run; deterministic tie-breaks; no new protocol
code; arrival k → `plan[k]`; presence+exactly-one outside groups; nil-vs-false admitted.
