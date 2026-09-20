# X′ slice 1 — owned ingress constructors + the import → policy → hash vertical slice

Branch `refactor/boundary-funnels` off `main@ded8e1a`. Role `[Dev]` (model **A**,
rotation). merge=no. Input: `tmp/mcp-play-support/astra-defect-family-analysis.md`
sha256 `8391824dd542ae2c53019c9f512be6d8e4b8f7c8bd0c81f9789e14be13241651`
(adopted by the maintainer: **X′ + temporary Z**, not more patching).

## Why this slice

An independent analysis diagnosed **seven** recurrences of one defect family
(partial/unvalidated caller input measured as complete; engine-consulted field
semantics not mirrored; a transition applied twice) and showed the existing
textual checker **reproduced the defect at the meta level** (registered coverage
counted an ignored validator; whole-file spelling certified a discarded copy).
The adopted correction replaces "validate at every hand-written ingress" with
**enforced ownership**: consumers cannot obtain raw caller input, they obtain an
**owned, validated representation** built by the only constructor that accepts
raw input.

**Bounded claim (do not overstate it).** This is not structural impossibility in
unrestricted Lua — that is unattainable, and the previous attempt (a textual
checker) failed by treating a partial syntactic model as complete validation.
The property delivered here is **bounded and testable**: for the paths migrated,
there is exactly one way to turn raw input into a usable object; that
constructor rejects malformed input with a typed+diagnosable error; and every
consumer downstream of it holds the owned object. Prevention responsibility
**moved from regexes to the constructors**.

## Deliverable A — the single density primitive

`overload/mod/mcp_bridge/Json.lua` now carries the project's **one** density
primitive (ported in behaviour from `feat/r2-aprime:Json.lua:23-61`):

- `Json.denseArray(value, minLen)` → `ok, countOrCause` with causes
  `not_array | non_integer_key | hole | too_short`;
- `Json.denseFault(value)` → `cause, offendingKey` naming
  `non_integer_key | hole | key_beyond_dense_end` (smallest offending key wins;
  `nil` when the value is dense/empty/non-table).

**There is no second copy.** `MovementAdapterFactory.validateArray` is now a
thin alias (`local validateArray=Json.denseArray`) — the density decision exists
in exactly one place. Every migrated ingress uses the same vocabulary:

| ingress | before | after |
| --- | --- | --- |
| `MovementAdapterFactory` (8 call sites) | local `validateArray` copy | delegate to `Json.denseArray` |
| `AssistantAdapter.versionKey` (addon/tome tuple) | `#v` + `tostring(v)` fallback | `Json.denseArray` + `Json.denseFault` |
| `AssistantAdapter` `cond.all` / `cond.any` | `ipairs(list)` after a weak `type=='table'` | `Json.denseArray` + `Json.denseFault` |
| `AssistantAdapter` `config.sustains` / `config.talents` | `ipairs(type(...)=='table' and ... or {})` | dense-validated before `ipairs` |
| `AutoCombatService.importAssistant` | raw config straight to `translate` | `OwnedImport.construct` first |

Unit tests: `tests/test_json.lua` covers all three causes + the boundary matrix
(empty, dense `1..n`, `{[1]=a,[3]=b}`, `{[2]=b}`, `{[1.5]=a}`, `{[1]=a,foo=b}`,
key beyond end, `{[0]=a,[1]=b}`, non-table, `Json.null`, `nil`) and the
diagnostic's determinism.

## Deliverable B — the import → policy → hash vertical slice

### The single construction choke point

`overload/mod/auto_combat/OwnedImport.lua` (new). Only `M.construct(raw)` accepts
raw caller input. It:

1. deep-copies the caller input into **private** storage (`Json.null` preserved,
   caller mutation after `construct` cannot change what was validated);
2. validates the declared schema **before any `#`/`ipairs`** — every required
   array over **all** keys:
   ```lua
   M.SCHEMA={
       {path='assistant.addon_version',min=0},
       {path='assistant.tome_version',min=0},
       {path='sustains',min=0},
       {path='talents',min=0},
       {path='talents[].when',condition=true},   -- recursive all/any/not
   }
   ```
3. registers the snapshot in a private weak-keyed identity registry (the owned
   type is **identity**, not a self-declared `{owned=true}` marker).

`M.view`/`M.isOwned` gate the type. Adding an ingress is a **schema row**, not
new validation code.

### What still accepts raw input

Exactly two entry points, both immediately routing through the constructor:

- `OwnedImport.construct(raw)` — the only raw array reader;
- `AssistantAdapter.translate(config)` / `.detect(config)` — accept a raw table
  **only to call `OwnedImport.construct` first**; an already-owned snapshot is
  used directly. `AutoCombatService.importAssistant` also calls `construct`
  before `translate`, so the service path cannot skip it.

### Typed whole-import refusal

A malformed required array refuses the **whole** import — no draft, no hash, no
store — with one fault vocabulary:

```lua
{code='invalid_document', input=<path>, cause=<cause>, key=<offendingKey>}
```

Verified cases (asserting **zero** `Schema.hash` calls):

| malformed input | fault |
| --- | --- |
| `assistant.addon_version='2.3.9'` (scalar) | `input=assistant.addon_version, cause=not_array` |
| `assistant.addon_version=nil` | `input=assistant.addon_version, cause=not_array` |
| `assistant.addon_version={[1]=2,[2]=3,[4]=9}` | `cause=key_beyond_dense_end, key=4` |
| `assistant.addon_version={[1]=2,[2]=3,[3]=9,extra=true}` | `cause=non_integer_key` |
| `talents[1].when.all={[1]=…,[3]=…}` | `input=talents[1].when.all, cause=key_beyond_dense_end, key=3` |
| `talents[1].when.all='x'` | `cause=not_array` |
| `talents[1].when={all={{all={[1]=…,[4]=…}},{always={}}}}` | nested fault at `…all[1].all` |
| `sustains={[1]=…,[3]=…}` | `input=sustains, cause=key_beyond_dense_end, key=3` |
| `talents='nope'` | `input=talents, cause=not_array` |

A malformed **condition array terminates** the import (previously it merely
dropped the one rule, leaving a hashed/stored policy that silently lost a
condition — lossy sanitisation masquerading as validation). Translation returns
`nil, fault` up the tree; `translateTalent` propagates it; `translate` refuses.

### The hash choke point

`AssistantAdapter.hashPolicy(policy)` hashes **only** a policy registered by
`M.adopt` (the importer does this before hashing). A raw table straight from a
caller is not registered → `error('policy hash requires an owned policy …')`.
The registry is weak-keyed and lives **outside** the policy, so the policy bytes
— and therefore the content hash — are unchanged.

### Round-trip: before == after

For the pinned fixture `tests/fixtures/assistant/anorithil_pinned.json`:

| | hash |
| --- | --- |
| **before** this change (`main@ded8e1a` tree) | `2836a530` |
| **after** this change | `2836a530` |

The slice is behaviour-preserving for a valid import; the pinned hash is asserted
directly in `tests/test_auto_combat_owned_import.lua`.

## Deliverable C — the old checker is honest, not a gate

`tools/check_boundary_rules.py` is **not on this branch** (it lives on
`feat/boundary-selfcheck`, and `main` has no such file). Per the brief it stays
there; no third regex round was attempted. The checker was given one bounded
honesty change on its own branch (registering the migrated `AssistantAdapter`
ingress and narrowing its printed claim so a green run never reads as a global
semantic PASS); the prevention responsibility is stated in its header as
**moved to the constructors**. `tests/run.sh` on this branch does not gate on it.

## Invariants (unchanged)

No strict runtime-entry auditing (live getters are normal entries; unusable
values ⇒ typed unknown); **no plugin-level strategy restriction** (all movement/
retreat/teleport/`change_level` remain ordinary policy actions); reads submit no
actions and expose no player-unknown information; budget; `native_pending`;
lease; dry-run; deterministic tie-breaks; **no new protocol code**;
`T_SKIRMISHER_VAULT` untouched; `allow_auto_combat_execution` default unchanged;
no game-core edits; generated files not hand-edited.

## Scope: what slice 1 does NOT cover

Explicitly deferred (Astra's list), not silently expanded:

- **Derived plans / candidate sets** — `plan.values`, `plan.request_sequence`,
  `candidates.cells`, and the **plan/annotation/landing discriminated union**
  (missing landing metadata must not degrade to a deterministic single cell) are
  **slice 2**.
- **Raised-spec semantic tables** — engine-consulted field forwarding, live
  `false` precedence, `act_exclude` indexing, callable fields, `grid_exclude`
  nesting are **slice 2**.
- **Transitions** — exactly-once event identity, sync/async dedupe, lease/log
  side effects are **slice 3**.

**What slice 2 would need:** an owned `ValidatedPlan`/`CompleteCandidates` type
whose constructor validates `values`/`request_sequence` density **and** the
discriminated-union landing annotation (provenance distinguishes a deterministic
landing from a conservative envelope), consumed by footprint measurement,
planning and risk membership; plus one effective-spec resolution path with an
engine-reviewed semantic table (field source, precedence, nil/false behaviour,
callback calling convention, geometry-vs-membership consumers) and differential
source/dist probes. Sinks as well as sources must require the owned type.

## Acceptance

| ID | Result | Evidence |
| --- | --- | --- |
| Primitives | **PASS** — one primitive, three causes + offending key, unit-tested, no second copy | `tests/test_json.lua` (87 checks), `Json.lua:6-61`, `MovementAdapterFactory.lua` alias |
| Slice | **PASS** — malformed import refuses the whole import with a typed fault (input/cause/key), zero hash calls, no draft/store; valid import round-trips `2836a530` | `tests/test_auto_combat_owned_import.lua` (103 checks) |
| Unreachability | **PASS** — single construction point `OwnedImport.construct`; raw path unreachable from the importer; hash choke point rejects an unregistered policy | `OwnedImport.lua`, `AssistantAdapter.hashPolicy` |
| Scope honesty | **PASS** — §"Scope" lists the three deferred slices and the slice-2 needs | this document |
| Whole | **PASS** — Lua 43 suites, Python 39, three `--check` exit 0, probe source+dist 177/177, native acceptance source+dist 101/101, package parity 69/69 | `tmp/funnel-slice1/*` |

### Raw evidence (`tmp/funnel-slice1/`)

| artifact | note |
| --- | --- |
| `lua-suite.log` | 43 suites green |
| `python-tests.log` | 39 tests OK |
| `generator-checks.log` | three `--check` exit 0 |
| `probe-source.log` / `probe-dist.log` | 177/177 each |
| `accept-source.log` / `accept-dist.log` | 101/101 each |
| `dist-manifest.json`, `packaging.log` | 69 files, parity |

Session names: `funnel-slice1-ac-probe-src`, `funnel-slice1-ac-probe-dist`,
`funnel-slice1-accept-src`, `funnel-slice1-accept-dist` (all reaped;
`reap-session.sh --list` empty).
