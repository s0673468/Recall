"""Validate a future native synthetic restart run. No SDK/ADB/network calls."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import sys

PACKAGE = 'com.german.recall.syntheticbenchmark'
SCHEMA = 'recall-native-offline-restart/v2'
COMMON = {'schema','source_commit','phase','package','pid','build_mode','environment',
          'native_preferences','owner_sha256','event_sha256','snapshot_identity_sha256',
          'os_airplane_state_observed_by_app','physical_radio_state_covered','real_provider_contacted',
          'auth_identity_injected'}
ONE = {'pending_count','current_card_id','reviewed_this_session','native_platform_ack_observed',
       'native_enqueue_ack_us','offline_rpc_attempts','fake_unique_accept_count',
       'phase_marker_native_ack_observed','power_loss_durability_tested'}
TWO = {'phase_marker_restored','event_restored_before_load','snapshot_restored_before_load',
       'other_owner_sha256','other_owner_pending_count','other_owner_snapshot_present',
       'pending_after_restart','current_after_restart','rated_card_requeued','undo_available',
       'pending_after_lost_ack','event_sha256_after_lost_ack','fake_online_rpc_attempts',
       'fake_unique_accept_count','fake_received_event_sha256','pending_after_ack',
       'native_remove_ack_observed','current_after_online_refresh'}
LAUNCH = {'schema','source_commit','package','apk_sha256','apk_install_count','initial_reset_count',
          'restart_reset_count','phase_one_pid','phase_two_pid','force_stop_before_restart',
          'phase_one_process_gone','same_owned_avd','raw_logs_saved',
          'os_airplane_original_state','os_airplane_phase_one_before','os_airplane_phase_one_after',
          'os_airplane_phase_two_before','os_airplane_phase_two_after','os_airplane_restored_state',
          'os_airplane_phase_one_command_count','os_airplane_phase_two_command_count','os_airplane_restore_command_count'}


class Refused(Exception):
    def __init__(self, code): self.code = code


def require(condition, code):
    if not condition: raise Refused(code)


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def digest(value):
    return isinstance(value,str) and re.fullmatch(r'[0-9a-f]{64}',value) is not None


FRAME_DIAGNOSTIC_LIMIT = 4096
FRAME_DIAGNOSTIC_KEYS = {'byte_count','byte_count_capped','parse_offset',
                         'parse_offset_capped','object_prefix','object_suffix'}


def validate_frame_diagnostics(value):
    """Closed framing facts only; never a source string or decoder message."""
    require(isinstance(value,dict) and set(value)==FRAME_DIAGNOSTIC_KEYS,
            'fixture_frame_diagnostics_invalid')
    require(all(type(value[k]) is int and 0 <= value[k] <= FRAME_DIAGNOSTIC_LIMIT
                for k in ('byte_count','parse_offset')) and
            all(type(value[k]) is bool for k in
                ('byte_count_capped','parse_offset_capped','object_prefix','object_suffix')) and
            value['parse_offset'] <= value['byte_count'] and
            (not value['byte_count_capped'] or value['byte_count']==FRAME_DIAGNOSTIC_LIMIT) and
            (not value['parse_offset_capped'] or value['parse_offset']==FRAME_DIAGNOSTIC_LIMIT),
            'fixture_frame_diagnostics_invalid')
    return dict(value)


def identity(value, phase, commit):
    require(value['schema']==SCHEMA and value['phase']==phase and value['source_commit']==commit and
            value['package']==PACKAGE and integer(value['pid'],1) and value['build_mode']=='debug' and
            value['environment']=='github-hosted-isolated-android-emulator','identity_invalid')
    require(value['native_preferences'] is True and value['auth_identity_injected'] is True,
            'native_fixture_scope_invalid')
    require(all(value[key] is False for key in
       ('os_airplane_state_observed_by_app','physical_radio_state_covered','real_provider_contacted')),
       'coverage_claim_invalid')
    require(all(digest(value[key]) for key in
       ('owner_sha256','event_sha256','snapshot_identity_sha256')),'identity_hash_invalid')


def validate(launch, one, two, commit):
    require(re.fullmatch(r'[0-9a-f]{40}',commit) is not None,'source_commit_invalid')
    require(isinstance(launch,dict) and set(launch)==LAUNCH,'launch_schema_invalid')
    require(isinstance(one,dict) and set(one)==COMMON|ONE,'phase_one_schema_invalid')
    require(isinstance(two,dict) and set(two)==COMMON|TWO,'phase_two_schema_invalid')
    identity(one,'offline_recorded',commit);identity(two,'restart_synced',commit)
    require(launch['schema']=='recall-native-offline-launch/v2' and launch['source_commit']==commit and
            launch['package']==PACKAGE and digest(launch['apk_sha256']),'launch_identity_invalid')
    require(type(launch['apk_install_count']) is int and launch['apk_install_count']==1 and
            type(launch['initial_reset_count']) is int and launch['initial_reset_count']==1 and
            type(launch['restart_reset_count']) is int and launch['restart_reset_count']==0,
            'native_preferences_reset_or_reinstalled')
    require(launch['force_stop_before_restart'] is True and launch['phase_one_process_gone'] is True and
            launch['same_owned_avd'] is True and launch['raw_logs_saved'] is False,
            'restart_or_privacy_proof_invalid')
    require(launch['phase_one_pid']==one['pid'] and launch['phase_two_pid']==two['pid'] and
            integer(launch['phase_one_pid'],1) and integer(launch['phase_two_pid'],1) and
            one['pid']!=two['pid'],'fresh_process_proof_invalid')
    require(type(launch['os_airplane_original_state']) is int and launch['os_airplane_original_state'] in (0,1) and
            all(type(launch[k]) is int and launch[k]==1 for k in ('os_airplane_phase_one_before','os_airplane_phase_one_after')) and
            all(type(launch[k]) is int and launch[k]==0 for k in ('os_airplane_phase_two_before','os_airplane_phase_two_after')) and
            type(launch['os_airplane_restored_state']) is int and launch['os_airplane_restored_state']==launch['os_airplane_original_state'] and
            all(type(launch[k]) is int and launch[k]==1 for k in ('os_airplane_phase_one_command_count','os_airplane_phase_two_command_count','os_airplane_restore_command_count')),
            'os_airplane_state_not_proven')
    for key in ('owner_sha256','event_sha256','snapshot_identity_sha256'):
        require(one[key]==two[key],'native_identity_not_preserved')
    require(one['pending_count']==1 and type(one['pending_count']) is int and
            one['current_card_id']==2 and type(one['current_card_id']) is int and
            one['reviewed_this_session']==1 and type(one['reviewed_this_session']) is int and
            one['native_platform_ack_observed'] is True and integer(one['native_enqueue_ack_us']) and
            integer(one['offline_rpc_attempts'],1) and one['fake_unique_accept_count']==0 and
            type(one['fake_unique_accept_count']) is int and one['phase_marker_native_ack_observed'] is True and
            one['power_loss_durability_tested'] is False,'offline_native_ack_not_proven')
    require(two['phase_marker_restored'] is True and two['event_restored_before_load'] is True and
            two['snapshot_restored_before_load'] is True,'native_restore_not_proven')
    require(digest(two['other_owner_sha256']) and two['other_owner_sha256']!=one['owner_sha256'] and
            type(two['other_owner_pending_count']) is int and two['other_owner_pending_count']==0 and
            two['other_owner_snapshot_present'] is False,'owner_isolation_not_proven')
    require(type(two['pending_after_restart']) is int and two['pending_after_restart']==1 and
            type(two['current_after_restart']) is int and two['current_after_restart']==2 and
            two['rated_card_requeued'] is False and two['undo_available'] is False,
            'restarted_queue_not_safe')
    require(type(two['pending_after_lost_ack']) is int and two['pending_after_lost_ack']==1 and
            two['event_sha256_after_lost_ack']==one['event_sha256'], 'lost_ack_identity_not_preserved')
    require(type(two['fake_online_rpc_attempts']) is int and two['fake_online_rpc_attempts']==2 and
            type(two['fake_unique_accept_count']) is int and two['fake_unique_accept_count']==1 and
            two['fake_received_event_sha256']==[one['event_sha256'],one['event_sha256']],
            'fake_rpc_identity_or_dedup_not_proven')
    require(type(two['pending_after_ack']) is int and two['pending_after_ack']==0 and
            two['native_remove_ack_observed'] is True and
            type(two['current_after_online_refresh']) is int and two['current_after_online_refresh']==2,
            'native_delivery_completion_not_proven')
    return {'schema':'recall-native-offline-qualification/v2','qualification_passed':True,
            'source_commit':commit,'package':PACKAGE,'native_fresh_process_restart':True,
            'native_shared_preferences':True,'fake_http_sync_only':True,
            'os_airplane_mode_exercised':True,'os_airplane_scope':'disposable-owned-emulator-state-only',
            'os_airplane_original_state':launch['os_airplane_original_state'],
            'os_airplane_phase_one_state':1,'os_airplane_phase_two_state':0,
            'os_airplane_restored_state':launch['os_airplane_restored_state'],
            'os_airplane_phase_one_command_count':launch['os_airplane_phase_one_command_count'],
            'os_airplane_phase_two_command_count':launch['os_airplane_phase_two_command_count'],
            'os_airplane_restore_command_count':launch['os_airplane_restore_command_count'],
            'physical_radio_state_covered':False,
            'real_provider_contacted':False,'auth_identity_injected':True,
            'power_loss_durability_tested':False,'owner_sha256':one['owner_sha256'],
            'event_sha256':one['event_sha256'],'snapshot_identity_sha256':one['snapshot_identity_sha256'],
            'phase_one_pid':one['pid'],'phase_two_pid':two['pid'],'raw_logs_printed':False}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--launch',type=Path,required=True)
    parser.add_argument('--phase-one',type=Path,required=True);parser.add_argument('--phase-two',type=Path,required=True)
    parser.add_argument('--expected-source',required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        result=validate(json.loads(args.launch.read_bytes()),json.loads(args.phase_one.read_bytes()),
                        json.loads(args.phase_two.read_bytes()),args.expected_source);code=0
    except (Refused,ValueError,OSError,KeyError,TypeError):
        error=sys.exc_info()[1];result={'schema':'recall-native-offline-qualification/v2',
           'qualification_passed':False,'closed_failure_code':error.code if isinstance(error,Refused) else 'input_unavailable',
           'raw_logs_printed':False};code=1
    with args.output.open('x') as out:json.dump(result,out,sort_keys=True,indent=2);out.write('\n')
    print(json.dumps(result,sort_keys=True));return code


if __name__=='__main__': sys.exit(main())
