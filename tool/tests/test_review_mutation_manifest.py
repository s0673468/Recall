"""Scheduling probe selection uses synthetic commands without launching Flutter."""
from contextlib import nullcontext, redirect_stdout
from io import StringIO
from pathlib import Path
import importlib.util
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    'review_mutation_manifest', ROOT / 'tool/mutation_sweep_recall.py')
sweep = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sweep
spec.loader.exec_module(sweep)


class ReviewMutationManifestTest(unittest.TestCase):
    def test_new_scheduling_probes_stay_within_requested_sources_and_budget(self):
        probes = [m for m in sweep.MUTATIONS if m.group.endswith('_edges')]
        self.assertEqual({m.path for m in probes},
                         {sweep.ENGINE, sweep.API, sweep.CONTROLLER})
        self.assertLessEqual(len(probes) * 2, 150)
        for mutation in probes:
            self.assertTrue(all((ROOT / p).is_file()
                                for p in sweep.TESTS[mutation.group]))

    def test_before_omits_new_tests_and_after_runs_them_for_every_new_group(self):
        probes = {}
        for mutation in sweep.MUTATIONS:
            if mutation.group.endswith('_edges'):
                probes.setdefault(mutation.group, mutation)
        workspace = ROOT / '.dart_tool'
        workspace.mkdir(exist_ok=True)
        for phase in ('before', 'after'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory(dir=workspace) as directory:
                calls = []

                def run(command, log, timeout):
                    calls.append(command)
                    return {'status': 'survived' if log.name == 'baseline.log' else 'killed'}

                args = SimpleNamespace(phase=phase, batch=None, timeout=1,
                                       ids=[m.id for m in probes.values()])
                with patch.object(sweep, 'ROOT', Path(directory)), \
                        patch.object(sweep, 'run', side_effect=run), \
                        patch.object(sweep, 'planted', return_value=nullcontext()), \
                        redirect_stdout(StringIO()):
                    sweep.run_sweep(args)
                self.assertEqual(len(calls), len(probes) + 1)
                for command in calls:
                    tests = [arg for arg in command if arg.endswith('_test.dart')]
                    self.assertEqual(len(tests), len(set(tests)))
                    self.assertEqual(command.count(sweep.SCHEDULING_REGRESSIONS),
                                     1 if phase == 'after' else 0)
                    self.assertEqual(command.count('--concurrency=1'), 1)


if __name__ == '__main__':
    unittest.main()
