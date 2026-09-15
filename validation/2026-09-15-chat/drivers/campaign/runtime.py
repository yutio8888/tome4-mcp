"""Load a copy of the recorded ordinary campaign without a gameplay fixture."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

NATIVE_PATH = Path(__file__).resolve().parents[1] / "native/runtime.py"
spec = importlib.util.spec_from_file_location("mcp_native_runtime", NATIVE_PATH)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
WORKSPACE = native.WORKSPACE
DEFAULT_SESSION = WORKSPACE / "tmp/tome-mcp-validation/sessions/campaign-play-01"
CONTINUATION_SESSION = WORKSPACE / "tmp/tome-mcp-validation/sessions/campaign-play-v030-01"
SAVE_RELATIVE = Path("home/.t-engine/4.0/tome/save")


def hashes(root: Path) -> dict[str, str]:
    return {str(p.relative_to(root)): native.sha(p) for p in sorted(root.rglob("*")) if p.is_file()}


def source_records(workspace: Path = WORKSPACE) -> dict[str, dict]:
    """Read the two explicitly published campaign sources and their lineage."""
    paths = {
        "campaign-play-01": workspace / "documentation/mcp-campaign-trial-2026-09-15.json",
        "campaign-play-v030-01": workspace / "documentation/mcp-campaign-continuation-0.3.0.json",
    }
    documents = {key: json.loads(path.read_text()) for key, path in paths.items()}
    records = {}
    for key, document in documents.items():
        assert document["session"] == key and document["normal_campaign"] is True and document["cheat"] is False
        session = workspace / "tmp/tome-mcp-validation/sessions" / key
        prefix = str((session / SAVE_RELATIVE).relative_to(workspace)) + "/"
        published = {name.removeprefix(prefix): value for name, value in document["sha256"].items()
                     if name.startswith(prefix)}
        assert published, "Recorded save hashes are missing: " + key
        records[key] = dict(id=key, session=session.resolve(), evidence=paths[key].resolve(),
                            evidence_sha256=native.sha(paths[key]), published_save_sha256=published,
                            save_sha256=published, engine_sha256=document["input"]["engine_sha256"],
                            expected_state=document["last_snapshot"] if key == "campaign-play-01" else document["last_state"])
    continuation = documents["campaign-play-v030-01"]
    trial = records["campaign-play-01"]
    assert Path(continuation["input"]["source_session"]).resolve() == trial["session"], \
        "Continuation evidence is not linked to the recorded first campaign"
    original = continuation["input"]["source_save_sha256"]
    assert set(original) == set(continuation["original_save_hashes_unchanged"])
    assert all(continuation["original_save_hashes_unchanged"].values())
    assert all(original.get(name) == value for name, value in trial["published_save_sha256"].items()), \
        "Published original save hashes disagree across the two reports"
    trial["save_sha256"] = dict(original)
    expected_names = {"quick_hotkeys", "world.teaw", *(
        "mcp_campaign_play_01/" + name for name in ("cur.png", "desc.lua", "game.teag", "last_log.txt"))}
    assert all(set(record["save_sha256"]) == expected_names for record in records.values()), \
        "Each recorded campaign source must identify all six save files"
    for record in records.values():
        record["supporting_addon_sha256"] = continuation["input"]["supporting_addon_sha256"]
    return records


def validate_source(source_session: Path, *, records: dict[str, dict] | None = None,
                    source_record: str | None = None) -> tuple[dict, dict[str, str]]:
    """Accept only a recorded source or an explicitly linked, byte-identical copy.

    The old arbitrary-copy argument keeps its original Lv1 meaning. A relocated
    Lv3 copy must explicitly select the continuation record; a canonical Lv3
    session is selected by its recorded path.
    """
    records = records if records is not None else source_records()
    source_session = source_session.resolve()
    canonical = next((key for key, record in records.items() if record["session"] == source_session), None)
    if source_record is not None:
        assert source_record in records, "Unknown campaign source record"
        assert canonical is None or canonical == source_record, "Source path belongs to a different recorded campaign"
    selected = source_record or canonical or "campaign-play-01"
    record = records[selected]
    actual = hashes(source_session / SAVE_RELATIVE)
    assert actual and actual == record["save_sha256"], \
        "The source save differs from the complete published campaign record: " + selected
    return record, actual


class CampaignRuntime(native.Runtime):
    def __init__(self, name: str, source_session: Path = DEFAULT_SESSION,
                 addon_archive: Path | None = None, *, source_record: str | None = None):
        self.source_session = source_session.resolve()
        self.original_save = self.source_session / SAVE_RELATIVE
        self.source_records = source_records()
        self.source_record, self.original_hashes = validate_source(self.source_session, records=self.source_records,
                                                                  source_record=source_record)
        self.recorded_save_hashes = self.source_record["save_sha256"]
        self.historical_hashes = {key: validate_source(record["session"], records=self.source_records)[1]
                                  for key, record in self.source_records.items()}
        descriptions = list(self.original_save.glob("*/desc.lua"))
        assert len(descriptions) == 1, "Expected the one recorded campaign character"
        description = descriptions[0].read_text()
        assert "cheat = false" in description and "loadable = true" in description
        character = re.search(r'^name = "([^"]+)"', description, re.MULTILINE).group(1)
        original_input = json.loads((self.source_session / "input.json").read_text())
        original_addons = self.source_session / "runtime/game/addons"
        extras = {
            "battle-companion": original_addons / "tome-battle-companion.teaa",
            "danger-alert": original_addons / "tome-danger-alert.teaa",
            "mcp-play-birth": original_addons / "tome-mcp-play-birth",
        }
        supporting_hashes = {key: native.sha(path) if path.is_file() else hashes(path) for key, path in extras.items()}
        assert supporting_hashes == self.source_record["supporting_addon_sha256"], \
            "Supporting addons differ from the published continuation evidence"
        assert native.sha(Path(original_input["source"]) / "t-engine") == self.source_record["engine_sha256"], \
            "Native engine differs from the published source evidence"
        super().__init__(name, Path(original_input["source"]), Path(original_input["dependencies"]),
                         addon_archive=addon_archive, extra_addons=extras)
        # Only edit the newly created, unstarted runtime and home owned here.
        addons = self.runtime / "game/addons"
        shutil.rmtree(addons / "tome-mcp-probe")
        source_dist = addons / "tome-mcp-bridge/dist"
        if source_dist.is_dir():
            shutil.rmtree(source_dist)
        shutil.rmtree(self.home)
        shutil.copytree(self.source_session / "home", self.home)
        settings = self.home / ".t-engine/4.0/settings/mcp-test.cfg"
        text = settings.read_text()
        assert re.search(r"^cheat\s*=\s*false\s*$", text, re.MULTILINE)
        text, count = re.subn(r"^tome_mcp_bridge\s*=.*$",
                             'tome_mcp_bridge = {enabled=true,port=%d,token="%s"}' % (self.port, self.token),
                             text, flags=re.MULTILINE)
        assert count == 1
        settings.write_text(text)
        self.command = [str(self.runtime / "t-engine"), "--no-steam", "--no-web", "--flush-stdout",
                        "--home", str(self.home), "-Mtome", "-u" + character, "-Eno_birth_popup=true"]
        self.server_source = self.session / "mcp-server-src"
        shutil.copytree(WORKSPACE / "tools/tome-mcp-server/src", self.server_source,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        harness = self.session / "harness-source"
        for directory in ("campaign", "native"):
            target = harness / directory
            target.mkdir(parents=True)
            sources = Path(__file__).parent.glob("*.py") if directory == "campaign" else [NATIVE_PATH]
            for source in sources:
                shutil.copy2(source, target / source.name)
        with zipfile.ZipFile(self.session / "candidate.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(addons.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(addons))
        metadata = json.loads((self.session / "input.json").read_text())
        metadata.update(command=self.command, new_character=False, imported_save=True,
                        copied_recorded_test_save=True, source_session=str(self.source_session),
                        source_record=self.source_record["id"], source_evidence=str(self.source_record["evidence"]),
                        source_evidence_sha256=self.source_record["evidence_sha256"],
                        source_save_sha256=self.original_hashes, recorded_save_sha256=self.recorded_save_hashes,
                        historical_source_save_sha256=self.historical_hashes,
                        historical_source_evidence_sha256={key: record["evidence_sha256"] for key, record in self.source_records.items()},
                        cheat=False, normal_campaign=True,
                        gameplay_fixture=False, character_name=character,
                        candidate_sha256=native.sha(self.session / "candidate.zip"),
                        supporting_addon_sha256=supporting_hashes,
                        source_engine_sha256=self.source_record["engine_sha256"],
                        addon_lua_sha256={str(p.relative_to(addons)): native.sha(p) for p in addons.rglob("*.lua")},
                        mcp_server_py_sha256={str(p.relative_to(self.server_source)): native.sha(p)
                                             for p in self.server_source.rglob("*.py")},
                        runner_sha256={p.name: native.sha(p) for p in Path(__file__).parent.glob("*.py")})
        (self.session / "input.json").write_text(json.dumps(metadata, indent=2))
        assert hashes(self.home / ".t-engine/4.0/tome/save") == self.original_hashes

    def source_unchanged(self) -> bool:
        return hashes(self.original_save) == self.original_hashes and all(self.historical_sources_unchanged().values())

    def historical_sources_unchanged(self) -> dict[str, bool]:
        return {key: hashes(record["session"] / SAVE_RELATIVE) == self.historical_hashes[key]
                for key, record in self.source_records.items()}

    def restart_from_saved_copy(self) -> Path:
        """Reload a copy of this run's native save without any gameplay probe."""
        assert self.process and self.process.poll() is None
        self.process.terminate()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        original_home = self.home
        saved_hashes = hashes(original_home / ".t-engine/4.0/tome/save")
        self.home = self.session / "reload-home"
        shutil.copytree(original_home, self.home)
        assert hashes(self.home / ".t-engine/4.0/tome/save") == saved_hashes
        command = [str(self.home) if arg == str(original_home) else arg for arg in self.command]
        (self.session / "reload-input.json").write_text(json.dumps(dict(
            command=command, source_home=str(original_home), reloaded_own_test_save=True,
            source_save_sha256=saved_hashes, historical_source_save_sha256=self.historical_hashes,
            port=self.port, engine_sha256=native.sha(self.runtime / "t-engine")), indent=2))
        log_path = self.session / "reload.log"
        log = log_path.open("w")
        self.handles.append(log)
        self.log_paths.append(log_path)
        self.process = subprocess.Popen(command, cwd=self.runtime, env=self.env, stdout=log, stderr=subprocess.STDOUT)
        (self.session / "reload.pid").write_text(str(self.process.pid))
        return original_home
