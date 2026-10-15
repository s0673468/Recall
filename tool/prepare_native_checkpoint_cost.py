"""One new technical source copy per variant, no build or SDK invocation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import measure_android_cold_start as cold
import native_checkpoint_contract as contract

CONTROLLER='lib/features/review/application/review_controller.dart'
STORE='lib/features/review/data/local_review_store.dart'
ENTRY='tool/fixtures/synthetic_native_outbox_cost_main.dart'


def apply_checkpoint(data,patch):
    contract.require(cold.sha(data)==contract.BASE_CONTROLLER and cold.sha(patch)==contract.PATCH_SHA,'checkpoint_input_pin_invalid')
    lines=patch.decode().splitlines(keepends=True)
    contract.require(lines[:2]==['--- a/'+CONTROLLER+'\n','+++ b/'+CONTROLLER+'\n'],'checkpoint_patch_scope_invalid')
    source=data.decode().splitlines(keepends=True);out=[];cursor=0;at=2;hunks=0
    while at<len(lines):
        match=re.fullmatch(r'@@ -([0-9]+),([0-9]+) \+([0-9]+),([0-9]+) @@\n',lines[at])
        contract.require(match is not None,'checkpoint_hunk_invalid')
        old_start,old_count,new_start,new_count=map(int,match.groups());start=old_start-1
        contract.require(cursor<=start<=len(source),'checkpoint_hunk_invalid')
        out.extend(source[cursor:start]);cursor=start;at+=1;removed=added=0
        while at<len(lines) and not lines[at].startswith('@@ '):
            line=lines[at];contract.require(line[:1] in {' ','-','+'},'checkpoint_hunk_invalid')
            if line[0] in ' -':
                contract.require(cursor<len(source) and source[cursor]==line[1:],'checkpoint_context_invalid')
                cursor+=1;removed+=1
            if line[0] in ' +':out.append(line[1:]);added+=1
            at+=1
        contract.require(removed==old_count and added==new_count,'checkpoint_hunk_invalid');hunks+=1
    out.extend(source[cursor:]);result=''.join(out).encode()
    contract.require(hunks==3 and cold.sha(result)==contract.CHECKPOINT_CONTROLLER,'checkpoint_result_pin_invalid')
    return result


def prepare(args):
    cold.require_ci();contract.require(re.fullmatch('[0-9a-f]{40}',args.source_commit) is not None and args.variant in {'baseline','checkpoint'} and args.fixture_sha==contract.FIXTURE_SHA,'pinned_source_required')
    source=args.source.resolve(strict=True);destination=args.destination.resolve(strict=False)
    temporary=Path(os.environ.get('RUNNER_TEMP','/missing')).resolve(strict=True)
    contract.require(temporary in destination.parents and not destination.exists() and not destination.is_symlink(),'new_owned_source_copy_required')
    controller=cold.regular_bytes(source/CONTROLLER);store=cold.regular_bytes(source/STORE);entry=cold.regular_bytes(source/ENTRY)
    contract.require(cold.sha(controller)==contract.BASE_CONTROLLER and cold.sha(store)==contract.STORE_SHA and cold.sha(entry)==args.fixture_sha,'baseline_source_pin_invalid')
    patch=cold.regular_bytes(args.patch);changed=apply_checkpoint(controller,patch)
    args.destination=destination;args.source=source
    base=cold.prepare(args)
    target=destination/CONTROLLER
    contract.require(cold.regular_bytes(target)==controller and cold.regular_bytes(destination/STORE)==store,'technical_copy_changed_source')
    if args.variant=='checkpoint':target.write_bytes(changed)
    manifest=[]
    for path in sorted(destination.rglob('*')):
        if path.is_file():
            contract.require(not path.is_symlink(),'nonregular_technical_copy')
            manifest.append({'path':path.relative_to(destination).as_posix(),'sha256':cold.sha(cold.regular_bytes(path))})
    manifest.sort(key=lambda row:row['path'])
    contract.require(1<=len(manifest)<=2000,'technical_copy_size_invalid')
    digest=cold.sha(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode())
    proof={'schema':'recall-native-outbox-source/v1','source_commit':args.source_commit,'baseline_source_commit':contract.SOURCE,'variant':args.variant,'package':contract.PACKAGE,'controller_sha256':contract.BASE_CONTROLLER if args.variant=='baseline' else contract.CHECKPOINT_CONTROLLER,'baseline_controller_sha256':contract.BASE_CONTROLLER,'store_sha256':contract.STORE_SHA,'store_git_blob':contract.STORE_BLOB,'patch_sha256':'none' if args.variant=='baseline' else contract.PATCH_SHA,'fixture_sha256':args.fixture_sha,'technical_source_manifest_sha256':digest,'technical_source_files':len(manifest),'technical_source_manifest':manifest,'cold_provenance':base}
    contract.validate_provenance(proof,args.variant,args.source_commit)
    contract.require(cold.regular_bytes(source/CONTROLLER)==controller and cold.regular_bytes(source/STORE)==store and cold.regular_bytes(source/ENTRY)==entry,'original_source_changed')
    return proof


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,required=True);parser.add_argument('--destination',type=Path,required=True);parser.add_argument('--source-commit',required=True);parser.add_argument('--variant',choices=['baseline','checkpoint'],required=True);parser.add_argument('--patch',type=Path,default=Path(__file__).parent/'fixtures/checkpoint-drain-only.patch');parser.add_argument('--fixture-sha',required=True);args=parser.parse_args()
    try:value=prepare(args)
    except (contract.Refused,cold.Refused) as error:
        print(json.dumps({'schema':'recall-native-outbox-preparation/v1','prepared':False,'closed_failure_code':contract.closed_code(getattr(error,'code',None),'source_preparation_refused')}));return 1
    except Exception:
        print(json.dumps({'schema':'recall-native-outbox-preparation/v1','prepared':False,'closed_failure_code':'source_preparation_refused'}));return 1
    print(json.dumps(value,sort_keys=True));return 0

if __name__=='__main__':raise SystemExit(main())
