# X′ slice 1 rev2 — owned ingress constructors + the import → policy → hash vertical slice

Branch `refactor/boundary-funnels` off `main@ded8e1a`. Role `[Dev]` (model **B**, rotation —
rev2). merge=no. Input: `tmp/mcp-play-support/astra-defect-family-analysis.md`
sha256 `8391824dd542ae2c53019c9f512be6d8e4b8f7c8bd0c81f9789e14be13241651`
(adopted by the maintainer: **X′ + temporary Z**, not more patching). rev2 fixes
`review-xprime-slice1.md` (sha256
`0e9ea8759922b3352e06cf85d65cee113a5ec10d274ed8f585f84c2ec9df2c1f`, verdict DO_NOT_MERGE,
XPS1-REV-01..05).

## Why this slice

An independent analysis diagnosed **seven** recurrences of one defect family
(partial/unvalidated caller input measured as complete; engine-consulted field semantics
not mirrored; a transition applied twice). The adopted correction replaces "validate at
every hand-written ingress" with **enforced ownership**: consumers obtain an **owned,
validated representation** built by the only constructor that accepts raw input.

**Bounded claim (do not overstate it).** This is not structural impossibility in
unrestricted Lua — that is unattainable in a dynamic language without a sandbox. The
property delivered here is **bounded and testable**: for the paths migrated below, the
only way to turn raw input into a usable object is through the constructor or the sink
gate; that gate rejects malformed input with a typed+diagnosable error **before** any
hash/evaluate/store; and every sink that hashes/evaluates/stores re-validates the value it
is about to use, so ownership **identity** alone is never trusted.

## Which sinks require the owned form (exact list, rev2)

Every hash/evaluate/store sink on the declared **import → policy → hash** path requires
the owned form. The mechanism (stated, one choice): **re-construct at the sink**.

| sink | gate | behaviour with raw input |
| --- | --- | --- |
| `AutoCombatService.validate` (`tome.policy validate`) | `AssistantAdapter.ownPolicy(policy,'validate')` | re-construct (validate + private copy) before any hash; malformed ⇒ typed refusal |
| `AutoCombatService.dryRun` — explicit `args.policy` | `…ownPolicy(policy,'dry_run')` | same; then the owned copy is what is hashed and evaluated |
| `AutoCombatService.dryRun` — stored running/approved/draft | same gate | stored versions are re-checked against their recorded hash (identity is not trusted) |
| `AutoCombatService.setDraft` | `…ownPolicy(policy,'set_draft')` | the gate's **private copy** is what gets stored |
| `AutoCombatService.import` (`PolicyIO.import` result) | `…ownPolicy(policy,'import')` | the decoded policy is re-constructed before it is returned/hashed |
| `AutoCombatService.loadState` (character restore) | `…ownPolicy(policy,'load_state')` | the store only ever holds private validated copies (plain tables ⇒ save-safe) |
| `AssistantAdapter.hashPolicy` | requires `isOwnedPolicy` **and** a current-value hash match | the hash choke point itself re-checks |

Sinks **not** yet gated (and why): the **derived plans / candidate sets** and
**raised-spec semantics** listed under "Scope" below are slice 2, and **transitions** are
slice 3 — they are not policy hash/evaluate/store sinks and are not part of this slice's
declared path. `PolicySchema.validate`/`PolicyEvaluator`/`PolicyIO`/`PolicyStore` internals
remain ordinary functions, but every service-level entry into them now passes the gate, so
no production path reaches them with unvalidated raw policy. `PolicyEditorModel`/presets
build their own data and do not accept raw policies.

**Fault vocabulary at the sinks:** a policy that fails the gate is refused **before any
hash/evaluate/store** with one of

- `{code='invalid_policy', errors={…}}` — schema/catalog invalid (e.g. the
  JSON-encodable `{all={hidden={always={}}}}` condition container; see below);
- `{code='policy_mutated', input=<sink>, cause='owned_policy_changed',
  expected=<recorded hash>, actual=<current hash>}` — an owned policy whose current value
  no longer matches the hash recorded at registration;
- `{code='policy_not_owned', input=<sink>, cause='not_a_table'}` — not a policy table.

## Deliverable A — the single density primitive

`overload/mod/mcp_bridge/Json.lua` carries the project's **one** density primitive:

- `Json.denseArray(value, minLen)` → `ok, countOrCause` with causes
  `not_array | non_integer_key | hole | too_short`;
- `Json.denseFault(value)` → `cause, offendingKey` naming
  `non_integer_key | hole | key_beyond_dense_end`, **deterministic for all key types**
  (XPS1-REV-04): the offending key is the smallest in a documented **total order** —
  numeric keys first in ascending numeric order, then string keys in ascending byte
  order, then any exotic (non-JSON) key type by `tostring`, best-effort (two exotic keys
  can share a `tostring`; the deterministic contract covers the JSON-encodable
  number/string universe).

`MovementAdapterFactory.validateArray` is a thin alias; no second copy exists. The
same-density rule now also applies inside `PolicySchema.validate` (rev2): condition
`all`/`any`, `sustains`, `rules`, `targeting.tie_break` and target plans are
dense/closed-validated over **all** keys before any `ipairs` — the weak `isArray` test
that let `{all={hidden={always={}}}}` be traversed as an empty `all` is gone.

## Deliverable B — the import → policy → hash vertical slice

### The single construction choke point

`overload/mod/auto_combat/OwnedImport.lua` — only `M.construct(raw)` accepts raw import
input: private deep copy → schema validation (density **and, rev2, element shape**)
before any `#`/`ipairs` → registration in a weak-keyed identity registry.

`M.SCHEMA` rows flag `element=true` (rev2, XPS1-REV-03): **every** element of
`sustains`/`talents` must be a table; a non-table element (including `Json.null`) refuses
the **whole** import with the typed fault
`{code='invalid_document', input='talents'|'sustains', cause='invalid_element', key=<index>}`.
There is **no** surviving "malformed element ⇒ continue" case.

**Unsupported-element cases that DO survive (justified):** an element that is a valid
object but carries an **unsupported value** (a talent outside the pinned catalogue, an
unsupported action, an unknown field, an explicitly disabled entry) is reported in the
typed `unsupported`/`warnings` report and that one entry is skipped. These are not
malformed inputs: the element's shape is fully known and the mapping contract is
"documented subset, everything else is reported, never silently dropped"; an import still
needs at least one supported rule (`no_supported_rules` otherwise). A non-table element is
different in kind — it cannot be interpreted as an entry at all — and refuses everything.

A condition nested beyond `Schema.HARD.max_depth` refuses with the typed fault
`{code='invalid_document', input=<path>, cause='condition_too_deep', key=<depth>}`
(rev2: it no longer degrades to `nil` → an empty-string rule → an untyped error).

### The sink gate (`AssistantAdapter.ownPolicy`)

Chosen mechanism (stated): **re-construct (validate + private copy) at the sink**, not
reject-raw. Consequences, verified by regression:

- a caller-supplied malformed-but-JSON-encodable policy (`when={all={hidden={always={}}}}`)
  is refused at `validate`/`dry_run`/`set_draft` with zero hash calls, nothing stored, no
  revision advance;
- a **round-tripped valid policy** (`import_assistant(store=false)` → serialize → fresh
  unregistered table) still works: the sink re-constructs it (validate + copy) and the
  owned copy is what gets hashed/evaluated/stored;
- the stored draft is a **private copy**: a later mutation of the caller's table cannot
  change the stored value (A/B tested).

### What the owned value does and does not prevent (XPS1-REV-02, with the Lua limitation)

`OwnedImport` provides:

- a **private deep copy** — no aliasing to caller storage (verified A/B);
- a write guard for **absent** keys (`__newindex`) on the root and every nested table;
- a **protected metatable** (`__metatable`) — `getmetatable` exposes only a sentinel
  string, so `__newindex` cannot be stripped through the value and `setmetatable`
  refuses;
- identity-based ownership (weak registry) that a lookalike table cannot forge.

Lua 5.1 **cannot** prevent: `rawset` on an **existing** key (there is no `__newindex` on
assigned keys), and `debug.getmetatable`/`debug.setmetatable` access. There is no sandbox;
no immutability is claimed. The mitigation is therefore **re-validation at the sinks**:
the registry records the content hash at registration, and every hash/evaluate/store sink
re-hashes and compares (`policy_mutated`) **and** re-validates the schema/catalog
invariants before using the value. Identity proves history, not the current value — the
reviewer's `owned_policy_mutation` (hash `2836a530` → `ffffffffa376ac6c` while keeping
owned identity) is now refused typed. The weakened test asserting "NOT impossible to
mutate" was replaced by tests of the actual guarantee (mutated owned value refused at the
sink; caller mutation of its own tables cannot change the owned/stored value).

### Round-trip: before == after

For the pinned fixture `tests/fixtures/assistant/anorithil_pinned.json`, the content hash
stays `2836a530` (asserted directly in `tests/test_auto_combat_owned_import.lua`).

## Deliverable C — the old checker is regression scaffolding only

`tools/check_boundary_rules.py` is **not on this branch** (it lives on
`feat/boundary-selfcheck`). It is **regression scaffolding, not a gate and not a proof**:
its structural A/B checks are a tripwire for two recurring mechanical mistakes, and its
C/D/E entries only point at the regressions/review items that enforce them. It never
certifies runtime behaviour; the properties claimed in this document are established by
the unit tests and the native probes, not by the checker.

## Scope: what slice 1 does NOT cover

Explicitly deferred (Astra's list), not silently expanded:

- **Derived plans / candidate sets** — `plan.values`, `plan.request_sequence`,
  `candidates.cells`, and the plan/annotation/landing discriminated union are **slice 2**.
- **Raised-spec semantic tables** — engine-consulted field forwarding, live `false`
  precedence, `act_exclude` indexing, callable fields, `grid_exclude` nesting are
  **slice 2**.
- **Transitions** — exactly-once event identity, sync/async dedupe, lease/log side effects
  are **slice 3**.

**What slice 2 would need:** an owned `ValidatedPlan`/`CompleteCandidates` type whose
constructor validates `values`/`request_sequence` density **and** the discriminated-union
landing annotation, consumed by footprint measurement, planning and risk membership; plus
one effective-spec resolution path with an engine-reviewed semantic table. Sinks as well
as sources must require the owned type.

## Invariants (unchanged)

No strict runtime-entry auditing (live getters are normal entries; unusable values ⇒ typed
unknown); **no plugin-level strategy restriction** (all movement/retreat/teleport/
`change_level` remain ordinary policy actions); reads submit no actions and expose no
player-unknown information; budget; `native_pending`; lease; dry-run; deterministic
tie-breaks; **no new protocol code**; `T_SKIRMISHER_VAULT` untouched;
`allow_auto_combat_execution` default unchanged; no game-core edits; generated files not
hand-edited.

## Acceptance (rev2)

| ID | Result | Evidence |
| --- | --- | --- |
| Primitives | **PASS** — one primitive, deterministic offending-key rule for all key types (numeric ascending, then string byte order) | `tests/test_json.lua` (90 checks, stable across repeated fresh processes) |
| Sink ownership | **PASS** — validate/dry_run/set_draft/import/load_state gate every policy through re-construct; malformed-JSON policy never hashed/evaluated/stored; round-tripped valid policy still works; mutated owned policy refused (`policy_mutated`) | `tests/test_auto_combat_owned_import.lua` (161 checks) |
| Element shape + typed faults | **PASS** — non-table/`Json.null` element refuses the whole import (`invalid_element`, key=index); depth-over-limit carries `condition_too_deep` with code+input+cause+key | same |
| Metatable protection | **PASS** — protected `__metatable`; residual (`rawset`/`debug.*`) documented; sinks re-validate | `OwnedImport.lua`, `AssistantAdapter.ownPolicy`, tests |
| Scope honesty | **PASS** — this document states the gated/unmigrated sinks, what ownership does not prevent, and the checker-as-scaffolding | this document |
| Whole | Lua 43 suites green **and stable across repeated runs**; Python 39; three `--check` exit 0; probe source+dist; native acceptance source+dist; package parity | `tmp/funnel-slice1-rev2/` |

### Raw evidence (`tmp/funnel-slice1-rev2/`)

| artifact | sha256 | note |
| --- | --- | --- |
| `lua-suite.log` (+4 repeat runs) | `2f5aa4c4…` | 43 suites green, rc=0, 5/5 stable fresh runs |
| `python-tests.log` | `f8f988a5…` | 39 tests OK |
| `generator-checks.log` | `b0ee357f…` | native seams / effect manifest / protocol all `--check` rc=0 |
| `probe-source.log` | `cc4ff819…` | 177/177 (game.log `3e68f39d…`) |
| `probe-dist.log` | `9a4d4ae5…` | 177/177 (game.log `7a5c7dbc…`) |
| `accept-source.log` | `e446914b…` | 101/101 |
| `accept-dist.log` | `08a92599…` | 101/101 |
| `dist-manifest.json` | `5de437e3…` | 69 files, source==dist parity on all affected files |
| `tome-mcp-bridge.teaa` | `cc3b97ce…` | package parity 69/69 |

Session names: `funnel-slice1-rev2-ac-probe-src`, `funnel-slice1-rev2-ac-probe-dist`,
`funnel-slice1-rev2-accept-src`, `funnel-slice1-rev2-accept-dist` (all stopped by their
runners; `reap-session.sh --list` empty).

Head **`fce4f4a6511872d8eac5c7dac00e981d5e3a84f2`**; dist sha256
**`cc3b97cea67e63dcd483a0bda3db0b5fbbb2dbbde092a16901b5a5ef17027f1a`**.
