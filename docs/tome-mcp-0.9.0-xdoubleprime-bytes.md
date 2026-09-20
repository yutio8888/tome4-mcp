# X″ slice 1 — canonical-byte authoritative snapshots + transaction-boundary validation

Branch `refactor/xdoubleprime-bytes` off `main@ded8e1a`. Role `[Dev]` (model **A**, rotation).
merge=no. Replaces the X′ slice-1 table-identity mechanism.

## Binding inputs

- `tmp/mcp-play-support/astra-defect-family-addendum.md` sha256
  `6a25de79f3c380802036b588db03eb67e29c1ddf9c978b1f6ca701cc1fe6e26a` — the **X″** decision.
- `tmp/mcp-play-support/review-xprime-slice1.md` sha256
  `1dfbcea202ab3a691cbeae9304100147e1543ec9a3a57ecb01ef8c57a79606ac` — the review whose
  XPS1-R2-01..05 findings are the acceptance list.

## Why X″

An exposed populated Lua table **cannot** be made immutable: `__newindex` fires only for
absent keys, `rawset` bypasses it even for new ones, and there is no sandbox. X′ used table
identity as a certificate that a table had been validated at registration time; the review
showed (XPS1-R2-01/-02) that identity proves a **past** check, not the current value. A
schema-valid edit of a returned copy changed the running policy hash with the revision
unchanged, and the next `step` executed it.

X″ therefore makes the **authoritative state immutable canonical bytes** and requires
**every hash/evaluate/store transaction to validate the exact value it uses on a private
working tree**.

### The bounded claim (do not overstate it)

- Ordinary callers cannot mutate the authoritative snapshot through a returned table
  (get/save/export return detached decoded copies; the store keeps bytes).
- Every owned policy transaction validates the exact snapshot it will hash, store or
  evaluate, on that transaction's private working tree.
- It is **not** protection against another addon replacing our functions, `debug.*`
  access to private state, or the engine. There is no sandbox; the plugin does not audit
  runtime entry identity (AGENTS.md).

## Architecture

```
PolicyCodec.prepare(raw, sink)   -- complete structural audit -> schema/catalog validate
                                 --   -> canonical BYTES -> snapshot record
PolicyCodec.open(snapshot|bytes)  -- bounded decode + full current-schema validation
                                 --   -> transaction-private plain working tree
PolicyCodec.hash(snapshot|tree)   -- the historical content-hash projection
PolicyCodec.copy(snapshot)        -- detached decoded copy for a public consumer
```

A **snapshot record** is `{bytes=<immutable string>, hash=<content hash>, schema, id,
version}`. Only `PolicyCodec.prepare`/`open` create one; `PolicyStore`, the service, the
controller and the lifecycle consumers all speak it.

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

### Validate before encoding, and never lose information (XPS1-R2-03)

`prepare` runs, in order:

1. a **complete structural audit of the original value** (`audit`): non-finite numbers,
   unsupported value types, cycles, over-depth nesting, mixed/sparse arrays, and — the
   review's P1 — **inadmissible key kinds** (table/function/userdata/thread/boolean keys)
   are **typed faults**, never silently dropped;
2. schema + capability-catalogue validation of the complete value;
3. only then the canonical encoding.

The old `OwnedImport.copyValue` skipped table-valued keys and `ownPolicy` snapshotted before
validating, so a malformed original could pass as a smaller "valid" document. Both are gone.

### The transaction boundary

Every sink obtains a snapshot for **this** transaction, operates on a private tree, and
publishes only after all checks succeed:

| sink | transaction |
| --- | --- |
| `validate` | `prepare` (audit + validate) then hash |
| `dry_run` (explicit `args.policy`) | `prepare`; host factory gets a **detached copy**; the evaluated tree is an independent `open` of the same bytes |
| `dry_run` (stored running/approved/draft) | the stored snapshot's bytes are re-opened (**re-validated** under the current schema) |
| `set_draft` | `Store.setDraft` prepares the raw policy and stores **bytes** |
| `approve` / `activate` | promote the **specific snapshot record** (content-bound) |
| `import` / `import_assistant` (incl. `store=false`) | full constructor before translation; `store=true` goes through `set_draft` |
| `loadState` / `saveState` | restored documents are re-prepared under the current schema; saved state is a detached decoded version |
| `get` / `export` / `preset` | detached decoded copies / re-validated preset source |
| controller `start`/`step` | the controller holds a private working tree + the immutable snapshot; each opportunity re-checks the working tree against the snapshot hash (`policy_mutated`) |
| lifecycle/status/log/replay | report the running **snapshot hash** (immutable) |

`Schema.hash`/`Schema.canonical` are now **validated wrappers**: a public raw call
validates or raises. The lexical projection inside `PolicyCodec` receives only validated
trees.

### Approval binds content

`PolicyStore.setDraft` stores the snapshot record; `approve` copies that record to
`approved`; `activate` copies it to `running`. Because the record's `bytes` are an immutable
Lua string, **a later edit — schema-valid or not — of any returned copy cannot change what
the approved/running policy means**. `restore`/`loadState` re-prepare under the current
schema and always drop `running`/`active`, so merely loading policy data never resumes
control.

### Residual Lua limits

- No sandbox: another addon may replace any of our functions (AGENTS.md: no runtime-entry
  auditing).
- `debug.*` and `rawset` on a **private tree handed to a callback** remain possible; the
  mitigation is that the working tree is re-created per transaction and the authoritative
  content is bytes, so a mutated working tree is refused (`policy_mutated`) rather than
  trusted.
- Source digests remain advisory telemetry only, never a runtime gate.

## Sink inventory (explicitly gated vs not)

**Gated this slice** (validate the exact value at the transaction boundary):

`tome.policy` ops `validate`, `dry_run` (explicit + all three stored fallbacks), `set_draft`,
`approve`, `activate`, `import`, `import_assistant` (`store` true and false), `export`,
`preset`, `get`, `clear`, `status`, `log`, `replay`; `PolicyStore.setDraft/approve/activate/
hashes/status/getVersion`; `PolicyIO.export/import`; `PolicySchema.hash/canonical/project`;
`AssistantAdapter.policySnapshot` (every service/store/import sink);
`AutoCombat.start`/`step`/`status` (controller + lifecycle); `saveState`/`loadState`;
`PolicyEditor` (reads a detached copy).

**Not gated, with reasons:**

| path | reason |
| --- | --- |
| `OwnedImport.construct` (assistant config constructor) | It is a *pre-translation* structural constructor for one specific wire format (the pinned assistant export); it audits + validates rows but is not a policy hash/evaluate/store sink. Its output must still pass `prepare` before any policy sink. |
| `PolicyEvaluator.evaluate` / `AutoCombatGuard.build` with a caller-supplied `policy` | Pure functions with no store/hash/cache. In production the controller always passes its transaction tree. A direct caller (unit test) supplies its own data; no authoritative state is reached. |
| `PolicySnapshot.build` (`opts.policy`) | It only reads the selector default; the reads are pure. In production it receives the transaction tree via the host. |
| `PolicyEditorModel.toggle/bump` | Pure data transforms over a detached copy; their output is re-prepared at `set_draft`. |
| server (Python) policy shapes | The server forwards untrusted dicts; Lua is the mandatory authority. Server-side checks would not protect local callers. |
| `PolicyLog` events | They *consume* a hash produced by a gated sink; they never hash a live policy themselves. |

No production path hashes, evaluates or stores a policy without validating the exact value
it uses.

## Pre-registered falsification matrix (row-by-row)

The addendum's 7 rows; raw evidence under `tmp/xdoubleprime-bytes/`.

| row | what it exercises | result |
| --- | --- | --- |
| 1 | wire bypass: malformed `when={all={hidden={always={}}}}` through validate/dry_run/set_draft/import; valid `import_assistant(store=false)` → JSON → dry-run/store; stored fallbacks | PASS |
| 2 | source + returned-object mutation incl. `rawset` and metatable tampering, before/after store/approve | PASS |
| 3 | transaction leak: retaining/mutating host-factory callbacks (explicit and stored) | PASS |
| 4 | every sink + restore, malformed saved state, presets/export/log hashes, controller sustain/safety reads | PASS |
| 5 | whole-import atomicity: first/middle/last talent, sustain, nested condition, depth, cycle, invalid keys | PASS |
| 6 | codec + diagnostics: `decode(encode(valid))`, `encode(decode(bytes))`, empty containers, null/false/absent, numbers, metadata, golden hashes; fresh-process determinism; source+dist | PASS |
| 7 | cost falsifier: representative maximum-size policy | PASS (measured, no threshold) |

Row 7 numbers on this machine (64 rules, 15 211 bytes, 2000 iterations each):
`prepare≈1.4 ms`, `open≈0.19 ms` (private exact-bytes/version cache), `hash≈0 µs`
(cache). The addendum permits the cache: keyed by **exact bytes + codec version**, a Lua
string cannot change, the decoded tree is still re-created per transaction, and
world-dependent checks stay live.

## Acceptance

See `tmp/xdoubleprime-bytes/` for raw evidence (commands, logs, hashes) and the report
`tmp/mcp-play-support/xdoubleprime-bytes-report.md`.

## What this slice does not cover

- Derived movement plans / raised-spec semantic tables / transition exactly-once work
  (Astra's slice 2/3) are unchanged and out of scope.
- No protocol code changes (three generators `--check` green).
- **Keep Z**: the S3/Earthen admissions are not merged.
