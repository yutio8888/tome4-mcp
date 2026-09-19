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
  python3 tools/check_boundary_rules.py --self-test # prove the A/B detectors fire and clear

## Provenance model (BND-REV-01 revision 2)

A lint cannot infer "caller-supplied" from Lua source by spelling. Instead of a name allowlist,
the provenance model is an EXPLICIT INGRESS REGISTRY kept beside the validator (INGRESS_ARRAYS
below): a (file, function) entry listing the caller-data arrays that enter there, written as
they appear at the ingress (a registered ingress parameter like `plan`, a field chain like
`policy.rules`, or a validated local carrier like `action.sequence`). The registry carries the
load three ways:

  1. Registry conformance: every registered array must be dense-validated (a canonical
     `Json.denseArray`/domain-validator call on it, direct or through a local/field alias)
     INSIDE its registered function. Reverting a guard to a weak `isArray` + `#`/`ipairs` —
     the reviewer's sparse-`policy.rules` reproduction, where a valid rule at index 1 and an
     INVALID rule at index 3 measured as `schema_ok=true errors=0 lua_len=1` — now fails the
     lint, instead of reporting "all 0 sites are guarded" about an array it could not see.
  2. Generic sweep: any `#`/`ipairs` on an expression rooted at a registered ingress parameter
     (direct, local alias, multi-hop alias, field/index chain) is a site that must be guarded;
     a chain whose leaf field is neither in the file's registered `array` nor `scalar` field
     set is UNCATALOGUED and fails the run until classified.
  3. Registry rot: a registered function that no longer exists, or a registered array whose
     file no longer mentions it, fails the run — the registry is updated in the same change.

Stated limits (what this lint CANNOT see — kept explicit on purpose, per the review):
  * An array field that is NOT registered and is never measured with `#`/`ipairs` inside a
    registered function is invisible. Rule A only bites on measurement; a new caller-data
    entry point or array field must be registered in the same change (the uncatalogued sweep
    catches any new MEASURED field; the registry check catches the declared ones).
  * Provenance is per (file, function). A curated internal function whose parameter merely
    shares a name with a registered ingress parameter is not flagged (collisions resolve by
    the registry key, not spelling).
  * Guards are recognised by consumption/branch shape, not full dataflow: the validator call
    must be bound to a local and the invalid path must exit (or the use must lie inside the
    validated branch). Exotic control flow outside these shapes is reported unguarded —
    fail-noisy by design, never fail-silent.
  * `pairs()` walks are key-agnostic (no length/truncation) and out of scope for rule A.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ADDON = Path(__file__).resolve().parent.parent
OVERLOAD = ADDON / "overload"

# ---------------------------------------------------------------------------
# Lua source hygiene: comments out, strings optionally blanked.
# ---------------------------------------------------------------------------
def lua_code_lines(text: str, blank_strings: bool = True) -> list[str]:
    """Per-line Lua code with comments removed (line count preserved).

    Handles `--` line comments, `--[[..]]`/`--[=[..]=]` long comments, quoted
    strings with escapes, and `[[..]]` long strings. With `blank_strings` the
    string contents are blanked (delimiters kept) so string keywords can never
    skew block counting; Rule B keeps them because typed outcome codes live in
    string literals.
    """
    out: list[str] = []
    line: list[str] = []
    i, n = 0, len(text)
    state = "code"  # code | line_comment | block_comment | quote | long_string
    quote = ""
    level = 0
    while i < n:
        ch = text[i]
        if ch == "\n":
            out.append("".join(line))
            line = []
            if state == "line_comment":
                state = "code"
            i += 1
            continue
        if state == "code":
            if ch == "-" and i + 1 < n and text[i + 1] == "-":
                m = re.match(r"-+\[(=*)\[", text[i:])
                if m:
                    level = len(m.group(1))
                    state = "block_comment"
                    i += m.end()
                    continue
                state = "line_comment"
                i += 2
                continue
            if ch in "'\"":
                state = "quote"
                quote = ch
                line.append(ch)
                i += 1
                continue
            if ch == "[":
                m = re.match(r"\[(=*)\[", text[i:])
                if m:
                    level = len(m.group(1))
                    state = "long_string"
                    line.append("[")
                    i += 1
                    continue
            line.append(ch)
            i += 1
            continue
        if state == "line_comment":
            i += 1
            continue
        if state == "block_comment":
            m = re.match(r"\](=*)\]", text[i:])
            if m and len(m.group(1)) == level:
                state = "code"
                i += m.end()
                continue
            i += 1
            continue
        if state == "quote":
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                state = "code"
                line.append(ch)
                i += 1
                continue
            if not blank_strings:
                line.append(ch)
            i += 1
            continue
        if state == "long_string":
            m = re.match(r"\](=*)\]", text[i:])
            if m and len(m.group(1)) == level:
                state = "code"
                line.append("]")
                i += m.end() if False else 1
                continue
            if not blank_strings:
                line.append(ch)
            i += 1
            continue
    out.append("".join(line))
    return out


# ---------------------------------------------------------------------------
# Block tracker: Lua block depth, enclosing functions, parameters.
# ---------------------------------------------------------------------------
_IF_WHILE = re.compile(r"\b(?:if|while)\b")
_FOR = re.compile(r"\bfor\b")
_DO = re.compile(r"\bdo\b")
_FUNC = re.compile(r"\bfunction\b")
_REPEAT = re.compile(r"\brepeat\b")
_END = re.compile(r"\bend\b")
_UNTIL = re.compile(r"\buntil\b")
_NAMED_FUNC = re.compile(r"\bfunction\s+([\w.]+)\s*\(([^)]*)\)")
_ASSIGNED_FUNC = re.compile(r"([\w.]+)\s*=\s*function\s*\(([^)]*)\)")


class BlockAnalysis:
    """Per-line Lua block data for one (comment-stripped) file."""

    def __init__(self, code: list[str]):
        self.code = code
        self.depth_before: list[int] = []
        self.depth_after: list[int] = []
        self.func_open_line: list[bool] = []
        self.func_name: list[str | None] = []
        self.func_params: list[set[str]] = []
        self.enclosing_funcs: list[list[int]] = []   # open-line indices, innermost last
        self.if_end: dict[int, int] = {}             # if-line -> closing/end line
        self.if_else: dict[int, int] = {}            # if-line -> `else` line (or absent)
        self._analyze()

    def _deltas(self, line: str) -> tuple[int, int]:
        opens = len(_IF_WHILE.findall(line)) + len(_FOR.findall(line)) \
            + len(_REPEAT.findall(line)) + len(_FUNC.findall(line))
        standalone_do = len(_DO.findall(line)) - len(_FOR.findall(line)) \
            - len(_IF_WHILE.findall(line))
        opens += max(0, standalone_do)
        closes = len(_END.findall(line)) + len(_UNTIL.findall(line))
        return opens, closes

    def _analyze(self) -> None:
        stack: list[tuple[str, int, set[str]]] = []  # (kind, open_line, params)
        depth = 0
        for i, line in enumerate(self.code):
            self.enclosing_funcs.append([op for kind, op, _ in reversed(stack) if kind == "function"])
            opens, closes = self._deltas(line)
            self.depth_before.append(depth)
            decl_name, decl_params = None, set()
            if opens:
                named = _NAMED_FUNC.search(line)
                assigned = None if named else _ASSIGNED_FUNC.search(line)
                m = named or assigned
                if m:
                    decl_name = m.group(1)
                    decl_params = {p.strip() for p in m.group(2).split(",") if p.strip()}
                    if named is None and ":" in decl_name:
                        decl_params.add("self")
                self.func_open_line.append(True)
                self.func_name.append(decl_name)
                self.func_params.append(decl_params)
                stack.append(("function", i, decl_params))
                for _ in range(opens - 1):
                    stack.append(("block", i, set()))
            else:
                self.func_open_line.append(False)
                self.func_name.append(None)
                self.func_params.append(set())
            for _ in range(closes):
                if stack:
                    stack.pop()
            depth += opens - closes
            self.depth_after.append(depth)
        self._locate_ifs()

    def _locate_ifs(self) -> None:
        for i, line in enumerate(self.code):
            if not re.match(r"^\s*(?:elseif\s+)?if\b", line):
                continue
            d = self.depth_before[i]
            self_closed = self.depth_after[i] <= d
            if self_closed:
                self.if_end[i] = i
                continue
            else_line, end_line = None, None
            for j in range(i + 1, len(self.code)):
                db, da = self.depth_before[j], self.depth_after[j]
                stripped = self.code[j].strip()
                if db == d + 1:
                    if stripped.startswith("else") and else_line is None:
                        else_line = j
                    if stripped.startswith("end"):
                        end_line = j
                        break
                if db <= d:
                    end_line = j
                    break
            self.if_end[i] = end_line if end_line is not None else len(self.code) - 1
            if else_line is not None:
                self.if_else[i] = else_line

    def nearest_func(self, i: int) -> int:
        funcs = self.enclosing_funcs[i]
        return funcs[-1] if funcs else -1

    def params_in_scope(self, i: int) -> set[str]:
        """Parameters of every function scope enclosing line i (upvalues count)."""
        params: set[str] = set()
        for op in self.enclosing_funcs[i]:
            params |= self.func_params[op]
        return params


# ---------------------------------------------------------------------------
# A. Dense/closed validation before `#`/`ipairs` on caller-supplied data.
# ---------------------------------------------------------------------------
_NAME = r"[A-Za-z_]\w*"
_CHAIN = rf"{_NAME}(?:\s*(?:\[[^\]]*\]|\.\s*{_NAME}))*"
LENGTH_USE = re.compile(rf"#\s*(?P<expr>{_CHAIN})")
IPAIRS_USE = re.compile(rf"\bipairs\s*\(\s*(?P<expr>{_CHAIN})\s*[,)]")
# Canonical dense validators. Domain validators (`denseChildren`, `validateArray`,
# ...) count only when their argument names the expression (like the old rule).
DENSE_FUNCS = (
    "denseArray|validateArray|validateDense|isDenseArray|normalizeDenseArray|"
    "normalizeRequestSequence|normalizeSequence|assertDense|validateKeys|denseChildren"
)
DENSE_CALL = re.compile(rf"\b(?:{DENSE_FUNCS})\s*\(\s*(?P<args>[^()]*)\)")
_ASSIGN = re.compile(r"^\s*(?:local\s+)?([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*=\s*(.+)$")
_ASSIGN_FIELD = re.compile(r"^\s*([A-Za-z_]\w*\.[A-Za-z_]\w*)\s*=\s*(.+)$")
_IF_PREFIX = re.compile(r"^\s*(?:elseif\s+)?(?:if\b.*?\bthen\b|else\b)\s*(.+)$")

# ---------------------------------------------------------------------------
# Ingress registry (BND-REV-01 rev2): the explicit provenance model, kept
# beside the validator on purpose. (file, function) -> caller-data arrays.
# ---------------------------------------------------------------------------
INGRESS_ARRAYS: dict[tuple[str, str], list[str]] = {
    ("overload/mod/auto_combat/PolicySchema.lua", "M.validate"):
        ["policy.rules", "policy.sustains", "policy.targeting.tie_break"],
    ("overload/mod/auto_combat/PolicySchema.lua", "validateCondition"):
        ["cond.all", "cond.any"],
    ("overload/mod/auto_combat/PolicySchema.lua", "validateTargetPlan"):
        ["plan"],
    ("overload/mod/auto_combat/PolicySchema.lua", "validateDestination"):
        [],
    ("overload/mod/auto_combat/EffectManifest.lua", "M.verify"):
        ["policy.rules", "policy.sustains", "rule['then'].target_plan"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "M.evaluate"):
        ["policy.rules"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "M.evalCondition"):
        ["cond.all", "cond.any"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "isSafety"):
        ["cond.all", "cond.any"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "actorStepSelector"):
        ["then_.target_plan"],
    ("overload/mod/auto_combat/MovementPlanner.lua", "M.planSequence"):
        ["movement.request_sequence", "attempt.target_plan"],
    ("overload/mod/auto_combat/MovementPlanner.lua", "M.plan"):
        ["attempt.target_plan", "movement.request_sequence"],
    ("overload/mod/auto_combat/MovementAdapterFactory.lua", "validateArray"):
        ["list"],
    ("overload/mod/mcp_bridge/Actions.lua", "M.execute"):
        ["action.sequence"],
    ("overload/mod/mcp_bridge/Actions.lua", "M.normalizeSequence"):
        ["list"],
    ("overload/mod/mcp_bridge/Runtime.lua", "reads.execute"):
        ["action.sequence", "attempt.plan.values"],
    ("overload/mod/auto_combat/AutoCombatService.lua", "findRule"):
        ["policy.rules"],
    ("overload/mod/auto_combat/PolicyEditorModel.lua", "M.fields"):
        ["policy.rules"],
}

# Caller-data fields per file, classified by kind. `array` fields must be
# dense-validated before any measurement; `scalar` fields are vetted
# non-arrays (never length-measured as caller arrays). An unclassified field
# reached by a `#`/`ipairs` site is UNCATALOGUED and fails the run.
# Registered ingress parameters per (file, function): the parameters that
# carry caller-controlled data at that entry point. The sweep treats such a
# parameter, and anything derived from it (field/index chain or local alias),
# as caller data. Provenance is per (file, function): a curated internal
# function whose parameter merely shares a name is NOT caller data.
INGRESS_PARAMS: dict[tuple[str, str], list[str]] = {
    ("overload/mod/auto_combat/PolicySchema.lua", "M.validate"): ["policy"],
    ("overload/mod/auto_combat/PolicySchema.lua", "validateCondition"): ["cond"],
    ("overload/mod/auto_combat/PolicySchema.lua", "validateTargetPlan"): ["plan"],
    ("overload/mod/auto_combat/EffectManifest.lua", "M.verify"): ["policy"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "M.evaluate"): ["policy"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "M.evalCondition"): ["cond"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "isSafety"): ["cond"],
    ("overload/mod/auto_combat/PolicyEvaluator.lua", "actorStepSelector"): ["then_"],
    ("overload/mod/auto_combat/MovementPlanner.lua", "M.planSequence"): ["attempt", "movement"],
    ("overload/mod/auto_combat/MovementPlanner.lua", "M.plan"): ["attempt", "movement"],
    ("overload/mod/auto_combat/MovementAdapterFactory.lua", "validateArray"): ["list"],
    ("overload/mod/mcp_bridge/Actions.lua", "M.execute"): ["action"],
    ("overload/mod/mcp_bridge/Actions.lua", "M.normalizeSequence"): ["list"],
    ("overload/mod/mcp_bridge/Runtime.lua", "reads.execute"): ["attempt"],
    ("overload/mod/auto_combat/AutoCombatService.lua", "findRule"): ["policy"],
    ("overload/mod/auto_combat/PolicyEditorModel.lua", "M.fields"): ["policy"],
}

# Caller-data fields per file, classified by kind. `array` fields must be
INGRESS_FIELD_KINDS: dict[str, dict[str, set[str]]] = {
    "overload/mod/auto_combat/PolicySchema.lua": {
        "array": {"rules", "sustains", "all", "any", "tie_break", "target_plan"},
        "scalar": {"id", "name", "schema", "class", "updated", "mode", "limits",
                   "safety", "targeting", "logging", "when", "then", "action",
                   "talent", "target", "destination", "request", "accept",
                   "anchor", "x", "y", "dx", "dy", "distance", "kind", "priority",
                   "enabled", "emergency", "max_rules", "selector", "default"},
    },
    "overload/mod/auto_combat/EffectManifest.lua": {
        "array": {"rules", "sustains", "target_plan"},
        "scalar": {"action", "talent", "target", "then", "id", "priority",
                   "when", "emergency", "enabled", "targeting", "default"},
    },
    "overload/mod/auto_combat/PolicyEvaluator.lua": {
        "array": {"all", "any", "target_plan", "rules"},
        "scalar": {"then", "action", "talent", "target", "selector", "destination",
                   "direction", "max_turns", "enabled", "emergency", "priority",
                   "id", "when", "targeting", "default", "limits", "safety", "mode"},
    },
    "overload/mod/auto_combat/MovementPlanner.lua": {
        "array": {"target_plan", "request_sequence"},
        "scalar": {"talent", "destination", "bound_target", "exclude", "request",
                   "selector", "landing", "annotation", "kind", "accept"},
    },
    "overload/mod/mcp_bridge/Actions.lua": {
        "array": {"sequence"},
        "scalar": {"type", "talent_id", "x", "y", "authoritative_target"},
    },
    "overload/mod/mcp_bridge/Runtime.lua": {
        "array": {"sequence", "values", "target_plan"},
        "scalar": {"kind", "talent", "x", "y", "steps", "annotation",
                   "request_sequence", "type"},
    },
    "overload/mod/auto_combat/AutoCombatService.lua": {
        "array": {"rules"},
        "scalar": {"id"},
    },
    "overload/mod/auto_combat/PolicyEditorModel.lua": {
        "array": {"rules"},
        "scalar": {"id", "limits", "safety", "mode"},
    },
}


def _identifiers(expr: str) -> list[str]:
    clean = re.sub(r"\[[^\]]*\]", ".", expr)
    return [part for part in re.split(r"[.\s]+", clean) if part]


def _norm(text: str) -> str:
    return re.sub(r"\s+", "", text)


def _norm_chain(text: str) -> str:
    """Canonical chain form: whitespace and quoted-string contents removed and
    the result reduced to its identifier chain, so the registry's written form
    (`rule['then'].target_plan`) and the blanked scan form (`rule[''].target_plan`)
    compare equal (`rule.target_plan`)."""
    return ".".join(_identifiers(text))


def _assigns(code: list[str], scope_params: list[set[str]]) -> list[dict[str, list[str]]]:
    """Per-line alias map: local name -> caller-data chain(s) it aliases.

    Handles chained aliases (`local b=a.values` where `a` aliases caller data
    yields the one-hop field alias `plan.values`) and multi-target assigns
    (`local a,b=x,y`). An RHS is caller data only when it roots at an ingress
    parameter IN SCOPE on that line (or at a recorded alias) — a curated
    internal parameter that merely shares a name is not caller data.
    Comparison RHS (`x==y`) is not an assignment. A name reassigned to
    non-caller data drops its alias (conservative: a stale alias can only ever
    ADD a site, never hide one).
    """
    maps: list[dict[str, list[str]]] = []
    current: dict[str, list[str]] = {}
    for i, raw in enumerate(code):
        m = _ASSIGN.match(raw)
        if m is None:
            pm = _IF_PREFIX.match(raw)
            if pm:
                m = _ASSIGN.match(pm.group(1))
        if m:
            names = [n.strip() for n in m.group(1).split(",")]
            rhs = m.group(2)
            found: list[str] | None = None
            # only the LEADING chain of each top-level alternative (`a and a.x`,
            # `x or y`) may alias caller data — a chain nested inside a table
            # constructor or a call (`local t={field=caller.value}`) does not
            # make the whole assigned value caller data.
            for expr in _top_chains(rhs):
                ids = _identifiers(expr)
                if not ids:
                    continue
                if ids[0] in current:
                    chains = [_identifiers(r) + ids[1:] for r in current[ids[0]]]
                elif ids[0] in scope_params[i]:
                    chains = [ids]
                else:
                    chains = None
                if chains:
                    found = [".".join(c) for c in chains]
            if found is not None:
                current = dict(current)
                for name in names:
                    if name != "_":
                        current[name] = found
            else:
                for name in names:
                    if name in current:
                        current = dict(current)
                        del current[name]
        else:
            # field-LHS carrier copy (`action.sequence=plan.values`): the dotted
            # LHS becomes a chain-alias of the resolved caller-data chain.
            fm = _ASSIGN_FIELD.match(raw)
            if fm is None:
                pm = _IF_PREFIX.match(raw)
                if pm:
                    fm = _ASSIGN_FIELD.match(pm.group(1))
            if fm:
                lhs, rhs = fm.group(1), fm.group(2)
                found = None
                for expr in _top_chains(rhs):
                    ids = _identifiers(expr)
                    if not ids:
                        continue
                    if ids[0] in current:
                        chains = [_identifiers(r) + ids[1:] for r in current[ids[0]]]
                    elif ids[0] in scope_params[i]:
                        chains = [ids]
                    else:
                        chains = None
                    if chains:
                        found = [".".join(c) for c in chains]
                if found is not None:
                    current = dict(current)
                    current[lhs] = found
                elif lhs in current:
                    current = dict(current)
                    del current[lhs]
        maps.append(dict(current))
    return maps


def _top_chains(rhs: str) -> list[str]:
    """The leading chain of each top-level `and`/`or` alternative of an RHS."""
    rhs = rhs.strip()
    if rhs.startswith("{"):
        return []
    out = []
    for alt in re.split(r"\band\b|\bor\b", rhs):
        alt = alt.strip()
        m = re.match(_CHAIN, alt)
        if m:
            out.append(m.group(0))
    return out


def _binding_of(line: str) -> tuple[list[str], str] | None:
    """`local a,b = expr` -> (names, rhs) for a real assignment on the line."""
    m = _ASSIGN.match(line)
    if m is None:
        pm = _IF_PREFIX.match(line)
        if pm:
            line = pm.group(1)
            m = _ASSIGN.match(line)
    if m is None:
        return None
    rhs = m.group(2)
    if rhs.lstrip().startswith("="):
        return None
    return [n.strip() for n in m.group(1).split(",")], rhs


def _contains_return_error(lines: list[str], start: int, end: int) -> bool:
    for j in range(max(0, start), min(len(lines), end)):
        if re.search(r"\breturn\b|\berror\s*\(", lines[j]):
            return True
    return False


def _resolve_arg(arg: str, alias_map: dict[str, list[str]]) -> list[str]:
    """Canonical forms of a dense-validator argument: the raw identifier chain
    plus, when a local/field alias applies, its caller-data roots. The
    `and`/`or` split happens on the RAW text (before normalization)."""
    out: list[str] = []
    for part in re.split(r"\band\b|\bor\b", arg):
        part = part.strip()
        if not part:
            continue
        ids = _identifiers(part)
        if not ids:
            continue
        raw = ".".join(ids)
        out.append(raw)
        if ids[0] in alias_map:
            for root in alias_map[ids[0]]:
                out.append(".".join(_identifiers(root) + ids[1:]))
        elif part in alias_map:
            for root in alias_map[part]:
                out.append(".".join(_identifiers(root)))
    return out


def _consumed(blocks: BlockAnalysis, bind: int, use: int, var: str) -> tuple[bool, str]:
    """Verify the guard result `var` is consumed between `bind` and `use`:
    the invalid path must exit (return/error), or the use must be dominated by
    the validated branch (inside `if ok then` / inside the `else` of
    `if not ok`)."""
    code = blocks.code
    for j in range(bind + 1, use + 1):
        m = re.match(r"^\s*(?:elseif\s+)?if\s+(?P<cond>.+?)\s+then\b", code[j])
        if not m:
            continue
        cond = _norm(m.group("cond"))
        v = re.escape(var)
        invalid_test = re.search(rf"not{v}(?![\w])", cond) or re.search(rf"{v}==(?:false|nil)", cond)
        positive_test = re.fullmatch(rf"{v}(?:and.+)?", cond)
        if not (invalid_test or positive_test):
            continue
        self_closed = blocks.if_end.get(j) == j and blocks.depth_after[j] <= blocks.depth_before[j]
        end_j = blocks.if_end.get(j, use)
        else_j = blocks.if_else.get(j)
        then_end = (else_j if else_j is not None else end_j)
        if self_closed:
            # `if not ok then return ... end` all on one line
            body = code[j]
            if _contains_return_error([body], 0, len(body)):
                if use > j:
                    return True, f"invalid path exits at line {j + 1}"
                return False, f"use inside the invalid branch at line {j + 1}"
            if invalid_test:
                return False, f"invalid branch at line {j + 1} does not exit"
            return False, f"positive guard at line {j + 1} does not dominate the use"
        if invalid_test:
            if _contains_return_error(code, j + 1, then_end):
                if use > end_j or (else_j is not None and else_j < use <= end_j):
                    return True, f"invalid path exits at line {j + 1}"
                if use <= then_end:
                    return True, "use inside the invalid branch after its exit"
                return False, "invalid branch does not exit before the use"
            if else_j is not None and else_j < use <= end_j:
                return True, f"use inside the validated else of line {j + 1}"
            if j < use <= then_end:
                return False, f"use inside the invalid branch of line {j + 1} (no exit)"
            return False, f"invalid branch of line {j + 1} does not exit before the use"
        # positive test: dominated only inside the then-branch
        if j < use <= then_end:
            return True, f"use inside the validated then of line {j + 1}"
        if use > end_j and else_j is not None and _contains_return_error(code, else_j + 1, end_j):
            return True, f"invalid path exits in the else of line {j + 1}"
        return False, f"positive guard at line {j + 1} does not dominate the use"
    return False, f"`{var}` is bound but never tested before the use"


def guard_status(blocks: BlockAnalysis, use_index: int, targets: set[str],
                 aliases: list[dict[str, list[str]]]) -> tuple[bool, str]:
    """The same-function consumed-guard analysis (see module docstring)."""
    code = blocks.code
    near = blocks.nearest_func(use_index)
    for back in range(use_index - 1, max(-1, near), -1):
        if blocks.nearest_func(back) != near:
            continue
        binding = _binding_of(code[back])
        if not binding:
            continue
        names, rhs = binding
        for match in DENSE_CALL.finditer(rhs):
            arg_forms: set[str] = set()
            for arg in match.group("args").split(","):
                arg = arg.strip()
                if not arg:
                    continue
                for chain in _resolve_arg(arg, aliases[back]):
                    arg_forms.add(_norm(chain))
            if not arg_forms & targets:
                continue
            ok, why = _consumed(blocks, back, use_index, names[0])
            if ok:
                return True, (f"guarded by the dense validator bound at line {back + 1} "
                              f"(`{names[0]}`): {why}")
            return False, (f"line {back + 1}: `{names[0]}` is bound to a dense validator "
                           f"but not consumed as a guard: {why}")
    return False, "no consumed dense validator on this expression in the same function"


def scan_text(text: str, ingress: dict[str, list[str]] | None = None,
              array_fields: set[str] | None = None,
              scalar_fields: set[str] | None = None) -> list[dict]:
    """Every `#`/`ipairs` use on caller data (direct, aliased, field-chained).

    `ingress` maps registered ingress function name -> its ingress parameter
    names; `array_fields`/`scalar_fields` classify leaf fields. Defaults build
    the real-tree registry view.
    """
    if ingress is None:
        ingress = {name: params for (_, name), params in INGRESS_PARAMS.items() if params}
    if array_fields is None:
        array_fields = {f for kinds in INGRESS_FIELD_KINDS.values() for f in kinds.get("array", set())}
    if scalar_fields is None:
        scalar_fields = {f for kinds in INGRESS_FIELD_KINDS.values() for f in kinds.get("scalar", set())}

    code = lua_code_lines(text, blank_strings=True)
    blocks = BlockAnalysis(code)
    # an ingress parameter is in scope wherever its declaring (registered)
    # function is on the stack; alias resolution only trusts RHS rooted at
    # such a name.
    def _scope_params_at(i: int) -> set[str]:
        out: set[str] = set()
        for op in blocks.enclosing_funcs[i]:
            name = blocks.func_name[op]
            if name in ingress:
                out |= set(ingress[name])
        return out
    scope_params = [_scope_params_at(i) for i in range(len(code))]
    aliases = _assigns(code, scope_params)
    sites: list[dict] = []
    for i, line in enumerate(code):
        for pattern, kind in ((LENGTH_USE, "#"), (IPAIRS_USE, "ipairs")):
            for match in pattern.finditer(line):
                expr = match.group("expr")
                ids = _identifiers(expr)
                if not ids:
                    continue
                # only REGISTERED ingress parameters are caller data in scope
                params = scope_params[i]
                chains: list[list[str]] | None = None
                if ids[0] in params:
                    chains = [ids]
                elif ids[0] in aliases[i]:
                    chains = [_identifiers(r) + ids[1:] for r in aliases[i][ids[0]]]
                if chains is None:
                    continue
                for chain in chains:
                    if len(chain) > 1:
                        leaf = chain[-1]
                        if leaf in scalar_fields:
                            break  # vetted non-array: not a site
                        if leaf not in array_fields:
                            sites.append({
                                "line": i + 1, "expr": expr, "kind": kind,
                                "chain": ".".join(chain), "aliased": ids[0] not in params,
                                "guarded": False, "uncatalogued": True,
                            })
                            break
                    targets = {_norm(expr)} | {_norm(".".join(c)) for c in chains}
                    guarded, why = guard_status(blocks, i, targets, aliases)
                    sites.append({
                        "line": i + 1, "expr": expr, "kind": kind,
                        "chain": ".".join(chain),
                        "aliased": ids[0] not in params,
                        "guarded": guarded, "uncatalogued": False, "why": why,
                    })
                    break
    return sites


def _function_region(blocks: BlockAnalysis, open_line: int) -> tuple[int, int]:
    """[start, end] line indices of the function opened at `open_line`."""
    d = blocks.depth_before[open_line]
    for j in range(open_line + 1, len(blocks.code)):
        if blocks.depth_after[j] <= d:
            return open_line, j
    return open_line, len(blocks.code) - 1


def registry_check() -> tuple[list[str], list[str]]:
    """Registry conformance + rot (BND-REV-01 rev2). Returns (findings, rows)."""
    findings: list[str] = []
    rows: list[str] = []
    files: dict[str, tuple[str, BlockAnalysis, list[dict[str, list[str]]], dict[str, str]]] = {}
    for (rel, func), bindings in INGRESS_ARRAYS.items():
        path = ADDON / rel
        if rel not in files:
            if not path.exists():
                files[rel] = ("", None, [], {})
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            code = lua_code_lines(text, blank_strings=True)
            blocks = BlockAnalysis(code)
            ingress = {name: params for (f, name), params in INGRESS_PARAMS.items() if f == rel}
            scope_params = [
                {p for op in blocks.enclosing_funcs[i]
                 for p in ingress.get(blocks.func_name[op] or '', [])}
                for i in range(len(code))]
            aliases = _assigns(code, scope_params)
            by_name: dict[str, int] = {}
            for i, name in enumerate(blocks.func_name):
                if name is not None and name not in by_name:
                    by_name[name] = i
            files[rel] = (text, blocks, aliases, by_name)
        text, blocks, aliases, by_name = files[rel]
        if blocks is None:
            findings.append(f"{rel}: registered ingress file is missing (registry rot)")
            continue
        if func not in by_name:
            findings.append(f"{rel}: registered ingress function `{func}` not found "
                            "(registry rot — update INGRESS_ARRAYS)")
            continue
        start, end = _function_region(blocks, by_name[func])
        region_code = "\n".join(blocks.code[start:end + 1])
        region_aliases = aliases[start:end + 1]
        for binding in bindings:
            # dense coverage: a canonical dense validator call inside the region
            # whose (alias-resolved) argument chain equals the binding.
            covered = False
            for k in range(start, end + 1):
                for match in DENSE_CALL.finditer(blocks.code[k]):
                    forms: set[str] = set()
                    for arg in match.group("args").split(","):
                        arg = arg.strip()
                        if not arg:
                            continue
                        for chain in _resolve_arg(arg, region_aliases[k - start]):
                            forms.add(_norm_chain(chain))
                    if _norm_chain(binding) in forms:
                        covered = True
                        break
                if covered:
                    break
            if not covered and _norm_chain(binding) not in _norm_chain(region_code):
                findings.append(
                    f"{rel}: registered ingress array `{binding}` is not mentioned in "
                    f"`{func}` any more (registry rot — update INGRESS_ARRAYS)")
                rows.append(f"{rel}:{func}: {binding} MISSING")
                continue
            if not covered:
                findings.append(
                    f"{rel}: registered ingress array `{binding}` has no dense validator "
                    f"inside `{func}` — the guard regressed to a weak/missing check "
                    "(checklist A); restore `Json.denseArray` at the ingress or update "
                    "the registry if the ingress moved")
            rows.append(f"{rel}:{func}: {binding} -> "
                        + ("dense-validated at ingress" if covered else "NOT dense-validated"))
    return findings, rows


def scan_sites() -> tuple[list[dict], list[str]]:
    sites: list[dict] = []
    notes: list[str] = []
    for path in sorted(OVERLOAD.rglob("*.lua")):
        rel = path.relative_to(ADDON).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        file_sites = scan_text(
            text,
            ingress={name: params for (f, name), params in INGRESS_PARAMS.items()
                     if f == rel and params},
            array_fields=INGRESS_FIELD_KINDS.get(rel, {}).get("array", set()),
            scalar_fields=INGRESS_FIELD_KINDS.get(rel, {}).get("scalar", set()),
        )
        for s in file_sites:
            s["path"] = rel
            if s.get("uncatalogued"):
                notes.append(f"{rel}:{s['line']}: UNCATALOGUED ingress field `{s['chain']}` "
                             f"({s['kind']} use) — classify it in INGRESS_FIELD_KINDS "
                             "(array/scalar) or dense-guard it")
        sites.extend(file_sites)
    return sites, notes


# ---------------------------------------------------------------------------
# Self-test: the detectors must fire on every reviewed defect shape and clear
# the guarded forms (BND-REV-01/02/03).
# ---------------------------------------------------------------------------
SELF_TEST_INGRESS = {
    "unguarded": ["plan"], "guarded": ["plan"], "ignored_guard": ["plan"],
    "nonexit_guard": ["plan"], "nested_closure": ["plan"],
    "nested_closure_guarded_inner": ["plan"], "field_alias": ["plan"],
    "field_alias_guarded": ["plan"], "sparse_ingress": ["policy"],
    "validateTargetPlan": ["plan"], "evalCondition": ["cond"], "M.verify": ["policy"],
}
SELF_TEST_ARRAY_FIELDS = {"rules", "all", "any", "target_plan", "values", "tie_break"}
SELF_TEST_SCALAR_FIELDS = {"id", "when", "then", "action", "talent"}

# The reviewer's five shapes (BND-REV-03) plus the guarded/bare forms.
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
local function ignored_guard(plan)
    Json.denseArray(plan, 1)
    return #plan
end
local function nonexit_guard(plan)
    local ok = Json.denseArray(plan, 1)
    if ok then print('ok') end
    return #plan
end
local function nested_closure(plan)
    local inner = function()
        return #plan
    end
    return inner()
end
local function nested_closure_guarded_inner(plan)
    local inner = function()
        local ok = Json.denseArray(plan, 1)
        if not ok then return 0 end
        return #plan
    end
    return inner()
end
local function field_alias(plan)
    local a = plan
    local b = a.values
    return #b
end
local function field_alias_guarded(plan)
    local a = plan
    local b = a.values
    local ok = Json.denseArray(b, 1)
    if not ok then return 0 end
    return #b
end
local function curated(plan)
    -- a curated internal parameter that merely shares the name `plan` is NOT
    -- caller data: provenance is per (file, function), not per spelling.
    return #plan
end
local function sparse_ingress(policy)
    -- the reviewer's production shape: the weak isArray + #/ipairs ingress that
    -- measured a sparse policy.rules (hole at 3) as a complete one-rule policy.
    if not isArray(policy.rules) or #policy.rules == 0 then return nil end
    for i, rule in ipairs(policy.rules) do local x = rule end
end
'''

# The reviewer's synthetic no-op forwarder (BND-REV-02): a literal list plus
# three COMMENTED-OUT type() lines and no forwarding at all. It must FAIL.
SELF_TEST_B_NOOP = (
    "local FOOTPRINT_FLAGS={'friendlyblock','friendlyfire','selffire','pass_terrain',"
    "'no_restrict','actorblock','stop_block','force_max_range','min_range',"
    "'grid_exclude','requires_knowledge','block_path','block_radius','filter','act_exclude'}\n"
    "-- type(spec.block_path)=='function'\n"
    "-- type(spec.block_radius)=='function'\n"
    "-- type(spec.filter)=='function'\n"
    "return {}\n")

SELF_TEST_B_GOOD = '''
local FOOTPRINT_FLAGS={'friendlyblock','friendlyfire','selffire','pass_terrain',
    'no_restrict','actorblock','stop_block','force_max_range','min_range',
    'grid_exclude','requires_knowledge','block_path','block_radius','filter','act_exclude'}
local function forwardFootprintFlags(spec)
    local forwarded={}
    for _,flag in ipairs(FOOTPRINT_FLAGS) do
        forwarded[flag]=spec[flag]
    end
    -- function-valued fields are type-checked on the real data path; a
    -- malformed value fails closed with a typed outcome.
    if forwarded.block_path~=nil and forwarded.block_path~=false
        and type(forwarded.block_path)~='function' then
        return nil,'invalid_footprint_block_path'
    end
    if forwarded.block_radius~=nil and forwarded.block_radius~=false
        and type(forwarded.block_radius)~='function' then
        return nil,'invalid_footprint_block_radius'
    end
    if forwarded.filter~=nil and forwarded.filter~=false
        and type(forwarded.filter)~='function' then
        return nil,'invalid_footprint_filter'
    end
    return forwarded
end
function M.expandFrom(spec,opts)
    local forwarded=forwardFootprintFlags(spec)
    if not forwarded then return nil,'footprint_unknown' end
    local set=M.model(forwarded,opts)
    local native=M.native(opts.native,forwarded)
    return set,native
end
'''

SELF_TEST_B_FALSE_DROP = '''
local FOOTPRINT_FLAGS={'friendlyblock','friendlyfire','selffire','pass_terrain',
    'no_restrict','actorblock','stop_block','force_max_range','min_range',
    'grid_exclude','requires_knowledge','block_path','block_radius','filter','act_exclude'}
local function forwardFootprintFlags(spec)
    local forwarded={}
    for _,flag in ipairs(FOOTPRINT_FLAGS) do
        if spec[flag] then forwarded[flag]=spec[flag] end
    end
    return forwarded
end
'''

SELF_TEST_B_ONE_PATH = '''
local FOOTPRINT_FLAGS={'friendlyblock','friendlyfire','selffire','pass_terrain',
    'no_restrict','actorblock','stop_block','force_max_range','min_range',
    'grid_exclude','requires_knowledge','block_path','block_radius','filter','act_exclude'}
local function forwardFootprintFlags(spec)
    local forwarded={}
    for _,flag in ipairs(FOOTPRINT_FLAGS) do
        forwarded[flag]=spec[flag]
    end
    return forwarded
end
function M.expandFrom(spec,opts)
    local forwarded=forwardFootprintFlags(spec)
    local set=M.model(forwarded,opts)
    return set
end
'''


def self_test() -> int:
    failures: list[str] = []
    parsed = scan_text(SELF_TEST_A, ingress=SELF_TEST_INGRESS,
                       array_fields=SELF_TEST_ARRAY_FIELDS,
                       scalar_fields=SELF_TEST_SCALAR_FIELDS)

    def site(expr: str):
        matches = [s for s in parsed if s["expr"] == expr]
        return matches

    # 1. bare unguarded forms are flagged
    if not any(s["chain"] == "plan" and not s["guarded"] and not s.get("uncatalogued")
               for s in parsed):
        failures.append("A: an unguarded #plan/ipairs(plan) was not flagged")
    sparse = [s for s in parsed if s["line"] in (56, 57)]
    if not sparse or any(s["guarded"] or s.get("uncatalogued") for s in sparse):
        failures.append("A: the weak isArray+#/ipairs sparse policy.rules ingress was "
                        "not flagged as unguarded caller array")
    # 2. reviewer shape: ignored validator result is not a guard
    ignored = [s for s in parsed if s["line"] == 15]  # `return #plan` in ignored_guard
    if not ignored or ignored[0]["guarded"]:
        failures.append("A: an ignored denseArray result must NOT count as a guard")
    # 3. reviewer shape: `local ok=...; if ok then print() end` is not a guard
    nonexit = [s for s in parsed if s["line"] == 20]  # `return #plan` in nonexit_guard
    if not nonexit or nonexit[0]["guarded"]:
        failures.append("A: a guard whose invalid path continues must NOT be recognised")
    # 3b. reviewer shape: a guard in the outer function must NOT leak into an
    # anonymous nested closure...
    nested = [s for s in parsed if s["line"] == 24]  # `return #plan` inside inner
    if not nested or nested[0]["guarded"]:
        failures.append("A: a guard in the outer function leaked into an anonymous nested closure")
    # ...but a guard INSIDE the closure is honoured.
    nested_ok = [s for s in parsed if s["line"] == 32]
    if not nested_ok or not nested_ok[0]["guarded"]:
        failures.append("A: a guard inside the nested closure was not recognised")
    # 4. a consumed+exiting guard is honoured
    if not any(s["line"] == 10 and s["guarded"] for s in parsed):
        failures.append("A: a validateArray-guarded site (consumed, invalid path exits) "
                        "was not recognised")
    # 5. reviewer shape: one-hop field alias detected; guarded form clears
    alias_site = [s for s in parsed if s["line"] == 39]
    if not alias_site or alias_site[0]["guarded"] or alias_site[0]["chain"] != "plan.values":
        failures.append("A: a one-hop field alias (a=plan; b=a.values; #b) was not flagged")
    if not any(s["line"] == 46 and s["guarded"] for s in parsed):
        failures.append("A: a guarded one-hop field alias was not recognised")
    # 5b. reviewer shape: a curated internal parameter merely named `plan` is NOT flagged
    curated = [s for s in parsed if s["line"] == 51]
    if curated:
        failures.append("A: a curated internal parameter named `plan` was falsely flagged "
                        "(provenance must be per (file, function))")

    # B: the reviewer's no-op forwarder must FAIL; conforming forms must pass.
    noop = analyse_forwarder("self-test", SELF_TEST_B_NOOP)
    if not noop:
        failures.append("B: the reviewer's no-op forwarder (commented-out checks) PASSED")
    if not any("nothing reads it" in f for f in noop):
        failures.append("B: the no-op forwarder was not reported as an unread list")
    if not any("type" in f and "function-valued" in f for f in noop):
        failures.append("B: the no-op forwarder was not reported for missing "
                        "function-valued type checks")
    if analyse_forwarder("self-test", SELF_TEST_B_GOOD):
        failures.append("B: a conforming forwarder was reported failing: "
                        + str(analyse_forwarder("self-test", SELF_TEST_B_GOOD)))
    false_drop = analyse_forwarder("self-test", SELF_TEST_B_FALSE_DROP)
    if not any("false" in f for f in false_drop):
        failures.append("B: a truthiness-guarded copy (drops explicit false) was not flagged")
    one_path = analyse_forwarder("self-test", SELF_TEST_B_ONE_PATH)
    if not any("both footprint backends" in f for f in one_path):
        failures.append("B: a forwarder reaching only one footprint backend was not flagged")

    # Registry conformance must fire on a regressed ingress (sparse-policy class).
    reg_findings, _ = _registry_check_text(
        SELF_TEST_REGRESSION, "self-test.lua", {"M.validate": ["policy.rules"]})
    if not reg_findings:
        failures.append("A: a weak isArray+ipairs ingress for a registered array "
                        "was not rejected by the registry conformance check")

    for failure in failures:
        print("SELF-TEST FAIL:", failure, file=sys.stderr)
    if failures:
        return 1
    print("self-test: OK (A flags unguarded/ignored-result/non-exiting/nested-closure/"
          "field-alias shapes, clears consumed+exiting guards, rejects a weak sparse "
          "ingress for a registered array, and does not flag curated name collisions; "
          "B fails the reviewer's no-op forwarder and clears a conforming one, "
          "including explicit-false survival and both footprint paths)")
    return 0


# A synthetic regressed ingress for the registry conformance self-test: the
# sparse-policy.rules shape the reviewer reproduced in production.
SELF_TEST_REGRESSION = '''
local function isArray(t) return type(t)=='table' and t~=Json.null end
function M.validate(policy)
    if not isArray(policy.rules) or #policy.rules==0 then return nil end
    for i,rule in ipairs(policy.rules) do local x=rule end
end
'''


def _registry_check_text(text: str, rel: str, arrays: dict[str, list[str]]) -> tuple[list[str], list[str]]:
    """Run the registry conformance logic on an injected text (self-test hook)."""
    code = lua_code_lines(text, blank_strings=True)
    blocks = BlockAnalysis(code)
    aliases = _assigns(code, [set()] * len(code))
    by_name = {name: i for i, name in enumerate(blocks.func_name) if name is not None}
    findings: list[str] = []
    rows: list[str] = []
    for func, bindings in arrays.items():
        if func not in by_name:
            findings.append(f"{rel}: registered ingress function `{func}` not found")
            continue
        start, end = _function_region(blocks, by_name[func])
        region_aliases = aliases[start:end + 1]
        for binding in bindings:
            if _norm_chain(binding) not in _norm_chain("\n".join(blocks.code[start:end + 1])):
                findings.append(f"{rel}: registered ingress array `{binding}` is not "
                                f"mentioned in `{func}` (registry rot)")
                continue
            covered = False
            for k in range(start, end + 1):
                for match in DENSE_CALL.finditer(blocks.code[k]):
                    forms: set[str] = set()
                    for arg in _norm(match.group("args")).split(","):
                        arg = arg.strip()
                        if not arg:
                            continue
                        for chain in _resolve_arg(arg, region_aliases[k - start]):
                            forms.add(_norm_chain(chain))
                    if _norm_chain(binding) in forms:
                        covered = True
                        break
                if covered:
                    break
            if not covered:
                findings.append(f"{rel}: registered ingress array `{binding}` has no dense "
                                f"validator inside `{func}` (guard regressed)")
    return findings, rows


# ---------------------------------------------------------------------------
# B. Engine-consulted raised-spec fields: forwarded, or explicitly fail-closed.
# ---------------------------------------------------------------------------
ENGINE_FOOTPRINT_FIELDS = [
    "friendlyblock", "friendlyfire", "selffire", "pass_terrain", "no_restrict",
    "actorblock", "stop_block", "force_max_range", "min_range", "grid_exclude",
    "requires_knowledge", "block_path", "block_radius", "filter", "act_exclude",
]
FUNCTION_VALUED = ["block_path", "block_radius", "filter"]

ENGINE_SOURCES = [
    "game/engines/default/engine/Target.lua",
    "game/engines/default/engine/interface/ActorProject.lua",
    "game/engines/default/engine/interface/GameTargeting.lua",
]

# Engine-consulted raised-spec fields that are basic shape/geometry/UI plumbing
# rather than the supplemental footprint flags the forwarder must carry. A
# DERIVED engine field outside both sets is reported for manual review — that
# is exactly how a new engine field (e.g. `typ.new_footprint_gate`) becomes
# visible instead of drifting silently.
KNOWN_NON_SUPPLEMENTAL = {
    # geometry/shape plumbing (Target.lua types_def + ActorProject expansion)
    "range", "radius", "ball", "cone", "cone_angle", "wall", "halfmax_spots",
    "line", "line_function", "widebeam", "triangle", "triangle_mode",
    "start_x", "start_y", "source_actor", "x", "y", "type", "multiple",
    # projector plumbing
    "bypass", "display", "uid", "on_stop_check", "sound_stop",
    # targeting-UI plumbing (GameTargeting)
    "immediate_keys", "nolock", "nowarning", "can_autoaccept", "default_target",
    "cursor_type", "target",
}


# Engine-consulted raised-spec fields that belong to the targeting-UI/scan
# layer (Target's display/scan hooks and GameTargeting's prompt handling),
# NOT to the projection footprint the forwarder must carry. Enumerated here
# with that justification; any DERIVED field outside BOTH sets is reported
# for manual review — that is exactly how a new engine field (e.g.
# `typ.new_footprint_gate`) becomes visible instead of drifting silently.
KNOWN_UI_PLUMBING = {
    # Target.lua display/scan hooks and defaults
    "display_blocked_by_adjacent", "display_check_block_path",
    "display_corner_block", "display_default_target", "display_line_step",
    "display_on_block", "display_on_block_corner", "display_update_hit",
    "display_update_min_range", "display_update_radius", "custom_scan_filter",
    "no_filter_highlight", "__name",
    # GameTargeting.lua prompt/scan/tooltip plumbing
    "stop_before_target", "scan_on", "first_target", "msg", "talent",
    "no_move_tooltip", "no_start_scan", "no_first_target_filter",
    "first_target",
}


def _engine_texts() -> dict[str, str]:
    root = ADDON.parent.parent.parent
    texts = {}
    for rel in ENGINE_SOURCES:
        path = root / rel
        if path.exists():
            texts[rel] = path.read_text(encoding="utf-8", errors="replace")
    return texts


def derive_engine_fields(texts: dict[str, str]) -> dict[str, list[str]]:
    """Derive the engine-consulted raised-spec fields from the engine sources
    (comment- and string-stripped accesses on `typ`/`target_type`/`t`)."""
    derived: dict[str, list[str]] = {}
    for rel, text in texts.items():
        code = "\n".join(lua_code_lines(text, blank_strings=True))
        fields = set(re.findall(r"\b(?:typ|target_type|t)\.([a-z_]\w*)", code))
        fields |= set(re.findall(r"\b(?:typ|target_type)\.([a-z_]\w*)", code))
        derived[rel] = sorted(fields)
    return derived


def engine_drift_notes() -> list[str]:
    """Two-way drift check (BND-REV-04): derive the engine-consulted field set
    from the engine sources and compare BOTH directions against the declared
    supplemental list.

    Honest claim (replacing the old false "cannot silently drift"): the
    derivation makes drift visible — a declared field the engine no longer
    consults, and an engine-consulted field that is neither declared nor
    classified as basic shape/UI plumbing, are both reported for manual
    review. It is a derived-superset heuristic over the audited sources, not a
    proof; the manual-review step is mandatory and named here.
    """
    notes = []
    texts = _engine_texts()
    missing_sources = [rel for rel in ENGINE_SOURCES if rel not in texts]
    if missing_sources:
        notes.append("engine source(s) not found, cannot derive the field set: "
                     + ", ".join(missing_sources))
        return notes
    derived = derive_engine_fields(texts)
    consulted: set[str] = set()
    for fields in derived.values():
        consulted |= set(fields)
    absent = [f for f in ENGINE_FOOTPRINT_FIELDS if f not in consulted]
    if absent:
        notes.append("declared supplemental field(s) not consulted by any derived "
                     "engine source (list drift? manual review required): "
                     + ", ".join(absent))
    extra = sorted(consulted - set(ENGINE_FOOTPRINT_FIELDS) - KNOWN_NON_SUPPLEMENTAL - KNOWN_UI_PLUMBING)
    if extra:
        notes.append("engine-consulted field(s) neither declared as supplemental nor "
                     "classified as basic shape/UI plumbing — manual review required "
                     "(this is how a NEW engine field becomes visible): "
                     + ", ".join(extra))
    return notes


def analyse_forwarder(rel: str, text: str) -> list[str]:
    """Semantic Rule B analysis of one forwarder file (BND-REV-02).

    Comments are stripped first (commented-out checks never count); findings
    cover the real forwarding operation, not a textual marker:
      * the FOOTPRINT_FLAGS list must be complete (or explicitly fail-closed);
      * the list must be CONSUMED by a forwarder loop that copies values into
        the spec (a list that exists but nothing reads fails);
      * the copy must be direct (an `if src[flag] then` truthiness guard drops
        an explicit `false`, which the engine honours);
      * the copied table must reach BOTH footprint backends (`M.model` and
        `M.native`, or `M.expand` which dispatches to both);
      * the function-valued fields must be type-checked on the real data path
        (on the copied table) with a malformed value becoming a typed
        fail-closed outcome.
    """
    code_lines = lua_code_lines(text, blank_strings=False)
    code = "\n".join(code_lines)
    findings: list[str] = []
    match = re.search(r"FOOTPRINT_FLAGS\s*=\s*\{(.*?)\}", code, re.S)
    if not match:
        return [f"{rel}: a forwarder exists but no FOOTPRINT_FLAGS list was found"]
    forwarded = set(re.findall(r"'([a-z_]+)'", match.group(1)))
    missing = [f for f in ENGINE_FOOTPRINT_FIELDS if f not in forwarded]
    unresolved = [f for f in missing
                  if not re.search(rf"\b{f}\b[^\n]{{0,120}}(fail[- ]closed|unknown)", code, re.I)]
    if unresolved:
        findings.append(f"{rel}: FOOTPRINT_FLAGS omits engine-consulted field(s) with no "
                        f"explicit fail-closed handling in code: {', '.join(unresolved)}")
    # 1. consumed by a forwarder loop
    loop = re.search(
        r"for\s+[\w_,\s]+in\s+(?:ipairs|pairs)\s*\(\s*FOOTPRINT_FLAGS\s*\)\s+do", code)
    dst: str | None = None
    loop_var: str | None = None
    if not loop:
        findings.append(f"{rel}: the FOOTPRINT_FLAGS list exists but nothing reads it "
                        "(no `for ... in ipairs/pairs(FOOTPRINT_FLAGS)` forwarder loop)")
    else:
        first_line = code[:loop.start()].count("\n")
        end_line = _loop_end(code_lines, first_line)
        body_lines = code_lines[first_line + 1:end_line]
        body = "\n".join(body_lines)
        copy = re.search(rf"({_NAME})\s*\[\s*({_NAME})\s*\]\s*=\s*[\w.\[\]]*?\2", body)
        if not copy:
            findings.append(f"{rel}: the forwarder loop does not copy each flag into the "
                            "spec (`dst[flag]=src[flag]`); the list is read but nothing "
                            "is forwarded")
        else:
            dst, loop_var = copy.group(1), copy.group(2)
            truthy = re.search(rf"if\s+[\w.]+\s*\[\s*{loop_var}\s*\]\s+then", body)
            if truthy:
                findings.append(f"{rel}: the copy is guarded by truthiness "
                                f"(`if src[{loop_var}] then ...`), so an explicit `false` "
                                "would be dropped — the engine honours `false`, copy "
                                "unconditionally or with `~=nil`")
    # 2. copied values must reach BOTH footprint backends
    if dst:
        if re.search(rf"\bM\.expand\s*\([^)]*\b{re.escape(dst)}\b", code):
            reach_model = reach_native = True  # expand dispatches to both backends
        else:
            reach_model = reaches_backend(code, dst, "M.model")
            reach_native = reaches_backend(code, dst, "M.native")
        if not (reach_model and reach_native):
            findings.append(
                f"{rel}: the copied table `{dst}` does not reach both footprint backends "
                f"(M.model: {reach_model}, M.native: {reach_native}); a value that reaches "
                "only one path is silently absent from the other")
    else:
        findings.append(f"{rel}: no forwarded spec table could be identified, so both "
                        "footprint paths could not be verified")
    # 3. function-valued fields type-checked on the real data path, fail closed
    for field in FUNCTION_VALUED:
        check = re.search(rf"type\s*\(\s*[\w.\[\]'\"()]*\b{field}\b[\w.'\[\]\"]*\s*\)\s*[~=]=\s*'function'", code)
        if not check:
            findings.append(f"{rel}: `{field}` is function-valued but has no "
                            "`type(...)=='function'` check on the data path "
                            "(a malformed value must fail closed)")
            continue
        first_line = code[:check.start()].count("\n")
        if not _contains_return_error(code_lines, first_line, first_line + 4):
            findings.append(f"{rel}: the `{field}` type check does not fail closed "
                            "(no `return`/`error` outcome follows the malformed branch)")
    return findings


def reaches_backend(code: str, dst: str, name: str) -> bool:
    for m in re.finditer(rf"\b{re.escape(name)}\s*\(([^()]*)\)", code):
        if re.search(rf"(?<![\w.]){re.escape(dst)}(?![\w])", m.group(1)):
            return True
    return False


def _loop_end(code_lines: list[str], first_line: int) -> int:
    depth = 0
    for i in range(first_line, len(code_lines)):
        opens, closes = _block_deltas(code_lines[i])
        depth += opens - closes
        if depth <= 0 and i > first_line:
            return i
    return len(code_lines) - 1


def _block_deltas(line: str) -> tuple[int, int]:
    opens = len(_IF_WHILE.findall(line)) + len(_FOR.findall(line)) \
        + len(_REPEAT.findall(line)) + len(_FUNC.findall(line))
    standalone_do = len(_DO.findall(line)) - len(_FOR.findall(line)) - len(_IF_WHILE.findall(line))
    opens += max(0, standalone_do)
    closes = len(_END.findall(line)) + len(_UNTIL.findall(line))
    return opens, closes


def _loop_end(code_lines: list[str], first_line: int) -> int:
    depth = 0
    for i in range(first_line, len(code_lines)):
        opens, closes = _block_deltas(code_lines[i])
        depth += opens - closes
        if depth <= 0 and i > first_line:
            return i
        if depth <= 0 and opens == 0:
            return i
    return len(code_lines) - 1


def check_rule_b() -> tuple[str, list[str]]:
    """Return (status, findings) where status is PASS/FAIL/REVIEW.

    The forwarder is introduced by proposal A'; on a tree where it does not
    exist yet there is nothing to forward, so that state is REVIEW (not PASS,
    not FAIL) — the rule only bites once the mechanism exists. A forwarder file
    is analysed SEMANTICALLY (see analyse_forwarder): a no-op file whose list is
    never read fails, and commented-out checks never count.
    """
    forwarders: list[tuple[str, str]] = []
    for path in sorted(OVERLOAD.rglob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        code = "\n".join(lua_code_lines(text, blank_strings=True))
        if "FOOTPRINT_FLAGS" in code or "copyFootprintFlags" in code:
            forwarders.append((path.relative_to(ADDON).as_posix(), text))
    if not forwarders:
        drift = engine_drift_notes()
        detail = "no raised-field forwarder on this tree; rule applies once proposal A' lands"
        if drift:
            return "FAIL", [detail] + drift
        return "REVIEW", [detail]
    findings: list[str] = []
    for rel, text in forwarders:
        findings.extend(analyse_forwarder(rel, text))
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

    sites, notes = scan_sites()
    unguarded = [s for s in sites if not s.get("guarded") and not s.get("uncatalogued")]
    uncatalogued = [s for s in sites if s.get("uncatalogued")]
    reg_findings, reg_rows = registry_check()
    b_status, b_findings = check_rule_b()

    if args.list:
        print("A. ingress registry (explicit provenance model; see module docstring):")
        for row in reg_rows:
            print(f"    {row}")
        print("A. every scanned `#`/`ipairs` on caller data (direct, aliased, chained):")
        for s in sites:
            flag = ("UNGUARDED" if not s["guarded"] else "guarded")
            if s.get("uncatalogued"):
                flag = "UNCATALOGUED"
            alias = " (alias)" if s.get("aliased") else ""
            print(f"    {s['path']}:{s['line']}: {s['kind']} {s['expr']}{alias}  [{flag}]")
        print()

    failures: list[str] = []
    if unguarded:
        print(f"A. dense-validation: FAIL ({len(unguarded)}/{len(sites)} caller-data site(s) "
              f"use #/ipairs without a consumed dense validator in scope)")
        for s in unguarded:
            print(f"     {s['path']}:{s['line']}: {s['kind']} {s['expr']}")
            print(f"       {s['why']}")
            failures.append(f"{s['path']}:{s['line']}: {s['kind']} {s['expr']}")
    else:
        print(f"A. dense-validation: PASS (registry: {len(reg_rows)} registered ingress "
              f"array(s) across {len(INGRESS_ARRAYS)} function(s); "
              f"{len(sites) - len(uncatalogued)} measured #/ipairs site(s), all guarded; "
              f"{len(uncatalogued)} uncatalogued)")
    for finding in reg_findings:
        print(f"    REGISTRY: {finding}")
    for note in notes:
        print(f"    {note}")
    failures.extend(reg_findings)
    failures.extend(notes)

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
