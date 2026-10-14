"""Invented ADB/JSON fixtures: never invokes subprocess, SDK or an emulator."""
import importlib.util
import json
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
# Keep the fake import confined to this driver, preserving other test modules.
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
