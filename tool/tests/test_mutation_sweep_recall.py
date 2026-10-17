"""Safety checks for the bounded, synthetic-only mutation runner."""
import importlib.util
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mutation_sweep_recall', ROOT / 'tool/mutation_sweep_recall.py')
sweep = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sweep
spec.loader.exec_module(sweep)


class MutationSweepTest(unittest.TestCase):
    def setUp(self):
        workspace = ROOT / '.dart_tool'
        workspace.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=workspace)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / 'source.dart'
        self.original = b'count + 1;\r\n'
        self.source.write_bytes(self.original)
        self.mutation = sweep.Mutation('example', 'schedule', 'source.dart', 'count + 1', 'count - 1')

    def test_restores_exact_bytes_on_success_failure_and_interrupt(self):
        for error in (None, RuntimeError, KeyboardInterrupt):
            with self.subTest(error=error):
                def action():
                    with sweep.planted(self.root, self.mutation):
                        self.assertIn(b'count - 1', self.source.read_bytes())
                        if error:
                            raise error()
                if error:
                    with self.assertRaises(error):
                        action()
                else:
                    action()
                self.assertEqual(self.source.read_bytes(), self.original)

    def test_missing_or_ambiguous_match_never_modifies_source(self):
        for source in (b'no match', b'count + 1; count + 1;'):
            self.source.write_bytes(source)
            with self.assertRaises(ValueError):
                with sweep.planted(self.root, self.mutation):
                    self.fail('must not run')
            self.assertEqual(self.source.read_bytes(), source)

    def test_termination_unwinds_and_restores_planted_source(self):
        code = '''
import os
from pathlib import Path
import signal
import sys
sys.path.insert(0, sys.argv[1])
import mutation_sweep_recall as sweep
signal.signal(signal.SIGTERM, sweep.interrupt)
mutation = sweep.Mutation('example', 'schedule', 'source.dart', 'count + 1', 'count - 1')
with sweep.planted(Path(sys.argv[2]), mutation):
    os.kill(os.getpid(), signal.SIGTERM)
'''
        result = subprocess.run([sys.executable, '-c', code, str(ROOT / 'tool'), str(self.root)],
                                capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_test_failure_is_distinguished_from_compilation_and_timeout(self):
        cases = [
            ("print('All tests passed!')", 5, 'survived'),
            ("print('[E] Expected: 1 Actual: 2'); exit(1)", 5, 'killed'),
            ("print('Error compiling [E]'); exit(1)", 5, 'invalid'),
            ("print('[E] Expected: 1 Actual: 2 Failed to load'); exit(1)", 5, 'invalid'),
            ('import time; time.sleep(10)', 0.05, 'timeout'),
        ]
        for code, timeout, status in cases:
            with self.subTest(status=status):
                result = sweep.run([sys.executable, '-c', code], self.root / 'run.log', timeout, self.root)
                self.assertEqual(result['status'], status)

    def test_manifest_has_unique_ids_and_exact_current_source_matches(self):
        self.assertEqual(len(sweep.MUTATIONS), len({m.id for m in sweep.MUTATIONS}))
        for mutation in sweep.MUTATIONS:
            with self.subTest(id=mutation.id):
                self.assertIn(mutation.group, sweep.TESTS)
                self.assertNotEqual(mutation.before, mutation.after)
                self.assertEqual((ROOT / mutation.path).read_text().count(mutation.before), 1)


if __name__ == '__main__':
    unittest.main()
