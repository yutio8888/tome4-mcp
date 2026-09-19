#!/usr/bin/env python3
"""Executable form of the project's boundary checklist (AGENTS.md "边界输入与引擎字段清单").

The same defect family kept reaching review in different places ("partial/unvalidated input
measured as complete", "engine-consulted field silently dropped", "state transition twice"), so
this tool turns the checklist into a pre-commit self-check:

  A. caller-supplied arrays must be dense+closed validated BEFORE any `#`/`ipairs`/length use;
  B. every engine-consulted raised-spec field must be forwarded (explicit `false` preserved) or
     recorded as an explicit unknown -> fail-closed, never silently dropped;
  C. a missing/malformed input must converge to unknown, never to a smaller complete set;
  D. a mismatch must advance the generation exactly once;
  E. docs must not claim unobserved native rows.

A-B are checked structurally here (they are the two mechanical ones). C-E are **not** decidable by
a lint, so they are always reported as REVIEW (never PASS) and name the regressions that enforce
them. A green run therefore never overclaims.

Usage:
  python3 tools/check_boundary_rules.py --check     # exit 1 on any A/B FAIL (used by tests/run.sh)
  python3 tools/check_boundary_rules.py             # report only
  python3 tools/check_boundary_rules.py --list      # list every scanned caller-data site

Detection notes (kept honest on purpose):
  * A "caller-data" expression is one whose leaf identifier is `plan`, `target_plan`,
    `request_sequence` or `declared`, or the qualified `plan.values`, `action.sequence`,
    `candidates.cells`. This deliberately does NOT match every `#` on every array (that would be
    noise); it matches the names the defect family actually appeared on.
  * An "array use" counts as guarded when a dense validator was called on the same expression
    earlier in the enclosing function (the scan stops at the enclosing `function` line). Domain
    validators (`normalizeRequestSequence`, `normalizeSequence`) count only when they name the
    expression, and the shared `Json.denseArray`/`MovementAdapterFactory.validateArray` always do.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ADDON = Path(__file__).resolve().parent.parent
OVERLOAD = ADDON / "overload"

# ---------------------------------------------------------------------------
# A. Dense/closed validation before `#`/`ipairs` on caller-supplied data.
# ---------------------------------------------------------------------------
_NAME = r"[A-Za-z_]\w*"
_CHAIN = rf"{_NAME}(?:\s*(?:\[[^\]]*\]|\.\s*{_NAME}))*"
LENGTH_USE = re.compile(rf"#\s*(?P<expr>{_CHAIN})")
IPAIRS_USE = re.compile(rf"\bipairs\s*\(\s*(?P<expr>{_CHAIN})\s*[,)]")
_DENSE_FUNCS = (
    "denseArray|validateArray|validateDense|isDenseArray|normalizeDenseArray|"
    "normalizeRequestSequence|normalizeSequence|assertDense|validateKeys"
)
DENSE_CALL = re.compile(rf"\b(?:{_DENSE_FUNCS})\s*\(\s*(?P<args>[^()]*)\)")

# Callers whose array is caller-supplied: leaf identifiers, and the exact qualified forms that
# carry policy/plan/candidate data.
_LEAF_CALLER = {"plan", "target_plan", "request_sequence", "declared"}


def _identifiers(expr: str) -> list[str]:
    """Identifiers of an expression, with `[...]` indices treated as separators."""
    clean = re.sub(r"\[[^\]]*\]", ".", expr)
    return [part for part in re.split(r"[.\s]+", clean) if part]


def caller_kind(expr: str) -> str | None:
    """Return 'caller' when `expr` is caller-supplied data, else None."""
    ids = _identifiers(expr)
    if not ids:
        return None
    leaf, quals = ids[-1], ids[:-1]
    if leaf in _LEAF_CALLER:
        return "caller"
    # `plan.values`, `action.sequence`, `candidates.cells`.
    if leaf == "values" and quals and quals[-1] == "plan":
        return "caller"
    if leaf == "sequence" and quals and quals[-1] == "action":
        return "caller"
    if leaf == "cells" and quals and quals[-1] == "candidates":
        return "caller"
    return None


def _strip_comment(line: str) -> str:
    """Drop a trailing `--` comment (naive but sufficient for these sources)."""
    marker = line.find("--")
    return line if marker < 0 else line[:marker]


# Assignment that binds a local (or reassigns a name) to some expression.
_ASSIGN = re.compile(r"\s*(?:local\s+)?([A-Za-z_]\w*)\s*=\s*(.+)$")


def alias_roots(lines: list[str]) -> list[dict[str, str]]:
    """Per-line map of local name -> the caller-data expression it aliases.

    `local sequence=movement.request_sequence; #sequence` is the same defect as a direct read, so
    the lint follows one level (and chains) of locals. The map is order-sensitive and cleared when
    a name is reassigned to something that is not caller data (a conservative approximation: a
    stale alias can only ever add a real site, never hide one).
    """
    roots: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for raw in lines:
        code = _strip_comment(raw)
        match = _ASSIGN.match(code)
        if match:
            name, rhs = match.group(1), match.group(2)
            found = None
            for expr in re.findall(rf"{_CHAIN}", rhs):
                if caller_kind(expr) == "caller":
                    found = expr
                else:
                    ids = _identifiers(expr)
                    if ids and current.get(ids[-1]):
                        found = current[ids[-1]]
            if found is not None:
                current = dict(current)
                current[name] = found
            elif name in current and re.match(r"\s*(?:local\s+)?" + re.escape(name) + r"\s*=", code):
                current = dict(current)
                del current[name]
        roots.append(dict(current))
    return roots


def _norm(text: str) -> str:
    return re.sub(r"\s+", "", text)


def _guarded(lines: list[str], index: int, expr: str, root: str | None = None) -> bool:
    """A dense validator named the same expression (or its alias root) earlier in the function."""
    targets = {_norm(expr)}
    if root is not None:
        targets.add(_norm(root))
    ids = _identifiers(expr)
    leaf = ids[-1] if ids else expr
    bare = len(ids) <= 1
    for back in range(index, max(-1, index - 400), -1):
        code = _strip_comment(lines[back])
        for match in DENSE_CALL.finditer(code):
            args = _norm(match.group("args"))
            for arg in args.split(","):
                if not arg:
                    continue
                if arg in targets:
                    return True
                # `denseArray(plan,1)` guards the bare alias read as `#plan`.
                if bare and _identifiers(arg)[-1:] == [leaf]:
                    return True
        # Stop at the enclosing function boundary (never let another function's guard count).
        if re.match(r"\s*(?:local\s+)?function\b", code) and back != index:
            break
    return False


def scan_text(text: str) -> list[dict]:
    """Every `#`/`ipairs` use on a caller-data expression (direct or one-hop alias)."""
    sites: list[dict] = []
    lines = text.splitlines()
    roots = alias_roots(lines)
    for i, raw in enumerate(lines):
        code = _strip_comment(raw)
        for pattern, kind in ((LENGTH_USE, "#"), (IPAIRS_USE, "ipairs")):
            # Every match on the line (`#a and #b` has two independent uses).
            for match in pattern.finditer(code):
                expr = match.group("expr")
                ids = _identifiers(expr)
                root = None
                if caller_kind(expr) == "caller":
                    root = expr
                elif ids and roots[i].get(ids[-1]):
                    # A local alias of caller data (the leaf is the alias name).
                    root = roots[i][ids[-1]]
                if root is None:
                    continue
                sites.append({
                    "line": i + 1,
                    "expr": expr,
                    "kind": kind,
                    "aliased": root != expr,
                    "guarded": _guarded(lines, i, expr, root),
                })
    return sites


def scan_sites() -> list[dict]:
    sites: list[dict] = []
    for path in sorted(OVERLOAD.rglob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(ADDON).as_posix()
        for site in scan_text(text):
            site["path"] = rel
            sites.append(site)
    return sites


# ---------------------------------------------------------------------------
# Self-test: the detector must flag a real violation and clear a guarded form.
# ---------------------------------------------------------------------------
SELF_TEST_A = r'''
local function unguarded(plan)
    if #plan > 8 then return nil end
    for i, step in ipairs(plan) do local x = step end
    return #plan
end
local function guarded(plan)
    local ok = validateArray(plan, 1)
    if not ok then return nil end
    if #plan > 8 then return nil end
    for i, step in ipairs(plan) do local x = step end
end
local function qualified(attempt)
    -- an unguarded qualified read is still a violation
    if #attempt.target_plan > 1 then return nil end
end
local function inline_guard(plan)
    if not denseArray(plan) then return nil end
    for i, step in ipairs(plan) do local x = step end
end
local function aliased(attempt)
    local seq = attempt.target_plan
    return #seq
end
local function aliased_guarded(attempt)
    local seq = attempt.target_plan
    if not Json.denseArray(seq, 1) then return nil end
    return #seq
end
'''
SELF_TEST_B_GOOD = ("local FOOTPRINT_FLAGS = {'friendlyblock','friendlyfire','selffire',"
                    "'pass_terrain','no_restrict','actorblock','stop_block','force_max_range',"
                    "'min_range','grid_exclude','requires_knowledge','block_path','block_radius',"
                    "'filter','act_exclude'}\n")
SELF_TEST_B_BAD = "local FOOTPRINT_FLAGS = {'friendlyblock'}\n"


def _self_test_forwarder(text: str) -> list[str]:
    match = re.search(r"FOOTPRINT_FLAGS\s*=\s*\{(.*?)\}", text, re.S)
    forwarded = set(re.findall(r"'([a-z_]+)'", match.group(1)))
    return [f for f in ENGINE_FOOTPRINT_FIELDS if f not in forwarded]


def self_test() -> int:
    failures: list[str] = []
    parsed = scan_text(SELF_TEST_A)
    if not any(s["expr"] == "plan" and not s["guarded"] for s in parsed):
        failures.append("A: an unguarded #plan/ipairs(plan) was not flagged")
    if not any(s["expr"] == "attempt.target_plan" and not s["guarded"] for s in parsed):
        failures.append("A: an unguarded #attempt.target_plan was not flagged")
    if not any(s["guarded"] for s in parsed):
        failures.append("A: a validateArray/denseArray-guarded site was not recognised")
    if not any(s["aliased"] and not s["guarded"] for s in parsed):
        failures.append("A: an aliased unguarded caller-data read was not flagged")
    if not any(s["aliased"] and s["guarded"] for s in parsed):
        failures.append("A: an aliased guarded caller-data read was not recognised")
    if not _self_test_forwarder(SELF_TEST_B_BAD):
        failures.append("B: an incomplete synthetic forwarder was not reported incomplete")
    if _self_test_forwarder(SELF_TEST_B_GOOD):
        failures.append("B: the complete synthetic forwarder was reported incomplete")
    for failure in failures:
        print("SELF-TEST FAIL:", failure, file=sys.stderr)
    if failures:
        return 1
    print("self-test: OK (A flags unguarded caller-data #/ipairs, direct and aliased, and clears "
          "guarded forms; B rejects an incomplete forwarder)")
    return 0


# ---------------------------------------------------------------------------
# B. Engine-consulted raised-spec fields: forwarded, or explicitly fail-closed.
# ---------------------------------------------------------------------------
# The engine consults these when building a projection footprint
# (ActorProject.lua / Target.lua). Source of truth is the engine; the list is asserted
# against the engine by engine_drift_notes() so it cannot silently drift.
ENGINE_FOOTPRINT_FIELDS = [
    "friendlyblock", "friendlyfire", "selffire", "pass_terrain", "no_restrict",
    "actorblock", "stop_block", "force_max_range", "min_range", "grid_exclude",
    "requires_knowledge", "block_path", "block_radius", "filter", "act_exclude",
]
# Fields whose ENGINE type is function (or function|false). A malformed value must fail closed.
FUNCTION_VALUED = ["block_path", "block_radius", "filter"]

ENGINE_SOURCES = [
    "game/engines/default/engine/Target.lua",
    "game/engines/default/engine/interface/ActorProject.lua",
]


def _engine_texts() -> dict[str, str]:
    root = ADDON.parent.parent.parent
    texts = {}
    for rel in ENGINE_SOURCES:
        path = root / rel
        if path.exists():
            texts[rel] = path.read_text(encoding="utf-8", errors="replace")
    return texts


def engine_drift_notes() -> list[str]:
    """Assert the declared list against the engine sources (drift detector)."""
    notes = []
    texts = _engine_texts()
    missing_sources = [rel for rel in ENGINE_SOURCES if rel not in texts]
    if missing_sources:
        notes.append("engine source(s) not found, cannot verify the field list: "
                     + ", ".join(missing_sources))
        return notes
    absent = [f for f in ENGINE_FOOTPRINT_FIELDS if not any(f in t for t in texts.values())]
    if absent:
        notes.append("declared field(s) not mentioned by any projection source (list drift?): "
                     + ", ".join(absent))
    return notes


def check_rule_b() -> tuple[str, list[str]]:
    """Return (status, findings) where status is PASS/FAIL/REVIEW.

    The forwarder is introduced by proposal A'; on a tree where it does not exist yet there is
    nothing to forward, so that state is REVIEW (not PASS, not FAIL) — the rule only bites once
    the mechanism exists. A forwarder that exists but drops a field is a FAIL.
    """
    forwarder = None
    for path in sorted(OVERLOAD.rglob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "FOOTPRINT_FLAGS" in text or "copyFootprintFlags" in text:
            forwarder = (path, text)
            break
    if forwarder is None:
        drift = engine_drift_notes()
        detail = "no raised-field forwarder on this tree; rule applies once proposal A' lands"
        if drift:
            return "FAIL", [detail] + drift
        return "REVIEW", [detail]
    path, text = forwarder
    rel = path.relative_to(ADDON).as_posix()
    findings: list[str] = []
    match = re.search(r"FOOTPRINT_FLAGS\s*=\s*\{(.*?)\}", text, re.S)
    if not match:
        return "FAIL", [f"{rel}: a forwarder exists but no FOOTPRINT_FLAGS list was found"]
    forwarded = set(re.findall(r"'([a-z_]+)'", match.group(1)))
    missing = [f for f in ENGINE_FOOTPRINT_FIELDS if f not in forwarded]
    unresolved = []
    for field in missing:
        if not re.search(rf"{field}[^\n]{{0,120}}(fail[- ]closed|unknown)", text, re.I):
            unresolved.append(field)
    if unresolved:
        findings.append(f"{rel}: FOOTPRINT_FLAGS omits engine-consulted field(s) with no "
                        f"explicit fail-closed note: {', '.join(unresolved)}")
    # Function-valued fields must be type-checked (fail closed on a malformed value).
    for field in FUNCTION_VALUED:
        if not re.search(rf"type\s*\(\s*[a-zA-Z_.\[\]]*\b{field}\b\s*\)\s*[=~]=\s*'function'", text):
            findings.append(f"{rel}: `{field}` is function-valued but has no `type(...)=='function'` "
                            "check (a malformed value must fail closed)")
    findings.extend(engine_drift_notes())
    return ("FAIL" if findings else "PASS"), findings


# ---------------------------------------------------------------------------
# C/D/E: not structurally decidable; always REVIEW, naming the enforcing regressions.
# ---------------------------------------------------------------------------
C_EVIDENCE = [
    ("tests/test_effect_footprint.lua", "a native expansion failure is unknown, not the model"),
    ("tests/test_auto_combat_guard.lua", "an unresolved branch stays in the conservative union"),
    ("tests/test_auto_combat_movement.lua", "unknown passability/hazard stay unknown"),
]
D_EVIDENCE = [
    ("tests/test_auto_combat_controller.lua", "pass/stop dedupe does not advance the generation"),
]
E_EVIDENCE = [
    ("VALIDATION.md", "unobserved native rows must not claim PASS"),
    ("tools/verify_validation_manifest.py", "evidence hashes must exist and match"),
]


def _evidence(rows: list[tuple[str, str]]) -> str:
    parts = []
    for rel, what in rows:
        exists = (ADDON / rel).exists()
        parts.append(f"{rel} ({what})" + ("" if exists else " [MISSING]"))
    return "；".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit non-zero on any A/B FAIL")
    ap.add_argument("--list", action="store_true", help="list every scanned caller-data site")
    ap.add_argument("--self-test", action="store_true", help="prove the A/B detectors fire and clear")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    sites = scan_sites()
    unguarded = [s for s in sites if not s["guarded"]]
    b_status, b_findings = check_rule_b()

    if args.list:
        print("A. every scanned `#`/`ipairs` on caller-data (direct or aliased):")
        for s in sites:
            flag = "unguarded" if not s["guarded"] else "guarded"
            alias = " (alias)" if s["aliased"] else ""
            print(f"    {s['path']}:{s['line']}: {s['kind']} {s['expr']}{alias}  [{flag}]")
        print()

    failures: list[str] = []
    if unguarded:
        print(f"A. dense-validation: FAIL ({len(unguarded)}/{len(sites)} caller-data site(s) "
              f"use #/ipairs without a dense validator in scope)")
        for s in unguarded:
            print(f"     {s['path']}:{s['line']}: {s['kind']} {s['expr']}")
            failures.append(f"{s['path']}:{s['line']}: {s['kind']} {s['expr']}")
    else:
        print(f"A. dense-validation: PASS (all {len(sites)} caller-data #/ipairs sites are "
              f"guarded by a dense validator)")

    if b_status == "FAIL":
        print("B. engine-field forwarding: FAIL")
        failures.extend(b_findings)
    else:
        print(f"B. engine-field forwarding: {b_status}")
    for finding in b_findings:
        print("   ", finding)

    print("C. malformed input -> unknown        : REVIEW (enforced by: " + _evidence(C_EVIDENCE) + ")")
    print("D. exactly-once state transition     : REVIEW (enforced by: " + _evidence(D_EVIDENCE) + ")")
    print("E. docs match observed native rows   : REVIEW (enforced by: " + _evidence(E_EVIDENCE) + ")")

    if failures:
        print(f"\n{len(failures)} boundary-rule finding(s).", file=sys.stderr)
        return 1 if args.check else 0
    print("\nboundary rules: OK (A/B structural; C/D/E are REVIEW by design)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
