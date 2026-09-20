# ToME MCP 0.9.0 — rebase-review fix round (`feat/s3-arm2`)

Dispositions of the independent rebase review (`tmp/mcp-play-support/review-rebase-admissions.md`,
sha256 `bc79698e…`); scope/attribution in
`tmp/mcp-play-support/rebase-admissions-fix-scope.md`. Branch-specific rows only:
RA-02/RA-03/RA-05/RA-06 are `feat/r2-aprime` rows and are not reproduced here.

## RA-04 (P2) — closed by rebase

`feat/s3-arm2` is rebased onto `main@97a69d8`, so the corrected TODO entry (the
withdrawn loop-39 "declared interchangeable group" **equivalence** claim, NOT
proposal A′) is what the branch carries. The equivalence premise is not restated
anywhere on the branch.

## RA-01 (P2) — closed: the "single density validator" claim made TRUE

`overload/mod/mcp_bridge/Actions.lua` — `M.normalizeSequence` deleted its own
`pairs`/`maxKey`/`count` density loop and now delegates the density decision to
the shared `Json.denseArray(list,1)`, preserving the external contract: typed
`invalid_sequence`, never a shorter prefix, at most 8 entries, empty list
refused (`too_short` ⇒ same typed error).

Re-audit of every remaining ad-hoc density decision under `overload/`:

- The only density decisions are `Json.denseArray`/`Json.denseFault` themselves
  (`overload/mod/mcp_bridge/Json.lua`), plus the thin delegations
  (`MovementAdapterFactory.validateArray = Json.denseArray`,
  `AutoCombatGuard.denseCells`, `EffectManifest.densePolicyArray`,
  `PolicySchema.denseList`/`denseCount`, `AssistantAdapter` and `OwnedImport`
  call sites, and now the `Actions.normalizeSequence` carrier) — no site runs
  its own `pairs` density verdict.
- `PolicyCodec.classify` keeps its own key-scan loop, which is the frozen
  X-doubleprime codec internals (byte-identical to `main`, invariant): it runs
  on the codec's own decoded-document domain, and for array-marked tables it
  delegates to `Json.denseArray`/`denseFault` anyway. It is not a caller-array
  checklist-A ingress.
- Every other `pairs` loop under `overload/` is an object key-allowance /
  unexpected-field check (closed-field validation), not an array-density
  decision.
