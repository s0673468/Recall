from pathlib import Path
import shutil
import subprocess
import unittest


class UpdateNoticeTests(unittest.TestCase):
    def test_waiting_worker_notice_behavior(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.fail("Node.js is required to validate the website update notice")
        test = Path(__file__).with_name("update_notice.test.cjs")
        result = subprocess.run(
            [node, "--test", str(test)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_notice_guides_a_deliberate_reopen_and_never_forces_an_update(self) -> None:
        root = Path(__file__).resolve().parents[2]
        shell = (root / "index.html").read_text(encoding="utf-8")
        notice = shell.split('<aside id="recall-update-notice"', 1)[1].split("</aside>", 1)[0]
        self.assertIn('hidden aria-label="Website update"', notice)
        self.assertIn("<details>", notice)
        self.assertIn("<summary>Update ready</summary>", notice)
        self.assertIn("close all Recall tabs and reopen", notice)
        self.assertIn("Do not clear browser data", notice)
        self.assertIn('aria-label="Dismiss update notice"', notice)


if __name__ == "__main__":
    unittest.main()
