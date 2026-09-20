# X″ slice 1 — canonical-byte authoritative snapshots + transaction-boundary validation (rev 2)

Branch `refactor/xdoubleprime-bytes` off `main@ded8e1a`. Role `[Dev]`. merge=no. Replaces
the X′ slice-1 table-identity mechanism. **Rev 2** of this document incorporates the
XDP-REV-01..06 review fixes (private snapshot records, callback isolation, complete
public-hash audit, canonical decode, typed UTF-8 fault) and corrects the earlier
sink/matrix overclaims **and the incorrect deviation** (see § Deviation correction).

## Binding inputs

- `tmp/mcp-play-support/astra-defect-family-addendum.md` sha256
  `6a25de79f3c380802036b588db03eb67e29c1ddf9c978b1f6ca701cc1fe6e26a` — the **X″** decision.
- `tmp/mcp-play-support/review-xprime-slice1.md` sha256
  `1dfbcea202ab3a691cbeae9304100147e1543ec9a3a57ecb01ef8c57a79606ac` — the review whose
  XPS1-R2-01..05 findings are the acceptance list.
- `tmp/mcp-play-support/review-xdoubleprime.md` sha256
  `e411c933c7ca7f5cfb08cc8c999352d1635607b27ecaf095fb949338b1bfa795` — the fresh review
  whose XDP-REV-01..06 findings are the rev-2 acceptance list.

## Why X″

An exposed populated Lua table **cannot** be made immutable: `__newindex` fires only for
absent keys, `rawset` bypasses it even for new ones, and there is no sandbox. X′ used table
identity as a certificate that a table had been validated at registration time; the review
showed (XPS1-R2-01/-02) that identity proves a **past** check, not the current value.

X″ therefore makes the **authoritative state immutable canonical bytes** and requires
**every hash/evaluate/store transaction to validate the exact value it uses on a private
working tree**.

### The bounded claim (do not overstate it)

- The authoritative draft/approved/running records are **private**: they live in a vault
  keyed by a unique Lua table, no public entry point returns the live record
  (`getSnapshot` returns a fresh copy, `getVersion` a detached decoded policy tree), and
  every promotion/restore **normalises** its input — bytes re-opened and re-validated under
  the current schema, hash re-derived from the exact bytes, a supplied `.hash` discarded.
- Every owned policy transaction validates the exact snapshot it will hash, store or
  evaluate; callbacks (host factories) receive **neither the service nor the working
  tree**, and the controller verifies its tree by **exact canonical re-encoding** each
  opportunity.
- It is **not** protection against another addon replacing our functions, `debug.*`
  access to private state, or the engine. There is no sandbox; the plugin does not audit
  runtime entry identity (AGENTS.md). Code holding the unique vault key reference (or
  `debug`/C-boundary access) can still reach private state; that residual is inherent to
  Lua and is stated, not claimed away.

## Architecture

```
PolicyCodec.prepare(raw, sink)    -- complete structural audit -> schema/catalog validate
                                  --   -> canonical BYTES -> snapshot record
PolicyCodec.open(snapshot|bytes)  -- bounded decode + CANONICAL re-encode check (XDP-REV-04)
                                  --   + complete audit + current-schema validation
                                  --   -> transaction-private plain working tree
PolicyCodec.hash(bytes|snapshot|tree)
                                  -- bytes/record: hash re-derived from the exact bytes;
                                  -- raw table: the SAME complete prepare audit (XDP-REV-03)
PolicyCodec.copy(snapshot)        -- detached decoded copy for a public consumer
PolicyCodec.normalise(record)     -- fresh record re-derived from the exact bytes; a
                                  -- supplied `.hash` is discarded (XDP-REV-01/03)
PolicyCodec.matchesSnapshot(tree, bytes)
                                  -- exact transaction validation: no metatables anywhere
                                  -- in the tree AND re-encode == recorded bytes (XDP-REV-02)
```

A **snapshot record** is `{bytes=<immutable string>, hash=<derived content hash>, schema,
id, version}`. Records are created **only** by `prepare`/`normalise` and stored **only** in
the private `PolicyStore` vault; `PolicyStore.getSnapshot` returns a fresh copy.

### The codec is not the hash projection

`PolicySchema.canonical` was a **hash projection**: it inferred arrays with `#` and dropped
the editable `updated` metadata, so it is not a round-trippable document encoding. X″ adds
an explicit codec (`PolicyCodec`) with a total, prefix-free encoding:

| value | encoding |
| --- | --- |
| null / absent | `n` (absent = the key is omitted) |
| `true` / `false` | `t` / `f` |
| finite number | `#i<digits>;` (integral) or `#d<%.17g>;` (float) |
| string | `s<len>:<bytes>` |
| array (1..n dense) | `a<len>:` then `len` values |
| object | `o<len>:` then `len` × (`<klen>:<key>` value), bytewise ascending |

Empty containers are the empty **object** (`o0:`) — Lua plain values cannot distinguish an
empty array from an empty object, so one canonical form is fixed (the historical projection
already rendered `{}` as `{}`). Key order is canonical and numbers have one exact
representation, so `encode(decode(encode(v)))` is a fixed point.

The **content-hash projection is unchanged and byte-compatible** for valid input: the
golden valid-input hash `2836a530` is asserted directly. The codec is a *storage* format;
the hash is a *projection* of the validated content (dropping `updated`), so storage keeps
`updated` while the hash does not.

### Validate before encoding, and never lose information (XPS1-R2-03, XDP-REV-03/05)

`prepare` runs, in order:

1. a **complete structural audit of the original value** (`audit`): non-finite numbers,
   unsupported value types, cycles, over-depth nesting, mixed/sparse arrays, unknown
   metatables, **inadmissible key kinds** (table/function/userdata/thread/boolean keys)
   and — XDP-REV-05 — **strings/keys that are not valid UTF-8** are **typed faults**
   (`invalid_utf8` / `invalid_utf8_key`), refused before any encode or projection
   (reusing the validator `Json` itself enforces at encode time, so the two cannot drift);
2. schema + capability-catalogue validation of the complete value;
3. only then the canonical encoding.

`Codec.open` (any byte-string ingress, including hostile bytes never produced by this
codec) runs the same order: bounded decode → **canonical re-encode check** (XDP-REV-04:
the exact bytes must equal the canonical re-encoding, so alternate lexical forms —
leading-zero counts/lengths, non-canonical number spellings — are refused
`noncanonical_bytes`, never kept as authoritative bytes) → complete audit → current-schema
validation. A private exact-bytes/version cache skips only re-validation of bytes this
codec version already validated; the decoded tree is re-created per transaction.

### The transaction boundary (XDP-REV-01/02)

Every sink obtains a **normalised** snapshot for **this** transaction, operates on a
private tree, and publishes only after all checks succeed:

| sink | transaction |
| --- | --- |
| `validate` | `prepare`/`normalise` (audit + validate) then the derived hash |
| `dry_run` (explicit `args.policy`) | `prepare`; the EXACT bytes are captured in a private local **before** the callback; the factory receives **only a detached decode** (never `svc`, never the working tree); the evaluated tree is a SEPARATE decode of the captured bytes, verified by exact canonical re-encoding after the callback |
| `dry_run` (stored running/approved/draft) | the stored record is normalised: bytes re-opened and re-validated under the current schema, hash re-derived |
| `set_draft` | `Store.setDraft` prepares the raw policy and stores **bytes** in the private vault |
| `approve` / `activate` | promote a **fresh record** re-derived from the exact bytes (`Codec.normalise`); never the same table reference, never a supplied hash |
| `import` / `import_assistant` (incl. `store=false`) | full constructor before translation; `store=true` goes through `set_draft` |
| `loadState` / `saveState` | restored documents/records are **normalised** under the current schema (a wire-shaped `{bytes,hash}` dict is never stored by alias); saved state is a detached decoded version; `running`/control always dropped |
| `get` / `export` / `preset` | detached decoded copies / re-validated preset source; hashes read from the vault's derived records |
| controller `start`/`step` | the factory receives only a detached decode; the controller re-opens a SEPARATE tree from the captured bytes; each opportunity verifies the tree by **exact canonical re-encoding + a metatable sweep** (`policy_mutated`) — not a lossy digest |
| lifecycle/status/log/replay | report the running record's **derived hash** (records are private, hash derived at ingress) |

`Schema.hash`/`Schema.canonical`/`Schema.project` are **validated wrappers** over the
codec: a public raw call runs the SAME complete audit as `prepare` or refuses (XDP-REV-03
— a metatable-bearing policy and a table-valued key under `updated` are refused, not
hashed). The lexical projection inside `PolicyCodec` receives only validated trees.

### Approval binds content

`PolicyStore.setDraft` stores a normalised snapshot record in the private vault; `approve`
and `activate` store a **fresh record re-derived from the exact bytes** (never the same
table). Because a record only ever enters the vault through that route, its `.hash` is the
derived hash of its bytes; `getSnapshot` returns a copy, so no caller holds a mutable
locator. `loadState` normalises under the current schema and always drops
`running`/`active`, so merely loading policy data never resumes control.

### Residual Lua limits

- No sandbox: another addon may replace any of our functions (AGENTS.md: no runtime-entry
  auditing).
- Code holding the unique vault-key reference — or using `debug.*`/C-boundary access —
  can reach private state. The vault key is a unique table, so ordinary holders of the
  store/service table cannot reconstruct it; this is privacy by unreachability, not
  immutability, and it is stated as such.
- Source digests remain advisory telemetry only, never a runtime gate.

## Sink inventory (explicitly gated vs not, post rev 2)

**Gated** (validate the exact value at the transaction boundary):

`tome.policy` ops `validate`, `dry_run` (explicit + all three stored fallbacks),
`set_draft`, `approve`, `activate`, `import`, `import_assistant` (`store` true and false),
`export`, `preset`, `get`, `clear`, `status`, `log`, `replay`; `PolicyStore.setDraft/
restore/approve/activate/hashes/status/getVersion/getSnapshot` (private vault; promotions
re-open + re-derive); `PolicyIO.export/import`; `PolicySchema.hash/canonical/project`
(complete audit); `AssistantAdapter.policySnapshot`/`hashPolicy` (normalise; a wire
`{bytes,hash}` shape never supplies a trusted hash); `AutoCombat.start`/`step` (captured
bytes, detached host, exact re-encode verification); `saveState`/`loadState` (normalise,
never stored by alias); lifecycle/status/log/replay hash consumers (derived records).

**Not gated, with reasons:**

| path | reason |
| --- | --- |
| `OwnedImport.construct` (assistant config constructor) | It is a *pre-translation* structural constructor for one specific wire format (the pinned assistant export); it audits + validates rows but is not a policy hash/evaluate/store sink. Its output must still pass `prepare` before any policy sink. |
| `PolicyEvaluator.evaluate` / `AutoCombatGuard.build` with a caller-supplied `policy` | Pure functions with no store/hash/cache. In production the controller always passes its transaction tree. A direct caller (unit test) supplies its own data; no authoritative state is reached. |
| `PolicySnapshot.build` (`opts.policy`) | It only reads the selector default; the reads are pure. In production it receives the transaction tree via the host. |
| `PolicyEditorModel.toggle/bump` | Pure data transforms over a detached copy; their output is re-prepared at `set_draft`. |
| server (Python) policy shapes | The server forwards untrusted dicts; Lua is the mandatory authority. Server-side checks would not protect local callers. |
| `PolicyLog` events | They *consume* a hash produced by a gated sink; they never hash a live policy themselves. |
| direct `Codec.open`/`Codec.copy` of caller bytes | These are the validation boundary themselves: hostile bytes are audited (complete audit + canonical decode) or refused. |

**Residual (XDP-REV-02-class), honestly stated:** any code that can replace a module
function, hold the unique vault-key reference, or use `debug`/C-boundary access is outside
X″ by design (no sandbox; no runtime-entry auditing). Within ordinary Lua callers, no
production path hashes, evaluates or stores a policy without validating the exact value it
uses.

## Pre-registered falsification matrix (row-by-row, post rev 2)

Raw evidence under `tmp/xdp-fix1/` (this rev) and `tmp/xdoubleprime-bytes/` (rev 1).

| row | what it exercises | result |
| --- | --- | --- |
| 1 | wire bypass: malformed `when={all={hidden={always={}}}}` through validate/dry_run/set_draft/import; valid `import_assistant(store=false)` → JSON → dry-run/store; stored fallbacks; **a JSON-round-tripped `{bytes,hash}` dict is normalised (forged hash discarded), corrupt bytes refused** | PASS (in-process suite + determinism) |
| 2 | source + returned-object mutation incl. `rawset` and metatable tampering; **getSnapshot returns a fresh copy; promotion re-opens + re-derives; restore normalises** | PASS (in-process suite) |
| 3 | transaction leak: retaining/mutating host-factory callbacks (explicit and stored); **the callback receives exactly one argument (never `svc`); a root-`__index` live factory cannot turn a low-HP pause into an action** | PASS (in-process suite) |
| 4 | every sink + restore, malformed saved state, presets/export/log hashes, controller sustain/safety reads; **noncanonical bytes refused (`noncanonical_bytes`) and never stored** | PASS (in-process suite; native source+dist runs separately) |
| 5 | whole-import atomicity: first/middle/last talent, sustain, nested condition, depth, cycle, invalid keys | PASS (in-process suite) |
| 6 | codec + diagnostics: `decode(encode(valid))`, `encode(decode(bytes))` stability, empty containers, **null/false/absent incl. an actual `Json.null` value**, numbers, metadata, golden hashes; fresh-process determinism (12 processes); source+dist | PASS (in-process suite + fresh-process determinism; source+dist native evidence separate) |
| 7 | cost falsifier: representative maximum-size policy | **NOT_OBSERVED / BLOCKED pending a frozen threshold**: the driver measures `prepare/open/hash` only (64 rules, 15 211 bytes → `prepare≈1.43–1.47 ms`, `open≈0.19–0.20 ms`, `hash≈0.2 µs` cached); it does not yet measure GC or the promised action-opportunity transaction, and no latency/GC budget was pre-agreed. Measured numbers are reported; **no PASS is claimed**. |

## Deviation correction

The rev-1 Dev report stated: *"The `dryRun` fallback failure for a mutated stored policy
uses a defensive branch; the real guarantee is that snapshot bytes cannot change, so the
branch is unreachable in practice."* **That deviation was incorrect and is withdrawn.**
The dry-run callback also received `svc`, and for a stored fallback the transaction's
local snapshot was the same mutable record reachable through `svc.store.draft/approved/
running`; a callback could swap that record and the replacement was opened, hashed,
reported and evaluated (the reviewer's `stored_via_svc_record` evidence). The branch was
reachable, not defensive. The fix (rev 2): callbacks receive neither `svc` nor the working
tree; the exact bytes are captured in a private local before any callback; the evaluated
tree is a separate decode of the captured bytes verified by exact canonical re-encoding.

## Acceptance

See `tmp/xdp-fix1/` for rev-2 raw evidence (commands, logs, hashes) and the report
`tmp/mcp-play-support/xdp-fix1-report.md`.

## What this slice does not cover

- Derived movement plans / raised-spec semantic tables / transition exactly-once work
  (Astra's slice 2/3) are unchanged and out of scope.
- No protocol code changes (three generators `--check` green).
- **Keep Z**: the S3/Earthen admissions are not merged.
