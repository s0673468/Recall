#!/usr/bin/env python3
"""Exercise the real Android release policy in an unsigned CI/build checkout."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PROBE = """
gradle.projectsEvaluated {
    def app = gradle.rootProject.project(':app')
    app.tasks.register('probeReleaseStagingPolicy') {
        doLast {
            def release = app.extensions.getByName('android').buildTypes.getByName('release')
            if (release.debuggable || release.signingConfig != null) {
                throw new GradleException('Unsigned release must be non-debuggable with no signer')
            }
            println('RECALL_UNSIGNED_RELEASE_POLICY_OK')
        }
    }
}
"""


def main() -> None:
    # This gate belongs on an unprovisioned compute host/CI checkout. Never hide
    # or rewrite an existing signing configuration just to make a test pass.
    if (ROOT / 'android/key.properties').exists():
        raise SystemExit('Run the policy gate in a checkout without android/key.properties')
    environment = os.environ.copy()
    environment.pop('ORG_GRADLE_PROJECT_recallUnsignedRelease', None)
    cases = [
        ('default release refuses missing signing', None,
         'Release signing requires android/key.properties', False),
        ('explicit signed release refuses missing signing', 'false',
         'Release signing requires android/key.properties', False),
        ('malformed opt-in refuses configuration', 'yes',
         'recallUnsignedRelease must be true or false', False),
        ('unsigned release has no signer and is not debuggable', 'true',
         'RECALL_UNSIGNED_RELEASE_POLICY_OK', True),
    ]
    with tempfile.TemporaryDirectory(prefix='recall-release-policy-') as temporary:
        probe = Path(temporary) / 'probe.gradle'
        probe.write_text(PROBE)
        for label, value, expected, success in cases:
            command = [str(ROOT / 'android/gradlew'), '--no-daemon', '--max-workers=2',
                       '--console=plain', '-I', str(probe), ':app:probeReleaseStagingPolicy']
            if value is not None:
                command.append(f'-PrecallUnsignedRelease={value}')
            result = subprocess.run(command, cwd=ROOT / 'android', env=environment,
                                    capture_output=True, text=True, timeout=300)
            output = result.stdout + result.stderr
            if (result.returncode == 0) != success or expected not in output:
                raise SystemExit(f'FAILED: {label}\n{output[-8000:]}')
            print(f'PASS: {label}', flush=True)


if __name__ == '__main__':
    main()
