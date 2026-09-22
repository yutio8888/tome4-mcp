"""Mutation checks against copied production sinks; never edit the real tree."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools/check_boundary_rules.py'
spec = importlib.util.spec_from_file_location('boundary_rules', TOOL)
boundary = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = boundary
spec.loader.exec_module(boundary)


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ('mcp_bridge/Json.lua', 'mcp_bridge/Actions.lua',
                     'auto_combat/MovementAdapterFactory.lua', 'auto_combat/AutoCombatGuard.lua',
                     'auto_combat/MovementPlanner.lua', 'auto_combat/PolicySchema.lua'):
            dest = self.root / 'overload/mod' / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / 'overload/mod' / path, dest)
        # The public ingress is a deliberately small STRUCTURAL fixture, so
        # this test remains independent of the concurrent SYS-12 implementation.
        # Production --root always checks the actual Runtime/RequestValidation.
        for name in ('Runtime.lua', 'RequestValidation.lua'):
            shutil.copyfile(ROOT / 'tests/fixtures/boundary_rules' / name,
                            self.root / boundary.BRIDGE / name)

    def mutate(self, relative, before, after):
        path = self.root / relative
        source = path.read_text()
        self.assertEqual(source.count(before), 1, before)
        path.write_text(source.replace(before, after))

    def fails(self, label):
        errors = boundary.check(self.root)
        self.assertTrue(any(label in error for error in errors), errors)

    def test_registered_structures_pass(self):
        self.assertEqual(boundary.check(self.root), [])

    def test_missing_density_validation_cannot_hide_in_comment(self):
        statement = 'local denseOk,planCause=Factory.validateArray(plan.values,1)'
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', statement, '-- ' + statement)
        self.fails('A.guardStationary.denseOk')

    def test_string_with_validation_does_not_count(self):
        statement = 'local seqOk,seqLengthOrCause=Factory.validateArray(declared,1)'
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', statement, 'local decoy=[=[' + statement + ']=]')
        self.fails('A.guardStationary.seqOk')

    def test_each_historical_array_gate_fails_if_removed(self):
        mutations = [
            ('AutoCombatGuard.lua', 'local cells,denseCount=denseCells(candidates and candidates.cells)', 'A.expandComplete'),
            ('MovementPlanner.lua', 'local planOk,planLenOrCause=Factory.validateArray(plan,1)', 'A.M.planSequence'),
            ('PolicySchema.lua', 'local planCount,planCause=denseList(plan,1)', 'A.validateTargetPlan'),
        ]
        for name, line, label in mutations:
            with self.subTest(name=name):
                self.mutate(boundary.AUTO + name, line, '-- ' + line)
                self.fails(label)

    def test_early_length_and_ipairs_reads_fail(self):
        line = 'local denseOk,planCause=Factory.validateArray(plan.values,1)'
        for prefix in ('local n=#plan.values\n', 'for _,v in ipairs(plan.values) do end\n'):
            with self.subTest(prefix=prefix):
                self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', line, prefix + line)
                self.fails('before validation/rejection')
                self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', prefix + line, line)

    def test_guard_in_unrelated_branch_cannot_dominate_sink(self):
        line = 'local ok,maxKey=Json.denseArray(cells,0)\n    if not ok then return nil end'
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', line, 'if false then\n' + line + '\nend')
        self.fails('not dominated')

    def test_rejection_must_return(self):
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua',
                    'if not denseOk then\n            return disable(',
                    'if not denseOk then\n            disable(')
        self.fails('rejection does not return')

    def test_weakened_shared_density_validator_fails(self):
        self.mutate(boundary.BRIDGE + 'Json.lua',
                    "if maxKey ~= count then return false, 'hole' end", '')
        self.fails('A.density')

    def test_missing_raised_flag_fails_even_with_comment(self):
        self.mutate(boundary.AUTO + 'MovementAdapterFactory.lua',
                    'force_max_range=true,min_range=true,grid_exclude=true,filter=true,',
                    'force_max_range=true,min_range=true,filter=true, -- grid_exclude=true\n')
        self.fails('B.raised-registry')

    def test_missing_footprint_flag_fails(self):
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua',
                    "'stop_block','force_max_range','min_range','grid_exclude','filter',",
                    "'stop_block','force_max_range','min_range','filter',")
        self.fails('B.footprint-registry')

    def test_false_dropping_copy_and_missing_assignment_fail(self):
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', 'if flags[key]~=nil then', 'if flags[key] then')
        self.fails('B.copy')
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', 'raised[flag]=typ[flag]', 'raised[flag]=nil')
        self.fails('B.mixed-copy')

    def test_callback_skip_without_unknown_rejection_fails(self):
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua',
                    'local malformedField=M.malformedFunctionField(stationaryFlags)',
                    'local malformedField=nil')
        self.fails('B.stationary-unknown')

    def test_public_gate_and_density_are_required(self):
        self.mutate(boundary.BRIDGE + 'RequestValidation.lua', 'if not dense then return false,path end', '')
        self.fails('A.public-arrays')
        self.mutate(boundary.BRIDGE + 'Runtime.lua', 'if not valid then return fail(validationCode) end', '')
        self.fails('A.public-dispatch')

    def test_unified_runner_really_executes_failing_gate(self):
        (self.root / 'tools').mkdir()
        shutil.copyfile(TOOL, self.root / 'tools/check_boundary_rules.py')
        self.mutate(boundary.AUTO + 'AutoCombatGuard.lua', 'if flags[key]~=nil then', 'if flags[key] then')
        result = subprocess.run(['bash', str(ROOT / 'tests/run.sh')], text=True, capture_output=True,
                                env={**os.environ, 'TOME_MCP_ADDON_DIR': str(self.root),
                                     'TOME_MCP_PYTHON': sys.executable, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAIL B.copy', result.stdout)

    def test_cli_fails_and_cde_are_only_review(self):
        (self.root / boundary.BRIDGE / 'RequestValidation.lua').unlink()
        result = subprocess.run([sys.executable, str(TOOL), '--check', '--root', str(self.root)],
                                text=True, capture_output=True,
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for rule in 'CDE':
            self.assertIn('REVIEW ' + rule + ':', result.stdout)
            self.assertNotIn('PASS ' + rule, result.stdout)


if __name__ == '__main__':
    unittest.main()
