# Independent Review — S3 supplemental final recheck

## Recommendation

**ACCEPT** the frozen S3 package under the contracted S3 scope.

The supplemental evidence closes prior P1 finding `REV-S3-01`. The original six-row run remains an immutable historical **5/6** record—its `S3-LIVE-VAULT` row is still `NOT_OBSERVED` in that run—but the separately pinned supplement is **2/2 PASS** and supplies the missing direct Vault request/answer observation. Combined acceptance coverage now establishes every required S3 behavior. `REV-S3-02` and `REV-S3-03` remain closed.

No open P0, P1, P2, or P3 finding remains from this recheck. From Review's perspective, S3 no longer blocks the coordinator's S4 transition; this report does not merge branches or alter lifecycle state.

## Review identity and scope

- Role: independent `[Review]`, rechecking my own prior finding only.
- Provider/model/reasoning: `pi/openai-codex/gpt-5.6-sol/high`.
- PI session: `01a0c8a4-8c42-79e6-8a26-27ec0b6bbf30`.
- Coordinator HEAD: `4ca3caf923c1b2bb2a35773d22aa339b297075e6`.
- Dev helper HEAD: `440a5a7f1c4bba27accb076b9f7235d23838c0f4`.
- Product package: `candidate.teaa`, SHA-256 `3a4e186b001971bdebfa9315a33dcac3ddd06c9abd7a1698c9af6caf03f413fb`.
- Review was read-only except for scratch/report files under this Review directory. No game was launched, no package was rebuilt, and no repository/evidence bytes were edited.
- The pre-existing unrelated coordinator-tree untracked file `docs/tome-mcp-token-usage-analysis.md` and Dev's disclosed ignored cache/dependency paths are outside this diff.

The canonical report SHA-256 is recorded after final write in sibling `report-supplement-final.sha256` and in the completion envelope; a file cannot truthfully contain its own full-file SHA-256.

## Findings

### `REV-S3-01` — P1 — **CLOSED**

The missing observable was direct evidence that one real native `T_VAULT` invocation made exactly two ordered target requests and that request 2 carried `nolock=true`. Independent recomputation from the frozen full `game.log` found exactly this sequence for invocation 1:

1. line 2750: `invocation_start`, actor `(7,5)`;
2. line 2751: request 1, `type="hit"`, range 1, `nolock_present=false`;
3. line 2752: answer 1, arity 3, actor UID `15424` at `(8,5)`;
4. line 2753: request 2, `type="hit"`, range 3, `nolock_present=true`, `nolock=true`;
5. line 2754: answer 2, arity 3, no actor, grid `(7,4)`;
6. line 2766: `invocation_finish`, `requests=2`, `lifetime_requests=2`, `ok=true`, `truncated=false`, `emit_failures=false`.

There are no trace parse errors and no other Vault invocation in the log. This is actual observer telemetry, not a dry-run plan. Native success is independently established rather than inferred from `finish.ok`: public evidence shows player landing `(7,5)→(7,4)`, target life `10000→9982.883436931501` (damage `17.11656306849909`), `EFF_DAZED`, the three corresponding player-visible log messages, Vault cooldown 9, and exactly one attempt/native submission/effective action/run action with no retry or rejection.

### Existing findings

- `REV-S3-02` — **CLOSED, unchanged**. The accepted v2 index identifies zero-byte original `raw/010` and its valid transcript replacements.
- `REV-S3-03` — **CLOSED, unchanged**. The accepted v2 metadata honestly classifies the original Vault row as partial while leaving its missing request subpart `NOT_OBSERVED`.
- New findings in this recheck: **none**.

## Per-row verdicts

### Frozen supplement

| Row | Verdict | Independent basis |
| --- | --- | --- |
| `S3-SUP-COMPACT` | **PASS** | Independently projected full transcript observe results at lines 3, 22, 26, and 30 through the delivered `snapshot_summary`/existing `_prune` semantics. All four wrapper raw results are type-preserving equal, including `active:false`, `actions:0`, and `last_decisions:[]`; nested nulls are omitted and no defaults are invented. |
| `S3-SUP-VAULT` | **PASS** | One invocation contains the exact six-event ordered trace above. Request 2 directly has `nolock_present=true,nolock=true`; public counters, landing, damage, daze, cooldown, and visible logs establish actual native success. |

Supplement metric: **2/2 PASS**, with one scored Vault start, zero retries, three disclosed setup actions, 22 wrapper calls, and no failed MCP response.

### Original immutable six-row run

| Original row | Historical verdict | Final disposition |
| --- | --- | --- |
| `S3-LIVE-READ` | **PASS** | Remains established; no product/evidence change. |
| `S3-LIVE-SHADOW` | **PASS** | Remains established; no product/evidence change. |
| `S3-LIVE-LEAP` | **PASS** | Remains established; no product/evidence change. |
| `S3-LIVE-VAULT-NO-SHIELD` | **PASS** | Remains established; no product/evidence change. |
| `S3-LIVE-VAULT` | **NOT_OBSERVED** in the original run | Historical result is not rewritten. The separate `S3-SUP-VAULT` PASS closes the acceptance evidence gap and `REV-S3-01`. |
| `S3-LIVE-HANDOFF` | **PASS** | Remains established; no product/evidence change. |

## Required acceptance-ID disposition

| ID | Verdict | Basis |
| --- | --- | --- |
| `HARN-01` | **PASS** | Dev adds only `auto_combat: s.get('auto_combat')` to the compact projection. Four real compact/full pairs compare exactly; existing pruning retains false/zero/list values and removes absent/null domains. |
| `TRACE-01` | **PASS** | Trace source records invocation-local request ordinals, raw `typ` presence/value, and actual returned answer arity/values; frozen native telemetry has the required two request/answer pairs. |
| `TRACE-02` | **PASS** | Wrapper forwards exact argument/return arity, calls getter/action once, restores raw-vs-inherited `getTarget`, and rethrows the original error object. Focused regression reports 68 checks passed; actual trace reports no emission failure/truncation and public behavior settles once. |
| `TRACE-03` | **PASS** | Observer is explicit test-only addon content, absent from the 72-member product archive, separately loaded, bounded, and valid JSON. Product archive/source/runtime bytes are unchanged. |
| `TRACE-04` | **PASS** | Regression is registered in `tests/run.sh`; frozen full entry SHA-256 `9eb4f4cc…a260d` ends `WHOLE_ENTRY_EXIT=0`; independent focused run also passed 68 checks. Integration limits are documented. |
| `COORD-HARN-01` | **PASS** | Installation event is valid JSON; full-log parse errors: 0. |
| `COORD-HARN-02` | **PASS** | Request ordinal is invocation-local; lifetime count is separate. Source and two-invocation regression cover the distinction; actual finish reports 2 and 2. |
| `COORD-HARN-03` | **PASS** | Getter/action arguments and returns use packed explicit arity, including trailing nil; regression contains arity falsifiers. |
| `COORD-HARN-04` | **PASS** | Error text conversion is protected and original error object is rethrown; hostile-`__tostring` regression passes. |
| `DOC-HARN-01` | **PASS** | Original driver remains immutable; the supplement uses a separately hashed copy with the compact function transplanted. |
| `DOC-HARN-02` | **PASS** | Documentation accurately says nil fields are absent and explains explicit presence/class/arity discriminators. |
| `DOC-HARN-03` | **PASS** | Actual command explicitly lists `mcp-bridge`, birth fixture, and observer; runtime/candidate ZIP contain no `MCPProbe` or product source-directory shadow. |
| `DOC-HARN-04` | **PASS** | Documentation matches implementation timing: Vault action captured at `ToME:load`; current actor getter captured at invocation. |
| `DOC-HARN-05` | **PASS** | Documentation and adjudication treat `finish.ok` only as pcall/no-exception and require public effect/outcome evidence. |
| `SUP-DOC-01` | **PASS** | Errata supplies the actual Test-report hash `fb6e49a1…a0cda` and preserves the original report. |
| `SUP-DOC-02` | **PASS** | Corrected accounting includes raw 018 status and raw 020 actor inspection; total remains 22. |
| `SUP-DOC-03` | **PASS** | Errata distinguishes PI session `01a0c8dc…` from Test Paseo agent `522fef2b-f4c1-4931-9ef2-2a21503f4d92`. |
| `SUP-DOC-04` | **PASS** | Errata withdraws unsupported dry-run `current_costs`; raw 012 has no such field. The public status/event evidence separately records resources `300→284.1`. |
| `SUP-DOC-05` | **PASS** | Report-time log hash `e68e9207…` independently matches final-log prefix 161748; final frozen file hash is `f154bebd…`, so append timing is reconciled without rewriting the report. |

## Independent provenance and integrity checks

- Dev range `0561430264ed41ce132318e49d29a344e2a93965..440a5a7f1c4bba27accb076b9f7235d23838c0f4` changes exactly seven disclosed files: compact forwarding, three observer-addon files, observer regression, test registration, and helper documentation. No product path or distribution file changes.
- Product archive has 72 files. Every member is byte-identical to both Dev HEAD and the coordinator product tree. The session runtime archive and `candidate.zip` embedded archive are byte-identical to frozen `candidate.teaa`.
- `candidate.zip` contains the observer only as three separate `tome-mcp-s3-observer/**` files; it has no `tome-mcp-bridge/**` source tree and no probe. All three observer copies (Dev source, prepared supplement, runtime) are byte-identical.
- Runtime native `agility.lua` SHA-256 is `b0b1c7bd745a5f76e39c283c4a310efa4bf04968ecbfa868f67cada956280ae2`, equal to the reviewed game source. That source itself performs actor `getTarget`, then grid `getTarget` with `{type="hit",nolock=true,...}` before attack/daze/move.
- Frozen session identities: `input.json` `5ba7aa3f…969cf7`; `candidate.zip` `7f465ee8…bb890`; engine `5aa8fe5c…48dc7`; driver `4ef74791…fcd3ec`; transcript `4db2fd25…88f77` (30 records); final `game.log` `f154bebd…1a99a`.
- Transcript has 30 records (2 startup plus 28 generated by 22 wrapper calls and internal reads), no failed response, and expected tool counts. The separately retained call log accounts for 4 observe, 1 map, 5 inspect, 3 setup action, 4 auto, and 5 policy wrapper calls.
- Original manifest, original v2 manifest, prior review manifest, and supplement manifest all pass the repository verifier. This proves declared byte/reference integrity only; behavior was adjudicated separately above.
- Supplement manifest SHA-256: `6a098fa640cd8ff5ba38c0a4a204aeff9e4725348350318dafe0d5b30ddd4912`.
- Test report SHA-256: `fb6e49a1d18e1e2f1f497ab37273a3a9ebcfa2663f32a4ae1f680fbed40a0cda`.
- Report errata SHA-256: `aa8a34a69a1500bd42170ae7b4d14720d70123e453b4a961e818933a6dba7b03`.
- Prior corrected Review report remains unchanged at SHA-256 `bd35da2e2d0cb084c9e4dcc9237d36512ea7001290f4d00a077c1bc19f38d7e7`.
- Independent machine recomputation is retained in `supplement-recomputed-evidence.json` (SHA-256 `b328fec7b890c017bfb54835baf91a89ad9e2a9bed26908323dc27472a6455f1`).

## Uncertainties and limitations

- The observer is disclosed instrumentation. It proves what the current getter receives/returns during the reviewed action but is not, and is not claimed to be, a runtime function-identity proof. Product archive parity, runtime native source parity, transparent-wrapper mechanics, and public effects provide the permitted corroboration.
- The session uses a disclosed training fixture, not an ordinary campaign or natural progression. Acceptance is limited to the S3 contract.
- `finish.ok` proves only no thrown exception. The PASS relies on the independent public counters/effects/landing evidence as well.
- Full-log hashes vary across report-time snapshots because the log appended during teardown. Exact prefix hashes and the final manifest-pinned hash reconcile those snapshots.
- Manifest verification does not prove behavior; the raw transcript, trace, source, and public before/after outcomes were recomputed independently.
- Original six-row metrics and evidence remain immutable. The supplement closes the acceptance gap; it does not retroactively change the original row's recorded verdict.
