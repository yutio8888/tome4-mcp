#!/usr/bin/env python3
"""Validate the protocol/v4 contract and its cross-language vectors.

This is the M0 contract-consistency check from Spec v1.0 API-07. It does not
execute the bridge; it fails when the schema files, limits and vectors drift
apart. Generated Lua/Python validators are wired in M2/M4.

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
    requests = load(protocol / "requests.schema.json")
    if requests["properties"]["v"].get("const") != 4:
        raise Failure("requests.schema must pin v=4")
    ops = set(requests["properties"]["op"]["enum"])
    expected = {"connect", "connect_observer", "observe", "inspect", "list_collection", "act", "respond", "status", "stop"}
    if ops != expected:
        raise Failure(f"request ops disagree: {ops ^ expected}")
    if "$defs" not in requests:
        raise Failure("requests.schema needs $defs")
    return [f"requests: {len(ops)} ops, v=4"]


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
    notes += check_identifiers(protocol, identifiers, limits)
    notes += check_integer_vectors(integers)
    notes += check_ledger(protocol, ledger, limits)
    notes += check_result_examples(protocol, examples)
    return notes


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the protocol/v4 contract consistency")
    parser.add_argument("--check", action="store_true", help="validate and exit non-zero on drift")
    parser.add_argument("--root", default=str(DEFAULT_PROTOCOL), help="protocol directory (default protocol/v4)")
    args = parser.parse_args()
    if not args.check:
        parser.error("only --check is implemented in M0")
    try:
        notes = check_all(Path(args.root))
    except Failure as exc:
        print(f"protocol check FAILED: {exc}", file=sys.stderr)
        return 1
    for note in notes:
        print(f"protocol check: {note}")
    print("protocol check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
