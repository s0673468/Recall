"""Two fresh Android processes; one initial reset of the unique synthetic APK.
Raw logcat stays in memory. This driver never stops an AVD or production Recall.
"""
from __future__ import annotations
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import measure_android_cold_start as cold
import native_offline_receipt_contract as contract

PACKAGE = contract.PACKAGE
SENTINEL = 'RECALL_NATIVE_OFFLINE_JSON '
CHUNK_SENTINEL = 'RECALL_NATIVE_OFFLINE_CHUNK '
CHUNK_BYTES = 240
FRAME_MAX_BYTES = 8192
PACKET_MAX_BYTES = 512
FAILURES = {'fixture_build_required', 'synthetic_phase_failed'}
PHASES = {'fixture_guard', 'offline_recording', 'native_restore', 'fake_sync'}
ASSERTION_STAGES = {'empty_native_input','initial_load','online_ready','offline_refresh',
                    'offline_ready','rating','offline_sync','durable_one_rating',
                    'snapshot_readback','marker_write','cleanup'}


def require(ok, code):
    if not ok: raise contract.Refused(code)


def closed_frame_diagnostics(body, offset_chars):
    # Count private input in memory, then retain only bounded framing facts.
    size = len(body.encode('utf-8',errors='replace'))
    offset = len(body[:offset_chars].encode('utf-8',errors='replace'))
    limit = contract.FRAME_DIAGNOSTIC_LIMIT
    return contract.validate_frame_diagnostics({
        'byte_count':min(size,limit),'byte_count_capped':size>limit,
        'parse_offset':min(offset,limit),'parse_offset_capped':offset>limit,
        'object_prefix':body.lstrip().startswith('{'),
        'object_suffix':body.rstrip().endswith('}')})


def receipt_bodies(raw, *, allow_incomplete=False):
    """Decode only explicit v1 packets; never stitch unframed log fragments.

    Polling may observe a valid ordered prefix while the producer is printing.
    Each snapshot is checked from scratch; a missing tail must reach the existing
    phase deadline, never count as a receipt. Direct calls refuse incomplete data.
    """
    legacy = []
    packets = []
    for line in raw.splitlines():
        if SENTINEL in line:
            require(line.count(SENTINEL) == 1, 'fixture_frame_mixed_protocol')
            legacy.append(line.split(SENTINEL, 1)[1])
        if CHUNK_SENTINEL in line:
            require(line.count(CHUNK_SENTINEL) == 1, 'fixture_packet_invalid')
            packet = CHUNK_SENTINEL + line.split(CHUNK_SENTINEL, 1)[1]
            require(packet.isascii() and len(packet) <= PACKET_MAX_BYTES,
                    'fixture_packet_invalid')
            packets.append(packet[len(CHUNK_SENTINEL):])
    require(not (legacy and packets), 'fixture_frame_mixed_protocol')
    if not packets:
        return legacy
    frame = None
    chunks = []
    for body in packets:
        match = re.fullmatch(r'v1 ([0-9a-f]{64}) ([1-9][0-9]{0,3}) '
                             r'(0|[1-9][0-9]{0,1}) ([1-9][0-9]{0,1}) '
                             r'([A-Za-z0-9_-]+={0,2})', body)
        require(match is not None, 'fixture_packet_invalid')
        digest, size_text, index_text, count_text, encoded = match.groups()
        size, index, count = int(size_text), int(index_text), int(count_text)
        require(1 <= size <= FRAME_MAX_BYTES and
                count == (size + CHUNK_BYTES - 1) // CHUNK_BYTES and
                index < count, 'fixture_packet_metadata_invalid')
        current = (digest, size, count)
        if frame is None:
            frame = current
        require(current == frame and index == len(chunks),
                'fixture_packet_sequence_invalid')
        try:
            chunk = base64.b64decode(encoded, altchars=b'-_', validate=True)
        except (ValueError, binascii.Error):
            raise contract.Refused('fixture_packet_encoding_invalid') from None
        require(base64.urlsafe_b64encode(chunk).decode('ascii') == encoded,
                'fixture_packet_encoding_invalid')
        require(len(chunk) == min(CHUNK_BYTES, size - index * CHUNK_BYTES),
                'fixture_packet_length_invalid')
        chunks.append(chunk)
    if len(chunks) != frame[2]:
        if allow_incomplete:
            return []
        raise contract.Refused('fixture_frame_incomplete')
    data = b''.join(chunks)
    require(len(data) == frame[1] and hashlib.sha256(data).hexdigest() == frame[0],
            'fixture_frame_checksum_invalid')
    try:
        return [data.decode('utf-8')]
    except UnicodeDecodeError:
        raise contract.Refused('fixture_frame_utf8_invalid') from None


def closed_event(raw, expected_phase, pid, commit, *, allow_incomplete=False):
    events = []
    for body in receipt_bodies(raw, allow_incomplete=allow_incomplete):
        try: value = json.loads(body)
        except json.JSONDecodeError as error:
            refused = contract.Refused('fixture_json_invalid')
            refused.frame_diagnostics = closed_frame_diagnostics(body,error.pos)
            raise refused from None
        require(isinstance(value, dict) and value.get('schema') == contract.SCHEMA,
                'fixture_schema_invalid')
        require(type(value.get('pid')) is int and value['pid'] == pid and
                value.get('source_commit') == commit, 'fixture_process_identity_invalid')
        if value.get('phase') == 'failed':
            base = {'schema','phase','source_commit','pid','failure_code','failed_phase'}
            stage = value.get('failed_assertion_stage')
            require(set(value) in (base,base|{'failed_assertion_stage'}) and
                    ('failed_assertion_stage' not in value or
                     (value.get('failure_code') == 'synthetic_phase_failed' and
                      value.get('failed_phase') == 'offline_recording' and
                      type(stage) is str and stage in ASSERTION_STAGES)) and
                    value.get('failure_code') in FAILURES and value.get('failed_phase') in PHASES,
                    'fixture_failure_schema_invalid')
            # Fixed labels only. Never forward an exception/string from Android.
            error = contract.Refused('fixture_reported_failure')
            error.failure_code = value['failure_code']; error.failed_phase = value['failed_phase']
            error.failed_assertion_stage = stage
            raise error
        require(value.get('phase') == expected_phase, 'fixture_phase_invalid')
        events.append(value)
    require(len(events) <= 1, 'duplicate_fixture_receipt')
    return events[0] if events else None


def stop(serial):
    cold.adb(serial, 'shell','am','force-stop',PACKAGE)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not cold.adb(serial,'shell','pidof',PACKAGE).strip(): return
        time.sleep(.1)
    raise contract.Refused('previous_process_not_gone')


def phase(serial, activity, name, commit, timeout):
    launch = cold.adb(serial,'shell','am','start','-W','-n',PACKAGE+'/'+activity,timeout=35)
    cold.launch_metrics(launch)
    text = cold.adb(serial,'shell','pidof',PACKAGE).strip()
    require(re.fullmatch(r'[1-9][0-9]*',text) is not None, 'fresh_pid_missing')
    pid = int(text); deadline = time.monotonic() + timeout
    incomplete_frame = False
    while time.monotonic() < deadline:
        raw = cold.adb(serial,'logcat','-d','-v','epoch','--pid='+str(pid),'-s','flutter:I','*:S',
                       timeout=min(12,max(.1,deadline-time.monotonic())))
        value = closed_event(raw,name,pid,commit,allow_incomplete=True)
        incomplete_frame = incomplete_frame or (CHUNK_SENTINEL in raw and value is None)
        if value is not None: return value
        time.sleep(min(.25,max(0,deadline-time.monotonic())))
    raise contract.Refused('fixture_frame_incomplete' if incomplete_frame else 'fixture_phase_timeout')


def airplane_state(serial):
    text = cold.adb(serial,'shell','settings','get','global','airplane_mode_on').strip()
    require(text in {'0','1'}, 'airplane_state_invalid_or_unsupported')
    return int(text)


def set_airplane(serial, state):
    require(type(state) is int and state in (0,1), 'airplane_target_invalid')
    cold.adb(serial,'shell','cmd','connectivity','airplane-mode','enable' if state else 'disable')
    actual = airplane_state(serial)
    require(actual == state, 'airplane_state_change_not_observed')
    return actual


def run_owned(args, serial, activity):
    """The only mutation seam; regression tests inject a fully fake ADB."""
    installed = resets = 0
    original_state = None
    # Bind the receipt to the APK bytes present before installation.
    require(args.apk.is_file() and not args.apk.is_symlink(), 'regular_apk_required')
    apk_sha = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    try:
        original_state = airplane_state(serial)
        cold.adb(serial,'install','--no-streaming',str(args.apk),timeout=45); installed += 1
        stop(serial)
        require(cold.adb(serial,'shell','pm','clear',PACKAGE).strip() == 'Success',
                'initial_fixture_reset_failed'); resets += 1
        before_one = set_airplane(serial,1)
        one = phase(serial,activity,'offline_recorded',args.source_commit,args.phase_timeout)
        after_one = airplane_state(serial)
        require(after_one == 1, 'airplane_phase_one_state_changed')
        stop(serial)
        before_two = set_airplane(serial,0)
        two = phase(serial,activity,'restart_synced',args.source_commit,args.phase_timeout)
        after_two = airplane_state(serial)
        require(after_two == 0, 'airplane_phase_two_state_changed')
        require(hashlib.sha256(args.apk.read_bytes()).hexdigest() == apk_sha, 'apk_input_changed')
    finally:
        # CI action owns its ephemeral AVD cleanup, not this process. Restore
        # only the exact guarded AVD state, with no broadcasts/settings hacks.
        try:
            if original_state is not None:
                try: restored = set_airplane(serial,original_state)
                except Exception: raise contract.Refused('airplane_restore_failed') from None
        finally:
            cold.adb(serial,'shell','am','force-stop',PACKAGE)
    launch = {'schema':'recall-native-offline-launch/v2','source_commit':args.source_commit,
        'package':PACKAGE,'apk_sha256':apk_sha,
        'apk_install_count':installed,'initial_reset_count':resets,'restart_reset_count':0,
        'phase_one_pid':one['pid'],'phase_two_pid':two['pid'],'force_stop_before_restart':True,
        'phase_one_process_gone':True,'same_owned_avd':True,'raw_logs_saved':False,
        'os_airplane_original_state':original_state,'os_airplane_phase_one_before':before_one,
        'os_airplane_phase_one_after':after_one,'os_airplane_phase_two_before':before_two,
        'os_airplane_phase_two_after':after_two,'os_airplane_restored_state':restored,
        'os_airplane_phase_one_command_count':1,'os_airplane_phase_two_command_count':1,'os_airplane_restore_command_count':1}
    result = contract.validate(launch,one,two,args.source_commit)
    return {'launch':launch,'phase-one':one,'phase-two':two,'qualification':result}


def qualify_failure_output(args):
    # Called only after host, one owned emulator, source pin and APK-ID guards.
    temporary = Path(os.environ.get('RUNNER_TEMP','/missing')).resolve(strict=True)
    output = args.output.resolve(strict=False)
    require(temporary in output.parents, 'action_owned_output_required')
    require(not output.exists() and not output.is_symlink(), 'new_output_required')
    args.output = output
    args._qualified_failure_output = output


def retain_closed_failure(args, value):
    output = getattr(args,'_qualified_failure_output',None)
    if not isinstance(output,Path): return value
    allowed = {'schema','qualification_passed','closed_failure_code','raw_logs_printed',
               'failure_code','failed_phase','failed_assertion_stage','frame_diagnostics'}
    valid = (isinstance(value,dict) and set(value)<=allowed and
             value.get('schema')=='recall-native-offline-qualification/v2' and
             value.get('qualification_passed') is False and value.get('raw_logs_printed') is False and
             type(value.get('closed_failure_code')) is str and
             re.fullmatch(r'[a-z_]{1,80}',value['closed_failure_code']) is not None)
    if valid and ('failure_code' in value or 'failed_phase' in value):
        valid = (type(value.get('failure_code')) is str and value['failure_code'] in FAILURES and
                 type(value.get('failed_phase')) is str and value['failed_phase'] in PHASES)
    if valid and 'failed_assertion_stage' in value:
        valid = (value.get('failure_code')=='synthetic_phase_failed' and
                 value.get('failed_phase')=='offline_recording' and
                 type(value['failed_assertion_stage']) is str and
                 value['failed_assertion_stage'] in ASSERTION_STAGES)
    if valid and 'frame_diagnostics' in value:
        valid = value['closed_failure_code']=='fixture_json_invalid'
        try:contract.validate_frame_diagnostics(value['frame_diagnostics'])
        except contract.Refused:valid = False
    if not valid:
        return {'schema':'recall-native-offline-qualification/v2','qualification_passed':False,
                'closed_failure_code':'failure_artifact_payload_refused','raw_logs_printed':False,
                'failure_artifact_saved':False}
    result = dict(value);result['failure_artifact_saved'] = False
    created_file = None
    try:
        output.mkdir(mode=0o700,parents=True,exist_ok=False)
        target = output/'qualification.json'
        # Exclusive creation: never rewrite a prior original receipt.
        with target.open('x') as stream:
            created_file = target
            result['failure_artifact_saved'] = True
            json.dump(result,stream,sort_keys=True,indent=2);stream.write('\n')
        return result
    except OSError:
        result['failure_artifact_saved'] = False
        if created_file is not None:
            try:created_file.unlink()
            except OSError:pass
        return result


def run(args):
    cold.require_ci()
    require(15 <= args.phase_timeout <= 90 and re.fullmatch(r'[0-9a-f]{40}',args.source_commit),
            'bounded_source_pinned_run_required')
    require(Path('/dev/kvm').exists() and os.access('/dev/kvm',os.R_OK|os.W_OK), 'kvm_required')
    devices = subprocess.run(['adb','devices'],capture_output=True,text=True,timeout=12)
    require(devices.returncode == 0, 'adb_inventory_failed')
    connected = [line.split()[0] for line in devices.stdout.splitlines()[1:] if line.strip()]
    require(len(connected) == 1 and re.fullmatch(r'emulator-[0-9]+',connected[0]),
            'single_owned_emulator_required')
    serial = connected[0]
    require(cold.adb(serial,'shell','getprop','ro.kernel.qemu').strip() == '1' and
            cold.adb(serial,'shell','getprop','ro.product.cpu.abi').strip() == 'x86_64',
            'isolated_x64_avd_required')
    apk = args.apk.resolve(strict=True)
    require(apk.is_file() and not args.apk.is_symlink(), 'regular_apk_required')
    package, activity = cold.apk_identity(apk)
    require(package == PACKAGE, 'isolated_apk_identity_required')
    args.apk = apk
    qualify_failure_output(args)
    return run_owned(args,serial,activity)


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--apk',type=Path,required=True)
    parser.add_argument('--source-commit',required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--phase-timeout',type=int,default=60);args=parser.parse_args()
    try:
        require(not args.output.exists() and not args.output.is_symlink(), 'new_output_required')
        results=run(args)
        args.output.mkdir(mode=0o700,parents=True,exist_ok=False)
        for name,value in results.items():
            with (args.output/(name+'.json')).open('x') as stream:json.dump(value,stream,sort_keys=True,indent=2)
        print(json.dumps(results['qualification'],sort_keys=True));return 0
    except (contract.Refused,cold.Refused,OSError,ValueError,KeyError,TypeError,subprocess.TimeoutExpired) as error:
        result={'schema':'recall-native-offline-qualification/v2','qualification_passed':False,
                'closed_failure_code':error.code if isinstance(error,(contract.Refused,cold.Refused)) else 'input_or_tool_unavailable',
                'raw_logs_printed':False}
        if getattr(error,'failure_code',None) in FAILURES and getattr(error,'failed_phase',None) in PHASES:
            result.update(failure_code=error.failure_code,failed_phase=error.failed_phase)
            if (error.failed_phase == 'offline_recording' and
                    getattr(error,'failed_assertion_stage',None) in ASSERTION_STAGES):
                result['failed_assertion_stage'] = error.failed_assertion_stage
        if isinstance(error,(contract.Refused,cold.Refused)) and error.code == 'fixture_json_invalid':
            facts = getattr(error,'frame_diagnostics',None)
            if facts is not None:
                try:result['frame_diagnostics'] = contract.validate_frame_diagnostics(facts)
                except contract.Refused:
                    result['closed_failure_code'] = 'fixture_frame_diagnostics_invalid'
        result = retain_closed_failure(args,result)
        print(json.dumps(result,sort_keys=True));return 1

if __name__ == '__main__':sys.exit(main())
