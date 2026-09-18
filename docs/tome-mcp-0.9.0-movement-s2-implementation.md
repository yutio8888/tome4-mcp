# Movement adapter factory — S2 implementation (0.9.0)

Status: **implemented on `feat/s2-ordered-queue`** (base `main@6025d93`).

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
- **Observed-request classification (rev2, S2-REV-01).** Before any answer is
  built, the observed native request is classified from the cursor spec the
  engine actually supplies and matched against the declared entry at that
  index. The engine's targeting vocabulary (`engine.Target.types_def` plus the
  `hit` sentinel) splits prompts into actor-locked shapes (`hit`/`bolt` — the
  targeting UI binds an actor entity and the answer carries one) and
  area/grid shapes (`ball`/`cone`/`beam`/`widebeam`/`wall`/`triangle`). A
  reordered or wrong-kind native flow therefore never gets the k-th declared
  answer: the mismatch is `unexpected_target_request` with
  `expected={index,request}` / `observed={index,request}`. A cursor spec whose
  shape cannot be classified unambiguously (unknown type string, non-table
  spec) is `movement_request_kind_unknown` — never a blind answer; the declared
  kind stays curated and the observed shape is used only for this match and
  the per-request native guard. An extra prompt past the declared sequence
  reports the classified observed kind instead of a synthetic placeholder.
  After any live-prompt deviation the wrapper stops answering: the remaining
  prompts of the invocation go to the player, and the settle check neither
  overwrites the recorded deviation nor reports the remaining entries as
  missing.
- Every request keeps the **native per-request range/self-warning guard**
  (`allowed(typ,x,y)`), evaluated against that request's own spec, so a value
  legal for the grid prompt but not the actor prompt stays refused. A guard
  failure is answered as the existing native target cancel
  (`command.target_cancelled`: `target_out_of_range` / `self_target_warning` /
  `target_out_of_bounds` / `invalid_target`).
- `command.target_sequence` records one bounded entry per observed request,
  including the **answered value** (`answer={x,y,uid,name}`, rev2/S2-REV-06);
  `command.target_geometry` keeps its meaning (the first observed request).
- The queue never resubmits the talent while pending.

Lowering (`Runtime.buildAutoCombatHostFor`'s `reads.execute`) maps a
`plan.kind=='sequence'` plan to `action.sequence = plan.values` (implying the
authoritative wrapper), and only when `plan.kind` is a single `grid`/`actor` does
it use the legacy single-target lowering. The production outcome mapping
preserves `target_sequence`, `reduced`, `reduced_reason` and `sequence_deviation`.

## 4. Typed deviations (§6.1)

| Condition | Behaviour |
| --- | --- |
| Extra, reordered/wrong-kind or non-optional missing prompt | `unexpected_target_request` with `expected={index,request}` / `observed={index,request|nil}` / `skippable`; pause, never resubmit. A **live** prompt is handed to the real native targeting UI for the player to answer (rev2/S2-REV-05: the wrapper falls through to the engine's own `getTarget`, whose `targetGetForPlayer` exclusive target mode is the native interactive path); a missing non-optional entry detected at settle time has no live prompt left and surfaces directly. The controller pauses and `AutoCombatService` releases the auto-combat lease (the typed deviations are in `SAFETY_PAUSES`), so the player owns the interaction. |
| An observed native request whose cursor shape cannot be classified | `movement_request_kind_unknown` with `{expected={index,request}, observed_shape}`; the live prompt is handed back, the executor pauses and the lease is released (rev2/S2-REV-01). |
| Missing **trailing optional** entry | settled native outcome with `reduced=true`, `reduced_reason='trailing_optional_not_raised'` — **not** an error. |
| A decided value cannot be evaluated (unresolvable subject actor, no planned destination) | `movement_request_value_unknown` with `{index,request,dependency}`; the prompt is cancelled (there is no value to hand the player either), the executor pauses and the lease is released — never answered with a wrong value. |
| Stall with no next prompt | bounded by the existing `native_timeout` abort (`Runtime.guardAutoInvocation`), unchanged. |
| Multi-prompt plan against an adapter with no `request_sequence` | unchanged `unsupported_target_plan`, `missing='ordered_request_sequence'`, `scope='multi_prompt'`. |

The controller (`AutoCombat.lua`) pauses with the deviation's typed reason, does
**not** add it to `rejected_landings` (a multi-prompt deviation has no single
coordinate), and never resubmits. The event reaches the bounded decision ring and
the client-visible policy log as a `paused`/`denied` detail. The typed deviations
(`unexpected_target_request`, `movement_request_value_unknown`,
`movement_request_kind_unknown`) are player-handoff pauses: `AutoCombatService`
releases the lease and stops the run, exactly like the existing safety pauses
(rev2/S2-REV-05).

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

- **Lua**: `bash tests/run.sh` (42 suites; includes the updated
  `tests/test_auto_combat_sequence.lua`, 83 checks) and the updated
  `test_effect_manifest.lua` / `test_auto_combat_movement_factory.lua` /
  `test_auto_combat_movement.lua` / `test_auto_combat_service.lua` /
  `test_runtime.lua`.
- **Python**: `server/tests` 39 OK; `tools/generate_effect_manifest.py --check`,
  `tools/generate_native_seams.py --check`, `tools/generate_protocol.py --check`
  all exit 0.
- **Native auto-combat probe** (`tests/native/auto_combat_run.py`), source and
  packaged `dist`, scenario `movement-sequence`:
  `sd_plan_sequence`, `sd_reverse_plan_rejected`, `sd_static_unsupported`,
  `sd_two_requests_ordered`, `sd_distinct_values`, `sd_second_range_refused`,
  `sd_missing_optional_reduced`, `sd_reorder_refused` (rev2/S2-REV-01). The
  `sd_distinct_values` check observes the **recorded answer values**
  (`answer={x,y,uid,name}` per prompt), not only the prompt geometries
  (rev2/S2-REV-06).
- **Native acceptance** (`tests/native/run.py`), source and `dist`: 101 checks
  passed.
- `python3 tools/package.py`: 68 files; archive = manifest = source tree, 0
  mismatches.

Raw evidence lives under `tmp/` (git-ignored); this document records only the
summary and the package sha256 of the tested archive.
