"""Process-level ownership checks using only synthetic mutation sources."""
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
ORIGINAL = b'count + 1;\r\nlapses + 1;\r\n'
WORKER = '''
from pathlib import Path
import signal
import sys
sys.path.insert(0, sys.argv[1])
import mutation_sweep_recall as sweep
sweep.ROOT = root = Path(sys.argv[2])
gate, outcome = sys.argv[3:5]
sweep.MUTATIONS = [
    sweep.Mutation('S01', 'schedule', 'source.dart', 'count + 1', 'count'),
    sweep.Mutation('S02', 'schedule', 'source.dart', 'lapses + 1', 'lapses'),
]
sweep.TESTS = {'schedule': ['synthetic_test.dart']}
def run(command, log, timeout):
    log.write_bytes((root / 'source.dart').read_bytes())
    stage = 'baseline' if log.name == 'baseline.log' else 'mutation'
    if stage == gate:
        (root / 'ready').touch()
        sys.stdin.readline()
    if stage == 'mutation' and outcome == 'exception':
        raise RuntimeError('synthetic test runner failure')
    status = 'invalid' if stage == outcome else 'survived'
    return {'status': status}
sweep.run = run
signal.signal(signal.SIGTERM, sweep.interrupt)
sys.argv = ['mutation_sweep_recall.py'] + sys.argv[5:]
sweep.main()
'''


class MutationSweepLockTest(unittest.TestCase):
    def setUp(self):
        workspace = ROOT / '.dart_tool'
        workspace.mkdir(exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=workspace)
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / 'source.dart'
        self.source.write_bytes(ORIGINAL)

    def worker(self, *, gate='none', outcome='success', phase='after',
               mutation='S01', batch=False):
        args = [sys.executable, '-c', WORKER, str(ROOT / 'tool'),
                str(self.root), gate, outcome, '--phase', phase, '--ids', mutation]
        if batch:
            args += ['--batch', 'replay']
        process = subprocess.Popen(args, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_worker, process)
        return process

    @staticmethod
    def stop_worker(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)

    def wait_ready(self, process):
        deadline = time.monotonic() + 5
        while not (self.root / 'ready').exists():
            if process.poll() is not None:
                self.fail(f'Worker exited before readiness: {process.communicate()}')
            if time.monotonic() >= deadline:
                self.fail('Worker did not reach the requested stage')
            time.sleep(0.01)

    def assert_competitor_rejected(self, owner, **kwargs):
        before = self.source.read_bytes()
        output = self.root / '.dart_tool/mutation-sweep'
        snapshots = {p.relative_to(output): p.read_bytes()
                     for p in output.rglob('*') if p.is_file()}
        competitor = self.worker(mutation='S02', **kwargs)
        _, errors = competitor.communicate(timeout=5)
        self.assertNotEqual(competitor.returncode, 0)
        self.assertIn(b'Another mutation sweep', errors)
        self.assertIsNone(owner.poll())
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual({p.relative_to(output): p.read_bytes()
                          for p in output.rglob('*') if p.is_file()}, snapshots)

    def test_owner_excludes_competitors_during_baseline(self):
        owner = self.worker(gate='baseline')
        self.wait_ready(owner)
        self.assertEqual(self.source.read_bytes(), ORIGINAL)
        self.assert_competitor_rejected(owner)
        owner.communicate(input=b'continue\n', timeout=5)
        self.assertEqual(owner.returncode, 0)
        self.assertEqual(self.source.read_bytes(), ORIGINAL)

    def test_owner_excludes_other_phases_and_batches_until_restored(self):
        owner = self.worker(gate='mutation')
        self.wait_ready(owner)
        self.assertNotEqual(self.source.read_bytes(), ORIGINAL)
        self.assert_competitor_rejected(owner, phase='before', batch=True)
        owner.communicate(input=b'continue\n', timeout=5)
        self.assertEqual(owner.returncode, 0)
        self.assertEqual(self.source.read_bytes(), ORIGINAL)
        successor = self.worker(phase='before', mutation='S02', batch=True)
        successor.communicate(timeout=5)
        self.assertEqual(successor.returncode, 0)
        baseline = self.root / '.dart_tool/mutation-sweep/before/replay/baseline.log'
        self.assertEqual(baseline.read_bytes(), ORIGINAL)
        self.assertEqual(self.source.read_bytes(), ORIGINAL)

    def test_termination_restores_source_and_releases_ownership(self):
        owner = self.worker(gate='mutation')
        self.wait_ready(owner)
        owner.terminate()
        owner.communicate(timeout=5)
        self.assertNotEqual(owner.returncode, 0)
        self.assertEqual(self.source.read_bytes(), ORIGINAL)
        successor = self.worker()
        successor.communicate(timeout=5)
        self.assertEqual(successor.returncode, 0)
        self.assertEqual(self.source.read_bytes(), ORIGINAL)

    def test_completion_and_failures_release_ownership(self):
        for outcome in ('success', 'baseline', 'mutation', 'exception'):
            with self.subTest(outcome=outcome):
                owner = self.worker(outcome=outcome)
                owner.communicate(timeout=5)
                self.assertEqual(owner.returncode == 0, outcome == 'success')
                self.assertEqual(self.source.read_bytes(), ORIGINAL)
                successor = self.worker()
                successor.communicate(timeout=5)
                self.assertEqual(successor.returncode, 0)
                self.assertEqual(self.source.read_bytes(), ORIGINAL)


if __name__ == '__main__':
    unittest.main()
