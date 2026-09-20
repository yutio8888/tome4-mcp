# Movement adapter factory — S2 implementation (0.9.0)

Status: **implemented on `feat/s2-ordered-queue`** (base `main@8fdefa0`, the completed contract revision: §4.4 intro/execution-model bullet, §6.1 rows, §6.2).

**`action.sequence` is an internal executor carrier, not a policy field and not a
protocol field.** It is the closed decided-value list the executor's ordered
prompt-response queue consumes inside one native submission; it is never
agent-facing, never read from a policy, and never widened into `protocol/v4`.

This
document records what S2 of
`docs/tome-mcp-0.9.0-movement-adapter-factory-design.md` §13 actually built: the
closed `request_sequence` descriptor field, the Phase Door TL4/TL5+ cells, the
single-submission ordered prompt-response queue, its typed deviations, and the
planner/dry-run/annotation behaviour. The normative contract is §4.4 (with
§4.2/§6.1/§12.1/§13/§13.1). S3 (movement/effect composition) and S4 (`swap` /
moving another actor) are **out of scope**; `allow_auto_combat_execution` stays
`false`.

## 1. Descriptor field: `request_sequence`

`MovementAdapterFactory` gained a sixth template, `request_then_landing`, whose
`request_sequence` is a closed, ordered list of the native prompts a variant
raises. The record is validated by `M.normalizeRequestSequence`; every violation
is `movement_adapter_invalid`:

| Key | Rule |
| --- | --- |
| `index` | integer, must equal the array position; a hole/gap/reorder is invalid. |
| `request` | one of the prompt kinds `actor`/`grid`/`self`; `none` is not a prompt and is rejected for a sequence (rev2/S2-REV-04). |
| `observed` | **required** (S2 rev3): the per-entry CURATED OBSERVED SIGNATURE the reviewed native flow raises at this position. |
| `subject` | `'self'` or `'actor'` (`M.REQUEST_SUBJECTS`). |
| `value_source` | `'subject'` (default) or `'target_plan'` (`M.REQUEST_VALUE_SOURCES`). |
| `landing_from` | absent or `'envelope'` only. |
| `optional` | boolean; only admitted on the **trailing** entry. |
| unknown key | rejected (closed record). |
| length > 8 | rejected (the `PolicySchema` plan cap). |

`request_sequence` and `target_requests` must agree in length and kind; when
`target_requests` is omitted it is **derived** from the sequence, and a declared
`target_requests` must be a **closed dense `1..n` array** (a hole, non-array or
unknown key is `movement_adapter_invalid` at build time — rev2/S2-REV-03).
`request` excludes `none`: a sequence entry is a real native prompt, and a
`none` entry would be declarable-but-unexecutable (`invalid_sequence` at the
executor), so it is rejected at declaration time (rev2/S2-REV-04); `none`
remains a `target_requests` value for single-request descriptors such as
`self_random_teleport`, which need no queue. Existing
consumers (`EffectManifest.requestSequences`, the static policy validator, the
capability summary) therefore keep working unchanged. The template declares **no**
mechanical defaults for request order, subject, centre, bounds or landing.

### 1.1 The curated observed signature (S2 rev3)

Cursor geometry is **not** a sound actor/grid classifier (design §4.4/§3.2): the
engine documents `hit` as "hit a single grid in LOS"
(`engines/default/engine/Target.lua:634`), `setSpot` fills `target.entity` from
the selected cell for every geometry (`Target.lua:731-732`), the cursor starts
with the caster as `entity` (`engine/interface/GameTargeting.lua:28-33`), and
reviewed talents consume the same shapes with opposite semantics (Dimensional
Step: grid via `hit`; Rush: actor via `bolt`; Phase Door: actor via `hit`;
Tumble: grid via `beam`). So the runtime evidence is a **curated observed
signature** per entry:

- `cursor_type` (required): the `typ.type` string the reviewed action passes.
- Optional static discriminators from a **closed allowlist**: the boolean flags
  `nolock`/`pass_terrain`/`friendlyblock`/`nowarning`/`immediate_keys`/
  `no_restrict`, the bounded strings `first_target`/`msg`, and
  `default_target='self'` (matches only when `typ.default_target` is the caster).
- **Never** signature fields: dynamic numerics (`range`/`radius`, which are the
  per-request guard inputs and vary with talent level) and closures
  (`block_path`).

Matching is `typ.type == observed.cursor_type` **and**, for every allowlisted field,
the matching constraint above. **Signature semantics (normative, S2-R3-01 rev5):
the signature is PRESENCE-EXPLICIT, not a wildcard predicate.**

- A DECLARED boolean flag must be PRESENT in the observed spec and equal:
  `{cursor_type='hit'}` does not match a prompt that raises `nolock`; a declared
  `nolock=false` requires the key present with value `false`, distinct from absence.
  This is what makes a Vault-shaped pair (techniques/agility.lua:113,119) a
  distinguishable *curated* pair: its two prompts BOTH raise type='hit' and differ
  ONLY by nolock presence, so the two-entry program is cleanly distinguishable.
  (The agility `T_VAULT` itself is **not executable** — it is a mixed
  movement/effect talent reserved for S3; see §4.1. The presence-explicit rule is
  still load-bearing for the curated pairs the descriptor grammar admits.)
- An UNDECLARED boolean flag must NOT be raised by the observed spec.
- A declared string (`first_target`/`msg`) or `default_target='self'` must be present
  and equal when declared; when the signature omits them the observed value is
  **ignored** — real flows raise them nondeterministically (Phase Door's
  `first_target` is rng.percent-driven, conveyance.lua:85), so they are never
  required-absent and never discriminate by absence.
- Observed fields outside the allowlist (range/radius/closures) are ignored (guard
  inputs, not identity).

The **normative runtime gate is the executor's EXACTLY-ONE rule**: for each raised
prompt, the set of declared entries whose signature matches it must be exactly the
arrival position; zero matches, several matches, or a match at another index are a
typed deviation (`unexpected_target_request` with expected/observed index, observed
shape and matched indexes) that pauses and hands the live prompt back. The build-time
checks keep only what is decidable by inspection: every published entry must carry a
signature, and for N≥2 no entry's signature may **SUBSUME** another's (identical flag
constraint sets, the subsumer declaring no additional strings, equal values) — a
subsumed entry can never be the unique match of any prompt, so the descriptor is
`movement_adapter_invalid` (detail `request_signature_ambiguous`, with the colliding
indices). There is NO carrier-level pairwise rejection: a directly submitted
overlapping sequence is caught at runtime by the exactly-one gate. This is a **drift
check on recorded fields, never an identity/closure audit** of the live object (a
replaced live entry is called as-is; §7.1/AGENTS.md). Every published sequence
**must** carry a signature on every entry. This is a plugin-completeness boundary,
not a strategy judgement. Both Phase Door TL4/TL5+ descriptors carry their real,
source-verified signatures (actor
`{cursor_type='hit',friendlyblock=false,nowarning=true,default_target='self'}`,
landing `{cursor_type='ball',nolock=true,pass_terrain=true,nowarning=true}`). The
S2-R4-01 reclassification removed the agility `T_VAULT` from the executable
manifest (mixed movement/effect talent, typed reason
`movement_effect_composition_required`); the presence-explicit grammar still
admits a Vault-**shaped** two-entry pair when a pure-movement talent declares it.

## 2. Phase Door matrix (TL4 / TL5+)

The S1 `unsupported` TL4+ branch is replaced by real descriptors. Both axes are
still pre-read, so an unknown level or attribute remains
`movement_variant_unknown`.

| effective level | `phase_door_force_precise` | resolved `request_sequence` |
| --- | --- | --- |
| `< 4` | absent | `{'none'}` target_requests (`self_random_teleport`, no `request_sequence` — a single no-prompt request needs no queue) |
| `< 4` | present | `{'grid'}` (`grid_move_bounded`, LOS fallback) |
| `[4,5)` | absent | `{'actor'}` — subject self; landing = native random self, `t.getRange` |
| `[4,5)` | present | `{'actor','grid'}` — actor self, then the landing grid (`t.getRadius`) |
| `>= 5` | either | `{'actor','grid'}` — the grid prompt is statically unconditional |

**TL4 choice and justification.** §4.4/§12.1(a) admits either a trailing
`optional=true` grid entry on a single TL4 branch or two explicit attribute
branches. S2 chose the **explicit split**: the `phase_door_force_precise` axis is
already read and must be known at TL4+, so the two states are already
distinguishable; an explicit N=1 branch keeps the declared program exactly what
the source raises; and the TL5+ cell is then statically unconditional
(`at_least=5`), matching the native gate's first disjunct. The trailing-`optional`
mechanism is nevertheless implemented and tested (factory validation, executor
`reduced=true`), because a genuinely state-dependent trailing prompt needs it.

## 3. Executor queue

`overload/mod/mcp_bridge/Actions.lua` gained a closed internal `action.sequence`
field (dedup-safe: `Json.encode` in `M.fingerprint` covers it). It lives **inside
one action opportunity and one native submission**: the executor arms the queue
on the single `useTalent` call and answers the k-th observed `getTarget` with the
k-th declared entry's decided value.

- `kind` is what the answer **is** (`grid` coordinates with no entity, `self`
  the caster cell, `actor` the bound actor); `request` is the declared prompt
  kind it answers. The value-kind admissible for each prompt kind is
  `SEQUENCE_VALUE_KINDS` (an `actor` prompt may be answered with the caster or
  the bound actor; a `grid` prompt only with pure coordinates).
- **Observed-signature match (S2 rev3).** Before any answer is built, the
  observed native request is matched against the **declared entry's curated
  observed signature** (§1.1). A **readable** spec that matches no declared
  entry — a reordered flow, whose out-of-order prompt cannot match the entry
  curated for its arrival position, a signature-mismatched prompt, or an extra
  prompt past the sequence — is a typed deviation `unexpected_target_request`
  with `expected={index,request}` / `observed={index,request|nil}` and
  `observed_shape=typ.type`; the live prompt is **handed back** (the wrapper
  falls through to the real native targeting UI) and
  `command.target_handed_back` is recorded — **never** `command.target_cancelled`
  (a still-live prompt is neither answered nor cancelled). A spec the bridge
  cannot **read** as a signature (`typ` not a table, or `typ.type` not a string)
  is `movement_request_kind_unknown` with `observed_shape=nil`, also handed back.
  The deviation additionally carries `matched_indexes` (the declared positions whose
  signature matched the prompt; empty for a zero-match, two or more for an ambiguous
  declaration, a single other index for a reorder). For a **specifically curated**
  pair whose signatures differ by a declared discriminator (Vault-shaped `nolock`
  presence; Phase Door's cursor type), the positions are distinguishable by
  construction and a reordered native flow cannot receive the k-th declared answer.
  That is **not** a property of arbitrary accepted declarations: the build check
  rejects only subsumption, so a non-subsuming overlap is admissible and both
  signatures can match one prompt. For every accepted declaration the guarantee is
  the **runtime exactly-one gate** below (an ambiguous prompt matches several
  entries and is handed back, never answered), so a wrong answer is prevented at
  execution time regardless of whether the declaration was distinguishable by
  construction. What this check cannot observe is the native body's internal
  consumption of an already-given answer, which stays bounded by the per-request
  native guard, the native rejection and the declared postcondition check. After any
  live handback the wrapper stops answering: the remaining prompts of the invocation
  go to the player, and the settle check neither overwrites the recorded deviation
  nor reports the remaining entries as missing.
- **Runtime EXACTLY-ONE gate (S2-R3-01 rev5, normative).** The executor computes the
  set of declared entries whose curated observed signature matches each raised
  prompt; the prompt is answered only when that set is exactly the arrival position.
  There is NO carrier-level pairwise rejection in `Actions.normalizeSequence`: even a
  directly submitted overlapping/identical sequence is caught here (ambiguous →
  several matches → handback), so the invariant cannot be bypassed through the
  command path.
- Every request keeps the **native per-request range/self-warning guard**
  (`allowed(typ,x,y)`), evaluated against that request's own spec, so a value
  legal for the grid prompt but not the actor prompt stays refused. A guard
  failure is answered as the existing native target cancel
  (`command.target_cancelled`: `target_out_of_range` / `self_target_warning` /
  `target_out_of_bounds` / `invalid_target`). An internal value whose KIND
  cannot answer the declared prompt (a decode failure inside the carrier, not a
  live-prompt mismatch) is also cancelled, not handed back (there is no correct
  value to hand anyone).
- `command.target_sequence` records one bounded entry per observed request,
  including the **answered value** (`answer={x,y,uid,name}`, rev2/S2-REV-06);
  `command.target_geometry` keeps its meaning (the first observed request).
- The settle-time missing-entry rule applies only after the invocation actually
  entered the targeting flow (`raised`), and its zero-prompt exemption is
  **narrow** (S2-FIX5/S2-FIX5-R1): only a pre-prompt native **FAILURE** (a falsy
  `useTalent` return before any `getTarget` — cooldown / no energy / `on_pre_use`)
  settles as the ordinary `native_rejected`/no-energy outcome with no
  `sequence_deviation`. A zero-prompt **TRUTHY** return for a declared
  non-optional sequence is **not** exempt: the curated prompts were never
  consumed, so the typed `unexpected_target_request` missing-sequence deviation is
  surfaced (`expected={index,request}` at the first missing entry,
  `observed={index,request=nil}`, `skippable=false`) and the action is never
  reported as `action_complete`. Fail-closed by default; no curated
  `zero_prompt_success` allowance exists for any reviewed talent.
- The queue never resubmits the talent while pending.

Lowering (`Runtime.buildAutoCombatHostFor`'s `reads.execute`) maps a
`plan.kind=='sequence'` plan to `action.sequence = plan.values` (implying the
authoritative wrapper), and only when `plan.kind` is a single `grid`/`actor` does
it use the legacy single-target lowering. Each decided value carries its entry's
curated `observed` signature, so the executor matches the live prompt against the
same curation the factory validated. The production outcome mapping preserves
`target_sequence`, `reduced`, `reduced_reason`, `sequence_deviation` and
`handed_back`.

### 3.1 Asynchronous handback (S2 rev3/§6.2)

The typed deviation is delivered to the controller **inside the same submission**,
not after the pending native call settles:

1. `Actions.execute` attaches `target_sequence`, `sequence_deviation`,
   `sequence_reduced`/`reduced_reason` and `handed_back=true` to its
   `native_pending` result. `M.mapAutoCombatOutcome` copies all of them onto the
   mapped outcome (including the `handed_back` evidence).
2. The controller (`AutoCombat.lua`) checks `outcome.sequence_deviation`
   **before** its budget increment and its `native_pending` branch: on a
   deviation it records the bounded detail, calls `self:pause(reason)` and
   returns the pause (with `handed_back` evidence) — it never enters
   `waiting_native`.
3. `AutoCombatService.step` then takes the existing safety-pause path
   (`M.SAFETY_PAUSES`): run stopped, `Arbiter.revoke` — **the auto lease is
   released immediately**, while the native call is still pending. Because the
   run is stopped, `onOpportunity` can never turn the pending body into a fresh
   opportunity; the rule cannot be resubmitted.
4. **Settle-time delivery (belt-and-braces, exactly once).**
   `reapAutoInvocation` delivers an undelivered `root.sequence_deviation` through
   `AutoCombatService.nativeDeviation` (modelled on `nativeAbort`: record the
   typed event, pause with the reason, stop the run, revoke the lease), guarded
   by a `deviation_delivered` flag so a deviation already delivered inside the
   step is never delivered twice. This covers a body that settles without player
   input.
5. **The live interaction is answerable.** The handback falls through to the real
   native path, which registers a handle via `Interactions.openTarget` and
   suspends on `coroutine.yield()`. After the lease is released the caller
   answers it through `respond`/`dismiss`, whose routing falls back to the auto
   invocation's current handle (`autoHandbackHandle`) once the arbiter no longer
   owns auto-combat and the run is stopped; the existing control-token,
   interaction-id, consumed and revision guards all apply, and nothing is
   granted while the run is still live. S2-R3-02: the auto route computes the
   response fingerprint **before** both routes and classifies a reused
   `response_id` first — `response_conflict` when the recorded fingerprint
   differs, an idempotent no-op reply when it matches (reachable after a failed
   apply) — exactly like the command-scoped route, and every auto answer is
   counted and bounded by `Interactions.MAX_RESPONSES`
   (`response_budget_exhausted`). The command route's extra `revoke` on budget
   exhaustion tears down a remote-owned command execution state that does not
   exist for the auto invocation (its lease is already released to manual), so
   the auto route enforces the bound by refusing the answer without revoking the
   session. The bounded abort
   (`abortAutoInvocation`) is **live-handle-first**: a live target handle is
   cancelled (reason `handed_back_timeout` when the prompt was handed back)
   regardless of `command.target_cancelled`, and only when no live handle remains
   may `target_cancelled` take the `authoritative_target_cancelled` fast path.

## 4. Typed deviations (§6.1)

| Condition | Behaviour |
| --- | --- |
| Readable prompt matching no declared entry (extra, reordered, or signature-mismatched) | `unexpected_target_request` with `expected={index,request}` / `observed={index,request|nil}` / `observed_shape` / `skippable`; pause, never resubmit, release the lease via the safety-pause path; a **live** prompt is handed back to the real native targeting UI (`target_handed_back`). A missing non-optional entry detected at settle time has no live prompt left and surfaces directly. |
| A raised prompt the bridge cannot read as a signature (`typ` not a table or `typ.type` not a string) | `movement_request_kind_unknown` with `{expected={index,request}, observed_shape=nil}`; the live prompt is handed back; the executor pauses and the lease is released. A **readable but unmatched** spec is **not** this code (it is `unexpected_target_request`). |
| Missing **trailing optional** entry | settled native outcome with `reduced=true`, `reduced_reason='trailing_optional_not_raised'` — **not** an error. |
| A decided value cannot be evaluated (unresolvable subject actor, no planned destination) | `movement_request_value_unknown` with `{index,request,dependency}`; the prompt is cancelled (there is no value to hand the player either), the executor pauses and the lease is released — never answered with a wrong value. |
| Stall with no next prompt | bounded by the existing `native_timeout` abort (`Runtime.guardAutoInvocation`), unchanged. |
| Multi-prompt plan against an adapter with no `request_sequence` | unchanged `unsupported_target_plan`, `missing='ordered_request_sequence'`, `scope='multi_prompt'`. |

The controller (`AutoCombat.lua`) pauses with the deviation's typed reason, does
**not** add it to `rejected_landings` (a multi-prompt deviation has no single
coordinate), and never resubmits. The event reaches the bounded decision ring and
the client-visible policy log as a `paused` detail (with the deviation's
`expected`/`observed`/`observed_shape` and the `handed_back` marker). The typed
deviations (`unexpected_target_request`, `movement_request_value_unknown`,
`movement_request_kind_unknown`) are player-handoff pauses: `AutoCombatService`
releases the lease and stops the run, exactly like the existing safety pauses.

**No new `protocol/v4` error code.** `unexpected_target_request`,
`movement_request_value_unknown`, `reduced` and `target_sequence` are internal
auto-combat reasons/fields carried through existing plumbing; the protocol
registry (`protocol/v4/vectors/error-codes.json`, 75 codes) and `ErrorRegistry`
are untouched.

### 4.1 Officially-unsupported multi-prompt talents (S2-R3-01 rev5)

From the full survey of the official 1.7.6 talents (259 `data/talents/**` files,
action-block parse), the multi-prompt talents and their dispositions. Each is
published as a structured `EffectManifest.UNSUPPORTED` entry with its own typed
reason — a capability boundary, never a strategy judgement:

| Talent | Typed reason | Why (file:line) |
| --- | --- | --- |
| `T_PHASE_DOOR` | — (supported) | two-entry: `hit`+`default_target=self` (spells/conveyance.lua:84) then `ball`+`nolock` (:114); distinguishable by cursor type |
| `T_VAULT` | `movement_effect_composition_required` | the agility Vault (techniques/agility.lua:82-161) is a MIXED talent: its sequence (first `hit` prompt, target def at :92 / `getTarget` at :114, then `hit`+`nolock` at :118) is distinguishable, but the first (actor) prompt's target is attacked (:137-138) and may be dazed (:140-145) before the move (:149-150); component-free movement admission would bind that actor prompt and hide the effect from the guard. Reserved for S3 (review S2-R4-01) |
| `T_MERGE`, `T_STONE` | `moving_or_swapping_another_actor` | the effect targets/moves another actor: Merge kills the caster's own doomed shadow (`target.die(target)` at cursed/advanced-shadowmancy.lua:51) before acting on the second actor (:52); Stone relocates that shadow (`target:move(sx,sy,true)` at :88) and attacks through it (`target:project(...)` at :100). The second spec differs by the ALLOWLISTED `pass_terrain=true` (:45,:82) plus `friendlyblock=false` for Stone (:82), so the signature axis was **not** the blocker |
| `T_CURSED_BOLT` | `nondeterministic_prompt_subject` | each loop iteration picks a random shadow as the bolt origin (`rng.table(shadows)` at cursed/advanced-shadowmancy.lua:242) and the entry is order-sensitive (first success consumes the crit roll :248-251, first failure aborts :255-258); the prompt count itself is bounded and player-known (cap 4, cursed/shadows.lua:350-352), so the count was **not** the blocker |
| `T_WORMHOLE` | `effect_is_a_later_triggered_trap_pair` | activation moves nobody: it creates a pair of later-triggered traps (chronomancy/spacetime-weaving.lua:164-207, added at :209-224) whose third-party trigger teleports whoever steps on one later (:179-194, `teleportRandom` at :183). The prompts ARE distinguishable by cursor_type (:144 `bolt` vs :152 `hit`) and `distance>=2` (:157) is checkable pre-commit, so neither was the blocker |
| `T_EARTHEN_MISSILES`, `T_DWARVEN_HALF_EARTHEN_MISSILES` | — (supported, A′ admission) | The loop-39 withdrawal is **SUPERSEDED**. The prompts are mutually unidentifiable (all three local bolt specs are identical: `spells/stone.lua:38,45,53`; the dwarven twin adds `friendlyfire=false,friendlyblock=false` at `:34,:41,:49`), so they are declared as ONE mechanically validated `group` (§A′ below). The admission is justified by the **arrival-order** guarantee, NOT by any equivalence claim: the S2 executor answers the k-th OBSERVED prompt with `plan[k]` (`Actions.lua`), so no declared value is ever re-mapped. The per-missile `self:spellCrit(damage)` roll (`stone.lua:42,48,56`; `dwarven-nature.lua:38,44,52`) and the caster on-crit callbacks (`Combat.lua:2025-2056`) are published as `outcome_uncertainty='per_projectile_random_crit'` — an annotation, never a refusal (AGENTS.md read policy v1.4). The tactic stays legal for a player |

Note: the talent called "Stone Shards" in the survey is the dwarven
"Earthen Missiles" (`T_DWARVEN_HALF_EARTHEN_MISSILES`,
gifts/dwarven-nature.lua:21); there is no talent of that name in 1.7.6.
`T_SKIRMISHER_VAULT` (techniques/acrobatics.lua:27, single `beam` prompt at :53) is a DIFFERENT talent — the
acrobatics Vault, a genuine single-prompt landing — and is correctly
modelled single-prompt; it is not re-modelled.

## 5. Planner, annotations and dry run

`MovementPlanner.planSequence` plans each declared entry with the *existing*
kind-specific branch (so range bounding, occupancy resolution, envelope
annotation and `accept` evaluation are reused verbatim) and returns
`{kind='sequence', steps, values, annotation}`. A reversed plan is
`target_plan_mismatch`; a descriptor with a `request_sequence` is driven by the
queue for every N (including N=1, because a self-subject actor prompt cannot be
expressed by the single-target lowering). A `subject='self'` entry bound to
another actor is the typed S4 gap
(`moving_or_swapping_another_actor`), never a strategy refusal.

The movement report keeps `requests` (the declared kinds), `landing.kind`
`random|bounded`, center/radius and the LOS-fallback envelope as **annotations**;
a random or out-of-vision landing is never itself a refusal — the policy's
`destination.accept` decides. Planning and dry run stay read-only and
non-executing (they never call `useTalent`/`t.action`/`teleportRandom`).

## 6. Invariants preserved

Live getters/builders are normal entrypoints (no identity/digest gate; a
missing/erroring/nil/non-finite value is a typed unknown); no plugin-level
strategy restrictions; one-opportunity budget counting native actions only; a
settled queue deviation does not consume the budget and is never resubmitted;
manual input revokes the lease; deterministic tie-breaks (no RNG in planning);
reads never submit actions and never expose player-unknown information.

## 7. Evidence

- **Lua**: `bash tests/run.sh` (40 suites). The ordered-queue suites:
  `tests/test_auto_combat_sequence.lua` (197 checks, includes the A′ in-group
  matching/arrival-index cases and the classifier
  falsification matrix: legal grid-via-`hit`/`actor-via-`ball` accepted per
  signature, unreadable spec ⇒ `movement_request_kind_unknown`, readable-but-
  unmatched ⇒ `unexpected_target_request` + `observed_shape`, same-kind reorder
  detected, signature-ambiguous descriptor rejected at build time);
  `test_auto_combat_movement_factory.lua` (122, includes the A′ mechanical group
  and stationary-template validation), `test_auto_combat_guard.lua` (60,
  includes the Dwarven `friendlyblock=false`/`friendlyfire=false` fidelity and
  the partial-footprint fail-closed case), `test_effect_manifest.lua` (465,
  includes the A′ admission assertions), `test_auto_combat_controller.lua`
  (121, includes the `native_pending` + deviation pause-before-pending case),
  `test_auto_combat_service.lua` (162, includes the lease release and the
  settle-time `nativeDeviation` delivery), `test_runtime.lua` (253, includes the
  production outcome-mapping survival, the reap-exactly-once delivery, the
  live-handle-first abort, the `authoritative_target_cancelled` regression, the
  respond/dismiss answerability after lease release, and the NEW end-to-end
  guard-PERMIT-to-`Tracker.startAction` regression).
- **Python**: `server/tests` 39 OK; `tools/generate_effect_manifest.py --check`,
  `tools/generate_native_seams.py --check`, `tools/generate_protocol.py --check`
  all exit 0.
- **Native auto-combat probe** (`tests/native/auto_combat_run.py`), source and
  packaged `dist`, scenario `movement-sequence`:
  `sd_plan_sequence`, `sd_reverse_plan_rejected`, `sd_static_unsupported`,
  `sd_two_requests_ordered`, `sd_distinct_values`, `sd_second_range_refused`,
  `sd_missing_optional_reduced`, `sd_reorder_refused`, the NEW
  `sd_phase_door_no_handback` (REAL TL4 `T_PHASE_DOOR` driven through its
  manifest `request_sequence` — no test-only talent, no synthetic shapes, the
  curated signatures matched against the real raised specs) and the NEW
  `permit-path:*` checks (a guard permit verdict reaching
  `Tracker.startAction`/`Actions.execute` in exactly one submission, and a
  reject verdict reaching none), and the S2 rev3
  `sd_handback_yielding` (a TRULY yielding native handback: the native body
  suspends on the real `targetGetForPlayer`, the deviation survives to the
  controller, the run pauses with the typed reason and the lease is released,
  the rule is not resubmitted, the prompt is answerable afterwards, and an
  unanswered prompt is cancelled at the bound). The `sd_distinct_values` check
  observes the **recorded answer values** (`answer={x,y,uid,name}` per prompt),
  not only the prompt geometries (rev2/S2-REV-06).
- **Native acceptance** (`tests/native/run.py`), source and `dist`: 101 checks
  passed.
- `python3 tools/package.py`: 68 files; archive = manifest = source tree, 0
  mismatches; the dist sha256 is recorded in the round report.


## 8. A′ admission: declared groups + the stationary effect program

The revised proposal A′ (adversarial review verdict *sound with changes*; binding
revision log §6) admits `T_EARTHEN_MISSILES` and
`T_DWARVEN_HALF_EARTHEN_MISSILES`. The two mechanisms it adds are:

### 8.1 `group` — declared, mechanically validated membership (§6.3)

`group` is a closed key on a `request_sequence` entry (bounded identifier:
lowercase word characters, 1..32). It is **declared** membership, never inferred
from signature equality, and it is validated mechanically at BOTH boundaries:

- `MovementAdapterFactory.normalizeRequestSequence` requires, per group: ≥2
  members, one `request` kind, EXACTLY EQUAL normalised signature records
  (`M.signatureEquals`), and CONTIGUOUS members (`group_not_contiguous`
  otherwise); on a stationary program it additionally requires
  `request='grid'` + `value_source='target_plan'`. Any violation is
  `movement_adapter_invalid` (`bad_group_key` / `group_too_small` /
  `group_kind_mismatch` / `group_signature_mismatch` /
  `group_stationary_not_grid` / `group_stationary_value_source` /
  `group_not_contiguous`) and is never published.
- `Actions.normalizeSequence` re-validates the SAME invariants on the internal
  carrier (`Factory.groupMembership` with `{carrier=true}`), so a hand-authored
  carrier cannot forge or weaken factory-validated membership — it is
  `invalid_sequence`. R2-APR-03 (rev): the carrier re-validation uses the
  factory's SHARED machinery: the observed signature is normalized by the
  factory's canonical `normalizeObserved` (identical grammar and bounds — a
  65-byte `first_target` the factory refuses is refused on the carrier too), and
  group membership enforces every carrier-expressible invariant including
  CONTIGUITY. R2-APR2-02 (rev): contiguity is now enforced **unconditionally at
  both boundaries** — the previously generic-only `stationary or carrier`
  contiguity gate was widened, so an interleaved group is refused at BUILD time
  as `group_not_contiguous` (and on the carrier, unchanged). The two boundaries
  therefore accept **exactly the same language**; the semantic chosen is
  *forbid interleaving*, because the carrier is a re-validation of the
  factory's published language and must never ACCEPT a membership the factory
  would refuse. The stationary `grid`/`value_source` closure itself is a
  build-time template property (the carrier's entries carry no `value_source`);
  stationary routing is gated by the template-derived marker (R2-APR-02), so the
  enum is never a caller-authorable routing input.
- An entry declaring a group is exempt from the build-time subsumption rejection
  **for its own group members only**; every ungrouped pair keeps today's
  behaviour exactly (including the presence-distinguishable `{cursor_type='hit'}`
  vs `{cursor_type='hit',nolock=false}` pair, which stays ADMITTED — the earlier
  proposal's nil-vs-false rejection is deleted).

### 8.2 The runtime gate relaxes MATCHING ONLY (§6.1)

For a raised prompt the executor computes the matched set. It answers **iff** the
matched set CONTAINS the expected arrival index AND all matches are members of
that entry's declared group (or, as before, the single expected entry matches).

- The answer is always `action.sequence[observed]`: **arrival k ⇒ plan[k]**.
  There is no value comparison, no reordering and no "interchangeable" logic.
- A matched set that EXCLUDES the expected arrival index is ALWAYS a typed
  deviation; cross-group matches, non-members and ambiguous ungrouped matches
  likewise produce `unexpected_target_request` with
  `expected`/`observed`/`matched_indexes`.
- **Guarantee wording (§6.1, revised):** *the k-th OBSERVED prompt is answered
  only with `plan[k]`*. What the mechanism cannot observe is **source-slot**
  identity inside a same-signature group (a hypothetical replaced native body
  raising its identical prompts in another source order is undetectable); for the
  reviewed 1.7.6 bodies (`spells/stone.lua:38-56`;
  `gifts/dwarven-nature.lua:34-52`) the prompts are raised in source order, so
  this does not block admission. Source drift is advisory under `AGENTS.md` and
  is not policed by a runtime identity gate.

### 8.3 `stationary_sequence` — the closed stationary program (§6.5)

The movement vocabulary has no "fire N projectiles at N chosen grids without
moving", so a closed `stationary_sequence` template exists: fixed
`delivery='stationary'`, `landing='none'`, `center='none'`, `traverses=false`,
`relocates_other=false`, `required={request_sequence}`, and **grid-only**
enforcement (`stationary_entry_not_grid` / `stationary_entry_value_source` /
`stationary_entry_optional`). Every plan value must be a **valid grid**; a
malformed value is rejected, never filtered. The program is lowered by the
**existing** sequence planner into the same `{kind='sequence'}` plan — no second
queue — and the guard marker `stationary` is a **validated consequence of the
resolved template**, never an independently authorable manifest boolean.
R2-APR2-01 (rev): the guard REQUIRES the planner-attached resolved
`plan.request_sequence` and DENSE-validates it over ALL keys before using its
length (a sparse `{1,3}` sequence reports `#declared==1` and could otherwise
pair with one dense grid to bypass the declared program). The length is then
cross-checked against the dense `plan.values` and compared entry-by-entry on
kind. An absent, sparse or length-mismatching sequence is a typed
`movement_plan_unavailable` (`plan_sequence_missing` / `bad_plan_shape` /
`plan_sequence_length_mismatch` / `plan_sequence_kind_mismatch`) with **zero**
precheck/expansion calls.

### 8.4 Guard: Dwarven projection fidelity and footprint closure (§6.4/§6.5)

- These talents have LOCAL `tg` tables, not a callable `t.target` builder, so
  "the real shape" is a curated copy of those local flags
  (`AutoCombatGuard.STATIONARY_SPECS`). The `canProject` precheck and the native
  footprint input carry the **actual static flags**; the engine uses
  `friendlyblock` to let a friendly actor NOT block the projection
  (`engines/default/engine/Target.lua:527-535,588-607,657-664`), so a probe
  rebuilt from `{type,range,talent}` alone can manufacture a false
  `no_line_of_sight`. `friendlyfire=false` also reaches risk/effect modelling.
  R2-APR2-03 (rev): the forwarded allowlist is now the **complete** set of
  engine-consulted STATIC projection fields — `selffire`, `friendlyfire`,
  `friendlyblock`, `stop_block`, `actorblock`, `nolock`, `pass_terrain`,
  `nowarning`, `no_restrict`, `requires_knowledge`, `force_max_range`,
  `min_range`, `grid_exclude`, `filter`, and a raised `block_path`/`block_radius`
  callback (or an explicit `false`, which the engine honours and which disables
  the default blocker). A value is forwarded whenever it is present (`~=nil`, so
  `false` is admitted). R2-APR3-01 (rev3/rev5): `act_exclude`
  (`{[uid]=true,...}`, documented at `Target.lua:647-650`) is also forwarded and
  honoured: the engine applies it BEFORE the self/friendly admission
  (`ActorProject.lua:248-255`), so the membership measurement excludes every
  actor whose uid is a key — including the caster. The measurement mirrors the
  engine's EXACT admission expression `typ.act_exclude and typ.act_exclude[act.uid]`
  value-for-value (`AutoCombatGuard.M.actExcludeVerdict`): a raised table is
  indexed by uid and `[uid]=false` stays a non-exclusion; `nil`/`false`
  short-circuit to no exclusion; a **string** indexes without error to `nil`, so
  it is native-faithful **no exclusion** (it must NOT be turned into a known
  self-risk); a **number**/`true` would make the native indexing RAISE, so it is
  an undecidable admission -> a **typed unknown** (`malformed_act_exclude`,
  `unknown=true`) -> fail closed, never a known self/friendly risk and never a
  silent non-exclusion. A raised table with an unreadable actor uid is likewise
  unknown (fail closed). R2-APR3-02 (rev3): the three
  function-valued fields (`block_path`, `block_radius`, `filter`) are
  type-checked — a real callback or an explicit `false` is forwarded verbatim,
  while a non-nil non-function value (string/number/boolean) is never forwarded;
  it is an explicit unknown -> fail-closed rejection
  (`malformed_function_field`) because the engine would invoke it
  (`ActorProject.lua:60,74,95-96` and the radial `typ:block_radius` calls).
  NOT forwarded, and not needed: the per-projection instance fields the caller
  sets (`source_actor`, `start_x`/`start_y`, `x`/`y`, `line_function`, `bypass`,
  `multiple`) and the shape/radius geometry the guard derives from the manifest
  component (`Target.getType` supplies those itself).
- **Every** applicable component × planned-grid footprint must expand; an
  unreadable one propagates `unknown` and the guard fails closed
  (`footprint_unavailable`, `unknown=true`). A partially-readable union is never
  measured as complete.
- Routing itself is derived from the resolved factory leaf: a mover declaration
  keeps the ordinary movement skip, a uniform stationary declaration is measured
  at every chosen grid, and only a mixed declaration needs the variant resolved
  (an indeterminate read fails closed with `movement_variant_unknown`).

### 8.4a Caller-array ingress closure (R2-APR4-01..03)

- **Checklist A everywhere on the policy/manifest ingress.** The single shared
  validator `Json.denseArray` (positive-integer keys only, no holes, no keys
  beyond the dense end) now guards every caller-supplied array BEFORE any
  `#`/`ipairs`:
  - `EffectManifest.verify` (R2-APR4-01) dense-validates the top-level `rules`/
    `sustains` and each rule's `target_plan` at the boundary entry; a sparse
    plan is the typed `target_plan_not_dense` with a diagnosable `cause`
    (`hole|non_integer_key|key_beyond_dense_end`) and the offending `key`
    (R2-APR4-01 rev5), a sparse rules list is `invalid_rules`, never measured
    as the shorter prefix.
  - `PolicySchema` (R2-APR4-02) dense-validates `rules`, `sustains`,
    `cond.all`, `cond.any` and `targeting.tie_break`. The **canonical encoding
    used for the content hash** is key-driven (not `#`-driven): a sparse/mixed/
    non-integer-keyed policy array makes `M.canonical` return `nil,cause`, so
    `M.hash` returns **no hash** rather than the shorter-prefix hash.
  - `PolicyEvaluator` (R2-APR4-02) dense-validates `policy.rules` before
    evaluation (a sparse list fails closed as `invalid_policy_rules`),
    `cond.all`/`cond.any` (a sparse branch list is UNKNOWN) and the
    `target_plan` read for the actor step selector (a sparse plan carries no
    trustworthy binding).
- **Checklist D across every generation increment** (R2-APR4-03). The five
  `generation=self.generation+1` sites in `AutoCombat.lua` are `start`, `stop`,
  `pause`, `resume` and the `awaiting_ready` promotion in `onOpportunity`.
  Each is one externally-visible transition. The Option-A safety handoff used to
  compose `pause` + `stop` (delta 2) because the service normalised a paused run
  to the terminal `stopped` state with a second transition; it now calls
  `AutoCombat:handoff(reason)`, which sets the terminal state WITHOUT advancing
  the generation (and deduplicates a same-cause replay). Every safety-handoff
  reason — `flee_below_hp_pct`, `no_emergency_action` and the queue-deviation
  reasons — therefore advances the generation by exactly 1.

### 8.4b Rev-5 review closure: the typed density code + the assistant-import ingress (R2-APR4-01 rev5, R2-APR5-01)

- **`EffectManifest.verify` emits the contracted typed density rejection.** A
  caller-supplied `target_plan` that fails `Json.denseArray` at the verify
  boundary is now `target_plan_not_dense` — never the bare generic
  `invalid_target_plan` — with a diagnosable `cause`
  (`hole|non_integer_key|key_beyond_dense_end`, from the shared
  `Json.denseFault` diagnostic; the raw `denseArray` cause is kept when no
  density fault can be named, e.g. `too_short`) and the offending `key`. A
  dense prefix plus exactly one detached key is `key_beyond_dense_end` with
  that key; a multi-key gap is `hole` at the first missing index.
  (`PolicySchema.validateTargetPlan` and the planner keep their existing
  `invalid_target_plan`+cause shape, which passed review.)
- **`AssistantAdapter` dense-closes every caller array BEFORE any
  `#`/`ipairs`/hashing** (R2-APR5-01, checklist A): `M.versionKey`
  (`assistant.addon_version`/`tome_version`) rejects a sparse tuple as the
  typed `sparse_version_array` detect refusal (field+cause+key);
  `translateCondition` dense-validates `cond.all`/`cond.any` before the child
  traversal (a sparse branch drops its whole rule with a typed
  `sparse_condition_array` report carrying branch+cause+key); `M.translate`
  dense-validates top-level `config.sustains`/`config.talents` before any
  traversal or hashing — a present but sparse/non-table list fails the WHOLE
  import as `sparse_import_array` (path+cause+key, no draft, no hash), while
  an absent list stays simply empty. A malformed import can never surface as
  a valid hashed shorter-prefix draft.
- **Boundary registry:** `tools/check_boundary_rules.py` (the
  `feat/boundary-selfcheck` provenance registry) is NOT on `main` yet — this
  branch rebased onto `main` (`ded8e1a`) per the dispatch note, and the
  registry file is still absent there. The AssistantAdapter registration
  entries are stated verbatim in the dev report so the registry owner can add
  them; against a scratch copy of that registry (with the entries applied) the
  five registered arrays all report "dense-validated at ingress" and the file
  contributes zero uncatalogued/unguarded sites.

### 8.5 Published residual limitations (§6.6/§6.7)

- `outcome_uncertainty='per_projectile_random_crit'` on the plan annotation: a
  crit may change projectile damage **and** trigger caster on-crit behaviour
  (`Combat.lua:2025-2056`). It is an annotation, never a refusal.
- Same-signature intra-group **source order** is unobservable (see §8.2).
- Fail-closed remains only for the plugin's own unreadable values/footprints, or
  for position-specific **non-random** semantics found by source review.
- A chosen grid is an aim request, not a promise about the eventual damaged
  actor/grid; projectile travel and damage settle after the answer.

### 8.6 Rebase-review closure (RA-01..07 dispositions)

Dispositions of the independent rebase review (`review-rebase-admissions.md`,
P0=P1=0; RA-04 was the dispatcher's sequencing defect, the rest Dev scope):

- **RA-04 (P2, dispatcher sequencing): closed by rebase.** Both admission
  branches are rebased onto `main@97a69d8`, so the corrected TODO entry (the
  withdrawn loop-39 "interchangeable group" equivalence claim, NOT proposal A′)
  is what the branch carries. The equivalence premise is not restated anywhere;
  §8.1/§8.2 keep the arrival-order framing (`arrival k ⇒ plan[k]`,
  index-preserving execution, per-projectile crit as an annotation).
- **RA-06 (P3): wording corrected.** The removed branch-local
  `MovementAdapterFactory.validateArray` was NOT "the same function" as
  `Json.denseArray`: its ACCEPTANCE predicate is subsumed (X-doubleprime is at
  least as strict), but the typed-cause precedence differs — the old validator
  checked `minLength` before holes and treated `Json.null` as a table (it
  reported `too_short`), while X-doubleprime decides density first
  (`non_integer_key`/`hole`), only then `too_short`, and reports `Json.null` as
  `not_array`. The stale "was the same function" comment is replaced by this
  statement (`PolicySchema.validateTargetPlan`). X-doubleprime is not weakened.
- **RA-05 (P3): service-test bypass removed.** The second `no_emergency_action`
  service scenario no longer mutates `controller.policy.rules` and clears
  `policy_snapshot` to dodge the `policy_mutated` guard; it is rebuilt through
  the real store (`set_draft → approve → activate → start`) exactly like the
  exact-delta adaptation, and additionally asserts the handoff runs on the
  guard-validated activated policy.
- **RA-02 (P2, R2-APR6-03): CLOSED — one shared typed cause vocabulary.** The
  same sparse shape is projected by all three boundaries with the SAME
  X-doubleprime density cause: `PolicySchema.validateTargetPlan` (error
  `cause`), `MovementPlanner.planSequence` (`detail` on the typed
  `invalid_target_plan`) and the runtime carrier `Actions.normalizeSequence`
  (typed `invalid_sequence` plus the additive third-return cause; a non-table
  or `Json.null` now yields the shared `not_array` instead of the bare error).
  The cause vocabulary is exactly `Json.denseArray`'s
  (`not_array|non_integer_key|hole|too_short`); layer-specific limits (the
  carrier's max 8) and non-density entry faults keep the bare typed error with
  no cause, and the two-value success/error contract is unchanged. A cross-layer
  regression drives the SAME shape through all three sinks and asserts the
  causes are equal (`tests/test_auto_combat_sequence.lua`).
- **RA-03 (P2, NOT_OBSERVED → native evidence added):** the auto-combat probe
  gains a `movement-earthen` scenario that drives the REAL
  `T_EARTHEN_MISSILES` and `T_DWARVEN_HALF_EARTHEN_MISSILES` through the real
  raised signatures — both manifest tiers (TL4: 2 prompts, TL5: 3 prompts) and
  both variants — through the production host (`host.plan` → the stationary
  plan with `outcome_uncertainty='per_projectile_random_crit'` published as an
  annotation; `host.request` → the real native bodies answer each observed bolt
  prompt with `plan[k]` in arrival order, distinct destinations per missile, no
  handback). No test-only talent is involved.
- **RA-07 (P3): stays OPEN.** No committed `tools/check_boundary_rules.py`
  registration exists on this branch; the AssistantAdapter registry rows remain
  scratch-only and the acceptance row is not claimed closed.

Raw evidence lives under `tmp/` (git-ignored); this document records only the
summary and the package sha256 of the tested archive.
