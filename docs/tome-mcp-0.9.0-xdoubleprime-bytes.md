# X″ slice 1 — canonical-byte authoritative snapshots + transaction-boundary validation (rev 3, frozen)

Branch `refactor/xdoubleprime-bytes`. Role `[Dev]`. merge=no. Replaces the X′ slice-1
table-identity mechanism. **Rev 3 is the closure**: it fixes the last two P1s and rewrites the
guarantee down to exactly what is true. **The X″ loop is frozen here** (see § Loop frozen).

## Binding inputs

- `tmp/mcp-play-support/astra-defect-family-addendum.md` sha256
  `6a25de79f3c380802036b588db03eb67e29c1ddf9c978b1f6ca701cc1fe6e26a` — the **X″** decision.
- `tmp/mcp-play-support/review-xdoubleprime.md` sha256
  `e411c933c7ca7f5cfb08cc8c999352d1635607b27ecaf095fb949338b1bfa795` — rev-1 findings
  (XDP-REV-01..06 are the rev-2 acceptance list).
- `tmp/mcp-play-support/review-xdoubleprime-rev2.md` sha256
  `9cb0695e22767d49c9dae46940f3658929c1138f6a6eb74ddccc1a93300fd36e` — rev-2 verdict
  (DO_NOT_MERGE, 2×P1 + 3×P2). Its `XDP2-NEW-01..05` are the rev-3 acceptance list.

## Why X″

An exposed populated Lua table **cannot** be made immutable: `__newindex` fires only for
absent keys, `rawset` bypasses it even for new ones, and there is no sandbox. X′ used table
identity as a certificate that a table had been validated at registration time; the review
showed (XPS1-R2-01/-02) that identity proves a **past** check, not the current value.

X″ therefore makes the **authoritative state immutable canonical bytes** and requires every
**hash/evaluate/store transaction to validate the exact value it uses**.

## What X″ guarantees (exactly this, no more)

These hold for the **agent surface, the wire, and ordinary callers** (any Lua code that
only holds the public `store`/`svc` tables and calls public APIs):

1. **The agent/wire/ordinary-caller paths validate the exact snapshot they hash, evaluate
   and store.** Every sink runs a complete structural audit + schema/catalog validation on
   the value it is about to use, and the value it uses is the value it validated (re-opened
   from the captured bytes, verified by exact canonical re-encoding — not a lossy digest).
2. **The authoritative content is canonical bytes.** Draft/approved/running live as
   `xdp1\n`-headed canonical byte strings in a **module-level lexical vault** keyed by the
   store token. Bytes are immutable in Lua, so nothing an ordinary caller does can change
   what a stored policy means.
3. **Returned values are detached.** Every `PolicyStore` API returns scalars or fresh
   copies (`getSnapshot` a fresh record copy, `getVersion`/`copy` a fresh decoded tree,
   `hashes`/`status` scalars, `restore` a copy of what it stored). The vault is **not an
   entry of the store table**, so `pairs(store)` cannot enumerate it. Mutating any returned
   table cannot change the stored bytes or hash.
4. **A stale writer cannot silently overwrite.** Writing a draft/promotion compares
   `expected_hash` against the current slot; a mismatch is a typed `policy_conflict`.
   A supplied `.hash` on a wire/record-shaped input is **never** authority (the hash is
   always re-derived from the exact bytes).
5. **Control and reporting cannot diverge across a callback.** The host factories are
   invoked only with a detached decode (never `svc`, never the working tree), and the
   transaction captures the store authority (revision + slot hash + id) **before** the
   callback and re-checks it **after**: if a reentrant public call moved the authority, the
   transaction aborts typed (`policy_conflict` with `cause=policy_changed_during_start` /
   `policy_changed_during_dry_run` — the registered wire code, no new protocol surface)
   instead of publishing a controller or report bound to a different snapshot.
6. **Malformed diagnostics are deterministic.** A typed fault (including competing
   invalid-UTF-8 string keys) is selected by a total order over all key kinds, so the same
   input yields the same fault in every fresh process.

### What X″ does NOT guarantee (stated plainly)

**X″ does not defend against same-process Lua code that replaces our functions or reaches
private state.** There is no sandbox and no possible Lua-level guarantee:

- another addon may replace *any* of our module functions (the project does not audit
  runtime entry identity — `AGENTS.md`);
- code with `debug.*`/C-boundary access can reach the module's lexical upvalues, including
  the vault;
- therefore **any** residual below is reachable **only** from same-process Lua code that
  goes outside the public API, and the plugin neither can nor claims to stop it.

## Known limitations (residual items, with reachability)

| # | Residual | Reachability | Why it is accepted |
| --- | --- | --- | --- |
| L1 | Any remaining **reentrancy variant** around a callback that we did not enumerate | same-process only: a Lua closure that already shares `svc` and calls public ops | the enumerated variants (`start`, `dry_run`) are guarded and regression-tested; a future variant would be another same-process case, not an MCP/wire/ordinary-caller path |
| L2 | **Exotic-key diagnostics** beyond the exercised kinds (e.g. a new key type) | same-process only: a caller constructs such a table as a policy | the diagnostic is already total-order deterministic for every key kind T‑Engine/LuaJIT can produce; an unrecognised kind would still be a typed `invalid_key` |
| L3 | Replaced module functions / `debug` access to the vault | same-process only (by construction) | `AGENTS.md`: the plugin is **not responsible for other addons'** replaced implementations |
| L4 | Cost of the codec on huge policies | **reachable from MCP**: a policy author can submit/repeat an accepted maximum-size policy and incur the codec work (performance, not a security boundary) | row 7 is measured, not adjudicated (no frozen threshold) |
| L5 | **Toolchain observation**: a LuaJIT code-shape-sensitive failure was seen in an edited `PolicyCodec` structural-audit shape (an in-loop key-counting rewrite reported a single string key `{lt=<n>}` as `{numeric=1,strings=1}` => spurious `mixed_keys`) | the **deployed code shape** is not caller-controlled (Fix 5 keeps `classify` byte-identical to base), but the **workload** is caller-triggerable: a policy author can supply/repeat the representative max-size policy | retained artifact under `tmp/xdp-closure/jit-instability/`; see § Toolchain note |

### Toolchain note (L5) — deferred root cause

While shaping Fix 5, an edit that rewrote `classify`'s key-counting loop produced a
**LuaJIT-build-sensitive, edit/code-shape-sensitive failure**: an object with a single string
key `{lt=<n>}` was occasionally classified as `{numeric=1,strings=1}` and refused
`mixed_keys`. Retained reproduction under `tmp/xdp-closure/jit-instability/`:
`repro-caller.lua` (sha256 `f378d21f…`) against the offending `offending-PolicyCodec.lua`
(sha256 `c3210277…`) failed **26/40** fresh `luajit -O2` processes (`offense-o2.log`
`82944817…`), while the **base revision `6f63975f`** and the **deployed revision** each failed
**0/40** (`control-o2.log` = `deployed-o2.log` = `e86bb19e…`); `-joff` (JIT off) did not fail.

**The precise micro-cause is a hypothesis, not an established fact.** The retained evidence
establishes only: (a) an edit/code-shape-sensitive, LuaJIT-only observation, and (b) that the
practical revert+stress mitigation works. The coordinator's own three independent reproduction
attempts of a rebuilt in-loop pre-scan shape all failed to reproduce (0/20×2000; 0/30 fresh
processes ×2000; 0/20000 ×3 opt levels), so **"register aliasing" is stated as a hypothesis**;
the root cause is otherwise deferred and out of scope for this closure. What *is* established:
the **deployed code shape is not caller-controlled** (Fix 5 keeps `classify` byte-identical to
base), whereas the **representative workload can be caller-triggered** by a policy author.
**Mitigation applied:** `classify` is kept byte-identical to the base revision (both revisions:
1482 bytes incl. the trailing newline / 1481 without; sha256
`f2d2b3e896fa0d970b97c3b7985560ce4364a0e613b5d07a22361558dd27daf8` incl. / `5db26f925ef8328b7fe63f19cf602f27732728f24166cd51e95c5e2f0bfac514` excl., the
latter matching the reviewer's figure) and the
deterministic invalid-UTF-8 pre-scan runs *before* the original key loop, so the vulnerable
code shape is not emitted. Post-mitigation: 0/40 failures on the deployed revision (above).

None of **L1–L3** is reachable from MCP (`policy_ops` does not include `restore`), from the
wire, or from a policy author; they are same-process Lua concerns and are **out of scope** by
the project's stance. **L4 is a performance path that a policy author can trigger** (exempted
from the reachability claim above).

## Architecture

```
PolicyStore (module-level lexical VAULT[store]={draft,approved,running})
  new()            -- token; the vault is NOT an entry of the token
  setDraft         -- prepare(raw) -> canonical bytes -> record in VAULT; returns scalar hash
  approve/activate -- promote a FRESH record re-derived (Codec.normalise) from exact bytes
  restore          -- normalise input, store, return a DETACHED COPY
  getSnapshot      -- fresh record copy; getVersion -- fresh decoded tree
  hashes/status    -- scalars only (hash + id); runningId/authority/matchesAuthority
PolicyCodec.prepare(raw, sink)   -- complete audit -> schema/catalog validate -> canonical bytes
PolicyCodec.open(snapshot|bytes)-- bounded decode + canonical re-encode check + audit + validate
                                --   -> transaction-private plain working tree
PolicyCodec.hash(...)            -- bytes/record re-derived; raw table runs the SAME audit
PolicyCodec.matchesSnapshot(tree, bytes)
                                -- no metatables anywhere AND re-encode == recorded bytes
```

A **snapshot record** is a private `{bytes=<immutable string>, hash=<derived>, schema, id,
version}`. Records exist only in the vault. `Store.authority(store,slot)` returns
`{revision, hash, id}` and `Store.matchesAuthority` compares it — the reentrancy check that
does not expose records.

### The codec is not the hash projection

`PolicySchema.canonical` was a **hash projection**: it inferred arrays with `#` and dropped
the editable `updated` metadata, so it is not a round-trippable document encoding. X″ adds an
explicit codec with a total, prefix-free encoding:

| value | encoding |
| --- | --- |
| null / absent | `n` (absent = the key is omitted) |
| `true` / `false` | `t` / `f` |
| finite number | `#i<digits>;` (integral) or `#d<%.17g>;` (float) |
| string | `s<len>:<bytes>` |
| array (1..n dense) | `a<len>:` then `len` values |
| object | `o<len>:` then `len` × (`<klen>:<key>` value), bytewise ascending |

Empty containers are the empty **object** (`o0:`). Key order is canonical and numbers have
one exact representation, so `encode(decode(encode(v)))` is a fixed point. The **content-hash
projection is unchanged and byte-compatible** for valid input (golden hash `2836a530`).

## Sink inventory

**Gated** (validate the exact value at the transaction boundary): `tome.policy` ops
`validate`, `dry_run`, `set_draft`, `approve`, `activate`, `import`, `import_assistant`,
`export`, `preset`, `get`, `clear`, `status`, `log`, `replay`; all `PolicyStore` APIs (private
vault; detached returns; promotions re-open + re-derive); `PolicyIO.export/import`;
`PolicySchema.hash/canonical/project`; `AssistantAdapter.policySnapshot/hashPolicy`;
`AutoCombat.start`/`step` (captured bytes, detached host, post-callback authority check,
exact re-encode verification); `saveState`/`loadState`; lifecycle/status/log/replay hash
consumers; `Runtime` observe `policy_id` (public `Store.status` accessor).

**Not gated, with reasons:** `OwnedImport.construct` (pre-translation assistant constructor,
not a policy sink); `PolicyEvaluator.evaluate` / `AutoCombatGuard.build` with a caller-supplied
policy (pure, no store/hash/cache; production passes the transaction tree);
`PolicySnapshot.build` (pure reads); `PolicyEditorModel.toggle/bump` (pure transforms,
re-prepared at `set_draft`); server (Python) policy shapes (Lua is the authority);
`PolicyLog` events (consume a hash from a gated sink); direct `Codec.open/copy` (the
validation boundary itself).

## Pre-registered falsification matrix (honest, post rev 3)

| row | what it exercises | result |
| --- | --- | --- |
| 1 | wire bypass: malformed `when` through validate/dry_run/set_draft/import; `import_assistant(store=false)`; stored fallbacks; **a JSON-round-tripped `{bytes,hash}` dict is normalised (forged hash discarded), corrupt bytes refused** | PASS (in-process suite + determinism) |
| 2 | source + returned-object mutation incl. `rawset`/metatable tampering; **`restore` returns a detached copy; `pairs(store)` exposes no vault; mutating every returned table cannot change the stored bytes/hash** | PASS (in-process suite) |
| 3 | transaction leak: retaining/mutating host-factory callbacks; callback receives exactly one argument; **a shared-closure factory that calls public set_draft/approve/activate during `start`/`dry_run` aborts typed (`policy_conflict` + `cause=policy_changed_during_*`), no controller published** | PASS (in-process suite) |
| 4 | every sink + restore, malformed saved state, presets/export/log hashes, controller sustain/safety reads; noncanonical bytes refused; **Runtime observe `policy_id` is a real running id** | PASS (in-process suite; native source+dist runs separately) |
| 5 | whole-import atomicity: first/middle/last talent, sustain, nested condition, depth, cycle, invalid keys | PASS (in-process suite) |
| 6 | codec + diagnostics: `decode(encode(valid))`, `encode(decode(bytes))` stability, empty containers, null/false/absent, numbers, metadata, golden hashes; **competing invalid-UTF-8 keys deterministic** across fresh processes (source+dist) | PASS (in-process suite + fresh-process determinism; source+dist native evidence separate) |
| 7 | cost falsifier: representative maximum-size policy | **NOT_OBSERVED**: the driver measures `prepare/open/hash` only (64 rules, 15 211 bytes → `prepare≈1.50 ms`, `open≈0.19 ms`, `hash≈0.2 µs` cached); it does not measure GC or the promised action-opportunity transaction, and no latency/GC budget was pre-agreed. Measured numbers reported; **no PASS is claimed**. |

`[Dev]` reports these rows; only an independent reviewer adjudicates them.

## Approval binds content

`PolicyStore.setDraft` stores a normalised snapshot record in the vault; `approve`/`activate`
store a **fresh record re-derived from the exact bytes**. Because a record enters the vault
only through that route, its `.hash` is the derived hash of its bytes. `loadState` normalises
under the current schema and always drops `running`/`active`, so merely loading policy data
never resumes control.

## Loop frozen here (explicit)

**The X″ hardening loop ends with this revision.** The remaining residuals (L1–L4) are
same-process Lua concerns; chasing further same-process adversarial scenarios is **out of
scope** per the project's "we are not responsible for other addons' replaced
implementations" stance (`AGENTS.md`) and the standing finding that **no absolute integrity
guarantee is achievable in Lua**. Future X″-class findings should be assessed against the
narrowed guarantee in § What X″ guarantees; anything requiring same-process adversarial
protection is declined by design, not deferred.

## What this slice does not cover

- Derived movement plans / raised-spec semantic tables / transition exactly-once work
  (Astra's slice 2/3) are unchanged and out of scope.
- No protocol code changes (three generators `--check` green).
- **Keep Z**: the S3/Earthen admissions are not merged.
- No new protocol fields, no strategy restrictions, no runtime-entry identity gate.
