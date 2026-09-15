#!/usr/bin/env python3
"""Build a reproducible addon archive containing only production files."""

from pathlib import Path
import hashlib
import json
import zipfile

from generate_native_seams import generate

ROOT = Path(__file__).resolve().parents[1]


def main():
    for path, expected in generate().items():
        if not path.is_file() or path.read_text() != expected:
            raise SystemExit('Native seam out of date: ' + str(path))
    files = [ROOT / "init.lua", ROOT / "README.md"]
    for name in ("hooks", "superload", "overload"):
        files.extend(sorted((ROOT / name).rglob("*.lua")))
    missing = [str(p) for p in files if not p.is_file()]
    if missing:
        raise SystemExit("Missing production files: " + ", ".join(missing))
    if not all((ROOT / name).is_dir() for name in ("hooks", "superload", "overload")):
        raise SystemExit("Production addon directories are incomplete")
    target = ROOT / "dist"
    target.mkdir(exist_ok=True)
    archive = target / "tome-mcp-bridge.teaa"
    manifest = {}
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as out:
        for file in sorted(files):
            relative = file.relative_to(ROOT).as_posix()
            data = file.read_bytes()
            info = zipfile.ZipInfo(relative, date_time=(2026, 9, 15, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            out.writestr(info, data)
            manifest[relative] = hashlib.sha256(data).hexdigest()
    result = {
        "archive": archive.name,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "files": manifest,
    }
    (target / "manifest.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"archive": str(archive), "files": len(files), "sha256": result["sha256"]}))


if __name__ == "__main__":
    main()
