#!/usr/bin/env python3
"""Verify evidence references and every declared local provenance file.

Evidence/gate paths are relative to the manifest. Legacy raw_sources maps use
repo-relative paths (--root); list-form raw_sources and artifacts use records
{path, sha256, base?}, where base is manifest (default), repo, or absolute.
Files in mounted external archives may use base=absolute. No hashes or missing
historical files are silently waived. A successful check proves byte/reference
integrity, not gate behavior or native execution. See the tooling feedback doc.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

VALID_STATUS = {"passed", "failed", "skipped", "not_run", "partial"}
ROOT_KEYS = {
    "schema_version", "candidate_id", "product_version", "protocol_version",
    "code_baseline", "candidate_commit", "candidate_commit_note", "evidence_note",
    "raw_sources", "package", "environment", "commands", "evidence", "gates",
    "limitations", "artifacts", "source", "notes",
}


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def verify(manifest, base: Path, root: Path) -> list[str]:
    errors: list[str] = []

    def record(value, label, required, allowed):
        if not isinstance(value, dict):
            errors.append(f"{label}: expected object")
            return False
        missing, extra = required - value.keys(), value.keys() - allowed
        if missing:
            errors.append(f"{label}: missing keys {sorted(missing)}")
        if extra:
            errors.append(f"{label}: unknown keys {sorted(extra)}")
        return not missing and not extra

    def array(value, label):
        if not isinstance(value, list):
            errors.append(f"{label}: expected array")
            return []
        return value

    def string(value):
        return isinstance(value, str) and bool(value.strip())

    def digest(value, label):
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            errors.append(f"{label}: expected lowercase SHA-256")
            return False
        return True

    def location(entry, label):
        path, scope = entry.get("path"), entry.get("base", "manifest")
        if not string(path) or "\x00" in path:
            errors.append(f"{label}: invalid path")
            return None
        if scope not in ("manifest", "repo", "absolute"):
            errors.append(f"{label}: invalid base {scope!r}")
            return None
        candidate = Path(path)
        if scope == "absolute":
            if not candidate.is_absolute():
                errors.append(f"{label}: absolute base requires absolute path")
                return None
        else:
            if candidate.is_absolute() or ".." in candidate.parts:
                errors.append(f"{label}: relative base requires a contained relative path")
                return None
            anchor = base if scope == "manifest" else root
            candidate = anchor / candidate
            if not candidate.resolve().is_relative_to(anchor.resolve()):
                errors.append(f"{label}: path escapes declared base")
                return None
        return candidate.resolve()

    def files(entries, label, *, evidence=False):
        valid_refs, paths, ids, refs = set(), set(), set(), set()
        for index, entry in enumerate(array(entries, label)):
            name = f"{label}[{index}]"
            allowed = {"path", "sha256", "id", "note"} | (set() if evidence else {"base"})
            if not record(entry, name, {"path", "sha256"}, allowed):
                continue
            before = len(errors)
            if "id" in entry:
                ident = entry["id"]
                if not string(ident):
                    errors.append(f"{name}: invalid id")
                elif ident in ids:
                    errors.append(f"{name}: duplicate id {ident}")
                else:
                    ids.add(ident)
            ref = entry["path"]
            if string(ref):
                if ref in refs:
                    errors.append(f"{name}: duplicate path {ref}")
                refs.add(ref)
            path = location(entry, name)
            hash_ok = digest(entry["sha256"], name)
            if path is not None:
                if path in paths:
                    errors.append(f"{name}: duplicate resolved path {path}")
                paths.add(path)
                if not path.is_file():
                    errors.append(f"{name}: missing file {path}")
                elif hash_ok:
                    try:
                        if sha256(path) != entry["sha256"]:
                            errors.append(f"{name}: hash mismatch {path}")
                    except OSError as exc:
                        errors.append(f"{name}: unreadable file: {exc}")
            if len(errors) == before:
                valid_refs.add(ref)
        return valid_refs

    if not record(manifest, "manifest", {"evidence", "gates"}, ROOT_KEYS):
        return errors
    if "schema_version" in manifest and (type(manifest["schema_version"]) is not int
                                           or manifest["schema_version"] not in (1, 2)):
        errors.append("manifest: unsupported schema_version")
    evidence = files(manifest["evidence"], "evidence", evidence=True)
    gate_ids = set()
    for index, gate in enumerate(array(manifest["gates"], "gates")):
        label = f"gates[{index}]"
        if not record(gate, label, {"id", "status", "evidence"},
                      {"id", "name", "status", "evidence", "reason", "note"}):
            continue
        ident = gate["id"]
        if not string(ident):
            errors.append(f"{label}: invalid id")
        elif ident in gate_ids:
            errors.append(f"{label}: duplicate gate id {ident}")
        else:
            gate_ids.add(ident)
        if not isinstance(gate["status"], str) or gate["status"] not in VALID_STATUS:
            errors.append(f"{label}: invalid status {gate['status']!r}")
        references = array(gate["evidence"], f"{label}.evidence")
        if gate["status"] == "passed" and not references:
            errors.append(f"{label}: passed without evidence")
        seen = set()
        for ref in references:
            if not string(ref):
                errors.append(f"{label}: invalid evidence reference")
            elif ref in seen:
                errors.append(f"{label}: duplicate evidence reference {ref}")
            else:
                seen.add(ref)
                if ref not in evidence:
                    errors.append(f"{label}: evidence is undeclared or not hash-verified: {ref}")

    raw = manifest.get("raw_sources", [])
    if isinstance(raw, dict):  # historical format, explicitly repo-relative
        raw = [{"path": path, "sha256": value, "base": "repo"} for path, value in raw.items()]
    files(raw, "raw_sources")
    files(manifest.get("artifacts", []), "artifacts")
    if "package" in manifest:
        package = manifest["package"]
        pairs = (("addon_archive", "archive_sha256"), ("python_source", "python_source_sha256"),
                 ("game_engine", "game_engine_sha256"))
        allowed = {"plugin_combination"} | {key for pair in pairs for key in pair}
        if record(package, "package", set(), allowed):
            for path_key, hash_key in pairs:
                if path_key not in package and hash_key not in package:
                    continue
                if not string(package.get(path_key)):
                    errors.append(f"package.{path_key}: unverifiable provenance; supply path or migrate to artifacts")
                    continue
                files([{"path": package[path_key], "sha256": package.get(hash_key)}], f"package.{path_key}")
    return errors


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="repository root for legacy raw_sources and base=repo records")
    args = parser.parse_args(argv)
    try:
        manifest = json.loads(args.manifest.read_text(), object_pairs_hook=unique_object)
        errors = verify(manifest, args.manifest.resolve().parent, args.root.resolve())
    except (OSError, ValueError, RecursionError) as exc:
        errors = [str(exc)]
    if errors:
        print("manifest check FAILED:\n- " + "\n- ".join(errors), file=sys.stderr)
        return 1
    print(f"manifest check: OK ({len(manifest['evidence'])} evidence files, "
          f"{len(manifest['gates'])} gates; all declared provenance verified; byte integrity only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
