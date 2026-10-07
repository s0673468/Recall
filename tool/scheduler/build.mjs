// Build output never contains personal data or credentials. No network calls.
import {spawnSync} from 'node:child_process';
import {readFileSync, writeFileSync, mkdirSync, rmSync} from 'node:fs';
import {gzipSync} from 'node:zlib';
import {resolve, dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {verifyArtifact, sha256} from './differential.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const output = resolve(process.argv[2] || join(root, 'build/scheduler'));
const dart = process.env.DART || 'dart';
mkdirSync(output, {recursive: true});
rmSync(join(output, 'provenance.json'), {force: true});
function run(command, args) {
  const result = spawnSync(command, args, {cwd: root, encoding: 'utf8'});
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || `${command} failed`);
  return `${result.stdout || ''}${result.stderr || ''}`.trim();
}
const dartVersion = run(dart, ['--version']);
run(dart, ['run', 'tool/scheduler/generate_vectors.dart', join(output, 'vectors.json')]);
run(dart, ['compile', 'js', '-O2', '--no-source-maps',
  'tool/scheduler/compile_entry.dart', '-o', join(output, 'engine.js')]);
const compiled = readFileSync(join(output, 'engine.js'), 'utf8');
const numericSource = readFileSync(join(root, 'tool/scheduler/numeric_math.mjs'), 'utf8');
const numericAdapterSha256 = sha256(numericSource);
const numericInline = numericSource.replace(/^export /gm, '');
if (/\beval\s*\(|new\s+Function\s*\(/.test(compiled)) {
  throw new Error('Compiled engine requires dynamic code evaluation');
}
writeFileSync(join(output, 'engine.mjs'), `${numericInline}\nconst Math = createNumericMath(globalThis.Math);\n${compiled}\n` +
  'const nativeSchedule = globalThis.recallDartSchedule;\n' +
  'delete globalThis.recallDartSchedule;\n' +
  `export const compiledSourceSha256 = '${sha256(compiled)}';\n` +
  `export const numericAdapterSha256 = '${numericAdapterSha256}';\n` +
  `export const numericAdapterAlgorithm = 'double-double-small-exp/v1';\n` +
  'export const schedule = (request) => JSON.parse(nativeSchedule(JSON.stringify(request)));\n');
writeFileSync(join(output, 'THIRD_PARTY_LICENSES.txt'), readFileSync(join(root, 'tool/scheduler/THIRD_PARTY_LICENSES.txt')));
writeFileSync(join(output, 'vectors.json.gz'), gzipSync(readFileSync(join(output, 'vectors.json')), {level: 9}));
const allowUnverified = process.argv.includes('--allow-unverified');
const proof = await verifyArtifact(output, false, null, !allowUnverified);
const sourceFiles = ['lib/features/review/application/fsrs_engine.dart',
  'lib/features/review/data/models.dart', 'pubspec.lock',
  'tool/scheduler/protocol.dart', 'tool/scheduler/compile_entry.dart',
  'tool/scheduler/generate_vectors.dart', 'tool/scheduler/numeric_math.mjs',
  'tool/scheduler/build.mjs', 'tool/scheduler/differential.mjs'];
proof.dartVersion = dartVersion;
proof.baseCommit = run('git', ['rev-parse', 'HEAD']);
proof.sourceHashes = Object.fromEntries(sourceFiles.map(file => [file, sha256(readFileSync(join(root, file)))]));
proof.generatedAt = new Date().toISOString();
writeFileSync(join(output, 'provenance.json'), JSON.stringify(proof, null, 2) + '\n');
rmSync(join(output, 'engine.js'), {force: true});
rmSync(join(output, 'engine.js.deps'), {force: true});
rmSync(join(output, 'vectors.json'), {force: true});
console.log(`${proof.matched}/${proof.vectors} matched; grading ${proof.verified ? 'enabled' : 'disabled'}. Engine ${proof.engineSha256}.`);
