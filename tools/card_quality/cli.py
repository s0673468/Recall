"""Local-only train/score/explain CLI. Errors and stdout never echo source text."""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

from .adapter import load_export, read_json
from .features import QualityError
from .model import explain, score, train, validate_model
from .synthetic import generate


def private_write(path, value):
    """Atomic owner-only artifacts under an owner-only output directory.

    Refuse existing permissive directories instead of changing unrelated access.
    Refuse symlinks, including in output ancestry, and preserve existing files
    until serialization/write succeeds.
    """
    path = Path(path).absolute()
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise QualityError('output symlinks are not permitted')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    mode = path.parent.stat()
    if mode.st_uid != os.getuid() or stat.S_IMODE(mode.st_mode) & 0o077:
        raise QualityError('output directory must be owned by this user with mode 0700')
    fd, temporary = tempfile.mkstemp(prefix='.card-quality-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _json(value):
    return json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('train', 'score'):
        sub = commands.add_parser(command)
        sub.add_argument('--input', type=Path, required=True, help='offline Recall table export JSON')
        mode = sub.add_mutually_exclusive_group(required=True)
        mode.add_argument('--synthetic', action='store_true')
        mode.add_argument('--real-data', action='store_true', help='explicit local source opt-in; never prints content')
        sub.add_argument('--anki-db', type=Path, help='optional read-only authoring snapshot; requires --real-data')
        sub.add_argument('--out', type=Path, required=True, help='file inside a private 0700 directory')
        if command == 'score':
            sub.add_argument('--model', type=Path, required=True)
            sub.add_argument('--garden-map-out', type=Path, help='optional private card_id/nid map; requires --anki-db')
    sub = commands.add_parser('explain')
    sub.add_argument('--model', type=Path, required=True)
    sub.add_argument('--out', type=Path)
    sub = commands.add_parser('synthetic')
    sub.add_argument('--out', type=Path, required=True)
    sub.add_argument('--seed', type=int, default=17)
    args = parser.parse_args(argv)
    try:
        outputs = [getattr(args, key, None) for key in ('out', 'garden_map_out')]
        outputs = [p.resolve() for p in outputs if p is not None]
        inputs = [getattr(args, key, None) for key in ('input', 'model', 'anki_db')]
        inputs = [p.resolve() for p in inputs if p is not None]
        if len(set(outputs)) != len(outputs) or set(outputs) & set(inputs):
            raise QualityError('outputs must be distinct from sources and each other')
        if getattr(args, 'garden_map_out', None) and not args.anki_db:
            raise QualityError('a garden ID map requires --anki-db and explicit --real-data')
        if args.command == 'synthetic':
            private_write(args.out, _json(generate(seed=args.seed)))
            print('Synthetic fixture written.')
        elif args.command == 'explain':
            model = validate_model(read_json(args.model))
            sentences = explain(model)
            if args.out:
                private_write(args.out, '\n'.join(sentences) + '\n')
            else:
                print('\n'.join(sentences))
        else:
            rows = load_export(args.input, synthetic=args.synthetic, real_data=args.real_data, anki_db=args.anki_db)
            if args.command == 'train':
                model = train(rows)
                private_write(args.out, _json(model))
                print(_json({'training': model['training'], 'evaluation': model['evaluation']}), end='')
            else:
                predictions = score(validate_model(read_json(args.model)), rows)
                if args.out.suffix.lower() == '.csv':
                    stream = io.StringIO()
                    writer = csv.DictWriter(stream, fieldnames=('card_id', 'quality_score', 'forget_score', 'top_reasons'))
                    writer.writeheader()
                    writer.writerows({**row, 'top_reasons': ';'.join(row['top_reasons'])} for row in predictions)
                    result = stream.getvalue()
                elif args.out.suffix.lower() == '.json':
                    result = _json(predictions)
                else:
                    raise QualityError('scores output must be CSV or JSON')
                private_write(args.out, result)
                if args.garden_map_out:
                    private_write(args.garden_map_out, _json([
                        {'card_id': row['card_id'], 'nid': row['nid']} for row in rows
                    ]))
                print(f'Scored cards: {len(predictions)}')
        return 0
    except QualityError as error:
        print(f'card quality refused: {error}', file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
        # Raw exceptions may contain content, identifiers, file paths or values.
        print('card quality refused: invalid local data or unavailable private output', file=sys.stderr)
        return 2
