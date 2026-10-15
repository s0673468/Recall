"""Synthetic debug-emulator measurements; no normal Recall/device claim.

prepare copies a bounded technical tree and transforms only its application ID
and asset declarations. run requires a fresh GitHub-hosted isolated emulator.
Raw ADB/logcat output is consumed in memory and never emitted or saved.
"""
from __future__ import annotations

import argparse
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

PACKAGE = 'com.german.recall.syntheticbenchmark'
ORIGINAL_PACKAGE = 'com.german.health_anki_flutter'
BASE_GRADLE_SHA = '729f278b435614cb6c6060000a3cec7ab9ca1de31d42098a5b693921951beb5d'
BASE_PUBSPEC_SHA = '1d4ae9abc9fa98130bc0240f0f5a91a8069ca40da3685e9150114925938d448e'
SENTINEL = 'RECALL_ANDROID_BENCH_JSON '
SCHEMA = 'recall-synthetic-android/v1'
FIXTURE_FAILURE_CODES = {'fixture_build_required', 'synthetic_phase_failed'}
FIXTURE_FAILED_PHASES = {'first_frame', 'fixture_setup', 'deck_load', 'rating', 'dispose'}
TIMINGS = {'dart_main_first_frame', 'dart_main_root_ready', 'fixture_setup',
           'deck_load', 'rating_to_next', 'native_enqueue_ack'}


class Refused(Exception):
    def __init__(self, code: str, *, failure_code: str | None = None,
                 failed_phase: str | None = None):
        self.code = code
        self.failure_code = failure_code if failure_code in FIXTURE_FAILURE_CODES else None
        self.failed_phase = (failed_phase if self.failure_code == 'synthetic_phase_failed' and
                             failed_phase in FIXTURE_FAILED_PHASES else None)


def require(condition: bool, code: str) -> None:
    if not condition:
        raise Refused(code)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path: Path) -> bytes:
    require(stat.S_ISREG(path.lstat().st_mode) and not path.is_symlink(), 'nonregular_input')
    return path.read_bytes()


def require_ci() -> None:
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted' and
            sys.platform == 'linux', 'isolated_hosted_ci_required')


def isolated_gradle(data: bytes) -> bytes:
    require(sha(data) == BASE_GRADLE_SHA, 'gradle_source_pin_changed')
    text = data.decode('utf-8')
    pattern = r'(?m)^(\s*applicationId\s*=\s*")' + re.escape(ORIGINAL_PACKAGE) + r'("\s*)$'
    changed, count = re.subn(pattern, lambda match: match[1] + PACKAGE + match[2], text)
    require(count == 1 and changed.replace(PACKAGE, ORIGINAL_PACKAGE) == text,
            'application_id_transform_refused')
    return changed.encode()


def technical_assets_only(data: bytes) -> bytes:
    require(sha(data) == BASE_PUBSPEC_SHA, 'pubspec_source_pin_changed')
    # The exact approved base has one assets stanza, containing technical font
    # assets only. The fixture drops every asset stanza and re-adds this closed
    # font directory; no corpus/article/media path can enter its build manifest.
    lines = data.decode().splitlines(keepends=True)
    output: list[str] = []
    in_assets = False
    removed = 0
    for line in lines:
        if re.match(r'^  assets:\s*(?:#.*)?$', line.rstrip('\n')):
            require(not in_assets, 'asset_stanza_refused')
            in_assets = True
            removed += 1
            output.extend(['  assets:\n', '    - assets/fonts/\n'])
            continue
        if in_assets:
            if not line.strip() or line.lstrip().startswith('#') or line.startswith('    '):
                continue
            in_assets = False
        output.append(line)
    require(removed == 1, 'asset_stanza_refused')
    return ''.join(output).encode()


def permitted_source(relative: Path) -> bool:
    parts = relative.parts
    if not parts or any(part in {'.git', '.dart_tool', 'build', '.gradle', '.worktrees'} for part in parts):
        return False
    if relative.as_posix() in {'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', '.metadata', '.flutter-version'}:
        return True
    if parts[0] == 'lib' or parts[:2] == ('tool', 'fixtures'):
        return relative.suffix == '.dart'
    if parts[:2] == ('assets', 'fonts'):
        return relative.suffix.lower() in {'.ttf', '.otf'}
    if parts[0] == 'android':
        if relative.name in {'key.properties', 'local.properties'} or relative.suffix in {'.jks', '.keystore'}:
            return False
        return (relative.suffix in {'.kt', '.java', '.kts', '.gradle', '.xml', '.pro'} or
                relative.as_posix() in {'android/gradle.properties','android/gradle/wrapper/gradle-wrapper.properties'} or
                relative.as_posix() in {'android/gradlew', 'android/gradlew.bat',
                    'android/gradle/wrapper/gradle-wrapper.jar'} or
                ('res' in parts and any(part.startswith('mipmap') for part in parts) and
                 relative.stem == 'ic_launcher' and relative.suffix in {'.png', '.webp'}) or
                (len(parts) == 7 and parts[:5] == ('android', 'app', 'src', 'main', 'res') and
                 parts[5].startswith('drawable') and
                 relative.stem == 'ic_launcher_foreground_bitmap' and relative.suffix in {'.png', '.webp'}))
    return False


def prepare(args: argparse.Namespace) -> dict:
    require_ci()
    source = args.source.resolve(strict=True)
    destination = args.destination.absolute()
    temporary = Path(os.environ.get('RUNNER_TEMP', '/missing')).resolve(strict=True)
    require(temporary in destination.parents, 'owned_temporary_copy_required')
    require(not destination.exists() and not destination.is_symlink() and
            source != destination and source not in destination.parents, 'new_source_copy_required')
    require(re.fullmatch(r'[0-9a-f]{40}', args.source_commit) is not None, 'source_commit_required')
    original_gradle = regular_bytes(source / 'android/app/build.gradle.kts')
    original_pubspec = regular_bytes(source / 'pubspec.yaml')
    patched_gradle = isolated_gradle(original_gradle)
    patched_pubspec = technical_assets_only(original_pubspec)
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    copied = 0
    for root, directories, files in os.walk(source, followlinks=False):
        # Never traverse unrelated roots, signing stores, caches or data trees.
        relative_root = Path(root).relative_to(source)
        if not relative_root.parts:
            directories[:] = [name for name in directories if name in {'lib', 'android', 'tool', 'assets'}]
        elif relative_root.parts == ('tool',):
            directories[:] = [name for name in directories if name == 'fixtures']
        elif relative_root.parts == ('assets',):
            directories[:] = [name for name in directories if name == 'fonts']
        else:
            directories[:] = [name for name in directories if name not in
                              {'.git', '.dart_tool', 'build', '.gradle', '.worktrees'} and
                              not (Path(root) / name).is_symlink()]
        for name in files:
            path = Path(root) / name
            relative = path.relative_to(source)
            if not permitted_source(relative):
                continue
            data = regular_bytes(path)
            target = destination / relative
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with target.open('xb') as stream:
                stream.write(data)
            target.chmod(path.stat().st_mode & 0o777)
            copied += 1
    (destination / 'android/app/build.gradle.kts').write_bytes(patched_gradle)
    (destination / 'pubspec.yaml').write_bytes(patched_pubspec)
    require(regular_bytes(source / 'android/app/build.gradle.kts') == original_gradle and
            regular_bytes(source / 'pubspec.yaml') == original_pubspec, 'original_source_changed')
    require((destination / 'tool/fixtures/synthetic_android_main.dart').is_file() and
            (destination / 'tool/fixtures/synthetic_recall_flow.dart').is_file(), 'fixture_helper_missing')
    require(any((destination / 'assets/fonts').glob('*.ttf')) or
            any((destination / 'assets/fonts').glob('*.otf')), 'technical_fonts_missing')
    return {'schema': 'recall-synthetic-android-provenance/v1', 'source_commit': args.source_commit,
            'package': PACKAGE, 'original_package': ORIGINAL_PACKAGE, 'copied_technical_files': copied,
            'test_only_transform': True, 'normal_source_unchanged': True,
            'gradle_original_sha256': sha(original_gradle), 'gradle_fixture_sha256': sha(patched_gradle),
            'pubspec_original_sha256': sha(original_pubspec), 'pubspec_fixture_sha256': sha(patched_pubspec),
            'application_id_changes': 1, 'namespace_and_signing_policy_unchanged': True,
            'asset_scope': 'technical-fonts-only', 'actual_cards_articles_media_copied': False,
            'entrypoint_sha256': sha(regular_bytes(destination / 'tool/fixtures/synthetic_android_main.dart')),
            'flow_helper_sha256': sha(regular_bytes(destination / 'tool/fixtures/synthetic_recall_flow.dart'))}


def adb(serial: str, *arguments: str, timeout: float = 12) -> str:
    require(re.fullmatch(r'emulator-[0-9]+', serial) is not None, 'owned_emulator_required')
    try:
        result = subprocess.run(['adb', '-s', serial, *arguments], capture_output=True,
                                text=True, timeout=timeout, check=False)
    except (subprocess.TimeoutExpired, OSError):
        raise Refused('adb_unavailable_or_timeout') from None
    empty_owned_pid = (arguments == ('shell', 'pidof', PACKAGE) and
                       result.returncode == 1 and not result.stdout.strip())
    require(result.returncode == 0 or empty_owned_pid, 'adb_command_failed')
    return result.stdout


def epoch_us(text: str) -> int:
    return int(Decimal(text) * 1_000_000)


def log_event(line: str) -> tuple[int, dict] | None:
    if SENTINEL not in line:
        return None
    prefix, body = line.split(SENTINEL, 1)
    match = re.match(r'^\s*([0-9]+\.[0-9]+)\s', prefix)
    require(match is not None, 'epoch_log_format_missing')
    try:
        value = json.loads(body)
    except ValueError:
        raise Refused('fixture_json_invalid') from None
    require(isinstance(value, dict) and value.get('schema') == SCHEMA, 'fixture_schema_invalid')
    return epoch_us(match[1]), value


def closed_fixture_failure(value: dict, pid: int, commit: str) -> Refused:
    """Project only the fixture's fixed failure labels, never its raw event."""
    base = {'schema','phase','source_commit','build_mode','environment','pid','failure_code'}
    require(isinstance(value, dict) and set(value) in (base, base | {'failed_phase'}),
            'fixture_failure_schema_invalid')
    code = value.get('failure_code')
    phase = value.get('failed_phase')
    require(type(code) is str and code in FIXTURE_FAILURE_CODES and
            ((code == 'synthetic_phase_failed' and type(phase) is str and phase in FIXTURE_FAILED_PHASES) or
             (code == 'fixture_build_required' and 'failed_phase' not in value)),
            'fixture_failure_schema_invalid')
    source = value.get('source_commit')
    # Missing build defines deliberately emit the build guard before startup.
    # Such a failure may have an empty source pin; it never qualifies a sample.
    source_matches = source == commit or (code == 'fixture_build_required' and source == '')
    require(value.get('schema') == SCHEMA and value.get('phase') == 'failed' and
            type(value.get('pid')) is int and value['pid'] == pid and source_matches and
            value.get('build_mode') == 'debug' and
            value.get('environment') == 'isolated-android-emulator',
            'fixture_failure_identity_invalid')
    return Refused('fixture_reported_failure', failure_code=code, failed_phase=phase)


def process_start_us(text: str, pid: int) -> int:
    matching = []
    pattern = re.compile(r'\[\s*\d+,\s*' + str(pid) + r',\s*\d+,\s*' + re.escape(PACKAGE) + r'(?:,|\])')
    for line in text.splitlines():
        if pattern.search(line):
            stamp = re.match(r'^\s*([0-9]+\.[0-9]+)\s', line)
            require(stamp is not None, 'process_event_epoch_missing')
            matching.append(epoch_us(stamp[1]))
    require(len(matching) == 1, 'process_start_event_missing_or_ambiguous')
    return matching[0]


def launch_metrics(text: str) -> dict[str, int]:
    require(re.search(r'^Status:\s*ok\s*$', text, re.M) is not None, 'cold_launch_failed')
    values = {}
    for field in ('ThisTime', 'TotalTime', 'WaitTime'):
        match = re.search(r'^' + field + r':\s*([0-9]+)\s*$', text, re.M)
        if match:
            values[field] = int(match[1])
    require({'TotalTime', 'WaitTime'} <= values.keys(), 'launch_metrics_missing')
    return values


def validate_events(events: dict[str, tuple[int, dict]], pid: int, commit: str) -> dict:
    require(set(events) == {'first_frame', 'root_ready', 'done'}, 'fixture_phases_missing')
    for phase, (_, value) in events.items():
        require(value.get('phase') == phase and value.get('pid') == pid and
                value.get('source_commit') == commit and value.get('build_mode') == 'debug' and
                value.get('environment') == 'isolated-android-emulator', 'fixture_identity_invalid')
    done = events['done'][1]
    require(set(done) == {'schema','phase','source_commit','build_mode','environment','pid','timing_us','integrity'},
            'fixture_done_fields_invalid')
    timing = done['timing_us']; integrity = done['integrity']
    require(isinstance(integrity, dict), 'fixture_integrity_invalid')
    for phase in ('first_frame', 'root_ready'):
        require(set(events[phase][1]) == {'schema','phase','source_commit','build_mode','environment','pid','dart_main_elapsed_us'},
                'fixture_phase_fields_invalid')
    require(isinstance(timing, dict) and set(timing) == TIMINGS and
            all(type(value) is int and value >= 0 for value in timing.values()), 'fixture_timings_invalid')
    require(integrity == {'cards_loaded':20,'pending_after_rating':1,'next_card_id':2,
                         'http_requests':integrity.get('http_requests'),'native_preferences':True} and
            type(integrity.get('http_requests')) is int and integrity['http_requests'] > 0,
            'fixture_integrity_invalid')
    require(events['first_frame'][1].get('dart_main_elapsed_us') == timing['dart_main_first_frame'] and
            events['root_ready'][1].get('dart_main_elapsed_us') == timing['dart_main_root_ready'],
            'fixture_phase_timings_disagree')
    require(timing['dart_main_root_ready'] >= timing['dart_main_first_frame'], 'fixture_clock_order_invalid')
    return done


def apk_identity(apk: Path) -> tuple[str, str]:
    sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or '/missing')
    tools = sorted(sdk.glob('build-tools/*/aapt'))
    require(bool(tools), 'aapt_required')
    result = subprocess.run([str(tools[-1]), 'dump', 'badging', str(apk)],
                            capture_output=True, text=True, timeout=15)
    require(result.returncode == 0, 'apk_inspection_failed')
    package = re.search(r"^package: name='([^']+)'", result.stdout, re.M)
    activity = re.search(r"^launchable-activity: name='([^']+)'", result.stdout, re.M)
    require(package is not None and package[1] == PACKAGE and activity is not None,
            'isolated_apk_identity_required')
    require(re.fullmatch(r'[A-Za-z0-9_.]+', activity[1]) is not None, 'activity_identity_invalid')
    return package[1], activity[1]


def run(args: argparse.Namespace) -> dict:
    require_ci()
    require(args.samples == 3 and 15 <= args.sample_timeout <= 90, 'bounded_three_samples_required')
    require(Path('/dev/kvm').exists() and os.access('/dev/kvm', os.R_OK | os.W_OK), 'kvm_required')
    require(re.fullmatch(r'[0-9a-f]{40}', args.source_commit) is not None, 'source_commit_required')
    devices = subprocess.run(['adb', 'devices'], capture_output=True, text=True, timeout=12)
    require(devices.returncode == 0, 'adb_devices_failed')
    connected = re.findall(r'^(\S+)\s+device\s*$', devices.stdout, re.M)
    require(len(connected) == 1 and re.fullmatch(r'emulator-[0-9]+', connected[0]) is not None,
            'single_owned_emulator_required')
    serial = connected[0]
    require(adb(serial,'shell','getprop','ro.kernel.qemu').strip() == '1' and
            adb(serial,'shell','getprop','ro.product.cpu.abi').strip() == 'x86_64', 'isolated_x64_avd_required')
    package, activity = apk_identity(args.apk.resolve(strict=True))
    adb(serial, 'install', '--no-streaming', '-r', str(args.apk.resolve()), timeout=45)
    samples = []; pids = set()
    try:
        for sample in range(1, 4):
            adb(serial, 'shell', 'am', 'force-stop', package)
            require(not adb(serial, 'shell', 'pidof', package).strip(), 'old_process_not_stopped')
            require(adb(serial, 'shell', 'pm', 'clear', package).strip() == 'Success', 'fixture_preferences_reset_failed')
            start = time.monotonic_ns()
            launch = adb(serial,'shell','am','start','-W','-n',package+'/'+activity,timeout=35)
            pid_text = adb(serial,'shell','pidof',package).strip()
            require(re.fullmatch(r'[0-9]+',pid_text) is not None, 'fresh_pid_missing')
            pid = int(pid_text); require(pid not in pids, 'pid_not_fresh');pids.add(pid)
            events = {}; deadline = time.monotonic()+args.sample_timeout
            while time.monotonic() < deadline:
                raw = adb(serial,'logcat','-d','-v','epoch','--pid='+str(pid),'-s','flutter:I','*:S',
                          timeout=min(12,max(.1,deadline-time.monotonic())))
                for line in raw.splitlines():
                    parsed = log_event(line)
                    if parsed is None:continue
                    stamp,value = parsed;phase=value.get('phase')
                    if phase == 'failed':
                        raise closed_fixture_failure(value, pid, args.source_commit)
                    require(phase in {'first_frame','root_ready','done'}, 'fixture_phase_invalid')
                    if phase in events:require(events[phase] == parsed,'duplicate_fixture_phase')
                    events[phase] = parsed
                if 'done' in events:break
                time.sleep(min(.25,max(0,deadline-time.monotonic())))
            require('done' in events, 'fixture_done_timeout')
            done = validate_events(events,pid,args.source_commit)
            process_epoch = process_start_us(adb(serial,'logcat','-b','events','-d','-v','epoch','-s','am_proc_start:I','*:S'),pid)
            first = events['first_frame'][0]-process_epoch;ready = events['root_ready'][0]-process_epoch
            require(0 <= first <= ready, 'device_realtime_order_invalid')
            clocks = abs((ready-first)-(done['timing_us']['dart_main_root_ready']-done['timing_us']['dart_main_first_frame']))
            samples.append({'sample':sample,'pid':pid,'fresh_process':True,'fresh_fixture_preferences':True,
                'host_launch_to_done_us':(time.monotonic_ns()-start)//1000,
                'am_start_w_ms':launch_metrics(launch),'device_log_epoch_us':{'process_first_frame':first,'process_root_ready':ready},
                'device_log_timestamp_quantization_us':1000,'inter_event_clock_disagreement_us':clocks,
                'timing_us':done['timing_us'],'integrity':done['integrity']})
    finally:
        # The action owns AVD lifecycle cleanup. Never kill a host emulator or any
        # existing Recall package from this consumer.
        adb(serial,'shell','am','force-stop',PACKAGE)
    return {'schema': 'recall-synthetic-android-cold/v1','source_commit':args.source_commit,
            'build_mode':'debug','environment':'github-hosted-kvm-isolated-emulator',
            'package':PACKAGE,'sample_count':len(samples),'samples':samples,
            'clock_scope':{'process_frame':'android-logcat-realtime-epoch-proxy',
                           'phase_work':'dart-stopwatch-monotonic','launch_done':'host-monotonic',
                           'logging_delay_bounded':False},
            'normal_app_auth_provider_startup_covered':False,'release_or_personal_device_measurement':False}


def self_test() -> dict:
    assert launch_metrics('Status: ok\nTotalTime: 200\nWaitTime: 211\n') == {'TotalTime':200,'WaitTime':211}
    assert process_start_us('123.456 1 2 I am_proc_start: [0,55,10001,'+PACKAGE+',activity,x]\n',55) == 123456000
    assert log_event('123.457 55 55 I flutter: '+SENTINEL+'{"schema":"'+SCHEMA+'","phase":"done"}')[0] == 123457000
    assert not permitted_source(Path('assets/cards/private.json'))
    assert not permitted_source(Path('android/key.properties'))
    assert not permitted_source(Path('android/local.properties'))
    assert permitted_source(Path('assets/fonts/Outfit-Regular.ttf'))
    assert permitted_source(Path('android/app/src/main/AndroidManifest.xml'))
    assert permitted_source(Path('android/app/src/main/res/drawable-hdpi/ic_launcher_foreground_bitmap.png'))
    assert not permitted_source(Path('android/app/src/main/res/drawable-hdpi/private_article.png'))
    assert not permitted_source(Path('ios/Runner/Info.plist'))
    for call in [lambda:process_start_us('',55),lambda:launch_metrics('Status: error\n'),
                 lambda:log_event('not_epoch '+SENTINEL+'{}')]:
        try:call()
        except Refused:pass
        else:raise AssertionError('invalid input accepted')
    commit='a'*40;common={'schema':SCHEMA,'source_commit':commit,'pid':55,'build_mode':'debug','environment':'isolated-android-emulator'}
    timing={name:1 for name in TIMINGS};timing['dart_main_root_ready']=2
    events={'first_frame':(1,{**common,'phase':'first_frame','dart_main_elapsed_us':1}),
            'root_ready':(2,{**common,'phase':'root_ready','dart_main_elapsed_us':2}),
            'done':(3,{**common,'phase':'done','timing_us':timing,'integrity':
                {'cards_loaded':20,'pending_after_rating':1,'next_card_id':2,'http_requests':1,'native_preferences':True}})}
    assert validate_events(events,55,commit)['timing_us']==timing
    for bad in [54,56]:
        try:validate_events(events,bad,commit)
        except Refused:pass
        else:raise AssertionError('foreign PID accepted')
    mutated={**events,'done':(3,{**events['done'][1],'provider_payload':'forbidden'})}
    try:validate_events(mutated,55,commit)
    except Refused:pass
    else:raise AssertionError('unclosed result accepted')
    return {'self_test_checks':18,'sdk_or_adb_executed':False}


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare');p.add_argument('--source',type=Path,required=True);p.add_argument('--destination',type=Path,required=True)
    p.add_argument('--source-commit',required=True);p.add_argument('--output',type=Path,required=True)
    r = sub.add_parser('run');r.add_argument('--apk',type=Path,required=True);r.add_argument('--source-commit',required=True)
    r.add_argument('--samples',type=int,default=3);r.add_argument('--sample-timeout',type=int,default=60);r.add_argument('--output',type=Path,required=True)
    sub.add_parser('self-test')
    args=parser.parse_args()
    try:
        result=self_test() if args.command=='self-test' else prepare(args) if args.command=='prepare' else run(args)
        if args.command != 'self-test':
            args.output.parent.mkdir(parents=True,exist_ok=True)
            with args.output.open('x') as stream:json.dump(result,stream,sort_keys=True,indent=2);stream.write('\n')
        print(json.dumps(result,sort_keys=True));return 0
    except (Refused,OSError,ValueError,subprocess.TimeoutExpired):
        error=sys.exc_info()[1]
        result={'schema':'recall-synthetic-android-failure/v1','closed_failure_code':error.code if isinstance(error,Refused) else 'technical_prerequisite_failed',
                'raw_logs_printed':False,'normal_app_or_personal_data_changed':False}
        if isinstance(error, Refused) and error.failure_code is not None:
            result['failure_code'] = error.failure_code
            if error.failed_phase is not None:
                result['failed_phase'] = error.failed_phase
        if args.command != 'self-test' and not args.output.exists():
            args.output.parent.mkdir(parents=True,exist_ok=True)
            with args.output.open('x') as stream:json.dump(result,stream,sort_keys=True);stream.write('\n')
        print(json.dumps(result,sort_keys=True));return 1


if __name__ == '__main__':
    sys.exit(main())
