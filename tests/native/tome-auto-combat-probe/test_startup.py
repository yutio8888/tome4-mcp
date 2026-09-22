"""Offline runner configuration check: no Runtime instance or engine launch."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


class StartupConfig(unittest.TestCase):
    def test_config_flag_and_evidence(self):
        runner = Path(__file__).resolve().parent.parent / 'auto_combat_run.py'
        fake_runtime = types.ModuleType('runtime')
        fake_runtime.DEFAULT_DEPS = fake_runtime.DEFAULT_SOURCE = fake_runtime.WORKSPACE = runner.parent
        fake_runtime.Runtime = object
        fake_runtime.sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        spec = importlib.util.spec_from_file_location('auto_combat_runner_startup_test', runner)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, runtime=fake_runtime):
            spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            setting = root / 'home/.t-engine/4.0/settings/mcp-test.cfg'
            setting.parent.mkdir(parents=True)
            setting.write_text('cheat = true\n')
            metadata = root / 'input.json'
            metadata.write_text(json.dumps({'engine_sha256': 'unchanged-engine'}))
            fixture = types.SimpleNamespace(home=root / 'home', session=root)
            module.configure_policy_only(fixture)
            self.assertEqual(setting.read_text(), 'cheat = true\n\ntome_mcp_sysfix_policy_probe = true\n')
            record = json.loads(metadata.read_text())
            self.assertTrue(record['sysfix_policy'])
            self.assertEqual(record['engine_sha256'], 'unchanged-engine')
            self.assertEqual(record['sysfix_policy_setting_sha256'], fake_runtime.sha(setting))


if __name__ == '__main__':
    unittest.main()
