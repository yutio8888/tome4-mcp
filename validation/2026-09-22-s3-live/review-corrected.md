# Corrected independent Review — frozen S3 native live-play evidence

## Correction notice

This report supersedes my unverified first draft. The coordinator preserved that draft unchanged as `review/report-initial-unverified.md` (SHA-256 `367c618a37e8831e921d2361c1c8ab64cf9e6f2b34e61fb5619a15373f4814ce`). It must not be used for provenance or acceptance.

The first draft incorrectly stated the Review model, addon/package and evidence hashes, and several coordinates. In particular, it named GPT-5.3, package `48c0468…`, Test report `f3d12dfa…`, manifest `d6c2d085…`, Shadow `(1,1)`/target `(11,4)`, and handoff `(8,4)→(7,4)`. None is a fact from this S3 package. Those values entered through my manual use of stale, unverified working-summary/transcribed values before recomputing from the actual files. Their exact originating run is unknown. I also conflated the Review candidate HEAD with the earlier Test/package source identities. That violated the provenance-first requirement.

For this correction I regenerated identities, hashes, coordinates, counters, transcript-key searches, archive parity, and source comparisons directly from files. Exact outputs are retained in `review/recomputed-evidence.json`, `review/identity-and-v2-output.txt`, `review/key-hashes.txt`, `review/runtime-source-comparison.txt`, `review/git-diff-output.txt`, `review/source-excerpts.txt`, `review/game-log-load-lines.txt`, and `review/manifest-verifier-output.txt`. No unsupported replacement value is used below.

## Identity, revisions, and fixed runtime

- **Task / role:** S3-LIVE-REVIEW-20260922 / Review
- **Reviewer:** `302ada78-e664-4298-b53b-5c1243821a99`
- **Required and dispatched model:** `pi/openai-codex/gpt-5.6-sol/high`. `review-dispatch.json` records provider `pi`, model `openai-codex/gpt-5.6-sol`, thinking `high`; process environment records `PI_MODEL=gpt-5.6-sol`, `PI_PROVIDER=openai-codex`, `PI_REASONING_LEVEL=high`.
- **Product baseline:** `8e3c21978a5040ac9ba97cd2175ee36901b91819`
- **Package source pin:** `084642634b1d92dfb5e2880f43998672469798ab`
- **Test dispatch/source-document commit:** `fdd741c1c47aa65be7ecc329a06a52a8d647482f`
- **Original Review candidate:** `0561430264ed41ce132318e49d29a344e2a93965`
- **Current own-finding recheck HEAD:** `aaa2d309106188918b48201b2f9408927fada338` (adds documentation/index errata only; no product or frozen-evidence mutation)
- **Fixed addon archive:** `candidate.teaa`, SHA-256 `3a4e186b001971bdebfa9315a33dcac3ddd06c9abd7a1698c9af6caf03f413fb`
- **Runtime input:** `1a2f86f112a8a55cff1b5ce4180e98e01874a28545cc595f0aecaf78dae63a7d`
- **Runtime candidate ZIP:** `02a25e63f8f392ba09f92dd248b170393db5b8becd9d545ae849ce381fb1498d`; its embedded addon is byte-identical to `candidate.teaa`
- **Loaded engine executable:** `5aa8fe5cfa8f0cde3aa82deb4602be95d8f7668e7d5d2ea4ce450cae18248dc7`
- **Driver / wrapper:** `1f8034f2579c67f713f03ef5efe5432af686f5587f109e60e5606d44bc9a74e3` / `87447b3971d67b192f2390a8ac96fe84d78a3388d551c34261e6ecf9f5fbf26b`
- **Server `tome_mcp/server.py`:** `36f251558046efa171eb1e63a6796a04c21e76fd07c5ba170502591ace91dec9`
- **Full MCP transcript / game log:** `2edfe66352b2874af72d635f63494183705b305ab19004c6e4162a2b1bc8278c` / `bb857a6d7a424c55ef92debd1c67114d70202e38e511862cbe80900213f40920`
- **Unrelated untracked file:** `docs/tome-mcp-token-usage-analysis.md`, unchanged SHA-256 `3b6f6e42c074c8948ecf67c22a28e3e37a91c5663e40e485ecc071405070746c`

The archive has 72 members; independent byte comparison found 72/72 match package-source commit `084642…`, baseline `8e3c219…`, and current product paths, with no mismatches. The runtime game log binds `/addons/tome-mcp-bridge.teaa` and separately discloses the `mcp-play-birth-s3` fixture. Runtime copies of Shadowstep, Giant Leap, and agility Vault source match the inspected game sources byte-for-byte.

## Recommendation

**`incomplete`**

Five mandatory rows are established. `S3-LIVE-VAULT` remains **NOT_OBSERVED** for the mandatory two actual request/answer records and second-request `nolock=true`. Landing, damage, daze, and one settled submission are observed, but a plan, static source, effects, and absence of `unexpected_target_request` do not replace direct request evidence. `REV-S3-01` remains open, S3 remains unaccepted, and S4 remains blocked.

The two P3 index issues from my prior report are now closed by `aaa2d309…`; they do not close the P1 evidence gap. The announced passive Test-addon/compact-forwarding work is undelivered and was not reviewed here.

## Open findings (P0–P3)

### P0

None.

### P1 — `REV-S3-01` — OPEN — mandatory Vault request observation missing

- **Category:** acceptance evidence / coverage; no gameplay defect demonstrated
- **File:line:** `validation/2026-09-22-s3-live/test-report.md:52-57,74-81`; `manifest-v2.json:708-716`; transcript records 58–66; `overload/mod/auto_combat/AutoCombat.lua:933-945`
- **Trigger:** inspect every retained response/event from the shield-equipped cap-1 Vault run.
- **Expected:** direct evidence of two ordered real native prompts and answers: actor hit answered with the bound dummy, then grid hit answered with the distinct landing grid, with request 2 exposing `nolock=true`.
- **Actual:** run 5 reports one native submission/effective action and the player moves `(8,4)→(7,6)` while the dummy at `(8,5)` loses life `9877.42223577878→9858.38485239453` and has `EFF_DAZED`/`EFF_OFFBALANCE`. Across all 90 transcript responses, recursive search finds zero response keys named `target_sequence`, `native_result`, or `nolock`, and zero response values `unexpected_target_request`. `raw/037` is a dry-run of the preceding no-shield policy, not a record of run-5 prompts. Loaded static Vault source corroborates two prompts and second `{type="hit", nolock=true}`, but does not observe this execution.
- **Consequence:** mandatory denominator remains 6 and supported numerator remains 5. Vault's request-observation subpart is NOT_OBSERVED; S3 cannot be accepted.
- **Evidence:** `raw/051`–`raw/054`, transcript records 58–66, `recomputed-evidence.json`, agility Vault source lines 106–150 (prompts at 113–119; second request `nolock=true` at 118).
- **Confidence:** high.
- **Direction:** coordinator must obtain a separately pinned native supplement that directly retains both requests/answers and request-2 `nolock`. If passive Test-only tracing cannot expose it, determine narrowly whether capture infrastructure must change; do not upgrade this package on inference.

### P2

None.

### P3

No P3 remains open after the authorized own-finding recheck below.

## Authorized recheck of own findings

### `REV-S3-02` — CLOSED

`errata-v2.json:9-22` accurately says `raw/010-observe-post-read.json` is zero bytes with SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, not the repeated response, and points to full transcript records 13 and 14. I parsed both one-based records: both are successful `tome.observe` responses and preserve revision `7704`, world tick `0`, player `(5,5)` life `104`, dummy `(8,5)` life `10000`, and unchanged history. Original raw/report/metrics/manifest bytes remain intact. Fix accepted.

### `REV-S3-03` — CLOSED

`manifest-v2.json:708-716` changes the Vault gate metadata from `not_run` to valid status `partial`, retains effects/landing as observed, and explicitly keeps the mandatory request/`nolock` subpart NOT_OBSERVED. `errata-v2.json:25-31` records the correction. The v2 verifier returns `manifest check: OK (7 evidence files, 8 gates; all declared provenance verified; byte integrity only)`. Fix accepted.

Verified v2 hashes:

- `errata-v2.json`: `01b1aec5947d9a521074ad8820a51f15da3a942f4c464f7d84990dbcad8c5d16`
- `manifest-v2.json`: `255c070d0993285422177d814d493bb60edbd17174ea21eeb182eb67fcf35774`
- preserved original manifest: `d6f9e701fbfa89e7b5797ffb390b73a54b0fe396771950a621d7f6166b74cdb9`
- preserved original Test report: `bac775cbb29ee47fa0b74ee26d08eb52fafaf133d9dfda17d10111710ec27cff`
- preserved metrics: `b25ee6ed4fdb07f8bc50278b5ca64e925ffc66dca606b6120a9c4f1ebae93c75`

## Per-row verdicts

| Row | Verdict | Recomputed basis |
|---|---|---|
| `S3-LIVE-READ` | **PASS** | Initial player `(5,5)`, visible dummy `(8,5)`. Three dry runs bind that dummy at distance 3 and expose a bounded landing centered `(8,5)`, radius 5, min radius 0, with passability/hazard unknown; each says `executed:false`, `side_effects:none`. Transcript records 13/14 and before/after policy status preserve revision `7704`, tick `0`, player/life/history, and log total `0`. |
| `S3-LIVE-SHADOW` | **PASS** | Actual start player `(5,5)`, target `(8,5)`; one settled native submission. Endpoint `(9,4)` is within the declared target-centered radius-5 envelope and adjacent under native game geometry. Dummy life `10000→9949.17223570128`; `EFF_DAZED` is directly inspected. |
| `S3-LIVE-LEAP` | **PASS** | Player `(9,4)→(8,4)`, exactly the requested visible/passable grid adjacent to dummy `(8,5)`. Run 2 has native/effective/run/instant counters all `1`; dummy life `9949.17223570128→9877.17223570128`; `EFF_DAZED` inspected. No resubmission. |
| `S3-LIVE-VAULT-NO-SHIELD` | **PASS** | Attempt A honestly pauses on the carried instant-opportunity budget; its displayed native/effective/instant `1` values are inherited from Leap, not a fresh Vault submission. After native wait creates opportunity 3, attempt B reaches native execution once, records `native_rejected`, zero effective/run actions, unchanged player `(8,4)`, unchanged contemporaneous dummy life `9877.42223577878`, and player-visible “You require a shield to use this talent.” |
| `S3-LIVE-VAULT` | **NOT_OBSERVED** | One submission, shield attack, landing `(8,4)→(7,6)`, dummy damage/daze are established. The required two actual request/answer records and request-2 `nolock=true` are absent. |
| `S3-LIVE-HANDOFF` | **PASS** | Before key: player `(7,6)`, arbiter owner `auto_combat`, policy active. One native Left moves to `(6,6)` and tick `43→54`; after key owner is `manual`, MCP control/lease is re-held, policy remains active, run is null, and log total remains `7` through three reads/final status. This covers armed pre-start takeover only. |
| `S3-EVIDENCE` | **PASS (v2 index)** | All declared files retrieve and verify; package/runtime identities and 72-member parity hold. v2 honestly records Vault `partial` and corrects raw/010 while preserving originals. Behavioral acceptance still fails through the Vault row. |
| `S3-DOCS` | **PASS at `aaa2d309…`** | Feedback/roadmap retain S3 unaccepted, state the Vault gap, preserve fixture limits, keep S4 and SYS08/SYS09/U01 pending, and identify the initial Review report as unverified. `056..aaa` changes docs plus v2 index/errata only. |

## Explicit disposition of Test ISSUE-1/2/3

| Test item | Independent result | Disposition |
|---|---|---|
| `S3-LIVE-ISSUE-1` | Compact `raw/001` and `raw/035` do **not** contain an `auto_combat` key; they do not contain explicit null. Full MCP transcript record 2 contains a populated summary (`enabled:true`, `active:false`, `state:"stopped"`, actions 0). `agent-play.py:88-133` constructs `snapshot_summary` without forwarding `auto_combat`. | Test's product-null claim is rejected. Real issue is compact harness presentation loss, nonblocking here because full transcript and policy status survive. The announced future harness fix is not reviewed. |
| `S3-LIVE-ISSUE-2` | `AutoCombat.lua:45-50` carries per-opportunity attempts/instant/native counters into a new controller; run actions start at 0. At lines 757-763 the carried instant budget pauses before another submission. Thus run-3 `native_submissions=1/effective_actions=1/instant_actions=1/run_actions=0` is carried Leap accounting, not evidence of a new Vault call. Opportunity 3 resets counters and attempt B then records one native call plus zero effective actions. | No product accounting defect established. Test lines 20/48 must not be read as a fresh submission. Coordinator correction is accurate. |
| `S3-LIVE-ISSUE-3` | Pinned `server.py:604-606` explicitly lists `log` in `policy_op`; line 615 documents status/log as read-only. `raw/036` success is expected. | Coordinator's in-Test reminder was wrong; current coordinator feedback corrects it. No product rejection/change is warranted. |

## Provenance and correctly checked claims

1. Original manifest verifier: `manifest check: OK (6 evidence files, 8 gates; all declared provenance verified; byte integrity only)`.
2. v2 verifier: `manifest check: OK (7 evidence files, 8 gates; all declared provenance verified; byte integrity only)`.
3. Archive SHA and 72/72 parity were recomputed against package source `084642…`, baseline `8e3c219…`, and current product source. Runtime ZIP embeds the same addon bytes.
4. Runtime talent sources match installed sources:
   - Shadowstep `03ad1476b0811c966efa79ba8fc192cf95055cd0dddfd21ad7942b836ad695bb`
   - Giant Leap `f9eb9c5960f2c4fcfa7fdaffb41ea0b0ba1c11d5111023d9668ddeeba8ff3004`
   - agility Vault `b0b1c7bd745a5f76e39c283c4a310efa4bf04968ecbfa868f67cada956280ae2`
5. The game log shows the archive addon and disclosed fixture loading, then the `mcp-s3-live` zone. This is training-fixture evidence, not ordinary campaign/natural progression.
6. `s3-live-01` failed before scoring; its failure remains retained. `s3-live-02` loaded the corrected fixture. `reap.log` (`d32590fcadb18f17433cd391001926c3d82be160e88a7ce13864e1f9dc5d8fb7`) confirms lifecycle cleanup.
7. Calls index is `5af6edec8fbfefae0552ee36cbb1ce3e16b0eaa94e7546789689582a96fecef3`; full transcript has 90 records. The historical Test claim remains 6/6, but coordinator/v2 and this Review use 5/6 supported.

## Key artifact hash ledger

| Artifact | SHA-256 |
|---|---|
| `candidate.teaa` | `3a4e186b001971bdebfa9315a33dcac3ddd06c9abd7a1698c9af6caf03f413fb` |
| `pin.json` | `92e05f8fee2acd251c69da2706d6052a1dc72075ea14b46b38a6ee76485b9c2d` |
| `runtime-pin.json` | `ba7f484eb1e5483c856f549388b929ebc0cb6e596c721a4e0b5692fad4c2083e` |
| `launch.json` | `7adaf198e0fee48272f04fb0ce3c05b687c73f0feef4a1d4993fb0fa0e4a25e5` |
| `load-parity.json` | `f6be0f1e1f47f9dac187f0ff2a16ee7c97b7a75b7eb8cbf653b466694e34f8da` |
| Test report | `bac775cbb29ee47fa0b74ee26d08eb52fafaf133d9dfda17d10111710ec27cff` |
| `summary.json` | `0a86f5643f393205f65fd56371f773e202d42d6a45ff4d1580cbf614cb3a6c4b` |
| `metrics.json` | `b25ee6ed4fdb07f8bc50278b5ca64e925ffc66dca606b6120a9c4f1ebae93c75` |
| `test-brief.md` | `9349a417dcfa1eab34d34a15d292d61813268e7d14ff7c006e38a54caf046635` |
| `test-info-reminder.md` | `d567b71c17ead8f30e3a0c659ff9a96d999e5b88e7f10de573bd07588068fad3` |
| Runtime input | `1a2f86f112a8a55cff1b5ce4180e98e01874a28545cc595f0aecaf78dae63a7d` |
| Runtime candidate ZIP | `02a25e63f8f392ba09f92dd248b170393db5b8becd9d545ae849ce381fb1498d` |
| Runtime engine | `5aa8fe5cfa8f0cde3aa82deb4602be95d8f7668e7d5d2ea4ce450cae18248dc7` |
| Full MCP transcript | `2edfe66352b2874af72d635f63494183705b305ab19004c6e4162a2b1bc8278c` |
| Game log | `bb857a6d7a424c55ef92debd1c67114d70202e38e511862cbe80900213f40920` |
| Original manifest | `d6f9e701fbfa89e7b5797ffb390b73a54b0fe396771950a621d7f6166b74cdb9` |
| v2 manifest | `255c070d0993285422177d814d493bb60edbd17174ea21eeb182eb67fcf35774` |
| v2 errata | `01b1aec5947d9a521074ad8820a51f15da3a942f4c464f7d84990dbcad8c5d16` |

## Selected raw hash ledger

| Raw artifact | SHA-256 |
|---|---|
| `test/raw/001-observe-initial.json` | `0062d8b2de7300e674dfec25adf0f0e2a91b803eafa4b92ef8a810c057bdcd8a` |
| `test/raw/007-policy-dryrun-read-1.json` | `0b5e3cfaeeed848881d727b1f84f021c4e12140bf37bfd4a6e030dc7108070ba` |
| `test/raw/008-policy-dryrun-read-2.json` | `5febfa0ba964e5b06b4008cc3a2ab22e6a4635e41533763404657ba1c5ef988d` |
| `test/raw/009-policy-dryrun-read-3.json` | `c4e5862fb8108cc44d366e4166fc0fc91a9359a2668ef6df59b21595a6b25c29` |
| `test/raw/010-observe-post-read.json` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `test/raw/011-policy-status-post-read.json` | `9403a09c5bd34e4ab3189527ae23c7d39efa43d8451e20c567b1bc9c0c16bb31` |
| `test/raw/017-shadow-auto-status-1.json` | `e6b05bc37d9f2cb2371bba873dd4fb37f84156cc550028f55e09423b7ba1e22b` |
| `test/raw/018-shadow-observe-post.json` | `95c03f91470bf16c6edc96a0f35b9fa6e310b1e68aa599d792dafbf587c7d39d` |
| `test/raw/019-shadow-inspect-dummy.json` | `97918bd75a40a8f5b14aaad2ba2de5c2877e07fb7d90d8c629ee1b16f6f1871b` |
| `test/raw/020-map-pre-leap.json` | `aa16004df19fe5a7e46d0e5554b741b882fb182814611c1515893fe4f187e664` |
| `test/raw/026-leap-auto-status.json` | `65f6526b84c0e176ea4df6dcd5d6e1c53b5033e6b6085ec4542dd9b7ff4dd672` |
| `test/raw/027-leap-observe-post.json` | `06fb46ea16aeba338bb6105877363a77ee823b2c84bd8101ab71075347b55b14` |
| `test/raw/028-leap-inspect-dummy.json` | `4a8c5670b0b4d96d2f912d0401c20ecf0761baba1fcef3e0ed88365b0c62013a` |
| `test/raw/034-vault-noshield-status.json` | `0bf2fa4fe1136607bf04e9b7f44ebdcacd78071d509f8ab10ff28de897477630` |
| `test/raw/037-vault-noshield-dryrun.json` | `924c9c02a38513d5113a0d8cc0070519b19ff3bdb5277ae7d9a2730b10625365` |
| `test/raw/039-setup-native-wait-1.json` | `e07c26570a51780c3d435996ab8444ff470a85cb6db8524f22c4ecedd5fd2318` |
| `test/raw/041-vault-noshield-status-2.json` | `3f9429b4d5541585244a68d09e7b977b6da1e54661bae412ab7636ff6c0f60d2` |
| `test/raw/042-vault-noshield-observe-2.json` | `a683fe72372a6be9f9f805abe6b2f78ce9a04f79fb57a3a04e7d0c847cab8adf` |
| `test/raw/043-inspect-player.json` | `261b0fd49f7ba11fcf7484f703054467243da55303af3a867d84a5ba4b8dd766` |
| `test/raw/045-equip-shield.json` | `0413449bd5920fc99a830a145c0156ccb79be82c073fd5cad967f87c6c2ebaae` |
| `test/raw/046-inspect-player-post-equip.json` | `55ce2ef54b5254795d43cd8d0da1a80db910941f4df79eb0d6de0aa338f640e7` |
| `test/raw/051-vault-start.json` | `89dbdfc9ed04ea8bce1ca285b0d0dbb6bbc89c1d92af9601b8d6f080ff0b0ff6` |
| `test/raw/052-vault-status.json` | `7b21d2d07785e54ffb0d7ba787f981e9ca985c64fb30041acf2f7df6ea5d2fc4` |
| `test/raw/053-vault-observe.json` | `9cea34589807e733fc0dfade7e46ec804f4e204a6a4a0f846237651f148cff1e` |
| `test/raw/054-vault-inspect-dummy.json` | `117f3ccf77c6cfdd4d219bc524cbe86234e8d56fe6645a9f5499bfc9d4cd0b16` |
| `test/raw/058-handoff-activate-nostart.json` | `92f552ef4e272405189d7f94693e77ce3437f6478630aecc89dfb01e518f44c9` |
| `test/raw/059-handoff-status-pre-key.json` | `7ed4d00b77e9bc27c670458dcb96fc593362f193048fb910a733a34fef04f2b6` |
| `test/raw/060-handoff-key-left.json` | `fb71f74bfa277d5a43a222a69e349ec409abe10268a588e42042db03f8b0bf86` |
| `test/raw/061-handoff-status-post-key.json` | `4185badb4a59419aebb6cb0d850fe4e85039904a7b4b728e9c98fbc8b29d768b` |
| `test/raw/062-handoff-read-1-observe.json` | `87c2b2dfbbd3c2777878a2ef5a99705bd0b775b703ae951903f0b8b728ecb16d` |
| `test/raw/063-handoff-read-2-map.json` | `19ac99778d80e82afaad420140275a2992ba2c6507d87ee632b8a024cad34a5c` |
| `test/raw/064-handoff-read-3-inspect-talent.json` | `5288999f46fda83dec2df45aaa456949aa0621b788a63b62be6216f222ddc345` |
| `test/raw/065-handoff-final-status.json` | `1889d0b6aadcc8c5d78578ab27b985f81031a178ee62d84ec71ee220e086604e` |

## Remaining uncertainty / N/A

- The exact run-5 request trace is unavailable in this frozen package; Review authority assigns `NOT_OBSERVED`.
- Why the existing public path omitted executor `target_sequence` is not determined by this evidence-only review. No production defect is inferred.
- Ordinary campaign behavior, broad product quality, pending-action handoff, S4, SYS08/SYS09/U01 implementation, and the undelivered Test-addon change are N/A by scope.
- No fresh game was launched; the native session was already reaped.

## Exact command/output record

The following commands were run read-only against repo/runtime, with writes only under `review/`:

```text
env | sort | grep '^PI_'
git rev-parse HEAD; git log; git diff --name-status <base>..<head>; git status --short
sha256sum <all key, cited raw, source, runtime, original, and v2 artifacts>
python3 tools/verify_validation_manifest.py --help
python3 tools/verify_validation_manifest.py validation/2026-09-22-s3-live/manifest.json --root <repo>
python3 tools/verify_validation_manifest.py validation/2026-09-22-s3-live/manifest-v2.json --root <repo>
python3 review/recompute_evidence.py > review/recomputed-evidence.json
cmp -s <installed talent> <runtime talent>  # all three MATCH
rg/nl/read over raw files, transcript, game log, package/runtime pins, production source, docs, reports, and v2 errata
```

Authoritative exact outputs are in the review files named in the correction notice. `report-initial-unverified.md` and the original frozen evidence were not modified.
