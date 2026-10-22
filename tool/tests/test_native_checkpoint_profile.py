"""Keep the compiled native-cost guards and workflow on one exact profile."""

from pathlib import Path
import re
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
ROOT = TOOL.parent
sys.path.insert(0, str(TOOL))
import native_checkpoint_contract as contract
import prepare_native_checkpoint_cost as prepare


class NativeCheckpointProfileTests(unittest.TestCase):
    def test_compiled_fixture_guards_match_receipt_contract(self):
        fixture = (ROOT / prepare.ENTRY).read_text()
        for name, expected in {
            '_baselineControllerSha': contract.BASE_CONTROLLER,
            '_checkpointControllerSha': contract.CHECKPOINT_CONTROLLER,
            '_checkpointPatchSha': contract.PATCH_SHA,
            '_storeBlob': contract.STORE_BLOB,
        }.items():
            with self.subTest(name=name):
                match = re.search(rf"const {name}\s*=\s*'([^']+)';", fixture)
                self.assertIsNotNone(match)
                self.assertEqual(match[1], expected)
        base_guard = re.search(r"_require\(_baseCommit == '([^']+)'\);", fixture)
        self.assertIsNotNone(base_guard)
        self.assertEqual(base_guard[1], contract.SOURCE)

    def test_workflow_builds_and_prepares_the_same_profile(self):
        workflow = (ROOT / '.github/workflows/recall-synthetic-native-cost.yml').read_text()
        for variant, controller, patch in [
            ('baseline', contract.BASE_CONTROLLER, 'none'),
            ('checkpoint', contract.CHECKPOINT_CONTROLLER, contract.PATCH_SHA),
        ]:
            with self.subTest(variant=variant):
                build = re.search(
                    rf'(?ms)^      - name: Build isolated {variant} debug APK\n'
                    r'(.*?)(?=^      - name:)', workflow,
                )
                self.assertIsNotNone(build)
                defines = dict(re.findall(r'--dart-define=(\w+)=([^\s]+)', build[1]))
                self.assertEqual(defines, {
                    'RECALL_SYNTHETIC_NATIVE_OUTBOX_COST': 'true',
                    'RECALL_SOURCE_COMMIT': '"$GITHUB_SHA"',
                    'RECALL_BASE_COMMIT': contract.SOURCE,
                    'RECALL_VARIANT': variant,
                    'RECALL_CONTROLLER_SHA256': controller,
                    'RECALL_PATCH_SHA256': patch,
                    'RECALL_FIXTURE_SHA256': contract.FIXTURE_SHA,
                })
        self.assertEqual(
            re.findall(r'--fixture-sha ([0-9a-f]+)', workflow),
            [contract.FIXTURE_SHA, contract.FIXTURE_SHA],
        )


if __name__ == '__main__':
    unittest.main()
