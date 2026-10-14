"""Fabricated contract fixtures, not Android observations or measurements."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest

path=Path(__file__).resolve().parents[1]/'native_offline_receipt_contract.py'
spec=importlib.util.spec_from_file_location('native_offline_contract',path)
contract=importlib.util.module_from_spec(spec);spec.loader.exec_module(contract)
COMMIT='a'*40
H=lambda text:hashlib.sha256(text.encode()).hexdigest()


def fabricated_receipts():
    owner=H('invented-owner-A');event=H('invented-event-E1');snapshot=H('invented-snapshot')
    base={'schema':contract.SCHEMA,'source_commit':COMMIT,'package':contract.PACKAGE,
          'build_mode':'debug','environment':'github-hosted-isolated-android-emulator',
          'native_preferences':True,'auth_identity_injected':True,
          'owner_sha256':owner,'event_sha256':event,'snapshot_identity_sha256':snapshot,
          'os_airplane_state_observed_by_app':False,'physical_radio_state_covered':False,'real_provider_contacted':False}
    one={**base,'phase':'offline_recorded','pid':101,'pending_count':1,'current_card_id':2,
         'reviewed_this_session':1,'native_platform_ack_observed':True,'native_enqueue_ack_us':10,
         'offline_rpc_attempts':1,'fake_unique_accept_count':0,'phase_marker_native_ack_observed':True,
         'power_loss_durability_tested':False}
    two={**base,'phase':'restart_synced','pid':202,'phase_marker_restored':True,
         'event_restored_before_load':True,'snapshot_restored_before_load':True,'other_owner_sha256':H('invented-owner-B'),
         'other_owner_pending_count':0,'other_owner_snapshot_present':False,'pending_after_restart':1,
         'current_after_restart':2,'rated_card_requeued':False,'undo_available':False,
         'pending_after_lost_ack':1,'event_sha256_after_lost_ack':event,
         'fake_online_rpc_attempts':2,'fake_unique_accept_count':1,'fake_received_event_sha256':[event,event],
         'pending_after_ack':0,'native_remove_ack_observed':True,'current_after_online_refresh':2}
    launch={'schema':'recall-native-offline-launch/v2','source_commit':COMMIT,'package':contract.PACKAGE,
            'apk_sha256':H('invented-apk'),'apk_install_count':1,'initial_reset_count':1,'restart_reset_count':0,
            'phase_one_pid':101,'phase_two_pid':202,'force_stop_before_restart':True,
            'phase_one_process_gone':True,'same_owned_avd':True,'raw_logs_saved':False,
            'os_airplane_original_state':0,'os_airplane_phase_one_before':1,'os_airplane_phase_one_after':1,
            'os_airplane_phase_two_before':0,'os_airplane_phase_two_after':0,'os_airplane_restored_state':0,
            'os_airplane_phase_one_command_count':1,'os_airplane_phase_two_command_count':1,'os_airplane_restore_command_count':1}
    return launch,one,two


class ContractTests(unittest.TestCase):
    def test_expected_synthetic_contract_qualifies(self):
        result=contract.validate(*fabricated_receipts(),COMMIT)
        self.assertTrue(result['qualification_passed'])
        self.assertTrue(result['native_fresh_process_restart'])
        self.assertTrue(result['fake_http_sync_only'])
        self.assertFalse(result['physical_radio_state_covered'])
        self.assertFalse(result['real_provider_contacted'])

    def refused(self,which,updates,code):
        receipts=list(fabricated_receipts());receipts[which].update(updates)
        with self.assertRaises(contract.Refused) as caught:contract.validate(*receipts,COMMIT)
        self.assertEqual(caught.exception.code,code)

    def test_host_os_state_is_separate_from_app_radio_claims(self):
        result=contract.validate(*fabricated_receipts(),COMMIT)
        self.assertTrue(result['os_airplane_mode_exercised'])
        self.assertFalse(result['physical_radio_state_covered'])
    def test_missing_or_wrong_airplane_proof_is_refused(self):
        for updates in [{'os_airplane_original_state':True},{'os_airplane_phase_one_after':0},
                        {'os_airplane_phase_two_before':1},{'os_airplane_restored_state':1},
                        {'os_airplane_restore_command_count':0}]:
            with self.subTest(updates=updates):self.refused(0,updates,'os_airplane_state_not_proven')
    def test_native_reset_between_phases_is_refused(self):
        self.refused(0,{'restart_reset_count':1},'native_preferences_reset_or_reinstalled')

    def test_reinstall_between_phases_is_refused(self):
        self.refused(0,{'apk_install_count':2},'native_preferences_reset_or_reinstalled')

    def test_same_process_is_refused(self):
        launch,one,two=fabricated_receipts();two['pid']=one['pid'];launch['phase_two_pid']=one['pid']
        with self.assertRaises(contract.Refused) as caught:contract.validate(launch,one,two,COMMIT)
        self.assertEqual(caught.exception.code,'fresh_process_proof_invalid')

    def test_owner_or_event_or_snapshot_drift_is_refused(self):
        for field in ['owner_sha256','event_sha256','snapshot_identity_sha256']:
            with self.subTest(field=field):self.refused(2,{field:H('different')},'native_identity_not_preserved')

    def test_other_owner_cannot_inherit_native_state(self):
        self.refused(2,{'other_owner_pending_count':1},'owner_isolation_not_proven')

    def test_lost_ack_cannot_clear_the_outbox(self):
        self.refused(2,{'pending_after_lost_ack':0},'lost_ack_identity_not_preserved')

    def test_duplicate_fake_server_acceptance_is_refused(self):
        self.refused(2,{'fake_unique_accept_count':2},'fake_rpc_identity_or_dedup_not_proven')

    def test_retry_must_use_the_same_event(self):
        launch,one,two=fabricated_receipts();two['fake_received_event_sha256']=[one['event_sha256'],H('different-event')]
        with self.assertRaises(contract.Refused) as caught:contract.validate(launch,one,two,COMMIT)
        self.assertEqual(caught.exception.code,'fake_rpc_identity_or_dedup_not_proven')

    def test_memory_platform_fake_cannot_qualify(self):
        self.refused(1,{'native_preferences':False},'native_fixture_scope_invalid')

    def test_radio_or_provider_claims_cannot_be_inferred(self):
        for field in ['os_airplane_state_observed_by_app','physical_radio_state_covered','real_provider_contacted']:
            with self.subTest(field=field):self.refused(2,{field:True},'coverage_claim_invalid')

    def test_wrong_source_or_package_is_refused(self):
        self.refused(2,{'source_commit':'b'*40},'identity_invalid')
        self.refused(2,{'package':'com.german.health_anki_flutter'},'identity_invalid')

    def test_raw_payloads_and_log_artifacts_are_refused(self):
        self.refused(2,{'raw_event':'untrusted'},'phase_two_schema_invalid')
        self.refused(0,{'raw_logs_saved':True},'restart_or_privacy_proof_invalid')

    def test_ack_and_final_refresh_are_required(self):
        self.refused(2,{'native_remove_ack_observed':False},'native_delivery_completion_not_proven')
        self.refused(2,{'current_after_online_refresh':1},'native_delivery_completion_not_proven')


if __name__=='__main__':unittest.main()
