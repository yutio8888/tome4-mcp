# Wave 2 — interface / contract fixes (INT-01 … INT-06, SAFE-01)

Date: 2026-09-17 · branch `feat/wave2-interface-contract` · review
`tmp/mcp-play-support/wave2-interface-contract-handoff.md`. Runs after Wave 1
(both touch `Runtime.lua`).

## Decisions (binding, recorded)

- **D7 (INT-01/INT-02) mixed.** Request ops/args and the **error contract** are
  normative and derived/checked from the live registry. Result shapes are
  documented per op with representative fields (a full result schema is not
  required); an unmodeled op must be a declared, checked allowlist gap.
- **D8 (INT-04).** `approve` CASes the **draft**, `activate` CASes the
  **approved** version. Code stays; the frozen §11.1 prose, `server.py`
  description and tests are corrected.
- **D9 (INT-05).** Remote `auto_explore` is added to `capabilities.actions`,
  `action_support` and `native_tasks` with native-activity semantics.
- **D10 (INT-06).** `get` (three actual versions) and `clear` (draft only) are
  added. §11 wording is formally revised to bless the shipped names:
  `policy_log` (newest-first tail) + `replay` (paginated trace) and the
  `invalid_policy` error code — the merged MCP tools are not renamed.
- **D11 (SAFE-01).** **SUPERSEDED (v1.6).** The original decision registered the finite
  computed-getter set through `NativeCompatibility` (source digest + exact identity + declaration match +
  dependency-closure machinery) as a runtime gate. Per `AGENTS.md` and design §8.3 this gate is removed:
  the game's live getters are called as normal entrypoints; digest/identity/closure is advisory re-review
  telemetry only; missing/error/`nil`/invalid results are what make a value unavailable.
- **D12.** Serial after Wave 1 (done).

## INT-01 — v4 schemas describe the live interface

- `requests.schema.json` now enumerates the **14 live TCP ops**
  (`connect`, `connect_observer`, `observe`, `inspect`, `list_collection`,
  `act`, `respond`, `status`, `stop`, `dismiss`, `abandon`, `level_map`,
  `policy`, `policy_log`) with `PolicyArgs`/`PolicyLogArgs` and the missing
  additive args: `observe.detail`, `inspect.kind` (+`character`)/`computed`,
  `status.compact`.
- `generate_protocol.py` now derives the live op set from the `Runtime.dispatch`
  branches (not a hardcoded list) and from the MCP `@server.tool` names, and
  fails on any drift in either direction.
- Result shapes: `vectors/result-examples.json` gains a per-op representative
  field map; the checker requires every live op to be documented or explicitly
  listed in `unmodeled_ops` (currently 14 documented, 0 gaps).

## INT-02 — one error registry, complete envelope

- `protocol/v4/vectors/error-codes.json` is the single normative registry (now
  **75 codes**) with `category`/`acceptance_scope`/`recovery` for every emitted
  code.
- `generate_protocol.py` generates `overload/mod/mcp_bridge/ErrorRegistry.lua`
  and `server/src/tome_mcp/error_registry.py` from it (checked by `--check`).
- `Runtime.fail` and the `bridge_error` path build the full envelope from the
  registry; Python `BridgeError.as_dict` fills the same defaults. Details still
  override (`accepted`/`uncertain`/`recovery`).
- The checker extracts every `fail('...')` code and every Python `BridgeError`
  code (plus the dynamic store/arbiter codes) and **fails CI on any code missing
  from the registry**; it also validates a full envelope per registry entry
  against `errors.schema.json`.

## INT-03 — strict policy validator

`PolicySchema` now rejects: unknown `logging` keys / non-integer `ring_size` /
non-boolean `log_rejections`; unknown `targeting.tie_break` keys; extra keys on
`all`/`any`/`not`/predicate-leaf unions; irrelevant `talent`/`target`/`max_turns`
on `wait`/`attack`/`use_talent`. Negative tests added.

## INT-04/05/06

- **INT-04** §11.1 now states approve→draft CAS, activate→approved CAS;
  `server.py` description matches; tests assert a draft-hash `activate` (after
  the draft changed) conflicts.
- **INT-05** `auto_explore` added to the general `actions`, `action_support`
  (`scope='native_explore'`) and `native_tasks` (`task.auto_explore`).
- **INT-06** `tome.policy` gains `get` and `clear` (draft only). `get` is a read
  (observe-allowed); `clear` persists the draft removal.

## SAFE-01 — computed getters use the live entrypoints

`ActorCombat.register(actor)` records the finite computed-getter set with the
generated `stats_md5` / `combat_md5` as **advisory telemetry**;
`ActorCombat.computed` calls the game's **current live** getter directly, and a
missing/throwing/`nil`/invalid return falls back to `unknown`. **No runtime
digest/identity/closure gate applies**: a same-label replacement or a modified
native file does not by itself fail the read. (Historical rev 1 registered these
through `NativeCompatibility` and mapped a modified file to `unknown`; that gate
is superseded per `AGENTS.md` / design §8.3.)

## Validation

- Lua 33 suites / **102,008 checks**; Python **34 tests**; both `--check`
  generators green.
- Native probe **35/35** on source and `dist/*.teaa`.
- `dist/tome-mcp-bridge.teaa`: 60 files, SHA-256
  `c5c94255012daee3818be0f86c91e8aa04f7b02e1f43589c2dd1a179dec259c0`.
- Not re-done: Wave 1 execution safety; execution/`change_level` defaults
  unchanged.
