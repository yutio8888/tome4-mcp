# Movement adapter factory / templates (0.9.0 investigation)

Status: **proposal only**. Baseline: `main` at
`ba48e7e65d9a9b74f4172d39405ae94647e556da` (2026-09-17). This document does
not change product code, game state, `allow_auto_combat_execution`, or the
strategy/capability boundary.

## 1. Recommendation

Add a closed, source-reviewed `MovementAdapterFactory` that expands a small
template plus talent-specific parameters into the existing `movement` leaf
descriptor. Keep an explicit manifest entry for every admitted talent. Do **not**
try to discover and admit movement talents by inspecting `is_teleport`, target
shape, or talent name.

**Use the game's live getters/builders as normal entrypoints, with no strict
audit.** Planning calls the actual `t.target`/`getTalentTarget`/`getTalentRange`/
`getTalentLevel`/... functions to obtain geometry. Because Lua is dynamic any
function may be replaced by another addon; the project cannot and does not
guarantee that a runtime entry is the pristine native implementation, and is
**not responsible for other plugins' broken implementations**. So there is **no
identity/digest/closure gate**: a getter that errors, is missing or returns `nil`
simply means the value is not obtainable (`movement_derivation_unknown`/
`unknown`) and the action is unavailable. The live builder still cannot establish
actor-versus-grid semantics or the order of prompts built inside `action`, so
those stay **curated**; the source review of the action and its branches remains
the largest manual step for each new talent.

This preserves the anti-goal “no generic all-teleport adapter”: the current
contract requires every prompt to be represented by a source-reviewed, curated
target plan, and current execution rejects multi-prompt plans rather than guessing
(`docs/tome-mcp-0.9.0-movement-skills-design.md:186-212`;
`overload/mod/auto_combat/MovementPlanner.lua:390-415`).

## 2. Verified current state

- The three admitted movement leaves are hand-written entries for Rush, Tumble,
  and Phase Door; each records `target_requests`, `delivery`, `landing`, `center`,
  `traverses`, and `relocates_other`. Phase Door also has a coarse TL4+
  unsupported variant (`overload/mod/auto_combat/EffectManifest.lua:233-256`).
- The structured gap list names Blink Rune, Vault (T_SKIRMISHER_VAULT, later
  admitted in S1), Dimensional Step, Shadowstep, Giant Leap, Displacement Shield,
  and moving/swapping another actor as adapter or execution-capability gaps, not
  tactical refusals (`overload/mod/auto_combat/EffectManifest.lua:264-287`). The
  S2-R3-01 rev5 survey adds the officially-unsupported multi-prompt talents with
  their typed reasons (`moving_or_swapping_another_actor`,
  `nondeterministic_prompt_subject`, `effect_is_a_later_triggered_trap_pair`,
  `same_shape_equivalent`; corrected by the loop-38 unsupported-entry audit —
  see the S2 implementation doc's survey table for the corrected evidence). The
  *Agility*-tree
  `T_VAULT` (techniques/agility.lua) is **unsupported until S3** with the typed
  reason `movement_effect_composition_required`: its sequence is distinguishable,
  but it is a mixed movement/effect talent (the first actor prompt's target is
  attacked and may be dazed before the move), so component-free movement
  admission would expose the effect to no guard (review S2-R4-01; see the
  implementation doc §4.1 and §4.5 on main).
- Plain policy `move` is already talent-independent: selectors are generic and
  deterministic, while talent selectors reuse the same data vocabulary
  (`overload/mod/auto_combat/MovementPlanner.lua:29-52`). No factory entry is
  needed for an ordinary step.
- Policy schema accepts an ordered target plan, but the planner currently drives
  exactly one request and returns typed `unsupported_target_plan` for a longer
  plan (`overload/mod/auto_combat/PolicySchema.lua:267-310`;
  `overload/mod/auto_combat/MovementPlanner.lua:302-361,396-404`).
- Runtime lowers a grid plan to native `force_grid` and an actor plan to native
  `force_actor` (`overload/mod/mcp_bridge/Runtime.lua:1294-1313`). Engine
  `force_target` replaces `getTarget` for the whole talent action, returning
  either coordinates plus the actor or coordinates with no entity
  (`game/engines/default/engine/interface/ActorTalents.lua:152-165,179-202`).
  The alternate bridge prefill seam answers only the first `getTarget` and then
  restores native targeting (`overload/mod/mcp_bridge/Actions.lua:217-280`).
- Source files are MD5-pinned, builder source/definition lines are generated,
  and live builder objects are checked by source line plus `rawequal`; the
  recorded result is emitted as `adapter_source_drift` telemetry
  (`tools/generate_effect_manifest.py:27-84,110-145`;
  `overload/mod/auto_combat/EffectManifestDrift.lua:1-13,32-59,61-115`). **Under
  the §1/§3.1 live-getter boundary this signal is advisory telemetry only**: a
  replaced-but-working object must not disable the action, and only a
  missing/throwing/`nil`/invalid return may.
- The current guard records drift telemetry and then skips every movement entry
  because the first tranche has no movement/effect composition path
  (`overload/mod/auto_combat/AutoCombatGuard.lua:181-192`). Consequently, adding
  damage components to Shadowstep or Giant Leap without changing that branch
  would silently leave those effects unguarded.

## 3. What runtime derivation can and cannot prove

### 3.1 Live-getter boundary (v1.6): no strict audit

Planning calls the game's actual builder/getter functions directly
(`t.target`/`getTalentTarget`, `getTalentRange`, `getTalentLevel`, `getStat`,
spell-power helpers, ...) to obtain geometry and scalar parameters. There is **no
identity/digest/closure gate** on them.

- Lua is dynamic: any function may be replaced by another addon at runtime. The
  project **cannot and does not guarantee** that a runtime entry is the pristine
  native implementation, and is **not responsible for other plugins' broken
  implementations**. Requiring proof of an unbounded transitive closure is both
  impossible and out of scope.
- A getter that **errors, is missing, or returns `nil`** means the value is not
  obtainable → `movement_derivation_unknown`/`unknown` and the action is
  unavailable. This is a real "value not obtainable" condition, **not** a purity
  or identity claim.
- Source digests/identity may be retained as an **advisory re-review hint or
  optional telemetry**, but they are **never a runtime gate**.
- It must not call `useTalent` or `t.action` as a discovery probe.
### 3.2 Feasibility by class

| Class | What the builder reveals | What it does not reveal | Conclusion |
| --- | --- | --- | --- |
| No-prompt self teleport | Phase Door has no `t.target`, but its action conditionally creates an actor prompt at effective TL4 and a grid prompt at TL5 or when `phase_door_force_precise` is set (`game/modules/tome/data/talents/spells/conveyance.lua:65-84,104-147`). | Builder absence does not prove prompt absence, request order, mover, or landing envelope. | `{"none"}` must remain a curated, state-scoped request program. |
| Actor charge | Rush's builder returns a `bolt` cursor, while the action separately requires the returned entity to be a creature and computes a line landing before it (`game/modules/tome/data/talents/techniques/combat-techniques.lua:35-67`). | `type="bolt"` does not mean “actor request”; that semantic comes from the action's entity check. | Derive live geometry only; curate `actor` and `actor_charge`. |
| Grid blink | Blink's builder returns `type="hit"`; the action consumes the coordinates, ignores the returned entity, checks LOS/terrain/projection, and calls `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/misc/inscriptions.lua:646-680`). | `type="hit"` alone cannot distinguish grid from actor semantics. | Derive range/flags; curate `grid` and its landing helper. |
| Exact grid move | Tumble's builder is a `beam`, but the action treats its result as a landing coordinate and moves exactly there after native checks (`game/modules/tome/data/talents/techniques/acrobatics.lua:127-173`). | Cursor shape is not the movement request kind or landing classification. | Curate `grid_move_exact`; use the builder for conformance. |
| Grid-or-actor variant | Dimensional Step also uses `type="hit"`; an empty grid takes the self-teleport branch, while a TL5 actor may take a two-actor swap branch (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:22-81`). | The builder does not encode the TL5 occupancy-dependent semantic branch. | Curate variants; an unknown occupant cannot be resolved through hidden-state reads. |
| Actor-anchored teleport | Shadowstep uses `type="hit"`, requires an entity in the action, teleports around its coordinates, and attacks only if the final position is adjacent (`game/modules/tome/data/talents/cunning/shadow-magic.lua:109-152`). | The builder does not encode the entity requirement, fallback radius, or conditional attack. | Curate request, landing envelope, and effect components. |
| Request then landing | Phase Door builds its actor target table and later its landing target table locally inside `action`, in that order (`game/modules/tome/data/talents/spells/conveyance.lua:78-114,132-147`). | A call to `getTalentTarget` observes neither prompt and cannot discover their order. | The complete variant-specific sequence stays manual. |

There is therefore no sound automatic classifier even for the listed classes.
The builder probe is a **conformance/value provider for a curated request**, not
the source of `target_requests`.

## 4. Proposed factory and resolved-leaf model

### 4.1 Closed declarations

Proposed manifest source shape (illustrative Lua, not product code):

```lua
T_BLINK_RUNE = movementAdapter("grid_move_bounded", {
  delivery = "teleport",
  radius = {helper="teleportRandom_precise_fallback", value=5},
  traverses = false,
  builder = {required=true, request="grid"},
  components = { -- manually reviewed; not supplied by the template
    {id="out_of_phase", phase="secondary", target="self"},
  },
})
```

`MovementAdapterFactory.expand(template, params)` should be pure, reject unknown
keys, require a source record, and return either a static `movement` leaf or a
set of declarative variants. It must never scan learned talents or infer a
template from live flags. The static manifest remains the whitelist; the
existing catalog remains derived from it
(`overload/mod/auto_combat/EffectManifest.lua:289-335`).

A non-variant template expands directly to today's descriptor. A variant
template expands to:

```lua
movement = {
  variants = {
    {when={...audited scalar conditions...}, descriptor={
      target_requests={...}, delivery=..., landing=..., center=...,
      radius=..., min_radius=..., traverses=..., relocates_other=...,
    }},
  },
}
```

Immediately before planning, a `MovementVariantResolver` evaluates the allowed
conditions and returns exactly one descriptor in the **current** shape. Zero,
multiple, or indeterminate matches return a typed unknown; no ordering fallback
is allowed. This generalizes the current effective-level-only unsupported check,
which already fails closed when the level is unavailable
(`overload/mod/auto_combat/MovementPlanner.lua:282-299`).

### 4.2 Template taxonomy

All defaults below are mechanical, not strategic. Curated semantic source
coverage, builder mode, helper dependencies, variants, and non-movement
components are always explicit per talent (recorded identity/digest is
advisory metadata, not a gate).

| Template | Required parameters | Mechanical defaults | Resolved current `movement` mapping |
| --- | --- | --- | --- |
| `actor_charge` | `landing_proof`; optional effect components | `target_requests={'actor'}`; `delivery='line_move'`; `landing='bounded_alternatives'`; `center='actor'`; `traverses=true`; `relocates_other=false` | Direct mapping. Rush is the reference class; the source action computes the last legal line cell before the actor (`game/modules/tome/data/talents/techniques/combat-techniques.lua:48-83`). |
| `grid_move_exact` | `delivery`; explicit `traverses`; native rejection/postcondition notes | `target_requests={'grid'}`; `landing='exact'`; `center='requested_grid'`; `relocates_other=false` | Direct mapping. Tumble and Vault differ in delivery/prerequisites, not descriptor shape (`game/modules/tome/data/talents/techniques/acrobatics.lua:61-117,160-182`). |
| `grid_move_bounded` | `delivery`; finite `radius` or audited radius getter; alternate-selection helper; explicit `traverses` | `target_requests={'grid'}`; `landing='bounded_alternatives'`; `center='requested_grid'`; `relocates_other=false` | Direct mapping. Use for `teleportRandom(...,0)` and occupied-cell leap fallback; annotate native random tie-break separately. |
| `self_random_teleport` | finite radius getter/value and its helper proof; optional minimum | `target_requests={'none'}`; `delivery='teleport'`; `landing='random'`; `center='self'`; `min_radius=0` only when the reviewed native call omits it; `traverses=false`; `relocates_other=false` | Direct mapping after dynamic values resolve. Phase Door's radius comes from `t.getRange`, not from the cursor range (`game/modules/tome/data/talents/spells/conveyance.lua:74-76,104-107,146-148`). |
| `actor_anchor_teleport` | finite radius/getter; post-landing relation; effect components | `target_requests={'actor'}`; `delivery='teleport'`; `landing='bounded_alternatives'`; `center='actor'`; `traverses=false`; `relocates_other=false` | Direct mapping for self movement around an actor. Shadowstep is the reference class (`game/modules/tome/data/talents/cunning/shadow-magic.lua:127-149`). |
| `request_then_landing` | complete ordered request list per variant (`request_sequence`, §4.4); subject binding; every landing branch/envelope; explicit `relocates_other`; prompt-response validation | No request order, center, bounds, or subject defaults | Each resolved variant becomes the current leaf, plus the closed `request_sequence` the ordered prompt-response queue consumes (§4.4). A variant without a `request_sequence` is still executable only for N=1; N≥2 without one is `unsupported_target_plan`, `missing='ordered_request_sequence'`. Phase Door TL4/TL5 is the reference class (`game/modules/tome/data/talents/spells/conveyance.lua:82-147`). |
| `swap` | request kind; both actor identities; hit/resist/fizzle branches; two-actor destination relation; postconditions | `delivery='teleport'`; `relocates_other=true`; no landing or request defaults | **Cannot map losslessly to today's single-subject descriptor.** Keep typed unsupported until the descriptor and executor model two subjects. Dimensional Step TL5 is the reference class (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:48-79`). |

`grid_move_bounded` deliberately covers both leap and teleport delivery; a new
template is justified only when it adds a reusable invariant, not merely a new
talent name. Conversely, `request_then_landing` is not a generic escape hatch:
it requires the entire prompt program and all branches to be curated.

### 4.4 Ordered request sequences (S2)

A `request_then_landing` descriptor declares its prompts as a closed, ordered list. The
list is curated data, never inferred. The engine's cursor geometry is **not** a sound
request-kind classifier: `hit` is documented as "hit a single grid in LOS"
(`engines/default/engine/Target.lua:634`), `setSpot` populates `target.entity` from the
selected cell for every geometry (`Target.lua:731-732`), the cursor's `entity` starts
as the caster for every geometry (`engine/interface/GameTargeting.lua:28-33`), and the
same shapes are consumed with opposite semantics by reviewed talents — Dimensional Step
raises a grid request with `type="hit"` (`game/modules/tome/data/talents/chronomancy/
spacetime-weaving.lua:29-46`), Rush an actor request with `bolt`, Tumble a grid landing
with `beam`, Phase Door an actor request with `hit` (`spells/conveyance.lua:78-84`);
see §3.2 ("no sound automatic classifier", `:107-109`). The *expected* kind at each
position therefore comes only from the source review, and the review must also curate,
per entry, the entry's **observed signature** — the stable, distinguishing fields of
the cursor spec that prompt actually raises — which is the only runtime evidence the
bridge matches against (§6.1).

```lua
request_sequence = {
  { index=1, request='actor', subject='self',
    observed={cursor_type='hit', default_target='self'} },
  { index=2, request='grid', subject='self', value_source='target_plan',
    landing_from='envelope', optional=true,
    observed={cursor_type='ball', nolock=true} },
}
```

Phase Door's prompts are the worked example: the actor prompt is
`{default_target=self, type="hit", friendlyblock=false, nowarning=true,
range=getTalentRange}` (`spells/conveyance.lua:78-84`) and the landing prompt is
`{type="ball", nolock=true, pass_terrain=true, nowarning=true, range=getRange,
radius=getRadius}` (`:105-107`); their `cursor_type` values alone already
distinguish them. Dynamic numerics (`range`, `radius`) are never signature fields.

- `index` is explicit and must equal the array position; a hole, gap or reorder is
  `movement_adapter_invalid`. `request_sequence` and `target_requests` must agree in
  length and kind (a mismatch is `movement_adapter_invalid`), and a declared
  `target_requests` must be a closed dense `1..n` array, so every existing consumer
  of `target_requests` — `EffectManifest.requestSequences`, the static policy validator
  and the capability summary — keeps working unchanged
  (`overload/mod/auto_combat/EffectManifest.lua:363-384,485-566`).
- `request` is one of `actor`/`grid`/`self` — **`none` is not a declarable `request_sequence` entry**
  (a prompt-less talent declares no `request_sequence` at all; `none` remains valid only for the N=1
  `target_requests` leaf produced by `self_random_teleport`/similar, §4.1). Declaring `none` in a
  `request_sequence` is `movement_adapter_invalid`; the earlier draft's `TARGET_REQUESTS (... none ...)`
  wording was superseded by the S2 rev2 decision (`tmp/mcp-play-support/s2-fix1-dev-report.md`).
- `subject` is the binding of the answer: `'self'` always answers with the caster cell,
  `'actor'` with the policy's decided actor. Phase Door's Phase-1 default is the caster
  (`game/modules/tome/data/talents/spells/conveyance.lua:79`), and its Phase-1 result may
  replace the subject with the requested cell's occupant (`:90`).
- `value_source='subject'` (default) repeats the subject; `value_source='target_plan'`
  takes the value from that step's own policy `target_plan[i]`
  (`selector`/`destination`), i.e. a **distinct** decided value. This is the only reason
  the queue is needed: the merged authoritative prefill answers *every* native request
  with one value (`overload/mod/mcp_bridge/Actions.lua:230-233,267-304`), which cannot
  express “actor prompt ⇒ the caster, landing prompt ⇒ this coordinate”.
- `landing_from='envelope'` annotates the landing from the declared envelope
  (`radius`/`min_radius`/`fallback_center`/`fallback_radius`) instead of an exact cell.
- `observed` is the per-entry curated signature of the prompt the reviewed native flow
  raises at this position: `cursor_type` (required, the `typ.type` string the action
  passes) plus optional static discriminators from a closed allowlist — boolean flags
  `nolock`/`pass_terrain`/`friendlyblock`/`nowarning`/`immediate_keys`/`no_restrict`,
  `first_target`, `msg`, and `default_target='self'`. **Signature semantics
  (normative, S2-R3-01 rev5): the signature is PRESENCE-EXPLICIT, not a wildcard
  predicate.** `cursor_type` is always an equality constraint; a DECLARED boolean flag
  must be PRESENT in the observed spec and EQUAL (so `{cursor_type='hit'}` does not
  match a prompt that raises `nolock`, and a declared `nolock=false` requires the key
  present with value `false`, distinct from absence — Vault's two prompts
  (techniques/agility.lua:113,119) differ exactly by nolock presence and are therefore
  cleanly distinguishable); an UNDECLARED boolean flag must NOT be raised by the
  observed spec; a declared string (`first_target`/`msg`) or `default_target='self'`
  must be present and equal when declared, and when the signature omits them the
  observed value is **ignored** — real flows raise them nondeterministically (Phase
  Door's `first_target` is rng.percent-driven, conveyance.lua:85), so they are never
  required-absent and never discriminate by absence. Observed fields outside the
  allowlist (range/radius/closures) are ignored (guard inputs, not identity). The
  normative runtime gate is the executor's **EXACTLY-ONE rule** (§6.1): a raised
  prompt may be answered only when exactly one declared entry — the arrival position
  — matches it; zero matches, several matches, or a match at another index are typed
  deviations that pause and hand the live prompt back. The build-time checks keep
  only what is decidable by inspection: every published entry must carry a
  signature, and for a sequence of N≥2 entries no entry's signature may **SUBSUME**
  another's (equal flag constraint sets and the subsumer declaring no additional
  strings) — a subsumed entry can never be the unique match of any prompt, so the
  descriptor is `movement_adapter_invalid` (detail `request_signature_ambiguous`,
  with the colliding indices). The signature detects drift from the reviewed flow as
  recorded; it is not an identity audit of any live object (§7.1) and it never
  claims geometry proves actor/grid semantics (§3.2).
- `optional=true` marks a **trailing** entry the native flow may legitimately not raise.
  A missing `optional` trailing prompt is a settled native outcome (reported with
  `reduced=true`), **not** an error; a non-trailing `optional` entry is
  `movement_adapter_invalid`. A missing non-optional prompt is
  `unexpected_target_request` (see §6.1).

A variant that can raise 1, 2 or N prompts is expressed by the existing variant matrix —
one branch per reviewed state — not by a partial sequence (§4.1). Phase Door's Phase-2
gate is `getTalentLevel(t) >= 5 or attr("phase_door_force_precise")`
(`game/modules/tome/data/talents/spells/conveyance.lua:108`); at effective TL5 the first
disjunct is statically true from the same effective-level read the variant resolved, so
the TL5 branch declares `{'actor','grid'}` unconditionally, while the TL4 cell may declare
the second entry `optional=true` or be split into two explicit attribute branches. Either
form is admitted; exactly one descriptor must resolve and the trailing-optional rule is
the bound that keeps a genuinely missing prompt from passing silently.

**Execution model (normative).** The queue lives *inside one action opportunity and one
native submission*; it never resubmits the talent while pending. The executor arms the
queue on the single `useTalent` call and answers the k-th observed `getTarget` with the
k-th declared entry's decided value, keeping every existing per-request guard:

- the native range guard and the self-warning check are evaluated **for that request's
  own spec** — Phase Door's actor prompt carries `range=getTalentRange` (10 at TL≥4,
  `:75,84`) while its landing prompt carries `range=getRange` and `radius=getRadius`
  (`:106-107,114`), so a value legal for the second prompt but not the first stays
  refused;
- a value that fails the guard is answered as a native target cancel carrying the typed
  reason (existing `command.target_cancelled`, `overload/mod/mcp_bridge/Actions.lua:297`
  surfaced at `:330-334`);
- the raised prompt is checked against the declared program by the normative
  runtime **EXACTLY-ONE rule (S2-R3-01 rev5)** before any answer is built: the
  executor computes the set of declared entries whose curated observed signature
  matches the prompt and answers only when that set is exactly the arrival position.
  Zero matches (extra/drifted prompt), several matches (ambiguous declaration), or a
  match at another index (reordered flow) are a typed deviation
  (`unexpected_target_request` with the expected/observed index, the observed shape
  and the matched indexes) — the live prompt is handed back, never a blind answer of
  the k-th declared value. Cursor geometry alone is never used as actor/grid evidence
  (§3.2: no sound automatic classifier exists). A spec the bridge cannot read as a
  signature (`typ` not a table or `typ.type` not a string) is
  `movement_request_kind_unknown`. For the **specifically curated** published
  descriptors whose pairs differ by a declared discriminator, the two positions are
  distinguishable by construction (Vault's two `hit` prompts by `nolock` presence;
  Phase Door's by cursor type), so those descriptors cannot answer a reordered
  native flow with the k-th declared value. That construction argument holds **only
  for a curated pair**, not for an arbitrary accepted declaration: the build check
  rejects only subsumption, so an overlapping (yet non-subsuming) declaration — for
  example `{cursor_type='hit',first_target='friend'}` beside
  `{cursor_type='hit',msg='aim'}` — is admissible and both signatures match one
  prompt carrying both strings. For every accepted declaration the guarantee comes
  from the **runtime exactly-one gate** above: the ambiguous prompt matches several
  entries, so it is handed back rather than answered, and a wrong answer is
  prevented at execution time whether or not the declaration was distinguishable by
  construction. What this check cannot observe is the native body's internal
  consumption of an already-given answer, which remains the native flow's own
  behaviour and is bounded by the per-request native guard, the native rejection, and
  the declared postcondition check (§6.1);
- a native flow that never raises the next prompt and never returns is bounded by the
  existing `native_timeout` abort
  (`overload/mod/mcp_bridge/Runtime.lua:50-52,2044-2078,2081-2104`).

The observed request sequence is recorded for evidence on the command
(`target_sequence`, one bounded entry per observed request) while `target_geometry`
keeps its current meaning (the first observed native request). Planning, dry run and the
committed decision reuse the existing movement report: `requests` (the declared kinds),
`landing` (`kind='random'|'bounded'`, center, radius, and the LOS-fallback envelope) and
the same player-known fields. A random or out-of-vision landing remains an
**annotation**; whether it is acceptable is the policy's `destination.accept` result, as
in §6.1.

### 4.3 Manual fields that do not belong in templates

The following remain per-talent review output:

- exact request semantics and order for every effective-level/attribute/occupancy
  variant; native cursor `type` is insufficient (§3.2);
- the mover/subject and whether another actor can be moved, removed, swapped, or
  restored on failure;
- landing cardinality and a finite envelope, including center, radius,
  `min_radius`, fallback centers, LOS-dependent fallback, and helper selection;
- whether movement traverses intervening cells or relocates directly;
- ground, instant, projectile, attack, secondary, and delayed components,
  including their center relative to the **actual** landing;
- every state condition that changes prompts or outcomes (effective talent level,
  attributes, target occupancy, inscriptions/modifiers, and helper overrides);
- semantic source coverage for the definition, action, builder, dynamic getters,
  and transitively relied-on helpers; recorded file digests, definition lines,
  and live-object identities are **advisory re-review/telemetry metadata**, not
  runtime gates (see §3.1); and
- native rejection, energy/pending semantics, and final postconditions.

These are execution semantics, not policy preferences. Templates may provide
field defaults only where the category itself proves them.

## 5. Landing envelopes and mixed effects

ToME's module override for `teleportRandom(x,y,0)` first calls
`findFreeGrid(x,y,5,...)` (`game/modules/tome/class/Actor.lua:1631-1647`).
`findFreeGrid` chooses a closest candidate and uses RNG among equal-distance
candidates (`game/engines/default/engine/utils.lua:2943-2981`), after which
`teleportRandom` again makes a native random choice from its candidate set
(`game/modules/tome/class/Actor.lua:1652-1687`). The factory should therefore
classify these calls as `bounded_alternatives`, radius 5, with a
`native_random_tie_break` annotation—not as exact merely because the call's
`dist` argument is zero.

The envelope must be conservative and finite. Uncertain occupancy, hazard, or
which point inside a proven envelope native code chooses is policy information;
it remains annotated and is evaluated by `destination.accept`. An unresolvable
envelope is different: the executor cannot check the final postcondition, so the
adapter is unavailable before commit.

Mixed movement/effect talents are executable when the closed composition model below
(S3) is in place. Normative, in force as of the S3 slice:

### 5.1 Mixed movement/effect composition (S3)

A mixed movement talent is a manifest movement entry whose `components` array is
**non-empty**. No new field is introduced for the effect list: the entry keeps its
S1/S2 movement descriptor (`movement=movementAdapter(...)`) and carries its effect
components in the same closed component record vocabulary the hostile entries use
(`overload/mod/auto_combat/EffectManifest.lua:62-355`).

**Closed component vocabulary for `kind='movement'` entries** (normative narrowing):

- `components` contains only effect components — phases `instant`/`projectile`/
  `secondary`/`ground`. No `cursor` components (cursor/landing geometry is the
  movement descriptor's, via the factory and `resolveBuilder`).
- A single-target pre-move melee strike is declared `phase='melee'`,
  `delivery='attackTarget'`, `shape='hit'`, `center='target'` with no filters,
  exactly like the admitted melee entries (T_ATTACK,
  `overload/mod/auto_combat/EffectManifest.lua:118-123`). It is risk-exempt
  (`EffectRisk.lua:47-49,63`) but is **declared and recorded** — never invisible.
- A multi-actor effect anchored to the landing must use `delivery='project'` with
  explicit `selffire`/`friendlyfire`; `delivery='attackTarget'` is forbidden for
  such components because that delivery is risk-exempt and would hide the AoE.

**Two closed vocabulary additions** (internal guard/factory vocabulary only; no
protocol field and no policy field changes):

1. `center='actual_landing'` — the effect center is the mover's **actual** post-settle
   cell. Admitted only with `shape='hit'` or `shape='ball'` and a finite radius (or
   `{from='target'}` from the live builder); any other shape with this center is
   `movement_adapter_invalid` at build time (the plugin's own completeness boundary).
2. `when.kind='landing_adjacent'` with `anchor='actor'` — a guard condition vocabulary
   (distinct from the factory's variant-axis `validateWhen`): the component is active
   only when the mover's final cell is at distance 1 (`Distance.grid`) from the named
   anchor. Pre-commit it is resolved conservatively against the landing candidate set;
   an indeterminate resolution keeps the branch in the union
   (`AutoCombatGuard.lua:30-46` pattern).

**Landing candidate set (the `actual_landing` quantifier).** The guard quantifies the
effect over every cell the mover can actually occupy at settle:

- With `attempt.plan` (the normal path; all three guard call sites carry it):
  `plan.kind='grid'` + `landing.kind='deterministic'` → the single cell;
  `landing.kind='bounded'`/`'random'` → the circle (`Distance.grid`) around
  `landing.center` with `landing.radius`. `min_radius` is deliberately ignored for the
  union (including the inner ring is a conservative superset). A `sequence` plan uses
  its last step's landing annotation
  (`overload/mod/auto_combat/MovementPlanner.lua:580-604`). A missing/unreadable
  landing annotation is incalculable → fail closed (plugin-own), detail
  `reason='landing_envelope_unavailable'`.
- Without `attempt.plan`: the candidate set is derived from the descriptor envelope —
  `center='actor'` → the circle around the bound actor; `center='self'` → around the
  caster; `center='requested_grid'` → incalculable without a plan → fail closed
  (plugin-own, new internal reason `movement_plan_unavailable`).
- Cell knowledge for the unknown-occupancy rule is the same player-known `ctx.known`
  read the guard already uses (`AutoCombatGuard.lua:132-140`); no hidden state is read.

**Union and membership (normative).** For `center='actual_landing'` components the
pre-commit union is computed by **complete pair expansion**, never by the analytic
circle:

1. enumerate the finite landing candidate set `L` from the declared envelope;
2. for every active risk-bearing component `c` and every candidate `l` for which `c.when`
   may hold, expand `spec(c,l)` through the existing native backend
   (`EffectFootprint.expand`, `overload/mod/auto_combat/EffectFootprint.lua:290-300`);
3. union only after **all** required expansions succeeded;
4. one `nil` expansion, a malformed spec, an unreadable radius, an unavailable anchor or
   an incomplete enumeration **discards the partial union** and yields unknown
   membership (`selffire_risk` with `unknown=true`, or `movement_plan_unavailable` when
   the candidate set itself is undecidable).

**[CORRECTED 2026-09-18]** An earlier revision of this section prescribed the analytic
`circle(center, envelope_radius + r)` as a conservative superset. That is **false**: the
native backend applies **per-center** line/radius blocking (`block_radius` evaluated per
cell, `calc_beam_any_angle` rooted at the candidate's own `start_x/start_y`), so a
blocker beside one candidate can remove cells that the analytic circle would still claim;
`expand` also returns `native_failed` rather than falling back. Measuring such a partial
or analytic union would **understate** friendly/self risk — the exact fail-open class the
S3 review flagged. The analytic circle may remain **only** as a test oracle asserting that
the complete union is *contained* in it, never as the production expansion (Designer plan
`tmp/mcp-play-support/s3-design-arm2.md` D1, sha256 `4c2d3bffd12c323036e83fc86ec1d714cdfa08eb4ff0a083917cf4a5ae771a28`). For
`center='actual_landing'` components self-membership is evaluated as `candidates ∩
union ≠ ∅` (conservatively `true` when either side is unknown) instead of containment at
the mover's **current** cell — the mover will have moved (`AutoCombatGuard.lua:117`
tests the current cell and must not be used for these components). Friendly membership
counts allies inside the union; unseen grids inside it are unknown occupancy and fail
closed (`:123-140`, unchanged). The live builder's instant-geometry override
(`AutoCombatGuard.lua:283-293`) is **not** applied to movement entries' effect
components: their geometry is the curated record plus the live radius getter
(`{from='target'}`); the builder is consumed only by planning (`resolveBuilder`) and by
the per-request native guard at answer time.

**Guard dispatch (normative).** The unconditional movement skip
(`overload/mod/auto_combat/AutoCombatGuard.lua:185-187`) becomes:

```lua
if entry.kind=='movement' then
    if #(entry.components or {})==0 then return nil end  -- pure movement, unchanged
    -- mixed entry: fall through to the composition path
elseif entry.target~='hostile' then return nil end

## 6. Fail-closed and policy-annotation rules

### 6.1 Typed outcomes

| Condition | Proposed typed result | Scope |
| --- | --- | --- |
| Unknown template, missing required parameter, or malformed expansion | `movement_adapter_invalid` | Build/test failure; never publish the adapter. |
| Builder/action/getter/helper missing, throwing, returning `nil`, or wrong type | `movement_derivation_unknown` with `dependency` detail (a replaced live object is only telemetry; its usable return value decides) | Disable this action before commit. |
| Builder is valid but a raised prompt cannot be read as a signature (`typ` not a table or `typ.type` not a string) | `movement_request_kind_unknown` with `{index, request, observed_shape=nil}` | Disable this action for this run and pause with the live prompt handed back; never infer actor/grid from cursor shape (§3.2). |
| No variant, multiple variants, or a level/attribute read that errors or returns `nil` | `movement_variant_unknown` with the unresolved condition | Disable this action before commit. |
| Policy target plan differs in length/order/kind | existing `target_plan_mismatch` / `target_plan_selector_mismatch` | Policy validation error or action denial. Existing exact comparison is at `overload/mod/auto_combat/EffectManifest.lua:427-456`. |
| Adapter declares a valid multi-prompt plan but executor lacks the queue | existing `unsupported_target_plan`, `scope='multi_prompt'` | Capability pause/denial before commit (`overload/mod/auto_combat/MovementPlanner.lua:396-400`). |
| Native asks for an extra, missing, reordered, or signature-mismatched prompt after commit starts | `unexpected_target_request` with `expected={index,request}`, `observed={index,request|nil}`, `observed_shape`, and `skippable` for a missing entry; matching is against the entry's curated observed signature (§4.4), never a global shape→kind map | Pause and stop the executor, never resubmit, release the lease via the safety-pause path, and hand the live interaction back to the player/caller (§6.2); a missing **skippable trailing** entry (`optional=true`, §4.4) is a settled native outcome reported with `reduced=true`, not this code. |
| A declared entry's decided value cannot be evaluated at answer time (unresolvable subject actor, or a `value_source='target_plan'` step with no planned destination) | `movement_request_value_unknown` with `{index, request, dependency}` | Pause the executor before answering with a wrong value; this is the plugin's own uncomputability boundary, never a strategy refusal. |
| A multi-prompt plan resolves against a descriptor that has no `request_sequence` (not yet upgraded, including every S1 talent) | existing `unsupported_target_plan`, `missing='ordered_request_sequence'`, `scope='multi_prompt'` | Capability pause/denial before commit; unchanged from the current behaviour. |
```

**ANCHOR (find, line 248, unchanged — listed for sequence only):**

```
| Adapter declares a valid multi-prompt plan but executor lacks the queue | existing `unsupported_target_plan`, `scope='multi_prompt'` | Capability pause/denial before commit (`overload/mod/auto_combat/MovementPlanner.lua:396-400`). |
```

*Optional factual correction (the baseline citation has drifted):* the cited
`MovementPlanner.lua:396-400` now precedes the check; the live multi-prompt rejection is
at `overload/mod/auto_combat/MovementPlanner.lua:514-519` and the variant-branch typed
reason at `:395-401 [baseline citation]`. If the dispatcher prefers minimal normative
churn, leave the row as is; the correction is not load-bearing.

| Landing kind/center/bounds cannot be proved | `movement_landing_envelope_unknown` | Disable this action before commit. (In the implemented factory this surfaces as `movement_derivation_unknown` from the envelope getter/`resolveBuilder` reads, `overload/mod/auto_combat/MovementAdapterFactory.lua:551-596`.) |
| Actual mover or endpoint falls outside the resolved descriptor after commit | `movement_postcondition_mismatch`, `uncertain=true` | **Implemented in S3 for mixed movement entries** (the first real implementation of this row; extending it to exact S1 movers is a follow-up). The host checks the settled player position against the declared landing envelope after the native body settles, and the controller pauses with this reason; a curated fizzle-with-success branch (`movement_postcondition.fizzle_keeps_position=true`, e.g. Shadowstep's fizzle, `cunning/shadow-magic.lua:139`) is a settled outcome, not a mismatch. Internal pause reason — not a `protocol/v4` code (the S2 precedent: `unexpected_target_request` also rides the pause/detail surface). |
| Template needs to move/swap another actor but the typed capability is absent | `moving_or_swapping_another_actor` | Publish as unsupported capability. |
| Mixed effect footprint cannot be computed (native expansion failure, unseen-grid occupancy, unreadable radius, missing landing annotation) | existing `selffire_risk` with `unknown=true` + component detail (`phase`, `component`, `provenance`, `footprint_backend`) | Disable this action only; `EffectRisk` unknown dominance (`EffectRisk.lua:34-44,95-101`) and the fail-closed branch (`AutoCombatGuard.lua:315-340`) are unchanged. |
| A mixed entry reaches the guard with no plan and an undecidable candidate set (`center='requested_grid'` without a plan) | new internal reason `movement_plan_unavailable` | Disable this action only; plugin-completeness boundary, never a strategy refusal. |
| A component's target/geometry does not match the curated declaration (non-`hit`/`ball` shape with `center='actual_landing'`, unknown key, envelope/`request_sequence` disagreement) | build-time `movement_adapter_invalid` | Never publish the adapter (`MovementAdapterFactory.lua:223-355` closed-record checks); at runtime a drifted builder/getter remains `movement_derivation_unknown`/`adapter_builder_failed`, never a gate. |

Once request program, semantic coverage, and landing envelope are established,
`visible=false`, `passable='unknown'`, `hazard='unknown'`, and a native-random
choice are annotations. `MovementPlanner.accepts` already treats visibility,
passability, hazard, and deterministic-vs-nondeterministic landing as explicit
policy filters (`overload/mod/auto_combat/MovementPlanner.lua:80-107`). A strict
policy may reject the same report that a permissive policy accepts; neither
outcome changes adapter capability.

### 6.2 Pre-commit versus post-commit

All static/derivation faults are resolved before `Actions.execute`. If the exact
native prompt sequence can be preflighted, a mismatch never starts the action. If an
adapted action has already yielded to a live native prompt and then produces a
mismatch, the executor hands the prompt back to the real native targeting UI, and the
typed deviation must be delivered to the controller **inside the same submission**,
not after the pending native call settles: `Actions.execute` attaches
`sequence_deviation` (and `target_sequence`, `handed_back`) to its `native_pending`
result (`overload/mod/mcp_bridge/Actions.lua:671-672`); the controller checks the
deviation **before** its `native_pending` branch and pauses with the typed reason
(`overload/mod/auto_combat/AutoCombat.lua`, deviation check before the
`native_pending` branch); and `AutoCombatService` then stops the run and revokes the
lease through the existing safety-pause path
(`overload/mod/auto_combat/AutoCombatService.lua:480-487`). While the prompt is handed
back live, `command.target_cancelled` is **not** set — a still-live prompt is neither
answered nor cancelled — the executor records `command.target_handed_back` instead,
and the bounded abort cancels a live target handle first, treating
`target_cancelled` as authoritative only when no live handle remains
(`overload/mod/mcp_bridge/Runtime.lua:2073-2105`). After the lease is released, the
handed-back interaction is answerable by the caller through the existing
respond/dismiss routing extended to the auto invocation's current handle, with the
command-scoped response guards preserved unchanged (S2-R3-02: the response
fingerprint is computed before both routes, a reused `response_id` is classified
conflict-vs-idempotent before the consumed checks, and every auto answer is counted
and bounded by `Interactions.MAX_RESPONSES`); if nobody
answers, the existing `native_timeout` bound force-cancels it
(`overload/mod/mcp_bridge/Runtime.lua:2110-2134`). This preserves the rule that
`native_pending` is tracked without resubmission
(`docs/tome-mcp-auto-combat-plugin-design.md:256-263`).

## 7. Source records and advisory drift telemetry

### 7.1 Pin set

Extend the generated source record for each movement adapter with:

- whole-file MD5 plus talent definition line (already generated) — kept as an
  **advisory re-review hint/telemetry**, never a runtime gate;
- live `t.action`/`t.target` source/line (advisory);
- the live getters used by a parameter (`getRange`, `getRadius`,
  effective-level/state getters) are called directly at planning time with **no
  identity gate**; a missing/erroring getter yields `movement_derivation_unknown`;
- engine/module helpers invoked by the action (`canProject`, `teleportRandom`,
  `findFreeGrid`, ...) are ordinary calls; and
- the action-commit/targeting seams already recorded by `NativeCompatibility`
  (as advisory metadata; the project calls the live seam, it does not gate on it).

The present generator records semantic source coverage for complete engine
semantics files and selected talent builders
(`tools/generate_effect_manifest.py:63-84,125-143`); the drift checker may recheck
live builder identity as **telemetry** before a guarded action
(`overload/mod/auto_combat/EffectManifestDrift.lua:117-148`), but a mismatch is
reported, never used to deny an action. The proposed change extends the same
**review-metadata** mechanism to action/getter/helper records; it does not create
a separate trust system, and it introduces no runtime gate.

### 7.2 Runtime probe rules

The runtime probe calls the game's actual live getter/builder objects directly,
under `pcall`, and copies only allowlisted scalar/table fields. An error,
non-table builder result, non-finite bound, or `nil` value becomes typed unknown
and disables the one action. A replacement object, changed helper closure, or
source digest mismatch is **not** itself a denial: the probe simply uses the live
object and judges its usable return value. Recorded identity/digest information
is advisory re-review telemetry (§3.1).

No “purity” or RNG tripwire is added. Deterministic policy choice still uses
stable ranking, while the live native getters/builders may consume RNG under the
frozen read policy (`docs/tome-mcp-auto-combat-plugin-design.md:365-373,424-443`).

## 8. Candidate disposition

| Candidate / variant | Template and derived fields | Fields still curated | Disposition |
| --- | --- | --- | --- |
| `T_BLINK_RUNE` | `grid_move_bounded`; live builder supplies `range` and cursor flags. Resolved leaf: `{'grid'}`, `teleport`, `bounded_alternatives`, `requested_grid`, radius 5, `traverses=false`, `relocates_other=false`. The action calls `teleportRandom(x,y,0)` and then grants Out of Phase (`game/modules/tome/data/talents/misc/inscriptions.lua:646-680`); radius-5 fallback comes from `game/modules/tome/class/Actor.lua:1642-1647`. | Grid semantics; LOS/terrain/projection path; helper coverage; inscription-data-dependent secondary buff and its postcondition. | **Supportable with the factory** after source review and helper coverage. Native uncertainty is annotated, not refused. |
| `T_SKIRMISHER_VAULT` | `grid_move_exact` with `delivery='leap'`, `traverses=false`; builder supplies live beam/range. The action adds a launch-target check, rejects blocked/unprojectable landing, and moves exactly to the requested grid (`game/modules/tome/data/talents/techniques/acrobatics.lua:27-56,61-117`). | The adjacent visible launch-actor prerequisite is action-local; exact native rejection behavior and the post-move Directed Speed effect stay manual. | **Supportable with the factory**. Native prerequisite failure is a normal rejection, not a new strategy gate. |
| `T_DIMENSIONAL_STEP`, effective TL below 5 | `grid_move_bounded` with `delivery='teleport'`, radius 5 and live builder range. The non-swap branch calls `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:22-46,73-84`). | Effective-level variant, requested-grid occupancy semantics, helper coverage, teleport callbacks/postcondition. | **Supportable for a source-proven non-swap variant**. If occupant status needed to choose the branch is player-unknown, return `movement_variant_unknown`; do not inspect a hidden actor. |
| `T_DIMENSIONAL_STEP`, TL5 actor target | `swap` candidate. The action may remove the target, teleport the caster, move the target to the old caster cell, or restore it on failure after resistance/hit checks (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:48-72`). | Both actor identities, probability/resistance branch, removal/restoration atomicity, two endpoints, effects, and postconditions. | **Remain unsupported** as `moving_or_swapping_another_actor` until typed two-actor execution and verification exist. |
| `T_SHADOWSTEP` | `actor_anchor_teleport`; live builder supplies range/cursor (`{type="hit", range=getTalentRange, talent=t}`, `cunning/shadow-magic.lua:123`). Leaf: `{'actor'}`, `teleport`, `bounded_alternatives`, `actor`, radius 5, `min_radius=0`, no traversal/other relocation — `teleportRandom(x,y,0)` around the target cell is the precise path with the `findFreeGrid(x,y,5)` nearest-free fallback (`mod/class/Actor.lua:1644-1646,1659-1681`). | Entity/LOS pre-checks (`shadow-magic.lua:131-137`); the fizzle-with-success branch (`:139`, `return true`, no move); the two adjacency-conditional post-landing components (`:142-149` — `landing_adjacent` when-gate, single-target strike + daze on the anchor actor). | **S3-admitted** with the S3 composition model (§5.1): the effect components are declared, guarded (`landing_adjacent` condition resolved against the candidate envelope), and their post-settle evidence observed; no `actual_landing` component is needed (the effect targets the anchor actor only). |
| `T_GIANT_LEAP` | `grid_move_bounded` with `delivery='leap'`, `traverses=false`, radius 1 (landing alternatives), `builder_shape='ball'`, `no_energy`. Empty requested grid lands exactly; occupied falls back to `findFreeGrid(x,y,1)` nearest-free (`uber/str.lua:47-50`). | Occupancy-branch annotation; the radius-one weapon/daze component `center='actual_landing'`, `radius={from='target'}`, `selffire=0` (explicit `str.lua:39` + body exclusion `:65`), `friendlyfire=100` (unfiltered projection `:63-71`); unioned pre-commit footprint = `circle(requested, 1+1)`; `movement_postcondition` (success always moves — `:49,52` return falsy, no fizzle branch); the uber damage requirement stays a native pre-check (`:23-30`). | **S3 second admission** — the first real `actual_landing` union and the self-exclusion annotation (landing on the player's own tile is normal; `selffire=0` ⇒ no self risk, allies within the union are the measured friendly risk). |
| `T_VAULT` (agility) | `request_then_landing` (S2 §4.4) with the ordered two-prompt program: prompt 1 the attacked actor (`{cursor_type='hit'}`, entity required, range 1 fixed, `agility.lua:92-93,113-115`), prompt 2 the landing grid (`{cursor_type='hit', nolock=true, range=getDist}`, `:118-121`, `value_source='target_plan'`); landing `bounded_alternatives` radius 1 around the requested grid (`findFreeGrid(x,y,1)` fallback `:123-126`, `block_move` refusal `:128`), `traverses=false` (direct `self:move` `:149-150`), `relocates_other=false`; `range={getter='getDist'}` for the landing envelope (`:105`) and **no `builder_shape`** (the first prompt's fixed `range=1` must not overwrite the landing bound; `conformance={builder=false}`, the Phase Door pattern). | The pre-move strike/daze components (`phase='melee'` strike like T_ATTACK; daze as a `secondary` `hit` on the prompt target, `:137-147`); the TL5 free-block self branch (`:156-159`) as postcondition metadata; the subject='actor' binding that keeps the strike on the policy's hostile-bound actor. | **S3 third admission** — closes the S2-R4-01 reservation (`movement_effect_composition_required`): the sequence is distinguishable (presence-explicit `hit` vs `hit`+`nolock`), the effect is declared and guarded, and the actor prompt can no longer be bound to `self` with the effect invisible. |
| `T_DISPLACEMENT_SHIELD` | No movement template. It selects an actor and installs a damage-transfer shield; it does not relocate the player when activated (`game/modules/tome/data/talents/spells/conveyance.lua:286-321`). | Delayed damage redirection, target lifecycle, chance, capacity, duration, and effect semantics. | **Remain a source-reviewed effect-adapter task**, outside this factory. |
| Phase Door, effective TL below 4 and no precise attribute | `self_random_teleport`; `{'none'}`, `teleport`, `random`, `self`, radius from live `t.getRange`, default native minimum 0, no traversal/other relocation. The native call uses `target:teleportRandom(x,y,range)` (`game/modules/tome/data/talents/spells/conveyance.lua:74-78,104-107,146-148`). | Exact variant condition, dynamic range getter, helper coverage, final envelope/postcondition. | **Already conceptually supported, but the current fixed `radius=6,min_radius=1` should be replaced or proven for every admitted state** (`overload/mod/auto_combat/EffectManifest.lua:246-255`). |
| Phase Door, precise attribute below TL4 | `request_then_landing` resolved to `{'grid'}` with subject self; landing is random around the requested grid with radius `getRadius`, with the source's LOS-dependent broad fallback (`game/modules/tome/data/talents/spells/conveyance.lua:71-72,104-147`). | Attribute predicate, both envelopes, LOS/fizzle branch, prompt table. | **Supportable after this state variant is declared**. Current level-only unsupported gating does not cover it. |
| Phase Door, TL4 only, subject self | `request_then_landing` resolved to `{'actor'}` and a random landing; the actor response is self. The actor prompt begins at TL4, while the grid prompt begins at TL5 or under the precise attribute (`game/modules/tome/data/talents/spells/conveyance.lua:82-108`). | Subject binding, random center/range, effective-level and attribute matrix. | **Supportable as a single-prompt self-subject variant** after explicit source review. Selecting another actor remains the multi-actor gap. |
| Phase Door, TL5+, subject self | `request_then_landing` with ordered `{'actor','grid'}`. Controlled landing uses the requested center and `getRadius`; an out-of-LOS fizzle can switch to a broad random envelope centered on the caster (`game/modules/tome/data/talents/spells/conveyance.lua:82-147`). | Exact request order, subject, two landing envelopes, fizzle condition/probability, dynamic getters. | **Supportable only after ordered prompt-response execution exists**. Randomness is policy-annotated; it is not the blocker. |
| Phase Door, TL4/TL5 subject other than self | Same request variants, but the selected target is relocated and receives continuum destabilization (`game/modules/tome/data/talents/spells/conveyance.lua:95-103,146-153`). | Mover identity, resistance/fizzle, target effect, and other-actor postcondition. | **Remain unsupported** as `moving_or_swapping_another_actor`. |

The Phase Door source requires a two-dimensional variant matrix: effective level
and `phase_door_force_precise`. The current single `at_least=4` rule is not enough
because the attribute forces the grid prompt at lower levels
(`game/modules/tome/data/talents/spells/conveyance.lua:71-72,82-108`). An unknown
level or unknown attribute must produce `movement_variant_unknown`; selecting the
no-prompt leaf would be unsafe.

## 9. Verification plan

### 9.1 Pure fixtures

1. Expand every template twice and deep-compare canonical output. Vary map/table
   insertion order and assert byte-equivalent normalized descriptors.
2. For every template, reject unknown keys, missing required parameters,
   non-finite/negative envelopes, invalid request kinds, and forbidden defaults.
3. Feed the same `type="hit"` builder fixture to actor-required, grid-only, and
   grid-or-actor curated declarations. Assert the builder never changes the
   declared semantic request kind.
4. Test builder table/function success plus missing, throwing, non-table, `nil`,
   NaN, and out-of-range results. Each fault must have the expected typed outcome;
   a replaced-but-working object still yields a usable value.
5. Resolve the full Phase Door level/attribute matrix, including unknown level,
   unknown attribute, zero matches, and overlapping matches. Only one descriptor
   may emerge.
6. Verify policy plans against every resolved request sequence, including
   actor/grid reversal, missing response, extra response, selector contradiction,
   and the current `unsupported_target_plan` capability case.
7. Exercise exact, bounded, and random envelope containment. An endpoint outside
   the envelope must become `movement_postcondition_mismatch`; a valid random
   endpoint must not.
8. Verify mixed component footprints are unioned over the landing candidate set and
   centered on `actual_landing` by **complete pair expansion** (§5.1, corrected): an exact
   landing yields a single-cell candidate set; a bounded envelope expands **every**
   component × candidate pair; `min_radius` is ignored. The analytic
   `circle(center, envelope+effect)` is used **only** as an oracle asserting the complete
   union is contained in it. Any single failed/cancelled expansion proves unknown
   membership (partial union discarded), not a measured risk. An unknowable footprint (native expansion failure,
   unseen-grid occupancy, missing landing annotation, unreadable radius) disables only
   that action (`selffire_risk` with `unknown=true`, or `movement_plan_unavailable` when
   the candidate set itself is undecidable). Assert `landing_adjacent` resolution: an
   envelope containing distance-1 candidates keeps the component (conservative), a
   provably non-adjacent envelope resolves it false, an indeterminate read keeps it.
   Assert the melee-strike pattern (Vault) measures zero risk and is still declared, and
   that Giant Leap's `selffire=0` self-exclusion is reported, not risk.
9. Replace action, builder, getter, `teleportRandom`, and `findFreeGrid` objects
   with working replacements and mutate recorded file digests. Assert the adapter
   **still executes** (calls the live object) and that changed telemetry raises a
   re-review signal; only a missing/throwing/`nil`/invalid result disables the one
   action.
10. Supply identical movement reports to strict and permissive `accept` objects.
    Assert only the policy result changes; capability and annotation remain the
    same.
11. Assert derivation/dry-run never invokes `useTalent`, `t.action`, `move`,
    `teleportRandom`, or another action entrypoint and never queries hidden actor
    occupancy. Calling live getters/builders is allowed and may consume RNG.
12. For the ordered executor, assert one action opportunity, one native
    submission, exact response consumption by index/kind, and no resubmission
    while pending.

### 9.2 Per-talent source-review checklist

For each new declaration, record:

- talent ID, game version, definition/action/builder/getter/helper paths and lines
  (advisory review metadata; recorded digests/live identities are telemetry only);
- every prompt and exact order for each effective-level/attribute/occupancy
  variant, including the entity value returned with coordinates;
- mover, requested center, native projected center, all exact/alternate/random
  landing branches, finite bounds, traversed cells, and other actors moved;
- all immediate, secondary, ground, delayed, callback, and post-landing effects;
- which branch predicates are player-known and which become `unknown`;
- native pre-use, range, LOS, `canProject`, rejection, energy, cooldown,
  pending/interaction, and callback behavior;
- pre-commit movement/effect report and policy acceptance fields; and
- final postconditions for success, native rejection, fizzle, resistance, and
  integrity mismatch.

The checklist is the irreducible manual work. A template removes repeated Lua
shape declarations, not the need to understand the native action.

### 9.3 Native source and packaged-`dist` probes

Run each scenario against the production source tree and the packaged `.teaa`,
record the package SHA-256 and loaded manifest/source digests as **advisory build
provenance**, and compare the same semantic signals. Existing acceptance already treats source and `dist` as
separate evidence and requires settled final movement postconditions rather than
mere submission (`VALIDATION.md:18-21,43`).

Every scenario must capture the observed prompt sequence and response kind **and**
settle to a final postcondition:

- Blink: one grid response; final self position lies in the declared radius-5
  envelope; Out of Phase postcondition matches the reviewed branch.
- Vault: one grid response; legal launch setup lands exactly on the requested
  grid and applies Directed Speed; missing-launch and blocked-grid setups reject
  without relocation.
- Dimensional Step: below-TL5 empty-grid case lands within the precise-fallback
  envelope; TL5 swap probes separately assert both actors' final locations on
  success and restoration/no-move branches on resistance/fizzle.
- Shadowstep: one actor response (the bound hostile); the final location is inside the
  radius-5 envelope around the anchor's cell (or the fizzle branch with its
  player-visible log line and no movement, `shadow-magic.lua:139`); the attack and daze
  occur only when the final adjacency distance is exactly 1 (`:142-149`) — both the
  fired and the not-fired case settle with the observed evidence; the pre-commit guard
  detail shows the guarded `landing_adjacent` components rather than a skipped entry.
- Giant Leap: empty destination lands exactly; occupied destination stays within radius
  one; the weapon/daze footprint is centered on the actual final landing; daze is
  observable on actors inside the radius-1 ball around the landing and never claimed on
  the player (self excluded by source, `str.lua:39,65`); the pre-commit union
  (`circle(requested, 2)`) contains the settled effect set.
- Vault: two prompts answered in order (actor = the bound hostile adjacent to the
  player, then the landing grid from the target plan); the strike + daze land on the
  prompt target before the move (`agility.lua:137-147`); the landing is the requested
  grid or a within-distance-1 alternative (`:123-128`); a shield-less setup and a
  blocked landing reject without relocation (native pre-use/block_move outcomes, not
  plugin refusals); the TL5 free-block branch is observed separately.
- Phase Door: exercise every level/attribute request sequence, self versus other
  subject, controlled versus LOS-fizzle envelope, and actual mover identity.
- Displacement Shield: verify no activation-time relocation and separately test
  the delayed transfer effect if/when its effect adapter is designed.
- Negative probes: missing/throwing/`nil`/invalid getter result, extra/reordered
  prompt, unknown variant input, out-of-envelope final location, owner/revision
  loss, and manual takeover all prevent further automated submission. Recorded
  source drift or live-object replacement is captured as telemetry only and must
  not on its own stop an otherwise valid action.

Sampling many random endpoints is not a proof of the envelope. The proof comes
from the curated semantic record of the source/helper behaviour; probes verify
that production lowering and postcondition instrumentation match that proof.

## 10. Anti-goals and genuine unsupported cases

- No scan that auto-admits talents because `is_teleport`, `requires_target`, or a
  cursor `type` resembles a known talent. The source examples in §3.2 show those
  signals are semantically ambiguous.
- No arbitrary modded talent admitted without review. Until curated it remains
  `unsupported_adapter`; once curated the adapter calls
  the **live** entry, and a later replacement is another addon's concern (the
  project is not responsible for other plugins' broken implementations).
- No movement whose request order, mover, finite landing envelope, or final
  postcondition cannot be established. This is execution non-determinability,
  not a judgment that the tactic is unsafe.
- No moving or swapping another actor until typed subject identities, two-actor
  destinations, restoration/failure branches, effects, and postconditions are
  implemented.
- No mixed movement/effect talent whose footprint cannot be computed over all
  possible landings. Known non-zero risk is reported and policy-controlled;
  uncomputable risk disables that action.
- No hidden-occupant or hidden-terrain probe to select a variant or improve a
  destination. Player-unknown facts remain unknown and native collision remains
  final authority (`docs/tome-mcp-0.9.0-movement-skills-design.md:242-272`).
- No direct calls from auto-combat to `move`, `teleportRandom`, or talent actions.
  Execution continues through `Actions` / native `useTalent` (the actual live
  entrypoints; see §3.1)
  (`docs/tome-mcp-0.9.0-movement-skills-design.md:334-347`).

Random landing, out-of-vision requests, retreat, kiting, and teleportation are
not anti-goals. Once a curated adapter establishes the execution envelope, those
facts are annotated and the data policy decides whether to accept them
(`docs/tome-mcp-auto-combat-plugin-design.md:18-28,407-415`).

## 11. Required contract clarification

The movement design currently says known bounds are recorded and missing bounds
appear as `unknown`, while still allowing audited random teleport
(`docs/tome-mcp-0.9.0-movement-skills-design.md:283-300`). This factory needs to
distinguish “unknown endpoint inside a proven envelope” from “unknown envelope,”
because only the former has a checkable postcondition.

Recommended exact addition after that paragraph:

> A stochastic endpoint is not an execution-integrity failure when the
> curated, source-reviewed adapter establishes the mover, request sequence,
> landing class, and a
> finite conservative landing envelope; visibility, occupancy, passability,
> hazard, and the chosen point inside that envelope may remain `unknown` and are
> reported to policy. If the adapter cannot establish the mover, request order,
> or any finite conservative envelope needed to verify the final postcondition,
> the action is unavailable with a typed movement capability/derivation reason.
> This is not a strategy refusal and does not make other complete actions
> unavailable.

Also replace the Phase Door level-only capability description with an explicit
effective-level **and** `phase_door_force_precise` variant matrix; the native
source makes the grid prompt depend on either TL5 or that attribute
(`game/modules/tome/data/talents/spells/conveyance.lua:71-72,104-114`).

## 12. Top uncertainties for implementation

1. **Decided for S2 (see §4.4).** The ordered prompt-response queue ships in S2 as a
   single-submission, in-opportunity queue, so single-prompt templates keep their exact
   current lowering and Phase Door TL4/TL5 becomes executable. Two implementation
   choices remain open and are settled by the S2 tests, not by this section: (a) whether
   the TL4 cell declares its grid entry `optional=true` or is split into two explicit
   attribute branches (§4.4), and (b) the exact internal key the executor uses to carry
   the resolved per-entry values (the analysis proposes `action.sequence`, validated as a
   closed internal field; it is not a policy field and not a protocol field).
2. The exact typed representation for mover/subject and `actual_landing` effect
   centers. The current descriptor is adequate for self-only movement but cannot
   losslessly represent swaps.
3. Whether TL5 Dimensional Step should admit a grid-only branch only when the
   requested cell is player-known empty, or wait entirely for the swap-capable
   descriptor. A hidden occupant must not be queried to answer this.
4. **Decided for S3 (see §5.1).** Harmful/mixed effects carried by a movement talent are
   full effect-manifest components on the movement entry (the guard's single source of
   truth); purely self-beneficial post-move branches with no footprint risk (Vault's TL5
   free Block, `techniques/agility.lua:156-159`) are curated postcondition metadata on
   the entry (`movement_postcondition`), not risk components. The unconditional movement
   guard skip now applies only to component-free movement entries
   (`AutoCombatGuard.lua:185-187`).


## 13. Delivery slices (roadmap)

The movement work is delivered in four slices. Each slice is a
branch + PR that goes through an independent review before merge; the next slice
starts only after the previous one is accepted.

| Slice | Scope | Reference |
| --- | --- | --- |
| **S1 (first slice)** | Closed `MovementAdapterFactory` + **single-prompt** templates (`actor_charge`, `grid_move_exact`, `grid_move_bounded`, `self_random_teleport`, `actor_anchor_teleport`) expanding into the current `movement` descriptor; the **Phase Door effective-level x `phase_door_force_precise` variant matrix** (fixes the level-only gating gap); semantic source coverage and advisory drift telemetry (no runtime gate). Candidates admissible after source review: Rush, Tumble, Phase Door no-prompt/precise-attribute, Blink Rune, Vault, Dimensional Step **non-swap**. | §4.1, §4.2, §8 |
| **S2** | `request_then_landing`: the **ordered prompt-response queue** for multi-prompt talents (Phase Door TL4/TL5 actor-then-grid, and other actor+grid skills). One action opportunity, one native submission, one decided value per declared request; per-request native range/self-warning guards preserved; typed `unexpected_target_request` / `movement_request_value_unknown` deviations pause and hand the interaction back. | §4.2, §4.4, §6.1, §12.1 |
| **S3** | **Movement/effect composition**: movement talents whose landing also carries a harmful/beneficial effect (Shadowstep, Giant Leap): compose the movement report with the effect/selffire guard, union the `actual_landing` footprint, and stop skipping movement entries in the guard. | §2 (finding 2), §5 |
| **S4** | **`swap` / moving or swapping another actor**: typed two-subject descriptor, executor and verification (Dimensional Step TL5, the `moving_or_swapping_another_actor` gap). | §4.2, §12.2 |

Separate, non-movement item: **Displacement Shield** (actor-target damage-transfer
shield that does not relocate the player) is an effect-adapter task, outside this
factory (§8).

### 13.1 Per-slice live-test scenarios (maintainer-specified)

Each slice's live test is dispatched as a `[Test]` agent **after that slice merges**,
with the merged build pins filled in. The test agent only plays/reports; raw
evidence stays under `tmp/`.

- **S1 — Berserker / Trollmire 1–2 / Rush.** Halfling Berserker (`berserker_p2`),
  Insane/Roguelike; **must learn `T_RUSH` at level 1 and actually use it in real
  combat**; clear Trollmire levels 1 and 2, then stop. (See
  `tmp/mcp-play-support/movement-playtest-handoff.md`.)
- **S2 — Archmage / Phase Door to effective TL5.** Archmage (`archmage_arcane_p2`),
  Halfling, Insane/Roguelike, `cheat=false`; force-learn `T_PHASE_DOOR` at **raw level
  4**, which with the Archmage `spell/conveyance` mastery 1.3
  (`game/modules/tome/data/birth/classes/mage.lua:202`) is effective talent level 5.2 —
  enough for both prompts while the landing radius stays 1. Then exercise the ordered
  prompt-response queue in play (actor prompt then grid/landing prompt) and report:
  the observed request sequence (two requests, in order, with **distinct** recorded
  values), the landing annotation (`requests`, `landing.kind='random'`, `radius`,
  `fallback`), and the postcondition — the landed cell within the declared radius 1 of
  the effective center, or the LOS-fizzle fallback branch with its player-visible log
  line; then stop. A refusal because the landing is random is a **bug**, not a pass
  (the reference policy uses `landing='allow_random'`). Verifies multi-prompt execution,
  not strategy.
- **S3 — debug Shadowblade / Shadowstep vs a training dummy.** Debug character
  `Shadowblade`, learn `T_SHADOWSTEP`, attack a **training dummy** (傀儡) to exercise
  the movement-talent path with its attack/damage component; report the movement +
  effect composition (guarded effect, `actual_landing` footprint) and the native
  postcondition; then stop. Verifies S3 (movement/effect composition).
- **S4 — Temporal Warden / Dimensional Step TL5 / successful swap.** Temporal Warden,
  learn `T_DIMENSIONAL_STEP` to **effective talent level 5**, then **successfully
  swap position with a monster** (two-subject swap) and report both actors'
  post-positions and effects; then stop. Verifies S4 (`swap` / moving another actor).

S3/S4 live tests use the test-only fixtures in
`docs/tome-mcp-0.9.0-movement-test-fixtures.md` (Shadowblade + training dummy;
Temporal Warden + swap monster).

Sequencing: S1 → S1 live test → S2 → S2 live test → S3 → S3 live test → S4 → S4 live
test; order may be re-prioritised by the maintainer. None of them authorises
execution by default (`allow_auto_combat_execution` stays `false`).

**Post-acceptance (maintainer):** after **all four slices are accepted and merged**,
resume the **regular test subagent** with a **Halfling / Celestial-Anorithil
(星月术士)** Insane/Roguelike run on the merged build (standard metrics) to
re-validate the whole plugin on the pilot build after the movement work.
