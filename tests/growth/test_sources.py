"""Source provenance regressions; all mutations use temporary synthetic files."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

RUNTIME_PATH = Path(__file__).resolve().parents[1] / "campaign/runtime.py"
spec = importlib.util.spec_from_file_location("campaign_runtime", RUNTIME_PATH)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class SourceRecords(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "documentation").mkdir()
        self.paths = {}
        self.expected = {}
        self.names = ("quick_hotkeys", "world.teaw", "mcp_campaign_play_01/cur.png",
                      "mcp_campaign_play_01/desc.lua", "mcp_campaign_play_01/game.teag",
                      "mcp_campaign_play_01/last_log.txt")
        for key in ("campaign-play-01", "campaign-play-v030-01"):
            path = self.root / "tmp/tome-mcp-validation/sessions" / key
            self.paths[key] = path
            for name in self.names:
                target = path / runtime.SAVE_RELATIVE / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(key + ":" + name)
            self.expected[key] = runtime.hashes(path / runtime.SAVE_RELATIVE)
        self.documents = {}
        for key, level in (("campaign-play-01", 1), ("campaign-play-v030-01", 3)):
            prefix = str((self.paths[key] / runtime.SAVE_RELATIVE).relative_to(self.root)) + "/"
            included = self.expected[key] if level == 3 else {name: self.expected[key][name] for name in
                ("mcp_campaign_play_01/desc.lua", "mcp_campaign_play_01/game.teag")}
            self.documents[key] = dict(session=key, normal_campaign=True, cheat=False,
                input=dict(engine_sha256="e" * 64),
                sha256={prefix + name: value for name, value in included.items()},
                **{"last_snapshot" if level == 1 else "last_state": {"player": {"level": level}}})
        self.documents["campaign-play-v030-01"].update(
            input=dict(source_session=str(self.paths["campaign-play-01"]),
                       source_save_sha256=self.expected["campaign-play-01"], engine_sha256="e" * 64,
                       supporting_addon_sha256={"battle-companion": "b" * 64, "danger-alert": "d" * 64,
                                               "mcp-play-birth": {"init.lua": "a" * 64}}),
            original_save_hashes_unchanged={name: True for name in self.names})
        self.write_documents()

    def write_documents(self):
        for key, filename in (("campaign-play-01", "mcp-campaign-trial-2026-09-15.json"),
                              ("campaign-play-v030-01", "mcp-campaign-continuation-0.3.0.json")):
            (self.root / "documentation" / filename).write_text(json.dumps(self.documents[key]))

    def records(self):
        return runtime.source_records(self.root)

    def copy(self, key):
        destination = self.root / "relocated-copy"
        shutil.copytree(self.paths[key], destination)
        return destination

    def test_both_recorded_paths_require_all_six_save_files(self):
        records = self.records()
        for key, source in self.paths.items():
            record, actual = runtime.validate_source(source, records=records)
            self.assertEqual(record["id"], key)
            self.assertEqual(actual, self.expected[key])
            self.assertEqual(len(record["save_sha256"]), 6)

    def test_existing_lv1_copy_argument_keeps_lv1_meaning(self):
        record, _ = runtime.validate_source(self.copy("campaign-play-01"), records=self.records())
        self.assertEqual(record["id"], "campaign-play-01")

    def test_unlinked_lv3_copy_cannot_bypass_lv1_validation(self):
        with self.assertRaisesRegex(AssertionError, "complete published"):
            runtime.validate_source(self.copy("campaign-play-v030-01"), records=self.records())

    def test_explicitly_linked_lv3_copy_is_accepted(self):
        record, _ = runtime.validate_source(self.copy("campaign-play-v030-01"), records=self.records(),
                                             source_record="campaign-play-v030-01")
        self.assertEqual(record["id"], "campaign-play-v030-01")

    def test_known_source_path_cannot_select_the_other_record(self):
        with self.assertRaisesRegex(AssertionError, "different recorded"):
            runtime.validate_source(self.paths["campaign-play-01"], records=self.records(),
                                    source_record="campaign-play-v030-01")

    def test_tampering_with_auxiliary_save_is_rejected(self):
        source = self.copy("campaign-play-v030-01")
        (source / runtime.SAVE_RELATIVE / "quick_hotkeys").write_text("changed")
        with self.assertRaisesRegex(AssertionError, "complete published"):
            runtime.validate_source(source, records=self.records(), source_record="campaign-play-v030-01")

    def test_extra_save_file_is_rejected(self):
        source = self.copy("campaign-play-v030-01")
        (source / runtime.SAVE_RELATIVE / "extra.teag").write_text("unexpected")
        with self.assertRaisesRegex(AssertionError, "complete published"):
            runtime.validate_source(source, records=self.records(), source_record="campaign-play-v030-01")

    def test_missing_save_file_is_rejected(self):
        source = self.copy("campaign-play-v030-01")
        (source / runtime.SAVE_RELATIVE / "world.teaw").unlink()
        with self.assertRaisesRegex(AssertionError, "complete published"):
            runtime.validate_source(source, records=self.records(), source_record="campaign-play-v030-01")

    def test_unrelated_continuation_parent_is_rejected(self):
        self.documents["campaign-play-v030-01"]["input"]["source_session"] = str(self.root / "unrelated")
        self.write_documents()
        with self.assertRaisesRegex(AssertionError, "not linked"):
            self.records()

    def test_disagreement_between_original_reports_is_rejected(self):
        self.documents["campaign-play-v030-01"]["input"]["source_save_sha256"]["mcp_campaign_play_01/game.teag"] = "wrong"
        self.write_documents()
        with self.assertRaisesRegex(AssertionError, "disagree"):
            self.records()

    def test_published_continuation_must_cover_all_six_files(self):
        sha256 = self.documents["campaign-play-v030-01"]["sha256"]
        del sha256[next(name for name in sha256 if name.endswith("/cur.png"))]
        self.write_documents()
        with self.assertRaisesRegex(AssertionError, "all six"):
            self.records()


if __name__ == "__main__":
    unittest.main()
