from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest


BOOTSTRAP = Path(__file__).resolve().parents[2] / "flutter_bootstrap.js"


class FlutterBootstrapTests(unittest.TestCase):
    def test_existing_recall_worker_does_not_trigger_flutter_registration(self) -> None:
        template = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertEqual(template.count("{{flutter_js}}"), 1)
        self.assertEqual(template.count("{{flutter_build_config}}"), 1)
        # Render Flutter's template with a loader that reproduces the obsolete
        # worker branch, including the case where Recall already has a worker.
        rendered = template.replace(
            "{{flutter_js}}",
            "var calls = []; var registrations = []; var _flutter = {loader: {"
            "load: function(options) { calls.push(options || {});"
            "if (options && options.serviceWorkerSettings) {"
            "registrations.push('flutter_service_worker.js'); } }}};",
        ).replace(
            "{{flutter_build_config}}",
            "_flutter.buildConfig = {builds: [{mainJsPath: 'main.dart.js'}]};",
        )
        result = subprocess.run(
            ["node", "-e", rendered + "\nconsole.log(JSON.stringify({calls, registrations, config: _flutter.buildConfig}));"],
            check=True,
            capture_output=True,
            text=True,
        )
        state = json.loads(result.stdout)
        self.assertEqual(state["calls"], [{}])
        self.assertEqual(state["registrations"], [])
        self.assertEqual(state["config"]["builds"][0]["mainJsPath"], "main.dart.js")


if __name__ == "__main__":
    unittest.main()
