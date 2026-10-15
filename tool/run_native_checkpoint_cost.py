"""Four invented native-ACK cases in one action-owned AVD; raw logs stay private."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import measure_android_cold_start as cold
import run_synthetic_native_offline_restart as framing
import native_checkpoint_contract as contract


def read_provenance(path,variant,source_commit):
    try:value=json.loads(cold.regular_bytes(path))
    except (ValueError,UnicodeError):raise contract.Refused('source_provenance_invalid') from None
    return contract.validate_provenance(value,variant,source_commit)


def event(raw,variant,count,pid,fixture_sha,*,allow_incomplete=False,source_commit=contract.SOURCE):
    # Exact delivered114 decoder, including its order/length/hash/encoding limits.
    bodies=framing.receipt_bodies(raw,allow_incomplete=allow_incomplete)
    contract.require(len(bodies)<=1,'duplicate_fixture_receipt')
    if not bodies:return None
    try:value=json.loads(bodies[0])
    except ValueError:raise contract.Refused('fixture_json_invalid') from None
    return contract.validate(value,variant=variant,count=count,pid=pid,fixture_sha=fixture_sha,source_commit=source_commit)


def sample(serial,activity,variant,count,fixture_sha,timeout,source_commit):
    framing.stop(serial)
    contract.require(cold.adb(serial,'shell','pm','clear',contract.PACKAGE).strip()=='Success','fixture_reset_failed')
    launch=cold.adb(serial,'shell','am','start','-W','-n',contract.PACKAGE+'/'+activity,
                    '--es','route','/recall-outbox-cost/'+str(count),timeout=35)
    metrics=cold.launch_metrics(launch)
    text=cold.adb(serial,'shell','pidof',contract.PACKAGE).strip()
    contract.require(re.fullmatch('[1-9][0-9]*',text) is not None,'fresh_pid_missing')
    pid=int(text);deadline=time.monotonic()+timeout;incomplete=False
    while time.monotonic()<deadline:
        raw=cold.adb(serial,'logcat','-d','-v','epoch','--pid='+str(pid),'-s','flutter:I','*:S',timeout=min(12,max(.1,deadline-time.monotonic())))
        value=event(raw,variant,count,pid,fixture_sha,allow_incomplete=True,source_commit=source_commit)
        incomplete=incomplete or (framing.CHUNK_SENTINEL in raw and value is None)
        if value is not None:return {'variant':variant,'pending_seeded':count,'pid':pid,'initial_reset_count':1,'launch_ms':metrics,'receipt':value}
        time.sleep(min(.25,max(0,deadline-time.monotonic())))
    raise contract.Refused('fixture_frame_incomplete' if incomplete else 'fixture_phase_timeout')


def owned_run(args,serial,artifacts):
    samples=[];pids=set();original=None;installed=0
    try:
        original=framing.airplane_state(serial)
        if original!=0:framing.set_airplane(serial,0)
        for variant in ['baseline','checkpoint']:
            artifact=artifacts[variant]
            framing.stop(serial)
            cold.adb(serial,'install','--no-streaming','-r',str(artifact['apk']),timeout=45);installed+=1
            for count in [128,512]:
                value=sample(serial,artifact['activity'],variant,count,artifact['provenance']['fixture_sha256'],args.phase_timeout,args.source_commit)
                contract.require(value['pid'] not in pids,'pid_not_fresh');pids.add(value['pid']);samples.append(value)
                contract.require(framing.airplane_state(serial)==0,'emulator_airplane_state_changed')
            contract.require(cold.sha(cold.regular_bytes(artifact['apk']))==artifact['apk_sha256'],'apk_input_changed')
    finally:
        try:
            if original is not None and framing.airplane_state(serial)!=original:
                framing.set_airplane(serial,original)
        finally:cold.adb(serial,'shell','am','force-stop',contract.PACKAGE)
    contract.require(len(samples)==4 and len(pids)==4 and installed==2,'four_case_proof_invalid')
    return {'schema':'recall-native-outbox-comparison/v1','qualification_passed':True,'source_commit':args.source_commit,'baseline_source_commit':contract.SOURCE,
        'environment':'github-hosted-isolated-android-emulator','build_mode':'debug','package':contract.PACKAGE,
        'same_owned_avd':True,'apk_install_count':installed,'initial_reset_count':4,'fresh_pid_count':4,
        'os_airplane_original_state':original,'os_airplane_restored_state':original,
        'raw_logs_saved':False,'physical_device_tested':False,'real_provider_contacted':False,
        'samples':samples,'artifacts':{variant:{'apk_sha256':value['apk_sha256'],'source_provenance_sha256':value['provenance_sha256'],'technical_source_manifest_sha256':value['provenance']['technical_source_manifest_sha256'],'controller_sha256':value['provenance']['controller_sha256'],'fixture_sha256':value['provenance']['fixture_sha256']} for variant,value in artifacts.items()}}


def run(args):
    cold.require_ci()
    contract.require(re.fullmatch('[0-9a-f]{40}',args.source_commit) is not None and 15<=args.phase_timeout<=90,'bounded_pinned_run_required')
    contract.require(Path('/dev/kvm').exists() and os.access('/dev/kvm',os.R_OK|os.W_OK),'kvm_required')
    temporary=Path(os.environ.get('RUNNER_TEMP','/missing')).resolve(strict=True);output=args.output.resolve(strict=False)
    contract.require(temporary in output.parents and not output.exists() and not output.is_symlink(),'new_owned_output_required')
    devices=subprocess.run(['adb','devices'],capture_output=True,text=True,timeout=12)
    contract.require(devices.returncode==0,'adb_inventory_failed')
    connected=[x.split()[0] for x in devices.stdout.splitlines()[1:] if x.strip()]
    contract.require(len(connected)==1 and re.fullmatch('emulator-[0-9]+',connected[0]) is not None,'single_owned_emulator_required')
    serial=connected[0]
    contract.require(cold.adb(serial,'shell','getprop','ro.kernel.qemu').strip()=='1' and cold.adb(serial,'shell','getprop','ro.product.cpu.abi').strip()=='x86_64','isolated_x64_avd_required')
    artifacts={}
    for variant in ['baseline','checkpoint']:
        apk_input=getattr(args,variant+'_apk')
        contract.require(not apk_input.is_symlink(),'regular_apk_required')
        apk=apk_input.resolve(strict=True);proof_path=getattr(args,variant+'_provenance')
        data=cold.regular_bytes(apk);package,activity=cold.apk_identity(apk)
        contract.require(package==contract.PACKAGE,'isolated_apk_identity_required')
        proof=read_provenance(proof_path,variant,args.source_commit)
        artifacts[variant]={'apk':apk,'activity':activity,'apk_sha256':cold.sha(data),'provenance':proof,'provenance_sha256':cold.sha(cold.regular_bytes(proof_path))}
    contract.require(artifacts['baseline']['apk_sha256']!=artifacts['checkpoint']['apk_sha256'] and artifacts['baseline']['provenance']['fixture_sha256']==artifacts['checkpoint']['provenance']['fixture_sha256'],'distinct_variant_artifacts_required')
    # Only now may the command retain a closed failure artifact in owned temp.
    args._qualified_output=output
    return owned_run(args,serial,artifacts)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source-commit',required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--phase-timeout',type=int,default=90)
    for variant in ['baseline','checkpoint']:
        parser.add_argument('--'+variant+'-apk',type=Path,required=True);parser.add_argument('--'+variant+'-provenance',type=Path,required=True)
    args=parser.parse_args()
    try:value=run(args);code=0
    except (contract.Refused,cold.Refused,framing.contract.Refused) as error:
        # Every helper raises a fixed code; never emit exception text or frames.
        closed=contract.closed_code(getattr(error,'code',None),'source_runtime_refused')
        value={'schema':'recall-native-outbox-comparison/v1','qualification_passed':False,'closed_failure_code':closed,'raw_logs_saved':False};code=1
    except Exception:
        value={'schema':'recall-native-outbox-comparison/v1','qualification_passed':False,'closed_failure_code':'source_runtime_refused','raw_logs_saved':False};code=1
    output=getattr(args,'_qualified_output',None)
    if output is not None:
        try:
            output.mkdir(mode=0o700,parents=True,exist_ok=False)
            with (output/'comparison.json').open('x') as stream:json.dump(value,stream,sort_keys=True,indent=2);stream.write('\n')
        except OSError:
            value={'schema':'recall-native-outbox-comparison/v1','qualification_passed':False,'closed_failure_code':'output_write_refused','raw_logs_saved':False};code=1
    print(json.dumps(value,sort_keys=True));return code

if __name__=='__main__':raise SystemExit(main())
