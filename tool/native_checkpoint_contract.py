"""Closed synthetic native-outbox cost receipts; contains no runtime I/O."""
import re
import hashlib
import json
from pathlib import PurePosixPath

SCHEMA='recall-native-outbox-cost/v1'
PACKAGE='com.german.recall.syntheticbenchmark'
FIXTURE_SHA='14d0c405edb826824278573afbf395cf03853b77a6e06193aeb7ebc37cc147d4'
SOURCE='65ccdd07fa6f04d9f6172449dc9582a93c388f4a'
BASE_CONTROLLER='36cc07b4bc83149673c2a1353a480e41137a0fa8102a525912351630d63ef081'
CHECKPOINT_CONTROLLER='1de4edbf61cdf5f1c7cd854f1e846140b798f0193bd299ae29cf339492b9497d'
STORE_SHA='6cafc9cb765dfb72ebb8a1ba588b15a8caaf10709503194465343c109dce3951'
STORE_BLOB='677f35e331a048e5abcc9eee8e725a1a6593db91'
PATCH_SHA='e164264887a97dbd2981ab938f22cc87cfd4550b7b2b1b8c2cccfc979f18d905'
TIMINGS={'sync_pending','mark_total','remove_total','native_ack_total','native_ack_max','api_apply_total'}
COUNTS={'mark_calls','remove_calls','native_ack_writes','native_ack_chars','native_ack_utf8_bytes','apply_review_requests','accepted_unique','pending_after'}
KEYS={'schema','phase','baseline_source_commit','source_commit','variant','controller_sha256','store_git_blob','fixture_sha256','patch_sha256','package','pid','pending_seeded','build_mode','environment','native_preferences','fake_http_only','power_loss_tested','physical_device_tested','real_provider_contacted','timing_us','counts'}

class Refused(Exception):
    def __init__(self,code):self.code=code

def require(ok,code):
    if not ok:raise Refused(code)

def digest(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None

def validate(value, *, variant, count, pid, fixture_sha, source_commit=SOURCE):
    require(type(source_commit) is str and re.fullmatch("[0-9a-f]{40}",source_commit) is not None,"pinned_source_required")
    require(variant in {'baseline','checkpoint'} and type(count) is int and count in {128,512},'bounded_case_required')
    require(type(value) is dict and value.get('schema')==SCHEMA,'fixture_schema_invalid')
    if value.get('phase')=='failed':
        require(set(value)=={'schema','phase','source_commit','variant','pid','failure_code'} and type(value.get('failure_code')) is str and value.get('failure_code') in {'guard_refused','measurement_refused'},'fixture_failure_schema_invalid')
        require(value.get('source_commit')==source_commit and value.get('variant')==variant and type(value.get('pid')) is int and value['pid']==pid,'fixture_identity_invalid')
        raise Refused('fixture_reported_failure')
    require(set(value)==KEYS and value.get('phase')=='done','fixture_fields_invalid')
    require(value['source_commit']==source_commit and value['baseline_source_commit']==SOURCE and value['variant']==variant and value['package']==PACKAGE and type(value['pid']) is int and value['pid']==pid and value['pending_seeded']==count and type(value['pending_seeded']) is int,'fixture_identity_invalid')
    require(fixture_sha==FIXTURE_SHA and value['fixture_sha256']==fixture_sha and value['store_git_blob']==STORE_BLOB and value['controller_sha256']==(BASE_CONTROLLER if variant=='baseline' else CHECKPOINT_CONTROLLER) and value['patch_sha256']==('none' if variant=='baseline' else PATCH_SHA),'fixture_source_binding_invalid')
    require(value['build_mode']=='debug' and value['environment']=='isolated_android_fixture' and value['native_preferences'] is True and value['fake_http_only'] is True and value['power_loss_tested'] is False and value['physical_device_tested'] is False and value['real_provider_contacted'] is False,'fixture_scope_invalid')
    times=value['timing_us'];counts=value['counts']
    require(type(times) is dict and set(times)==TIMINGS and all(type(x) is int and 0<=x<=1_000_000_000 for x in times.values()),'fixture_timing_invalid')
    require(type(counts) is dict and set(counts)==COUNTS and all(type(x) is int and 0<=x<=1_000_000_000_000 for x in counts.values()),'fixture_counts_invalid')
    removals=1 if variant=='baseline' else count//32
    require(counts['mark_calls']==count and counts['remove_calls']==(1 if variant=='baseline' else count//32+1) and counts['native_ack_writes']==count+removals and counts['apply_review_requests']==count and counts['accepted_unique']==count and counts['pending_after']==0,'fixture_completion_invalid')
    require(counts['native_ack_chars']>0 and counts['native_ack_utf8_bytes']>=counts['native_ack_chars'] and times['native_ack_max']<=times['native_ack_total']<=times['sync_pending'] and times['mark_total']<=times['sync_pending'] and times['remove_total']<=times['sync_pending'] and times['api_apply_total']<=times['sync_pending'],'fixture_metric_consistency_invalid')
    return value


def validate_provenance(value,variant,source_commit=SOURCE):
    require(type(source_commit) is str and re.fullmatch("[0-9a-f]{40}",source_commit) is not None,"pinned_source_required")
    keys={'schema','baseline_source_commit','source_commit','variant','package','controller_sha256','baseline_controller_sha256','store_sha256','store_git_blob','patch_sha256','fixture_sha256','technical_source_manifest_sha256','technical_source_files','technical_source_manifest','cold_provenance'}
    require(type(value) is dict and set(value)==keys and value['schema']=='recall-native-outbox-source/v1' and value['source_commit']==source_commit and value['baseline_source_commit']==SOURCE and value['variant']==variant and value['package']==PACKAGE,'source_provenance_invalid')
    require(value['controller_sha256']==(BASE_CONTROLLER if variant=='baseline' else CHECKPOINT_CONTROLLER) and value['baseline_controller_sha256']==BASE_CONTROLLER and value['store_sha256']==STORE_SHA and value['store_git_blob']==STORE_BLOB and value['patch_sha256']==('none' if variant=='baseline' else PATCH_SHA) and value['fixture_sha256']==FIXTURE_SHA and digest(value['technical_source_manifest_sha256']) and type(value['technical_source_files']) is int and 1<=value['technical_source_files']<=2000,'source_provenance_binding_invalid')
    manifest=value['technical_source_manifest']
    require(type(manifest) is list and len(manifest)==value['technical_source_files'],'technical_manifest_invalid')
    paths=[]
    for row in manifest:
        require(type(row) is dict and set(row)=={'path','sha256'} and type(row['path']) is str and digest(row['sha256']),'technical_manifest_invalid')
        path=PurePosixPath(row['path'])
        require(bool(path.parts) and not path.is_absolute() and str(path)==row['path'] and '..' not in path.parts and row['path'] not in paths,'technical_manifest_invalid')
        paths.append(row['path'])
    require(paths==sorted(paths) and hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest()==value['technical_source_manifest_sha256'],'technical_manifest_invalid')
    by_path={row['path']:row['sha256'] for row in manifest}
    require(by_path.get('lib/features/review/application/review_controller.dart')==value['controller_sha256'] and by_path.get('lib/features/review/data/local_review_store.dart')==STORE_SHA and by_path.get('tool/fixtures/synthetic_native_outbox_cost_main.dart')==FIXTURE_SHA,'technical_manifest_binding_invalid')
    cold=value['cold_provenance']
    require(type(cold) is dict and cold.get('source_commit')==source_commit and cold.get('package')==PACKAGE and cold.get('normal_source_unchanged') is True and cold.get('namespace_and_signing_policy_unchanged') is True and cold.get('test_only_transform') is True and cold.get('actual_cards_articles_media_copied') is False and cold.get('asset_scope')=='technical-fonts-only' and cold.get('application_id_changes')==1,'technical_copy_proof_invalid')
    return value

# Fixed labels only; never expose an arbitrary exception code as telemetry.
FAILURE_CODES = {
 'technical_manifest_invalid','technical_manifest_binding_invalid','bounded_case_required','fixture_schema_invalid','fixture_failure_schema_invalid',
 'fixture_identity_invalid','fixture_reported_failure','fixture_fields_invalid',
 'fixture_source_binding_invalid','fixture_scope_invalid','fixture_timing_invalid',
 'fixture_counts_invalid','fixture_completion_invalid','fixture_metric_consistency_invalid',
 'source_provenance_invalid','source_provenance_binding_invalid','technical_copy_proof_invalid',
 'checkpoint_input_pin_invalid','checkpoint_patch_scope_invalid','checkpoint_hunk_invalid',
 'checkpoint_context_invalid','checkpoint_result_pin_invalid','pinned_source_required',
 'new_owned_source_copy_required','baseline_source_pin_invalid','technical_copy_changed_source',
 'nonregular_technical_copy','technical_copy_size_invalid','original_source_changed',
 'duplicate_fixture_receipt','fixture_json_invalid','fixture_reset_failed','fresh_pid_missing',
 'fixture_frame_incomplete','fixture_phase_timeout','pid_not_fresh','emulator_airplane_state_changed',
 'apk_input_changed','four_case_proof_invalid','bounded_pinned_run_required','kvm_required',
 'new_owned_output_required','adb_inventory_failed','single_owned_emulator_required',
 'isolated_x64_avd_required','isolated_apk_identity_required','distinct_variant_artifacts_required',
 'isolated_hosted_ci_required','nonregular_input','gradle_source_pin_changed',
 'application_id_transform_refused','pubspec_source_pin_changed','asset_stanza_refused',
 'owned_temporary_copy_required','new_source_copy_required','source_commit_required',
 'fixture_helper_missing','technical_fonts_missing','owned_emulator_required',
 'adb_unavailable_or_timeout','adb_command_failed','cold_launch_failed','launch_metrics_missing',
 'aapt_required','apk_inspection_failed','activity_identity_invalid','previous_process_not_gone',
 'airplane_state_invalid_or_unsupported','airplane_target_invalid',
 'airplane_state_change_not_observed','fixture_frame_mixed_protocol','fixture_packet_invalid',
 'fixture_packet_metadata_invalid','fixture_packet_sequence_invalid','fixture_packet_encoding_invalid',
 'fixture_packet_length_invalid','fixture_frame_checksum_invalid','fixture_frame_utf8_invalid',
 'regular_apk_required','source_preparation_refused','source_runtime_refused','output_write_refused'
}

def closed_code(value, fallback):
    return value if type(value) is str and value in FAILURE_CODES else fallback
