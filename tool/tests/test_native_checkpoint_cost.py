"""Invented receipts, private temp technical copies and mocked ADB; no SDK."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

TOOL=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(TOOL))
# Exercise the delivered helpers on sys.path; no external workspace fixtures or
# reads of current production controller/Store/pubspec are test prerequisites.
import native_checkpoint_contract as contract
import prepare_native_checkpoint_cost as prepare

def _private_module(name, filename):
    spec=importlib.util.spec_from_file_location(name,TOOL/filename)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

# The existing offline driver tests import their shared driver with a private
# fake cold module. Do not eagerly cache that shared driver with real helpers
# during discovery here, or their scoped import mocks cannot bind to it.
_private_framing=_private_module('_checkpoint_test_framing','run_synthetic_native_offline_restart.py')
with patch.dict(sys.modules, {'run_synthetic_native_offline_restart':_private_framing}):
    driver=_private_module('_checkpoint_test_driver','run_native_checkpoint_cost.py')
cold=driver.cold
H=lambda x:hashlib.sha256(x).hexdigest()
FIXTURE=contract.FIXTURE_SHA


def receipt(variant='baseline',count=128,pid=101):
    return {'schema':contract.SCHEMA,'phase':'done','baseline_source_commit':contract.SOURCE,'source_commit':contract.SOURCE,
        'variant':variant,'controller_sha256':contract.BASE_CONTROLLER if variant=='baseline' else contract.CHECKPOINT_CONTROLLER,
        'store_git_blob':contract.STORE_BLOB,'fixture_sha256':FIXTURE,'patch_sha256':'none' if variant=='baseline' else contract.PATCH_SHA,
        'package':contract.PACKAGE,'pid':pid,'pending_seeded':count,'build_mode':'debug',
        'environment':'isolated_android_fixture','native_preferences':True,'fake_http_only':True,
        'power_loss_tested':False,'physical_device_tested':False,'real_provider_contacted':False,
        'timing_us':{'sync_pending':1000,'mark_total':600,'remove_total':100,'native_ack_total':500,'native_ack_max':20,'api_apply_total':100},
        'counts':{'mark_calls':1,'remove_calls':1 if variant=='baseline' else count//32+1,
        'native_ack_writes':2+(1 if variant=='baseline' else count//32),'native_ack_chars':10000,
        'native_ack_utf8_bytes':10000,'apply_review_requests':count,'accepted_unique':count,'pending_after':0}}


def source_proof(variant='baseline'):
    manifest=sorted([{'path':prepare.CONTROLLER,'sha256':contract.BASE_CONTROLLER if variant=='baseline' else contract.CHECKPOINT_CONTROLLER},{'path':prepare.STORE,'sha256':contract.STORE_SHA},{'path':prepare.ENTRY,'sha256':FIXTURE}],key=lambda row:row['path'])
    return {'schema':'recall-native-outbox-source/v1','baseline_source_commit':contract.SOURCE,'source_commit':contract.SOURCE,'variant':variant,'package':contract.PACKAGE,
        'controller_sha256':contract.BASE_CONTROLLER if variant=='baseline' else contract.CHECKPOINT_CONTROLLER,
        'baseline_controller_sha256':contract.BASE_CONTROLLER,'store_sha256':contract.STORE_SHA,'store_git_blob':contract.STORE_BLOB,
        'patch_sha256':'none' if variant=='baseline' else contract.PATCH_SHA,'fixture_sha256':FIXTURE,
        'technical_source_manifest_sha256':H(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()),'technical_source_files':len(manifest),'technical_source_manifest':manifest,
        'cold_provenance':{'source_commit':contract.SOURCE,'package':contract.PACKAGE,'normal_source_unchanged':True,
            'namespace_and_signing_policy_unchanged':True,'test_only_transform':True,'actual_cards_articles_media_copied':False,
            'asset_scope':'technical-fonts-only','application_id_changes':1}}


def packet(value):
    import base64
    data=json.dumps(value,separators=(',',':')).encode();n=(len(data)+239)//240
    return '\n'.join(driver.framing.CHUNK_SENTINEL+'v1 %s %d %d %d %s'%(H(data),len(data),i,n,base64.urlsafe_b64encode(data[i*240:(i+1)*240]).decode()) for i in range(n))


class ContractTests(unittest.TestCase):
    def test_both_variants_both_sizes_strictly_qualify(self):
        for variant in ['baseline','checkpoint']:
            for count in [128,512]:
                value=receipt(variant,count)
                self.assertEqual(contract.validate(value,variant=variant,count=count,pid=101,fixture_sha=FIXTURE),value)
    def test_previous_profile_pins_are_refused(self):
        # Neither main's #162 profile nor the pre-merge #161 profile qualifies
        # the combined controller, even when just one stale pin is presented.
        profiles = [
            ('ccad3943873239b697ecabee422931a2b3777db6',
             '19261c0fb264ccdd73438aecf2e4e9253263e8f07b341e371ec8448e8f9f1718',
             '75310a20d3d611979c069e936074937fa23ce325182904b6c9fbeba04f30a4c6',
             '0e86e56d778c35b00e743dda28bb2a441c7a0cb8c45c12f757b859f675a0bc5e',
             '4bb392d3430bb161cd45f93baf9592d7a077e206f2a0049bd69ce866bac22cae'),
            ('5d47516c79198da7c85a64c5324ac5e41b2a57e8',
             'dd06f96a561a26837ef05ce3b922b5455502619e9a74259532ea1658e6f6d34c',
             'aadfed529f70451fc9a2c497c222915b4460917ec2d8ba432de2ee9260ac9ce2',
             '5b763397f9315c456c7d585d2d01382b06de242751e49aafa427608790c91e76',
             '504d28ea6158f42866c6833b9ad41ca531bc47356b67456600df3ed89e09da90'),
        ]
        for source,baseline,checkpoint,patch_sha,fixture in profiles:
            for variant in ['baseline','checkpoint']:
                stale = {'baseline_source_commit':source,
                         'controller_sha256':baseline if variant=='baseline' else checkpoint,
                         'fixture_sha256':fixture}
                # A prior profile can share identical patch bytes when its
                # hunk positions coincide; only a distinct patch pin is stale.
                if variant=='checkpoint' and patch_sha!=contract.PATCH_SHA:
                    stale['patch_sha256']=patch_sha
                for key,value in stale.items():
                    with self.subTest(source=source,variant=variant,key=key):
                        for count in [128,512]:
                            with self.assertRaises(contract.Refused):
                                contract.validate({**receipt(variant,count),key:value},variant=variant,count=count,pid=101,fixture_sha=FIXTURE)
                        with self.assertRaises(contract.Refused):
                            contract.validate_provenance({**source_proof(variant),key:value},variant)
    def test_previous_main_profile_pins_are_refused(self):
        for variant,controller in [
            ('baseline','41f5faf0621886563e85b644dad6bf26cae412305afc09d0fa58c2de73e9bfd1'),
            ('checkpoint','bf09fae109736b8bc93ddc407d0fa9c5c5f3ce4036952b19dfc4d679f096e28e'),
        ]:
            stale = {
                'baseline_source_commit':'fcefe7f19653402ddd4d1b8562e7088d9677e676',
                'controller_sha256':controller,
                'fixture_sha256':'a126a57433830e47c5088cd502be927a4b42230c8c99cef9cd34d2edc23d9aa5',
            }
            if variant=='checkpoint':
                stale['patch_sha256']='7ed41d29484fd3b7e9c0afaf881f301221be40cc0ec46d8dc14a10381e50af0a'
            for key,value in stale.items():
                with self.subTest(variant=variant,key=key):
                    for count in [128,512]:
                        with self.assertRaises(contract.Refused):
                            contract.validate({**receipt(variant,count),key:value},variant=variant,count=count,pid=101,fixture_sha=FIXTURE)
                    with self.assertRaises(contract.Refused):
                        contract.validate_provenance({**source_proof(variant),key:value},variant)

    def test_invented_values_cannot_claim_real_provider_or_release_device(self):
        for update in [{'real_provider_contacted':True},{'physical_device_tested':True},{'native_preferences':False},{'build_mode':'release'},{'power_loss_tested':True}]:
            with self.subTest(update=update),self.assertRaises(contract.Refused):contract.validate({**receipt(),**update},variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
    def test_wrong_variant_source_store_fixture_pid_count_refuse(self):
        for key,value in [('variant','checkpoint'),('source_commit','a'*40),('store_git_blob','b'*40),('fixture_sha256','c'*64),('pid',102),('pending_seeded',True),('patch_sha256',contract.PATCH_SHA)]:
            with self.subTest(key=key),self.assertRaises(contract.Refused):contract.validate({**receipt(),key:value},variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
    def test_ack_counts_and_completion_are_required(self):
        for key in contract.COUNTS:
            data=receipt();data['counts'][key]=True
            with self.subTest(key=key),self.assertRaises(contract.Refused):contract.validate(data,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
        for variant in ['baseline','checkpoint']:
            for key in ['mark_calls','remove_calls','native_ack_writes','apply_review_requests','accepted_unique','pending_after']:
                data=receipt(variant);data['counts'][key]+=1
                with self.subTest(variant=variant,key=key),self.assertRaises(contract.Refused):contract.validate(data,variant=variant,count=128,pid=101,fixture_sha=FIXTURE)
    def test_per_review_marks_no_longer_qualify(self):
        # Drains mark the first send alone and the rest in one batch write; a
        # receipt with one mark write per review is a regression, not a sample.
        for variant in ['baseline','checkpoint']:
            for count in [128,512]:
                data=receipt(variant,count);removals=1 if variant=='baseline' else count//32
                data['counts'].update(mark_calls=count,native_ack_writes=count+removals)
                with self.subTest(variant=variant,count=count),self.assertRaises(contract.Refused):contract.validate(data,variant=variant,count=count,pid=101,fixture_sha=FIXTURE)
    def test_timing_and_byte_consistency_refuse(self):
        for metric in contract.TIMINGS:
            data=receipt();data['timing_us'][metric]=-1
            with self.subTest(metric=metric),self.assertRaises(contract.Refused):contract.validate(data,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
        data=receipt();data['timing_us']['native_ack_total']=2000
        with self.assertRaises(contract.Refused):contract.validate(data,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
    def test_no_payload_or_unknown_fields_accepted(self):
        with self.assertRaises(contract.Refused):contract.validate({**receipt(),'raw_event':'private'},variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
        data=receipt();data['timing_us']['raw']='private'
        with self.assertRaises(contract.Refused):contract.validate(data,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
    def test_failure_code_is_closed_and_never_a_valid_sample(self):
        failed={'schema':contract.SCHEMA,'phase':'failed','source_commit':contract.SOURCE,'variant':'baseline','pid':101,'failure_code':'measurement_refused'}
        with self.assertRaises(contract.Refused) as caught:contract.validate(failed,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
        self.assertEqual(caught.exception.code,'fixture_reported_failure')
        failed['failure_code']='private'
        with self.assertRaises(contract.Refused) as caught:contract.validate(failed,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
        self.assertEqual(caught.exception.code,'fixture_failure_schema_invalid')
        self.assertEqual(contract.closed_code('inventedprivatetoken','source_runtime_refused'),'source_runtime_refused')
    def test_provenance_source_transform_and_scope_required(self):
        for variant in ['baseline','checkpoint']:self.assertEqual(contract.validate_provenance(source_proof(variant),variant)['variant'],variant)
        for key in ['controller_sha256','store_sha256','patch_sha256','fixture_sha256']:
            proof=source_proof();proof[key]='wrong'
            with self.subTest(key=key),self.assertRaises(contract.Refused):contract.validate_provenance(proof,'baseline')
        proof=source_proof();proof['cold_provenance']['actual_cards_articles_media_copied']=True
        with self.assertRaises(contract.Refused):contract.validate_provenance(proof,'baseline')


class ManifestTests(unittest.TestCase):
    def test_manifest_hash_duplicate_path_and_protected_binding_refuse(self):
        for mode in ['hash','duplicate','store','traversal','extra']:
            proof=source_proof();manifest=proof['technical_source_manifest']
            if mode=='hash':proof['technical_source_manifest_sha256']='f'*64
            if mode=='duplicate':manifest.append(dict(manifest[0]));proof['technical_source_files']+=1
            if mode=='store':next(row for row in manifest if row['path']==prepare.STORE)['sha256']='f'*64
            if mode=='traversal':manifest[0]['path']='../private'
            if mode=='extra':manifest[0]['payload']='private'
            if mode!='hash':proof['technical_source_manifest_sha256']=H(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode())
            with self.subTest(mode=mode),self.assertRaises(contract.Refused):contract.validate_provenance(proof,'baseline')

class DecoderTests(unittest.TestCase):
    def test_real_decoder_complete_and_incomplete_packets(self):
        raw=packet(receipt());self.assertEqual(driver.event(raw,'baseline',128,101,FIXTURE),receipt())
        partial='\n'.join(raw.splitlines()[:-1]);self.assertIsNone(driver.event(partial,'baseline',128,101,FIXTURE,allow_incomplete=True))
        with self.assertRaises(driver.framing.contract.Refused):driver.event(partial,'baseline',128,101,FIXTURE)
    def test_corrupt_duplicate_reordered_and_wrong_process_refuse(self):
        lines=packet(receipt()).splitlines()
        for raw in ['\n'.join(lines+lines),'\n'.join(reversed(lines)),lines[0][:-1]]:
            with self.assertRaises((contract.Refused,driver.framing.contract.Refused)):driver.event(raw,'baseline',128,101,FIXTURE)
        with self.assertRaises(contract.Refused):driver.event(packet(receipt(pid=202)),'baseline',128,101,FIXTURE)
    def test_complete_malformed_json_is_not_skipped(self):
        with self.assertRaises(contract.Refused):driver.event(driver.framing.SENTINEL+'{"x":','baseline',128,101,FIXTURE)


class ProfileBindingTests(unittest.TestCase):
    def test_dart_guards_bind_the_same_profile_as_the_python_contract(self):
        fixture=(TOOL/'fixtures/synthetic_native_outbox_cost_main.dart').read_text()
        for name,value in [('_baselineControllerSha',contract.BASE_CONTROLLER),
                           ('_checkpointControllerSha',contract.CHECKPOINT_CONTROLLER),
                           ('_checkpointPatchSha',contract.PATCH_SHA),
                           ('_storeBlob',contract.STORE_BLOB)]:
            with self.subTest(name=name):
                self.assertEqual(re.findall(r'const '+name+r"\s*=\s*'([0-9a-f]+)';",fixture),[value])
        self.assertEqual(re.findall(r"_require\(_baseCommit == '([0-9a-f]+)'\);",fixture),[contract.SOURCE])
        self.assertEqual(H(fixture.encode()),contract.FIXTURE_SHA)

    def test_workflow_defines_and_documentation_bind_both_variants(self):
        workflow=(TOOL.parent/'.github/workflows/recall-synthetic-native-cost.yml').read_text()
        for name,values in [
            ('RECALL_BASE_COMMIT',[contract.SOURCE]*2),
            ('RECALL_CONTROLLER_SHA256',[contract.BASE_CONTROLLER,contract.CHECKPOINT_CONTROLLER]),
            ('RECALL_PATCH_SHA256',['none',contract.PATCH_SHA]),
            ('RECALL_FIXTURE_SHA256',[contract.FIXTURE_SHA]*2),
        ]:
            with self.subTest(name=name):
                self.assertEqual(re.findall(r'--dart-define='+name+r'=([^\s]+)',workflow),values)
        self.assertEqual(re.findall(r'--fixture-sha ([0-9a-f]+)',workflow),[contract.FIXTURE_SHA]*2)
        readme=(TOOL/'fixtures/README-native-checkpoint-cost.md').read_text()
        for value in [contract.SOURCE,contract.BASE_CONTROLLER,contract.CHECKPOINT_CONTROLLER,
                      contract.STORE_SHA,contract.STORE_BLOB,contract.PATCH_SHA,contract.FIXTURE_SHA]:
            with self.subTest(pin=value):self.assertIn('`'+value+'`',readme)
        self.assertIn('RECALL_BASE_COMMIT='+contract.SOURCE[:8]+'...',readme)


class PreparerTests(unittest.TestCase):
    # These tiny inputs are invented. Runtime constants are patched only for
    # this unit fixture; deployed source/profile pins remain immutable.
    BASE = b"class Invented {\n  int a = 1;\n  // gap A\n  int b = 2;\n  // gap B\n  int c = 3;\n}\n"
    RESULT = BASE.replace(b"a = 1",b"a = 11").replace(b"b = 2",b"b = 22").replace(b"c = 3",b"c = 33")
    STORE = b"// Invented isolated Store unit fixture.\n"
    FIXTURE = b"// Invented isolated entrypoint.\nvoid main() {}\n"
    GRADLE = b'android {\n  namespace = "invented.fixture"\n  defaultConfig {\n    applicationId = "com.german.health_anki_flutter"\n  }\n}\n'
    PUBSPEC = b'name: invented_unit_fixture\nversion: 0.0.1+1\nflutter:\n  uses-material-design: true\n  assets:\n    - assets/private/\n'
    PATCH = ("--- a/"+prepare.CONTROLLER+"\n+++ b/"+prepare.CONTROLLER+
             "\n@@ -2,1 +2,1 @@\n-  int a = 1;\n+  int a = 11;\n"
             "@@ -4,1 +4,1 @@\n-  int b = 2;\n+  int b = 22;\n"
             "@@ -6,1 +6,1 @@\n-  int c = 3;\n+  int c = 33;\n").encode()

    def setUp(self):
        from contextlib import ExitStack
        self.mocks=ExitStack();self.addCleanup(self.mocks.close)
        for name,value in [('BASE_CONTROLLER',H(self.BASE)),('CHECKPOINT_CONTROLLER',H(self.RESULT)),
                           ('STORE_SHA',H(self.STORE)),('STORE_BLOB','d'*40),
                           ('FIXTURE_SHA',H(self.FIXTURE)),('PATCH_SHA',H(self.PATCH))]:
            self.mocks.enter_context(patch.object(contract,name,value))
        self.mocks.enter_context(patch.object(cold,'BASE_GRADLE_SHA',H(self.GRADLE)))
        self.mocks.enter_context(patch.object(cold,'BASE_PUBSPEC_SHA',cold.pubspec_pin_sha(self.PUBSPEC)))

    def test_invented_exact_patch_scope_context_and_result_pins(self):
        # This independent check binds the tracked technical patch, without
        # loading production files into the invented unit fixture. The pinned
        # ACK-batch experiment is independently source-bound before compilation.
        real=(TOOL/'fixtures/checkpoint-drain-only.patch').read_bytes()
        self.assertEqual(H(real),'e2b1fd925a43d0f17325aaa5f0afb9e7880a0903320d21f819e55fd14653ddd7')
        self.assertEqual(prepare.apply_checkpoint(self.BASE,self.PATCH),self.RESULT)
        for data,payload in [(self.BASE+b'\n',self.PATCH),(self.BASE,self.PATCH+b'\n')]:
            with self.assertRaises(contract.Refused):prepare.apply_checkpoint(data,payload)
        bad=self.PATCH.replace(prepare.CONTROLLER.encode(),b'lib/invented_other.dart')
        with patch.object(contract,'PATCH_SHA',H(bad)),self.assertRaises(contract.Refused) as caught:
            prepare.apply_checkpoint(self.BASE,bad)
        self.assertEqual(caught.exception.code,'checkpoint_patch_scope_invalid')
        bad=self.PATCH.replace(b'-  int a = 1;',b'-  int a = 9;')
        with patch.object(contract,'PATCH_SHA',H(bad)),self.assertRaises(contract.Refused) as caught:
            prepare.apply_checkpoint(self.BASE,bad)
        self.assertEqual(caught.exception.code,'checkpoint_context_invalid')
        with patch.object(contract,'CHECKPOINT_CONTROLLER','0'*64),self.assertRaises(contract.Refused) as caught:
            prepare.apply_checkpoint(self.BASE,self.PATCH)
        self.assertEqual(caught.exception.code,'checkpoint_result_pin_invalid')

    def source(self,root):
        source=root/'source';source.mkdir()
        files={prepare.CONTROLLER:self.BASE,prepare.STORE:self.STORE,prepare.ENTRY:self.FIXTURE,
          'android/app/build.gradle.kts':self.GRADLE,'pubspec.yaml':self.PUBSPEC,
          'tool/fixtures/synthetic_android_main.dart':b'void main() {}',
          'tool/fixtures/synthetic_recall_flow.dart':b'// invented helper',
          'tool/fixtures/synthetic_study_frame.dart':b'// invented paint helper','assets/fonts/invented.ttf':b'inventedfont',
          'assets/private/never-read.txt':b'invented excluded corpus','config/secret.env':b'invented excluded config','android/key.properties':b'invented excluded signing'}
        for rel,data in files.items():
            path=source/rel;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        payload=root/'invented.patch';payload.write_bytes(self.PATCH)
        return source,files,payload

    def test_both_variant_technical_copies_preserve_source_and_exclude_data(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source,before,payload=self.source(root)
            read=cold.regular_bytes
            for variant in ['baseline','checkpoint']:
                args=types.SimpleNamespace(source=source,destination=root/(variant+'-copy'),source_commit=contract.SOURCE,variant=variant,fixture_sha=H(self.FIXTURE),patch=payload)
                with patch.dict(os.environ,{'RUNNER_TEMP':temp}),patch.object(cold,'require_ci',lambda:None),patch.object(cold,'regular_bytes',wraps=read) as reads:
                    proof=prepare.prepare(args)
                self.assertEqual(proof['variant'],variant)
                self.assertEqual((args.destination/prepare.CONTROLLER).read_bytes(),self.BASE if variant=='baseline' else self.RESULT)
                self.assertEqual((args.destination/prepare.STORE).read_bytes(),self.STORE)
                forbidden={source/'assets/private/never-read.txt',source/'config/secret.env',source/'android/key.properties'}
                self.assertFalse(any(call.args[0] in forbidden for call in reads.call_args_list))
                self.assertFalse((args.destination/'assets/private').exists());self.assertFalse((args.destination/'config').exists());self.assertFalse((args.destination/'android/key.properties').exists())
                self.assertIn(cold.PACKAGE,(args.destination/'android/app/build.gradle.kts').read_text().split('applicationId')[1].splitlines()[0])
                self.assertNotIn('assets/private/',(args.destination/'pubspec.yaml').read_text())
                self.assertTrue(all((source/rel).read_bytes()==data for rel,data in before.items()))

    def test_destination_symlink_escape_and_modified_store_refuse_before_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source,_,payload=self.source(root);owned=root/'owned';owned.mkdir();(owned/'escape').symlink_to(root,target_is_directory=True)
            args=types.SimpleNamespace(source=source,destination=owned/'escape'/'copy',source_commit=contract.SOURCE,variant='baseline',fixture_sha=H(self.FIXTURE),patch=payload)
            with patch.dict(os.environ,{'RUNNER_TEMP':str(owned)}),patch.object(cold,'require_ci',lambda:None),self.assertRaises(contract.Refused):prepare.prepare(args)
            args.destination=owned/'copy';(source/prepare.STORE).write_bytes(b'not pinned')
            with patch.dict(os.environ,{'RUNNER_TEMP':str(owned)}),patch.object(cold,'require_ci',lambda:None),self.assertRaises(contract.Refused):prepare.prepare(args)
            self.assertFalse(args.destination.exists())


class DriverTests(unittest.TestCase):
    def exercise(self,fail=False,repeat_pid=False,original=1):
        calls=[];airplane=original;active=None;variant=None;count=None;launched=0
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);artifacts={}
            for v in ['baseline','checkpoint']:
                apk=root/(v+'.apk');apk.write_bytes(v.encode());artifacts[v]={'apk':apk,'apk_sha256':H(v.encode()),'activity':'fixture.Activity','provenance':source_proof(v),'provenance_sha256':H(v.encode())}
            def adb(serial,*a,**kw):
                nonlocal airplane,active,variant,count,launched
                calls.append(a)
                if a[:5]==('shell','settings','get','global','airplane_mode_on'):return str(airplane)
                if a[:4]==('shell','cmd','connectivity','airplane-mode'):airplane=int(a[-1]=='enable');return ''
                if a[:3]==('shell','am','force-stop'):active=None;return ''
                if a[:2]==('shell','pidof'):return '' if active is None else str(active)
                if a[0]=='install':variant='baseline' if a[-1].endswith('baseline.apk') else 'checkpoint';return 'Success'
                if a[:3]==('shell','pm','clear'):return 'Success'
                if a[:3]==('shell','am','start'):
                    launched+=1;active=101 if repeat_pid else 100+launched;count=int(a[-1].rsplit('/',1)[1]);return 'Status: ok\nTotalTime: 1\nWaitTime: 1'
                if a[0]=='logcat':
                    if fail:raise contract.Refused('fixture_phase_timeout')
                    return packet(receipt(variant,count,active))
                raise AssertionError('unmocked operation')
            args=types.SimpleNamespace(phase_timeout=15,source_commit=contract.SOURCE)
            try:
                with patch.object(cold,'adb',adb):result=driver.owned_run(args,'emulator-5554',artifacts)
            finally:self.calls=calls;self.final_airplane=airplane;self.active=active
        return result
    def test_two_apks_four_clears_routes_fresh_pids_and_restore(self):
        result=self.exercise();self.assertTrue(result['qualification_passed']);self.assertEqual(result['fresh_pid_count'],4)
        self.assertEqual(sum(x[0]=='install' for x in self.calls),2)
        self.assertEqual(sum(x[:3]==('shell','pm','clear') for x in self.calls),4)
        self.assertEqual([x[-1] for x in self.calls if x[:3]==('shell','am','start')],['/recall-outbox-cost/128','/recall-outbox-cost/512']*2)
        self.assertEqual(self.final_airplane,1);self.assertIsNone(self.active)
        self.assertFalse(any(x[:3]==('shell','pm','clear') and x[-1]!=contract.PACKAGE for x in self.calls))
    def test_error_restores_state_and_stops_owned_package(self):
        with self.assertRaises(contract.Refused):self.exercise(fail=True)
        self.assertEqual(self.final_airplane,1);self.assertIsNone(self.active)
        self.assertEqual(self.calls[-1],('shell','am','force-stop',contract.PACKAGE))
    def test_pid_reuse_refuses_even_with_valid_receipt(self):
        with self.assertRaises(contract.Refused) as caught:self.exercise(repeat_pid=True)
        self.assertEqual(caught.exception.code,'pid_not_fresh');self.assertIsNone(self.active)

class GuardTests(unittest.TestCase):
    def test_checkpoint_driver_owns_its_framing_import_without_shared_cache_alias(self):
        self.assertIs(driver.framing,_private_framing)
        self.assertIs(driver.framing.cold,cold)
        self.assertIsNot(driver.framing,sys.modules.get('run_synthetic_native_offline_restart'))
        self.assertNotEqual(driver.__name__,'run_native_checkpoint_cost')

    def test_actual_harness_head_is_distinct_from_pinned_baseline(self):
        actual='a'*40;value=receipt();value['source_commit']=actual
        self.assertEqual(contract.validate(value,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE,source_commit=actual)['baseline_source_commit'],contract.SOURCE)
        with self.assertRaises(contract.Refused):contract.validate(value,variant='baseline',count=128,pid=101,fixture_sha=FIXTURE)
        proof=source_proof();proof['source_commit']=actual;proof['cold_provenance']['source_commit']=actual
        self.assertEqual(contract.validate_provenance(proof,'baseline',actual)['source_commit'],actual)
        proof['baseline_source_commit']=actual
        with self.assertRaises(contract.Refused):contract.validate_provenance(proof,'baseline',actual)

    def test_driver_guards_precede_all_mutations_and_failure_output(self):
        from contextlib import ExitStack
        for mode in ['valid','wrong_apk','symlink','wrong_store','physical_device','no_kvm']:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as temp:
                root=Path(temp);args=types.SimpleNamespace(source_commit=contract.SOURCE,phase_timeout=15,output=root/'result')
                for variant in ['baseline','checkpoint']:
                    apk=root/(variant+'.apk');apk.write_bytes(variant.encode());setattr(args,variant+'_apk',apk)
                    proof=source_proof(variant)
                    if mode=='wrong_store':proof['store_sha256']='f'*64
                    path=root/(variant+'.json');path.write_text(json.dumps(proof));setattr(args,variant+'_provenance',path)
                if mode=='symlink':
                    linked=root/'link.apk';linked.symlink_to(args.baseline_apk);args.baseline_apk=linked
                package='com.german.health_anki_flutter' if mode=='wrong_apk' else contract.PACKAGE
                inventory='List of devices attached\n'+('physical-device' if mode=='physical_device' else 'emulator-5554')+'\tdevice\n'
                original_exists=driver.Path.exists
                def exists(path):return mode!='no_kvm' if str(path)=='/dev/kvm' else original_exists(path)
                with ExitStack() as stack:
                    stack.enter_context(patch.dict(os.environ,{'RUNNER_TEMP':temp}))
                    stack.enter_context(patch.object(cold,'require_ci',lambda:None))
                    stack.enter_context(patch.object(driver.Path,'exists',exists))
                    stack.enter_context(patch.object(driver.os,'access',return_value=True))
                    stack.enter_context(patch.object(driver.subprocess,'run',return_value=subprocess.CompletedProcess([],0,inventory,'')))
                    stack.enter_context(patch.object(cold,'adb',side_effect=lambda serial,*a,**kw:'1' if a[-1]=='ro.kernel.qemu' else 'x86_64'))
                    stack.enter_context(patch.object(cold,'apk_identity',return_value=(package,'fixture.Activity')))
                    owned=stack.enter_context(patch.object(driver,'owned_run',return_value={'invented_mock_result':True}))
                    if mode=='valid':self.assertEqual(driver.run(args),{'invented_mock_result':True})
                    else:
                        with self.assertRaises((contract.Refused,cold.Refused)):driver.run(args)
                self.assertEqual(owned.call_count,int(mode=='valid'))
                self.assertEqual(hasattr(args,'_qualified_output'),mode=='valid');self.assertFalse(args.output.exists())

    def test_unknown_exception_code_and_text_are_never_emitted(self):
        import contextlib,io
        with tempfile.TemporaryDirectory() as temp:
            args=['driver','--source-commit',contract.SOURCE,'--output',temp+'/result','--baseline-apk','base.apk','--checkpoint-apk','next.apk','--baseline-provenance','base.json','--checkpoint-provenance','next.json']
            out=io.StringIO()
            with patch.object(sys,'argv',args),patch.object(driver,'run',side_effect=contract.Refused('inventedprivatetoken')),contextlib.redirect_stdout(out):self.assertEqual(driver.main(),1)
            value=json.loads(out.getvalue());self.assertEqual(value['closed_failure_code'],'source_runtime_refused');self.assertNotIn('inventedprivatetoken',out.getvalue());self.assertFalse((Path(temp)/'result').exists())

if __name__=='__main__':unittest.main()
