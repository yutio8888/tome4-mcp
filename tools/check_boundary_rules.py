#!/usr/bin/env python3
"""Fail closed on drift in registered Lua boundary structures (AGENTS A/B).

This is a deliberately bounded structural checker, not a Lua semantic proof.
It lexes executable tokens, scopes guards to their function/control block, and
checks registered validation-to-consumer and field-copy paths. Comments and
string payloads cannot satisfy code checks. New paths/refactors require an
explicit registry update plus behavior tests; C/D/E always remain REVIEW.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
AUTO = "overload/mod/auto_combat/"
BRIDGE = "overload/mod/mcp_bridge/"
FIELDS = set("friendlyblock friendlyfire selffire pass_terrain no_restrict actorblock stop_block "
             "force_max_range min_range grid_exclude requires_knowledge block_path block_radius "
             "filter act_exclude".split())
CALLBACKS = {"block_path", "block_radius", "filter"}


def lex(source):
    tokens = []
    pos = 0
    while pos < len(source):
        if source[pos].isspace():
            pos += 1
            continue
        start = pos
        comment = source.startswith("--", pos)
        if comment:
            pos += 2
        long = re.match(r"\[(=*)\[", source[pos:])
        if long:
            close = "]" + long[1] + "]"
            end = source.find(close, pos + len(long[0]))
            if end < 0:
                raise ValueError("unterminated Lua long string/comment")
            pos = end + len(close)
            if not comment:
                tokens.append(("STRING:" + source[start:pos], start))
            continue
        if comment:
            end = source.find("\n", pos)
            pos = len(source) if end < 0 else end
            continue
        if source[pos] in "\"'":
            quote = source[pos]
            pos += 1
            while pos < len(source) and source[pos] != quote:
                pos += 2 if source[pos] == "\\" else 1
            if pos >= len(source):
                raise ValueError("unterminated Lua string")
            tokens.append(("STRING:" + source[start + 1:pos], start))
            pos += 1
            continue
        match = re.match(r"[A-Za-z_][A-Za-z_0-9]*|\d+(?:\.\d+)?|\.\.\.|\.\.|~=|==|<=|>=|.", source[pos:])
        tokens.append((match[0], start))
        pos += len(match[0])
    return tokens


def words(source):
    return [word for word, _ in lex(source)]


@dataclass
class Block:
    kind: str
    start: int
    end: int = -1
    branch: int = 0
    pending_do: bool = False
    name: str = ""


class Lua:
    def __init__(self, path):
        self.path = path
        self.source = path.read_text()
        tokenized = lex(self.source)
        self.tokens = [word for word, _ in tokenized]
        self.lines = [self.source.count("\n", 0, pos) + 1 for _, pos in tokenized]
        self.scopes, self.blocks = [], []
        stack = []
        for index, word in enumerate(self.tokens):
            if word in ("else", "elseif") and stack and stack[-1].kind == "if":
                stack[-1].branch += 1
            self.scopes.append(tuple((block.start, block.branch) for block in stack))
            if word in ("function", "if", "for", "while", "repeat"):
                block = Block(word, index, pending_do=word in ("for", "while"))
                if word == "function":
                    opening = self.tokens.index("(", index + 1)
                    block.name = "".join(self.tokens[index + 1:opening])
                stack.append(block)
                self.blocks.append(block)
            elif word == "do":
                if stack and stack[-1].pending_do:
                    stack[-1].pending_do = False
                else:
                    block = Block(word, index)
                    stack.append(block)
                    self.blocks.append(block)
            elif word in ("end", "until"):
                if not stack:
                    raise ValueError(f"unmatched {word} at {path}:{self.lines[index]}")
                stack.pop().end = index
        if stack:
            raise ValueError(f"unclosed Lua block in {path}")

    def function(self, name):
        matches = [block for block in self.blocks if block.kind == "function" and block.name == name]
        if len(matches) != 1:
            raise ValueError(f"expected one function {name}, found {len(matches)}")
        return matches[0]

    def find(self, pattern, block=None):
        pattern = words(pattern)
        start, end = (block.start, block.end + 1) if block else (0, len(self.tokens))
        return [i for i in range(start, end - len(pattern) + 1)
                if self.tokens[i:i + len(pattern)] == pattern]

    def require(self, pattern, name=None):
        block = self.function(name) if name else None
        matches = self.find(pattern, block)
        if len(matches) != 1:
            raise ValueError(f"{name or 'module'}: expected one executable structure: {pattern}")
        return matches[0]

    def guard(self, name, assignment, flag, consumers):
        block = self.function(name)
        call = self.require(assignment, name)
        guards = [node for node in self.blocks if node.kind == "if" and node.start > call
                  and node.end < block.end and self.scopes[node.start] == self.scopes[call]
                  and node.start in self.find(f"if not {flag} then", block)]
        if not guards:
            raise ValueError(f"{name}: missing fail-closed guard for {flag}")
        guard = guards[0]
        # A direct return in the rejection arm, not one hidden in another if/function.
        direct = self.scopes[guard.start] + ((guard.start, 0),)
        if not any(self.tokens[i] == "return" and self.scopes[i] == direct
                   for i in range(guard.start + 1, guard.end)):
            raise ValueError(f"{name}: {flag} rejection does not return")
        # Reject newly inserted #/ipairs/index consumers of the same input,
        # not only the historically registered loop spelling. Restrict the
        # scan to this control arm (e.g. schema's string arm may use #value).
        argument = assignment.split("(", 1)[1].rsplit(")", 1)[0].split(",", 1)[0]
        argument = argument.rsplit(" and ", 1)[-1]
        for pattern in ("#" + argument, "ipairs(" + argument + ")", argument + "["):
            for sink in self.find(pattern, block):
                scope = self.scopes[call]
                if self.scopes[sink][:len(scope)] == scope and sink <= guard.end:
                    raise ValueError(f"{name}:{self.lines[sink]}: {pattern} before validation/rejection")
        for consumer in consumers:
            sinks = self.find(consumer, block)
            if not sinks:
                raise ValueError(f"{name}: registered consumer missing: {consumer}")
            for sink in sinks:
                scope = self.scopes[call]
                if sink <= guard.end or self.scopes[sink][:len(scope)] != scope:
                    raise ValueError(f"{name}:{self.lines[sink]}: {consumer} is not dominated by {flag} validation")

    def fields(self, declaration, expected, mapping):
        start = self.require(declaration) + len(words(declaration))
        end = self.tokens.index("}", start)
        values = self.tokens[start:end]
        parts, current = [], []
        for token in values + [","]:
            if token == ",":
                if current:
                    parts.append(current)
                current = []
            else:
                current.append(token)
        found = []
        for part in parts:
            if mapping and len(part) == 3 and part[1:] == ["=", "true"]:
                found.append(part[0])
            elif not mapping and len(part) == 1 and part[0].startswith("STRING:"):
                found.append(part[0][7:])
            else:
                raise ValueError(f"{declaration}: unsupported/non-literal field entry {part}")
        if len(found) != len(set(found)) or not expected <= set(found):
            raise ValueError(f"{declaration}: duplicate/missing fields {sorted(expected - set(found))}")


def check(root):
    failures = []
    cache = {}

    def lua(path):
        if path not in cache:
            cache[path] = Lua(root / path)
        return cache[path]

    def rule(label, path, apply):
        try:
            apply(lua(path))
        except (OSError, ValueError) as exc:
            failures.append(f"FAIL {label} {path}: {exc}")

    def structures(label, path, name, patterns):
        rule(label, path, lambda src: [src.require(pattern, name) for pattern in patterns])

    structures("A.density", BRIDGE + "Json.lua", "M.denseArray", [
        "for key in pairs(list) do",
        "if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then return false, 'non_integer_key' end",
        "if key > maxKey then maxKey = key end", "count = count + 1",
        "if maxKey ~= count then return false, 'hole' end",
        "for i = 1, maxKey do if list[i] == nil then return false, 'hole' end end",
        "return true, maxKey",
    ])
    structures("A.factory", AUTO + "MovementAdapterFactory.lua", None,
               ["local validateArray=Json.denseArray", "M.validateArray=validateArray"])
    registrations = [
        (BRIDGE + "Actions.lua", "M.normalizeSequence", "local ok,maxKeyOrCause=Json.denseArray(list,1)", "ok", ["for i=1,maxKey do", "list[i]"]),
        (AUTO + "AutoCombatGuard.lua", "guardStationary", "local denseOk,planCause=Factory.validateArray(plan.values,1)", "denseOk", ["plan.values[index]", "for index=1,planLength do"]),
        (AUTO + "AutoCombatGuard.lua", "guardStationary", "local seqOk,seqLengthOrCause=Factory.validateArray(declared,1)", "seqOk", ["declared[index]", "if declaredLength~=planLength then"]),
        (AUTO + "AutoCombatGuard.lua", "denseCells", "local ok,maxKey=Json.denseArray(cells,0)", "ok", ["for i=1,maxKey do", "cells[i]"]),
        (AUTO + "AutoCombatGuard.lua", "expandComplete", "local cells,denseCount=denseCells(candidates and candidates.cells)", "cells", ["ipairs(cells)"]),
        (AUTO + "MovementPlanner.lua", "M.planSequence", "local planOk,planLenOrCause=Factory.validateArray(plan,1)", "planOk", ["plan[i]", "if planLength~=#sequence then"]),
        (AUTO + "MovementPlanner.lua", "M.plan", "local planOk,planLenOrCause=Factory.validateArray(attempt.target_plan,1)", "planOk", ["if planLenOrCause>1 then"]),
        (AUTO + "PolicySchema.lua", "validateTargetPlan", "local planCount,planCause=denseList(plan,1)", "planCount", ["if planCount>8 then", "plan[index]"]),
    ]
    for path, name, assignment, flag, consumers in registrations:
        rule(f"A.{name}.{flag}", path,
             lambda src, n=name, a=assignment, f=flag, c=consumers: src.guard(n, a, f, c))
    structures("A.schema-helper", AUTO + "PolicySchema.lua", "denseList", [
        "local ok,countOrCause=Json.denseArray(value,minLength or 0)",
        "if ok then return countOrCause end", "return nil,countOrCause"])
    structures("A.candidate-condition", AUTO + "AutoCombatGuard.lua", "resolveAdjacentCondition", [
        "if not denseCells(candidates and candidates.cells) then return 'unknown' end"])
    # Public JSON arrays (including observe.sections) must pass the schema
    # validator before dispatch reads them. Missing module fails on old Runtime.
    rule("A.public-arrays", BRIDGE + "RequestValidation.lua", lambda src: src.guard(
        "validateValue", "local dense,length=Json.denseArray(value)", "dense", ["for i=1,length do"]))
    rule("A.public-dispatch", BRIDGE + "Runtime.lua", lambda src: src.guard(
        "dispatch", "local valid,validationCode=RequestValidation.validate(request)",
        "valid", ["local a,op=request.args,request.op"]))
    structures("A.public-schema-link", BRIDGE + "RequestValidation.lua", "M.validate", [
        "local valid=validateValue(Schema.envelope,request,'request')",
        "if not valid then return nil,'invalid_request' end",
        "local ok,path=validateValue(Schema.operations[request.op],args,'args')"])
    structures("B.stationary-unknown", AUTO + "AutoCombatGuard.lua", "guardStationary", [
        "local malformedField=M.malformedFunctionField(stationaryFlags)",
        "if malformedField then return disable('selffire_risk',{talent=talent,stationary=true,unknown=true,reason='malformed_function_field',field=malformedField}) end"])
    rule("B.raised-registry", AUTO + "MovementAdapterFactory.lua",
         lambda src: src.fields("M.RAISED_FLAG_KEYS={", FIELDS, True))
    rule("B.footprint-registry", AUTO + "AutoCombatGuard.lua",
         lambda src: src.fields("local FOOTPRINT_FLAGS={", FIELDS, False))
    rule("B.callbacks", AUTO + "AutoCombatGuard.lua",
         lambda src: src.fields("local FUNCTION_FIELDS={", CALLBACKS, True))
    structures("B.copy", AUTO + "AutoCombatGuard.lua", "M.copyFootprintFlags", [
        "for _,key in ipairs(FOOTPRINT_FLAGS) do if flags[key]~=nil then",
        "if FUNCTION_FIELDS[key] and type(flags[key])~='function' and flags[key]~=false then else spec[key]=flags[key] end"])
    structures("B.callback-unknown", AUTO + "AutoCombatGuard.lua", "M.malformedFunctionField", [
        "for key in pairs(FUNCTION_FIELDS) do local value=flags[key] if value~=nil and value~=false and type(value)~='function' then return key end end"])
    structures("B.main-unknown", AUTO + "AutoCombatGuard.lua", "M.build", [
        "local malformedField=typ and M.malformedFunctionField(typ) or nil",
        "if malformedField then return disable('selffire_risk',{talent=talent,unknown=true,reason='malformed_function_field',field=malformedField,source=builderSource}) end"])
    structures("B.mixed-copy", AUTO + "AutoCombatGuard.lua", "mixedComposition", [
        "for flag in pairs(Factory.RAISED_FLAG_KEYS) do if type(typ)=='table' and typ[flag]~=nil then raised[flag]=typ[flag] raisedCount=raisedCount+1 end end"])
    structures("B.expander-copy", AUTO + "AutoCombatGuard.lua", "expandComplete", [
        "for flag,value in pairs(raised or {}) do spec[flag]=value end"])
    structures("B.footprint-call", AUTO + "AutoCombatGuard.lua", "M.footprintSpec", [
        "M.copyFootprintFlags(spec,flags)"])
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check only; never modifies source")
    parser.add_argument("--root", type=Path, default=ROOT, help="addon root or isolated mutation fixture")
    args = parser.parse_args(argv)
    failures = check(args.root.resolve())
    for failure in failures:
        print(failure)
    if not failures:
        print("PASS A/B registered structural checks (not a behavior/native verdict)")
    print("REVIEW C: tests/test_auto_combat_guard.lua (SHORT_REAL_SPEC / FIX1-01 missing/malformed landing); unknown must not shrink the candidate set")
    print("REVIEW D: tests/test_auto_combat_controller.lua (R2-APR3-04 synchronous/asynchronous mismatch); assert exact generation delta")
    print("REVIEW E: tools/verify_validation_manifest.py + independent review of VALIDATION.md and raw native/source/dist provenance; hashes do not prove execution")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
