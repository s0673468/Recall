"""Security boundaries for the optional hosted native-cost workflow."""

from pathlib import Path
import hashlib
import re
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import native_checkpoint_contract as contract


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/recall-synthetic-native-cost.yml"


def entries_under(text: str, heading: str) -> list[str]:
    match = re.search(rf"(?m)^\s{{10}}{re.escape(heading)}:\s*\|\s*$", text)
    if not match:
        raise AssertionError(f"missing {heading} block")
    tail = text[match.end():]
    entries = []
    for line in tail.splitlines():
        if line and not line.startswith(" " * 12):
            break
        if line.strip():
            entries.append(line.strip())
    return entries


class NativeCostWorkflowPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = WORKFLOW.read_text()

    def test_optional_triggers_stay_on_harness_and_shared_test_tools(self) -> None:
        blocks = re.findall(r"(?ms)^  (?:push|pull_request):\n(.*?)(?=^  \w|^permissions:)", self.text)
        self.assertEqual(len(blocks), 2)
        for block in blocks:
            self.assertIn("branches: [main]", block)
            paths = re.findall(r"(?m)^      - ([^\n]+)$", block)
            self.assertTrue(paths)
            self.assertTrue(all(path.startswith(("tool/", "test/", ".github/workflows/")) for path in paths))
            self.assertTrue(all(not path.startswith(("lib/", "android/", "pubspec")) for path in paths))

    def test_host_permission_and_retained_files_are_closed(self) -> None:
        text = self.text
        self.assertRegex(text, r"(?m)^permissions:\n  contents: read$")
        self.assertRegex(text, r"(?m)^    runs-on: ubuntu-latest$")
        self.assertNotIn("self-hosted", text)
        self.assertNotIn("secrets.", text)
        self.assertRegex(text, r"(?m)^    timeout-minutes: 40$")
        self.assertRegex(text, r"(?m)^  cancel-in-progress: false$")
        self.assertRegex(text, r"(?m)^          persist-credentials: false$")
        self.assertRegex(text, r"(?m)^          retention-days: 2$")
        self.assertEqual(
            entries_under(text, "path"),
            [
                "${{ env.COST_RESULTS }}/base-provenance.json",
                "${{ env.COST_RESULTS }}/checkpoint-provenance.json",
                "${{ env.COST_RESULTS }}/native/comparison.json",
            ],
        )

    def test_workflow_and_dart_entry_bind_the_same_qualified_source(self) -> None:
        entry = (TOOL / 'fixtures/synthetic_native_outbox_cost_main.dart').read_bytes()
        self.assertEqual(hashlib.sha256(entry).hexdigest(), contract.FIXTURE_SHA)
        self.assertEqual(
            re.findall(r'--fixture-sha ([0-9a-f]{64})', self.text),
            [contract.FIXTURE_SHA] * 2,
        )
        self.assertEqual(
            re.findall(r'--dart-define=RECALL_FIXTURE_SHA256=([0-9a-f]{64})', self.text),
            [contract.FIXTURE_SHA] * 2,
        )
        self.assertEqual(
            re.findall(r'--dart-define=RECALL_BASE_COMMIT=([0-9a-f]{40})', self.text),
            [contract.SOURCE] * 2,
        )
        self.assertEqual(
            re.findall(r'--dart-define=RECALL_CONTROLLER_SHA256=([0-9a-f]{64})', self.text),
            [contract.BASE_CONTROLLER, contract.CHECKPOINT_CONTROLLER],
        )
        self.assertEqual(
            re.findall(r'--dart-define=RECALL_PATCH_SHA256=(none|[0-9a-f]{64})', self.text),
            ['none', contract.PATCH_SHA],
        )
        self.assertEqual(
            hashlib.sha256((TOOL / 'fixtures/checkpoint-drain-only.patch').read_bytes()).hexdigest(),
            contract.PATCH_SHA,
        )
        dart = entry.decode()
        self.assertIn("_require(_baseCommit == '" + contract.SOURCE + "');", dart)
        self.assertIn("const _storeBlob = '" + contract.STORE_BLOB + "';", dart)

    def test_fail_closed_order_before_disposable_emulator(self) -> None:
        text = self.text
        operations = (
            "Qualify mocked contracts before compilation",
            "Prepare two fresh pinned technical copies",
            "Build isolated baseline debug APK",
            "Build isolated checkpoint debug APK",
            "Stop only these two disposable Gradle daemons before emulator",
            "Require hosted KVM",
            "Four guarded process launches on one disposable AVD",
        )
        offsets = [text.index(operation) for operation in operations]
        self.assertEqual(offsets, sorted(offsets))
        self.assertEqual(text.count("reactivecircus/android-emulator-runner@"), 1)
        self.assertRegex(text, r"(?m)^          force-avd-creation: true$")
        self.assertRegex(text, r"(?m)^          arch: x86_64$")


if __name__ == "__main__":
    unittest.main()
