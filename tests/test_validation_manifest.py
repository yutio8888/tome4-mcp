"""Exercise the real manifest CLI, including historical-format provenance."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools/verify_validation_manifest.py'


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / 'candidate'
        self.base.mkdir()
        for name in ('summary.json', 'raw.json', 'addon.teaa'):
            (self.base / name).write_text('fixture ' + name)
        self.entry = lambda name: {'path': name, 'sha256': hashlib.sha256((self.base / name).read_bytes()).hexdigest()}
        self.manifest = {'schema_version': 2, 'candidate_id': 'fixture',
                         'evidence': [self.entry('summary.json')],
                         'gates': [{'id': 'G1', 'status': 'passed', 'evidence': ['summary.json']}],
                         'raw_sources': [self.entry('raw.json')],
                         'artifacts': [self.entry('addon.teaa')]}

    def run_manifest(self, manifest=None, raw=None):
        path = self.base / 'manifest.json'
        path.write_text(raw if raw is not None else json.dumps(self.manifest if manifest is None else manifest))
        return subprocess.run([sys.executable, str(TOOL), str(path), '--root', str(self.root)],
                              text=True, capture_output=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})

    def rejects(self, fragment):
        result = self.run_manifest()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertNotIn('check: OK', result.stdout)

    def test_valid_current_manifest(self):
        result = self.run_manifest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('byte integrity only', result.stdout)

    def test_valid_legacy_format(self):
        self.manifest.pop('schema_version')
        self.manifest['raw_sources'] = {'candidate/raw.json': self.entry('raw.json')['sha256']}
        self.manifest['package'] = {'addon_archive': 'addon.teaa', 'archive_sha256': self.entry('addon.teaa')['sha256']}
        self.assertEqual(self.run_manifest().returncode, 0)

    def test_external_archive_is_explicit_and_verified(self):
        self.manifest['raw_sources'][0].update(path=str(self.base / 'raw.json'), base='absolute')
        self.assertEqual(self.run_manifest().returncode, 0)
        (self.base / 'raw.json').write_text('changed')
        self.rejects('hash mismatch')

    def test_original_dangling_counterexample(self):
        self.manifest['evidence'] = []
        self.manifest['gates'][0]['evidence'] = ['missing-and-undeclared.json']
        self.manifest['raw_sources'] = {'nonexistent.json': '0' * 64}
        self.rejects('undeclared or not hash-verified')

    def test_missing_required_and_unknown_fields(self):
        original = copy.deepcopy(self.manifest)
        for target, mutation in [('root', 'missing'), ('root', 'unknown'), ('evidence', 'unknown'), ('gate', 'missing')]:
            with self.subTest(target=target, mutation=mutation):
                self.manifest = copy.deepcopy(original)
                obj = self.manifest if target == 'root' else self.manifest['evidence' if target == 'evidence' else 'gates'][0]
                if mutation == 'unknown':
                    obj['typo'] = True
                else:
                    obj.pop('evidence')
                self.rejects('keys')

    def test_invalid_container_types(self):
        original = copy.deepcopy(self.manifest)
        for key in ('evidence', 'gates', 'raw_sources', 'artifacts'):
            with self.subTest(key=key):
                self.manifest = copy.deepcopy(original)
                self.manifest[key] = False
                self.rejects('expected array')

    def test_duplicate_evidence_paths_and_ids(self):
        self.manifest['evidence'] *= 2
        self.rejects('duplicate path')
        self.manifest['evidence'] = [{**self.entry('summary.json'), 'id': 'same'},
                                     {**self.entry('raw.json'), 'id': 'same'}]
        self.rejects('duplicate id')

    def test_resolved_path_alias_duplicate(self):
        self.manifest['evidence'].append({**self.entry('summary.json'), 'path': './summary.json'})
        self.rejects('duplicate resolved path')

    def test_duplicate_gate_id_and_reference(self):
        self.manifest['gates'] *= 2
        self.rejects('duplicate gate id')
        self.manifest['gates'] = [self.manifest['gates'][0]]
        self.manifest['gates'][0]['evidence'] *= 2
        self.rejects('duplicate evidence reference')

    def test_file_and_hash_failures_for_every_kind(self):
        original = copy.deepcopy(self.manifest)
        for group in ('evidence', 'raw_sources', 'artifacts'):
            for mutation in ('missing', 'hash', 'omitted_hash', 'bad_hash'):
                with self.subTest(group=group, mutation=mutation):
                    self.manifest = copy.deepcopy(original)
                    entry = self.manifest[group][0]
                    if mutation == 'missing':
                        entry['path'] = 'absent'
                    elif mutation == 'hash':
                        entry['sha256'] = '0' * 64
                    elif mutation == 'omitted_hash':
                        del entry['sha256']
                    else:
                        entry['sha256'] = 42
                    self.rejects({'missing': 'missing file', 'hash': 'hash mismatch',
                                  'omitted_hash': 'missing keys', 'bad_hash': 'SHA-256'}[mutation])

    def test_unverifiable_legacy_package_does_not_pass(self):
        self.manifest['package'] = {'archive_sha256': 'a' * 64, 'addon_archive': None}
        self.rejects('unverifiable provenance')

    def test_legacy_package_hash_mismatch(self):
        self.manifest['package'] = {'addon_archive': 'addon.teaa', 'archive_sha256': '0' * 64}
        self.rejects('hash mismatch')

    def test_duplicates_in_raw_and_artifacts(self):
        for group in ('raw_sources', 'artifacts'):
            self.manifest[group] *= 2
            self.rejects('duplicate path')

    def test_non_passed_gate_dangling_refs_also_fail(self):
        self.manifest['gates'][0].update(status='partial', evidence=['unknown'])
        self.rejects('undeclared or not hash-verified')

    def test_empty_passed_gate_invalid_status_and_ref_types(self):
        for status, refs, message in [('passed', [], 'passed without evidence'),
                                      ('PASS', [], 'invalid status'),
                                      ('passed', [True], 'invalid evidence reference'),
                                      ([], [], 'invalid status')]:
            with self.subTest(status=status, refs=refs):
                self.manifest['gates'][0].update(status=status, evidence=refs)
                self.rejects(message)

    def test_malformed_json_and_duplicate_keys(self):
        for raw in ('{', '{"evidence": [], "evidence": [], "gates": []}', 'null', '[]'):
            with self.subTest(raw=raw):
                result = self.run_manifest(raw=raw)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn('Traceback', result.stderr)

    def test_bad_scope_or_escape(self):
        for patch in ({'base': 'url'}, {'path': '../raw.json'}, {'path': '/tmp/unknown'},
                      {'base': 'absolute', 'path': 'relative'}):
            with self.subTest(patch=patch):
                self.manifest['raw_sources'] = [{**self.entry('raw.json'), **patch}]
                self.assertEqual(self.run_manifest().returncode, 1)


if __name__ == '__main__':
    unittest.main()
