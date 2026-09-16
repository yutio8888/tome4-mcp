#!/usr/bin/env python3
"""Verify a validation manifest points at existing, hash-matching evidence.

Usage:
    python3 tools/verify_validation_manifest.py validation/0.9.0/<candidate>/manifest.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

VALID_STATUS = {"passed", "failed", "skipped", "not_run", "partial"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    if not args.manifest.is_file():
        print(f"manifest check FAILED: missing {args.manifest}", file=sys.stderr)
        return 1
    manifest = json.loads(args.manifest.read_text())
    base = args.manifest.parent
    errors: list[str] = []
    evidence = manifest.get("evidence", [])
    for entry in evidence:
        path = base / entry["path"]
        if not path.is_file():
            errors.append(f"missing evidence: {entry['path']}")
            continue
        if sha256(path) != entry.get("sha256"):
            errors.append(f"hash mismatch: {entry['path']}")
    for gate in manifest.get("gates", []):
        if gate.get("status") not in VALID_STATUS:
            errors.append(f"gate {gate.get('id')} has invalid status {gate.get('status')!r}")
        if gate.get("status") == "passed" and not gate.get("evidence"):
            errors.append(f"gate {gate.get('id')} passed without evidence")
    if errors:
        print("manifest check FAILED: " + "; ".join(errors), file=sys.stderr)
        return 1
    print(f"manifest check: OK ({len(evidence)} evidence files, {len(manifest.get('gates', []))} gates)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
