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

Matching is `typ.type == observed.cursor_type` **and** every declared flag/string
equals the observed spec's value; observed fields the signature does not declare
are ignored (they are guard inputs, not identity). This is a **drift check on
recorded fields, never an identity/closure audit** of the live object (a replaced
live entry is called as-is; §7.1/AGENTS.md). Every published sequence **must**
carry a signature on every entry; for `N≥2` the signatures must be **pairwise
distinct** — two prompts no stable observed field can tell apart make their
reorder undetectable, so the descriptor is `movement_adapter_invalid` (detail
`request_signature_ambiguous`, with the colliding indices) and is never published.
This is a plugin-completeness boundary, not a strategy judgement. Both Phase Door
TL4/TL5+ descriptors carry their real, source-verified signatures (actor
`{cursor_type='hit',friendlyblock=false,nowarning=true,default_target='self'}`,
landing `{cursor_type='ball',nolock=true,pass_terrain=true,nowarning=true}`).

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
  Because published sequences have pairwise-distinct signatures, a reordered
  native flow can never receive the k-th declared answer **for a published
  descriptor**; what this check cannot observe is the native body's internal
  consumption of an already-given answer, which stays bounded by the
  per-request native guard, the native rejection and the declared postcondition
  check. After any live handback the wrapper stops answering: the remaining
  prompts of the invocation go to the player, and the settle check neither
  overwrites the recorded deviation nor reports the remaining entries as
  missing.
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
   granted while the run is still live. The bounded abort
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
