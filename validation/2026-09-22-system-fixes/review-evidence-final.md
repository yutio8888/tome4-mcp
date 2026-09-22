# SYSFIX evidence independent review — final assigned-scope verdict

Status: `review_complete` / recommendation: `accept` for this Review's assigned scope. No new finding was identified. This accepts EVIDENCE-REV-01/02 regression and SYS-05/06/07 evidence/index applicability; it does not adjudicate the separate Runtime Review's native behavioral scope and does not authorize merge.

## Exact candidate and index

- Frozen production source: clean detached `084642634b1d92dfb5e2880f43998672469798ab` at `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/workspaces/final-candidate/game/addons/tome-mcp-bridge`.
- Current durable-index HEAD: `5168984dfc2666741456f90a2d16e136163659d5` at `/workspace/t-engine4/game/addons/tome-mcp-bridge`.
- Final manifest: `validation/2026-09-22-system-fixes/manifest.json`, SHA-256 `026b973f4cf01b03d05f466c1b2bc88937c15f073e9673c3dbdcc47105cd968e`.
- Final summary: `validation/2026-09-22-system-fixes/summary.json`, SHA-256 `452ded646036ebaeceac15d3efa76caddb603dc3b1b56b5f5f341f7560d63d38`.
- Candidate package: `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/artifacts/candidate-3a4e186b0019.teaa`, SHA-256 `3a4e186b001971bdebfa9315a33dcac3ddd06c9abd7a1698c9af6caf03f413fb`.

The frozen source commit is an ancestor of the index HEAD. The tracked diff from source to index contains only `VALIDATION.md`, model-performance documentation and the final validation directory; scoped product/tool/test paths have no diff. An independently checked parity list confirms 196 product/tool/test paths are byte-identical. The pre-existing untracked user token-analysis document and a concurrently delivered sibling Runtime Review report are outside this Review and were not modified.

## Finding disposition

### EVIDENCE-REV-01 · formerly P1 · `CLOSED` / `PASS`

The final checker's SHA-256 remains `683de8b622f75da7e3eee7900ca3a858f5bac09b07f6a8bd0530a4fd9790d5f4`, identical to the accepted `638d153...` repair. On the final source, the unmodified checker returns 0 with A/B structural PASS and C/D/E only REVIEW. The original combined dead/unrelated-branch scratch returns 1 with `FAIL A.density`, `FAIL A.density-keys`, `FAIL B.copy`, `FAIL B.copy-fields` and `FAIL B.copy-terminal`. The 22-case real-CLI boundary suite passes.

### EVIDENCE-REV-02 · formerly P1 · `CLOSED` / `PASS`

The final boundary-test and Guard-oracle hashes remain `72ad53208dd1686be9fcf25a81c14c8a9419e0aa379b4da9aed5d5fafd7b8be8` and `9cbfe4d32854724e710fbcf7d856784bc3566931c9710d52afbfe9e0502bb800`, identical to the accepted repair. The original post-copy `spec.no_restrict=nil` scratch returns 1 with `FAIL B.copy-terminal`; the final Guard suite passes all 426 checks. The earlier independent 15-field mutation result remains applicable because these files are byte-identical.

## SYS-07 independent evidence audit

### Retrieval and hashes · `PASS`

The repository verifier returns 0: 6 evidence files, 8 gates and all declared provenance verified. A separate audit independently resolves and rehashes all 138 declared records—6 evidence, 128 raw sources and 4 artifacts—with no missing files, duplicate paths, conflicting duplicate hashes or mismatches. Success is treated only as byte/reference integrity, not as behavioral proof.

### Package and source identity · `PASS`

The `.teaa` contains 72 unique members. The member set and every byte exactly match both its adjacent manifest and the frozen source. The complete source archive exactly matches all 518 tracked source files. The server archive exactly matches the 5 tracked `server/src` files, including `server.py` SHA-256 `36f251558046efa171eb1e63a6796a04c21e76fd07c5ba170502591ace91dec9`.

### Four replacement native records · `PASS` for evidence applicability

All four session inputs/results/logs are retrievable and pinned to `0846426...`; dist inputs additionally name and hash the exact `3a4e186...` package. Raw results and final summary agree:

- `sysfix-policy-source-04`: source, 20/20, overall PASS.
- `sysfix-policy-dist-01`: dist, 20/20, overall PASS.
- `sysfix-core-source-02`: source, 123/123, overall PASS.
- `sysfix-core-dist-01`: dist, 123/123, overall PASS.

Within each family, source/dist check-name and pass sequences are identical. Source-session loaded Lua hashes match frozen source/package content; dist sessions bind the exact package hash. Core evidence indexes the native input/result/wire/game/MCP/reload logs, loaded configs, saved games and new-process reload inputs. This Review accepts the trace and layer applicability, not the Runtime Review's behavioral interpretation.

### Failure preservation and supersession · `PASS`

Raw results and the final summary consistently preserve:

- `sysfix-policy-source-01`: overall FAIL, 0 checks, startup failure; separately superseded by `sysfix-policy-source-04`.
- `sysfix-policy-source-02`: overall FAIL, 8/9, `sysfix:pending_rest_settled` failed; separately superseded by `sysfix-policy-source-04`.
- `sysfix-core-source-01`: overall FAIL, 112/113, volatile-UID oracle failed; separately superseded by `sysfix-core-source-02`.
- `sysfix-policy-source-03`: coordinator runner setup FAIL before engine launch, 0 checks, `product_changed=false`; separately replaced by `sysfix-policy-source-04`.

The manifest's `historical-failures` gate intentionally remains `failed`; none of these runs is relabeled PASS.

### Independent Test and layer labeling · `PASS` for indexing/applicability

The indexed Test report is byte-identical to the original (`e0e257c753d4343d3312bb10085fd4b9f39239bd9e14519a4fa0f0695043b726`) and is pinned by frozen metrics SHA-256 `248dd7fcaf1d8d2c71bcebf49f1cc67db5e0083e8a17ab83df1df5430348c444`, source commit, package hash and server source. All 32 raw-directory files and all 33 entries in the Test's inner SHA list are retrievable, indexed and hash-correct. The report states exactly 4/4 per-row PASS and separately discloses the unnecessary manual wait after all oracles, excluding it from policy actions. Behavioral impact remains for the separate Runtime Review.

Labels are honest: offline tests explicitly do not claim native execution; policy migration/import checks are identified as engine Service dataflow rather than filesystem save/restart; core source/dist claims are tied to actual Ctrl-S plus new-process reload evidence. `VALIDATION.md` still showed independent Review as PENDING before this verdict, avoiding circular acceptance.

## Requirement verdicts

- SYS-05: `PASS` at source/tooling layer; own exact findings remain closed on final bytes.
- SYS-06: `PASS` at source/real-CLI layer; the final manifest itself validates successfully.
- SYS-07: `PASS` for evidence integrity, retrieval, candidate/package applicability, layer labels and failure supersession.
- SYS-08, SYS-09 and U-01: `N/A` to acceptance because they remain explicitly deferred with owner/trigger; this report does not claim them fixed.

## Evidence and next owner

Detailed final audit: `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/review-evidence/final-sys07-results.md`. Independent audit script: `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/review-evidence/final_sys07_audit.py`. The coordinator is the next owner and may merge only after the separate Runtime Review also accepts its scope. This reviewer has no merge authority.
