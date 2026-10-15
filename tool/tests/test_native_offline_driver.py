"""Invented ADB/JSON fixtures: never invokes subprocess, SDK or an emulator."""
import importlib.util
import json
import io
import contextlib
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from test_native_offline_contract import fabricated_receipts, COMMIT

cold=types.ModuleType('measure_android_cold_start')
cold.Refused=type('Refused',(Exception,),{})
cold.adb=lambda *a,**kw: (_ for _ in ()).throw(AssertionError('unmocked ADB'))
cold.launch_metrics=lambda text: {'TotalTime':1,'WaitTime':1}
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
with patch.dict(sys.modules, {'measure_android_cold_start': cold}):
    import run_synthetic_native_offline_restart as driver

class DriverTests(unittest.TestCase):
    def exercise(self, mutate=None, failure=None, change_apk=False, original=0, invalid_state=False, unsupported=False, refuse_change=False, alter_after_one=False, alter_after_two=False):
        _,one,two=fabricated_receipts()
        if mutate:mutate(one,two)
        calls=[];self.calls=calls;active=None;launches=0;airplane=original;commands=0
        def adb(serial,*args,**kwargs):
            nonlocal active,launches,airplane,commands
            calls.append(args)
            if args[:5]==('shell','settings','get','global','airplane_mode_on'):return 'null' if invalid_state else str(airplane)
            if args[:5]==('shell','cmd','connectivity','airplane-mode','enable') or args[:5]==('shell','cmd','connectivity','airplane-mode','disable'):
                commands+=1
                if unsupported:raise driver.contract.Refused('adb_command_failed')
                if not refuse_change:airplane=int(args[-1]=='enable')
                return ''
            if args[:2]==('shell','am') and args[2]=='force-stop': active=None;return ''
            if args==('shell','pidof',driver.PACKAGE):return '' if active is None else str(active)
            if args[:3]==('shell','pm','clear'):return 'Success'
            if args[:3]==('shell','am','start'):
                launches+=1;active=one['pid'] if launches==1 else two['pid'];return 'Status: ok\nTotalTime: 1\nWaitTime: 1'
            if args[0]=='logcat':
                receipt=one if launches==1 else two
                if alter_after_one and launches==1:airplane=0
                if alter_after_two and launches==2:airplane=1
                if change_apk and launches==2:apk.write_bytes(b'different-invented-apk')
                if failure:receipt=failure
                return 'I flutter: '+driver.SENTINEL+json.dumps(receipt)
            if args[0]=='install':return 'Success'
            raise AssertionError('unexpected operation')
        with tempfile.TemporaryDirectory() as tmp:
            apk=Path(tmp)/'invented.apk';apk.write_bytes(b'invented-not-an-apk')
            args=types.SimpleNamespace(apk=apk,source_commit=COMMIT,phase_timeout=15)
            with patch.object(cold,'adb',adb):result=driver.run_owned(args,'emulator-5554','fixture.Activity')
        return result,calls
    def test_one_clear_two_pids_no_reinstall_preserves_preferences(self):
        result,calls=self.exercise()
        self.assertTrue(result['qualification']['qualification_passed'])
        self.assertEqual(sum(a[0]=='install' for a in calls),1)
        self.assertEqual(sum(a[:3]==('shell','pm','clear') for a in calls),1)
        starts=[i for i,a in enumerate(calls) if a[:3]==('shell','am','start')]
        self.assertEqual(len(starts),2)
        self.assertFalse(any(a[:3]==('shell','pm','clear') for a in calls[starts[0]:]))
        self.assertTrue(all(any(part == driver.PACKAGE or part.startswith(driver.PACKAGE+'/') for part in a) for a in calls if a[:2]==('shell','am') or a[:2]==('shell','pm')))
        commands=[a[-1] for a in calls if a[:4]==('shell','cmd','connectivity','airplane-mode')]
        self.assertEqual(commands,['enable','disable','disable'])
        transcript=[a[-1] if a[:4]==('shell','cmd','connectivity','airplane-mode') else 'start' for a in calls if a[:4]==('shell','cmd','connectivity','airplane-mode') or a[:3]==('shell','am','start')]
        self.assertEqual(transcript,['enable','start','disable','start','disable'])
        self.assertEqual(sum(a[:5]==('shell','settings','get','global','airplane_mode_on') for a in calls),6)
        self.assertFalse(any('broadcast' in a or 'put' in a for a in calls))
    def test_airplane_state_drift_during_phase_one_refuses(self):
        with self.assertRaises(driver.contract.Refused) as caught:self.exercise(alter_after_one=True)
        self.assertEqual(caught.exception.code,'airplane_phase_one_state_changed')
        self.assertEqual(self.calls[-1],('shell','am','force-stop',driver.PACKAGE))
    def test_airplane_state_drift_during_phase_two_refuses(self):
        with self.assertRaises(driver.contract.Refused) as caught:self.exercise(alter_after_two=True)
        self.assertEqual(caught.exception.code,'airplane_phase_two_state_changed')
        self.assertEqual(self.calls[-1],('shell','am','force-stop',driver.PACKAGE))
    def test_original_enabled_state_is_restored(self):
        result,calls=self.exercise(original=1)
        self.assertEqual(result['launch']['os_airplane_restored_state'],1)
        self.assertEqual([a[-1] for a in calls if a[:4]==('shell','cmd','connectivity','airplane-mode')],['enable','disable','enable'])
    def test_invalid_state_refuses_before_install_no_state_hack(self):
        with self.assertRaises(driver.contract.Refused):self.exercise(invalid_state=True)
        self.assertFalse(any(a[0]=='install' or a[:4]==('shell','cmd','connectivity','airplane-mode') for a in self.calls))
    def test_unsupported_command_refuses_and_attempts_exact_restore(self):
        with self.assertRaises(driver.contract.Refused) as caught:self.exercise(unsupported=True)
        self.assertEqual(caught.exception.code,'airplane_restore_failed')
        self.assertEqual([a[-1] for a in self.calls if a[:4]==('shell','cmd','connectivity','airplane-mode')],['enable','disable'])
        self.assertEqual(self.calls[-1],('shell','am','force-stop',driver.PACKAGE))
    def test_readback_not_changed_refuses_and_restores(self):
        with self.assertRaises(driver.contract.Refused) as caught:self.exercise(refuse_change=True)
        self.assertEqual(caught.exception.code,'airplane_state_change_not_observed')
        self.assertEqual(self.calls[-1],('shell','am','force-stop',driver.PACKAGE))
    def test_app_failure_restores_before_owned_package_cleanup(self):
        _,one,_=fabricated_receipts()
        failure={'schema':driver.contract.SCHEMA,'phase':'failed','source_commit':COMMIT,'pid':one['pid'],'failure_code':'synthetic_phase_failed','failed_phase':'native_restore'}
        with self.assertRaises(driver.contract.Refused):self.exercise(failure=failure)
        self.assertEqual([a[-1] for a in self.calls if a[:4]==('shell','cmd','connectivity','airplane-mode')],['enable','disable'])
        self.assertEqual(self.calls[-1],('shell','am','force-stop',driver.PACKAGE))
    def test_apk_bytes_changed_after_install_are_refused(self):
        with self.assertRaises(driver.contract.Refused) as caught:
            self.exercise(change_apk=True)
        self.assertEqual(caught.exception.code,'apk_input_changed')
    def test_same_pid_refused(self):
        with self.assertRaises(driver.contract.Refused) as caught:
            self.exercise(lambda one,two:two.update(pid=one['pid']))
        self.assertEqual(caught.exception.code,'fresh_process_proof_invalid')
    def test_changed_event_refused(self):
        with self.assertRaises(driver.contract.Refused):self.exercise(lambda one,two:two.update(event_sha256='f'*64))
    def test_lost_ack_must_retain_outbox(self):
        with self.assertRaises(driver.contract.Refused):self.exercise(lambda one,two:two.update(pending_after_lost_ack=0))
    def test_closed_failure_projection(self):
        _,one,_=fabricated_receipts()
        failure={'schema':driver.contract.SCHEMA,'phase':'failed','source_commit':COMMIT,'pid':one['pid'],'failure_code':'synthetic_phase_failed','failed_phase':'native_restore'}
        with self.assertRaises(driver.contract.Refused) as caught:self.exercise(failure=failure)
        self.assertEqual(caught.exception.failure_code,'synthetic_phase_failed')
        self.assertEqual(caught.exception.failed_phase,'native_restore')
    def test_fixed_phase_one_assertion_stage_is_projected(self):
        _,one,_=fabricated_receipts()
        failure={'schema':driver.contract.SCHEMA,'phase':'failed','source_commit':COMMIT,'pid':one['pid'],'failure_code':'synthetic_phase_failed','failed_phase':'offline_recording','failed_assertion_stage':'online_ready'}
        with self.assertRaises(driver.contract.Refused) as caught:self.exercise(failure=failure)
        self.assertEqual(caught.exception.failed_assertion_stage,'online_ready')
    def test_unknown_or_wrong_phase_assertion_stage_is_refused(self):
        _,one,_=fabricated_receipts()
        for stage,phase in [('private payload','offline_recording'),('online_ready','native_restore')]:
            failure={'schema':driver.contract.SCHEMA,'phase':'failed','source_commit':COMMIT,'pid':one['pid'],'failure_code':'synthetic_phase_failed','failed_phase':phase,'failed_assertion_stage':stage}
            with self.assertRaises(driver.contract.Refused) as caught:self.exercise(failure=failure)
            self.assertEqual(caught.exception.code,'fixture_failure_schema_invalid')
    def test_main_outputs_only_fixed_stage_projection(self):
        error=driver.contract.Refused('fixture_reported_failure')
        error.failure_code='synthetic_phase_failed';error.failed_phase='offline_recording';error.failed_assertion_stage='online_ready'
        with tempfile.TemporaryDirectory() as tmp:
            argv=['driver','--apk',str(Path(tmp)/'invented.apk'),'--source-commit',COMMIT,'--output',str(Path(tmp)/'new-result')]
            out=io.StringIO()
            with patch.object(sys,'argv',argv),patch.object(driver,'run',side_effect=error),contextlib.redirect_stdout(out):code=driver.main()
            self.assertEqual(code,1)
            self.assertEqual(json.loads(out.getvalue()),{'schema':'recall-native-offline-qualification/v2','qualification_passed':False,'closed_failure_code':'fixture_reported_failure','raw_logs_printed':False,'failure_code':'synthetic_phase_failed','failed_phase':'offline_recording','failed_assertion_stage':'online_ready'})
            self.assertFalse((Path(tmp)/'new-result').exists())
    def frame_error(self, body):
        with self.assertRaises(driver.contract.Refused) as caught:
            driver.closed_event('123.456 101 101 I flutter: '+driver.SENTINEL+body,
                                'offline_recorded',101,COMMIT)
        self.assertEqual(caught.exception.code,'fixture_json_invalid')
        return caught.exception
    def test_exact_epoch_log_line_remains_valid(self):
        _,one,_=fabricated_receipts()
        self.assertEqual(driver.closed_event('123.456 101 101 I flutter: '+driver.SENTINEL+json.dumps(one),
                        'offline_recorded',101,COMMIT),one)
    def test_truncated_frame_refuses_with_bounded_facts(self):
        error=self.frame_error('{"schema":')
        self.assertEqual(error.frame_diagnostics,{'byte_count':10,'byte_count_capped':False,
             'parse_offset':10,'parse_offset_capped':False,'object_prefix':True,'object_suffix':False})
    def test_malformed_complete_frame_refuses_no_raw_tokens(self):
        secret='invented-private-token-not-for-output'
        error=self.frame_error('{"x":'+secret+'}')
        facts=driver.contract.validate_frame_diagnostics(error.frame_diagnostics)
        self.assertTrue(facts['object_prefix']);self.assertTrue(facts['object_suffix'])
        self.assertNotIn(secret,json.dumps(facts));self.assertFalse(hasattr(error,'body'))
    def test_fragmented_frame_is_not_silently_joined_or_ignored(self):
        _,one,_=fabricated_receipts();raw=json.dumps(one)
        split=raw.index('source_commit')
        with self.assertRaises(driver.contract.Refused) as caught:
            driver.closed_event(driver.SENTINEL+raw[:split]+'\n'+raw[split:],
                                'offline_recorded',101,COMMIT)
        self.assertEqual(caught.exception.code,'fixture_json_invalid')
    def test_utf8_offsets_are_bytes_and_diagnostics_cap(self):
        raw='{"x":"'+'é'*5000+'" trailing}'
        error=self.frame_error(raw);facts=error.frame_diagnostics
        self.assertEqual(facts['byte_count'],4096);self.assertTrue(facts['byte_count_capped'])
        self.assertEqual(facts['parse_offset'],4096);self.assertTrue(facts['parse_offset_capped'])
    def test_diagnostic_contract_rejects_raw_and_invalid_fields(self):
        facts=self.frame_error('{').frame_diagnostics
        for update in [{'raw_frame':'invented-private'},{'byte_count':True},{'parse_offset':4097}]:
            bad={**facts,**update}
            with self.assertRaises(driver.contract.Refused):driver.contract.validate_frame_diagnostics(bad)
    def test_output_guard_refuses_outside_temporary_or_existing_path(self):
        import os
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);owned=root/'owned';owned.mkdir()
            with patch.dict(os.environ,{'RUNNER_TEMP':str(owned)}):
                for target in [root/'outside',owned]:
                    args=types.SimpleNamespace(output=target)
                    with self.assertRaises(driver.contract.Refused):driver.qualify_failure_output(args)
                    self.assertFalse(hasattr(args,'_qualified_failure_output'))
    def test_output_guard_resolves_symlink_escape(self):
        import os
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);owned=root/'owned';owned.mkdir();outside=root/'outside';outside.mkdir()
            (owned/'escape').symlink_to(outside,target_is_directory=True)
            with patch.dict(os.environ,{'RUNNER_TEMP':str(owned)}):
                args=types.SimpleNamespace(output=owned/'escape'/'new')
                with self.assertRaises(driver.contract.Refused):driver.qualify_failure_output(args)
                self.assertFalse((outside/'new').exists())
    def test_pre_guard_failure_does_not_write_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            args=types.SimpleNamespace(output=Path(tmp)/'new')
            value={'schema':'recall-native-offline-qualification/v2','qualification_passed':False}
            self.assertEqual(driver.retain_closed_failure(args,value),value)
            self.assertFalse(args.output.exists())
    def test_guarded_json_failure_retains_only_closed_qualification(self):
        import os
        error=self.frame_error('{"private":invalid}')
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'new';out=io.StringIO()
            def qualified_failure(args):
                driver.qualify_failure_output(args)
                raise error
            argv=['driver','--apk',str(Path(tmp)/'invented.apk'),'--source-commit',COMMIT,'--output',str(output)]
            with patch.dict(os.environ,{'RUNNER_TEMP':tmp}),patch.object(sys,'argv',argv),patch.object(driver,'run',side_effect=qualified_failure),contextlib.redirect_stdout(out):
                self.assertEqual(driver.main(),1)
            result=json.loads(out.getvalue());saved=json.loads((output/'qualification.json').read_text())
            self.assertEqual(saved,result);self.assertTrue(saved['failure_artifact_saved'])
            self.assertEqual(saved['closed_failure_code'],'fixture_json_invalid')
            self.assertEqual(set(saved['frame_diagnostics']),driver.contract.FRAME_DIAGNOSTIC_KEYS)
            self.assertEqual([p.name for p in output.iterdir()],['qualification.json'])
            self.assertNotIn('private',json.dumps(saved));self.assertNotIn('invalid}',json.dumps(saved))
    def test_guarded_failure_never_overwrites_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'existing';output.mkdir();target=output/'qualification.json';target.write_text('original')
            args=types.SimpleNamespace(_qualified_failure_output=output)
            result=driver.retain_closed_failure(args,{'schema':'recall-native-offline-qualification/v2','qualification_passed':False,'closed_failure_code':'fixture_phase_timeout','raw_logs_printed':False})
            self.assertFalse(result['failure_artifact_saved']);self.assertEqual(target.read_text(),'original')
    def test_artifact_rejects_unknown_raw_field(self):
        with tempfile.TemporaryDirectory() as tmp:
            args=types.SimpleNamespace(_qualified_failure_output=Path(tmp)/'new')
            value={'schema':'recall-native-offline-qualification/v2','qualification_passed':False,
                   'closed_failure_code':'fixture_json_invalid','raw_logs_printed':False,'raw_frame':'invented-private'}
            result=driver.retain_closed_failure(args,value)
            self.assertEqual(result['closed_failure_code'],'failure_artifact_payload_refused')
            self.assertNotIn('invented-private',json.dumps(result));self.assertFalse(args._qualified_failure_output.exists())
    def test_artifact_rejects_nested_payload_and_unknown_phase(self):
        for update in [{'frame_diagnostics':{'raw_frame':'invented-private'}},
                       {'failure_code':'synthetic_phase_failed','failed_phase':'invented-private'}]:
            with self.subTest(update=update),tempfile.TemporaryDirectory() as tmp:
                args=types.SimpleNamespace(_qualified_failure_output=Path(tmp)/'new')
                value={'schema':'recall-native-offline-qualification/v2','qualification_passed':False,
                       'closed_failure_code':'fixture_json_invalid','raw_logs_printed':False,**update}
                result=driver.retain_closed_failure(args,value)
                self.assertEqual(result['closed_failure_code'],'failure_artifact_payload_refused')
                self.assertNotIn('invented-private',json.dumps(result));self.assertFalse(args._qualified_failure_output.exists())
    def test_failure_output_is_qualified_only_after_apk_identity_guard(self):
        import os
        from subprocess import CompletedProcess
        original_exists=driver.Path.exists
        for package,qualified in [(driver.PACKAGE,True),('com.german.health_anki_flutter',False)]:
            with self.subTest(package=package),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);apk=root/'invented.apk';apk.write_bytes(b'invented');output=root/'new'
                args=types.SimpleNamespace(apk=apk,output=output,source_commit=COMMIT,phase_timeout=60)
                adb=lambda serial,*a,**kw: '1' if a[-1]=='ro.kernel.qemu' else 'x86_64'
                exists=lambda path: True if str(path)=='/dev/kvm' else original_exists(path)
                inventory=CompletedProcess(['adb','devices'],0,'List of devices attached\nemulator-5554\tdevice\n','')
                with patch.dict(os.environ,{'RUNNER_TEMP':tmp}),patch.object(cold,'require_ci',lambda:None,create=True),patch.object(cold,'apk_identity',lambda p:(package,'fixture.Activity'),create=True),patch.object(cold,'adb',adb),patch.object(driver.Path,'exists',exists),patch.object(driver.os,'access',return_value=True),patch.object(driver.subprocess,'run',return_value=inventory),patch.object(driver,'run_owned',side_effect=driver.contract.Refused('fixture_phase_timeout')) as owned:
                    with self.assertRaises(driver.contract.Refused):driver.run(args)
                self.assertEqual(hasattr(args,'_qualified_failure_output'),qualified)
                self.assertEqual(owned.call_count,1 if qualified else 0)
                self.assertFalse(output.exists())
    def test_raw_error_field_refused(self):
        _,one,_=fabricated_receipts()
        failure={'schema':driver.contract.SCHEMA,'phase':'failed','source_commit':COMMIT,'pid':one['pid'],'failure_code':'synthetic_phase_failed','failed_phase':'native_restore','exception':'private'}
        with self.assertRaises(driver.contract.Refused) as caught:self.exercise(failure=failure)
        self.assertEqual(caught.exception.code,'fixture_failure_schema_invalid')
    def test_wrong_receipt_phase_refused(self):
        with self.assertRaises(driver.contract.Refused):self.exercise(lambda one,two:one.update(phase='restart_synced'))
    def test_duplicate_receipt_refused(self):
        _,one,_=fabricated_receipts();line=driver.SENTINEL+json.dumps(one)
        with self.assertRaises(driver.contract.Refused):driver.closed_event(line+'\n'+line,'offline_recorded',101,COMMIT)

if __name__=='__main__':unittest.main()
