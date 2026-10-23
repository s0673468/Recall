"""C03 still removes the explicit tap instant from the refactored rating call."""

from pathlib import Path
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import mutation_sweep_recall as sweep


class ControllerTapClockMutationTests(unittest.TestCase):
    def test_c03_preserves_the_review_entry_and_retry_branches(self):
        mutation = next(m for m in sweep.MUTATIONS if m.id == 'C03')
        before = '''final entry = retry == null
    ? api.reviewEntry(
        card,
        engine.review(card, rating, now: reviewedAt),
        elapsedMs: elapsedMs,
      )
    : Map<String, dynamic>.from(retry.entry);
'''
        expected = before.replace('engine.review(card, rating, now: reviewedAt)',
                                  'engine.review(card, rating)')
        workspace = TOOL.parent / '.dart_tool'
        workspace.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=workspace) as temp:
            root = Path(temp)
            target = root / mutation.path
            target.parent.mkdir(parents=True)
            target.write_text(before)
            with sweep.planted(root, mutation):
                self.assertEqual(target.read_text(), expected)
            self.assertEqual(target.read_text(), before)


if __name__ == '__main__':
    unittest.main()
