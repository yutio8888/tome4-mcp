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
| `T_EARTHEN_MISSILES`, `T_DWARVEN_HALF_EARTHEN_MISSILES` | **ADMITTED (loop 39 R2 follow-up)** | The three same-shape `bolt` prompts are semantically equivalent (one computed `damage`, the same projectile and the same `DamageType.SPLIT_BLEED` for every prompt — spells/stone.lua:40-56; gifts/dwarven-nature.lua:35-50), so they are declared as one **interchangeable group** (`request_sequence` `group`+`equiv`, validated by `MovementAdapterFactory`). The caster never moves, so the new closed `stationary_sequence` template expresses the program (`delivery='stationary'`, `landing='none'`, `center='none'`, no traversal) without claiming a relocation, the planner lowers it into the same S2 `{kind='sequence'}` plan, and the guard measures the declared damage at every chosen grid (`stationary=true` ⇒ `AutoCombatGuard.guardStationary`, never the unconditional movement skip). The TL5 third missile is the existing `talent_level` variant matrix (2 entries below, 3 at TL5+). |

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

- **Lua**: `bash tests/run.sh` (42 suites). The ordered-queue suites:
  `tests/test_auto_combat_sequence.lua` (108 checks, includes the classifier
  falsification matrix: legal grid-via-`hit`/`actor-via-`ball` accepted per
  signature, unreadable spec ⇒ `movement_request_kind_unknown`, readable-but-
  unmatched ⇒ `unexpected_target_request` + `observed_shape`, same-kind reorder
  detected, signature-ambiguous descriptor rejected at build time);
  `test_auto_combat_movement_factory.lua` (98), `test_auto_combat_controller.lua`
  (114, includes the `native_pending` + deviation pause-before-pending case),
  `test_auto_combat_service.lua` (162, includes the lease release and the
  settle-time `nativeDeviation` delivery), `test_runtime.lua` (227, includes the
  production outcome-mapping survival, the reap-exactly-once delivery, the
  live-handle-first abort, the `authoritative_target_cancelled` regression and
  the respond/dismiss answerability after lease release).
- **Python**: `server/tests` 39 OK; `tools/generate_effect_manifest.py --check`,
  `tools/generate_native_seams.py --check`, `tools/generate_protocol.py --check`
  all exit 0.
- **Native auto-combat probe** (`tests/native/auto_combat_run.py`), source and
  packaged `dist`, scenario `movement-sequence`:
  `sd_plan_sequence`, `sd_reverse_plan_rejected`, `sd_static_unsupported`,
  `sd_two_requests_ordered`, `sd_distinct_values`, `sd_second_range_refused`,
  `sd_missing_optional_reduced`, `sd_reorder_refused`, and the S2 rev3
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

Raw evidence lives under `tmp/` (git-ignored); this document records only the
summary and the package sha256 of the tested archive.
