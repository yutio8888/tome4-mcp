#!/usr/bin/env python3
"""Validate the protocol/v4 contract and its cross-language vectors.

This is the M0 contract-consistency check from Spec v1.0 API-07. It does not
execute the bridge; it fails when the schema files, limits and vectors drift
apart. It generates the Lua ingress schema and Lua/Python error registries.

Usage:
    python3 tools/generate_protocol.py --check
    python3 tools/generate_protocol.py --check --root protocol/v4
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROTOCOL = ROOT / "protocol/v4"

ERROR_CATEGORIES = {"protocol", "auth", "history", "request", "state", "collection", "transport", "native"}
ACCEPTANCE_SCOPES = {"command", "response", "not_applicable"}
COMMAND_ID = re.compile(r"^cmd-[1-9][0-9]*$")


class Failure(Exception):
    pass


def load(path: Path) -> dict:
    if not path.is_file():
        raise Failure(f"missing file: {path}")
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise Failure(f"invalid JSON in {path}: {exc}") from exc


def check_limits(protocol: Path, limits: dict) -> list[str]:
    notes = []
    required = [
        "MAX_FRAME_BYTES", "MAX_QUEUED_BYTES", "MAX_QUEUED_MESSAGES", "READ_BUDGET_BYTES_PER_FRAME",
        "WRITE_BUDGET_BYTES_PER_FRAME", "MESSAGE_BUDGET_PER_FRAME", "HANDSHAKE_TIMEOUT_MS",
        "MAX_RETAINED_COMMANDS", "COMMAND_RECEIPTS_BYTE_BUDGET", "MAX_RECEIPT_BYTES",
        "MAX_RECENT_SNAPSHOTS", "SNAPSHOT_BYTE_BUDGET", "MAX_RESPONSES_PER_COMMAND", "MAX_REST_TURNS",
        "DEFAULT_PAGE_SIZE", "MAX_PAGE_SIZE", "MAX_PAGE_DATA_BYTES", "MAX_VIEW_ITEMS", "MAX_VIEW_BYTES",
        "MAX_VIEWS", "VIEWS_BYTE_BUDGET", "VIEW_TTL_MS", "MAX_JSON_DEPTH", "MAX_ID_UTF8_BYTES",
        "MAX_OPTION_ID_UTF8_BYTES", "MAX_CURSOR_UTF8_BYTES", "MAX_SEQUENCE", "MAX_COORDINATE",
    ]
    for key in required:
        if key not in limits:
            raise Failure(f"limits.json missing {key}")
        value = limits[key]
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise Failure(f"limits.json {key} must be a positive integer, got {value!r}")
    if limits["DEFAULT_PAGE_SIZE"] > limits["MAX_PAGE_SIZE"]:
        raise Failure("DEFAULT_PAGE_SIZE must not exceed MAX_PAGE_SIZE")
    if limits["MAX_PAGE_SIZE"] > limits["MAX_VIEW_ITEMS"]:
        raise Failure("MAX_PAGE_SIZE must not exceed MAX_VIEW_ITEMS")
    common = load(protocol / "common.schema.json")
    cmd = common["$defs"]["CommandId"]
    if cmd.get("x-max-sequence") != limits["MAX_SEQUENCE"]:
        raise Failure("common.schema CommandId x-max-sequence disagrees with limits.MAX_SEQUENCE")
    if common["$defs"]["SessionId"].get("x-max-utf8-bytes") != limits["MAX_ID_UTF8_BYTES"]:
        raise Failure("SessionId byte limit disagrees with limits.MAX_ID_UTF8_BYTES")
    if common["$defs"]["OptionId"].get("x-max-utf8-bytes") != limits["MAX_OPTION_ID_UTF8_BYTES"]:
        raise Failure("OptionId byte limit disagrees with limits.MAX_OPTION_ID_UTF8_BYTES")
    if common["$defs"]["Cursor"].get("x-max-utf8-bytes") != limits["MAX_CURSOR_UTF8_BYTES"]:
        raise Failure("Cursor byte limit disagrees with limits.MAX_CURSOR_UTF8_BYTES")
    notes.append(f"limits: {len(required)} budgets consistent")
    return notes


def check_errors(protocol: Path, errors: dict) -> list[str]:
    schema = load(protocol / "errors.schema.json")
    allowed_categories = set(schema["properties"]["category"]["enum"])
    allowed_recovery = set(schema["properties"]["recovery"]["enum"])
    if allowed_categories != ERROR_CATEGORIES:
        raise Failure(f"errors.schema categories disagree with checker: {allowed_categories ^ ERROR_CATEGORIES}")
    seen = set()
    for entry in errors["codes"]:
        code = entry["code"]
        if code in seen:
            raise Failure(f"duplicate error code {code}")
        seen.add(code)
        if entry["category"] not in allowed_categories:
            raise Failure(f"{code}: bad category {entry['category']}")
        if entry["acceptance_scope"] not in ACCEPTANCE_SCOPES:
            raise Failure(f"{code}: bad acceptance_scope {entry['acceptance_scope']}")
        if entry["recovery"] not in allowed_recovery:
            raise Failure(f"{code}: bad recovery {entry['recovery']}")
    return [f"errors: {len(seen)} codes valid"]


def check_identifiers(protocol: Path, identifiers: dict, limits: dict) -> list[str]:
    for value in identifiers["command_id"]["valid"]:
        if not COMMAND_ID.match(value):
            raise Failure(f"valid command id rejected by pattern: {value!r}")
        if int(value[4:]) > limits["MAX_SEQUENCE"]:
            raise Failure(f"valid command id exceeds MAX_SEQUENCE: {value!r}")
    for value in identifiers["command_id"]["invalid"]:
        if COMMAND_ID.match(value) and int(value[4:]) <= limits["MAX_SEQUENCE"]:
            raise Failure(f"invalid command id accepted by pattern: {value!r}")
    field_limits = {
        "SessionId": limits["MAX_ID_UTF8_BYTES"],
        "OptionId": limits["MAX_OPTION_ID_UTF8_BYTES"],
        "Cursor": limits["MAX_CURSOR_UTF8_BYTES"],
    }
    for case in identifiers["byte_limit_cases"]:
        size = len(case["char"].encode("utf-8")) * case["count"]
        expected = size <= field_limits[case["field"]]
        if expected != case["valid"]:
            raise Failure(f"byte limit case {case} disagrees with limits for {case['field']}")
    for value in identifiers["nul_and_control"]["invalid"]:
        if value.isprintable() and not any(ord(ch) < 0x20 for ch in value):
            raise Failure(f"expected a control character in {value!r}")
    return [f"identifiers: {len(identifiers['command_id']['valid'])} valid, {len(identifiers['command_id']['invalid'])} invalid ids"]


def normalize_integer(raw: str) -> tuple[bool, int | None]:
    value = json.loads(raw)
    if isinstance(value, bool) or value is None:
        return False, None
    if isinstance(value, int):
        return True, value
    if isinstance(value, float) and value.is_integer():
        return True, int(value)
    return False, None


def check_integer_vectors(vectors: dict) -> list[str]:
    for case in vectors["cases"]:
        valid, normalized = normalize_integer(case["json"])
        if valid != case["valid"]:
            raise Failure(f"integer case {case['json']}: expected valid={case['valid']}, got {valid}")
        if valid and normalized != case.get("normalized"):
            raise Failure(f"integer case {case['json']}: expected {case.get('normalized')}, got {normalized}")
    return [f"integer normalization: {len(vectors['cases'])} vectors"]


def check_ledger(protocol: Path, cases: dict, limits: dict) -> list[str]:
    seen = set()
    for case in cases["cases"]:
        if case["id"] in seen:
            raise Failure(f"duplicate ledger case id {case['id']}")
        seen.add(case["id"])
        if "given" not in case or "expect" not in case:
            raise Failure(f"{case['id']} needs given/expect")
    if limits["MAX_RETAINED_COMMANDS"] != 256:
        raise Failure("ledger vectors assume MAX_RETAINED_COMMANDS=256")
    return [f"ledger: {len(seen)} design cases"]


def check_result_examples(protocol: Path, examples: dict) -> list[str]:
    history = load(protocol / "results.schema.json")["$defs"]["History"]["required"]
    view = load(protocol / "results.schema.json")["$defs"]["CommandView"]["required"]
    page = load(protocol / "results.schema.json")["$defs"]["ObservationPage"]["required"]
    for name, required in (("history", history), ("command_view", view), ("observation_page", page)):
        missing = [key for key in required if key not in examples[name]]
        if missing:
            raise Failure(f"result example {name} missing {missing}")
    ok = examples["tool_reply_ok"]
    if not (ok["ok"] is True and ok["error"] is None and isinstance(ok["result"], dict)):
        raise Failure("tool_reply_ok must be ok=true/result object/error null")
    err = examples["tool_reply_error"]
    if not (err["ok"] is False and err["result"] is None and isinstance(err["error"], dict)):
        raise Failure("tool_reply_error must be ok=false/result null/error object")
    return [f"result examples: {len(history)}+{len(view)}+{len(page)} required fields"]


def check_schema_envelope(protocol: Path) -> list[str]:
    root = protocol.parent.parent
    requests = load(protocol / "requests.schema.json")
    if requests["properties"]["v"].get("const") != 4:
        raise Failure("requests.schema must pin v=4")
    runtime = (root / "overload/mod/mcp_bridge/Runtime.lua").read_text()
    # Only the TCP dispatch branches, not the auto-combat sub-ops or journal ops.
    dispatch = runtime[runtime.index("local function dispatch("):runtime.index("local function receive(")]
    live = set(re.findall(r"(?<![_a-z])op=='([a-z_]+)'", dispatch))
    schema_ops = set(requests["properties"]["op"]["enum"])
    missing = live - schema_ops
    extra = schema_ops - live
    if missing:
        raise Failure(f"requests.schema missing live Runtime ops: {sorted(missing)}")
    if extra:
        raise Failure(f"requests.schema declares unemitted Runtime ops: {sorted(extra)}")
    # The MCP server tools must map onto live ops (INT-01: no stale subset).
    server = (root / "server/src/tome_mcp/server.py").read_text()
    tools = {name.split(".", 1)[1] for name in re.findall(r'@server\.tool\(name="([^"]+)"', server)}
    tool_ops = {"list_collection" if t == "list" else "level_map" if t == "map" else t for t in tools}
    unknown = tool_ops - live
    if unknown:
        raise Failure(f"MCP tools without a live Runtime op: {sorted(unknown)}")
    if "$defs" not in requests:
        raise Failure("requests.schema needs $defs")
    return [f"requests: {len(schema_ops)} live ops, {len(requests['oneOf'])} op-bound args unions, v=4"]


def emitted_lua_codes(root: Path) -> set[str]:
    codes: set[str] = set()
    for path in (root / "overload").rglob("*.lua"):
        text = path.read_text()
        codes |= set(re.findall(r"fail\('([a-z_]+)'", text))
    return codes


def emitted_python_codes(root: Path) -> set[str]:
    codes: set[str] = set()
    for path in (root / "server/src/tome_mcp").glob("*.py"):
        text = path.read_text()
        codes |= set(re.findall(r'BridgeError\(\s*"([a-z_]+)"', text))
        codes |= set(re.findall(r'code="([a-z_]+)"', text))
    return codes


# Dynamic top-level codes produced from a store/arbiter result rather than a
# literal in `fail('...')` (kept here so the registry cannot silently drift).
DYNAMIC_EMITTED = {"policy_conflict", "no_draft", "control_busy"}


def check_error_emission(protocol: Path, errors: dict) -> list[str]:
    root = protocol.parent.parent
    registry = {entry["code"] for entry in errors["codes"]}
    emitted = emitted_lua_codes(root) | emitted_python_codes(root) | DYNAMIC_EMITTED
    unknown = emitted - registry
    if unknown:
        raise Failure(f"emitted error codes missing from the registry: {sorted(unknown)}")
    return [f"errors: {len(emitted)} emitted codes all registered"]


def check_error_envelope(protocol: Path, errors: dict) -> list[str]:
    schema = load(protocol / "errors.schema.json")
    required = set(schema["required"])
    categories = set(schema["properties"]["category"]["enum"])
    recovery = set(schema["properties"]["recovery"]["enum"])
    scopes = set(load(protocol / "common.schema.json")["$defs"]["AcceptanceScope"]["enum"])
    for entry in errors["codes"]:
        envelope = {
            "code": entry["code"],
            "category": entry["category"],
            "acceptance_scope": entry["acceptance_scope"],
            "message": entry["code"],
            "accepted": entry.get("accepted"),
            "uncertain": bool(entry.get("uncertain", False)),
            "recovery": entry["recovery"],
        }
        if not required <= set(envelope):
            raise Failure(f"error envelope {entry['code']} missing {sorted(required - set(envelope))}")
        if envelope["category"] not in categories:
            raise Failure(f"error envelope {entry['code']} bad category")
        if envelope["recovery"] not in recovery:
            raise Failure(f"error envelope {entry['code']} bad recovery")
        if envelope["acceptance_scope"] not in scopes:
            raise Failure(f"error envelope {entry['code']} bad acceptance_scope")
    return [f"errors: {len(errors['codes'])} envelopes match the schema"]


def generated_request_schema(protocol: Path) -> tuple[Path, str]:
    """Compile the supported request-schema vocabulary; unsupported gates fail generation."""
    requests = load(protocol / "requests.schema.json")
    common = load(protocol / "common.schema.json")
    annotations = {"$schema", "$id", "$comment", "title", "description", "$defs"}
    supported = {"type", "additionalProperties", "required", "properties", "items", "enum", "const",
                 "oneOf", "anyOf", "not", "minimum", "maximum", "minLength", "maxLength",
                 "minItems", "maxItems", "uniqueItems", "x-max-utf8-bytes", "x-max-sequence", "pattern"}
    patterns = {
        r"^[^\u0000-\u001f]*$": "^[^%z\x01-\x1f]*$",
        r"^[\x20-\x7e]+$": "^[ -~]+$",
        r"^cmd-[1-9][0-9]*$": "^cmd%-[1-9][0-9]*$",
    }

    def compile_schema(value: dict) -> dict:
        if "$ref" in value:
            ref = value["$ref"]
            source = common if ref.startswith("common.schema.json#") else requests
            if not (ref.startswith("common.schema.json#/$defs/") or ref.startswith("#/$defs/")):
                raise Failure(f"unsupported request schema reference: {ref}")
            return compile_schema(source["$defs"][ref.rsplit("/", 1)[1]])
        out = {}
        for key, item in value.items():
            if key in annotations:
                continue
            if key not in supported:
                raise Failure(f"unsupported request schema keyword: {key}")
            if key == "properties":
                item = {name: compile_schema(spec) for name, spec in item.items()}
            elif key in {"oneOf", "anyOf"}:
                item = [compile_schema(spec) for spec in item]
            elif key in {"not", "items"}:
                item = compile_schema(item)
            elif key == "pattern":
                if item not in patterns:
                    raise Failure(f"unsupported request schema pattern: {item}")
                item = patterns[item]
            out[key] = item
        return out

    def lua(value):
        if isinstance(value, dict):
            return "{" + ",".join("["+lua(k)+"]="+lua(v) for k,v in sorted(value.items())) + "}"
        if isinstance(value, list):
            return "{" + ",".join(lua(v) for v in value) + "}"
        if isinstance(value, str):
            # Lua 5.1 has decimal, not JSON Unicode, string escapes.
            return '"' + ''.join('\\'+c if c in '\\"' else f"\\{ord(c):03d}" if ord(c)<32 else c for c in value) + '"'
        if value is True: return "true"
        if value is False: return "false"
        if value is None: return "Json.null"
        return str(value)

    envelope = {k:v for k,v in requests.items() if k not in {"oneOf", "$defs"}}
    operations = {}
    for branch in requests["oneOf"]:
        props = branch["properties"]
        operations[props["op"]["const"]] = compile_schema(props["args"])
    lines = ["-- GENERATED by tools/generate_protocol.py; do not edit by hand.",
             "-- Closed public v4 ingress schemas; internal action carriers never use this module.",
             "local Json=require 'mod.mcp_bridge.Json'", "return {", "envelope="+lua(compile_schema(envelope))+",", "operations={"]
    for op, spec in operations.items():
        lines.append("["+lua(op)+"]="+lua(spec)+",")
    lines += ["}}", ""]
    return protocol.parent.parent / "overload/mod/mcp_bridge/RequestSchema.lua", "\n".join(lines)


def generated_modules(protocol: Path, errors: dict) -> dict[Path, str]:
    root = protocol.parent.parent
    lines = ["-- GENERATED by tools/generate_protocol.py; do not edit by hand.",
             "-- Spec v1.0 API-04 error recovery registry (single normative source).",
             "local M={}", "M.CODES={"]
    for entry in sorted(errors["codes"], key=lambda item: item["code"]):
        extra = ""
        if entry.get("accepted") is not None:
            extra += f",accepted={'true' if entry['accepted'] else 'false'}"
        if entry.get("uncertain"):
            extra += ",uncertain=true"
        lines.append(f"    ['{entry['code']}']={{category='{entry['category']}',"
                     f"acceptance_scope='{entry['acceptance_scope']}',recovery='{entry['recovery']}'{extra}}},")
    lines += ["}",
              "function M.envelope(code,message,details)",
              "    local entry=M.CODES[code] or {category='protocol',acceptance_scope='not_applicable',recovery='query_original_after_reconnect'}",
              "    local out={code=code,category=entry.category,acceptance_scope=entry.acceptance_scope,",
              "        message=message or code:gsub('_',' '),accepted=entry.accepted,uncertain=entry.uncertain==true,",
              "        recovery=entry.recovery}",
              "    if type(details)=='table' then for key,value in pairs(details) do out[key]=value end end",
              "    return out",
              "end",
              "return M"]
    lua = (root / "overload/mod/mcp_bridge/ErrorRegistry.lua")
    py_lines = ["# GENERATED by tools/generate_protocol.py; do not edit by hand.",
                '"""Spec v1.0 API-04 error recovery registry (single normative source)."""',
                "ERROR_CODES: dict[str, dict] = {"]
    for entry in sorted(errors["codes"], key=lambda item: item["code"]):
        py_lines.append(
            f'    "{entry["code"]}": {{"category": "{entry["category"]}", '
            f'"acceptance_scope": "{entry["acceptance_scope"]}", '
            f'"recovery": "{entry["recovery"]}", '
            f'"accepted": {"True" if entry.get("accepted") else "None" if entry.get("accepted") is None else "False"}, '
            f'"uncertain": {bool(entry.get("uncertain"))}}},')
    py_lines += ["}", "",
                 'DEFAULT: dict = {"category": "protocol", "acceptance_scope": "not_applicable",',
                 '                  "recovery": "query_original_after_reconnect", "accepted": None, "uncertain": False}',
                 "", "def defaults(code: str) -> dict:",
                 '    """Full envelope defaults for a code (unknown codes stay protocol)."""',
                 "    return ERROR_CODES.get(code, DEFAULT)"]
    py = (root / "server/src/tome_mcp/error_registry.py")
    request_path, request_text = generated_request_schema(protocol)
    return {lua: "\n".join(lines) + "\n", py: "\n".join(py_lines) + "\n", request_path: request_text}


def check_generated(protocol: Path, errors: dict) -> list[str]:
    for path, expected in generated_modules(protocol, errors).items():
        if not path.is_file() or path.read_text() != expected:
            raise Failure(f"generated protocol module out of date: {path}")
    return [f"generated request schema and Lua/Python error registries up to date ({len(errors['codes'])} codes)"]


def check_code_alignment(protocol: Path, limits: dict) -> list[str]:
    """Keep the contract and the two implementations from drifting (API-07)."""
    root = protocol.parent.parent
    bridge = (root / "server/src/tome_mcp/bridge.py").read_text()
    if not re.search(r"^PROTOCOL_VERSION = 4$", bridge, re.M):
        raise Failure("bridge.py PROTOCOL_VERSION must be 4")
    # PRO-02: product version is consistent across Lua, Python package and module.
    if "addon_version = {0, 9, 0}" not in (root / "init.lua").read_text():
        raise Failure("init.lua addon_version must be 0.9.0")
    if not re.search(r'^version = "0\.9\.0"$', (root / "server/pyproject.toml").read_text(), re.M):
        raise Failure("server/pyproject.toml version must be 0.9.0")
    if '__version__ = "0.9.0"' not in (root / "server/src/tome_mcp/__init__.py").read_text():
        raise Failure("tome_mcp.__version__ must be 0.9.0")
    runtime = (root / "overload/mod/mcp_bridge/Runtime.lua").read_text()
    if "request.v~=4" not in runtime:
        raise Failure("Runtime.lua must reject request.v~=4")
    if "local response={v=4" not in runtime:
        raise Failure("Runtime.lua must emit a v=4 response envelope")
    interactions = (root / "overload/mod/mcp_bridge/Interactions.lua").read_text()
    match = re.search(r"MAX_RESPONSES=(\d+)", interactions)
    if not match or int(match.group(1)) != limits["MAX_RESPONSES_PER_COMMAND"]:
        raise Failure("Interactions.MAX_RESPONSES disagrees with limits.MAX_RESPONSES_PER_COMMAND")
    match = re.search(r"MAX_RETAINED_COMMANDS=(\d+)", runtime)
    if not match or int(match.group(1)) != limits["MAX_RETAINED_COMMANDS"]:
        raise Failure("Runtime MAX_RETAINED_COMMANDS disagrees with limits")
    ledger = (root / "overload/mod/mcp_bridge/CommandLedger.lua").read_text()
    if "MAX_SEQ = 9007199254740991" not in ledger:
        raise Failure("CommandLedger MAX_SEQ disagrees with limits.MAX_SEQUENCE")
    return ["code alignment: v4 + shared limits match"]


def check_commandview_schema(protocol: Path, limits: dict) -> list[str]:
    """The strict CommandView schema must match the real Runtime output (F5)."""
    root = protocol.parent.parent
    runtime = (root / "overload/mod/mcp_bridge/Runtime.lua").read_text()
    body = runtime[runtime.index("local function commandView"):runtime.index("local function receiptBytes")]
    names = set(re.findall(r"out\.([A-Za-z_]+)\s*=", body))
    table = re.search(r"ipairs\{(.*?)\}", body, re.S)
    if table:
        names |= set(re.findall(r"'([A-Za-z_]+)'", table.group(1)))
    schema = set(load(protocol / "results.schema.json")["$defs"]["CommandView"]["properties"])
    missing = names - schema
    extra = schema - names
    if missing:
        raise Failure(f"CommandView emits undeclared fields: {sorted(missing)}")
    if extra:
        raise Failure(f"CommandView schema declares unemitted fields: {sorted(extra)}")
    if f"MAX_RECENT_SNAPSHOTS={limits['MAX_RECENT_SNAPSHOTS']}" not in runtime:
        raise Failure("Runtime MAX_RECENT_SNAPSHOTS disagrees with limits")
    if f"SNAPSHOT_BYTE_BUDGET={limits['SNAPSHOT_BYTE_BUDGET']}" not in runtime:
        raise Failure("Runtime SNAPSHOT_BYTE_BUDGET disagrees with limits")
    return [f"commandview: {len(names)} fields match the schema"]


def check_result_coverage(protocol: Path, examples: dict) -> list[str]:
    """INT-01/D7: every live op has representative result fields, or is an
    explicitly declared unmodeled gap. A full result schema is not required."""
    root = protocol.parent.parent
    runtime = (root / "overload/mod/mcp_bridge/Runtime.lua").read_text()
    dispatch = runtime[runtime.index("local function dispatch("):runtime.index("local function receive(")]
    live = set(re.findall(r"(?<![_a-z])op=='([a-z_]+)'", dispatch))
    ops = examples.get("ops", {})
    allow = set(examples.get("unmodeled_ops", []))
    missing = live - set(ops) - allow
    if missing:
        raise Failure(f"result coverage gap (declare unmodeled_ops): {sorted(missing)}")
    for name, fields in ops.items():
        if not isinstance(fields, list) or not fields:
            raise Failure(f"result op {name} needs representative fields")
    return [f"results: {len(ops)} ops documented, {len(allow)} declared gaps"]


def check_all(protocol: Path) -> list[str]:
    if not protocol.is_dir():
        raise Failure(f"protocol directory missing: {protocol}")
    for name in ("common.schema.json", "requests.schema.json", "results.schema.json", "errors.schema.json"):
        load(protocol / name)
    limits = load(protocol / "limits.json")
    errors = load(protocol / "vectors/error-codes.json")
    identifiers = load(protocol / "vectors/identifiers.json")
    integers = load(protocol / "vectors/integer-normalization.json")
    ledger = load(protocol / "vectors/ledger-cases.json")
    examples = load(protocol / "vectors/result-examples.json")
    notes: list[str] = []
    notes += check_schema_envelope(protocol)
    notes += check_limits(protocol, limits)
    notes += check_errors(protocol, errors)
    notes += check_error_emission(protocol, errors)
    notes += check_error_envelope(protocol, errors)
    notes += check_generated(protocol, errors)
    notes += check_identifiers(protocol, identifiers, limits)
    notes += check_integer_vectors(integers)
    notes += check_ledger(protocol, ledger, limits)
    notes += check_result_examples(protocol, examples)
    notes += check_result_coverage(protocol, examples)
    notes += check_commandview_schema(protocol, limits)
    notes += check_code_alignment(protocol, limits)
    return notes


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the protocol/v4 contract consistency")
    parser.add_argument("--check", action="store_true", help="validate and exit non-zero on drift")
    parser.add_argument("--root", default=str(DEFAULT_PROTOCOL), help="protocol directory (default protocol/v4)")
    args = parser.parse_args()
    try:
        protocol = Path(args.root)
        limits = load(protocol / "limits.json")
        errors = load(protocol / "vectors/error-codes.json")
        if not args.check:
            for path, text in generated_modules(protocol, errors).items():
                path.write_text(text)
        notes = check_all(protocol)
    except Failure as exc:
        print(f"protocol check FAILED: {exc}", file=sys.stderr)
        return 1
    for note in notes:
        print(f"protocol check: {note}")
    print("protocol check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
